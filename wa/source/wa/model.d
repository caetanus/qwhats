/// WhatsApp's protobuf → WhatsApp Web's Msg model, the JSON the UI already speaks (the Go core's
/// normalize.go + model.go, field for field, so the UI cannot tell the cores apart). A waE2E.Message
/// is either a message (`type` from WAWebMsgType, `subtype` from WAWebCommonMsgSubtype) or an
/// add-on that changes another one (reaction, edit, revoke). JSON keys and omit-empty rules match the
/// Go structs' tags.
module wa.model;

import std.json;
import std.conv : to;
import std.string : strip, indexOf;
import wa.proto : ProtoReader, Field;
import e2e = wa.pb.e2e;
import ai = wa.pb.aicommondeprecated;
import aic = wa.pb.aicommon;
import web = wa.pb.web;

// WAWebAck.ACK
enum : int { ackFailed = -1, ackClock = 0, ackSent = 1, ackReceived = 2, ackRead = 3, ackPlayed = 4 }

// ── reading helpers ──────────────────────────────────────────────────────────────────────────

private string str(ProtoReader r, uint n) { return cast(string) r.get(n).bytes.idup; }
private ulong num(ProtoReader r, uint n) { return r.get(n).value; }
private bool flag(ProtoReader r, uint n) { return r.get(n).value != 0; }
private ProtoReader sub(ProtoReader r, uint n) { return ProtoReader(r.get(n).bytes); }
private double dbl(ProtoReader r, uint n) {
    ulong bits = r.get(n).value;
    return *cast(double*) &bits;
}
/// Every occurrence of a repeated field.
private const(ubyte)[][] all(ProtoReader r, uint n) {
    const(ubyte)[][] out_;
    foreach (f; r) if (f.number == n) out_ ~= f.bytes;
    return out_;
}
private string b64(const(ubyte)[] b) {
    import std.base64 : Base64;
    return b.length ? cast(string) Base64.encode(b) : "";
}

/// A JSON object with Go's omitempty: the lower-case setters skip zero values.
struct Obj {
    JSONValue v;
    static Obj make() { Obj o; o.v = JSONValue.emptyObject; return o; }
    void s(string k, string x) { if (x.length) v[k] = x; }
    void S(string k, string x) { v[k] = x; }
    void n(string k, long x) { if (x) v[k] = x; }
    void N(string k, long x) { v[k] = x; }
    void f(string k, double x) { if (x != 0) v[k] = x; }
    void b(string k, bool x) { if (x) v[k] = x; }
    void B(string k, bool x) { v[k] = x; }
    void o(string k, JSONValue x) { v[k] = x; }
    void a(string k, JSONValue[] x) { if (x.length) v[k] = JSONValue(x); }
    string get(string k) const { auto p = k in v; return p is null ? "" : p.str; }
    bool has(string k) const { return (k in v) !is null; }
}

// ── envelopes ────────────────────────────────────────────────────────────────────────────────

/// unwrap: the content inside WhatsApp's envelopes (deviceSent, ephemeral, view-once, edited,
/// document with caption, the FutureProof wrappers); `viewOnce` when one of them was view-once.
const(ubyte)[] unwrap(const(ubyte)[] m, out bool viewOnce) {
    static immutable uint[] futureProof = [
        e2e.Message.ephemeralMessage, e2e.Message.viewOnceMessage, e2e.Message.viewOnceMessageV2,
        e2e.Message.viewOnceMessageV2Extension, e2e.Message.documentWithCaptionMessage,
        e2e.Message.editedMessage, e2e.Message.groupMentionedMessage, e2e.Message.botInvokeMessage,
        e2e.Message.lottieStickerMessage, e2e.Message.eventCoverImage, e2e.Message.pollCreationMessageV4,
        e2e.Message.associatedChildMessage, e2e.Message.spoilerMessage, e2e.Message.questionMessage,
        e2e.Message.audioStickerMessage, e2e.Message.botForwardedMessage, e2e.Message.newsletterScheduledMessage,
    ];
    static immutable uint[] viewOnceKinds = [e2e.Message.viewOnceMessage, e2e.Message.viewOnceMessageV2,
        e2e.Message.viewOnceMessageV2Extension];
    foreach (_; 0 .. 8) {
        auto r = ProtoReader(m);
        if (r.has(e2e.Message.deviceSentMessage)) {
            m = sub(r, e2e.Message.deviceSentMessage).get(e2e.DeviceSentMessage.message).bytes;
            continue;
        }
        bool moved;
        foreach (w; futureProof) {
            if (!r.has(w)) continue;
            auto inner = sub(r, w).get(e2e.FutureProofMessage.message).bytes;
            if (inner.length == 0) return m;
            foreach (v; viewOnceKinds) if (v == w) viewOnce = true;
            m = inner;
            moved = true;
            break;
        }
        if (!moved) return m;
    }
    return m;
}

