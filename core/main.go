// qwhats-core: WhatsApp for QWhats native (docs/native-client.md). It speaks WhatsApp Web's own
// internal API — its models and its actions, as mapped from its JavaScript — as JSON-RPC 2.0 on
// stdio, one object per line: requests from the app on stdin, responses and collection events
// (notifications, no "id") on stdout. Diagnostics go to stderr. The app owns this process: when
// stdin closes, it exits.
//
//	qwhats-core --data ~/.local/share/qml-whats/native --cache ~/.cache/qml-whats/native
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

type Core struct {
	dataDir, cacheDir string
	store             *Store
	out               *json.Encoder
	outMu             sync.Mutex
	accMu             sync.Mutex
	accounts          map[string]*Account
	demo              bool
}

type request struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type P map[string]any

func (c *Core) write(v any) {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	c.out.Encode(v) // Encode ends with '\n': one object per line
}

func (c *Core) emit(method string, params any) {
	c.write(P{"jsonrpc": "2.0", "method": method, "params": params})
}

func (c *Core) reply(id json.RawMessage, result any, err error) {
	if id == nil {
		return // a notification from the app: no answer
	}
	if err != nil {
		c.write(P{"jsonrpc": "2.0", "id": id, "error": P{"code": -32000, "message": err.Error()}})
		return
	}
	c.write(P{"jsonrpc": "2.0", "id": id, "result": result})
}

func (c *Core) account(id string) (*Account, error) {
	if id == "" {
		id = "main"
	}
	c.accMu.Lock()
	defer c.accMu.Unlock()
	if a, ok := c.accounts[id]; ok {
		return a, nil
	}
	if c.demo {
		a := &Account{ID: id, core: c, state: "CONNECTED", presence: map[string]*Presence{}, stateAt: map[string]int{}}
		c.accounts[id] = a
		return a, nil
	}
	a, err := c.openAccount(id)
	if err != nil {
		return nil, err
	}
	c.accounts[id] = a
	return a, nil
}

// The accounts on disk (a directory per account under data/accounts).
func (c *Core) accountIDs() []string {
	if c.demo {
		return []string{"main"}
	}
	entries, _ := os.ReadDir(filepath.Join(c.dataDir, "accounts"))
	ids := []string{}
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	sort.Strings(ids)
	return ids
}

// params: every method's arguments (WhatsApp Web's names).
type params struct {
	Account          string   `json:"account"`
	ID               string   `json:"id"`
	Chat             string   `json:"chat"`
	Msg              string   `json:"msg"`
	Msgs             []string `json:"msgs"`
	Chats            []string `json:"chats"`
	Types            []string `json:"types"`
	Text             string   `json:"text"`
	QuotedMsg        string   `json:"quotedMsg"`
	MentionedJidList []string `json:"mentionedJidList"`
	ReactionText     string   `json:"reactionText"`
	Path             string   `json:"path"`
	Caption          string   `json:"caption"`
	AsPtt            bool     `json:"asPtt"`
	AsDocument       bool     `json:"asDocument"`
	Star             bool     `json:"star"`
	Archive          bool     `json:"archive"`
	Muted            bool     `json:"muted"`
	Pin              bool     `json:"pin"`
	Expiration       int64    `json:"expiration"`
	KeepStarred      bool     `json:"keepStarred"`
	DeleteMedia      bool     `json:"deleteMedia"`
	Duration         int      `json:"duration"`
	Seconds          int      `json:"seconds"`
	Draft            string   `json:"draft"`
	From             string   `json:"from"`
	Phone            string   `json:"phone"`
	Query            string   `json:"query"`
	Before           int64    `json:"before"`
	Limit            int      `json:"limit"`
	Name             string   `json:"name"`
	Participants     []string `json:"participants"`
	Password         string   `json:"password"`
	Send             bool     `json:"send"`
	Denoise          bool     `json:"denoise"`
	DenoiseModel     string   `json:"denoiseModel"`
}

