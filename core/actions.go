package main

// The actions: WhatsApp Web's own (WAWebSendTextMsgChatAction.sendTextMsgToChat,
// WAWebSendReactionMsgAction.sendReactionToMsg, WAWebChatSendDeleteMsgsBridge.sendDeleteMsgs, …),
// each done with whatsmeow, or — where whatsmeow has no builder — the way WhatsApp Web builds it.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

var ctx = context.Background()

func parseJID(s string) (types.JID, error) {
	j, err := types.ParseJID(s)
	if err != nil {
		return j, fmt.Errorf("bad id %q: %w", s, err)
	}
	return j, nil
}

// target: a stored message by its key, with the JIDs whatsmeow wants.
type target struct {
	m      Msg
	raw    []byte
	chat   types.JID
	sender types.JID // the author (me for my messages)
}

func (a *Account) target(key string) (target, error) {
	m, raw, ok := a.core.store.msg(a.ID, key)
	if !ok {
		return target{}, fmt.Errorf("no message %s", key)
	}
	chat, err := parseJID(m.Remote)
	if err != nil {
		return target{}, err
	}
	t := target{m: m, raw: raw, chat: chat}
	switch {
	case m.FromMe:
		t.sender = types.EmptyJID
		if a.client.Store.ID != nil {
			t.sender = a.client.Store.ID.ToNonAD()
		}
	case m.Author != "":
		t.sender, _ = parseJID(m.Author)
	default:
		t.sender = chat
	}
	return t, nil
}

func (a *Account) messageKey(t target) *waCommon.MessageKey {
	return a.client.BuildMessageKey(t.chat, t.sender, t.m.MsgID)
}

// ---- sending ---------------------------------------------------------------------------------------

// sendTextMsgToChat (WAWebSendTextMsgChatAction): text, optionally replying (quotedMsg: a message
// key) and mentioning (mentionedJidList).
func (a *Account) sendTextMsgToChat(chatS, text, quoted string, mentions []string) (Msg, error) {
	chat, err := parseJID(chatS)
	if err != nil {
		return Msg{}, err
	}
	msg := &waE2E.Message{}
	ci := &waE2E.ContextInfo{}
	useCI := false
	if quoted != "" {
		t, err := a.target(quoted)
		if err != nil {
			return Msg{}, err
		}
		ci.StanzaID = proto.String(t.m.MsgID)
		if !t.m.FromMe {
			ci.Participant = proto.String(t.sender.String())
		} else if a.client.Store.ID != nil {
			ci.Participant = proto.String(a.client.Store.ID.ToNonAD().String())
		}
		if len(t.raw) > 0 {
			var qm waE2E.Message
			if proto.Unmarshal(t.raw, &qm) == nil {
				inner, _ := unwrap(&qm)
				ci.QuotedMessage = inner
			}
		}
		useCI = true
	}
	if len(mentions) > 0 {
		ci.MentionedJID = mentions
		useCI = true
	}
	if exp := a.chatEphemeral(chatS); exp > 0 {
		ci.Expiration = proto.Uint32(exp)
		useCI = true
	}
	if useCI {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}
	} else {
		msg.Conversation = proto.String(text)
	}
	return a.send(chat, msg, "")
}

func (a *Account) chatEphemeral(chat string) uint32 {
	if c, ok := a.core.store.chat(a.ID, chat); ok {
		return c.EphemeralDuration
	}
	return 0
}

// send (WAWebSendMsgChatAction.addAndSendMsgToChat): stored first at ack CLOCK (the clock icon), then
// SENT when the server takes it, FAILED when it does not.
func (a *Account) send(chat types.JID, msg *waE2E.Message, id string) (Msg, error) {
	if id == "" {
		id = a.client.GenerateMessageID()
	}
	info := types.MessageInfo{ID: id, Timestamp: time.Now(), MessageSource: types.MessageSource{Chat: chat, IsFromMe: true}}
	if a.client.Store.ID != nil {
		info.Sender = a.client.Store.ID.ToNonAD()
	}
	n, ok := content(msg)
	if !ok {
		return Msg{}, errors.New("not a message")
	}
	envelope(&n, a.ID, info, a.canonical(chat).String(), a.me())
	n.Ack = AckClock
	raw, _ := proto.Marshal(msg)
	a.core.store.putMsg(n, raw)
	a.core.store.bumpChat(n, false, false)
	a.emitMsg("Msg:add", n)
	a.emitChat(n.Remote)
	to := chat
	if chat.IsBot() && chat.Server == types.DefaultUserServer {
		// Meta AI (and WhatsApp's other bots) are written to at their bot id, as WhatsApp Web does
		for bot, pn := range types.BotJIDMap {
			if pn == chat {
				to = bot
				break
			}
		}
	}
	resp, err := a.client.SendMessage(ctx, to, msg, whatsmeow.SendRequestExtra{ID: id})
	if err == nil && to.Server == types.BotServer {
		// the answer is decrypted with this message's secret, looked up by the bot id and our LID
		// (whatsmeow kept it under our phone number): keep it under both
		if secret := msg.GetMessageContextInfo().GetMessageSecret(); secret != nil && a.client.Store.LID.User != "" {
			if perr := a.client.Store.MsgSecrets.PutMessageSecret(ctx, to, a.client.Store.LID.ToNonAD(), id, secret); perr != nil {
				fmt.Fprintln(os.Stderr, "qwhats-core: bot secret:", perr)
			}
		}
	}
	if err != nil {
		n.Ack = AckFailed
		a.core.store.updateMsg(n)
		a.emitMsg("Msg:change", n)
		return n, err
	}
	n.Ack, n.T = AckSent, resp.Timestamp.Unix()
	a.core.store.updateMsg(n)
	a.emitMsg("Msg:change", n)
	a.emitChat(n.Remote)
	return n, nil
}