/// contextOf: the ContextInfo of whichever kind the message is (null when none).
const(ubyte)[] contextOf(const(ubyte)[] m) {
    auto r = ProtoReader(m);
    static immutable uint[2][] kinds = [
        [e2e.Message.extendedTextMessage, e2e.ExtendedTextMessage.contextInfo],
        [e2e.Message.imageMessage, e2e.ImageMessage.contextInfo],
        [e2e.Message.videoMessage, e2e.VideoMessage.contextInfo],
        [e2e.Message.ptvMessage, e2e.VideoMessage.contextInfo],
        [e2e.Message.audioMessage, e2e.AudioMessage.contextInfo],
        [e2e.Message.documentMessage, e2e.DocumentMessage.contextInfo],
        [e2e.Message.stickerMessage, e2e.StickerMessage.contextInfo],
        [e2e.Message.locationMessage, e2e.LocationMessage.contextInfo],
        [e2e.Message.liveLocationMessage, e2e.LiveLocationMessage.contextInfo],
        [e2e.Message.contactMessage, e2e.ContactMessage.contextInfo],
        [e2e.Message.contactsArrayMessage, e2e.ContactsArrayMessage.contextInfo],
        [e2e.Message.pollCreationMessage, e2e.PollCreationMessage.contextInfo],
        [e2e.Message.pollCreationMessageV3, e2e.PollCreationMessage.contextInfo],
    ];
    foreach (k; kinds)
        if (r.has(k[0])) {
            auto inner = sub(r, k[0]);
            return inner.has(k[1]) ? inner.get(k[1]).bytes : null;
        }
    return null;
}

// ── content ──────────────────────────────────────────────────────────────────────────────────

/// joinText: a title and a text, a blank line between (either may be missing).
string joinText(string title, string text) {
    title = title.strip;
    text = text.strip;
    if (title.length == 0 || text.length == 0) return title ~ text;
    return "*" ~ title ~ "*\n\n" ~ text;
}

/// flowButton: a native-flow button from its name and its parameters' JSON.
JSONValue flowButton(string name, string params) {
    JSONValue p;
    try p = parseJSON(params.length ? params : "{}"); catch (Exception) p = JSONValue.emptyObject;
    string g(string k) { if (p.type != JSONType.object) return ""; auto x = k in p; return x !is null && x.type == JSONType.string ? x.str : ""; }
    string kind = "reply", text = g("display_text"), value = g("id");
    switch (name) {
        case "cta_url": kind = "url"; value = g("url"); break;
        case "cta_call": kind = "call"; value = g("phone_number"); break;
        case "cta_copy": kind = "copy"; value = g("copy_code"); break;
        case "single_select": kind = "list"; if (text.length == 0) text = g("title"); break;
        default: break;
    }
    if (text.length == 0) text = name;
    return button(kind, text, value);
}

private JSONValue button(string kind, string text, string value) {
    auto o = Obj.make();
    o.S("kind", kind);
    o.S("text", text);
    o.s("value", value);
    return o.v;
}

/// collectText: every "text" string in a JSON value, in order (object keys sorted).
private void collectText(JSONValue v, ref string outv) {
    import std.algorithm : sort;
    if (v.type == JSONType.object) {
        if (auto t = "text" in v) if (t.type == JSONType.string && t.str.length) outv ~= t.str ~ "\n";
        auto keys = v.object.keys;
        sort(keys);
        foreach (k; keys) if (k != "text") collectText(v[k], outv);
    } else if (v.type == JSONType.array) {
        foreach (e; v.array) collectText(e, outv);
    }
}

