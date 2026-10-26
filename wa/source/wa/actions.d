/// The Message protobufs of the message menu's actions, as whatsmeow builds them (send.go:
/// BuildMessageKey, BuildReaction, BuildRevoke, BuildEdit; the Go core's sendPinInChat). Pure: the
/// time comes in, so they are checked byte for byte against whatsmeow's output (tests below).
module wa.actions;

import wa.proto : ProtoWriter;
import e2e = wa.pb.e2e;

/// BuildMessageKey: ours unless the sender is someone else (not our phone-number nor our LID user);
/// the participant (no device) only for someone else's message outside 1:1 chats.
/// `chat`, `sender`: JIDs as strings ("…@s.whatsapp.net", "…@g.us", "…@lid"); sender "" = ours.
ubyte[] messageKey(string chat, string sender, string id, string ownUser, string ownLidUser) {
    import wa.envelope : parseJidString;
    import wa.binary : Jid;
    auto s = parseJidString(sender);
    const fromMe = sender.length == 0 || s.user == ownUser || (ownLidUser.length && s.user == ownLidUser);
    auto k = ProtoWriter().str(1, chat).boolean(2, fromMe).str(3, id);
    const server = parseJidString(chat).server;
    if (!fromMe && server != "s.whatsapp.net" && server != "lid" && server != "msgr")
        k.str(4, Jid.pair(s.user, s.server).toString());
    return k.buf;
}

/// BuildReaction: "" takes the reaction back
ubyte[] reactionMessage(const(ubyte)[] key, string text, long ms) {
    auto r = ProtoWriter().bytes(e2e.ReactionMessage.key, key).str(e2e.ReactionMessage.text, text)
        .int64(e2e.ReactionMessage.senderTimestampMS, ms);
    return ProtoWriter().bytes(e2e.Message.reactionMessage, r.buf).buf;
}

/// BuildRevoke: delete for everyone
ubyte[] revokeMessage(const(ubyte)[] key) {
    auto pm = ProtoWriter().bytes(e2e.ProtocolMessage.key, key).varint(e2e.ProtocolMessage.type, e2e.ProtocolMessage.Type.REVOKE);
    return ProtoWriter().bytes(e2e.Message.protocolMessage, pm.buf).buf;
}

/// BuildEdit with a plain text (Message{conversation}) as the new content; the key is always ours
ubyte[] editMessage(string chat, string id, string text, long ms) {
    auto k = ProtoWriter().str(1, chat).boolean(2, true).str(3, id);
    auto pm = ProtoWriter().bytes(e2e.ProtocolMessage.key, k.buf)
        .varint(e2e.ProtocolMessage.type, e2e.ProtocolMessage.Type.MESSAGE_EDIT)
        .bytes(e2e.ProtocolMessage.editedMessage, ProtoWriter().str(e2e.Message.conversation, text).buf)
        .int64(e2e.ProtocolMessage.timestampMS, ms);
    auto fp = ProtoWriter().bytes(e2e.FutureProofMessage.message, ProtoWriter().bytes(e2e.Message.protocolMessage, pm.buf).buf);
    return ProtoWriter().bytes(e2e.Message.editedMessage, fp.buf).buf;
}

/// The Go core's sendPinInChat: PinInChatMessage {key, PIN_FOR_ALL / UNPIN_FOR_ALL, senderTimestampMS}
/// with MessageContextInfo {messageAddOnDurationInSecs}
ubyte[] pinMessage(const(ubyte)[] key, bool pin, long seconds, long ms) {
    auto pm = ProtoWriter().bytes(e2e.PinInChatMessage.key, key)
        .varint(e2e.PinInChatMessage.type, pin ? e2e.PinInChatMessage.Type.PIN_FOR_ALL : e2e.PinInChatMessage.Type.UNPIN_FOR_ALL)
        .int64(e2e.PinInChatMessage.senderTimestampMS, ms);
    auto ctx = ProtoWriter().varint(e2e.MessageContextInfo.messageAddOnDurationInSecs, cast(ulong) seconds);
    // canonical field order: messageContextInfo (35) before pinInChatMessage (63)
    return ProtoWriter().bytes(e2e.Message.messageContextInfo, ctx.buf).bytes(e2e.Message.pinInChatMessage, pm.buf).buf;
}