// sendMediaMsgToChat: a file as image / video / voice note (ptt) / audio / document, as WhatsApp
// Web's media send picks by type.
func (a *Account) sendMediaMsgToChat(chatS, path, caption, quoted string, asPtt, asDocument bool, seconds int) (Msg, error) {
	chat, err := parseJID(chatS)
	if err != nil {
		return Msg{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Msg{}, err
	}
	mimetype := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mimetype == "" {
		mimetype = "application/octet-stream"
	}
	kind := whatsmeow.MediaDocument
	switch {
	case asDocument:
	case asPtt || strings.HasPrefix(mimetype, "audio/"):
		kind = whatsmeow.MediaAudio
	case strings.HasPrefix(mimetype, "image/") && mimetype != "image/gif":
		kind = whatsmeow.MediaImage
	case strings.HasPrefix(mimetype, "video/"):
		kind = whatsmeow.MediaVideo
	}
	up, err := a.client.Upload(ctx, data, kind)
	if err != nil {
		return Msg{}, err
	}
	ci := &waE2E.ContextInfo{}
	if quoted != "" {
		if t, err := a.target(quoted); err == nil {
			ci.StanzaID = proto.String(t.m.MsgID)
			ci.Participant = proto.String(t.sender.String())
		}
	}
	if exp := a.chatEphemeral(chatS); exp > 0 {
		ci.Expiration = proto.Uint32(exp)
	}
	size := uint64(len(data))
	msg := &waE2E.Message{}
	switch kind {
	case whatsmeow.MediaImage:
		w, h, thumb := pictureInfo(data)
		msg.ImageMessage = &waE2E.ImageMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: &size, Mimetype: &mimetype, Caption: proto.String(caption), ContextInfo: ci,
			Width: proto.Uint32(w), Height: proto.Uint32(h), JPEGThumbnail: thumb}
	case whatsmeow.MediaVideo:
		msg.VideoMessage = &waE2E.VideoMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: &size, Mimetype: &mimetype, Caption: proto.String(caption), ContextInfo: ci}
	case whatsmeow.MediaAudio:
		if asPtt {
			mimetype = "audio/ogg; codecs=opus"
		}
		msg.AudioMessage = &waE2E.AudioMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: &size, Mimetype: &mimetype, PTT: proto.Bool(asPtt), ContextInfo: ci,
			Seconds: proto.Uint32(uint32(seconds)), MediaKeyTimestamp: proto.Int64(time.Now().Unix())}
		// a voice note carries its waveform (64 levels): WhatsApp's phones draw it, and iPhones
		// refuse a voice note without one
		if asPtt {
			if wf := waveformOf(path); wf != nil {
				msg.AudioMessage.Waveform = wf
			}
		}
	default:
		name := filepath.Base(path)
		msg.DocumentMessage = &waE2E.DocumentMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: &size, Mimetype: &mimetype, FileName: &name, Title: &name, Caption: proto.String(caption), ContextInfo: ci}
	}
	n, err := a.send(chat, msg, "")
	if err == nil {
		// we have the file already: no download needed
		if dst, ok := a.mediaPath(n, data); ok {
			n.MediaData.RenderableURL, n.MediaData.MediaStage = dst, "RESOLVED"
			a.core.store.updateMsg(n)
			a.emitMsg("Msg:change", n)
		}
	}
	return n, err
}

// sendReactionToMsg (WAWebSendReactionMsgAction); "" takes the reaction back.
func (a *Account) sendReactionToMsg(key, reaction string) error {
	t, err := a.target(key)
	if err != nil {
		return err
	}
	if _, err := a.client.SendMessage(ctx, t.chat, a.client.BuildReaction(t.chat, t.sender, t.m.MsgID, reaction)); err != nil {
		return err
	}
	if p, ok := a.core.store.applyAddon(a.ID, t.m.Remote, Addon{Kind: "reaction", ParentID: t.m.MsgID, Sender: a.me(), FromMe: true,
		Text: reaction, T: time.Now().Unix()}, a.me()); ok {
		a.emitMsg("Msg:change", p)
	}
	return nil
}

// sendRevoke (WAWebRevokeMsgAction): delete for everyone.
func (a *Account) sendRevoke(keys []string) error {
	fmt.Fprintf(os.Stderr, "qwhats-core: sendRevoke %d msg(s)\n", len(keys))
	// a batch keeps going past a message that fails (WhatsApp Web revokes each on its own): one bad
	// one must not stop the rest. Only an all-failed batch returns an error.
	var firstErr error
	done := 0
	for _, k := range keys {
		t, err := a.target(k)
		if err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: revoke", k, "target:", err)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if _, err := a.client.SendMessage(ctx, t.chat, a.client.BuildRevoke(t.chat, t.sender, t.m.MsgID)); err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: revoke", k, "send:", err)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if p, ok := a.core.store.applyAddon(a.ID, t.m.Remote, Addon{Kind: "revoke", ParentID: t.m.MsgID, Sender: a.me(), FromMe: true}, a.me()); ok {
			a.emitMsg("Msg:change", p)
		}
		a.emitChat(t.m.Remote)
		done++
	}
	if done == 0 {
		return firstErr
	}
	return nil
}

// editMessage: a new text for one of my messages (BuildEdit; WhatsApp allows it for 15 minutes).
func (a *Account) editMessage(key, text string) error {
	t, err := a.target(key)
	if err != nil {
		return err
	}
	if !t.m.FromMe {
		return errors.New("only your own messages can be edited")
	}
	newContent := &waE2E.Message{Conversation: proto.String(text)}
	if _, err := a.client.SendMessage(ctx, t.chat, a.client.BuildEdit(t.chat, t.m.MsgID, newContent)); err != nil {
		return err
	}
	edited := Msg{Type: "chat", Body: text}
	if p, ok := a.core.store.applyAddon(a.ID, t.m.Remote, Addon{Kind: "edit", ParentID: t.m.MsgID, Sender: a.me(), FromMe: true,
		Edited: &edited, T: time.Now().Unix()}, a.me()); ok {
		a.emitMsg("Msg:change", p)
		a.emitChat(t.m.Remote)
	}
	return nil
}