/// richText: a Meta AI answer as text — text parts, tables as markdown rows, code as ``` blocks;
/// the unified form's text fields when there are no parts.
string richText(const(ubyte)[] rich) {
    import std.array : join;
    auto r = ProtoReader(rich);
    string b;
    foreach (smb; all(r, e2e.AIRichResponseMessage.submessages)) {
        auto sm = ProtoReader(smb);
        if (str(sm, ai.AIRichResponseSubMessage.messageText).length) {
            b ~= str(sm, ai.AIRichResponseSubMessage.messageText);
        } else if (sm.has(ai.AIRichResponseSubMessage.tableMetadata)) {
            auto tm = sub(sm, ai.AIRichResponseSubMessage.tableMetadata);
            if (const t = str(tm, ai.AIRichResponseTableMetadata.title)) if (t.length) b ~= "*" ~ t ~ "*\n";
            foreach (i, rowb; all(tm, ai.AIRichResponseTableMetadata.rows)) {
                auto row = ProtoReader(rowb);
                string[] items;
                foreach (it; all(row, ai.AIRichResponseTableMetadata.AIRichResponseTableRow.items)) items ~= cast(string) it.idup;
                b ~= "| " ~ items.join(" | ") ~ " |\n";
                if (i == 0 && flag(row, ai.AIRichResponseTableMetadata.AIRichResponseTableRow.isHeading)) {
                    b ~= "|";
                    foreach (_; items) b ~= " --- |";
                    b ~= "\n";
                }
            }
            continue;
        } else if (sm.has(ai.AIRichResponseSubMessage.codeMetadata)) {
            auto cm = sub(sm, ai.AIRichResponseSubMessage.codeMetadata);
            b ~= "```";
            foreach (blk; all(cm, ai.AIRichResponseCodeMetadata.codeBlocks))
                b ~= str(ProtoReader(blk), ai.AIRichResponseCodeMetadata.AIRichResponseCodeBlock.codeContent);
            b ~= "```";
        } else continue;
        b ~= "\n";
    }
    if (b.length == 0 && r.has(e2e.AIRichResponseMessage.unifiedResponse)) {
        auto d = sub(r, e2e.AIRichResponseMessage.unifiedResponse).get(aic.AIRichResponseUnifiedResponse.data).bytes;
        if (d.length) try collectText(parseJSON(cast(string) d), b); catch (Exception) {}
    }
    return b.strip;
}

private string argb(ulong x) { import std.format : format; return format("#%08X", cast(uint) x); }

private JSONValue mediaData(string mime, ulong size) {
    auto o = Obj.make();
    o.S("mediaStage", "INIT");
    o.s("mimetype", mime);
    o.n("size", size);
    return o.v;
}

