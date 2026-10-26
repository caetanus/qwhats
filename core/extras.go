package main

// WhatsApp Web's chat-list menu (WAWebChatListHeaderMenu): new chat and new group, starred
// messages, and the app lock — plus the contact list the new-chat panel shows.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"golang.org/x/crypto/scrypt"
)

// starredMsgs: the starred messages, newest first (WAWebStarredMsgsCollection).
func (a *Account) starredMsgs(limit int) []Msg {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	out := []Msg{}
	for _, m := range a.core.store.msgList(`SELECT json FROM msgs WHERE account=? AND star=1 ORDER BY t DESC LIMIT ?`, a.ID, limit) {
		m = a.handOut(m)
		m.ChatName = a.chatName(m.Remote)
		out = append(out, m)
	}
	return out
}

// contactList: the address book's WhatsApp contacts, by name (the new-chat panel's "Contatos").
func (a *Account) contactList() []Contact {
	rows, err := a.core.store.db.Query(`SELECT id FROM contacts WHERE account=? AND name!='' AND id LIKE '%@s.whatsapp.net'`, a.ID)
	if err != nil {
		return []Contact{}
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	out := []Contact{}
	for _, id := range ids {
		if id == a.me() {
			continue
		}
		out = append(out, a.core.store.contact(a.ID, id))
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// openChat: a chat for this id even before it has messages (a new conversation from the panel).
func (a *Account) openChat(id string) Chat {
	a.core.store.ensureChat(a.ID, id)
	c, _ := a.core.store.chat(a.ID, id)
	full := a.fullChat(c)
	a.core.emit("Chat:change", full)
	return full
}

// createGroup (WAWebCreateGroupAction): the group, then its chat.
func (a *Account) createGroup(name string, participants []string) (Chat, error) {
	if strings.TrimSpace(name) == "" || len(participants) == 0 {
		return Chat{}, errors.New("a group needs a name and participants")
	}
	var jids []types.JID
	for _, p := range participants {
		j, err := parseJID(p)
		if err != nil {
			return Chat{}, err
		}
		jids = append(jids, j)
	}
	info, err := a.client.CreateGroup(ctx, whatsmeow.ReqCreateGroup{Name: name, Participants: jids})
	if err != nil {
		return Chat{}, err
	}
	id := info.JID.String()
	g := a.groupFrom(info)
	a.core.store.putGroup(g)
	a.core.emit("GroupMetadata:change", g)
	a.core.store.setChatName(a.ID, id, name)
	return a.openChat(id), nil
}

// ---- the app lock (WhatsApp Web's "Bloqueio do app"): a password, kept as an scrypt hash ----------

type appLock struct {
	Salt string `json:"salt"`
	Hash string `json:"hash"`
}

func (c *Core) lockFile() string { return filepath.Join(c.dataDir, "applock.json") }

func lockHash(password string, salt []byte) []byte {
	h, _ := scrypt.Key([]byte(password), salt, 1<<15, 8, 1, 32)
	return h
}

func (c *Core) lockStatus() bool {
	_, err := os.Stat(c.lockFile())
	return err == nil
}

func (c *Core) lockSet(password string) error {
	if len(password) < 4 {
		return errors.New("a senha precisa ter pelo menos 4 caracteres")
	}
	salt := make([]byte, 16)
	rand.Read(salt)
	b, _ := json.Marshal(appLock{Salt: hex.EncodeToString(salt), Hash: hex.EncodeToString(lockHash(password, salt))})
	return os.WriteFile(c.lockFile(), b, 0o600)
}

func (c *Core) lockCheck(password string) bool {
	b, err := os.ReadFile(c.lockFile())
	if err != nil {
		return true // no lock
	}
	var l appLock
	if json.Unmarshal(b, &l) != nil {
		return false
	}
	salt, _ := hex.DecodeString(l.Salt)
	want, _ := hex.DecodeString(l.Hash)
	return subtle.ConstantTimeCompare(lockHash(password, salt), want) == 1
}

func (c *Core) lockClear(password string) error {
	if !c.lockCheck(password) {
		return errors.New("senha incorreta")
	}
	return os.Remove(c.lockFile())
}

// linkMsgs: the messages that carry a link, newest first (the media panel's "Links" tab).
func (a *Account) linkMsgs(limit int) []Msg {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	out := []Msg{}
	for _, m := range a.core.store.msgList(`SELECT json FROM msgs WHERE account=? AND remote!='status@broadcast' AND type='chat' AND (json LIKE '%"matchedText"%' OR json LIKE '%http://%' OR json LIKE '%https://%') ORDER BY t DESC LIMIT ?`, a.ID, limit) {
		m = a.handOut(m)
		m.ChatName = a.chatName(m.Remote)
		out = append(out, m)
	}
	return out
}

// syncGroups (WhatsApp Web asks the same on connect): the groups we are in, with their current
// names and members. A chat for a group not on the list is one we left: it stays, read-only.
func (a *Account) syncGroups() {
	list, err := a.client.GetJoinedGroups(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: joined groups:", err)
		return
	}
	in := map[string]bool{}
	for _, gi := range list {
		g := a.groupFrom(gi)
		in[g.ID] = true
		a.core.store.putGroup(g)
		a.core.store.ensureChat(a.ID, g.ID)
		if g.Subject != "" {
			a.core.store.setChatName(a.ID, g.ID, g.Subject)
		}
		a.core.store.setChat(a.ID, g.ID, "isReadOnly", 0)
		a.emitChat(g.ID)
	}
	for _, c := range a.core.store.chats(a.ID) {
		if c.Kind == "group" && !in[c.ID] {
			a.core.store.setChat(a.ID, c.ID, "isReadOnly", 1)
			a.emitChat(c.ID)
		}
	}
	fmt.Fprintln(os.Stderr, "qwhats-core: groups joined:", len(list))
}

// sendPinInChat (WAWebPinMsgAction): a message pinned for everyone in the chat for a while
// (24 h, 7 or 30 days), or unpinned.
func (a *Account) sendPinInChat(key string, pin bool, seconds int) error {
	t, err := a.target(key)
	if err != nil {
		return err
	}
	if seconds <= 0 {
		seconds = 7 * 86400
	}
	typ := waE2E.PinInChatMessage_PIN_FOR_ALL
	if !pin {
		typ = waE2E.PinInChatMessage_UNPIN_FOR_ALL
	}
	if a.client != nil && !a.core.demo {
		msg := &waE2E.Message{
			PinInChatMessage: &waE2E.PinInChatMessage{
				Key:               a.client.BuildMessageKey(t.chat, t.sender, t.m.MsgID),
				Type:              typ.Enum(),
				SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
			},
			MessageContextInfo: &waE2E.MessageContextInfo{MessageAddOnDurationInSecs: proto.Uint32(uint32(seconds))},
		}
		if _, err := a.client.SendMessage(ctx, t.chat, msg); err != nil {
			return err
		}
	}
	if pin {
		a.core.store.setChatPin(a.ID, t.m.Remote, t.m.ID, time.Now().Unix()+int64(seconds))
	} else {
		a.core.store.setChatPin(a.ID, t.m.Remote, "", 0)
	}
	a.emitChat(t.m.Remote)
	return nil
}

// requestStatusHistory: the statuses posted before this device was linked (or missed while it was
// off), asked of the phone as an on-demand history of status@broadcast, anchored on the oldest
// status we have from someone. Once a session.
func (a *Account) requestStatusHistory() {
	since := time.Now().Add(-24 * time.Hour).Unix()
	l := a.core.store.msgList(`SELECT json FROM msgs WHERE account=? AND remote='status@broadcast' AND t>? AND IFNULL(json_extract(json,'$.author'),'')!='' ORDER BY t ASC LIMIT 1`, a.ID, since)
	if len(l) == 0 {
		return
	}
	t, err := a.target(l[0].ID)
	if err != nil {
		return
	}
	info := &types.MessageInfo{ID: l[0].MsgID, Timestamp: time.Unix(l[0].T, 0),
		MessageSource: types.MessageSource{Chat: types.StatusBroadcastJID, Sender: t.sender, IsFromMe: l[0].FromMe, IsGroup: false}}
	if _, err := a.client.SendPeerMessage(ctx, a.client.BuildHistorySyncRequest(info, 100)); err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: status history:", err)
	}
}

// saveMedia: a message's file (a status update, a photo…) copied into a folder, under a readable
// name ("WhatsApp Status 2026-10-21 18.19.jpg"). Downloads it first if needed.
func (a *Account) saveMedia(key, dir string) (P, error) {
	var m Msg
	if a.core.demo { // the demo's files are on disk already
		if _, err := a.core.demoDownload(a, key); err != nil {
			return nil, err
		}
		t, err := a.target(key)
		if err != nil {
			return nil, err
		}
		m = t.m
	} else {
		var err error
		if m, err = a.downloadMedia(key); err != nil {
			return nil, err
		}
	}
	if m.MediaData == nil || m.MediaData.RenderableURL == "" {
		return nil, errors.New("o arquivo ainda não está disponível")
	}
	src := m.MediaData.RenderableURL
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, "Downloads")
	}
	os.MkdirAll(dir, 0o755)
	kind := "WhatsApp"
	if m.Remote == "status@broadcast" {
		kind = "WhatsApp Status"
	}
	base := kind + " " + time.Unix(m.T, 0).Format("2006-01-02 15.04.05")
	ext := filepath.Ext(src)
	dst := filepath.Join(dir, base+ext)
	for i := 2; ; i++ {
		if _, err := os.Stat(dst); os.IsNotExist(err) {
			break
		}
		dst = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", base, i, ext))
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return nil, err
	}
	return P{"path": dst}, nil
}