func (c *Core) handle(r request) (any, error) {
	var p params
	if len(r.Params) > 0 {
		if err := json.Unmarshal(r.Params, &p); err != nil {
			return nil, fmt.Errorf("params: %w", err)
		}
	}
	if r.Method == "ping" {
		return "pong", nil
	}
	if r.Method == "account.list" {
		return c.accountList(), nil
	}
	a, err := c.account(p.Account)
	if err != nil {
		return nil, err
	}
	s := c.store
	ok := func(err error) (any, error) { return err == nil, err }
	need := func(v ...string) error {
		for _, x := range v {
			if x == "" {
				return errors.New("missing parameter")
			}
		}
		return nil
	}

	// collections: the same for a real account and the demo
	switch r.Method {
	case "getState":
		return P{"state": a.state}, nil
	case "Chat.list":
		out := []Chat{}
		for _, ch := range s.chats(a.ID) {
			if c := a.fullChat(ch); a.listed(c) {
				out = append(out, c)
			}
		}
		return out, nil
	case "Chat.get":
		ch, found := s.chat(a.ID, p.ID)
		if !found {
			return nil, fmt.Errorf("no chat %s", p.ID)
		}
		return a.fullChat(ch), nil
	case "Msg.list":
		out := []Msg{}
		for _, m := range s.msgs(a.ID, p.Chat, p.Before, p.Limit) {
			out = append(out, a.handOut(m))
		}
		return out, nil
	case "Msg.search":
		out := []Msg{}
		for _, m := range s.search(a.ID, p.Query, p.Chat, p.Limit) {
			out = append(out, a.handOut(m))
		}
		return out, nil
	case "Contact.get":
		return s.contact(a.ID, p.ID), nil
	case "GroupMetadata.get":
		g, found := s.group(a.ID, p.ID)
		if !found && !c.demo {
			var err error
			if g, err = a.sendQueryGroup(p.ID); err != nil {
				return nil, err
			}
		}
		if !found && c.demo {
			g = GroupMetadata{ID: p.ID, Account: a.ID, Participants: []Participant{}}
		}
		return a.namedGroup(g), nil
	case "Msg.byType":
		return a.msgsByType(p.Types, p.Limit), nil
	case "Status.list":
		return a.statusList(), nil
	case "Community.list":
		return a.communities(), nil
	case "Profile.get":
		return a.profile(), nil
	case "Msg.starred":
		return a.starredMsgs(p.Limit), nil
	case "saveMedia":
		return a.saveMedia(p.Msg, p.Path)
	case "sendStatusSeen":
		return ok(a.sendStatusSeen(p.Msg))
	case "Sticker.list":
		return a.stickerList(p.Limit), nil
	case "sendPinInChat":
		return ok(a.sendPinInChat(p.Msg, p.Pin, p.Seconds))
	case "Msg.links":
		return a.linkMsgs(p.Limit), nil
	case "Contact.list":
		return a.contactList(), nil
	case "openChat":
		if err := need(p.ID); err != nil {
			return nil, err
		}
		return a.openChat(p.ID), nil
	case "startRecording":
		return c.startRecording(p.Denoise, p.DenoiseModel)
	case "stopRecording":
		return c.stopRecording(p.Send)
	case "AppLock.status":
		return P{"enabled": c.lockStatus()}, nil
	case "AppLock.set":
		return ok(c.lockSet(p.Password))
	case "AppLock.check":
		return P{"ok": c.lockCheck(p.Password)}, nil
	case "AppLock.clear":
		return ok(c.lockClear(p.Password))
	case "updateDraftMessageChat":
		s.setChat(a.ID, p.Chat, "draftMessage", p.Draft)
		return true, nil
	}

	if c.demo {
		return c.demoAction(a, r.Method, p)
	}

	switch r.Method {
	case "sendStatusMute":
		return ok(a.sendStatusMute(p.ID, p.Muted))
	case "connect":
		err := a.connect()
		return P{"state": a.state}, err
	case "pairPhone":
		code, err := a.pairPhone(p.Phone)
		return P{"code": code}, err
	case "logout":
		return ok(a.client.Logout(ctx))

	case "sendTextMsgToChat":
		if err := need(p.Chat, p.Text); err != nil {
			return nil, err
		}
		m, err := a.sendTextMsgToChat(p.Chat, p.Text, p.QuotedMsg, p.MentionedJidList)
		return a.handOut(m), err
	case "sendMediaMsgToChat":
		if err := need(p.Chat, p.Path); err != nil {
			return nil, err
		}
		m, err := a.sendMediaMsgToChat(p.Chat, p.Path, p.Caption, p.QuotedMsg, p.AsPtt, p.AsDocument, p.Seconds)
		return a.handOut(m), err
	case "sendReactionToMsg":
		return ok(a.sendReactionToMsg(p.Msg, p.ReactionText))
	case "sendRevoke":
		return ok(a.sendRevoke(p.Msgs))
	case "sendDeleteMsgs":
		return ok(a.sendDeleteMsgs(p.Msgs, p.DeleteMedia))
	case "editMessage":
		return ok(a.editMessage(p.Msg, p.Text))
	case "sendStarMsgs":
		return ok(a.sendStarMsgs(p.Msgs, p.Star))
	case "forwardMessages":
		ms, err := a.forwardMessages(p.Msgs, p.Chats)
		out := []Msg{}
		for _, m := range ms {
			out = append(out, a.handOut(m))
		}
		return out, err
	case "setArchive":
		return ok(a.setArchive(p.Chat, p.Archive))
	case "setPin":
		return ok(a.setPin(p.Chat, p.Pin))
	case "sendConversationMute":
		return ok(a.sendConversationMute(p.Chat, p.Expiration))
	case "sendClear":
		return ok(a.sendClear(p.Chat, p.KeepStarred))
	case "sendDelete":
		return ok(a.sendDelete(p.Chat))
	case "sendSeen":
		return ok(a.sendSeen(p.Chat))
	case "markUnread":
		return ok(a.markUnread(p.Chat))
	case "markComposing":
		return ok(a.chatState(p.Chat, "composing"))
	case "markRecording":
		return ok(a.chatState(p.Chat, "recording"))
	case "markPaused":
		return ok(a.chatState(p.Chat, "paused"))
	case "sendPresenceAvailable":
		return ok(a.client.SendPresence(ctx, "available"))
	case "sendPresenceUnavailable":
		return ok(a.client.SendPresence(ctx, "unavailable"))
	case "subscribeUserPresence":
		j, err := parseJID(p.ID)
		if err != nil {
			return nil, err
		}
		return ok(a.client.SubscribePresence(ctx, j))
	case "changeEphemeralDuration":
		return ok(a.changeEphemeralDuration(p.Chat, p.Duration))
	case "markPlayed":
		return ok(a.markPlayed(p.Msg))
	case "loadEarlierMsgs":
		ms, err := a.loadEarlierMsgs(p.Chat, p.Before, max(p.Limit, 50))
		out := []Msg{}
		for _, m := range ms {
			out = append(out, a.handOut(m))
		}
		return out, err
	case "downloadMedia":
		return a.downloadMedia(p.Msg)
	case "fetchThumbnail":
		return a.fetchThumbnail(p.Msg)
	case "sendQueryGroup":
		return a.sendQueryGroup(p.ID)
	case "requestProfilePicFromServer":
		return a.requestProfilePicFromServer(p.ID)
	case "getStatus":
		return a.getStatus(p.ID)
	case "Channel.list":
		return a.channels()
	case "Newsletter.refresh":
		return a.refreshChannel(p.ID)
	case "profilePicFull":
		path, err := a.profilePicFull(p.ID)
		return P{"path": path}, err
	case "rejectCall":
		return ok(a.rejectCall(p.ID, p.From))
	case "createGroup":
		return a.createGroup(p.Name, p.Participants)
	case "Community.view":
		return a.communityView(p.ID)
	case "joinCommunityGroup":
		return a.joinCommunityGroup(p.ID, p.Chat)
	case "sendSticker":
		return a.sendSticker(p.Chat, p.Msg)
	}
	return nil, fmt.Errorf("method not found: %s", r.Method)
}

