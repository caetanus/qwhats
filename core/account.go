package main

// One WhatsApp account = one whatsmeow client over its own device store (accounts/<id>/device.db).
// Every whatsmeow event becomes WhatsApp Web's model (normalize.go) and is written to our store
// first, then told to the app as a collection event (Msg:add, Msg:change, Chat:change, …): the
// app can always re-read the collections and find the same thing.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"google.golang.org/protobuf/reflect/protoreflect"
	"image/color"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type Account struct {
	ID     string
	dir    string
	client *whatsmeow.Client
	store  *sqlstore.Container
	core   *Core
	mu     sync.Mutex
	qrStop context.CancelFunc
	state  string

	presMu   sync.Mutex
	presence map[string]*Presence         // chat → presence (typing / recording participants)
	calls    map[string]*events.CallOffer // live calls, by call id
	bridge   *callBridge                  // the voip engine's helper (callbridge.go)
	accepted map[string]bool
	stateAt  map[string]int // chat|who → the last chat-state update (expiry)
	stateSeq int
}

func (c *Core) openAccount(id string) (*Account, error) {
	dir := filepath.Join(c.dataDir, "accounts", id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(dir, "device.db")+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	container := sqlstore.NewWithDB(db, "sqlite3", waLog.Noop)
	if err := container.Upgrade(context.Background()); err != nil {
		return nil, fmt.Errorf("device store: %w", err)
	}
	dev, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return nil, err
	}
	a := &Account{ID: id, dir: dir, core: c, store: container, state: "UNPAIRED", presence: map[string]*Presence{},
		calls: map[string]*events.CallOffer{}, accepted: map[string]bool{}, stateAt: map[string]int{}}
	if dev.ID != nil {
		a.state = "OPENING"
	}
	a.client = whatsmeow.NewClient(dev, waLog.Noop)
	asChrome(a.client)
	a.client.AddEventHandler(a.onEvent)
	return a, nil
}

// repair: the phone unlinked us. As WhatsApp Web, back to the QR: the old device's keys are
// dropped and a new device pairs.
func (a *Account) repair() {
	a.setState("UNPAIRED")
	old := a.client
	old.RemoveEventHandlers()
	old.Disconnect()
	if old.Store.ID != nil {
		old.Store.Delete(context.Background())
	}
	a.client = whatsmeow.NewClient(a.store.NewDevice(), waLog.Noop)
	asChrome(a.client)
	a.client.AddEventHandler(a.onEvent)
	if err := a.connect(); err != nil {
		a.core.emit("error", P{"account": a.ID, "message": err.Error()})
	}
}

func (a *Account) loggedIn() bool { return a.client.Store.ID != nil }

func (a *Account) me() string {
	if a.client == nil {
		return demoMe
	}
	if a.client.Store.ID == nil {
		return ""
	}
	return a.client.Store.ID.ToNonAD().String()
}

// namedGroup: group metadata as the info drawer reads it — participants with their display names,
// me first, then admins, then by name (as WhatsApp Web lists them).
func (a *Account) namedGroup(g GroupMetadata) GroupMetadata {
	ps := make([]Participant, 0, len(g.Participants))
	for _, p := range g.Participants {
		p.IsMe = a.isMe(p.ID)
		if p.IsMe {
			p.Name = "Você"
		} else {
			p.Name = a.core.store.contact(a.ID, p.ID).FormattedName
		}
		ps = append(ps, p)
	}
	sort.SliceStable(ps, func(i, k int) bool {
		if ps[i].IsMe != ps[k].IsMe {
			return ps[i].IsMe
		}
		if ps[i].IsAdmin != ps[k].IsAdmin {
			return ps[i].IsAdmin
		}
		return strings.ToLower(strings.TrimPrefix(ps[i].Name, "~")) < strings.ToLower(strings.TrimPrefix(ps[k].Name, "~"))
	})
	g.Participants = ps
	g.Size = len(ps)
	return g
}

// isMe: my phone-number id or my LID (WhatsApp addresses me by either).
func (a *Account) isMe(id string) bool {
	if id == a.me() {
		return true
	}
	if a.client != nil && !a.client.Store.LID.IsEmpty() && id == a.client.Store.LID.ToNonAD().String() {
		return true
	}
	return false
}

func mustJID(s string) types.JID {
	j, _ := types.ParseJID(s)
	return j
}

// setState: WhatsApp Web's socket states (Conn:change).
func (a *Account) setState(s string) {
	a.state = s
	a.core.emit("Conn:change", P{"account": a.ID, "state": s})
}