// sendDeleteMsgs (WAWebChatSendDeleteMsgsBridge): delete for me — an app-state mutation whatsmeow
// has no builder for, made as WAWebDeleteMessageForMeSync makes it: regular_high, version 3, index
// [deleteMessageForMe, chat, id, fromMe, participant], value deleteMessageForMeAction.
func (a *Account) sendDeleteMsgs(keys []string, deleteMedia bool) error {
	patch := appstate.PatchInfo{Type: appstate.WAPatchRegularHigh}
	targets := []target{}
	for _, k := range keys {
		t, err := a.target(k)
		if err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: delete", k, "target:", err)
			continue
		}
		fromMe, participant := "0", "0"
		if t.m.FromMe {
			fromMe = "1"
		}
		if t.chat.Server == types.GroupServer && !t.m.FromMe {
			participant = t.sender.String()
		}
		patch.Mutations = append(patch.Mutations, appstate.MutationInfo{
			Index:   []string{appstate.IndexDeleteMessageForMe, t.chat.String(), t.m.MsgID, fromMe, participant},
			Version: 3,
			Value: &waSyncAction.SyncActionValue{DeleteMessageForMeAction: &waSyncAction.DeleteMessageForMeAction{
				DeleteMedia: proto.Bool(deleteMedia), MessageTimestamp: proto.Int64(t.m.T)}},
		})
		targets = append(targets, t)
	}
	if len(patch.Mutations) == 0 {
		return errors.New("no deletable messages")
	}
	if err := a.client.SendAppState(ctx, patch); err != nil {
		return err
	}
	for _, t := range targets {
		a.core.store.deleteMsg(a.ID, t.m.ID)
		a.core.emit("Msg:remove", P{"account": a.ID, "id": t.m.ID, "remote": t.m.Remote})
		a.emitChat(t.m.Remote)
	}
	return nil
}

// sendStarMsgs (WAWebChatSendStarMsgsBridge).
func (a *Account) sendStarMsgs(keys []string, star bool) error {
	for _, k := range keys {
		t, err := a.target(k)
		if err != nil {
			return err
		}
		if err := a.client.SendAppState(ctx, appstate.BuildStar(t.chat, t.sender, t.m.MsgID, t.m.FromMe, star)); err != nil {
			return err
		}
		t.m.Star = star
		a.core.store.updateMsg(t.m)
		a.emitMsg("Msg:change", t.m)
	}
	return nil
}

// lastKey: the chat's newest message as whatsmeow's archive / read / delete patches want it.
func (a *Account) lastKey(chat string) (time.Time, *waCommon.MessageKey) {
	m, ok := a.core.store.lastMsg(a.ID, chat)
	if !ok {
		return time.Now(), nil
	}
	t, err := a.target(m.ID)
	if err != nil {
		return time.Unix(m.T, 0), nil
	}
	return time.Unix(m.T, 0), a.messageKey(t)
}

// setArchive (WAWebSetArchiveChatAction).
func (a *Account) setArchive(chatS string, archive bool) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	ts, key := a.lastKey(chatS)
	if err := a.client.SendAppState(ctx, appstate.BuildArchive(chat, archive, ts, key)); err != nil {
		return err
	}
	a.core.store.setChat(a.ID, chatS, "archive", b2i(archive))
	if archive {
		a.core.store.setChat(a.ID, chatS, "pin", 0) // WhatsApp unpins what it archives
	}
	a.emitChat(chatS)
	return nil
}

// setPin (WAWebChatPinBridge.setPin): WhatsApp allows 3 pinned chats.
func (a *Account) setPin(chatS string, pin bool) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	if pin {
		n := 0
		for _, c := range a.core.store.chats(a.ID) {
			if c.Pin > 0 && c.ID != chatS {
				n++
			}
		}
		if n >= 3 {
			return errors.New("só dá para fixar 3 conversas")
		}
	}
	if err := a.client.SendAppState(ctx, appstate.BuildPin(chat, pin)); err != nil {
		return err
	}
	v := int64(0)
	if pin {
		v = time.Now().Unix()
	}
	a.core.store.setChat(a.ID, chatS, "pin", v)
	a.emitChat(chatS)
	return nil
}

// sendStatusMute (WAWebUserStatusMuteSync.getMutationForStatusMute): mute or unmute a contact's
// status updates — regular_high, version 7, index [userStatusMute, the contact], {muted}; the
// mutation whatsmeow has no builder for.
func (a *Account) sendStatusMute(idS string, muted bool) error {
	jid, err := parseJID(idS)
	if err != nil {
		return err
	}
	patch := appstate.PatchInfo{Type: appstate.WAPatchRegularHigh, Mutations: []appstate.MutationInfo{{
		Index:   []string{appstate.IndexUserStatusMute, jid.ToNonAD().String()},
		Version: 7,
		Value:   &waSyncAction.SyncActionValue{UserStatusMuteAction: &waSyncAction.UserStatusMuteAction{Muted: proto.Bool(muted)}},
	}}}
	if err := a.client.SendAppState(ctx, patch); err != nil {
		return err
	}
	a.core.store.setStatusMuted(a.ID, idS, muted)
	a.core.emit("Status:change", P{"account": a.ID, "id": idS})
	return nil
}

// sendConversationMute (WAWebChatMuteBridge): expiration is a Unix time; -1 = always, 0 = unmute.
func (a *Account) sendConversationMute(chatS string, expiration int64) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	var patch appstate.PatchInfo
	switch {
	case expiration == 0:
		patch = appstate.BuildMuteAbs(chat, false, nil)
	case expiration < 0:
		forever := int64(-1)
		patch = appstate.BuildMuteAbs(chat, true, &forever)
	default:
		ms := expiration * 1000
		patch = appstate.BuildMuteAbs(chat, true, &ms)
	}
	if err := a.client.SendAppState(ctx, patch); err != nil {
		return err
	}
	a.core.store.setChat(a.ID, chatS, "muteExpiration", expiration)
	a.emitChat(chatS)
	return nil
}

