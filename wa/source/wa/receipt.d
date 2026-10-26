/// Acknowledgements and receipts — the small stanzas a connected client must send back so the
/// server (and the sender) know a message arrived. Every routed stanza (message/receipt/notification
/// /call) gets an `<ack>`; an incoming chat message also gets a `<receipt>` (delivered), and
/// `<receipt type=read>` when the user opens it. Mirrors whatsmeow's sendAck / sendMessageReceipt.
module wa.receipt;

import std.conv : to;
import wa.binary.node;

/// Copy an attribute (keeping its JID-ness) from `src` to `dst` if present.
private void copyAttr(ref Node dst, const ref Node src, string key, string asKey = null) {
    auto v = src.attr(key);
    if (v is null) return;
    dst.attrs ~= Attr(asKey is null ? key : asKey, *cast(Value*) v);
}

/// The `<ack>` for a routed stanza: class = its tag, id/to (and participant/recipient) echoed back.
/// `type` is carried only for non-message stanzas; `error` only when non-zero.
Node ackStanza(const ref Node received, int error = 0) {
    Node a = Node("ack");
    a.attrs ~= Attr("class", Value(received.tag));
    copyAttr(a, received, "id");
    copyAttr(a, received, "from", "to");
    copyAttr(a, received, "participant");
    copyAttr(a, received, "recipient");
    // sendAck: a message to a bot is acked to the bot's phone-number JID (BotJIDMap)
    if (received.tag == "message") if (auto rv = received.attr("recipient")) {
        import wa.pb.botmap : botJIDMap;
        import wa.envelope : parseJidString;
        import std.string : indexOf;
        const r = rv.toString();
        const at = r.indexOf('@');
        if (at > 0 && r[at + 1 .. $] == "bot")
            if (auto pn = r[0 .. at] in botJIDMap)
                foreach (ref x; a.attrs) if (x.key == "recipient") x.value = Value(parseJidString(*pn ~ "@s.whatsapp.net"));
    }
    if (received.tag != "message" && received.attr("type") !is null)
        copyAttr(a, received, "type");
    if (error != 0) a.attrs ~= Attr("error", Value(error.to!string));
    return a;
}

/// A delivery `<receipt>` for an incoming message (echoes id/to/participant/recipient). Pass
/// `type_` = "read" / "played" for a read or played receipt; leave it empty for plain delivery.
Node messageReceipt(const ref Node received, string type_ = null) {
    Node r = Node("receipt");
    copyAttr(r, received, "id");
    copyAttr(r, received, "from", "to");
    copyAttr(r, received, "recipient");
    copyAttr(r, received, "participant");
    if (type_.length) r.attrs ~= Attr("type", Value(type_));
    return r;
}

/// The key material a retry receipt carries from the second attempt on (or when a group sender
/// key is missing), so the sender can rebuild the session: whatsmeow sendRetryReceipt's <keys>.
struct RetryKeys {
    ubyte[32] identityPub;
    uint oneTimeId;
    ubyte[32] oneTimePub;
    uint signedId;
    ubyte[32] signedPub;
    ubyte[64] signedSig;
    const(ubyte)[] account;      // our ADVSignedDeviceIdentity (device-identity)
}