// connect: a paired account just connects; a new one starts the QR flow (codes as `qr` events).
func (a *Account) connect() error {
	if a.client.IsConnected() {
		return nil
	}
	if a.loggedIn() {
		a.setState("OPENING")
		return a.client.Connect()
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.mu.Lock()
	if a.qrStop != nil {
		a.qrStop()
	}
	a.qrStop = cancel
	a.mu.Unlock()
	ch, err := a.client.GetQRChannel(ctx)
	if err != nil {
		cancel()
		return err
	}
	if err := a.client.Connect(); err != nil {
		cancel()
		return err
	}
	a.setState("PAIRING")
	go func() {
		for item := range ch {
			switch item.Event {
			case "code":
				// the code as a PNG too (the UI shows an image); a new file per code, so an Image reloads
				old, _ := filepath.Glob(filepath.Join(a.core.cacheDir, "qr-"+a.ID+"-*.png"))
				for _, o := range old {
					os.Remove(o)
				}
				img := filepath.Join(a.core.cacheDir, "qr-"+a.ID+"-"+strconv.FormatInt(time.Now().UnixNano(), 36)+".png")
				// High error correction, as WhatsApp Web: the logo drawn over the middle does not stop a scan
				// as WhatsApp Web's canvas: no quiet zone, WhatsApp's dark teal on white (drawn at 2× its 228)
				q, qerr := qrcode.New(item.Code, qrcode.High)
				if qerr == nil {
					q.DisableBorder = true
					q.ForegroundColor = color.RGBA{0x12, 0x2e, 0x31, 0xff}
				}
				if qerr != nil || q.WriteFile(456, img) != nil {
					img = ""
				}
				a.core.emit("qr", P{"account": a.ID, "code": item.Code, "image": img, "timeout": int(item.Timeout.Seconds())})
			case "timeout":
				a.core.emit("qr", P{"account": a.ID, "code": "", "expired": true})
				a.setState("TIMEOUT")
			}
		}
	}()
	return nil
}

func (a *Account) pairPhone(phone string) (string, error) {
	if !a.client.IsConnected() {
		if err := a.connect(); err != nil {
			return "", err
		}
	}
	return a.client.PairPhone(context.Background(), phone, true, whatsmeow.PairClientChrome, chromeName)
}

// canonical: one chat per person — a @lid address becomes the phone-number one when known
// (WhatsApp moved 1:1 chats to LIDs; WhatsApp Web keeps the pair in lid-pn-mapping).
func (a *Account) canonical(j types.JID) types.JID {
	j = j.ToNonAD()
	if pn, ok := types.BotJIDMap[j]; ok { // Meta AI's bot id: its chat is its number
		return pn
	}
	if a.client != nil && j.Server == types.HiddenUserServer && a.client.Store.LIDs != nil {
		if pn, err := a.client.Store.LIDs.GetPNForLID(context.Background(), j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return j
}

// indexKey: the stored key of the message a star / deleteForMe action names (chat, id, fromMe and,
// for someone else's group message, the sender).
func (a *Account) indexKey(remote, msgID string, fromMe bool, sender types.JID) string {
	part := ""
	if !fromMe && !sender.IsEmpty() {
		part = a.canonical(sender).String()
	}
	return msgKey(fromMe, remote, msgID, part)
}

// findIndexed: that message — by its exact key, else the only one with that id whose direction
// (and, in a group, author) match.
func (a *Account) findIndexed(remote, msgID string, fromMe bool, sender types.JID, key string) (Msg, bool) {
	s := a.core.store
	if m, _, ok := s.msg(a.ID, key); ok {
		return m, true
	}
	m, _, ok := s.msgByID(a.ID, remote, msgID)
	if !ok || m.FromMe != fromMe {
		return Msg{}, false
	}
	if !fromMe && !sender.IsEmpty() && m.Author != "" && m.Author != a.canonical(sender).String() {
		return Msg{}, false
	}
	return m, true
}

// appStateSynced: whether an app-state collection was ever synced into whatsmeow's store.
func (a *Account) appStateSynced(name appstate.WAPatchName) bool {
	v, _, err := a.client.Store.AppState.GetAppStateVersion(context.Background(), string(name))
	return err == nil && v > 0
}

// fullAppStateOnce: one full app-state sync with its events applied (contacts' names from the
// phone's address book, pins, archives, mutes, read marks) — for accounts paired before we asked
// whatsmeow to emit them. Marked done in the account's folder.
func (a *Account) fullAppStateOnce() {
	// once per collection per pairing: each mark names the device it was done for (a new pairing
	// syncs again). A collection is done when it synced or when it does not verify (the phone is
	// then asked for a fresh copy, once); a transport error leaves it for the next connection.
	dev := ""
	if a.client.Store.ID != nil {
		dev = a.client.Store.ID.String()
	}
	done := func(file string) bool {
		b, err := os.ReadFile(filepath.Join(a.dir, file))
		return err == nil && strings.TrimSpace(string(b)) == dev
	}
	mark := func(file string) { os.WriteFile(filepath.Join(a.dir, file), []byte(dev+"\n"), 0o600) }
	for _, name := range appstate.AllPatchNames {
		fmark := "appstate-full-v2-" + string(name)
		if done(fmark) {
			continue
		}
		err := a.client.FetchAppState(context.Background(), name, true, false)
		if err == nil {
			mark(fmark)
			continue
		}
		fmt.Fprintln(os.Stderr, "qwhats-core: app state", name, err)
		// only a collection that does not verify (mismatching LTHash / patch MAC) is worth asking the
		// phone for a fresh copy of (as WhatsApp Web does) — and once per collection per pairing
		if !errors.Is(err, appstate.ErrMismatchingLTHash) && !errors.Is(err, appstate.ErrMismatchingPatchMAC) {
			continue
		}
		mark(fmark)
		rmark := "appstate-recovery-" + string(name)
		if done(rmark) {
			continue
		}
		mark(rmark)
		if _, err := a.client.SendPeerMessage(context.Background(), whatsmeow.BuildAppStateRecoveryRequest(name)); err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: app state recovery", name, err)
			// not sent: the next connection retries the collection and may ask again
			os.Remove(filepath.Join(a.dir, rmark))
			os.Remove(filepath.Join(a.dir, fmark))
		}
	}
	for _, c := range a.core.store.chats(a.ID) {
		a.emitChat(c.ID)
	}
}

// ---- events --------------------------------------------------------------------------------------

func (a *Account) onEvent(evt any) {
	s := a.core.store
	switch e := evt.(type) {
	case *events.Connected:
		a.setState("CONNECTED")
		a.client.SendPresence(context.Background(), types.PresenceAvailable)
		go func() {
			a.logCallProps() // the calling flags of this account (docs/calls-plan.md, phase 0)
			if a.bridge == nil {
				a.startCallBridge() // the voip engine's helper connects here (callbridge.go)
			}
			a.fullAppStateOnce()
			a.syncGroups()           // the groups we are in: names, members, and the ones we left
			a.requestStatusHistory() // statuses from before we were linked
			a.channels()             // the followed channels' names, pictures and followers
			a.fetchPictures()
			a.fetchBusinessNames()
			a.ensureBusinessChats() // verified businesses/bots always have a chat row, so they are listed
		}()
	case *events.Disconnected:
		if a.state != "UNPAIRED" && a.state != "CONFLICT" {
			a.setState("OPENING")
		}
	case *events.KeepAliveTimeout:
		a.setState("TIMEOUT")
	case *events.KeepAliveRestored:
		a.setState("CONNECTED")
	case *events.StreamReplaced:
		a.setState("CONFLICT")
	case *events.StreamError:
		if e.Code == "516" { // WhatsApp Web: 516 = this device was logged out
			go a.repair()
		}
	case *events.LoggedOut:
		go a.repair()
	case *events.PairSuccess:
		a.core.emit("paired", P{"account": a.ID, "id": e.ID.ToNonAD().String()})

	case *events.Message:
		if e.Info.Sender.IsBot() || e.Info.Chat.IsBot() { // Meta AI: what its answers look like (diagnostics)
			fields := []string{}
			e.Message.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
				fields = append(fields, string(fd.Name()))
				return true
			})
			fmt.Fprintln(os.Stderr, "qwhats-core: bot message", e.Info.Chat.Server, e.Info.MsgBotInfo.EditType, fields)
		}
		a.onMessage(e.Info, e.Message, e.RawMessage, false)
	case *events.UndecryptableMessage:
		if e.Info.Sender.IsBot() || e.Info.Chat.IsBot() {
			fmt.Fprintln(os.Stderr, "qwhats-core: bot message undecryptable", e.Info.Chat.Server, e.Info.MsgBotInfo.EditType, e.DecryptFailMode)
		}
		// WhatsApp Web's `ciphertext` row: "Aguardando mensagem…", replaced when the real one arrives
		if e.IsUnavailable && e.UnavailableType == events.UnavailableTypeViewOnce {
			return
		}
		m := Msg{Type: "ciphertext", Subtype: "fanout"}
		remote, author := a.canonical(e.Info.Chat).String(), a.canonical(e.Info.Sender).String()
		envelope(&m, a.ID, e.Info, remote, author)
		s.putMsg(m, nil)
		s.bumpChat(m, false, false)
		a.emitMsg("Msg:add", m)
		a.emitChat(remote)

	case *events.Receipt:
		ack := map[types.ReceiptType]int{
			types.ReceiptTypeDelivered: AckReceived, types.ReceiptTypeRead: AckRead, types.ReceiptTypeReadSelf: AckRead,
			types.ReceiptTypePlayed: AckPlayed, types.ReceiptTypePlayedSelf: AckPlayed, types.ReceiptTypeSender: AckReceived,
		}[e.Type]
		if ack == 0 {
			return
		}
		remote := a.canonical(e.Chat).String()
		if e.Type == types.ReceiptTypeReadSelf {
			// read on another of my devices: the chat is read here too
			s.setChat(a.ID, remote, "unreadCount", 0)
			s.setChat(a.ID, remote, "unreadMentionCount", 0)
			s.setChat(a.ID, remote, "markedUnread", 0)
			a.emitChat(remote)
			return
		}
		for _, m := range s.raiseAck(a.ID, remote, e.MessageIDs, ack) {
			a.emitMsg("Msg:change", m)
		}
		a.emitChat(remote)

	case *events.HistorySync:
		a.storeHistory(e.Data)

	case *events.PushName:
		id := a.canonical(e.JID).String()
		s.setContact(a.ID, id, "pushname", e.NewPushName)
		a.emitContact(id)
	case *events.Contact:
		id := a.canonical(e.JID).String()
		s.setContact(a.ID, id, "name", e.Action.GetFullName())
		s.setContact(a.ID, id, "shortName", e.Action.GetFirstName())
		a.emitContact(id)
	case *events.BusinessName:
		id := a.canonical(e.JID).String()
		s.setContact(a.ID, id, "verifiedName", e.NewBusinessName)
		s.setContact(a.ID, id, "isBusiness", 1)
		a.emitContact(id)
	case *events.UserAbout:
		id := a.canonical(e.JID).String()
		s.setContact(a.ID, id, "status", e.Status)
		a.emitContact(id)
	case *events.Picture:
		// the cached picture is stale: fetched again on the next request
		id := a.canonical(e.JID).String()
		s.db.Exec(`UPDATE contacts SET pic='' WHERE account=? AND id=?`, a.ID, id)
		a.emitContact(id)
	case *events.Blocklist:
		for _, ch := range e.Changes {
			id := a.canonical(ch.JID).String()
			s.setContact(a.ID, id, "blocked", b2i(ch.Action == events.BlocklistChangeActionBlock))
			a.emitContact(id)
		}

	// app state (the same patches WhatsApp Web's *Sync modules apply)
	case *events.Archive:
		id := a.canonical(e.JID).String()
		s.setChat(a.ID, id, "archive", b2i(e.Action.GetArchived()))
		a.emitChat(id)
	case *events.Pin:
		id := a.canonical(e.JID).String()
		pin := int64(0)
		if e.Action.GetPinned() {
			pin = e.Timestamp.Unix()
		}
		s.setChat(a.ID, id, "pin", pin)
		a.emitChat(id)
	case *events.UserStatusMute:
		// muted (or not) on another device
		id := a.canonical(e.JID).String()
		s.setStatusMuted(a.ID, id, e.Action.GetMuted())
		a.core.emit("Status:change", P{"account": a.ID, "id": id})
	case *events.Mute:
		id := a.canonical(e.JID).String()
		exp := int64(0)
		if e.Action.GetMuted() {
			exp = e.Action.GetMuteEndTimestamp() / 1000
			if exp <= 0 {
				exp = -1
			}
		}
		s.setChat(a.ID, id, "muteExpiration", exp)
		a.emitChat(id)
	case *events.MarkChatAsRead:
		id := a.canonical(e.JID).String()
		if e.Action.GetRead() {
			// read up to the range's last message (else the action's time)
			t := e.Action.GetMessageRange().GetLastMessageTimestamp()
			if t == 0 {
				t = e.Timestamp.Unix()
			}
			s.markRead(a.ID, id, t)
		} else {
			s.setChat(a.ID, id, "markedUnread", 1)
		}
		a.emitChat(id)
	case *events.Star:
		remote := a.canonical(e.ChatJID).String()
		key := a.indexKey(remote, e.MessageID, e.IsFromMe, e.SenderJID)
		s.setStarMark(a.ID, key, e.Action.GetStarred())
		if m, ok := a.findIndexed(remote, e.MessageID, e.IsFromMe, e.SenderJID, key); ok {
			m.Star = e.Action.GetStarred()
			s.updateMsg(m)
			a.emitMsg("Msg:change", m)
		}
	case *events.DeleteForMe:
		remote := a.canonical(e.ChatJID).String()
		key := a.indexKey(remote, e.MessageID, e.IsFromMe, e.SenderJID)
		s.setDeleteMark(a.ID, key)
		if m, ok := a.findIndexed(remote, e.MessageID, e.IsFromMe, e.SenderJID, key); ok {
			s.deleteMsg(a.ID, m.ID)
			a.core.emit("Msg:remove", P{"account": a.ID, "id": m.ID, "remote": remote})
			a.emitChat(remote)
		}
	case *events.ClearChat:
		remote := a.canonical(e.JID).String()
		t := e.Action.GetMessageRange().GetLastMessageTimestamp()
		if t == 0 {
			t = time.Now().Unix()
		}
		a.cleared(remote, t, true)
	case *events.DeleteChat:
		remote := a.canonical(e.JID).String()
		t := e.Action.GetMessageRange().GetLastMessageTimestamp()
		if t == 0 {
			t = time.Now().Unix()
		}
		a.cleared(remote, t, false)
		s.setChat(a.ID, remote, "deleted", 1)
		a.core.emit("Chat:remove", P{"account": a.ID, "id": remote})

	case *events.GroupInfo:
		a.onGroupInfo(e)
	case *events.JoinedGroup:
		g := a.groupFrom(&e.GroupInfo)
		s.putGroup(g)
		a.core.emit("GroupMetadata:change", g)
		a.emitChat(g.ID)

	case *events.ChatPresence:
		a.onChatPresence(e)
	case *events.Presence:
		id := a.canonical(e.From).String()
		p := a.presenceOf(id)
		a.presMu.Lock()
		p.IsOnline = !e.Unavailable
		if !e.LastSeen.IsZero() {
			p.T = e.LastSeen.Unix()
		}
		p.Deny = e.Unavailable && e.LastSeen.IsZero()
		cp := *p
		a.presMu.Unlock()
		a.core.emit("Presence:change", cp)

	case *events.IdentityChange:
		if !e.Implicit {
			id := a.canonical(e.JID).String()
			a.systemRow(id, "e2e_notification", "identity", []string{id}, e.Timestamp)
		}

	case *events.CallOffer:
		dumpCallNode("offer", e.Data)
		a.onCallOffer(e)
		a.forwardCallEvent(e)
	case *events.CallOfferNotice:
		dumpCallNode("offer_notice", e.Data)
	case *events.CallPreAccept:
		dumpCallNode("preaccept", e.Data)
		a.forwardCallEvent(e)
	case *events.CallTransport:
		dumpCallNode("transport", e.Data)
		a.forwardCallEvent(e)
	case *events.CallRelayLatency:
		dumpCallNode("relaylatency", e.Data)
		a.forwardCallEvent(e)
	case *events.CallReject:
		dumpCallNode("reject", e.Data)
		a.forwardCallEvent(e)
	case *events.UnknownCallEvent:
		dumpCallNode("unknown", e.Node)
	case *events.CallAccept:
		dumpCallNode("accept", e.Data)
		a.forwardCallEvent(e)
		a.presMu.Lock()
		a.accepted[e.CallID] = true
		a.presMu.Unlock()
	case *events.CallTerminate:
		dumpCallNode("terminate", e.Data)
		a.forwardCallEvent(e)
		a.callEnded(e.BasicCallMeta, e.Reason)

	case *events.MediaRetry:
		a.onMediaRetry(e)
	}
}

