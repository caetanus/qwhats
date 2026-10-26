package main

// --demo: a fake logged-in account with made-up chats and no network, for developing and
// screenshotting the UI without anyone's WhatsApp. It speaks the same API: the collections are
// real (a throwaway store), the actions change the store and emit the same events a real account
// would, and the "other side" answers a sent message (receipts, typing, a reply).

import (
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// demo/: made by tools/demo-media.sh (nobody's real files).
//
//go:embed demo
var demoMedia embed.FS

type demoMeta struct {
	Voice struct {
		Duration uint32 `json:"duration"`
		Waveform string `json:"waveform"`
	} `json:"voice"`
	Video struct {
		Duration      uint32 `json:"duration"`
		Width, Height uint32
	} `json:"video"`
	Photo struct{ Width, Height uint32 } `json:"photo"`
	PDF   struct {
		Pages uint32 `json:"pages"`
	} `json:"pdf"`
}

func demoThumb(name string) string {
	b, _ := demoMedia.ReadFile("demo/" + name)
	return base64.StdEncoding.EncodeToString(b)
}

func demoSize(name string) uint64 {
	b, _ := demoMedia.ReadFile("demo/" + name)
	return uint64(len(b))
}

// demoMediaMsg: "@voice", "@photo:caption", "@video", "@pdf", "@sticker" → the message's type and mediaData.
func demoMediaMsg(m *Msg, spec string) {
	var meta demoMeta
	b, _ := demoMedia.ReadFile("demo/meta.json")
	json.Unmarshal(b, &meta)
	kind, caption := split2(strings.TrimPrefix(spec, "@"))
	m.Body, m.Caption = "", caption
	switch kind {
	case "voice":
		m.Type = "ptt"
		m.MediaData = &MediaData{MediaStage: "INIT", Mimetype: "audio/ogg; codecs=opus", Size: demoSize("voice.ogg"),
			Duration: meta.Voice.Duration, Waveform: meta.Voice.Waveform, Filename: "voice.ogg"}
	case "photo":
		m.Type = "image"
		m.MediaData = &MediaData{MediaStage: "INIT", Mimetype: "image/jpeg", Size: demoSize("photo.jpg"), Width: meta.Photo.Width,
			Height: meta.Photo.Height, Preview: demoThumb("photo.thumb.jpg"), Filename: "photo.jpg"}
	case "video":
		m.Type = "video"
		m.MediaData = &MediaData{MediaStage: "INIT", Mimetype: "video/mp4", Size: demoSize("video.mp4"), Width: meta.Video.Width,
			Height: meta.Video.Height, Duration: meta.Video.Duration, Preview: demoThumb("video.thumb.jpg"), Filename: "video.mp4"}
	case "sticker":
		// a run of these shows the stickers side by side (the photo stands in for the artwork)
		m.Type = "sticker"
		m.MediaData = &MediaData{MediaStage: "INIT", Mimetype: "image/jpeg", Size: demoSize("photo.jpg"), Width: 512,
			Height: 512, Preview: demoThumb("photo.thumb.jpg"), Filename: "photo.jpg"}
	case "location":
		m.Type, m.Lat, m.Lng, m.Loc = "location", -23.5874, -46.6576, "Parque Ibirapuera\nAv. Pedro Álvares Cabral, São Paulo"
	case "contact":
		m.Type = "vcard"
		m.VcardList = []Vcard{{DisplayName: "Marina Lopes", Vcard: "BEGIN:VCARD\nVERSION:3.0\nFN:Marina Lopes\nTEL;type=CELL;waid=5511900000009:+55 11 90000-0009\nEND:VCARD"}}
	case "poll":
		m.Type, m.PollName, m.PollSelectableOptionsCount = "poll_creation", "Que horas no domingo?", 1
		for i, o := range []string{"12h", "13h", "14h"} {
			m.PollOptions = append(m.PollOptions, PollOption{LocalID: i, Name: o})
		}
	case "pdf":
		m.Type = "document"
		m.MediaData = &MediaData{MediaStage: "INIT", Mimetype: "application/pdf", Size: demoSize("relatorio.pdf"), PageCount: meta.PDF.Pages,
			Preview: demoThumb("relatorio.thumb.jpg"), Filename: "Relatório trimestral.pdf"}
	}
}

const demoMe = "5511999999999@s.whatsapp.net"

type demoChat struct {
	id, name string
	lines    []string // "me:…", "them:…", or "<Name>:…" in groups; "~sys:<subtype>:<who>" for system rows
}

var demoChats = []demoChat{
	{"5511900000001@s.whatsapp.net", "Ana Souza", []string{"them:Oi! Tudo bem?", "me:Tudo ótimo, e você?", "them:Bem também 😊 Vamos almoçar amanhã?", "me:Bora! 12h30 no lugar de sempre?", "them:Fechado", "them:@voice", "me:@voice", "them:@location", "them:@sticker", "them:@sticker", "them:@sticker", "them:@sticker", "them:@sticker", "them:Olha o cardápio: https://www.restaurante-exemplo.com.br/cardapio — *imperdível* o _risoto_, e ~nada~ caro"}},
	{"120363000000000001@g.us", "Família", []string{"~sys:create:Mãe", "Mãe:Bom dia, família! ☀️", "Pai:Bom dia!", "me:Bom dia 🙂", "Mãe:Domingo tem almoço aqui em casa", "Mãe:@photo:Olha que dia lindo ontem!", "Tio Zé:Levo a sobremesa", "Mãe:@poll"}},
	{"5511900000002@s.whatsapp.net", "Carlos (trabalho)", []string{"them:O relatório ficou pronto?", "me:Quase, te mando até as 17h. Ainda falta revisar a parte do orçamento e conferir os números do último trimestre com a equipe de finanças, mas deve dar tempo.", "them:Perfeito, obrigado", "me:@pdf", "them:@contact", "them:Segue o resumo da reunião de hoje, com os pontos principais que discutimos e as próximas etapas do projeto:\n\n1. Prazo final mantido para o fim do mês\n2. Revisão do orçamento na quinta-feira\n3. Apresentação para a diretoria na semana que vem"}},
	{"120363000000000002@g.us", "Corrida de domingo", []string{"Bia:Quem vai amanhã?", "Rafa:Eu!", "me:Também", "Bia:Encontro às 7h no parque", "Rafa:@video:o percurso de hoje"}},
	{"5511900000004@s.whatsapp.net", "Física (longa)", longChat()},
	{"5511900000003@s.whatsapp.net", "Dr. Paulo — consultório", []string{"them:Lembrete: consulta sexta-feira às 9h.", "me:Confirmado, obrigado!", "them:@buttons",
		"them:### Horários da semana\n| Dia | Manhã | Tarde |\n| --- | --- | --- |\n| Seg | 8h–12h | 14h–18h |\n| Qua | 9h–12h | — |\n| Sex | 8h–11h | 14h–17h |\n\n- **Retorno**: grátis em 30 dias\n- Traga os exames"}},
}

// longChat: a long conversation (runs of my messages, short and long ones) — what makes the
// message list scroll and recycle its rows.
func longChat() []string {
	texts := []string{
		"Vc sabe que existem experimentos demonstrando que partículas seguem aproximadamente as trajetórias descritas por Bohm entre um ponto e outro né?",
		"Que pelas equações de Lorentz, os fótons *não experimentam tempo", "Isso é um problema",
		"Então é totalmente necessário que haja um substrato pro éter", "Analisando a qft, há uns 16 éteres lá",
		"Que eles são campos", "Em suma, depende", "Sim, eu sei", "Eu nunca boto fé em bohm",
		"Deixa eu te explicar a simetria de gauge, que é o que faz a coisa toda funcionar e que a maioria das pessoas ignora completamente quando fala de física de partículas",
		"ok", "hmm", "E o colapso da função de onda?", "Não existe colapso na interpretação de muitos mundos",
	}
	out := []string{}
	for i := 0; i < 60; i++ {
		who := "them:"
		if (i/3)%2 == 1 {
			who = "me:"
		}
		out = append(out, who+texts[i%len(texts)])
	}
	return out
}

func demoJID(name string) string {
	h := 0
	for _, r := range name {
		h = (h*131 + int(r)) % 9000000
	}
	return "551180" + strconv.Itoa(1000000+h) + "@s.whatsapp.net"
}

func (c *Core) seedDemo() {
	s := c.store
	now := time.Now().Unix()
	for ci, dc := range demoChats {
		group := strings.HasSuffix(dc.id, "@g.us")
		base := now - int64(ci)*3600*5 - int64(len(dc.lines))*240
		s.ensureChat("main", dc.id)
		if group {
			s.setChatName("main", dc.id, dc.name)
			g := GroupMetadata{ID: dc.id, Account: "main", Subject: dc.name, Desc: "Grupo de exemplo do modo demo.", Participants: []Participant{{ID: demoMe}}}
			for _, l := range dc.lines {
				if who, _ := split2(l); who != "me" && who != "them" && who != "~sys" {
					dup := false
					for _, p := range g.Participants {
						dup = dup || p.ID == demoJID(who)
					}
					if !dup {
						g.Participants = append(g.Participants, Participant{ID: demoJID(who), IsAdmin: who == "Mãe" || who == "Bia"})
					}
				}
			}
			s.putGroup(g)
		} else {
			s.setContact("main", dc.id, "name", dc.name)
			s.setContact("main", dc.id, "status", "Disponível")
		}
		var keys []string
		for i, l := range dc.lines {
			who, text := split2(l)
			id := "DEMO" + strconv.Itoa(ci) + "X" + strconv.Itoa(i)
			m := Msg{Account: "main", Remote: dc.id, MsgID: id, T: base + int64(i)*240, Type: "chat", Body: text, Ack: AckRead}
			switch who {
			case "me":
				m.FromMe, m.From, m.To = true, demoMe, dc.id
			case "them":
				m.From, m.Ack = dc.id, AckReceived
			case "~sys":
				sub, by := split2(text)
				m.Type, m.Subtype, m.Body, m.Author, m.From = "gp2", sub, "", demoJID(by), dc.id
				m.TemplateParams = []string{demoJID(by)}
				s.setContact("main", demoJID(by), "name", by)
			default:
				m.From, m.Author, m.Ack = dc.id, demoJID(who), AckReceived
				s.setContact("main", m.Author, "name", who)
			}
			if m.Body == "@buttons" {
				// a business's message with buttons (an interactive message)
				m.Body, m.Footer = "*Confirme sua consulta*\n\nSexta-feira, 9h, com o Dr. Paulo.", "Consultório Dr. Paulo"
				m.Buttons = []Button{{Kind: "reply", Text: "Confirmar"}, {Kind: "reply", Text: "Remarcar"},
					{Kind: "url", Text: "Ver endereço", Value: "https://www.example.com/consultorio"}, {Kind: "copy", Text: "Copiar código", Value: "PAULO-0921"},
					{Kind: "list", Text: "Outros horários", Value: "Seg 8h\nQua 10h\nSex 14h"}}
			} else if strings.HasPrefix(m.Body, "@") {
				demoMediaMsg(&m, m.Body)
			}
			m.ID = msgKey(m.FromMe, dc.id, id, m.Author)
			s.putMsg(m, nil)
			keys = append(keys, m.ID)
		}
		s.db.Exec(`UPDATE chats SET t=? WHERE account='main' AND id=?`, base+int64(len(dc.lines)-1)*240, dc.id)
		if ci < 2 {
			s.setChat("main", dc.id, "unreadCount", 2-ci)
		}
		if ci == 1 {
			s.setChat("main", dc.id, "pin", now)
			// a reaction and a reply, so both show in the demo
			s.applyAddon("main", dc.id, Addon{Kind: "reaction", ParentID: "DEMO1X4", Sender: demoJID("Tio Zé"), Text: "❤️", T: now}, demoMe)
			s.applyAddon("main", dc.id, Addon{Kind: "reaction", ParentID: "DEMO1X4", Sender: demoJID("Pai"), Text: "❤️", T: now}, demoMe)
			if m, _, ok := s.msgByID("main", dc.id, "DEMO1X6"); ok {
				m.QuotedMsg = &QuotedMsg{ID: "DEMO1X4", Type: "chat", Body: "Domingo tem almoço aqui em casa", Author: demoJID("Mãe")}
				s.updateMsg(m)
			}
		}
		if ci == 4 {
			s.setChat("main", dc.id, "muteExpiration", -1)
		}
		_ = keys
	}
	c.demoExtras()
}

// demoExtras: a missed call and two status updates, so the Calls and Status tabs have something.
func (c *Core) demoExtras() {
	s := c.store
	now := time.Now().Unix()
	call := Msg{Account: "main", Remote: demoChats[2].id, MsgID: "DEMOCALL1", From: demoChats[2].id, T: now - 5400, Type: "call_log",
		Subtype: "miss", CallOutcome: "MISSED", Ack: AckReceived, TemplateParams: []string{demoChats[2].id}}
	call.ID = msgKey(false, call.Remote, call.MsgID, "")
	s.putMsg(call, nil)
	for i, st := range []struct{ who, kind, text string }{{demoChats[0].id, "@photo:Domingo na praia ☀️", ""}, {demoChats[0].id, "chat", "Bom dia! 🌻"}, {demoChats[2].id, "chat", "Partiu trabalho 💼"}} {
		m := Msg{Account: "main", Remote: "status@broadcast", MsgID: fmt.Sprintf("DEMOSTATUS%d", i), From: "status@broadcast", Author: st.who,
			T: now - int64(3600*(3-i)), Type: "chat", Body: st.text, Ack: AckReceived}
		if strings.HasPrefix(st.kind, "@") {
			demoMediaMsg(&m, st.kind)
		} else {
			m.BackgroundColor, m.TextColor = "#FF8E44AD", "#FFFFFFFF" // a text status on its colour
		}
		m.ID = msgKey(false, m.Remote, m.MsgID, m.Author)
		s.putMsg(m, nil)
	}
}

func split2(l string) (string, string) {
	if i := strings.Index(l, ":"); i >= 0 {
		return l[:i], l[i+1:]
	}
	return l, ""
}

// demoAction: the actions, done on the store only (no network), with the events a real account emits.
func (c *Core) demoAction(a *Account, method string, p params) (any, error) {
	s := c.store
	switch method {
	case "createGroup":
		id := "1203630000000099" + strconv.Itoa(int(time.Now().Unix()%1000)) + "@g.us"
		parts := []Participant{}
		for _, x := range p.Participants {
			parts = append(parts, Participant{ID: x})
		}
		s.putGroup(GroupMetadata{ID: id, Account: a.ID, Subject: p.Name, Participants: parts})
		s.setChatName(a.ID, id, p.Name)
		return a.openChat(id), nil
	case "connect":
		go func() {
			time.Sleep(50 * time.Millisecond)
			a.setState("CONNECTED")
		}()
		return P{"state": "CONNECTED"}, nil
	case "sendTextMsgToChat":
		if p.Chat == "" || p.Text == "" {
			return nil, errors.New("missing parameter")
		}
		id := fmt.Sprintf("DEMOSENT%d", time.Now().UnixNano())
		m := Msg{Account: a.ID, Remote: p.Chat, MsgID: id, ID: msgKey(true, p.Chat, id, ""), FromMe: true, From: demoMe, To: p.Chat,
			T: time.Now().Unix(), Type: "chat", Body: p.Text, Ack: AckClock, MentionedJidList: p.MentionedJidList}
		if p.QuotedMsg != "" {
			if q, _, ok := s.msg(a.ID, p.QuotedMsg); ok {
				m.QuotedMsg = &QuotedMsg{ID: q.MsgID, Type: q.Type, Body: previewBody(q), Author: q.Author}
			}
		}
		s.putMsg(m, nil)
		s.bumpChat(m, false, false)
		a.emitMsg("Msg:add", m)
		a.emitChat(p.Chat)
		go c.demoConversation(a, m)
		return a.handOut(m), nil
	case "sendMediaMsgToChat":
		return c.demoSendMedia(a, p)
	case "sendReactionToMsg":
		t, _, ok := s.msg(a.ID, p.Msg)
		if !ok {
			return nil, errors.New("no message")
		}
		if pm, ok := s.applyAddon(a.ID, t.Remote, Addon{Kind: "reaction", ParentID: t.MsgID, Sender: demoMe, FromMe: true, Text: p.ReactionText, T: time.Now().Unix()}, demoMe); ok {
			a.emitMsg("Msg:change", pm)
		}
		return true, nil
	case "sendRevoke":
		for _, k := range p.Msgs {
			if t, _, ok := s.msg(a.ID, k); ok {
				if pm, ok := s.applyAddon(a.ID, t.Remote, Addon{Kind: "revoke", ParentID: t.MsgID, Sender: demoMe, FromMe: true}, demoMe); ok {
					a.emitMsg("Msg:change", pm)
					a.emitChat(t.Remote)
				}
			}
		}
		return true, nil
	case "editMessage":
		t, _, ok := s.msg(a.ID, p.Msg)
		if !ok || !t.FromMe {
			return nil, errors.New("only your own messages can be edited")
		}
		e := Msg{Type: "chat", Body: p.Text}
		if pm, ok := s.applyAddon(a.ID, t.Remote, Addon{Kind: "edit", ParentID: t.MsgID, Sender: demoMe, FromMe: true, Edited: &e, T: time.Now().Unix()}, demoMe); ok {
			a.emitMsg("Msg:change", pm)
			a.emitChat(t.Remote)
		}
		return true, nil
	case "sendDeleteMsgs":
		for _, k := range p.Msgs {
			if t, _, ok := s.msg(a.ID, k); ok {
				s.deleteMsg(a.ID, k)
				c.emit("Msg:remove", P{"account": a.ID, "id": k, "remote": t.Remote})
				a.emitChat(t.Remote)
			}
		}
		return true, nil
	case "forwardMessages":
		out := []Msg{}
		for _, k := range p.Msgs {
			t, _, ok := s.msg(a.ID, k)
			if !ok {
				continue
			}
			for _, chat := range p.Chats {
				id := fmt.Sprintf("DEMOFWD%d", time.Now().UnixNano())
				f := t
				f.MsgID, f.ID, f.Remote, f.FromMe, f.From, f.To, f.Author = id, msgKey(true, chat, id, ""), chat, true, demoMe, chat, ""
				f.T, f.Ack, f.IsForwarded, f.ForwardingScore, f.QuotedMsg, f.Reactions, f.Star = time.Now().Unix(), AckSent, true, t.ForwardingScore+1, nil, nil, false
				s.putMsg(f, nil)
				s.bumpChat(f, false, false)
				a.emitMsg("Msg:add", f)
				a.emitChat(chat)
				out = append(out, a.handOut(f))
			}
		}
		return out, nil
	case "sendStarMsgs":
		for _, k := range p.Msgs {
			if t, _, ok := s.msg(a.ID, k); ok {
				t.Star = p.Star
				s.updateMsg(t)
				a.emitMsg("Msg:change", t)
			}
		}
		return true, nil
	case "setArchive":
		s.setChat(a.ID, p.Chat, "archive", b2i(p.Archive))
		if p.Archive {
			s.setChat(a.ID, p.Chat, "pin", 0)
		}
	case "setPin":
		v := int64(0)
		if p.Pin {
			v = time.Now().Unix()
		}
		s.setChat(a.ID, p.Chat, "pin", v)
	case "sendConversationMute":
		s.setChat(a.ID, p.Chat, "muteExpiration", p.Expiration)
	case "sendClear":
		a.cleared(p.Chat, time.Now().Unix(), p.KeepStarred)
		return true, nil
	case "sendDelete":
		a.cleared(p.Chat, time.Now().Unix(), false)
		s.setChat(a.ID, p.Chat, "deleted", 1)
		c.emit("Chat:remove", P{"account": a.ID, "id": p.Chat})
		return true, nil
	case "sendSeen":
		s.setChat(a.ID, p.Chat, "unreadCount", 0)
		s.setChat(a.ID, p.Chat, "unreadMentionCount", 0)
		s.setChat(a.ID, p.Chat, "markedUnread", 0)
	case "markUnread":
		s.setChat(a.ID, p.Chat, "markedUnread", 1)
	case "changeEphemeralDuration":
		s.setChat(a.ID, p.Chat, "ephemeralDuration", p.Duration)
	case "sendStatusMute":
		s.setStatusMuted(a.ID, p.ID, p.Muted)
		c.emit("Status:change", P{"account": a.ID, "id": p.ID})
		return true, nil
	case "markComposing", "markRecording", "markPaused", "markPlayed", "sendPresenceAvailable", "sendPresenceUnavailable", "subscribeUserPresence", "rejectCall":
		return true, nil
	case "loadEarlierMsgs":
		out := []Msg{}
		for _, m := range s.msgs(a.ID, p.Chat, p.Before, max(p.Limit, 50)) {
			out = append(out, a.handOut(m))
		}
		return out, nil
	case "downloadMedia":
		return c.demoDownload(a, p.Msg)
	case "fetchThumbnail":
		m, _, ok := s.msg(a.ID, p.Msg)
		if !ok || m.Type != "video" || m.MediaData == nil || m.MediaData.ThumbnailHQ != "" {
			return a.handOut(m), nil
		}
		if _, err := c.demoDownload(a, p.Msg); err != nil {
			return nil, err
		}
		m, _, _ = s.msg(a.ID, p.Msg)
		frame := filepath.Join(c.cacheDir, "thumbs", "demo-"+m.MsgID+".jpg")
		os.MkdirAll(filepath.Dir(frame), 0o700)
		if videoFrame(m.MediaData.RenderableURL, frame) {
			m.MediaData.ThumbnailHQ = frame
			s.updateMsg(m)
			a.emitMsg("Msg:change", m)
		}
		return a.handOut(m), nil
	case "profilePicFull":
		return P{"path": ""}, nil
	case "Newsletter.refresh":
		return []Msg{}, nil
	case "Channel.list":
		return []Channel{{ID: "120363000000000009@newsletter", Name: "Notícias do Bairro", Description: "Canal de exemplo do modo demo", Subscribers: 1280}}, nil
	case "requestProfilePicFromServer", "getStatus":
		return s.contact(a.ID, p.ID), nil
	case "sendQueryGroup":
		g, _ := s.group(a.ID, p.ID)
		return g, nil
	default:
		return nil, fmt.Errorf("method not available in the demo: %s", method)
	}
	if p.Chat != "" {
		a.emitChat(p.Chat)
	}
	return true, nil
}

// demoConversation: what the other side does with a sent message — sent, delivered, read, typing,
// and a reply.
func (c *Core) demoConversation(a *Account, m Msg) {
	s := c.store
	for _, ack := range []int{AckSent, AckReceived, AckRead} {
		time.Sleep(600 * time.Millisecond)
		for _, x := range s.raiseAck(a.ID, m.Remote, []string{m.MsgID}, ack) {
			a.emitMsg("Msg:change", x)
		}
		a.emitChat(m.Remote)
	}
	from := m.Remote
	if strings.HasSuffix(m.Remote, "@g.us") {
		from = demoJID("Mãe")
	}
	pr := a.presenceOf(m.Remote)
	a.presMu.Lock()
	pr.TypingUserIds = []string{from}
	cp := *pr
	a.presMu.Unlock()
	c.emit("Presence:change", cp)
	time.Sleep(1500 * time.Millisecond)
	a.presMu.Lock()
	pr.TypingUserIds = []string{}
	cp = *pr
	a.presMu.Unlock()
	c.emit("Presence:change", cp)
	id := fmt.Sprintf("DEMOREPLY%d", time.Now().UnixNano())
	r := Msg{Account: a.ID, Remote: m.Remote, MsgID: id, From: m.Remote, T: time.Now().Unix(), Type: "chat",
		Body: "👍 (resposta automática do modo demo)", Ack: AckReceived}
	if strings.HasSuffix(m.Remote, "@g.us") {
		r.Author = from
	}
	r.ID = msgKey(false, m.Remote, id, r.Author)
	s.putMsg(r, nil)
	s.bumpChat(r, true, false)
	a.emitMsg("Msg:add", r)
	a.emitChat(m.Remote)
}

// demoDownload: the embedded file, after a moment of FETCHING (so the UI's spinner shows).
func (c *Core) demoDownload(a *Account, key string) (any, error) {
	m, _, ok := c.store.msg(a.ID, key)
	if !ok || m.MediaData == nil {
		return nil, errors.New("no media in this message")
	}
	name := map[string]string{"ptt": "voice.ogg", "image": "photo.jpg", "sticker": "photo.jpg", "video": "video.mp4", "document": "relatorio.pdf"}[m.Type]
	data, err := demoMedia.ReadFile("demo/" + name)
	if err != nil {
		return nil, err
	}
	m.MediaData.MediaStage = "FETCHING"
	a.emitMsg("Msg:change", m)
	time.Sleep(700 * time.Millisecond)
	p, ok := a.mediaPath(m, data)
	if !ok {
		return nil, errors.New("cannot write the media file")
	}
	m.MediaData.MediaStage, m.MediaData.RenderableURL = "RESOLVED", p
	c.store.updateMsg(m)
	a.emitMsg("Msg:change", m)
	return a.handOut(m), nil
}

// demoSendMedia: the picked file becomes a sent message at once (already "downloaded": it is ours).
func (c *Core) demoSendMedia(a *Account, p params) (any, error) {
	data, err := os.ReadFile(p.Path)
	if err != nil {
		return nil, err
	}
	id := fmt.Sprintf("DEMOSENT%d", time.Now().UnixNano())
	m := Msg{Account: a.ID, Remote: p.Chat, MsgID: id, ID: msgKey(true, p.Chat, id, ""), FromMe: true, From: demoMe, To: p.Chat,
		T: time.Now().Unix(), Ack: AckClock, Caption: p.Caption}
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(p.Path)))
	md := &MediaData{MediaStage: "RESOLVED", Mimetype: mt, Size: uint64(len(data)), Filename: filepath.Base(p.Path)}
	switch {
	case p.AsPtt:
		m.Type, md.Mimetype, md.Duration = "ptt", "audio/ogg; codecs=opus", uint32(p.Seconds)
	case p.AsDocument:
		m.Type = "document"
	case strings.HasPrefix(mt, "image/"):
		m.Type = "image"
		w, h, th := pictureInfo(data)
		md.Width, md.Height, md.Preview = w, h, base64.StdEncoding.EncodeToString(th)
	case strings.HasPrefix(mt, "video/"):
		m.Type = "video"
	case strings.HasPrefix(mt, "audio/"):
		m.Type = "audio"
	default:
		m.Type = "document"
	}
	m.MediaData = md
	if dst, ok := a.mediaPath(m, data); ok {
		md.RenderableURL = dst
	}
	c.store.putMsg(m, nil)
	c.store.bumpChat(m, false, false)
	a.emitMsg("Msg:add", m)
	a.emitChat(p.Chat)
	go c.demoConversation(a, m)
	return a.handOut(m), nil
}
