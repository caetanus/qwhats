package main

// What the navigation rail's panels read (WhatsApp Web's Calls, Status, Channels, Communities,
// Media and profile tabs): views over our store, plus the server for channels and my profile.

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// msgsByType: the newest messages of some types across every chat (calls: call_log; media:
// image/video), with the chat's title handed out alongside.
func (a *Account) msgsByType(types []string, limit int) []Msg {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	q := `SELECT json FROM msgs WHERE account=? AND remote!='status@broadcast' AND type IN (` +
		strings.TrimSuffix(strings.Repeat("?,", len(types)), ",") + `) ORDER BY t DESC LIMIT ?`
	args := []any{a.ID}
	for _, t := range types {
		args = append(args, t)
	}
	args = append(args, limit)
	out := []Msg{}
	for _, m := range a.core.store.msgList(q, args...) {
		m = a.handOut(m)
		m.ChatName = a.chatName(m.Remote)
		out = append(out, m)
	}
	return out
}

// chatName: a chat's title as the chat list shows it.
func (a *Account) chatName(id string) string {
	if c, ok := a.core.store.chat(a.ID, id); ok {
		return a.fullChat(c).Name
	}
	return chatTitle(a.core.store.contact(a.ID, id))
}

// StatusAuthor: one contact's status updates of the last 24 h (WhatsApp Web's status list row).
type StatusAuthor struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	ProfilePicThumb string `json:"profilePicThumb,omitempty"`
	T               int64  `json:"t"`
	Items           []Msg  `json:"items"`
	IsMe            bool   `json:"isMe,omitempty"`
	Viewed          bool   `json:"viewed,omitempty"` // every update seen (WhatsApp Web's "Vistas")
	Muted           bool   `json:"muted,omitempty"`  // their updates muted ("Silenciados", at the end)
}

// statusList: the status updates (chat status@broadcast) of the last 24 hours, by author, newest
// author first; mine first of all.
func (a *Account) statusList() []StatusAuthor {
	since := time.Now().Add(-24 * time.Hour).Unix()
	msgs := a.core.store.msgList(`SELECT json FROM msgs WHERE account=? AND remote='status@broadcast' AND t>? AND type!='revoked' ORDER BY t ASC`, a.ID, since)
	by := map[string]*StatusAuthor{}
	order := []string{}
	for _, m := range msgs {
		if m.Author == "" && !m.FromMe { // stored before statuses kept their author: whose is unknown
			continue
		}
		who := m.Author
		if m.FromMe || who == "" {
			who = a.me()
		}
		s := by[who]
		if s == nil {
			k := a.core.store.contact(a.ID, who)
			name := k.FormattedName
			if name == "" {
				name = chatTitle(k)
			}
			s = &StatusAuthor{ID: who, Name: name, IsMe: a.isMe(who), Viewed: true, Muted: a.core.store.statusMuted(a.ID, who)}
			if s.IsMe {
				s.Name = "Meu status"
			}
			if k.ProfilePicThumb != "-" {
				s.ProfilePicThumb = k.ProfilePicThumb
			}
			by[who] = s
			order = append(order, who)
		}
		item := a.handOut(m)
		item.Viewed = s.IsMe || a.core.store.statusSeen(a.ID, m.ID)
		if !item.Viewed {
			s.Viewed = false
		}
		s.Items = append(s.Items, item)
		s.T = m.T
	}
	out := []StatusAuthor{}
	for _, id := range order {
		out = append(out, *by[id])
	}
	for i := 1; i < len(out); i++ { // newest first, mine on top
		// mine, then the unseen ("Recentes"), then the seen ("Vistas"), then the muted ("Silenciados");
		// newest first within each
		rank := func(s StatusAuthor) int {
			if s.IsMe {
				return 0
			}
			if s.Muted {
				return 3
			}
			if !s.Viewed {
				return 1
			}
			return 2
		}
		for k := i; k > 0 && (rank(out[k]) < rank(out[k-1]) || (rank(out[k]) == rank(out[k-1]) && out[k].T > out[k-1].T)); k-- {
			out[k], out[k-1] = out[k-1], out[k]
		}
	}
	return out
}