// onCallOffer: a call rings — kept, receipted, shown.
func (a *Account) onCallOffer(e *events.CallOffer) {
	a.presMu.Lock()
	a.calls[e.CallID] = e
	a.presMu.Unlock()
	a.offerReceipt(e.BasicCallMeta)
	a.core.emit("Call:offer", P{"account": a.ID, "id": e.CallID, "from": a.canonical(e.CallCreator).String(),
		"isVideo": isVideoOffer(e), "isGroup": !e.GroupJID.IsEmpty()})
}

// onMessage: a live message or one from history (history=true): a Msg, an add-on, or nothing.
func (a *Account) onMessage(info types.MessageInfo, m *waE2E.Message, raw *waE2E.Message, history bool) (Msg, bool) {
	s := a.core.store
	remote, author := a.canonical(info.Chat).String(), a.canonical(info.Sender).String()
	// a @lid the store cannot map yet: the message itself may carry the phone-number twin
	if strings.HasSuffix(author, "@lid") && !info.SenderAlt.IsEmpty() && info.SenderAlt.Server == types.DefaultUserServer {
		author = info.SenderAlt.ToNonAD().String()
	}
	if strings.HasSuffix(remote, "@lid") && !info.IsGroup {
		if !info.IsFromMe && strings.HasSuffix(author, "@s.whatsapp.net") {
			remote = author
		} else if !info.RecipientAlt.IsEmpty() && info.RecipientAlt.Server == types.DefaultUserServer {
			remote = info.RecipientAlt.ToNonAD().String()
		}
	}
	if info.PushName != "" && !info.IsFromMe {
		s.setContact(a.ID, author, "pushname", info.PushName)
	}
	// a business's messages carry its verified name (WhatsApp Web's verifiedName)
	if info.VerifiedName != nil && info.VerifiedName.Details != nil && !info.IsFromMe {
		if vn := info.VerifiedName.Details.GetVerifiedName(); vn != "" {
			s.setContact(a.ID, author, "verifiedName", vn)
			s.setContact(a.ID, author, "isBusiness", 1)
		}
	}
	// Meta AI answers in pieces: the first message, then edits of it until the last — the bubble's
	// text grows as they come
	if bi := info.MsgBotInfo; (bi.EditType == types.EditTypeInner || bi.EditType == types.EditTypeLast) && bi.EditTargetID != "" {
		if t, _, ok := s.msgByID(a.ID, remote, bi.EditTargetID); ok {
			// each piece is an edit (protocolMessage MESSAGE_EDIT) carrying the whole text so far
			em := m
			if pm := m.GetProtocolMessage(); pm != nil && pm.GetEditedMessage() != nil {
				em = pm.GetEditedMessage()
			}
			n, isMsg := content(em)
			fmt.Fprintln(os.Stderr, "qwhats-core: bot piece", bi.EditType, isMsg, len(n.Body))
			if isMsg && n.Body != "" {
				t.Body = n.Body
				s.updateMsg(t)
				a.emitMsg("Msg:change", a.handOut(t))
				a.emitChat(remote)
			}
			return Msg{}, false
		}
	}
	// a message pinned (or unpinned) in the chat: the chat's pinned bar, until it expires
	if pm := unwrapPin(m); pm != nil {
		// the pinned message, found by its id in this chat (its key is stored from our side)
		key := ""
		if t, _, ok := s.msgByID(a.ID, remote, pm.GetKey().GetID()); ok {
			key = t.ID
		}
		if pm.GetType() == waE2E.PinInChatMessage_PIN_FOR_ALL {
			secs := int64(m.GetMessageContextInfo().GetMessageAddOnDurationInSecs())
			if secs <= 0 {
				secs = 7 * 86400
			}
			if key != "" {
				s.setChatPin(a.ID, remote, key, info.Timestamp.Unix()+secs)
			}
		} else {
			s.setChatPin(a.ID, remote, "", 0)
		}
		a.emitChat(remote)
		return Msg{}, false
	}
	if ad, ok := addon(m); ok {
		ad.Sender, ad.FromMe = author, info.IsFromMe
		if ad.T == 0 {
			ad.T = info.Timestamp.Unix()
		}
		if p, ok := s.applyAddon(a.ID, remote, ad, a.me()); ok && !history {
			a.emitMsg("Msg:change", p)
			a.emitChat(remote)
		}
		return Msg{}, false
	}
	n, ok := content(m)
	if !ok {
		return Msg{}, false
	}
	envelope(&n, a.ID, info, remote, author)
	n.IsMdHistoryMsg = history
	if n.EphemeralDuration > 0 {
		n.ExpiredTimestamp = n.T + int64(n.EphemeralDuration)
	}
	if raw == nil {
		raw = m
	}
	b, _ := proto.Marshal(raw)
	if !s.applyMarks(&n) {
		return n, false // deleted for me (app-state) before it arrived
	}
	s.putMsg(n, b)
	if p, ok := s.adoptOrphans(n, a.me()); ok {
		n = p
	}
	if n.Type == "notification_template" && n.Subtype == "ephemeral_setting" {
		s.setChat(a.ID, remote, "ephemeralDuration", n.EphemeralDuration)
	}
	if history {
		return n, true
	}
	mentionsMe := false
	for _, j := range n.MentionedJidList {
		if j == a.me() {
			mentionsMe = true
		}
	}
	s.bumpChat(n, true, mentionsMe)
	a.emitMsg("Msg:add", n)
	if !n.FromMe {
		a.stopTyping(remote, author)
	}
	a.emitChat(remote)
	return n, true
}

