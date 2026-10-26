package main

// The one place where WhatsApp's protobuf becomes WhatsApp Web's Msg model (docs/native-client.md).
// A waE2E.Message is either a message (Msg, with WAWebMsgType's `type` and WAWebCommonMsgSubtype's
// `subtype`) or an add-on that changes another message (reaction, edit, revoke). Nothing past this
// file sees a protobuf.

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
)

func b64(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

// unwrap: the content inside WhatsApp's envelopes (ephemeral, view-once, edited, document with
// caption, FutureProof wrappers). whatsmeow unwraps some of these for live messages; history and
// quotes arrive wrapped, and WhatsApp Web unwraps more kinds than whatsmeow does.
func unwrap(m *waE2E.Message) (inner *waE2E.Message, viewOnce bool) {
	for i := 0; m != nil && i < 8; i++ {
		var next *waE2E.FutureProofMessage
		switch {
		case m.GetDeviceSentMessage() != nil:
			m = m.GetDeviceSentMessage().GetMessage()
			continue
		case m.GetEphemeralMessage() != nil:
			next = m.GetEphemeralMessage()
		case m.GetViewOnceMessage() != nil:
			next, viewOnce = m.GetViewOnceMessage(), true
		case m.GetViewOnceMessageV2() != nil:
			next, viewOnce = m.GetViewOnceMessageV2(), true
		case m.GetViewOnceMessageV2Extension() != nil:
			next, viewOnce = m.GetViewOnceMessageV2Extension(), true
		case m.GetDocumentWithCaptionMessage() != nil:
			next = m.GetDocumentWithCaptionMessage()
		case m.GetEditedMessage() != nil:
			next = m.GetEditedMessage()
		case m.GetGroupMentionedMessage() != nil:
			next = m.GetGroupMentionedMessage()
		case m.GetBotInvokeMessage() != nil:
			next = m.GetBotInvokeMessage()
		case m.GetLottieStickerMessage() != nil:
			next = m.GetLottieStickerMessage()
		case m.GetEventCoverImage() != nil:
			next = m.GetEventCoverImage()
		case m.GetPollCreationMessageV4() != nil:
			next = m.GetPollCreationMessageV4()
		case m.GetAssociatedChildMessage() != nil:
			next = m.GetAssociatedChildMessage()
		case m.GetSpoilerMessage() != nil:
			next = m.GetSpoilerMessage()
		case m.GetQuestionMessage() != nil:
			next = m.GetQuestionMessage()
		case m.GetAudioStickerMessage() != nil:
			next = m.GetAudioStickerMessage()
		case m.GetBotForwardedMessage() != nil:
			next = m.GetBotForwardedMessage()
		case m.GetNewsletterScheduledMessage() != nil:
			next = m.GetNewsletterScheduledMessage()
		}
		if next == nil || next.GetMessage() == nil {
			return m, viewOnce
		}
		m = next.GetMessage()
	}
	return m, viewOnce
}

// context: the ContextInfo of whichever kind the message is.
func contextOf(m *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetContextInfo()
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetContextInfo()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetContextInfo()
	case m.GetPtvMessage() != nil:
		return m.GetPtvMessage().GetContextInfo()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage().GetContextInfo()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetContextInfo()
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage().GetContextInfo()
	case m.GetLocationMessage() != nil:
		return m.GetLocationMessage().GetContextInfo()
	case m.GetLiveLocationMessage() != nil:
		return m.GetLiveLocationMessage().GetContextInfo()
	case m.GetContactMessage() != nil:
		return m.GetContactMessage().GetContextInfo()
	case m.GetContactsArrayMessage() != nil:
		return m.GetContactsArrayMessage().GetContextInfo()
	case m.GetPollCreationMessage() != nil:
		return m.GetPollCreationMessage().GetContextInfo()
	case m.GetPollCreationMessageV3() != nil:
		return m.GetPollCreationMessageV3().GetContextInfo()
	}
	return nil
}