func (c *Core) accountList() []P {
	out := []P{}
	for _, id := range c.accountIDs() {
		a, err := c.account(id)
		if err != nil {
			continue
		}
		e := P{"id": id, "state": a.state, "me": a.me()}
		if a.client != nil {
			e["pushname"] = a.client.Store.PushName
		}
		out = append(out, e)
	}
	return out
}

func main() {
	home, _ := os.UserHomeDir()
	data := flag.String("data", filepath.Join(home, ".local/share/qml-whats/native"), "data directory")
	cache := flag.String("cache", filepath.Join(home, ".cache/qml-whats/native"), "media cache")
	demo := flag.Bool("demo", false, "a fake account with made-up chats, no network (UI development)")
	flag.Parse()
	os.MkdirAll(*data, 0o700)
	os.MkdirAll(*cache, 0o700)
	dbFile := filepath.Join(*data, "wa.db")
	if *demo {
		dbFile = filepath.Join(*data, "demo.db")
		os.Remove(dbFile)
		os.Remove(dbFile + "-wal")
		os.Remove(dbFile + "-shm")
	}
	st, err := openStore(dbFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: store:", err)
		os.Exit(1)
	}
	c := &Core{dataDir: *data, cacheDir: *cache, store: st, out: json.NewEncoder(softbankWriter{os.Stdout}), accounts: map[string]*Account{}}
	c.out.SetEscapeHTML(false)
	c.demo = *demo
	if c.demo {
		c.seedDemo()
	} else {
		useCurrentVersion(*data)
		// accounts that are paired connect at once (their messages flow in before the UI asks)
		for _, id := range c.accountIDs() {
			if a, err := c.account(id); err == nil && a.loggedIn() {
				go a.connect()
			}
		}
	}
	c.emit("ready", P{"accounts": c.accountList()})

	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 64<<20)
	for in.Scan() {
		var r request
		if err := json.Unmarshal(in.Bytes(), &r); err != nil {
			c.write(P{"jsonrpc": "2.0", "id": nil, "error": P{"code": -32700, "message": "parse error"}})
			continue
		}
		go func(r request) {
			res, err := c.handle(r)
			c.reply(r.ID, res, err)
		}(r)
	}
	// stdin closed: the app is gone
	c.accMu.Lock()
	for _, a := range c.accounts {
		if a.client != nil {
			a.client.Disconnect()
		}
	}
	c.accMu.Unlock()
}