// membershipNotice: the gp2 subtypes about who is in the group
var membershipNotice = map[string]bool{"add": true, "remove": true, "leave": true, "invite": true,
	"linked_group_join": true, "community_link": true, "member_add_mode": true}

// systemRow: a gp2 / e2e / call_log message made on our side, as WhatsApp Web makes them.
func (a *Account) systemRow(remote, typ, subtype string, params []string, at time.Time) {
	if at.IsZero() {
		at = time.Now()
	}
	id := fmt.Sprintf("%s-%d", subtype, at.UnixNano())
	m := Msg{ID: msgKey(false, remote, id, ""), Account: a.ID, Remote: remote, MsgID: id, From: remote, T: at.Unix(),
		Type: typ, Subtype: subtype, TemplateParams: params, Ack: AckReceived}
	if len(params) > 0 {
		m.Author = params[0]
	}
	a.core.store.putMsg(m, nil)
	// people joining and leaving don't move the chat in WhatsApp's list (its time and preview stay
	// the last real message): the notice is only in the conversation
	if !(typ == "gp2" && membershipNotice[subtype]) {
		a.core.store.bumpChat(m, false, false)
	}
	a.emitMsg("Msg:add", m)
	a.emitChat(remote)
}

// onGroupInfo: a group change becomes the stored metadata and WhatsApp Web's gp2 rows
// (templateParams: who did it, then whom or what).
func (a *Account) onGroupInfo(e *events.GroupInfo) {
	s := a.core.store
	id := e.JID.String()
	g, _ := s.group(a.ID, id)
	g.ID, g.Account = id, a.ID
	by := ""
	if e.Sender != nil {
		by = a.canonical(*e.Sender).String()
	}
	jids := func(l []types.JID) []string {
		out := []string{by}
		for _, j := range l {
			out = append(out, a.canonical(j).String())
		}
		return out
	}
	if e.Name != nil {
		g.Subject, g.SubjectTime = e.Name.Name, e.Name.NameSetAt.Unix()
		a.systemRow(id, "gp2", "subject", []string{by, e.Name.Name}, e.Timestamp)
	}
	if e.Topic != nil {
		g.Desc = e.Topic.Topic
		a.systemRow(id, "gp2", "description", []string{by}, e.Timestamp)
	}
	if e.Announce != nil {
		g.Announce = e.Announce.IsAnnounce
		a.systemRow(id, "gp2", "announce", []string{by, strconv.FormatBool(g.Announce)}, e.Timestamp)
	}
	if e.Locked != nil {
		g.Restrict = e.Locked.IsLocked
		a.systemRow(id, "gp2", "restrict", []string{by, strconv.FormatBool(g.Restrict)}, e.Timestamp)
	}
	if e.Ephemeral != nil {
		g.EphemeralDuration = e.Ephemeral.DisappearingTimer
		if !e.Ephemeral.IsEphemeral {
			g.EphemeralDuration = 0
		}
		a.systemRow(id, "gp2", "ephemeral", []string{by, strconv.Itoa(int(g.EphemeralDuration))}, e.Timestamp)
	}
	if len(e.Join) > 0 {
		a.systemRow(id, "gp2", "add", jids(e.Join), e.Timestamp)
		for _, j := range e.Join {
			g.Participants = append(g.Participants, Participant{ID: a.canonical(j).String()})
		}
	}
	if len(e.Leave) > 0 {
		sub := "remove"
		if len(e.Leave) == 1 && by == a.canonical(e.Leave[0]).String() {
			sub = "leave"
		}
		a.systemRow(id, "gp2", sub, jids(e.Leave), e.Timestamp)
		gone := map[string]bool{}
		for _, j := range e.Leave {
			gone[a.canonical(j).String()] = true
			if a.canonical(j).String() == a.me() {
				s.setChat(a.ID, id, "isReadOnly", 1)
			}
		}
		keep := []Participant{}
		for _, p := range g.Participants {
			if !gone[p.ID] {
				keep = append(keep, p)
			}
		}
		g.Participants = keep
	}
	if len(e.Promote) > 0 {
		a.systemRow(id, "gp2", "promote", jids(e.Promote), e.Timestamp)
		a.setAdmin(&g, e.Promote, true)
	}
	if len(e.Demote) > 0 {
		a.systemRow(id, "gp2", "demote", jids(e.Demote), e.Timestamp)
		a.setAdmin(&g, e.Demote, false)
	}
	g.Size = len(g.Participants)
	s.putGroup(g)
	a.core.emit("GroupMetadata:change", g)
	a.emitChat(id)
}