// sendClear (WAWebChatClearBridge): clear chat — the app-state mutation whatsmeow lacks, made as
// WAWebClearChatSync makes it: regular_high, version 6, index [clearChat, chat, deleteStarred,
// deleteMedia], value clearChatAction{messageRange}.
func (a *Account) sendClear(chatS string, keepStarred bool) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	ts, key := a.lastKey(chatS)
	rng := &waSyncAction.SyncActionMessageRange{LastMessageTimestamp: proto.Int64(ts.Unix())}
	if key != nil {
		rng.Messages = []*waSyncAction.SyncActionMessage{{Key: key, Timestamp: proto.Int64(ts.Unix())}}
	}
	deleteStarred := "1"
	if keepStarred {
		deleteStarred = "0"
	}
	patch := appstate.PatchInfo{Type: appstate.WAPatchRegularHigh, Mutations: []appstate.MutationInfo{{
		Index:   []string{appstate.IndexClearChat, chat.String(), deleteStarred, "0"},
		Version: 6,
		Value:   &waSyncAction.SyncActionValue{ClearChatAction: &waSyncAction.ClearChatAction{MessageRange: rng}},
	}}}
	if err := a.client.SendAppState(ctx, patch); err != nil {
		return err
	}
	a.cleared(chatS, ts.Unix(), keepStarred)
	return nil
}

// sendDelete (WAWebDeleteChatAction).
func (a *Account) sendDelete(chatS string) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	ts, key := a.lastKey(chatS)
	if err := a.client.SendAppState(ctx, appstate.BuildDeleteChat(chat, ts, key, false)); err != nil {
		return err
	}
	a.cleared(chatS, time.Now().Unix(), false)
	a.core.store.setChat(a.ID, chatS, "deleted", 1)
	a.core.emit("Chat:remove", P{"account": a.ID, "id": chatS})
	return nil
}

// sendSeen (WAWebUpdateUnreadChatAction.sendSeen): read receipts for the unread messages, and the
// chat's marked-unread flag cleared on every device.
func (a *Account) sendSeen(chatS string) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	c, _ := a.core.store.chat(a.ID, chatS)
	n := max(c.UnreadCount, 1)
	bySender := map[types.JID][]types.MessageID{}
	for _, m := range a.core.store.msgs(a.ID, chatS, 0, min(n+20, 500)) {
		if m.FromMe || m.Type == "gp2" || m.Type == "e2e_notification" || m.Type == "call_log" || m.Type == "notification_template" {
			continue
		}
		sender := types.EmptyJID
		if chat.Server == types.GroupServer && m.Author != "" {
			sender, _ = types.ParseJID(m.Author)
		}
		bySender[sender] = append(bySender[sender], m.MsgID)
	}
	for sender, ids := range bySender {
		if len(ids) > n {
			ids = ids[len(ids)-n:]
		}
		for len(ids) > 0 { // WhatsApp Web sends at most 256 ids per receipt
			k := min(len(ids), 256)
			a.client.MarkRead(ctx, ids[:k], time.Now(), chat, sender)
			ids = ids[k:]
		}
	}
	if c.MarkedUnread {
		ts, key := a.lastKey(chatS)
		a.client.SendAppState(ctx, appstate.BuildMarkChatAsRead(chat, true, ts, key))
	}
	a.core.store.setChat(a.ID, chatS, "unreadCount", 0)
	a.core.store.setChat(a.ID, chatS, "unreadMentionCount", 0)
	a.core.store.setChat(a.ID, chatS, "markedUnread", 0)
	a.emitChat(chatS)
	return nil
}

// markUnread (WAWebUpdateUnreadChatAction.markUnread).
func (a *Account) markUnread(chatS string) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	ts, key := a.lastKey(chatS)
	if err := a.client.SendAppState(ctx, appstate.BuildMarkChatAsRead(chat, false, ts, key)); err != nil {
		return err
	}
	a.core.store.setChat(a.ID, chatS, "markedUnread", 1)
	a.emitChat(chatS)
	return nil
}

// chatState: markComposing / markRecording / markPaused (WAWebPresenceChatAction).
func (a *Account) chatState(chatS, state string) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	switch state {
	case "composing":
		return a.client.SendChatPresence(ctx, chat, types.ChatPresenceComposing, types.ChatPresenceMediaText)
	case "recording":
		return a.client.SendChatPresence(ctx, chat, types.ChatPresenceComposing, types.ChatPresenceMediaAudio)
	}
	return a.client.SendChatPresence(ctx, chat, types.ChatPresencePaused, types.ChatPresenceMediaText)
}

// changeEphemeralDuration (WAWebChangeEphemeralDurationChatAction): seconds, 0 = off.
func (a *Account) changeEphemeralDuration(chatS string, seconds int) error {
	chat, err := parseJID(chatS)
	if err != nil {
		return err
	}
	if err := a.client.SetDisappearingTimer(ctx, chat, time.Duration(seconds)*time.Second, time.Now()); err != nil {
		return err
	}
	a.core.store.setChat(a.ID, chatS, "ephemeralDuration", seconds)
	a.emitChat(chatS)
	return nil
}

// markPlayed (WAWebMarkPlayedMsgAction): a voice note was listened to.
func (a *Account) markPlayed(key string) error {
	t, err := a.target(key)
	if err != nil {
		return err
	}
	if t.m.FromMe {
		return nil
	}
	sender := types.EmptyJID
	if t.chat.Server == types.GroupServer {
		sender = t.sender
	}
	return a.client.MarkRead(ctx, []types.MessageID{t.m.MsgID}, time.Now(), t.chat, sender, types.ReceiptTypePlayed)
}

// loadEarlierMsgs (WAWebChatMsgsCollection.loadEarlierMsgs): what we have is in the store; past
// it, the phone is asked (an on-demand history sync, answered as a HistorySync event).
func (a *Account) loadEarlierMsgs(chatS string, before int64, limit int) ([]Msg, error) {
	msgs := a.core.store.msgs(a.ID, chatS, before, limit)
	if len(msgs) >= limit {
		return msgs, nil
	}
	oldest, ok := a.core.store.oldestMsg(a.ID, chatS)
	if !ok {
		return msgs, nil
	}
	t, err := a.target(oldest.ID)
	if err != nil {
		return msgs, nil
	}
	info := &types.MessageInfo{ID: oldest.MsgID, Timestamp: time.Unix(oldest.T, 0),
		MessageSource: types.MessageSource{Chat: t.chat, Sender: t.sender, IsFromMe: oldest.FromMe, IsGroup: t.chat.Server == types.GroupServer}}
	_, err = a.client.SendPeerMessage(ctx, a.client.BuildHistorySyncRequest(info, 50))
	return msgs, err
}