/// content: type, text and media of a message, without its envelope. False: not a message
/// (protocol, add-on, or a kind the UI does not render).
bool content(const(ubyte)[] message, out JSONValue msg) {
    bool viewOnce;
    auto m = ProtoReader(unwrap(message, viewOnce));
    auto n = Obj.make();
    JSONValue md;   // mediaData (null when none)
    bool hasMedia;
    alias M = e2e.Message;

    if (m.has(M.conversation)) {
        n.S("type", "chat");
        n.s("body", str(m, M.conversation));
    } else if (m.has(M.extendedTextMessage)) {
        alias X = e2e.ExtendedTextMessage;
        auto e = sub(m, M.extendedTextMessage);
        n.S("type", "chat");
        n.s("body", str(e, X.text));
        n.s("matchedText", str(e, X.matchedText));
        n.s("title", str(e, X.title));
        n.s("description", str(e, X.description));
        n.s("thumbnail", b64(e.get(X.JPEGThumbnail).bytes));
        if (str(e, X.thumbnailDirectPath).length) {
            n.B("linkHQ", true);
            n.n("thumbWidth", num(e, X.thumbnailWidth));
            n.n("thumbHeight", num(e, X.thumbnailHeight));
        }
        if (e.has(X.previewType))
            try n.S("previewType", (cast(X.PreviewType) num(e, X.previewType)).to!string);
            catch (Exception) n.S("previewType", num(e, X.previewType).to!string);
        if (const bg = num(e, X.backgroundArgb)) {
            n.S("backgroundColor", argb(bg));
            // no text colour (absent, or alpha 0) is white, as WhatsApp draws it — not invisible
            const fg = cast(uint) num(e, X.textArgb);
            n.S("textColor", argb((fg >> 24) != 0 ? fg : 0xFFFFFFFF));
            n.n("font", num(e, X.font));
        }
    } else if (m.has(M.richResponseMessage)) {
        n.S("type", "chat");
        n.s("body", richText(m.get(M.richResponseMessage).bytes));
    } else if (m.has(M.buttonsMessage)) {
        alias X = e2e.ButtonsMessage;
        auto x = sub(m, M.buttonsMessage);
        n.S("type", "chat");
        n.s("body", joinText(str(x, X.text), str(x, X.contentText)));
        n.s("footer", str(x, X.footerText));
        JSONValue[] btns;
        foreach (bb; all(x, X.buttons)) {
            auto b = ProtoReader(bb);
            const t = str(sub(b, X.Button.buttonText), X.Button.ButtonText.displayText);
            if (t.length) btns ~= button("reply", t, str(b, X.Button.buttonID));
            else if (b.has(X.Button.nativeFlowInfo)) {
                auto nf = sub(b, X.Button.nativeFlowInfo);
                btns ~= flowButton(str(nf, X.Button.NativeFlowInfo.name), str(nf, X.Button.NativeFlowInfo.paramsJSON));
            }
        }
        n.a("buttons", btns);
    } else if (m.has(M.templateMessage)) {
        alias X = e2e.TemplateMessage;
        auto tm = sub(m, M.templateMessage);
        auto t = tm.has(X.hydratedTemplate) ? sub(tm, X.hydratedTemplate) : sub(tm, X.hydratedFourRowTemplate);
        alias H = X.HydratedFourRowTemplate;
        n.S("type", "chat");
        n.s("body", joinText(str(t, H.hydratedTitleText), str(t, H.hydratedContentText)));
        n.s("footer", str(t, H.hydratedFooterText));
        JSONValue[] btns;
        alias B = e2e.HydratedTemplateButton;
        foreach (bb; all(t, H.hydratedButtons)) {
            auto b = ProtoReader(bb);
            if (b.has(B.quickReplyButton)) {
                auto q = sub(b, B.quickReplyButton);
                btns ~= button("reply", str(q, B.HydratedQuickReplyButton.displayText), str(q, B.HydratedQuickReplyButton.ID));
            } else if (b.has(B.urlButton)) {
                auto u = sub(b, B.urlButton);
                btns ~= button("url", str(u, B.HydratedURLButton.displayText), str(u, B.HydratedURLButton.URL));
            } else if (b.has(B.callButton)) {
                auto c = sub(b, B.callButton);
                btns ~= button("call", str(c, B.HydratedCallButton.displayText), str(c, B.HydratedCallButton.phoneNumber));
            }
        }
        n.a("buttons", btns);
    } else if (m.has(M.interactiveMessage)) {
        alias X = e2e.InteractiveMessage;
        auto x = sub(m, M.interactiveMessage);
        n.S("type", "chat");
        n.s("body", joinText(str(sub(x, X.header), X.Header.title), str(sub(x, X.body_), X.Body.text)));
        n.s("footer", str(sub(x, X.footer), X.Footer.text));
        JSONValue[] btns;
        foreach (bb; all(sub(x, X.nativeFlowMessage), X.NativeFlowMessage.buttons)) {
            auto b = ProtoReader(bb);
            btns ~= flowButton(str(b, X.NativeFlowMessage.NativeFlowButton.name),
                str(b, X.NativeFlowMessage.NativeFlowButton.buttonParamsJSON));
        }
        n.a("buttons", btns);
    } else if (m.has(M.listMessage)) {
        alias X = e2e.ListMessage;
        auto x = sub(m, M.listMessage);
        n.S("type", "chat");
        n.s("body", joinText(str(x, X.title), str(x, X.description)));
        n.s("footer", str(x, X.footerText));
        string rows;
        foreach (sb; all(x, X.sections))
            foreach (rb; all(ProtoReader(sb), X.Section.rows))
                rows ~= (rows.length ? "\n" : "") ~ str(ProtoReader(rb), X.Row.title);
        n.a("buttons", [button("list", str(x, X.buttonText), rows)]);
    } else if (m.has(M.buttonsResponseMessage)) {
        n.S("type", "chat");
        n.s("body", str(sub(m, M.buttonsResponseMessage), e2e.ButtonsResponseMessage.selectedDisplayText));
    } else if (m.has(M.templateButtonReplyMessage)) {
        n.S("type", "chat");
        n.s("body", str(sub(m, M.templateButtonReplyMessage), e2e.TemplateButtonReplyMessage.selectedDisplayText));
    } else if (m.has(M.listResponseMessage)) {
        n.S("type", "chat");
        n.s("body", str(sub(m, M.listResponseMessage), e2e.ListResponseMessage.title));
    } else if (m.has(M.interactiveResponseMessage)) {
        alias X = e2e.InteractiveResponseMessage;
        n.S("type", "chat");
        n.s("body", str(sub(sub(m, M.interactiveResponseMessage), X.body_), X.Body.text));
    } else if (m.has(M.imageMessage)) {
        alias X = e2e.ImageMessage;
        auto x = sub(m, M.imageMessage);
        n.S("type", "image");
        n.s("caption", str(x, X.caption));
        md = mediaData(str(x, X.mimetype), num(x, X.fileLength));
        auto o = Obj(md);
        o.n("width", num(x, X.width));
        o.n("height", num(x, X.height));
        o.s("preview", b64(x.get(X.JPEGThumbnail).bytes));
        md = o.v;
        hasMedia = true;
    } else if (m.has(M.videoMessage) || m.has(M.ptvMessage)) {
        alias X = e2e.VideoMessage;
        const ptv = !m.has(M.videoMessage);
        auto x = sub(m, ptv ? M.ptvMessage : M.videoMessage);
        n.S("type", ptv ? "ptv" : "video");
        if (!ptv) n.s("caption", str(x, X.caption));
        auto o = Obj(mediaData(str(x, X.mimetype), num(x, X.fileLength)));
        o.n("duration", num(x, X.seconds));
        o.n("width", num(x, X.width));
        o.n("height", num(x, X.height));
        o.s("preview", b64(x.get(X.JPEGThumbnail).bytes));
        if (!ptv) o.b("isGif", flag(x, X.gifPlayback));
        md = o.v;
        hasMedia = true;
    } else if (m.has(M.audioMessage)) {
        alias X = e2e.AudioMessage;
        auto x = sub(m, M.audioMessage);
        const mime = str(x, X.mimetype);
        auto wave = x.get(X.waveform).bytes;
        // a voice note: flagged ptt, or recorded by WhatsApp (Ogg/Opus with a waveform)
        const ptt = flag(x, X.PTT) || (wave.length && mime.indexOf("opus") >= 0);
        n.S("type", ptt ? "ptt" : "audio");
        auto o = Obj(mediaData(mime, num(x, X.fileLength)));
        o.n("duration", num(x, X.seconds));
        o.s("waveform", b64(wave));
        md = o.v;
        hasMedia = true;
    } else if (m.has(M.documentMessage)) {
        alias X = e2e.DocumentMessage;
        auto x = sub(m, M.documentMessage);
        n.S("type", "document");
        n.s("caption", str(x, X.caption));
        auto name = str(x, X.fileName);
        if (name.length == 0) name = str(x, X.title);
        auto o = Obj(mediaData(str(x, X.mimetype), num(x, X.fileLength)));
        o.s("filename", name);
        o.n("pageCount", num(x, X.pageCount));
        o.s("preview", b64(x.get(X.JPEGThumbnail).bytes));
        md = o.v;
        hasMedia = true;
    } else if (m.has(M.stickerMessage)) {
        alias X = e2e.StickerMessage;
        auto x = sub(m, M.stickerMessage);
        n.S("type", "sticker");
        auto o = Obj(mediaData(str(x, X.mimetype), num(x, X.fileLength)));
        o.n("width", num(x, X.width));
        o.n("height", num(x, X.height));
        o.b("isAnimated", flag(x, X.isAnimated));
        md = o.v;
        hasMedia = true;
    } else if (m.has(M.locationMessage)) {
        alias X = e2e.LocationMessage;
        auto x = sub(m, M.locationMessage);
        n.S("type", "location");
        n.f("lat", dbl(x, X.degreesLatitude));
        n.f("lng", dbl(x, X.degreesLongitude));
        n.s("loc", (str(x, X.name) ~ "\n" ~ str(x, X.address)).strip);
        n.s("thumbnail", b64(x.get(X.JPEGThumbnail).bytes));
    } else if (m.has(M.liveLocationMessage)) {
        alias X = e2e.LiveLocationMessage;
        auto x = sub(m, M.liveLocationMessage);
        n.S("type", "location");
        n.f("lat", dbl(x, X.degreesLatitude));
        n.f("lng", dbl(x, X.degreesLongitude));
        n.b("isLive", true);
        n.s("caption", str(x, X.caption));
        n.s("thumbnail", b64(x.get(X.JPEGThumbnail).bytes));
    } else if (m.has(M.contactMessage)) {
        alias X = e2e.ContactMessage;
        auto x = sub(m, M.contactMessage);
        n.S("type", "vcard");
        n.a("vcardList", [vcard(str(x, X.displayName), str(x, X.vcard))]);
    } else if (m.has(M.contactsArrayMessage)) {
        auto x = sub(m, M.contactsArrayMessage);
        n.S("type", "multi_vcard");
        JSONValue[] list;
        foreach (cb; all(x, e2e.ContactsArrayMessage.contacts)) {
            auto c = ProtoReader(cb);
            list ~= vcard(str(c, e2e.ContactMessage.displayName), str(c, e2e.ContactMessage.vcard));
        }
        n.a("vcardList", list);
    } else if (m.has(M.pollCreationMessage) || m.has(M.pollCreationMessageV2) || m.has(M.pollCreationMessageV3)) {
        alias X = e2e.PollCreationMessage;
        const which = m.has(M.pollCreationMessage) ? M.pollCreationMessage
            : m.has(M.pollCreationMessageV2) ? M.pollCreationMessageV2 : M.pollCreationMessageV3;
        auto p = sub(m, which);
        n.S("type", "poll_creation");
        n.s("pollName", str(p, X.name));
        n.n("pollSelectableOptionsCount", num(p, X.selectableOptionsCount));
        JSONValue[] opts;
        foreach (i, ob; all(p, X.options)) {
            auto o = Obj.make();
            o.N("localId", cast(long) i);
            o.S("name", str(ProtoReader(ob), X.Option.optionName));
            opts ~= o.v;
        }
        n.a("pollOptions", opts);
    } else if (m.has(M.protocolMessage)
        && num(sub(m, M.protocolMessage), e2e.ProtocolMessage.type) == e2e.ProtocolMessage.Type.EPHEMERAL_SETTING) {
        const d = num(sub(m, M.protocolMessage), e2e.ProtocolMessage.ephemeralExpiration);
        n.S("type", "notification_template");
        n.S("subtype", "ephemeral_setting");
        n.n("ephemeralDuration", d);
        n.a("templateParams", [JSONValue(d.to!string)]);
    } else {
        return false;
    }

    if (hasMedia) {
        auto o = Obj(md);
        o.b("isViewOnce", viewOnce);
        n.o("mediaData", o.v);
    }
    if (auto cib = contextOf(m.data)) {
        alias C = e2e.ContextInfo;
        auto ci = ProtoReader(cib);
        JSONValue[] mentioned;
        foreach (j; all(ci, C.mentionedJID)) mentioned ~= JSONValue(cast(string) j.idup);
        n.a("mentionedJidList", mentioned);
        n.b("isForwarded", flag(ci, C.isForwarded));
        n.n("forwardingScore", num(ci, C.forwardingScore));
        const exp = num(ci, C.expiration);
        if (exp > (n.has("ephemeralDuration") ? n.v["ephemeralDuration"].integer : 0)) n.N("ephemeralDuration", exp);
        if (const sid = str(ci, C.stanzaID)) if (sid.length) {
            auto q = Obj.make();
            q.S("id", sid);
            q.s("author", str(ci, C.participant));
            if (ci.has(C.quotedMessage)) {
                JSONValue qn;
                if (content(ci.get(C.quotedMessage).bytes, qn)) {
                    q.s("type", qn["type"].str);
                    q.s("body", previewBody(qn));
                }
            }
            n.o("quotedMsg", q.v);
            n.s("quotedRemoteJid", str(ci, C.remoteJID));
        }
    }
    msg = n.v;
    return true;
}