// content: type, text and media of a message, without its envelope. ok=false: not a message
// (protocol, add-on, or a kind we do not render).
func content(m *waE2E.Message) (n Msg, ok bool) {
	m, viewOnce := unwrap(m)
	if m == nil {
		return n, false
	}
	switch {
	case m.Conversation != nil:
		n.Type, n.Body = "chat", m.GetConversation()
	case m.ExtendedTextMessage != nil:
		e := m.GetExtendedTextMessage()
		n.Type, n.Body = "chat", e.GetText()
		n.MatchedText, n.Title, n.Description, n.Thumbnail = e.GetMatchedText(), e.GetTitle(), e.GetDescription(), b64(e.GetJPEGThumbnail())
		if e.GetThumbnailDirectPath() != "" {
			n.LinkHQ, n.ThumbWidth, n.ThumbHeight = true, int(e.GetThumbnailWidth()), int(e.GetThumbnailHeight())
		}
		if e.PreviewType != nil {
			n.PreviewType = e.GetPreviewType().String()
		}
		if bg := e.GetBackgroundArgb(); bg != 0 {
			// no text colour (absent, or alpha 0) is white, as WhatsApp draws it — not invisible
			fg := e.GetTextArgb()
			if fg>>24 == 0 {
				fg = 0xFFFFFFFF
			}
			n.BackgroundColor, n.TextColor, n.Font = fmt.Sprintf("#%08X", bg), fmt.Sprintf("#%08X", fg), int(e.GetFont())
		}
	case m.RichResponseMessage != nil: // Meta AI's answers
		n.Type, n.Body = "chat", richText(m.GetRichResponseMessage())
	case m.ButtonsMessage != nil:
		x := m.GetButtonsMessage()
		n.Type, n.Body, n.Footer = "chat", joinText(x.GetText(), x.GetContentText()), x.GetFooterText()
		for _, b := range x.GetButtons() {
			if t := b.GetButtonText().GetDisplayText(); t != "" {
				n.Buttons = append(n.Buttons, Button{Kind: "reply", Text: t, Value: b.GetButtonID()})
			} else if nf := b.GetNativeFlowInfo(); nf != nil {
				n.Buttons = append(n.Buttons, flowButton(nf.GetName(), nf.GetParamsJSON()))
			}
		}
	case m.TemplateMessage != nil:
		t := m.GetTemplateMessage().GetHydratedTemplate()
		if t == nil {
			t = m.GetTemplateMessage().GetHydratedFourRowTemplate()
		}
		n.Type, n.Body, n.Footer = "chat", joinText(t.GetHydratedTitleText(), t.GetHydratedContentText()), t.GetHydratedFooterText()
		for _, b := range t.GetHydratedButtons() {
			switch {
			case b.GetQuickReplyButton() != nil:
				n.Buttons = append(n.Buttons, Button{Kind: "reply", Text: b.GetQuickReplyButton().GetDisplayText(), Value: b.GetQuickReplyButton().GetID()})
			case b.GetUrlButton() != nil:
				n.Buttons = append(n.Buttons, Button{Kind: "url", Text: b.GetUrlButton().GetDisplayText(), Value: b.GetUrlButton().GetURL()})
			case b.GetCallButton() != nil:
				n.Buttons = append(n.Buttons, Button{Kind: "call", Text: b.GetCallButton().GetDisplayText(), Value: b.GetCallButton().GetPhoneNumber()})
			}
		}
	case m.InteractiveMessage != nil:
		x := m.GetInteractiveMessage()
		n.Type, n.Body, n.Footer = "chat", joinText(x.GetHeader().GetTitle(), x.GetBody().GetText()), x.GetFooter().GetText()
		for _, b := range x.GetNativeFlowMessage().GetButtons() {
			n.Buttons = append(n.Buttons, flowButton(b.GetName(), b.GetButtonParamsJSON()))
		}
	case m.ListMessage != nil:
		x := m.GetListMessage()
		n.Type, n.Body, n.Footer = "chat", joinText(x.GetTitle(), x.GetDescription()), x.GetFooterText()
		rows := []string{}
		for _, sec := range x.GetSections() {
			for _, r := range sec.GetRows() {
				rows = append(rows, r.GetTitle())
			}
		}
		n.Buttons = append(n.Buttons, Button{Kind: "list", Text: x.GetButtonText(), Value: strings.Join(rows, "\n")})
	// the answers to those: the chosen button's text
	case m.ButtonsResponseMessage != nil:
		n.Type, n.Body = "chat", m.GetButtonsResponseMessage().GetSelectedDisplayText()
	case m.TemplateButtonReplyMessage != nil:
		n.Type, n.Body = "chat", m.GetTemplateButtonReplyMessage().GetSelectedDisplayText()
	case m.ListResponseMessage != nil:
		n.Type, n.Body = "chat", m.GetListResponseMessage().GetTitle()
	case m.InteractiveResponseMessage != nil:
		n.Type, n.Body = "chat", m.GetInteractiveResponseMessage().GetBody().GetText()
	case m.ImageMessage != nil:
		x := m.GetImageMessage()
		n.Type, n.Caption = "image", x.GetCaption()
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Width: x.GetWidth(), Height: x.GetHeight(), Preview: b64(x.GetJPEGThumbnail())}
	case m.VideoMessage != nil:
		x := m.GetVideoMessage()
		n.Type, n.Caption = "video", x.GetCaption()
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Duration: x.GetSeconds(), Width: x.GetWidth(), Height: x.GetHeight(),
			Preview: b64(x.GetJPEGThumbnail()), IsGif: x.GetGifPlayback()}
	case m.PtvMessage != nil:
		x := m.GetPtvMessage()
		n.Type = "ptv"
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Duration: x.GetSeconds(), Width: x.GetWidth(), Height: x.GetHeight(), Preview: b64(x.GetJPEGThumbnail())}
	case m.AudioMessage != nil:
		x := m.GetAudioMessage()
		n.Type = "audio"
		// a voice note: flagged ptt, or recorded by WhatsApp (Ogg/Opus with a waveform) — some come
		// without the flag and WhatsApp Web still shows them as voice notes
		if x.GetPTT() || (len(x.GetWaveform()) > 0 && strings.Contains(x.GetMimetype(), "opus")) {
			n.Type = "ptt"
		}
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Duration: x.GetSeconds(), Waveform: b64(x.GetWaveform())}
	case m.DocumentMessage != nil:
		x := m.GetDocumentMessage()
		n.Type, n.Caption = "document", x.GetCaption()
		name := x.GetFileName()
		if name == "" {
			name = x.GetTitle()
		}
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Filename: name, PageCount: x.GetPageCount(), Preview: b64(x.GetJPEGThumbnail())}
	case m.StickerMessage != nil:
		x := m.GetStickerMessage()
		n.Type = "sticker"
		n.MediaData = &MediaData{Mimetype: x.GetMimetype(), Size: x.GetFileLength(), Width: x.GetWidth(), Height: x.GetHeight(), IsAnimated: x.GetIsAnimated()}
	case m.LocationMessage != nil:
		x := m.GetLocationMessage()
		n.Type, n.Lat, n.Lng = "location", x.GetDegreesLatitude(), x.GetDegreesLongitude()
		n.Loc = strings.TrimSpace(x.GetName() + "\n" + x.GetAddress())
		n.Thumbnail = b64(x.GetJPEGThumbnail())
	case m.LiveLocationMessage != nil:
		x := m.GetLiveLocationMessage()
		n.Type, n.Lat, n.Lng, n.IsLive, n.Caption = "location", x.GetDegreesLatitude(), x.GetDegreesLongitude(), true, x.GetCaption()
		n.Thumbnail = b64(x.GetJPEGThumbnail())
	case m.ContactMessage != nil:
		x := m.GetContactMessage()
		n.Type, n.VcardList = "vcard", []Vcard{{DisplayName: x.GetDisplayName(), Vcard: x.GetVcard()}}
	case m.ContactsArrayMessage != nil:
		x := m.GetContactsArrayMessage()
		n.Type = "multi_vcard"
		for _, c := range x.GetContacts() {
			n.VcardList = append(n.VcardList, Vcard{DisplayName: c.GetDisplayName(), Vcard: c.GetVcard()})
		}
	case m.PollCreationMessage != nil || m.PollCreationMessageV2 != nil || m.PollCreationMessageV3 != nil:
		p := m.GetPollCreationMessage()
		if p == nil {
			p = m.GetPollCreationMessageV2()
		}
		if p == nil {
			p = m.GetPollCreationMessageV3()
		}
		n.Type, n.PollName, n.PollSelectableOptionsCount = "poll_creation", p.GetName(), p.GetSelectableOptionsCount()
		for i, o := range p.GetOptions() {
			n.PollOptions = append(n.PollOptions, PollOption{LocalID: i, Name: o.GetOptionName()})
		}
	case m.ProtocolMessage != nil && m.GetProtocolMessage().GetType() == waE2E.ProtocolMessage_EPHEMERAL_SETTING:
		n.Type, n.Subtype = "notification_template", "ephemeral_setting"
		n.EphemeralDuration = m.GetProtocolMessage().GetEphemeralExpiration()
		n.TemplateParams = []string{fmt.Sprint(n.EphemeralDuration)}
	default:
		return n, false
	}
	if n.MediaData != nil {
		n.MediaData.MediaStage = "INIT"
		n.MediaData.IsViewOnce = viewOnce
	}
	if ci := contextOf(m); ci != nil {
		n.MentionedJidList = ci.GetMentionedJID()
		n.IsForwarded, n.ForwardingScore = ci.GetIsForwarded(), ci.GetForwardingScore()
		n.EphemeralDuration = max(n.EphemeralDuration, ci.GetExpiration())
		if ci.GetStanzaID() != "" {
			q := &QuotedMsg{ID: ci.GetStanzaID(), Author: ci.GetParticipant()}
			if qm := ci.GetQuotedMessage(); qm != nil {
				if qn, ok := content(qm); ok {
					q.Type, q.Body = qn.Type, previewBody(qn)
				}
			}
			n.QuotedMsg, n.QuotedRemoteJid = q, ci.GetRemoteJID()
		}
	}
	return n, true
}