unittest {
    // byte for byte against whatsmeow (core/cmd/actionvec: BuildMessageKey, BuildReaction,
    // BuildRevoke, BuildEdit and the core's pin, own device 5511999990000:3 / LID 111222333444555:3)
    import std.conv : hexString;
    import std.digest : toHexString, LetterCase;
    string hx(const(ubyte)[] b) { return toHexString!(LetterCase.lower)(b).idup; }
    enum ms = 1_700_000_000_123L;
    {
        auto key = messageKey("5511900000001@s.whatsapp.net", "5511999990000@s.whatsapp.net", "3EB0ABCDEF", "5511999990000", "111222333444555");
        assert(hx(key) == "0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a33454230414243444546", "own-dm key");
        assert(hx(reactionMessage(key, "👍", ms)) == "f2023b0a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a334542304142434445461204f09f918d20fbd095ffbc31", "own-dm react");
        assert(hx(reactionMessage(key, "", ms)) == "f202370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a33454230414243444546120020fbd095ffbc31", "own-dm unreact");
        assert(hx(revokeMessage(key)) == "62300a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a334542304142434445461000", "own-dm revoke");
        assert(hx(pinMessage(key, true, 86_400, ms)) == "9a02042880a305fa03370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a33454230414243444546100118fbd095ffbc31", "own-dm pin");
        assert(hx(pinMessage(key, false, 86_400, ms)) == "9a02042880a305fa03370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a33454230414243444546100218fbd095ffbc31", "own-dm unpin");
    }
    {
        auto key = messageKey("5511900000001@s.whatsapp.net", "5511900000001@s.whatsapp.net", "3EB0ABCDEF", "5511999990000", "111222333444555");
        assert(hx(key) == "0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a33454230414243444546", "their-dm key");
        assert(hx(reactionMessage(key, "👍", ms)) == "f2023b0a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a334542304142434445461204f09f918d20fbd095ffbc31", "their-dm react");
        assert(hx(reactionMessage(key, "", ms)) == "f202370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a33454230414243444546120020fbd095ffbc31", "their-dm unreact");
        assert(hx(revokeMessage(key)) == "62300a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a334542304142434445461000", "their-dm revoke");
        assert(hx(pinMessage(key, true, 86_400, ms)) == "9a02042880a305fa03370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a33454230414243444546100118fbd095ffbc31", "their-dm pin");
        assert(hx(pinMessage(key, false, 86_400, ms)) == "9a02042880a305fa03370a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410001a0a33454230414243444546100218fbd095ffbc31", "their-dm unpin");
    }
    {
        auto key = messageKey("120363000000000001@g.us", "5511900000002:5@s.whatsapp.net", "3EB0ABCDEF", "5511999990000", "111222333444555");
        assert(hx(key) == "0a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e6574", "their-group key");
        assert(hx(reactionMessage(key, "👍", ms)) == "f202540a450a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e65741204f09f918d20fbd095ffbc31", "their-group react");
        assert(hx(reactionMessage(key, "", ms)) == "f202500a450a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e6574120020fbd095ffbc31", "their-group unreact");
        assert(hx(revokeMessage(key)) == "62490a450a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e65741000", "their-group revoke");
        assert(hx(pinMessage(key, true, 86_400, ms)) == "9a02042880a305fa03500a450a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e6574100118fbd095ffbc31", "their-group pin");
        assert(hx(pinMessage(key, false, 86_400, ms)) == "9a02042880a305fa03500a450a1731323033363330303030303030303030303140672e757310001a0a33454230414243444546221c3535313139303030303030303240732e77686174736170702e6e6574100218fbd095ffbc31", "their-group unpin");
    }
    {
        auto key = messageKey("120363000000000001@g.us", "987654321098765@lid", "3EB0ABCDEF", "5511999990000", "111222333444555");
        assert(hx(key) == "0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c6964", "lid-group key");
        assert(hx(reactionMessage(key, "👍", ms)) == "f2024b0a3c0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c69641204f09f918d20fbd095ffbc31", "lid-group react");
        assert(hx(reactionMessage(key, "", ms)) == "f202470a3c0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c6964120020fbd095ffbc31", "lid-group unreact");
        assert(hx(revokeMessage(key)) == "62400a3c0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c69641000", "lid-group revoke");
        assert(hx(pinMessage(key, true, 86_400, ms)) == "9a02042880a305fa03470a3c0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c6964100118fbd095ffbc31", "lid-group pin");
        assert(hx(pinMessage(key, false, 86_400, ms)) == "9a02042880a305fa03470a3c0a1731323033363330303030303030303030303140672e757310001a0a334542304142434445462213393837363534333231303938373635406c6964100218fbd095ffbc31", "lid-group unpin");
    }
    {
        auto key = messageKey("120363000000000001@g.us", "111222333444555@lid", "3EB0ABCDEF", "5511999990000", "111222333444555");
        assert(hx(key) == "0a1731323033363330303030303030303030303140672e757310011a0a33454230414243444546", "own-lid-group key");
        assert(hx(reactionMessage(key, "👍", ms)) == "f202360a270a1731323033363330303030303030303030303140672e757310011a0a334542304142434445461204f09f918d20fbd095ffbc31", "own-lid-group react");
        assert(hx(reactionMessage(key, "", ms)) == "f202320a270a1731323033363330303030303030303030303140672e757310011a0a33454230414243444546120020fbd095ffbc31", "own-lid-group unreact");
        assert(hx(revokeMessage(key)) == "622b0a270a1731323033363330303030303030303030303140672e757310011a0a334542304142434445461000", "own-lid-group revoke");
        assert(hx(pinMessage(key, true, 86_400, ms)) == "9a02042880a305fa03320a270a1731323033363330303030303030303030303140672e757310011a0a33454230414243444546100118fbd095ffbc31", "own-lid-group pin");
        assert(hx(pinMessage(key, false, 86_400, ms)) == "9a02042880a305fa03320a270a1731323033363330303030303030303030303140672e757310011a0a33454230414243444546100218fbd095ffbc31", "own-lid-group unpin");
    }
    assert(hx(editMessage("5511900000001@s.whatsapp.net", "3EB0ABCDEF", "texto novo ✏️", ms)) == "d203500a4e624c0a2c0a1c3535313139303030303030303140732e77686174736170702e6e657410011a0a33454230414243444546100e72130a11746578746f206e6f766f20e29c8fefb88f78fbd095ffbc31", "edit");
}
