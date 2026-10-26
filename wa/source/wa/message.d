/// The WhatsApp end-to-end payload that sits inside a decrypted Signal plaintext. Classic E2E
/// (the `<enc v="2">` form) wraps a `Message` protobuf in a random pad whose final byte is the pad
/// length; the newer `v="3"` form carries the payload unpadded. On top of that the `Message`
/// protobuf (waE2E.Message) holds the actual content — a bare `conversation` string for a plain
/// text message, or an `extendedTextMessage` when it has context (a quote, a link preview, …).
///
/// Only the common text shapes are decoded here; the rest of the (very large) Message protobuf is
/// left for when a concrete feature needs it. Field numbers are from whatsmeow's waE2E/WAWebProtobufsE2E.
module wa.message;

import wa.proto : ProtoReader;

class MessageException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Strip WhatsApp's E2E padding. `version` is the `<enc v="…">` attribute: v2 is padded (the last
/// byte is the pad length), v3 carries the payload as-is.
const(ubyte)[] unpad(const(ubyte)[] plaintext, int version_ = 2) {
    if (version_ == 3) return plaintext;
    if (plaintext.length == 0) throw new MessageException("empty plaintext");
    const n = plaintext[$ - 1];
    if (n == 0 || n > plaintext.length) throw new MessageException("bad padding");
    return plaintext[0 .. $ - n];
}

/// Add WhatsApp's E2E padding (the v2 form): append N bytes all equal to N, where N is 1..15.
/// Mirrors whatsmeow's padMessage (a random nibble, 0 mapped to 15).
ubyte[] pad(const(ubyte)[] plaintext) {
    import wa.crypto : randomBytes;
    ubyte n = randomBytes(1)[0] & 0x0f;
    if (n == 0) n = 0x0f;
    ubyte[] o = plaintext.dup;
    foreach (_; 0 .. n) o ~= n;
    return o;
}

// waE2E.Message field numbers (WAWebProtobufsE2E.proto)
enum MessageField : uint {
    conversation = 1, senderKeyDistribution = 2, image = 3, extendedText = 6, document = 7,
    audio = 8, video = 9, protocol = 12, sticker = 26, deviceSent = 31, messageContextInfo = 35,
    ephemeral = 40, reaction = 46, edited = 58,
}

/// Peel the wrappers that carry another Message inside: deviceSentMessage (our own message echoed
/// to our other devices: { destinationJID = 1; message = 2; }) and ephemeral/edited
/// (FutureProofMessage { message = 1; }). Returns the innermost Message bytes.
const(ubyte)[] innerMessage(const(ubyte)[] messageProto) {
    foreach (_; 0 .. 4) {
        auto r = ProtoReader(messageProto);
        if (r.has(MessageField.deviceSent)) {
            auto d = ProtoReader(r.get(MessageField.deviceSent).bytes);
            if (!d.has(2)) break;
            messageProto = d.get(2).bytes;
        } else if (r.has(MessageField.ephemeral)) {
            auto f = ProtoReader(r.get(MessageField.ephemeral).bytes);
            if (!f.has(1)) break;
            messageProto = f.get(1).bytes;
        } else break;
    }
    return messageProto;
}

/// The text of a decrypted (unpadded) `Message` protobuf, for the plain-text shapes: the
/// `conversation` (field 1), else `extendedTextMessage.text` (field 6 → 1), after peeling the
/// deviceSent/ephemeral wrappers. "" when the message carries no text (media, protocol, …).
string conversationText(const(ubyte)[] messageProto) {
    auto r = ProtoReader(innerMessage(messageProto));
    if (r.has(MessageField.conversation)) return cast(string) r.get(MessageField.conversation).bytes.idup;
    if (r.has(MessageField.extendedText)) {
        auto ext = ProtoReader(r.get(MessageField.extendedText).bytes);
        if (ext.has(1)) return cast(string) ext.get(1).bytes.idup;
    }
    return "";
}