func (a *Account) setAdmin(g *GroupMetadata, l []types.JID, admin bool) {
	for _, j := range l {
		id := a.canonical(j).String()
		for i := range g.Participants {
			if g.Participants[i].ID == id {
				g.Participants[i].IsAdmin = admin
			}
		}
	}
}

func (a *Account) groupFrom(gi *types.GroupInfo) GroupMetadata {
	g := GroupMetadata{ID: gi.JID.String(), Account: a.ID, Subject: gi.Name, SubjectTime: gi.NameSetAt.Unix(), Desc: gi.Topic,
		Owner: a.canonical(gi.OwnerJID).String(), Creation: gi.GroupCreated.Unix(), Restrict: gi.IsLocked, Announce: gi.IsAnnounce,
		IsParentGroup: gi.IsParent, Participants: []Participant{}}
	if gi.IsEphemeral {
		g.EphemeralDuration = gi.DisappearingTimer
	}
	if !gi.LinkedParentJID.IsEmpty() {
		g.ParentGroup = gi.LinkedParentJID.String()
	}
	for _, p := range gi.Participants {
		id := p.JID
		if !p.PhoneNumber.IsEmpty() {
			id = p.PhoneNumber
		}
		g.Participants = append(g.Participants, Participant{ID: a.canonical(id).String(), IsAdmin: p.IsAdmin || p.IsSuperAdmin, IsSuperAdmin: p.IsSuperAdmin})
	}
	g.Size = len(g.Participants)
	return g
}

// onChatPresence: WhatsApp Web keeps typing/recording per participant (typingUserIds,
// recordingUserIds), so the UI can say "Ana está digitando…" or "Ana, Bruno estão digitando…".
func (a *Account) onChatPresence(e *events.ChatPresence) {
	chat := a.canonical(e.Chat).String()
	who := a.canonical(e.Sender).String()
	p := a.presenceOf(chat)
	a.presMu.Lock()
	p.TypingUserIds = without(p.TypingUserIds, who)
	p.RecordingUserIds = without(p.RecordingUserIds, who)
	if e.State == types.ChatPresenceComposing {
		if e.Media == types.ChatPresenceMediaAudio {
			p.RecordingUserIds = append(p.RecordingUserIds, who)
		} else {
			p.TypingUserIds = append(p.TypingUserIds, who)
		}
		// "paused" does not always come: WhatsApp drops a chat state it has not heard again in 25 s
		a.stateSeq++
		seq := a.stateSeq
		a.stateAt[chat+"|"+who] = seq
		time.AfterFunc(25*time.Second, func() {
			a.presMu.Lock()
			stale := a.stateAt[chat+"|"+who] == seq
			a.presMu.Unlock()
			if stale {
				a.stopTyping(chat, who)
			}
		})
	}
	cp := *p
	a.presMu.Unlock()
	a.core.emit("Presence:change", cp)
}