// forwardMessages (WAWebForwardMessagesToChat): each message to each chat, as it was, marked
// forwarded (ContextInfo.isForwarded, forwardingScore + 1 — "Encaminhada com frequência" from 5),
// without its quote or mentions.
func (a *Account) forwardMessages(keys, chats []string) ([]Msg, error) {
	// a batch forwards every message it can and skips the ones it cannot (a message whose original is
	// not stored, or a kind that cannot be forwarded) instead of aborting the whole batch on the first
	// failure — several selected messages must not be stopped by one bad one.
	out := []Msg{}
	var firstErr error
	fail := func(k string, err error) {
		fmt.Fprintln(os.Stderr, "qwhats-core: forward", k, err)
		if firstErr == nil {
			firstErr = err
		}
	}
	for _, k := range keys {
		t, err := a.target(k)
		if err != nil {
			fail(k, err)
			continue
		}
		var orig waE2E.Message
		if len(t.raw) == 0 || proto.Unmarshal(t.raw, &orig) != nil {
			fail(k, fmt.Errorf("cannot be forwarded (not stored)"))
			continue
		}
		inner, _ := unwrap(&orig)
		for _, c := range chats {
			chat, err := parseJID(c)
			if err != nil {
				fail(k, err)
				continue
			}
			fwd := proto.Clone(inner).(*waE2E.Message)
			if fwd.Conversation != nil {
				fwd.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: fwd.Conversation}
				fwd.Conversation = nil
			}
			ci := &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(t.m.ForwardingScore + 1)}
			if chat == types.StatusBroadcastJID { // to my status: posted as mine, not "forwarded"
				ci = &waE2E.ContextInfo{}
				if fwd.ExtendedTextMessage != nil && fwd.ExtendedTextMessage.BackgroundArgb == nil {
					fwd.ExtendedTextMessage.BackgroundArgb = proto.Uint32(0xFF1E8C6F) // a text status needs its colour
					fwd.ExtendedTextMessage.TextArgb = proto.Uint32(0xFFFFFFFF)
				}
			}
			if exp := a.chatEphemeral(c); exp > 0 {
				ci.Expiration = proto.Uint32(exp)
			}
			if !setContext(fwd, ci) {
				fail(k, fmt.Errorf("this kind of message cannot be forwarded"))
				continue
			}
			m, err := a.send(chat, fwd, "")
			if err != nil {
				fail(k, err)
				continue
			}
			if t.m.MediaData != nil && t.m.MediaData.RenderableURL != "" && m.MediaData != nil {
				m.MediaData.RenderableURL, m.MediaData.MediaStage = t.m.MediaData.RenderableURL, "RESOLVED"
				a.core.store.updateMsg(m)
				a.emitMsg("Msg:change", m)
			}
			out = append(out, m)
		}
	}
	if len(out) == 0 && firstErr != nil {
		return out, firstErr
	}
	return out, nil
}

// setContext: a message's ContextInfo, whatever kind it is.
func setContext(m *waE2E.Message, ci *waE2E.ContextInfo) bool {
	switch {
	case m.ExtendedTextMessage != nil:
		m.ExtendedTextMessage.ContextInfo = ci
	case m.ImageMessage != nil:
		m.ImageMessage.ContextInfo = ci
	case m.VideoMessage != nil:
		m.VideoMessage.ContextInfo = ci
	case m.AudioMessage != nil:
		m.AudioMessage.ContextInfo = ci
	case m.DocumentMessage != nil:
		m.DocumentMessage.ContextInfo = ci
	case m.StickerMessage != nil:
		m.StickerMessage.ContextInfo = ci
	case m.LocationMessage != nil:
		m.LocationMessage.ContextInfo = ci
	case m.ContactMessage != nil:
		m.ContactMessage.ContextInfo = ci
	case m.ContactsArrayMessage != nil:
		m.ContactsArrayMessage.ContextInfo = ci
	case m.PtvMessage != nil:
		m.PtvMessage.ContextInfo = ci
	default:
		return false
	}
	return true
}

// fetchPictures: profile pictures for the chat list, newest chats first, a few a second (WhatsApp
// Web asks as rows come into view; we fill the cache in the background). "-" marks "has none";
// a Picture event clears it so it is asked again.
func (a *Account) fetchPictures() {
	if a.core.store.contact(a.ID, a.me()).ProfilePicThumb == "" { // mine too (my voice notes)
		a.fetchPic(a.me(), false)
	}
	for _, c := range a.core.store.chats(a.ID) {
		if !a.client.IsConnected() {
			return
		}
		if c.Kind == "newsletter" { // channels: their metadata's picture (channels())
			continue
		}
		pic := a.core.store.contact(a.ID, c.ID).ProfilePicThumb
		// a group marked "none" is asked again once a session: the mark may come from a failure
		if pic != "" && !(pic == "-" && c.Kind == "group") {
			continue
		}
		a.fetchPic(c.ID, pic == "-")
		a.emitChat(c.ID)
		time.Sleep(300 * time.Millisecond)
	}
}

// communityPic: a community's picture file (asked as a community, as WhatsApp Web does), "" if none.
func (a *Account) communityPic(id string) string {
	if p := a.core.store.contact(a.ID, id).ProfilePicThumb; p != "" && p != "-" {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	j, err := parseJID(id)
	if err != nil {
		return ""
	}
	info, err := a.client.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true, IsCommunity: true})
	if err != nil || info == nil {
		return ""
	}
	data, err := httpGet(info.URL)
	if err != nil {
		return ""
	}
	dir := filepath.Join(a.core.cacheDir, "pics")
	os.MkdirAll(dir, 0o700)
	p := filepath.Join(dir, strings.NewReplacer("@", "_", ":", "_").Replace(id)+"-"+info.ID+".jpg")
	if os.WriteFile(p, data, 0o600) != nil {
		return ""
	}
	a.core.store.setContact(a.ID, id, "pic", p)
	return p
}