/// Wrappers that carry another Message as FutureProofMessage { message = 1 }: viewOnce (37),
/// ephemeral (40), documentWithCaption (53), viewOnceV2 (55), viewOnceV2Extension (59), lottieSticker (74).
private immutable uint[] futureProofWrappers = [37, 40, 53, 55, 59, 74];

private const(ubyte)[] unwrapOnce(const(ubyte)[] messageProto, out bool unwrapped) {
    auto r = ProtoReader(messageProto);
    foreach (w; futureProofWrappers)
        if (r.has(w)) {
            auto f = ProtoReader(r.get(w).bytes);
            if (f.has(1)) { unwrapped = true; return f.get(1).bytes; }
        }
    return messageProto;
}

/// The `mediatype` attribute of an outgoing <enc> (whatsmeow getMediaTypeFromMessage); "" for none.
string encMediaType(const(ubyte)[] messageProto) {
    bool un;
    auto inner = unwrapOnce(messageProto, un);
    if (un) return encMediaType(inner);
    auto r = ProtoReader(messageProto);
    if (r.has(MessageField.extendedText) && ProtoReader(r.get(MessageField.extendedText).bytes).has(6)) return "url";
    if (r.has(MessageField.image)) return "image";
    if (r.has(MessageField.sticker)) return "sticker";
    if (r.has(MessageField.document)) return "document";
    if (r.has(MessageField.audio)) return ProtoReader(r.get(MessageField.audio).bytes).get(6).value ? "ptt" : "audio";
    if (r.has(MessageField.video)) return ProtoReader(r.get(MessageField.video).bytes).get(8).value ? "gif" : "video";
    if (r.has(4)) return "vcard";
    if (r.has(13)) return "contact_array";
    if (r.has(36)) return "list";
    if (r.has(39)) return "list_response";
    if (r.has(43)) return "buttons_response";
    if (r.has(38)) return "order";
    if (r.has(30)) return "product";
    return "";
}

/// The `type` attribute of an outgoing <message> (whatsmeow getTypeFromMessage).
string messageStanzaType(const(ubyte)[] messageProto) {
    bool un;
    auto inner = unwrapOnce(messageProto, un);
    if (un) return messageStanzaType(inner);
    auto r = ProtoReader(messageProto);
    if (r.has(MessageField.reaction) || r.has(56)) return "reaction";
    if (r.has(49) || r.has(50)) return "poll";
    if (encMediaType(messageProto).length) return "media";
    return "text";
}

/// The stanza's `edit` attribute (whatsmeow getEditAttribute): "1" an edit, "2" a pin, "7" a revoke
/// of our own message (or a reaction taken back, or a keep-in-chat undone), "8" an admin's revoke;
/// "" for anything else.
string editAttribute(const(ubyte)[] messageProto) {
    import e2e = wa.pb.e2e;
    import wa.pb.common : MessageKey;
    auto r = ProtoReader(messageProto);
    if (r.has(e2e.Message.editedMessage)) {
        auto inner = ProtoReader(r.get(e2e.Message.editedMessage).bytes).get(e2e.FutureProofMessage.message).bytes;
        if (inner.length) return editAttribute(inner);
    }
    if (r.has(e2e.Message.protocolMessage)) {
        auto p = ProtoReader(r.get(e2e.Message.protocolMessage).bytes);
        if (p.has(e2e.ProtocolMessage.key)) {
            const t = p.get(e2e.ProtocolMessage.type).value;
            if (t == e2e.ProtocolMessage.Type.REVOKE)
                return ProtoReader(p.get(e2e.ProtocolMessage.key).bytes).get(MessageKey.fromMe).value != 0 ? "7" : "8";
            if (t == e2e.ProtocolMessage.Type.MESSAGE_EDIT && p.has(e2e.ProtocolMessage.editedMessage)) return "1";
        }
    }
    if (r.has(e2e.Message.reactionMessage)) {
        auto rm = ProtoReader(r.get(e2e.Message.reactionMessage).bytes);
        if (rm.has(e2e.ReactionMessage.text) && rm.get(e2e.ReactionMessage.text).bytes.length == 0) return "7";
    }
    if (r.has(e2e.Message.keepInChatMessage)) {
        auto k = ProtoReader(r.get(e2e.Message.keepInChatMessage).bytes);
        if (ProtoReader(k.get(e2e.KeepInChatMessage.key).bytes).get(MessageKey.fromMe).value != 0
                && k.get(e2e.KeepInChatMessage.keepType).value == e2e.KeepType.UNDO_KEEP_FOR_ALL)
            return "7";
    }
    if (r.has(e2e.Message.pinInChatMessage)) return "2";
    return "";
}