// addon: a reaction, an edit or a revoke; ok=false when the message is none of them.
func addon(m *waE2E.Message) (a Addon, ok bool) {
	m, _ = unwrap(m)
	switch {
	case m.GetReactionMessage() != nil:
		r := m.GetReactionMessage()
		return Addon{Kind: "reaction", ParentID: r.GetKey().GetID(), Text: r.GetText(), T: r.GetSenderTimestampMS() / 1000}, true
	case m.GetProtocolMessage() != nil:
		p := m.GetProtocolMessage()
		switch p.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			return Addon{Kind: "revoke", ParentID: p.GetKey().GetID()}, true
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			e, ok := content(p.GetEditedMessage())
			if !ok {
				return a, false
			}
			return Addon{Kind: "edit", ParentID: p.GetKey().GetID(), Edited: &e, T: p.GetTimestampMS() / 1000}, true
		}
	}
	return a, false
}

// previewBody: the one-line text WhatsApp Web shows for a message in the chat list, quotes and
// notifications (the UI adds the icon for the type).
func previewBody(n Msg) string {
	switch {
	case n.Type == "chat":
		return n.Body
	case n.Caption != "":
		return n.Caption
	case n.Type == "document" && n.MediaData != nil:
		return n.MediaData.Filename
	case n.Type == "vcard" || n.Type == "multi_vcard":
		names := []string{}
		for _, v := range n.VcardList {
			names = append(names, v.DisplayName)
		}
		return strings.Join(names, ", ")
	case n.Type == "poll_creation":
		return n.PollName
	case n.Type == "location":
		return strings.SplitN(n.Loc, "\n", 2)[0]
	}
	return ""
}