private JSONValue vcard(string name, string card) {
    auto o = Obj.make();
    o.S("displayName", name);
    o.S("vcard", card);
    return o.v;
}

/// previewBody: the one-line text WhatsApp Web shows for a message (chat list, quotes, notifications).
string previewBody(JSONValue n) {
    import std.array : join;
    string g(string k) { auto p = k in n; return p is null || p.type != JSONType.string ? "" : p.str; }
    const t = g("type");
    if (t == "chat") return g("body");
    if (g("caption").length) return g("caption");
    if (t == "document") {
        if (auto mdp = "mediaData" in n) if (auto fn = "filename" in *mdp) return fn.str;
        return "";
    }
    if (t == "vcard" || t == "multi_vcard") {
        string[] names;
        if (auto l = "vcardList" in n) foreach (v; l.array) names ~= v["displayName"].str;
        return names.join(", ");
    }
    if (t == "poll_creation") return g("pollName");
    if (t == "location") { const loc = g("loc"); const i = loc.indexOf('\n'); return i < 0 ? loc : loc[0 .. i]; }
    return "";
}

/// The message a history entry stands for (whatsmeow ParseWebMessage): a MESSAGE_EDIT protocol
/// message becomes its edited content, under the edited message's id.
const(ubyte)[] historyContent(const(ubyte)[] message, ref string id) { long editMs; bool isEdit; return historyContent(message, id, editMs, isEdit); }