/// `<receipt type="retry">` asking the sender to re-encrypt a message we could not decrypt:
/// base attrs (id/to/participant/recipient), `<retry count id t v=1/>`, `<registration>`, and
/// `<keys>` when given. `peer` adds category="peer" (a peer_msg from our own devices).
Node retryReceipt(const ref Node received, int count, uint registrationId, bool peer,
    const RetryKeys* keys = null) {
    import wa.prekey : preKeyNode;
    import wa.device : djbType;
    Node r = Node("receipt");
    copyAttr(r, received, "id");
    copyAttr(r, received, "from", "to");
    copyAttr(r, received, "recipient");
    copyAttr(r, received, "participant");
    r.attrs ~= Attr("type", Value("retry"));
    if (peer) r.attrs ~= Attr("category", Value("peer"));

    Node retry = Node("retry");
    retry.attrs ~= Attr("count", Value(count.to!string));
    copyAttr(retry, received, "id");
    copyAttr(retry, received, "t");
    retry.attrs ~= Attr("v", Value("1"));
    r.children ~= retry;

    ubyte[] reg = [cast(ubyte)(registrationId >> 24), cast(ubyte)(registrationId >> 16),
        cast(ubyte)(registrationId >> 8), cast(ubyte) registrationId];
    r.children ~= leafNode("registration", reg);

    if (keys !is null) {
        Node k = Node("keys");
        k.children ~= leafNode("type", [djbType]);
        k.children ~= leafNode("identity", keys.identityPub[]);
        k.children ~= preKeyNode(keys.oneTimeId, keys.oneTimePub);
        k.children ~= preKeyNode(keys.signedId, keys.signedPub, keys.signedSig[]);
        k.children ~= leafNode("device-identity", keys.account);
        r.children ~= k;
    }
    return r;
}

private Node leafNode(string tag, const(ubyte)[] content) {
    Node n = Node(tag);
    n.hasBytes = true;
    n.bytes = content.idup;
    return n;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
}

unittest {
    // a retry receipt for a 1:1 message: base attrs, <retry>, <registration>, and <keys> when asked
    auto msg = node("message", [["id", "M9"], ["t", "1700000000"], ["type", "text"]]);
    msg.attrs ~= Attr("from", Value(Jid.pair("118", "lid")));
    auto plain = retryReceipt(msg, 1, 0x01020304, false);
    auto back = decodeStanza(encodeStanza(plain));
    assert(back.get("type") == "retry" && back.get("id") == "M9" && back.get("to") == "118@lid");
    assert(back.child("retry").get("count") == "1" && back.child("retry").get("t") == "1700000000");
    assert(back.child("retry").get("v") == "1");
    assert(back.child("registration").bytes == [1, 2, 3, 4]);
    assert(back.child("keys") is null);

    RetryKeys k;
    k.oneTimeId = 77;
    k.signedId = 1;
    k.account = [9, 9];
    auto withKeys = retryReceipt(msg, 2, 7, true, &k);
    auto b2 = decodeStanza(encodeStanza(withKeys));
    assert(b2.get("category") == "peer" && b2.child("retry").get("count") == "2");
    const keys = b2.child("keys");
    assert(keys !is null && keys.child("key") !is null && keys.child("skey") !is null);
    assert(keys.child("device-identity").bytes == [9, 9] && keys.child("type").bytes == [5]);
}

unittest {
    // An incoming group message: its ack echoes class/id/to/participant; the receipt mirrors id/to.
    auto msg = node("message", [["id", "MID1"], ["type", "text"]]);
    msg.attrs ~= Attr("from", Value(Jid.pair("123-456", "g.us")));
    msg.attrs ~= Attr("participant", Value(Jid.deviceJid("5511999", Jid.Domain.whatsapp, 0)));

    auto ackN = ackStanza(msg);
    auto ack = decodeStanza(encodeStanza(ackN));
    assert(ack.tag == "ack");
    assert(ack.get("class") == "message" && ack.get("id") == "MID1");
    assert(ack.get("to") == "123-456@g.us");
    assert(ack.get("participant") == "5511999@s.whatsapp.net");
    assert(ack.attr("type") is null);        // message acks carry no type

    auto rcptN = messageReceipt(msg);
    auto rcpt = decodeStanza(encodeStanza(rcptN));
    assert(rcpt.tag == "receipt" && rcpt.get("id") == "MID1" && rcpt.get("to") == "123-456@g.us");
    assert(rcpt.attr("type") is null);       // plain delivery

    auto readN = messageReceipt(msg, "read");
    auto read = decodeStanza(encodeStanza(readN));
    assert(read.get("type") == "read");
}