// envelope: the parts of the Msg that come from who/where/when, not from the content.
func envelope(n *Msg, account string, info types.MessageInfo, remote, author string) {
	n.Account = account
	n.Remote = remote
	n.MsgID = info.ID
	n.FromMe = info.IsFromMe
	n.T = info.Timestamp.Unix()
	n.NotifyName = info.PushName
	// groups and broadcasts (status updates included) say who wrote each message
	if remote != "" && (strings.HasSuffix(remote, "@"+types.GroupServer) || strings.HasSuffix(remote, "@"+types.BroadcastServer)) {
		n.Author = author
	}
	if n.FromMe {
		n.From, n.To = author, remote
		n.Ack = AckSent
	} else {
		n.From, n.To = remote, ""
		n.Ack = AckReceived
	}
	n.ID = msgKey(n.FromMe, remote, info.ID, author)
}

// stubOf: WhatsApp Web's (type, subtype) for a history system message (WebMessageInfo.messageStubType).
func stubOf(t waWeb.WebMessageInfo_StubType) (typ, subtype string) {
	switch t {
	case waWeb.WebMessageInfo_GROUP_CREATE:
		return "gp2", "create"
	case waWeb.WebMessageInfo_GROUP_CHANGE_SUBJECT:
		return "gp2", "subject"
	case waWeb.WebMessageInfo_GROUP_CHANGE_DESCRIPTION:
		return "gp2", "description"
	case waWeb.WebMessageInfo_GROUP_CHANGE_ICON:
		return "gp2", "picture"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_ADD:
		return "gp2", "add"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_REMOVE:
		return "gp2", "remove"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_LEAVE:
		return "gp2", "leave"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_INVITE:
		return "gp2", "invite"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_PROMOTE:
		return "gp2", "promote"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_DEMOTE:
		return "gp2", "demote"
	case waWeb.WebMessageInfo_GROUP_CHANGE_RESTRICT:
		return "gp2", "restrict"
	case waWeb.WebMessageInfo_GROUP_CHANGE_ANNOUNCE:
		return "gp2", "announce"
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_LINKED_GROUP_JOIN:
		return "gp2", "linked_group_join"
	case waWeb.WebMessageInfo_CHANGE_EPHEMERAL_SETTING:
		return "notification_template", "ephemeral_setting"
	case waWeb.WebMessageInfo_E2E_ENCRYPTED, waWeb.WebMessageInfo_E2E_ENCRYPTED_NOW:
		return "e2e_notification", "encrypt"
	case waWeb.WebMessageInfo_E2E_IDENTITY_CHANGED:
		return "e2e_notification", "identity"
	case waWeb.WebMessageInfo_CALL_MISSED_VOICE:
		return "call_log", "miss"
	case waWeb.WebMessageInfo_CALL_MISSED_VIDEO:
		return "call_log", "miss_video"
	case waWeb.WebMessageInfo_CALL_MISSED_GROUP_VOICE:
		return "call_log", "miss_group"
	case waWeb.WebMessageInfo_CALL_MISSED_GROUP_VIDEO:
		return "call_log", "miss_group_video"
	case waWeb.WebMessageInfo_REVOKE:
		return "revoked", "sender_revoke"
	}
	return "", ""
}