// fetchPic: one chat's picture. Only WhatsApp's own answers — no picture, or hidden from us — mark
// "none"; a failure (rate limit, network) leaves it to the next try.
func (a *Account) fetchPic(id string, again bool) {
	if again {
		a.core.store.setContact(a.ID, id, "pic", "")
	}
	c, err := a.requestProfilePicFromServer(id)
	if err == nil && c.ProfilePicThumb == "-" { // answered "none" without an error
		err = whatsmeow.ErrProfilePictureNotSet
	}
	switch {
	case err == nil:
	case errors.Is(err, whatsmeow.ErrProfilePictureNotSet), errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized):
		a.core.store.setContact(a.ID, id, "pic", "-")
		// a community's group without a picture of its own shows the community's (WhatsApp Web)
		if strings.HasSuffix(id, "@g.us") {
			g, ok := a.core.store.group(a.ID, id)
			if !ok {
				var qerr error
				if g, qerr = a.sendQueryGroup(id); qerr != nil {
					fmt.Fprintln(os.Stderr, "qwhats-core: group info:", qerr)
				}
			}
			if g.ParentGroup != "" {
				if p := a.communityPic(g.ParentGroup); p != "" {
					a.core.store.setContact(a.ID, id, "pic", p)
				}
			}
		}
	default:
		fmt.Fprintln(os.Stderr, "qwhats-core: picture:", err)
		if again {
			a.core.store.setContact(a.ID, id, "pic", "-")
		}
	}
}

// ---- media -----------------------------------------------------------------------------------------

// mediaPath: where a message's file lives once decrypted (cache/media/<hash>.<ext>).
func (a *Account) mediaPath(m Msg, data []byte) (string, bool) {
	dir := filepath.Join(a.core.cacheDir, "media")
	os.MkdirAll(dir, 0o700)
	ext := ""
	if m.MediaData != nil {
		if m.MediaData.Filename != "" {
			ext = filepath.Ext(m.MediaData.Filename)
		}
		if ext == "" {
			if exts, _ := mime.ExtensionsByType(strings.SplitN(m.MediaData.Mimetype, ";", 2)[0]); len(exts) > 0 {
				ext = exts[len(exts)-1]
			}
		}
	}
	sum := sha256.Sum256([]byte(m.Account + m.ID))
	p := filepath.Join(dir, hex.EncodeToString(sum[:12])+ext)
	if data != nil {
		if os.WriteFile(p, data, 0o600) != nil {
			return "", false
		}
	}
	return p, true
}

// downloadMedia (WhatsApp Web's download manager): decrypt into the cache; expired media asks the
// sender's phone to upload it again (mediaStage NEED_POKE, then a MediaRetry event).
func (a *Account) downloadMedia(key string) (Msg, error) {
	t, err := a.target(key)
	if err != nil {
		return Msg{}, err
	}
	if t.m.MediaData == nil {
		return t.m, errors.New("no media in this message")
	}
	if p := t.m.MediaData.RenderableURL; p != "" {
		if _, err := os.Stat(p); err == nil {
			return a.handOut(t.m), nil
		}
	}
	var raw waE2E.Message
	if proto.Unmarshal(t.raw, &raw) != nil {
		return t.m, errors.New("the original message is not stored")
	}
	inner, _ := unwrap(&raw)
	t.m.MediaData.MediaStage = "FETCHING"
	a.emitMsg("Msg:change", t.m)
	data, err := a.client.DownloadAny(ctx, inner)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: download", t.m.Type+":", err)
		// gone from WhatsApp's servers (expired, or never kept): the phone is asked to upload it again
		// an expired file comes back as something else (the hash doesn't match): the same case
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
			errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) || errors.Is(err, whatsmeow.ErrInvalidMediaEncSHA256) {
			if mk := mediaKeyOf(inner); mk != nil {
				info := types.MessageInfo{ID: t.m.MsgID, MessageSource: types.MessageSource{Chat: t.chat, Sender: t.sender, IsFromMe: t.m.FromMe,
					IsGroup: t.chat.Server == types.GroupServer}}
				if a.client.SendMediaRetryReceipt(ctx, &info, mk) == nil {
					t.m.MediaData.MediaStage = "NEED_POKE"
					a.core.store.updateMsg(t.m)
					a.emitMsg("Msg:change", t.m)
					return a.handOut(t.m), nil
				}
			}
		}
		t.m.MediaData.MediaStage = "ERROR_MISSING"
		a.core.store.updateMsg(t.m)
		a.emitMsg("Msg:change", t.m)
		return t.m, err
	}
	p, ok := a.mediaPath(t.m, data)
	if !ok {
		return t.m, errors.New("cannot write the media file")
	}
	t.m.MediaData.RenderableURL, t.m.MediaData.MediaStage = p, "RESOLVED"
	a.core.store.updateMsg(t.m)
	a.emitMsg("Msg:change", t.m)
	return a.handOut(t.m), nil
}

// fetchThumbnail: the high-quality thumbnail WhatsApp keeps on its media servers (the one WhatsApp
// Web shows for videos, documents and pictures before they are opened): the inline one is ~100 px.
// fetchLinkThumb: the large picture of a link preview (encrypted, like media: "thumbnail-link").
func (a *Account) fetchLinkThumb(t target) (Msg, error) {
	var raw waE2E.Message
	if proto.Unmarshal(t.raw, &raw) != nil {
		return t.m, errors.New("the original message is not stored")
	}
	inner, _ := unwrap(&raw)
	e := inner.GetExtendedTextMessage()
	if e == nil || e.GetThumbnailDirectPath() == "" { // only the small inline picture
		return a.handOut(t.m), nil
	}
	t.m.LinkHQ, t.m.ThumbWidth, t.m.ThumbHeight = true, int(e.GetThumbnailWidth()), int(e.GetThumbnailHeight())
	if e.PreviewType != nil {
		t.m.PreviewType = e.GetPreviewType().String()
	}
	data, err := a.client.DownloadThumbnail(ctx, e)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: link thumbnail:", err)
		return a.handOut(t.m), nil
	}
	dir := filepath.Join(a.core.cacheDir, "thumbs")
	os.MkdirAll(dir, 0o700)
	sum := sha256.Sum256([]byte(t.m.Account + t.m.ID))
	p := filepath.Join(dir, hex.EncodeToString(sum[:12])+"-link.jpg")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return a.handOut(t.m), err
	}
	t.m.LinkThumb = p
	a.core.store.updateMsg(t.m)
	m := a.handOut(t.m)
	a.emitMsg("Msg:change", m)
	return m, nil
}