unittest {
    // A non-message stanza (a receipt) carries its type into the ack, and an error is attached.
    auto incoming = node("receipt", [["id", "R1"], ["type", "retry"]]);
    incoming.attrs ~= Attr("from", Value(Jid.pair("5511888", "s.whatsapp.net")));
    auto ackN2 = ackStanza(incoming, 503);
    auto ack = decodeStanza(encodeStanza(ackN2));
    assert(ack.get("class") == "receipt" && ack.get("type") == "retry" && ack.get("error") == "503");
}

unittest {
    // a message to a bot is acked to the bot's phone-number JID (whatsmeow sendAck)
    import wa.pb.botmap : botJIDMap;
    import wa.envelope : parseJidString;
    string bot, pn;
    foreach (b, p; botJIDMap) { bot = b; pn = p; break; }
    Node m = Node("message");
    m.attrs ~= Attr("id", Value("X"));
    m.attrs ~= Attr("from", Value(parseJidString("123@s.whatsapp.net")));
    m.attrs ~= Attr("recipient", Value(parseJidString(bot ~ "@bot")));
    assert(ackStanza(m).get("recipient") == pn ~ "@s.whatsapp.net");
    Node r = Node("receipt");
    r.attrs ~= Attr("id", Value("X"));
    r.attrs ~= Attr("recipient", Value(parseJidString(bot ~ "@bot")));
    assert(ackStanza(r).get("recipient") == bot ~ "@bot");
}

/// A read receipt for messages in `chat` (whatsmeow MarkRead): `<receipt id=ids[0] type t to>`, the
/// other ids as `<list><item id/>…</list>`, and `participant` = the sender (without device) in groups
/// and broadcasts. `readSelf` (read receipts turned off in our privacy settings, or a channel) only
/// syncs the read state to our own devices.
Node readReceipt(const string[] ids, Jid chat, Jid sender, long t, bool readSelf) {
    return typedReceipt(ids, chat, sender, t, readSelf ? "read-self" : "read");
}

/// whatsmeow MarkRead with a receipt type: "read" / "read-self" (readReceipt), "played" (a voice note
/// listened to — it stays "played" whatever the read-receipts setting)
Node typedReceipt(const string[] ids, Jid chat, Jid sender, long t, string type_) {
    assert(ids.length > 0);
    Node r = Node("receipt");
    r.attrs ~= Attr("id", Value(ids[0]));
    r.attrs ~= Attr("type", Value(type_));
    r.attrs ~= Attr("to", Value(chat));
    r.attrs ~= Attr("t", Value(t.to!string));
    if (sender.user.length && chat.server != "s.whatsapp.net" && chat.server != "lid" && chat.server != "msgr")
        r.attrs ~= Attr("participant", Value(Jid.pair(sender.user, sender.server)));
    if (ids.length > 1) {
        Node list = Node("list");
        foreach (id; ids[1 .. $]) {
            Node it = Node("item");
            it.attrs ~= Attr("id", Value(id));
            list.children ~= it;
        }
        r.children ~= list;
    }
    return r;
}

unittest {
    import wa.envelope : parseJidString;
    // a group: one receipt per sender, participant without the device; the rest of the ids in a list
    auto g = readReceipt(["A", "B", "C"], parseJidString("123-456@g.us"), parseJidString("5511:3@s.whatsapp.net"), 1700000000, false);
    assert(g.get("id") == "A" && g.get("type") == "read" && g.get("to") == "123-456@g.us" && g.get("t") == "1700000000");
    assert(g.get("participant") == "5511@s.whatsapp.net");
    assert(g.children.length == 1 && g.children[0].tag == "list" && g.children[0].children.length == 2
        && g.children[0].children[1].get("id") == "C");
    // a 1:1 chat: no participant, a single id has no list; read receipts off → read-self
    auto d = readReceipt(["X"], parseJidString("5511@s.whatsapp.net"), parseJidString("5511@s.whatsapp.net"), 5, true);
    assert(d.get("type") == "read-self" && d.attr("participant") is null && d.children.length == 0);
}