unittest {
    import wa.proto : ProtoWriter;
    import e2e = wa.pb.e2e;
    auto mine = ProtoWriter().str(1, "5511@s.whatsapp.net").boolean(2, true).str(3, "ID");
    auto theirs = ProtoWriter().str(1, "1-2@g.us").boolean(2, false).str(3, "ID").str(4, "5522@s.whatsapp.net");
    auto revoke = ProtoWriter().message(e2e.Message.protocolMessage, ProtoWriter().message(e2e.ProtocolMessage.key, mine)
        .varint(e2e.ProtocolMessage.type, e2e.ProtocolMessage.Type.REVOKE)).buf;
    assert(editAttribute(revoke) == "7");
    auto admin = ProtoWriter().message(e2e.Message.protocolMessage, ProtoWriter().message(e2e.ProtocolMessage.key, theirs)
        .varint(e2e.ProtocolMessage.type, e2e.ProtocolMessage.Type.REVOKE)).buf;
    assert(editAttribute(admin) == "8");
    auto pm = ProtoWriter().message(e2e.ProtocolMessage.key, mine).varint(e2e.ProtocolMessage.type, e2e.ProtocolMessage.Type.MESSAGE_EDIT)
        .message(e2e.ProtocolMessage.editedMessage, ProtoWriter().str(e2e.Message.conversation, "novo"));
    auto edit = ProtoWriter().message(e2e.Message.editedMessage, ProtoWriter().message(e2e.FutureProofMessage.message,
        ProtoWriter().message(e2e.Message.protocolMessage, pm))).buf;
    assert(editAttribute(edit) == "1");
    auto unreact = ProtoWriter().message(e2e.Message.reactionMessage, ProtoWriter().message(e2e.ReactionMessage.key, mine)
        .str(e2e.ReactionMessage.text, "")).buf;
    assert(editAttribute(unreact) == "7");
    auto react = ProtoWriter().message(e2e.Message.reactionMessage, ProtoWriter().message(e2e.ReactionMessage.key, mine)
        .str(e2e.ReactionMessage.text, "👍")).buf;
    assert(editAttribute(react) == "");
    auto pin = ProtoWriter().message(e2e.Message.pinInChatMessage, ProtoWriter().message(1, mine).varint(2, 1)).buf;
    assert(editAttribute(pin) == "2");
    assert(editAttribute(ProtoWriter().str(e2e.Message.conversation, "oi").buf) == "");
}

/// A sender key handed out inside a Message (field 2: SenderKeyDistributionMessage { groupID = 1;
/// axolotlSenderKeyDistributionMessage = 2; }). Returns false when the message carries none.
bool senderKeyDistribution(const(ubyte)[] messageProto, out string groupId, out const(ubyte)[] axolotl) {
    auto r = ProtoReader(innerMessage(messageProto));
    if (!r.has(MessageField.senderKeyDistribution)) return false;
    auto d = ProtoReader(r.get(MessageField.senderKeyDistribution).bytes);
    groupId = cast(string) d.get(1).bytes.idup;
    axolotl = d.get(2).bytes;
    return axolotl.length > 0;
}