func (a *Account) fetchThumbnail(key string) (Msg, error) {
	t, err := a.target(key)
	if err != nil {
		return Msg{}, err
	}
	if t.m.Type == "chat" && t.m.LinkThumb == "" && (t.m.LinkHQ || t.m.MatchedText != "") { // a link preview's large picture
		return a.fetchLinkThumb(t)
	}
	if t.m.MediaData == nil || t.m.MediaData.ThumbnailHQ != "" {
		return a.handOut(t.m), nil
	}
	var raw waE2E.Message
	if proto.Unmarshal(t.raw, &raw) != nil {
		return t.m, errors.New("the original message is not stored")
	}
	inner, _ := unwrap(&raw)
	var th whatsmeow.DownloadableThumbnail
	switch {
	case inner.GetVideoMessage() != nil:
		th = inner.GetVideoMessage()
	case inner.GetImageMessage() != nil:
		th = inner.GetImageMessage()
	case inner.GetDocumentMessage() != nil:
		th = inner.GetDocumentMessage()
	}
	dir := filepath.Join(a.core.cacheDir, "thumbs")
	os.MkdirAll(dir, 0o700)
	sum := sha256.Sum256([]byte(t.m.Account + t.m.ID))
	p := filepath.Join(dir, hex.EncodeToString(sum[:12])+".jpg")
	if th != nil && th.GetThumbnailDirectPath() != "" {
		data, err := a.client.DownloadThumbnail(ctx, th)
		if err == nil {
			err = os.WriteFile(p, data, 0o600)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: HQ thumbnail:", err)
			p = ""
		}
	} else {
		p = ""
	}
	// most videos carry only the ~100 px inline thumbnail: a short one is fetched whole (it opens at
	// once then) and a frame of it becomes the thumbnail — when ffmpeg is installed
	if p == "" && t.m.Type == "video" && t.m.MediaData.Size <= 20<<20 {
		m, err := a.downloadMedia(key)
		if err != nil || m.MediaData == nil || m.MediaData.RenderableURL == "" {
			return t.m, err
		}
		frame := filepath.Join(dir, hex.EncodeToString(sum[:12])+"-frame.jpg")
		if videoFrame(m.MediaData.RenderableURL, frame) {
			p = frame
		}
		t.m = m
	}
	if p == "" {
		return a.handOut(t.m), nil // only the inline one exists
	}
	t.m.MediaData.ThumbnailHQ = p
	a.core.store.updateMsg(t.m)
	a.emitMsg("Msg:change", t.m)
	return a.handOut(t.m), nil
}

// videoFrame: a frame from early in a video as a 640 px JPEG (ffmpeg, when it is installed).
func videoFrame(video, out string) bool {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		return false
	}
	cmd := exec.Command(ff, "-loglevel", "error", "-y", "-ss", "0.3", "-i", video, "-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "3", out)
	return cmd.Run() == nil
}

func mediaKeyOf(m *waE2E.Message) []byte {
	switch {
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetMediaKey()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetMediaKey()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage().GetMediaKey()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetMediaKey()
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage().GetMediaKey()
	case m.GetPtvMessage() != nil:
		return m.GetPtvMessage().GetMediaKey()
	}
	return nil
}

func setDirectPath(m *waE2E.Message, p string) {
	switch {
	case m.GetImageMessage() != nil:
		m.ImageMessage.DirectPath = &p
	case m.GetVideoMessage() != nil:
		m.VideoMessage.DirectPath = &p
	case m.GetAudioMessage() != nil:
		m.AudioMessage.DirectPath = &p
	case m.GetDocumentMessage() != nil:
		m.DocumentMessage.DirectPath = &p
	case m.GetStickerMessage() != nil:
		m.StickerMessage.DirectPath = &p
	case m.GetPtvMessage() != nil:
		m.PtvMessage.DirectPath = &p
	}
}

// onMediaRetry: the sender's phone uploaded the media again: new path, download now.
func (a *Account) onMediaRetry(e *events.MediaRetry) {
	remote := a.canonical(e.ChatID).String()
	m, raw, ok := a.core.store.msgByID(a.ID, remote, e.MessageID)
	if !ok {
		return
	}
	var full waE2E.Message
	if proto.Unmarshal(raw, &full) != nil {
		return
	}
	inner, _ := unwrap(&full)
	res, err := whatsmeow.DecryptMediaRetryNotification(e, mediaKeyOf(inner))
	if err != nil || res.GetDirectPath() == "" {
		if m.MediaData != nil {
			m.MediaData.MediaStage = "ERROR_MISSING"
			a.core.store.updateMsg(m)
			a.emitMsg("Msg:change", m)
		}
		return
	}
	setDirectPath(inner, res.GetDirectPath())
	b, _ := proto.Marshal(&full)
	a.core.store.db.Exec(`UPDATE msgs SET raw=? WHERE account=? AND key=?`, b, a.ID, m.ID)
	go a.downloadMedia(m.ID)
}

// ---- contacts and groups ---------------------------------------------------------------------------

// sendQueryGroup (WAWebGroupQueryBridge): the group's metadata from the server, stored.
func (a *Account) sendQueryGroup(id string) (GroupMetadata, error) {
	j, err := parseJID(id)
	if err != nil {
		return GroupMetadata{}, err
	}
	gi, err := a.client.GetGroupInfo(ctx, j)
	if err != nil {
		return GroupMetadata{}, err
	}
	g := a.groupFrom(gi)
	a.core.store.putGroup(g)
	a.core.emit("GroupMetadata:change", g)
	a.emitChat(id) // whether we may still write there (admins only, or left)
	return g, nil
}