// ackOf: the history's WebMessageInfo.Status as WAWebAck.
func ackOf(s waWeb.WebMessageInfo_Status) int {
	switch s {
	case waWeb.WebMessageInfo_ERROR:
		return AckFailed
	case waWeb.WebMessageInfo_PENDING:
		return AckClock
	case waWeb.WebMessageInfo_SERVER_ACK:
		return AckSent
	case waWeb.WebMessageInfo_DELIVERY_ACK:
		return AckReceived
	case waWeb.WebMessageInfo_READ:
		return AckRead
	case waWeb.WebMessageInfo_PLAYED:
		return AckPlayed
	}
	return AckSent
}

// unwrapPin: the PinInChatMessage of a message, if it is one.
func unwrapPin(m *waE2E.Message) *waE2E.PinInChatMessage {
	inner, _ := unwrap(m)
	return inner.GetPinInChatMessage()
}

// richText: a Meta AI answer as text — its text parts, code as ``` blocks; the unified form's
// text fields when there are no parts.
func richText(r *waE2E.AIRichResponseMessage) string {
	var b strings.Builder
	for _, sm := range r.GetSubmessages() {
		switch {
		case sm.GetMessageText() != "":
			b.WriteString(sm.GetMessageText())
		case sm.GetTableMetadata() != nil:
			// a table as markdown rows (the UI draws `| … |` blocks as tables)
			tm := sm.GetTableMetadata()
			if tm.GetTitle() != "" {
				b.WriteString("*" + tm.GetTitle() + "*\n")
			}
			for i, r := range tm.GetRows() {
				b.WriteString("| " + strings.Join(r.GetItems(), " | ") + " |\n")
				if i == 0 && r.GetIsHeading() {
					b.WriteString("|" + strings.Repeat(" --- |", len(r.GetItems())) + "\n")
				}
			}
			continue
		case sm.GetCodeMetadata() != nil:
			b.WriteString("```")
			for _, blk := range sm.GetCodeMetadata().GetCodeBlocks() {
				b.WriteString(blk.GetCodeContent())
			}
			b.WriteString("```")
		default:
			continue
		}
		b.WriteString("\n")
	}
	if b.Len() == 0 {
		if d := r.GetUnifiedResponse().GetData(); len(d) > 0 {
			var v any
			if json.Unmarshal(d, &v) == nil {
				collectText(v, &b)
			}
		}
	}
	return strings.TrimSpace(b.String())
}

// joinText: a title and a text, a blank line between (either may be missing).
func joinText(title, text string) string {
	title, text = strings.TrimSpace(title), strings.TrimSpace(text)
	if title == "" || text == "" {
		return title + text
	}
	return "*" + title + "*\n\n" + text
}

// flowButton: a native-flow button (quick_reply, cta_url, cta_call, cta_copy, single_select, …) from
// its name and its parameters' JSON.
func flowButton(name, params string) Button {
	var p map[string]any
	json.Unmarshal([]byte(params), &p)
	str := func(k string) string { v, _ := p[k].(string); return v }
	b := Button{Kind: "reply", Text: str("display_text"), Value: str("id")}
	switch name {
	case "cta_url":
		b.Kind, b.Value = "url", str("url")
	case "cta_call":
		b.Kind, b.Value = "call", str("phone_number")
	case "cta_copy":
		b.Kind, b.Value = "copy", str("copy_code")
	case "single_select":
		b.Kind = "list"
		if b.Text == "" {
			b.Text = str("title")
		}
	}
	if b.Text == "" {
		b.Text = name
	}
	return b
}

// collectText: every "text" string in a JSON value, in order.
func collectText(v any, b *strings.Builder) {
	switch x := v.(type) {
	case map[string]any:
		if t, ok := x["text"].(string); ok && t != "" {
			b.WriteString(t)
			b.WriteString("\n")
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if k != "text" {
				collectText(x[k], b)
			}
		}
	case []any:
		for _, e := range x {
			collectText(e, b)
		}
	}
}