// stopTyping: who is no longer typing or recording in chat (their message arrived, or the state
// expired); tells the UI only when something changed.
func (a *Account) stopTyping(chat, who string) {
	p := a.presenceOf(chat)
	a.presMu.Lock()
	n := len(p.TypingUserIds) + len(p.RecordingUserIds)
	p.TypingUserIds = without(p.TypingUserIds, who)
	p.RecordingUserIds = without(p.RecordingUserIds, who)
	changed := n != len(p.TypingUserIds)+len(p.RecordingUserIds)
	delete(a.stateAt, chat+"|"+who)
	cp := *p
	a.presMu.Unlock()
	if changed {
		a.core.emit("Presence:change", cp)
	}
}

func (a *Account) presenceOf(id string) *Presence {
	a.presMu.Lock()
	defer a.presMu.Unlock()
	p := a.presence[id]
	if p == nil {
		p = &Presence{ID: id, Account: a.ID, TypingUserIds: []string{}, RecordingUserIds: []string{}}
		a.presence[id] = p
	}
	return p
}

func without(l []string, x string) []string {
	out := []string{}
	for _, v := range l {
		if v != x {
			out = append(out, v)
		}
	}
	return out
}

// cleared: the chat's messages up to t are gone (clear chat here or on another device).
func (a *Account) cleared(remote string, t int64, keepStarred bool) {
	for _, k := range a.core.store.clearChat(a.ID, remote, t, keepStarred) {
		a.core.emit("Msg:remove", P{"account": a.ID, "id": k, "remote": remote})
	}
	a.core.store.setChat(a.ID, remote, "clearedAt", t)
	a.core.store.setChat(a.ID, remote, "unreadCount", 0)
	a.emitChat(remote)
}

// ---- calls: we cannot answer (no open VoIP); ring, then a call_log row if nobody answered ----------

func isVideoOffer(e *events.CallOffer) bool {
	if e == nil || e.Data == nil {
		return false
	}
	for _, c := range e.Data.GetChildren() {
		if c.Tag == "video" {
			return true
		}
	}
	return false
}

// offerReceipt: WhatsApp Web answers every incoming offer with <receipt><offer/></receipt> (the
// caller then sees it ringing); whatsmeow does not.
func (a *Account) offerReceipt(meta types.BasicCallMeta) {
	a.client.DangerousInternals().SendNode(context.Background(), offerReceiptNode(a.client.GenerateMessageID(), meta))
}

func (a *Account) callEnded(meta types.BasicCallMeta, reason string) {
	a.presMu.Lock()
	offer := a.calls[meta.CallID]
	answered := a.accepted[meta.CallID]
	delete(a.calls, meta.CallID)
	delete(a.accepted, meta.CallID)
	a.presMu.Unlock()
	a.core.emit("Call:terminate", P{"account": a.ID, "id": meta.CallID, "reason": reason})
	if offer == nil {
		return
	}
	from := a.canonical(meta.CallCreator).String()
	video := isVideoOffer(offer)
	m := Msg{Type: "call_log", Subtype: "miss", CallOutcome: "MISSED", IsVideoCall: video}
	if video {
		m.Subtype = "miss_video"
	}
	if answered {
		m.Subtype, m.CallOutcome = "", "ACCEPTED"
	}
	info := types.MessageInfo{ID: "call-" + meta.CallID, Timestamp: offer.Timestamp,
		MessageSource: types.MessageSource{Chat: meta.CallCreator, Sender: meta.CallCreator}}
	envelope(&m, a.ID, info, from, from)
	a.core.store.putMsg(m, nil)
	a.core.store.bumpChat(m, !answered, false)
	a.emitMsg("Msg:add", m)
	a.emitChat(from)
}

// ---- history ---------------------------------------------------------------------------------------

