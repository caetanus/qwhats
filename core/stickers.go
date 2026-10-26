package main

// Stickers: the panel's recent stickers and sending one again. A sticker WhatsApp already has is
// sent with the same file (its direct path, keys and hash), as WhatsApp Web does — no re-upload.

import (
	"encoding/hex"
	"errors"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

// stickerList: the stickers sent and received, newest first, each file once.
func (a *Account) stickerList(limit int) []Msg {
	if limit <= 0 || limit > 200 {
		limit = 80
	}
	seen := map[string]bool{}
	out := []Msg{}
	for _, m := range a.core.store.msgList(`SELECT json FROM msgs WHERE account=? AND type='sticker' ORDER BY t DESC LIMIT 600`, a.ID) {
		_, raw, ok := a.core.store.msg(a.ID, m.ID)
		if !ok || len(raw) == 0 {
			continue
		}
		var orig waE2E.Message
		if proto.Unmarshal(raw, &orig) != nil {
			continue
		}
		inner, _ := unwrap(&orig)
		st := inner.GetStickerMessage()
		if st == nil || st.GetMimetype() == "application/was" { // Lottie stickers: not drawable here
			continue
		}
		k := hex.EncodeToString(st.GetFileSHA256())
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, a.handOut(m))
		if len(out) >= limit {
			break
		}
	}
	return out
}

// sendSticker: a stored sticker, sent to a chat.
func (a *Account) sendSticker(chatID, key string) (Msg, error) {
	t, err := a.target(key)
	if err != nil {
		return Msg{}, err
	}
	var orig waE2E.Message
	if len(t.raw) == 0 || proto.Unmarshal(t.raw, &orig) != nil {
		return Msg{}, errors.New("sticker not stored")
	}
	inner, _ := unwrap(&orig)
	if inner.GetStickerMessage() == nil {
		return Msg{}, errors.New("not a sticker")
	}
	st := proto.Clone(inner.GetStickerMessage()).(*waE2E.StickerMessage)
	st.ContextInfo = nil
	if exp := a.chatEphemeral(chatID); exp > 0 {
		st.ContextInfo = &waE2E.ContextInfo{Expiration: proto.Uint32(exp)}
	}
	chat, err := parseJID(chatID)
	if err != nil {
		return Msg{}, err
	}
	m, err := a.send(chat, &waE2E.Message{StickerMessage: st}, "")
	if err != nil {
		return Msg{}, err
	}
	if t.m.MediaData != nil && t.m.MediaData.RenderableURL != "" && m.MediaData != nil {
		m.MediaData.RenderableURL, m.MediaData.MediaStage = t.m.MediaData.RenderableURL, "RESOLVED"
		a.core.store.updateMsg(m)
		a.emitMsg("Msg:change", m)
	}
	return m, nil
}