/// What a Message is, by its top-level fields — names only, never content (safe to log).
/// Protocol messages also name their kind (history sync, app-state key share, revoke, …).
string messageKinds(const(ubyte)[] messageProto) {
    import std.conv : to;
    static immutable string[uint] names = [
        1: "conversation", 2: "senderKeyDistribution", 3: "image", 4: "contact", 5: "location",
        6: "extendedText", 7: "document", 8: "audio", 9: "video", 12: "protocol", 26: "sticker",
        31: "deviceSent", 35: "messageContextInfo", 40: "ephemeral", 46: "reaction", 58: "edited",
    ];
    static immutable string[uint] protoKinds = [
        0: "revoke", 3: "ephemeralSetting", 5: "historySyncNotification", 6: "appStateSyncKeyShare",
        7: "appStateSyncKeyRequest", 9: "initialSecurityNotification", 14: "messageEdit",
        11: "sharePhoneNumber", 16: "peerDataOperationRequest", 17: "peerDataOperationResponse",
        22: "lidMigrationMappingSync",
    ];
    string outv;
    bool[uint] seen;
    foreach (f; ProtoReader(innerMessage(messageProto))) {
        if (f.number in seen) continue;
        seen[f.number] = true;
        string n = f.number in names ? names[f.number] : "field" ~ f.number.to!string;
        if (f.number == MessageField.protocol) {
            auto p = ProtoReader(f.bytes);
            if (p.has(2)) {
                const t = cast(uint) p.get(2).value;
                n ~= ":" ~ (t in protoKinds ? protoKinds[t] : "type" ~ t.to!string);
            }
        }
        outv ~= (outv.length ? "," : "") ~ n;
    }
    return outv;
}

unittest {
    import wa.proto : ProtoWriter;

    // a plain text message: Message { conversation = "oi" }, then padded to pad-length 5
    ubyte[] proto = ProtoWriter().str(1, "oi").buf;
    assert(conversationText(proto) == "oi");
    ubyte[] padded = proto.dup;
    foreach (_; 0 .. 5) padded ~= cast(ubyte) 5;
    assert(unpad(padded) == proto);
    assert(conversationText(unpad(padded)) == "oi");
    assert(unpad(proto ~ cast(ubyte) 1, 2) == proto);   // minimal pad of 1
    assert(unpad(proto, 3) == proto);                   // v3: unpadded

    // extendedTextMessage { text = "https://x" } at field 6
    ubyte[] ext = ProtoWriter().str(1, "https://x").buf;
    ubyte[] withCtx = ProtoWriter().bytes(6, ext).buf;
    assert(conversationText(withCtx) == "https://x");
    // field 2 is senderKeyDistributionMessage, NOT text
    assert(conversationText(ProtoWriter().bytes(2, ext).buf) == "");

    // a message with no text (e.g. an image at field 3) → empty string, no throw
    assert(conversationText(ProtoWriter().bytes(3, [1, 2, 3]).buf) == "");

    // our own message echoed to our devices: deviceSentMessage { destinationJID = 1; message = 2 }
    ubyte[] dsm = ProtoWriter().bytes(31,
        ProtoWriter().str(1, "x@s.whatsapp.net").bytes(2, proto).buf).buf;
    assert(conversationText(dsm) == "oi");
    assert(messageKinds(dsm) == "conversation");

    // a protocol message names its kind: ProtocolMessage { type = 5 (history sync) }
    ubyte[] hs = ProtoWriter().bytes(12, ProtoWriter().varint(2, 5).buf).bytes(35, [1]).buf;
    assert(messageKinds(hs) == "protocol:historySyncNotification,messageContextInfo");
}

unittest {
    // the generated tables (tools/gen-wa-fields.py) agree with the numbers checked by hand
    import e2e = wa.pb.e2e;
    import hs = wa.pb.historysync;
    static assert(e2e.Message.conversation == MessageField.conversation);
    static assert(e2e.Message.extendedTextMessage == MessageField.extendedText);
    static assert(e2e.Message.protocolMessage == MessageField.protocol);
    static assert(e2e.Message.deviceSentMessage == MessageField.deviceSent);
    static assert(e2e.ExtendedTextMessage.contextInfo == 17);
    static assert(e2e.ProtocolMessage.Type.PEER_DATA_OPERATION_REQUEST_MESSAGE == 16);
    static assert(e2e.PeerDataOperationRequestType.PLACEHOLDER_MESSAGE_RESEND == 4);
    static assert(hs.HistorySync.nctSalt == 19 && hs.HistorySync.phoneNumberToLidMappings == 15);
}