// storeHistory: the phone's history sync (at pairing, then in chunks, and on demand): chats with
// WhatsApp Web's per-chat fields, messages (with system rows from stubs), reactions, push names.
func (a *Account) storeHistory(h *waHistorySync.HistorySync) {
	s := a.core.store
	for _, pn := range h.GetPushnames() {
		if j, err := types.ParseJID(pn.GetID()); err == nil {
			s.setContact(a.ID, a.canonical(j).String(), "pushname", pn.GetPushname())
		}
	}
	onDemand := h.GetSyncType() == waHistorySync.HistorySync_ON_DEMAND
	n := 0
	touched := []string{}
	for _, conv := range h.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		if pn := conv.GetPnJID(); jid.Server == types.HiddenUserServer && pn != "" {
			if p, err := types.ParseJID(pn); err == nil {
				jid = p
			}
		}
		id := a.canonical(jid).String()
		s.ensureChat(a.ID, id)
		s.setChatName(a.ID, id, conv.GetName())
		if !onDemand {
			// the phone's read mark (app-state) is newer than this copy: keep its count
			if s.readAt(a.ID, id) < int64(conv.GetConversationTimestamp()) {
				s.setChat(a.ID, id, "unreadCount", conv.GetUnreadCount())
				s.setChat(a.ID, id, "unreadMentionCount", conv.GetUnreadMentionCount())
			}
			// app-state is authoritative for read marks, archive and pin (regular_low) and mute
			// (regular_high): once synced, the history's older copy must not overwrite them
			if !a.appStateSynced(appstate.WAPatchRegularLow) {
				s.setChat(a.ID, id, "markedUnread", b2i(conv.GetMarkedAsUnread()))
				s.setChat(a.ID, id, "archive", b2i(conv.GetArchived()))
				s.setChat(a.ID, id, "pin", int64(conv.GetPinned()))
			}
			if !a.appStateSynced(appstate.WAPatchRegularHigh) {
				mute := int64(conv.GetMuteEndTime())
				if mute > 0 && mute < time.Now().Unix() {
					mute = 0
				}
				s.setChat(a.ID, id, "muteExpiration", mute)
			}
			s.setChat(a.ID, id, "isReadOnly", b2i(conv.GetReadOnly()))
			s.setChat(a.ID, id, "ephemeralDuration", conv.GetEphemeralExpiration())
			s.setChat(a.ID, id, "endOfHistoryTransferType", int(conv.GetEndOfHistoryTransferType()))
			s.setChat(a.ID, id, "isParentGroup", b2i(conv.GetIsParentGroup()))
		}
		newest := int64(conv.GetConversationTimestamp())
		// a clear / delete (app-state) already removed everything up to clearedAt: the history must
		// not bring it back (a clear keeps starred messages, a delete does not)
		var clearedAt int64
		var chatDeleted int
		s.db.QueryRow(`SELECT clearedAt, deleted FROM chats WHERE account=? AND id=?`, a.ID, id).Scan(&clearedAt, &chatDeleted)
		for _, hm := range conv.GetMessages() {
			wm := hm.GetMessage()
			if wm == nil {
				continue
			}
			if vn := wm.GetVerifiedBizName(); vn != "" && !wm.GetKey().GetFromMe() && !strings.HasSuffix(id, "@g.us") {
				s.setContact(a.ID, id, "verifiedName", vn)
				s.setContact(a.ID, id, "isBusiness", 1)
			}
			evt, err := a.client.ParseWebMessage(jid, wm)
			if err != nil {
				continue
			}
			if clearedAt > 0 && evt.Info.Timestamp.Unix() <= clearedAt {
				// the app-state's star (if any) decides, not the history's older copy
				starred := wm.GetStarred()
				part := ""
				if !evt.Info.IsFromMe {
					part = a.canonical(evt.Info.Sender).String()
				}
				if star, _ := s.mark(a.ID, msgKey(evt.Info.IsFromMe, id, evt.Info.ID, part)); star >= 0 {
					starred = star == 1
				}
				if chatDeleted != 0 || !starred {
					continue
				}
			}
			if typ, sub := stubOf(wm.GetMessageStubType()); typ != "" && wm.GetMessage() == nil {
				remote := a.canonical(evt.Info.Chat).String()
				params := []string{}
				for _, p := range wm.GetMessageStubParameters() {
					if pj, err := types.ParseJID(p); err == nil && pj.User != "" {
						p = a.canonical(pj).String()
					}
					params = append(params, p)
				}
				m := Msg{Type: typ, Subtype: sub, TemplateParams: params, IsMdHistoryMsg: true}
				envelope(&m, a.ID, evt.Info, remote, a.canonical(evt.Info.Sender).String())
				if !s.applyMarks(&m) {
					continue
				}
				s.putMsg(m, nil)
				newest = max(newest, m.T)
				n++
				continue
			}
			m, ok := a.onMessage(evt.Info, evt.Message, evt.RawMessage, true)
			if !ok {
				continue
			}
			for _, r := range wm.GetReactions() {
				sender := a.me()
				if !r.GetKey().GetFromMe() {
					sender = id
					if pj, err := types.ParseJID(r.GetKey().GetParticipant()); err == nil && pj.User != "" {
						sender = a.canonical(pj).String()
					}
				}
				s.applyAddon(a.ID, m.Remote, Addon{Kind: "reaction", ParentID: m.MsgID, Sender: sender, FromMe: r.GetKey().GetFromMe(),
					Text: r.GetText(), T: r.GetSenderTimestampMS() / 1000}, a.me())
			}
			if cur, _, ok := s.msg(a.ID, m.ID); ok {
				if cur.FromMe {
					cur.Ack = ackOf(wm.GetStatus())
				}
				cur.Star = wm.GetStarred()
				if star, _ := s.mark(a.ID, cur.ID); star >= 0 {
					cur.Star = star == 1 // app-state's star wins over the history's copy
				}
				s.updateMsg(cur)
			}
			newest = max(newest, m.T)
			n++
		}
		s.db.Exec(`UPDATE chats SET t=MAX(t, ?) WHERE account=? AND id=?`, newest, a.ID, id)
		touched = append(touched, id)
	}
	// the statuses of the last 24 hours, sent once when a device links (INITIAL_STATUS_V3)
	for _, wm := range h.GetStatusV3Messages() {
		evt, err := a.client.ParseWebMessage(types.StatusBroadcastJID, wm)
		if err != nil {
			continue
		}
		if _, ok := a.onMessage(evt.Info, evt.Message, evt.RawMessage, true); ok {
			n++
		}
	}
	ev := P{"account": a.ID, "type": h.GetSyncType().String(), "progress": h.GetProgress(), "chats": len(h.GetConversations()), "msgs": n}
	if onDemand && len(touched) == 1 {
		ev["chat"] = touched[0]
	}
	a.core.emit("History:progress", ev)
}

// ---- out to the app -------------------------------------------------------------------------------

// handOut: a Msg as the UI reads it, with the author's display name.
func (a *Account) handOut(m Msg) Msg {
	if !m.FromMe && m.Author != "" {
		k := a.core.store.contact(a.ID, m.Author)
		m.SenderName = k.FormattedName
		if strings.HasSuffix(m.Remote, "@g.us") {
			if k.Name == "" && k.PhoneNumber != "" {
				m.SenderPhone = formatPhone(k.PhoneNumber)
			}
			if p := k.ProfilePicThumb; p != "" && p != "-" {
				m.SenderPic = p
			}
			if g, ok := a.core.store.group(a.ID, m.Remote); ok {
				for _, p := range g.Participants {
					if (p.IsAdmin || p.IsSuperAdmin) && a.canonical(mustJID(p.ID)).String() == a.canonical(mustJID(m.Author)).String() {
						if g.ParentGroup != "" { // WhatsApp Web names the role in a community's groups only
							m.SenderRole = "Admin da comunidade"
						}
					}
				}
			}
		}
	}
	if m.Type == "ptt" || m.Type == "audio" { // the voice-note bubble shows who speaks
		who := m.Author
		switch {
		case m.FromMe:
			who = a.me()
		case who == "":
			who = m.Remote
		}
		if p := a.core.store.contact(a.ID, who).ProfilePicThumb; p != "" && p != "-" {
			m.SenderPic = p
		}
	}
	if q := m.QuotedMsg; q != nil {
		qc := *q
		switch {
		case qc.Author == "":
			// a 1:1 quote without a participant: the UI names it after the chat
		case a.isMe(qc.Author):
			qc.AuthorName = "Você"
		case strings.HasSuffix(qc.Author, "@g.us") || strings.HasSuffix(qc.Author, "@newsletter"):
			qc.AuthorName = a.chatName(qc.Author)
		case !strings.HasSuffix(m.Remote, "@g.us") && strings.HasSuffix(qc.Author, "@lid"):
			// in a 1:1 chat a quoted author that is not me is the other person, whatever id it uses
			qc.AuthorName = chatTitle(a.core.store.contact(a.ID, m.Remote))
		default:
			qc.AuthorName = a.core.store.contact(a.ID, a.canonical(mustJID(qc.Author)).String()).FormattedName
		}
		m.QuotedMsg = &qc
	}
	if len(m.TemplateParams) > 0 {
		m.TemplateNames = make([]string, len(m.TemplateParams))
		for i, p := range m.TemplateParams {
			switch {
			case p == a.me():
				m.TemplateNames[i] = "Você"
			case strings.Contains(p, "@"):
				m.TemplateNames[i] = a.core.store.contact(a.ID, p).FormattedName
			default:
				m.TemplateNames[i] = p
			}
		}
	}
	return m
}