// Channel: a followed newsletter (WhatsApp Web's Channels tab).
type Channel struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Subscribers int    `json:"subscribers"`
	Verified    bool   `json:"verified"`
	Invite      string `json:"invite,omitempty"`
	Pic         string `json:"pic,omitempty"`
}

func (a *Account) channels() ([]Channel, error) {
	list, err := a.client.GetSubscribedNewsletters(ctx)
	if err != nil {
		return nil, err
	}
	out := []Channel{}
	for _, n := range list {
		// the followed list often comes without the follower count or the picture: the channel's
		// own metadata has them (WAWebNewsletterMetadataQuery)
		if n.ThreadMeta.SubscriberCount == 0 || (n.ThreadMeta.Preview.URL == "" && n.ThreadMeta.Preview.DirectPath == "") {
			if full, err := a.client.GetNewsletterInfo(ctx, n.ID); err == nil && full != nil {
				if full.ThreadMeta.SubscriberCount > 0 {
					n.ThreadMeta.SubscriberCount = full.ThreadMeta.SubscriberCount
				}
				if full.ThreadMeta.Preview.URL != "" || full.ThreadMeta.Preview.DirectPath != "" {
					n.ThreadMeta.Preview = full.ThreadMeta.Preview
				}
			}
		}
		ch := Channel{ID: n.ID.String(), Name: n.ThreadMeta.Name.Text, Description: n.ThreadMeta.Description.Text,
			Subscribers: n.ThreadMeta.SubscriberCount, Verified: n.ThreadMeta.VerificationState == "verified", Invite: n.ThreadMeta.InviteCode}
		out = append(out, ch)
		// kept like group metadata: the chat's title, description, followers; and its picture
		a.core.store.putGroup(GroupMetadata{ID: ch.ID, Account: a.ID, Subject: ch.Name, Desc: ch.Description, Size: ch.Subscribers, Participants: []Participant{}})
		if pic, have := n.ThreadMeta.Preview, a.core.store.contact(a.ID, ch.ID).ProfilePicThumb; (have == "" || have == "-") && (pic.URL != "" || pic.DirectPath != "") {
			url := pic.URL
			if url == "" {
				url = "https://mmg.whatsapp.net" + pic.DirectPath
			}
			if data, err := httpGet(url); err == nil {
				dir := filepath.Join(a.core.cacheDir, "pics")
				os.MkdirAll(dir, 0o700)
				p := filepath.Join(dir, strings.NewReplacer("@", "_").Replace(ch.ID)+"-"+pic.ID+".jpg")
				if os.WriteFile(p, data, 0o600) == nil {
					a.core.store.setContact(a.ID, ch.ID, "pic", p)
				}
			}
		}
		if pic := a.core.store.contact(a.ID, ch.ID).ProfilePicThumb; pic != "-" {
			out[len(out)-1].Pic = pic
		}
		a.emitChat(ch.ID)
	}
	return out, nil
}

// refreshChannel: a channel's latest messages from its server — with the reaction, forward and view
// counts WhatsApp shows under them; messages we did not have are stored (the phone does not relay
// channel updates to linked devices: WhatsApp Web shows "não é possível carregá-la" for them).
func (a *Account) refreshChannel(id string) ([]Msg, error) {
	j, err := parseJID(id)
	if err != nil {
		return nil, err
	}
	list, err := a.client.GetNewsletterMessages(ctx, j, &whatsmeow.GetNewsletterMessagesParams{Count: 50})
	if err != nil {
		return nil, err
	}
	s := a.core.store
	for _, nm := range list {
		m, _, ok := s.msgByID(a.ID, id, nm.MessageID)
		if !ok && nm.Message != nil {
			n, isMsg := content(nm.Message)
			if !isMsg {
				continue
			}
			info := types.MessageInfo{ID: nm.MessageID, Timestamp: nm.Timestamp, MessageSource: types.MessageSource{Chat: j, Sender: j}}
			envelope(&n, a.ID, info, id, "")
			raw, _ := proto.Marshal(nm.Message)
			s.putMsg(n, raw)
			s.bumpChat(n, false, false)
			m, ok = n, true
		}
		if !ok {
			continue
		}
		m.NewsletterReactions = nil
		for e, c := range nm.ReactionCounts {
			if c > 0 {
				m.NewsletterReactions = append(m.NewsletterReactions, NewsletterReaction{Emoji: e, Count: c})
			}
		}
		sort.Slice(m.NewsletterReactions, func(i, k int) bool { return m.NewsletterReactions[i].Count > m.NewsletterReactions[k].Count })
		m.ForwardsCount, m.ViewsCount = nm.ForwardsCount, nm.ViewsCount
		s.updateMsg(m)
	}
	out := []Msg{}
	for _, m := range s.msgs(a.ID, id, 0, 80) {
		out = append(out, a.handOut(m))
	}
	a.emitChat(id)
	return out, nil
}