/// … and whether the entry is an edit (whatever its outer id), with the edit's timestampMS
const(ubyte)[] historyContent(const(ubyte)[] message, ref string id, out long editMs, out bool isEdit) {
    bool vo;
    auto m = ProtoReader(unwrap(message, vo));
    if (!m.has(e2e.Message.protocolMessage)) return message;
    alias P = e2e.ProtocolMessage;
    auto p = sub(m, e2e.Message.protocolMessage);
    if (num(p, P.type) != P.Type.MESSAGE_EDIT) return message;
    id = str(sub(p, P.key), wa.pb.common.MessageKey.ID);
    editMs = cast(long) num(p, P.timestampMS);
    isEdit = true;
    return p.get(P.editedMessage).bytes;
}

// ── add-ons ──────────────────────────────────────────────────────────────────────────────────

/// A message that changes another one: kind reaction / edit / revoke.
struct Addon {
    string kind;
    string parentId;    // the bare id of the target, in the same chat
    string text;        // reaction emoji
    JSONValue edited;   // edit: the new content (a Msg's content fields)
    long t;
    long tMs;           // edit: the protocol's timestampMS — edits are ordered by it (two in one second)
}

/// addon: a reaction, an edit or a revoke; false when the message is none of them.
bool addon(const(ubyte)[] message, out Addon a) {
    bool vo;
    auto m = ProtoReader(unwrap(message, vo));
    alias M = e2e.Message;
    alias K = wa.pb.common.MessageKey;
    if (m.has(M.reactionMessage)) {
        alias R = e2e.ReactionMessage;
        auto r = sub(m, M.reactionMessage);
        a.kind = "reaction";
        a.parentId = str(sub(r, R.key), K.ID);
        a.text = str(r, R.text);
        a.t = cast(long) num(r, R.senderTimestampMS) / 1000;
        return true;
    }
    if (m.has(M.protocolMessage)) {
        alias P = e2e.ProtocolMessage;
        auto p = sub(m, M.protocolMessage);
        const t = num(p, P.type);
        if (t == P.Type.REVOKE) {
            a.kind = "revoke";
            a.parentId = str(sub(p, P.key), K.ID);
            return true;
        }
        if (t == P.Type.MESSAGE_EDIT) {
            JSONValue e;
            if (!content(p.get(P.editedMessage).bytes, e)) return false;
            a.kind = "edit";
            a.parentId = str(sub(p, P.key), K.ID);
            a.edited = e;
            a.tMs = cast(long) num(p, P.timestampMS);
            a.t = a.tMs / 1000;
            return true;
        }
    }
    return false;
}