// requestProfilePicFromServer (WAWebContactProfilePicThumbBridge): the picture, as a cached file.
func (a *Account) requestProfilePicFromServer(id string) (Contact, error) {
	j, err := parseJID(id)
	if err != nil {
		return Contact{}, err
	}
	c := a.core.store.contact(a.ID, id)
	if c.ProfilePicThumb == "-" {
		return c, nil
	}
	if c.ProfilePicThumb != "" {
		if _, err := os.Stat(c.ProfilePicThumb); err == nil {
			return c, nil
		}
	}
	info, err := a.client.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil {
		return c, err
	}
	if info == nil { // no picture, or hidden from us
		a.core.store.setContact(a.ID, id, "pic", "-")
		return a.core.store.contact(a.ID, id), nil
	}
	data, err := httpGet(info.URL) // a plain CDN link: profile pictures are not encrypted
	if err != nil {
		return c, err
	}
	dir := filepath.Join(a.core.cacheDir, "pics")
	os.MkdirAll(dir, 0o700)
	p := filepath.Join(dir, strings.NewReplacer("@", "_", ":", "_").Replace(id)+"-"+info.ID+".jpg")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return c, err
	}
	a.core.store.setContact(a.ID, id, "pic", p)
	c = a.core.store.contact(a.ID, id)
	a.core.emit("Contact:change", c)
	return c, nil
}

// profilePicFull: the full-size picture (the info drawer's), as a cached file; "" when there is none.
func (a *Account) profilePicFull(id string) (string, error) {
	j, err := parseJID(id)
	if err != nil {
		return "", err
	}
	info, err := a.client.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: false})
	if err != nil || info == nil {
		return "", err
	}
	dir := filepath.Join(a.core.cacheDir, "pics")
	os.MkdirAll(dir, 0o700)
	p := filepath.Join(dir, strings.NewReplacer("@", "_", ":", "_").Replace(id)+"-full-"+info.ID+".jpg")
	if _, err := os.Stat(p); err == nil {
		return p, nil
	}
	data, err := httpGet(info.URL)
	if err != nil {
		return "", err
	}
	return p, os.WriteFile(p, data, 0o600)
}

// fetchBusinessNames: the verified names of the 1:1 chats with no name of their own (business
// accounts not in the address book), as WhatsApp Web's contact query brings them; in batches.
func (a *Account) fetchBusinessNames() {
	var todo []types.JID
	for _, c := range a.core.store.chats(a.ID) {
		if !strings.HasSuffix(c.ID, "@"+types.DefaultUserServer) {
			continue
		}
		k := a.core.store.contact(a.ID, c.ID)
		if k.Name != "" || k.VerifiedName != "" {
			continue
		}
		if j, err := parseJID(c.ID); err == nil {
			todo = append(todo, j)
		}
	}
	for len(todo) > 0 && a.client.IsConnected() {
		n := min(len(todo), 50)
		res, err := a.client.GetUserInfo(ctx, todo[:n])
		todo = todo[n:]
		if err != nil {
			continue
		}
		for j, ui := range res {
			if ui.VerifiedName == nil || ui.VerifiedName.Details == nil || ui.VerifiedName.Details.GetVerifiedName() == "" {
				continue
			}
			id := j.ToNonAD().String()
			a.core.store.setContact(a.ID, id, "verifiedName", ui.VerifiedName.Details.GetVerifiedName())
			a.core.store.setContact(a.ID, id, "isBusiness", 1)
			a.core.emit("Contact:change", a.core.store.contact(a.ID, id))
			a.emitChat(id)
		}
		time.Sleep(time.Second)
	}
}

// getStatus (WAWebContactStatusBridge): the contact's "about" text.
func (a *Account) getStatus(id string) (Contact, error) {
	j, err := parseJID(id)
	if err != nil {
		return Contact{}, err
	}
	res, err := a.client.GetUserInfo(ctx, []types.JID{j})
	if err != nil {
		return Contact{}, err
	}
	if ui, ok := res[j]; ok {
		a.core.store.setContact(a.ID, id, "status", ui.Status)
		if ui.VerifiedName != nil && ui.VerifiedName.Details != nil {
			a.core.store.setContact(a.ID, id, "verifiedName", ui.VerifiedName.Details.GetVerifiedName())
			a.core.store.setContact(a.ID, id, "isBusiness", 1)
		}
	}
	c := a.core.store.contact(a.ID, id)
	a.core.emit("Contact:change", c)
	return c, nil
}

// rejectCall: offer receipt already sent on arrival; now the rejection.
func (a *Account) rejectCall(callID, from string) error {
	j, err := parseJID(from)
	if err != nil {
		return err
	}
	return a.client.RejectCall(ctx, j, callID)
}

// pictureInfo: a photo's size and the small JPEG thumbnail WhatsApp sends inline (72 px wide).
func pictureInfo(data []byte) (w, h uint32, thumb []byte) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return 0, 0, nil
	}
	b := img.Bounds()
	w, h = uint32(b.Dx()), uint32(b.Dy())
	tw := 72
	th := max(1, tw*b.Dy()/max(1, b.Dx()))
	small := image.NewRGBA(image.Rect(0, 0, tw, th))
	for y := 0; y < th; y++ {
		for x := 0; x < tw; x++ {
			small.Set(x, y, img.At(b.Min.X+x*b.Dx()/tw, b.Min.Y+y*b.Dy()/th))
		}
	}
	var buf bytes.Buffer
	if jpeg.Encode(&buf, small, &jpeg.Options{Quality: 60}) == nil {
		thumb = buf.Bytes()
	}
	return w, h, thumb
}

func httpGet(url string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second, Transport: chromeTransport{base: http.DefaultTransport}}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// offerReceiptNode: <receipt id to><offer call-id call-creator/></receipt>, as WhatsApp Web sends.
func offerReceiptNode(id string, meta types.BasicCallMeta) waBinary.Node {
	return waBinary.Node{
		Tag:   "receipt",
		Attrs: waBinary.Attrs{"id": id, "to": meta.From},
		Content: []waBinary.Node{{
			Tag:   "offer",
			Attrs: waBinary.Attrs{"call-id": meta.CallID, "call-creator": meta.CallCreator},
		}},
	}
}