func (a *Account) emitMsg(method string, m Msg) {
	if m.FromMe && len(m.MsgID) >= 6 { // diagnostics: the ticks of what we send
		fmt.Fprintf(os.Stderr, "qwhats-core: %s %s %s ack=%d\n", time.Now().Format("15:04:05.000"), method, m.MsgID[len(m.MsgID)-6:], m.Ack)
	}
	a.core.emit(method, a.handOut(m))
}

// fullChat: the stored chat with its display name and its chat-list preview.
func (a *Account) fullChat(c Chat) Chat {
	if c.Name == "" {
		if c.Kind == "user" {
			c.Name = chatTitle(a.core.store.contact(a.ID, c.ID))
		} else {
			c.Name = strings.SplitN(c.ID, "@", 2)[0]
		}
	}
	if p := a.core.store.contact(a.ID, c.ID).ProfilePicThumb; p != "" && p != "-" {
		c.ProfilePicThumb = p
	}
	if c.Kind == "user" && !isBotJID(c.ID) && c.ID != types.MetaAIJID.String() {
		// a real person not in the address book (not a service/bot, not a verified business)
		k := a.core.store.contact(a.ID, c.ID)
		c.Unknown = k.Name == "" && k.VerifiedName == ""
	}
	if c.ID == types.MetaAIJID.String() {
		c.Name = "Meta AI"
	}
	if c.Kind == "newsletter" {
		if g, ok := a.core.store.group(a.ID, c.ID); ok {
			c.Subscribers = g.Size
			if c.Name == "" || c.Name == strings.SplitN(c.ID, "@", 2)[0] {
				c.Name = g.Subject
			}
		}
	}
	// where we can't write (WAWebChatModel's isReadOnly / isAnnounceGrpRestrict): broadcast lists
	// (the phone's only), groups we left, groups where only admins send
	if strings.HasSuffix(c.ID, "@broadcast") {
		c.IsReadOnly = true
	}
	if c.Kind == "group" {
		if g, ok := a.core.store.group(a.ID, c.ID); ok && g.ParentGroup != "" {
			c.ParentGroup, c.IsAnnounceGroup = g.ParentGroup, g.Announce
			if p := a.core.store.contact(a.ID, g.ParentGroup).ProfilePicThumb; p != "" && p != "-" {
				c.ParentPic = p
			}
		}
		if g, ok := a.core.store.group(a.ID, c.ID); ok && len(g.Participants) > 0 {
			in, admin := false, false
			for _, p := range g.Participants {
				if a.isMe(p.ID) {
					in, admin = true, p.IsAdmin || p.IsSuperAdmin
				}
			}
			if !in {
				c.IsReadOnly = true
			} else if g.Announce && !admin {
				c.IsAnnounceGrpRestrict = true
			}
		}
	}
	if k, until := a.core.store.chatPin(a.ID, c.ID); k != "" && until > time.Now().Unix() {
		if pm, _, ok := a.core.store.msg(a.ID, k); ok {
			pm = a.handOut(pm)
			c.PinnedMsg = &LastMsg{ID: pm.ID, Type: pm.Type, Body: oneLine(previewBody(pm)), FromMe: pm.FromMe, Author: pm.Author,
				SenderName: pm.SenderName, T: pm.T}
		}
	}
	if m, ok := a.core.store.lastMsg(a.ID, c.ID); ok {
		m = a.handOut(m)
		c.LastMsg = &LastMsg{ID: m.ID, Type: m.Type, Subtype: m.Subtype, Body: oneLine(previewBody(m)), FromMe: m.FromMe, Author: m.Author,
			SenderName: m.SenderName, Ack: m.Ack, T: m.T}
		if m.T > 0 && m.T < c.T && c.Kind == "group" { // a membership notice moved it: back to the message
			c.T = m.T
		}
	}
	return c
}

func (a *Account) emitChat(id string) {
	if c, ok := a.core.store.chat(a.ID, id); ok {
		if fc := a.fullChat(c); a.listed(fc) {
			a.core.emit("Chat:change", fc)
		}
	}
}

// listed: whether a chat belongs in the chat list. The phone's history lists every conversation it
// ever had, but sends messages only for the recent ones: the rest arrive as empty shells — most of
// them without a name (no address-book entry; @lid ones, WhatsApp's number-less ids, never). WhatsApp
// Web shows what it has messages for; so do we, plus what the user marked (pinned, unread) and the
// named ones. A shell that gets a message shows up then.
func (a *Account) listed(c Chat) bool {
	if c.ID == "status@broadcast" { // status updates have their own tab
		return false
	}
	if c.LastMsg != nil || c.Pin > 0 || c.UnreadCount > 0 || c.MarkedUnread || c.DraftMessage != "" {
		return true
	}
	if c.Kind != "user" {
		// a group with no messages is listed when the phone's history has it (it has a time); one we
		// only know from the joined-groups list (no time, never talked in) is not, as on WhatsApp Web
		return (c.Kind == "group" && c.T > 0) || c.Kind == "community"
	}
	// a verified business or a bot/service (Meta AI, Porto Seguro, …) is a thing the user wants to
	// reach even with no stored history — unlike a random person who messaged once (their push name
	// alone is not an interaction). So list businesses and bots, not unknown personal contacts.
	if k := a.core.store.contact(a.ID, c.ID); k.VerifiedName != "" || k.IsBusiness {
		return true
	}
	if isBotJID(c.ID) {
		return true
	}
	// a 1:1 personal chat is a thread, not an address-book entry: it belongs in recents only once a
	// message was exchanged (handled above). Knowing the contact's push name is not an interaction.
	return false
}

func (a *Account) emitContact(id string) {
	a.core.emit("Contact:change", a.core.store.contact(a.ID, id))
}

// isBotJID: a service/bot chat (Meta AI and the like) — not a person to mark "unknown". Covers the
// @bot server and the phone-number form a bot's chat is canonicalised to (types.BotJIDMap).
func isBotJID(id string) bool {
	j, err := parseJID(id)
	if err != nil {
		return false
	}
	if j.IsBot() {
		return true
	}
	for bot, pn := range types.BotJIDMap {
		if pn.ToNonAD().String() == id || bot.ToNonAD().String() == id {
			return true
		}
	}
	return false
}

// ensureBusinessChats: a chat row for every verified business and bot contact, so they appear in the
// list even with no stored history (WhatsApp keeps businesses reachable). It does not add personal
// contacts — a random person's push name is not a reason to list them.
func (a *Account) ensureBusinessChats() {
	rows, err := a.core.store.db.Query(`SELECT id FROM contacts WHERE account=? AND (verifiedName!='' OR isBusiness=1) AND id LIKE '%@s.whatsapp.net'`, a.ID)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	for _, id := range ids {
		if _, ok := a.core.store.chat(a.ID, id); !ok {
			a.core.store.ensureChat(a.ID, id)
			a.emitChat(id)
		}
	}
}