// Community: a parent group and its linked groups we know of.
type Community struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Pic    string `json:"pic,omitempty"`
	Groups []Chat `json:"groups"`
}

func (a *Account) communities() []Community {
	out := []Community{}
	index := map[string]int{}
	for _, c := range a.core.store.chats(a.ID) {
		if c.Kind == "community" {
			index[c.ID] = len(out)
			out = append(out, Community{ID: c.ID, Name: a.fullChat(c).Name, Groups: []Chat{}})
		}
	}
	for _, c := range a.core.store.chats(a.ID) {
		if c.Kind != "group" {
			continue
		}
		if g, ok := a.core.store.group(a.ID, c.ID); ok && g.ParentGroup != "" {
			i, ok := index[g.ParentGroup]
			if !ok { // a community known only through its groups: its name from its own metadata
				name := ""
				if pg, found := a.core.store.group(a.ID, g.ParentGroup); found && pg.Subject != "" {
					name = pg.Subject
				} else if a.client != nil {
					if pg, err := a.sendQueryGroup(g.ParentGroup); err == nil {
						name = pg.Subject
					}
				}
				if name == "" {
					name = "Comunidade"
				}
				i = len(out)
				index[g.ParentGroup] = i
				out = append(out, Community{ID: g.ParentGroup, Name: name, Groups: []Chat{}})
			}
			out[i].Groups = append(out[i].Groups, a.fullChat(c))
		}
	}
	for i := range out {
		if p := a.core.store.contact(a.ID, out[i].ID).ProfilePicThumb; p != "" && p != "-" {
			out[i].Pic = p
		}
	}
	return out
}

// Profile: my own (WhatsApp Web's profile drawer).
type Profile struct {
	ID              string `json:"id"`
	Pushname        string `json:"pushname"`
	Status          string `json:"status,omitempty"`
	PhoneNumber     string `json:"phoneNumber"`
	ProfilePicThumb string `json:"profilePicThumb,omitempty"`
}

func (a *Account) profile() Profile {
	me := a.me()
	p := Profile{ID: me, PhoneNumber: formatPhone(strings.SplitN(me, "@", 2)[0])}
	if a.client != nil {
		p.Pushname = a.client.Store.PushName
		if c, err := a.getStatus(me); err == nil {
			p.Status = c.Status
		}
		if c, err := a.requestProfilePicFromServer(me); err == nil && c.ProfilePicThumb != "-" {
			p.ProfilePicThumb = c.ProfilePicThumb
		}
	} else {
		p.Pushname, p.Status = "Você (demo)", "Disponível"
	}
	return p
}

// sendStatusSeen (WAWebStatusSeen): the author's read receipt for one status update.
func (a *Account) sendStatusSeen(key string) error {
	m, _, ok := a.core.store.msg(a.ID, key)
	if !ok {
		return errors.New("unknown status")
	}
	a.core.store.markStatusSeen(a.ID, key)
	if a.client == nil || a.core.demo {
		return nil
	}
	author, err := parseJID(m.Author)
	if err != nil {
		return err
	}
	return a.client.MarkRead(ctx, []types.MessageID{m.MsgID}, time.Now(), types.StatusBroadcastJID, author)
}