static import wa.pb.common;

// ── envelope ─────────────────────────────────────────────────────────────────────────────────

/// msgKey: WhatsApp Web's message key, fromMe_remote_id[_participant] (participant only for
/// others' group messages).
string msgKey(bool fromMe, string remote, string id, string participant) {
    import std.algorithm : endsWith;
    auto k = (fromMe ? "true_" : "false_") ~ remote ~ "_" ~ id;
    if (participant.length && !fromMe && remote.endsWith("@g.us")) k ~= "_" ~ participant;
    return k;
}

/// envelope: the Msg fields that come from who/where/when, not from the content.
void envelope(ref JSONValue n, string account, string msgId, bool fromMe, long t, string pushName,
    string remote, string author) {
    import std.algorithm : endsWith;
    auto o = Obj(n);
    o.S("account", account);
    o.S("remote", remote);
    o.S("msgId", msgId);
    o.B("fromMe", fromMe);
    o.N("t", t);
    o.s("notifyName", pushName);
    if (remote.endsWith("@g.us") || remote.endsWith("@broadcast")) o.s("author", author);
    if (fromMe) {
        o.S("from", author);
        o.S("to", remote);
        o.N("ack", ackSent);
    } else {
        o.S("from", remote);
        o.S("to", "");
        o.N("ack", ackReceived);
    }
    o.S("id", msgKey(fromMe, remote, msgId, author));
    n = o.v;
}

