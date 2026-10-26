package main

// Our store (wa.db): what whatsmeow does not keep, shaped like WhatsApp Web's IndexedDB
// (docs/whatsapp-web-api-map.md §06.1.10): messages by message key (with the original protobuf,
// which media download needs), add-ons in their own tables keyed by the parent (reactions) or
// parked until the parent exists (orphans), chats, contacts and group metadata. whatsmeow's own
// store (keys, sessions) lives beside it, one file per account.

import (
	"database/sql"
	"encoding/json"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

type Store struct{ db *sql.DB }

func openStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one writer; SQLite serializes anyway
	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS msgs(
  account TEXT, key TEXT, remote TEXT, id TEXT, t INTEGER, type TEXT, star INTEGER DEFAULT 0,
  json TEXT, raw BLOB, PRIMARY KEY(account, key));
CREATE INDEX IF NOT EXISTS msgs_by_chat ON msgs(account, remote, t);
CREATE INDEX IF NOT EXISTS msgs_by_id ON msgs(account, remote, id);
CREATE VIRTUAL TABLE IF NOT EXISTS msgs_fts USING fts5(account UNINDEXED, key UNINDEXED, remote UNINDEXED, body);
CREATE TABLE IF NOT EXISTS reactions(
  account TEXT, remote TEXT, parent TEXT, sender TEXT, text TEXT, t INTEGER, fromMe INTEGER,
  PRIMARY KEY(account, remote, parent, sender));
CREATE TABLE IF NOT EXISTS orphans(
  account TEXT, remote TEXT, parent TEXT, kind TEXT, json TEXT, t INTEGER);
CREATE INDEX IF NOT EXISTS orphans_by_parent ON orphans(account, remote, parent);
CREATE TABLE IF NOT EXISTS chats(
  account TEXT, id TEXT, name TEXT DEFAULT '', t INTEGER DEFAULT 0,
  unreadCount INTEGER DEFAULT 0, unreadMentionCount INTEGER DEFAULT 0, markedUnread INTEGER DEFAULT 0,
  archive INTEGER DEFAULT 0, pin INTEGER DEFAULT 0, muteExpiration INTEGER DEFAULT 0,
  isReadOnly INTEGER DEFAULT 0, isAnnounceGrpRestrict INTEGER DEFAULT 0, ephemeralDuration INTEGER DEFAULT 0,
  endOfHistoryTransferType INTEGER DEFAULT 0, draftMessage TEXT DEFAULT '', isParentGroup INTEGER DEFAULT 0,
  clearedAt INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
  PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS contacts(
  account TEXT, id TEXT, name TEXT DEFAULT '', shortName TEXT DEFAULT '', pushname TEXT DEFAULT '',
  verifiedName TEXT DEFAULT '', isBusiness INTEGER DEFAULT 0, blocked INTEGER DEFAULT 0,
  phoneNumber TEXT DEFAULT '', status TEXT DEFAULT '', pic TEXT DEFAULT '',
  PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS groups(account TEXT, id TEXT, json TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS chat_pins(account TEXT, chat TEXT, msg TEXT, until INTEGER, PRIMARY KEY(account, chat));
CREATE TABLE IF NOT EXISTS status_seen(account TEXT, key TEXT, PRIMARY KEY(account, key));
CREATE TABLE IF NOT EXISTS status_mute(account TEXT, id TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS msg_marks(account TEXT, key TEXT, star INTEGER DEFAULT -1, deleted INTEGER DEFAULT 0,
  PRIMARY KEY(account, key));
CREATE TABLE IF NOT EXISTS chat_read(account TEXT, chat TEXT, t INTEGER, PRIMARY KEY(account, chat));
`)
	if err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// ---- messages ------------------------------------------------------------------------------------

// putMsg: insert or replace a message, then apply the add-ons that were waiting for it.
// A real message replaces a `ciphertext` placeholder with the same id.
func (s *Store) putMsg(m Msg, raw []byte) {
	m = stored(m)
	j, _ := json.Marshal(m)
	if m.Type != "ciphertext" {
		s.db.Exec(`DELETE FROM msgs WHERE account=? AND remote=? AND id=? AND type='ciphertext' AND key!=?`, m.Account, m.Remote, m.MsgID, m.ID)
	}
	s.db.Exec(`INSERT INTO msgs(account, key, remote, id, t, type, star, json, raw) VALUES(?,?,?,?,?,?,?,?,?)
		ON CONFLICT(account, key) DO UPDATE SET t=excluded.t, type=excluded.type, star=excluded.star, json=excluded.json,
		  raw=COALESCE(excluded.raw, msgs.raw)`,
		m.Account, m.ID, m.Remote, m.MsgID, m.T, m.Type, b2i(m.Star), string(j), raw)
	s.index(m)
}

// stored: a Msg without what handOut adds (names are looked up when handed out, never kept).
func stored(m Msg) Msg {
	m.SenderName, m.TemplateNames, m.ChatName, m.SenderPic = "", nil, "", ""
	if m.QuotedMsg != nil {
		q := *m.QuotedMsg
		q.AuthorName = ""
		m.QuotedMsg = &q
	}
	return m
}

func (s *Store) index(m Msg) {
	s.db.Exec(`DELETE FROM msgs_fts WHERE account=? AND key=?`, m.Account, m.ID)
	body := strings.TrimSpace(m.Body + " " + m.Caption + " " + m.PollName)
	if m.MediaData != nil {
		body += " " + m.MediaData.Filename
	}
	if strings.TrimSpace(body) != "" && m.Type != "revoked" {
		s.db.Exec(`INSERT INTO msgs_fts(account, key, remote, body) VALUES(?,?,?,?)`, m.Account, m.ID, m.Remote, body)
	}
}

// updateMsg: rewrite a stored message (its protobuf stays).
func (s *Store) updateMsg(m Msg) {
	m = stored(m)
	j, _ := json.Marshal(m)
	s.db.Exec(`UPDATE msgs SET json=?, type=?, star=?, t=? WHERE account=? AND key=?`, string(j), m.Type, b2i(m.Star), m.T, m.Account, m.ID)
	s.index(m)
}

func (s *Store) msg(account, key string) (Msg, []byte, bool) {
	return s.msgWhere(`account=? AND key=?`, account, key)
}

// msgByID: a message by chat + bare id (add-ons name their parent this way).
func (s *Store) msgByID(account, remote, id string) (Msg, []byte, bool) {
	return s.msgWhere(`account=? AND remote=? AND id=? ORDER BY type='ciphertext' LIMIT 1`, account, remote, id)
}

func (s *Store) msgWhere(where string, args ...any) (Msg, []byte, bool) {
	var j string
	var raw []byte
	if err := s.db.QueryRow(`SELECT json, raw FROM msgs WHERE `+where, args...).Scan(&j, &raw); err != nil {
		return Msg{}, nil, false
	}
	var m Msg
	json.Unmarshal([]byte(j), &m)
	return m, raw, true
}

// ---- app-state marks (star / delete for me), kept for messages that arrive after them ----------

func (s *Store) setStarMark(account, key string, starred bool) {
	s.db.Exec(`INSERT INTO msg_marks(account, key, star) VALUES(?,?,?)
		ON CONFLICT(account, key) DO UPDATE SET star=excluded.star`, account, key, b2i(starred))
}

func (s *Store) setDeleteMark(account, key string) {
	s.db.Exec(`INSERT INTO msg_marks(account, key, deleted) VALUES(?,?,1)
		ON CONFLICT(account, key) DO UPDATE SET deleted=1`, account, key)
}

// mark: star is -1 (none), 0 or 1.
func (s *Store) mark(account, key string) (star int, deleted bool) {
	star = -1
	var d int
	if s.db.QueryRow(`SELECT star, deleted FROM msg_marks WHERE account=? AND key=?`, account, key).Scan(&star, &d) != nil {
		return -1, false
	}
	return star, d != 0
}

// applyMarks: a message about to be stored takes the marks recorded before it arrived; false when it
// was deleted for me (it must not be stored).
func (s *Store) applyMarks(m *Msg) bool {
	star, deleted := s.mark(m.Account, m.ID)
	if deleted {
		return false
	}
	if star >= 0 {
		m.Star = star == 1
	}
	return true
}

// markRead: the phone read the chat up to t; unread = incoming messages after that.
func (s *Store) markRead(account, chat string, t int64) {
	s.db.Exec(`INSERT INTO chat_read(account, chat, t) VALUES(?,?,?)
		ON CONFLICT(account, chat) DO UPDATE SET t=MAX(chat_read.t, excluded.t)`, account, chat, t)
	t = s.readAt(account, chat) // an older replayed mark must not bring unread back
	var n int64
	s.db.QueryRow(`SELECT count(*) FROM msgs WHERE account=? AND remote=? AND t>?
		AND json_extract(json, '$.fromMe') IS NOT 1`, account, chat, t).Scan(&n)
	s.db.Exec(`UPDATE chats SET unreadCount=?, unreadMentionCount=0, markedUnread=0 WHERE account=? AND id=?`, n, account, chat)
}

func (s *Store) readAt(account, chat string) int64 {
	var t int64
	s.db.QueryRow(`SELECT COALESCE(MAX(t), 0) FROM chat_read WHERE account=? AND chat=?`, account, chat).Scan(&t)
	return t
}

func (s *Store) deleteMsg(account, key string) {
	s.db.Exec(`DELETE FROM msgs WHERE account=? AND key=?`, account, key)
	s.db.Exec(`DELETE FROM msgs_fts WHERE account=? AND key=?`, account, key)
}

// msgs: a chat's window, oldest first (before: only messages older than this time).
func (s *Store) msgs(account, remote string, before int64, limit int) []Msg {
	if limit <= 0 || limit > 500 {
		limit = 60
	}
	if before <= 0 {
		before = 1 << 62
	}
	out := s.msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND t<? ORDER BY t DESC, rowid DESC LIMIT ?`, account, remote, before, limit)
	for i, k := 0, len(out)-1; i < k; i, k = i+1, k-1 {
		out[i], out[k] = out[k], out[i]
	}
	return out
}

func (s *Store) oldestMsg(account, remote string) (Msg, bool) {
	l := s.msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND type NOT IN ('gp2','e2e_notification','notification_template','call_log') ORDER BY t ASC LIMIT 1`, account, remote)
	if len(l) == 0 {
		return Msg{}, false
	}
	return l[0], true
}

// lastMsg: the chat's newest message (the chat list's preview).
func (s *Store) lastMsg(account, remote string) (Msg, bool) {
	// the list's preview: not the security-code notices, nor who joined or left (as WhatsApp Web)
	l := s.msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND type!='e2e_notification'
		AND NOT (type='gp2' AND json_extract(json, '$.subtype') IN ('add','remove','leave','invite','linked_group_join','community_link','member_add_mode'))
		ORDER BY t DESC, rowid DESC LIMIT 1`, account, remote)
	if len(l) == 0 {
		return Msg{}, false
	}
	return l[0], true
}

func (s *Store) search(account, query, remote string, limit int) []Msg {
	if limit <= 0 || limit > 200 {
		limit = 30
	}
	q := `SELECT m.json FROM msgs_fts f JOIN msgs m ON m.account=f.account AND m.key=f.key WHERE msgs_fts MATCH ? AND f.account=?`
	args := []any{query, account}
	if remote != "" {
		q += ` AND f.remote=?`
		args = append(args, remote)
	}
	q += ` ORDER BY m.t DESC LIMIT ?`
	return s.msgList(q, append(args, limit)...)
}

func (s *Store) msgList(q string, args ...any) []Msg {
	out := []Msg{}
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var j string
		rows.Scan(&j)
		var m Msg
		if json.Unmarshal([]byte(j), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

// clearChat: the chat's messages up to t go (keepStarred keeps starred ones), as WhatsApp's clearChat.
func (s *Store) clearChat(account, remote string, t int64, keepStarred bool) []string {
	q := `SELECT key FROM msgs WHERE account=? AND remote=? AND t<=?`
	if keepStarred {
		q += ` AND star=0`
	}
	keys := []string{}
	rows, err := s.db.Query(q, account, remote, t)
	if err == nil {
		for rows.Next() {
			var k string
			rows.Scan(&k)
			keys = append(keys, k)
		}
		rows.Close()
	}
	for _, k := range keys {
		s.deleteMsg(account, k)
	}
	return keys
}

// ---- add-ons -------------------------------------------------------------------------------------

// applyAddon: a reaction, edit or revoke changes its parent; parked when the parent is not here yet.
// Returns the changed parent.
func (s *Store) applyAddon(account, remote string, a Addon, me string) (Msg, bool) {
	parent, _, ok := s.msgByID(account, remote, a.ParentID)
	if !ok {
		j, _ := json.Marshal(a)
		s.db.Exec(`INSERT INTO orphans(account, remote, parent, kind, json, t) VALUES(?,?,?,?,?,?)`, account, remote, a.ParentID, a.Kind, string(j), a.T)
		return Msg{}, false
	}
	switch a.Kind {
	case "reaction":
		if a.Text == "" {
			s.db.Exec(`DELETE FROM reactions WHERE account=? AND remote=? AND parent=? AND sender=?`, account, remote, a.ParentID, a.Sender)
		} else {
			s.db.Exec(`INSERT INTO reactions(account, remote, parent, sender, text, t, fromMe) VALUES(?,?,?,?,?,?,?)
				ON CONFLICT(account, remote, parent, sender) DO UPDATE SET text=excluded.text, t=excluded.t`,
				account, remote, a.ParentID, a.Sender, a.Text, a.T, b2i(a.FromMe))
		}
		parent.Reactions = s.aggReactions(account, remote, a.ParentID)
	case "edit":
		if a.Edited != nil {
			if parent.Type == "chat" {
				parent.Body = a.Edited.Body
			} else {
				parent.Caption = previewBody(*a.Edited)
			}
			parent.MentionedJidList = a.Edited.MentionedJidList
		}
		parent.IsEdited, parent.LatestEditT = true, a.T
	case "revoke":
		parent.Type, parent.RevokeSender = "revoked", "sender_revoke"
		// in a group, someone other than the author revoking it is an admin
		if !parent.FromMe && parent.Author != "" && a.Sender != "" && a.Sender != parent.Author {
			parent.RevokeSender = "admin_revoke"
		}
		parent.Body, parent.Caption, parent.MediaData, parent.QuotedMsg, parent.Reactions = "", "", nil, nil, nil
		parent.Title, parent.Description, parent.Thumbnail, parent.MatchedText = "", "", "", ""
		parent.PollName, parent.PollOptions, parent.VcardList = "", nil, nil
	}
	s.updateMsg(parent)
	return parent, true
}

// adoptOrphans: the add-ons that arrived before m, applied now (history sync arrives out of order).
func (s *Store) adoptOrphans(m Msg, me string) (Msg, bool) {
	rows, err := s.db.Query(`SELECT rowid, json FROM orphans WHERE account=? AND remote=? AND parent=? ORDER BY t`, m.Account, m.Remote, m.MsgID)
	if err != nil {
		return m, false
	}
	type o struct {
		id int64
		a  Addon
	}
	list := []o{}
	for rows.Next() {
		var x o
		var j string
		rows.Scan(&x.id, &j)
		json.Unmarshal([]byte(j), &x.a)
		list = append(list, x)
	}
	rows.Close()
	if len(list) == 0 {
		return m, false
	}
	for _, x := range list {
		s.db.Exec(`DELETE FROM orphans WHERE rowid=?`, x.id)
		if p, ok := s.applyAddon(m.Account, m.Remote, x.a, me); ok {
			m = p
		}
	}
	return m, true
}

// aggReactions: WhatsApp Web's aggReactions — one entry per emoji, with its senders.
func (s *Store) aggReactions(account, remote, parent string) []Reaction {
	rows, err := s.db.Query(`SELECT sender, text, fromMe FROM reactions WHERE account=? AND remote=? AND parent=? ORDER BY t`, account, remote, parent)
	if err != nil {
		return nil
	}
	defer rows.Close()
	by := map[string]*Reaction{}
	order := []string{}
	for rows.Next() {
		var sender, text string
		var fromMe int
		rows.Scan(&sender, &text, &fromMe)
		r := by[text]
		if r == nil {
			r = &Reaction{AggregateEmoji: text}
			by[text] = r
			order = append(order, text)
		}
		r.Senders = append(r.Senders, sender)
		r.HasReactionByMe = r.HasReactionByMe || fromMe != 0
	}
	out := []Reaction{}
	for _, e := range order {
		out = append(out, *by[e])
	}
	sort.SliceStable(out, func(i, k int) bool { return len(out[i].Senders) > len(out[k].Senders) })
	return out
}

// raiseAck: receipts only ever move a message's ack up (WAWebAckMsgAction.updateMsgAck).
func (s *Store) raiseAck(account, remote string, ids []string, ack int) []Msg {
	changed := []Msg{}
	for _, id := range ids {
		m, _, ok := s.msgByID(account, remote, id)
		if ok && m.FromMe && ack > m.Ack {
			m.Ack = ack
			s.updateMsg(m)
			changed = append(changed, m)
		}
	}
	return changed
}

// ---- chats ---------------------------------------------------------------------------------------

const chatCols = `id, name, t, unreadCount, unreadMentionCount, markedUnread, archive, pin, muteExpiration,
	isReadOnly, isAnnounceGrpRestrict, ephemeralDuration, endOfHistoryTransferType, draftMessage, isParentGroup`

func (s *Store) chat(account, id string) (Chat, bool) {
	l := s.chatList(`account=? AND id=?`, account, id)
	if len(l) == 0 {
		return Chat{}, false
	}
	return l[0], true
}

func (s *Store) chats(account string) []Chat {
	return s.chatList(`account=? AND deleted=0 AND t>0 ORDER BY pin DESC, t DESC`, account)
}

func (s *Store) chatList(where string, args ...any) []Chat {
	out := []Chat{}
	rows, err := s.db.Query(`SELECT account, `+chatCols+` FROM chats WHERE `+where, args...)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var c Chat
		var mu, ar, ro, an, parent int
		rows.Scan(&c.Account, &c.ID, &c.Name, &c.T, &c.UnreadCount, &c.UnreadMentionCount, &mu, &ar, &c.Pin, &c.MuteExpiration,
			&ro, &an, &c.EphemeralDuration, &c.EndOfHistoryTransferType, &c.DraftMessage, &parent)
		c.MarkedUnread, c.Archive, c.IsReadOnly, c.IsAnnounceGrpRestrict = mu != 0, ar != 0, ro != 0, an != 0
		c.Kind = chatKind(c.ID, parent != 0)
		out = append(out, c)
	}
	return out
}

// ensureChat: the chat exists (a message to or from a new chat creates it).
func (s *Store) ensureChat(account, id string) {
	s.db.Exec(`INSERT INTO chats(account, id) VALUES(?,?) ON CONFLICT(account, id) DO NOTHING`, account, id)
}

// bumpChat: a message moved the chat: its time, and the unread count for an incoming message.
func (s *Store) bumpChat(m Msg, countUnread, mentionsMe bool) {
	s.ensureChat(m.Account, m.Remote)
	inc, men := 0, 0
	// a late message older than the phone's read mark is already read
	if countUnread && !m.FromMe && m.T > s.readAt(m.Account, m.Remote) {
		inc = 1
		if mentionsMe {
			men = 1
		}
	}
	s.db.Exec(`UPDATE chats SET t=MAX(t, ?), unreadCount=unreadCount+?, unreadMentionCount=unreadMentionCount+?, deleted=0
		WHERE account=? AND id=?`, m.T, inc, men, m.Account, m.Remote)
}

// setChat: one column (the app-state actions and group metadata write these).
func (s *Store) setChat(account, id, column string, value any) {
	switch column {
	case "name", "t", "unreadCount", "unreadMentionCount", "markedUnread", "archive", "pin", "muteExpiration",
		"isReadOnly", "isAnnounceGrpRestrict", "ephemeralDuration", "endOfHistoryTransferType", "draftMessage",
		"isParentGroup", "clearedAt", "deleted":
		s.ensureChat(account, id)
		s.db.Exec(`UPDATE chats SET `+column+`=? WHERE account=? AND id=?`, value, account, id)
	}
}

func (s *Store) setChatName(account, id, name string) {
	if name != "" {
		s.setChat(account, id, "name", name)
	}
}

// ---- contacts ------------------------------------------------------------------------------------

func (s *Store) contact(account, id string) Contact {
	c := Contact{ID: id, Account: account}
	var biz, blocked int
	s.db.QueryRow(`SELECT name, shortName, pushname, verifiedName, isBusiness, blocked, phoneNumber, status, pic FROM contacts WHERE account=? AND id=?`,
		account, id).Scan(&c.Name, &c.ShortName, &c.Pushname, &c.VerifiedName, &biz, &blocked, &c.PhoneNumber, &c.Status, &c.ProfilePicThumb)
	c.IsBusiness, c.IsContactBlocked = biz != 0, blocked != 0
	if c.PhoneNumber == "" && strings.HasSuffix(id, "@s.whatsapp.net") {
		c.PhoneNumber = strings.SplitN(id, "@", 2)[0]
	}
	c.FormattedName = formattedName(c)
	return c
}

// chatTitle: a 1:1 chat's title in the chat list — WhatsApp Web shows the address-book name, the
// verified business name, or else the number (not the push name, which goes beside the number).
func chatTitle(c Contact) string {
	switch {
	case c.Name != "":
		return c.Name
	case c.VerifiedName != "":
		return c.VerifiedName
	case c.Pushname != "": // not in the address book, but their name is nicer than a bare number
		return c.Pushname  // the UI marks it "[desconhecido]"; no "~" here
	case c.PhoneNumber != "":
		return formatPhone(c.PhoneNumber)
	}
	if strings.HasSuffix(c.ID, "@lid") { // a number-less id: not a phone number to show
		return "Contato do WhatsApp"
	}
	return strings.SplitN(c.ID, "@", 2)[0]
}

// formatPhone: "+55 11 98888-7777" for Brazil (country, area, number with the dash), "+<cc> <rest>"
// otherwise — how WhatsApp writes numbers it has no name for.
func formatPhone(n string) string {
	n = strings.TrimPrefix(n, "+")
	if strings.HasPrefix(n, "55") && (len(n) == 12 || len(n) == 13) {
		local := n[4:]
		cut := len(local) - 4
		return "+55 " + n[2:4] + " " + local[:cut] + "-" + local[cut:]
	}
	if strings.HasPrefix(n, "1") && len(n) == 11 {
		return "+1 " + n[1:4] + "-" + n[4:7] + "-" + n[7:]
	}
	return "+" + n
}

// oneLine: a preview is one line — line breaks and runs of spaces become one space. Markdown (as
// Meta AI writes it) reads as text: a table by its first row ("a · b"), headings without their #,
// no ** around bold.
func oneLine(s string) string {
	out := []string{}
	inTable := false
	for _, l := range strings.Split(s, "\n") {
		t := strings.TrimSpace(l)
		if len(t) > 1 && t[0] == '|' && t[len(t)-1] == '|' {
			if !inTable && strings.Trim(t, "|-: ") != "" {
				cells := strings.Split(t[1:len(t)-1], "|")
				for i := range cells {
					cells[i] = strings.TrimSpace(cells[i])
				}
				out = append(out, strings.Join(cells, " · "))
			}
			inTable = true
			continue
		}
		inTable = false
		if h := strings.TrimLeft(t, "#"); h != t && strings.HasPrefix(h, " ") {
			t = h
		}
		out = append(out, t)
	}
	return strings.Join(strings.Fields(strings.ReplaceAll(strings.Join(out, " "), "**", "")), " ")
}

// formattedName: WhatsApp Web's precedence — address book, verified business, ~push name, phone.
func formattedName(c Contact) string {
	switch {
	case c.Name != "":
		return c.Name
	case c.VerifiedName != "": // not in the address book: WhatsApp marks it, business or not
		return "~" + c.VerifiedName
	case c.Pushname != "":
		return "~" + c.Pushname
	case c.PhoneNumber != "":
		return formatPhone(c.PhoneNumber)
	}
	if strings.HasSuffix(c.ID, "@lid") {
		return "Contato do WhatsApp"
	}
	return strings.SplitN(c.ID, "@", 2)[0]
}

// setContact: one column (empty strings never erase what is known).
func (s *Store) setContact(account, id, column string, value any) {
	switch column {
	case "name", "shortName", "pushname", "verifiedName", "isBusiness", "blocked", "phoneNumber", "status", "pic":
		if v, ok := value.(string); ok && v == "" {
			return
		}
		s.db.Exec(`INSERT INTO contacts(account, id) VALUES(?,?) ON CONFLICT(account, id) DO NOTHING`, account, id)
		s.db.Exec(`UPDATE contacts SET `+column+`=? WHERE account=? AND id=?`, value, account, id)
	}
}

// ---- group metadata ------------------------------------------------------------------------------

func (s *Store) group(account, id string) (GroupMetadata, bool) {
	var j string
	if s.db.QueryRow(`SELECT json FROM groups WHERE account=? AND id=?`, account, id).Scan(&j) != nil {
		return GroupMetadata{}, false
	}
	var g GroupMetadata
	json.Unmarshal([]byte(j), &g)
	return g, true
}

func (s *Store) putGroup(g GroupMetadata) {
	j, _ := json.Marshal(g)
	s.db.Exec(`INSERT INTO groups(account, id, json) VALUES(?,?,?) ON CONFLICT(account, id) DO UPDATE SET json=excluded.json`, g.Account, g.ID, string(j))
	s.setChatName(g.Account, g.ID, g.Subject)
	s.setChat(g.Account, g.ID, "isAnnounceGrpRestrict", b2i(g.Announce))
	s.setChat(g.Account, g.ID, "ephemeralDuration", g.EphemeralDuration)
	s.setChat(g.Account, g.ID, "isParentGroup", b2i(g.IsParentGroup))
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (s *Store) statusSeen(account, key string) bool {
	var n int
	s.db.QueryRow(`SELECT count(*) FROM status_seen WHERE account=? AND key=?`, account, key).Scan(&n)
	return n > 0
}

// statusMuted: whether a contact's status updates are muted (WhatsApp's userStatusMute).
func (s *Store) statusMuted(account, id string) bool {
	var n int
	s.db.QueryRow(`SELECT count(*) FROM status_mute WHERE account=? AND id=?`, account, id).Scan(&n)
	return n > 0
}

func (s *Store) setStatusMuted(account, id string, muted bool) {
	if muted {
		s.db.Exec(`INSERT OR IGNORE INTO status_mute(account, id) VALUES(?, ?)`, account, id)
	} else {
		s.db.Exec(`DELETE FROM status_mute WHERE account=? AND id=?`, account, id)
	}
}

func (s *Store) markStatusSeen(account, key string) {
	s.db.Exec(`INSERT OR IGNORE INTO status_seen(account, key) VALUES(?, ?)`, account, key)
}

// setChatPin: the message pinned in a chat ("" unpins), until a time.
func (s *Store) setChatPin(account, chat, msg string, until int64) {
	if msg == "" {
		s.db.Exec(`DELETE FROM chat_pins WHERE account=? AND chat=?`, account, chat)
		return
	}
	s.db.Exec(`INSERT INTO chat_pins(account, chat, msg, until) VALUES(?,?,?,?)
		ON CONFLICT(account, chat) DO UPDATE SET msg=excluded.msg, until=excluded.until`, account, chat, msg, until)
}

func (s *Store) chatPin(account, chat string) (string, int64) {
	var msg string
	var until int64
	s.db.QueryRow(`SELECT msg, until FROM chat_pins WHERE account=? AND chat=?`, account, chat).Scan(&msg, &until)
	return msg, until
}