/// stubOf: WhatsApp Web's (type, subtype) for a history system message (WebMessageInfo.messageStubType).
string[2] stubOf(long t) {
    alias S = web.WebMessageInfo.StubType;
    switch (t) {
        case S.GROUP_CREATE: return ["gp2", "create"];
        case S.GROUP_CHANGE_SUBJECT: return ["gp2", "subject"];
        case S.GROUP_CHANGE_DESCRIPTION: return ["gp2", "description"];
        case S.GROUP_CHANGE_ICON: return ["gp2", "picture"];
        case S.GROUP_PARTICIPANT_ADD: return ["gp2", "add"];
        case S.GROUP_PARTICIPANT_REMOVE: return ["gp2", "remove"];
        case S.GROUP_PARTICIPANT_LEAVE: return ["gp2", "leave"];
        case S.GROUP_PARTICIPANT_INVITE: return ["gp2", "invite"];
        case S.GROUP_PARTICIPANT_PROMOTE: return ["gp2", "promote"];
        case S.GROUP_PARTICIPANT_DEMOTE: return ["gp2", "demote"];
        case S.GROUP_CHANGE_RESTRICT: return ["gp2", "restrict"];
        case S.GROUP_CHANGE_ANNOUNCE: return ["gp2", "announce"];
        case S.GROUP_PARTICIPANT_LINKED_GROUP_JOIN: return ["gp2", "linked_group_join"];
        case S.CHANGE_EPHEMERAL_SETTING: return ["notification_template", "ephemeral_setting"];
        case S.E2E_ENCRYPTED, S.E2E_ENCRYPTED_NOW: return ["e2e_notification", "encrypt"];
        case S.E2E_IDENTITY_CHANGED: return ["e2e_notification", "identity"];
        case S.CALL_MISSED_VOICE: return ["call_log", "miss"];
        case S.CALL_MISSED_VIDEO: return ["call_log", "miss_video"];
        case S.CALL_MISSED_GROUP_VOICE: return ["call_log", "miss_group"];
        case S.CALL_MISSED_GROUP_VIDEO: return ["call_log", "miss_group_video"];
        case S.REVOKE: return ["revoked", "sender_revoke"];
        default: return ["", ""];
    }
}

/// ackOf: the history's WebMessageInfo.Status as WAWebAck.
int ackOf(long s) {
    alias St = web.WebMessageInfo.Status;
    switch (s) {
        case St.ERROR: return ackFailed;
        case St.PENDING: return ackClock;
        case St.SERVER_ACK: return ackSent;
        case St.DELIVERY_ACK: return ackReceived;
        case St.READ: return ackRead;
        case St.PLAYED: return ackPlayed;
        default: return ackSent;
    }
}
