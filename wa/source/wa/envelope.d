/// The `<message>` stanza envelope: the routing layer around the `<enc>` payloads. Inbound, it
/// tells us who sent a message (chat, sender device, group-or-not, from-me) and hands over the
/// `<enc>` children to decrypt; outbound, it wraps our ciphertexts for each recipient device into
/// the `<participants>` fan-out WhatsApp expects. Mirrors whatsmeow's parseMessageSource/
/// parseMessageInfo and prepareMessageNode for the 1:1 case (groups parse but skmsg is a later
/// layer). The Signal store address is `user:device`, as libsignal's SignalAddress.String().
module wa.envelope;

import std.conv : to;
import wa.binary.node;
import wa.device : Device;
import wa.messages : decryptEncFromStore;
import wa.store.db : Store;

enum string groupServer = "g.us";
enum string broadcastServer = "broadcast";

/// The Signal protocol store key for a device JID: "user:device".
string signalAddress(const Jid j) {
    return j.user ~ ":" ~ j.device.to!string;
}

/// Who a message is from and to.
struct MessageSource {
    Jid chat;                // the conversation (the peer for 1:1, the group for groups)
    Jid sender;              // the device that sent it (participant in a group)
    bool isGroup;
    bool isFromMe;
    string addressingMode;   // "" , "pn", or "lid"
    Jid senderAlt;           // the same sender in the other namespace (LID ↔ phone), when given
    Jid recipientAlt;        // our own DM: the chat in the other namespace (peer_recipient_pn/_lid)

    /// The JID whose Signal sessions/sender keys decrypt this sender's messages: the LID when the
    /// stanza names the sender by phone but also gives its LID (whatsmeow's encryption identity).
    Jid encryptionIdentity() const {
        if (sender.server == "s.whatsapp.net" && senderAlt.server == "lid") return senderAlt;
        return sender;
    }
}

/// A parsed inbound `<message>`: its metadata and the raw `<enc>` children to decrypt.
struct IncomingMessage {
    string id;
    long timestamp;
    string type_;
    string pushName;
    string verifiedName;   // a business's, from the message's <verified_name> certificate
    MessageSource source;
    const(Node)[] encs;
}

/// Read a JID-valued attribute (the codec decodes JID tokens to Jid values; fall back to parsing).
Jid jidAttr(const ref Node n, string key) {
    auto v = n.attr(key);
    if (v is null) return Jid.init;
    if (v.isJid) return v.jid;
    return parseJidString(v.str);
}

/// Parse "user@server", "user:device@server", or a bare server into a Jid.
Jid parseJidString(string s) {
    import std.string : indexOf;
    const at = s.indexOf('@');
    if (at < 0) return Jid.pair(null, s);
    string local = s[0 .. at];
    string server = s[at + 1 .. $];
    const colon = local.indexOf(':');
    if (colon < 0) return Jid.pair(local, server);
    const dom = server == "lid" ? Jid.Domain.lid : Jid.Domain.whatsapp;
    return Jid.deviceJid(local[0 .. colon], dom, local[colon + 1 .. $].to!ushort);
}

/// Parse a `<message>` stanza. `ownUser` is our own phone/user part and `ownLidUser` our LID user
/// part (messages from our own devices may come addressed by either), to flag from-me.
IncomingMessage parseMessageStanza(const ref Node msg, string ownUser, string ownLidUser = null) {
    IncomingMessage m;
    m.id = msg.get("id");
    m.type_ = msg.get("type");
    m.pushName = msg.get("notify");
    {
        import wa.usync : verifiedNameOf;
        m.verifiedName = verifiedNameOf(msg.child("verified_name"));
    }
    if (const t = msg.get("t")) { try m.timestamp = t.to!long; catch (Exception) {} }

    auto from = jidAttr(msg, "from");
    m.source.addressingMode = msg.get("addressing_mode");
    if (from.server == groupServer || from.server == broadcastServer) {
        m.source.isGroup = true;
        m.source.chat = from;
        m.source.sender = jidAttr(msg, "participant");
    } else {
        m.source.sender = from;
        auto recipient = msg.attr("recipient");
        if (from.user == ownUser || (ownLidUser.length && from.user == ownLidUser)) {
            m.source.isFromMe = true;
            m.source.chat = recipient !is null ? jidAttr(msg, "recipient") : Jid.pair(from.user, from.server);
            const altKey = m.source.chat.server == "lid" ? "peer_recipient_pn" : "peer_recipient_lid";
            if (msg.attr(altKey) !is null) m.source.recipientAlt = jidAttr(msg, altKey);
        } else {
            m.source.chat = Jid.pair(from.user, from.server);
        }
    }
    if (m.source.sender.user == ownUser || (ownLidUser.length && m.source.sender.user == ownLidUser))
        m.source.isFromMe = true;

    // the alternate identity (whatsmeow parseMessageSource): participant_pn / participant_lid in
    // groups, sender_pn / sender_lid in 1:1; it comes without a device, so it inherits the sender's
    const altKeys = m.source.isGroup ? ["participant_pn", "participant_lid"] : ["sender_pn", "sender_lid"];
    foreach (k; altKeys)
        if (msg.attr(k) !is null) { m.source.senderAlt = jidAttr(msg, k); break; }
    if (m.source.senderAlt.user.length && m.source.senderAlt.device == 0 && m.source.sender.device != 0) {
        const alt = m.source.senderAlt;
        m.source.senderAlt = Jid.deviceJid(alt.user,
            alt.server == "lid" ? Jid.Domain.lid : Jid.Domain.whatsapp, m.source.sender.device);
    }

    foreach (ref c; msg.children)
        if (c.tag == "enc") m.encs ~= c;
    return m;
}

/// Decrypt every `<enc>` in a parsed 1:1 message against the store, returning the unpadded
/// WhatsApp `Message` protobuf for each (skmsg/group payloads are skipped for now).
ubyte[][] decryptMessage(Store store, ref const Device dev, const ref IncomingMessage m) {
    ubyte[][] out_;
    const encId = m.source.encryptionIdentity();
    const addr = signalAddress(encId);
    foreach (ref enc; m.encs) {
        const t = enc.get("type");
        if (t != "msg" && t != "pkmsg") continue;   // skmsg (groups) handled elsewhere
        out_ ~= decryptEncFromStore(store, dev, addr, enc);
    }
    return out_;
}

/// A recipient device and the `<enc>` we encrypted for it.
struct EncTarget {
    Jid device;
    Node enc;
}

/// Build an outbound `<message>` for a 1:1 chat: the per-device `<enc>` nodes wrapped in
/// `<participants>`, plus a `<device-identity>` when any of them is a pre-key message.
Node buildMessageStanza(string id, Jid to, string type_, EncTarget[] targets,
    const(ubyte)[] deviceIdentity = null) {
    Node parts = Node("participants");
    foreach (ref t; targets) {
        Node toNode = Node("to");
        toNode.attrs ~= Attr("jid", Value(t.device));
        toNode.children ~= t.enc;
        parts.children ~= toNode;
    }

    auto msg = node("message", [["id", id], ["type", type_], ["to", to.toString()]]);
    msg.attr("to").jid = to;
    msg.attr("to").isJid = true;
    msg.children ~= parts;
    if (deviceIdentity !is null) {
        Node di = Node("device-identity");
        di.hasBytes = true;
        di.bytes = deviceIdentity.idup;
        msg.children ~= di;
    }
    return msg;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.crypto : KeyPair;
    import wa.messages : encryptEncToStore;
    import wa.proto : ProtoWriter;
    import wa.signal.session : PreKeyBundle;
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
}

unittest {
    // Inbound parse: a 1:1 message from a peer, with one <enc>.
    auto from = Jid.deviceJid("5511988887777", Jid.Domain.whatsapp, 3);
    auto msg = node("message", [["id", "ABC123"], ["t", "1700000000"], ["type", "text"],
        ["notify", "Fulano"]]);
    msg.attrs ~= Attr("from", Value(from));
    Node enc = Node("enc");
    enc.attrs ~= Attr("v", Value("2"));
    enc.attrs ~= Attr("type", Value("pkmsg"));
    enc.hasBytes = true;
    enc.bytes = [1, 2, 3];
    msg.children ~= enc;

    auto parsed = parseMessageStanza(msg, "5550000");
    assert(parsed.id == "ABC123");
    assert(parsed.timestamp == 1_700_000_000);
    assert(parsed.type_ == "text");
    assert(parsed.pushName == "Fulano");
    assert(!parsed.source.isGroup && !parsed.source.isFromMe);
    assert(parsed.source.sender.user == "5511988887777" && parsed.source.sender.device == 3);
    assert(signalAddress(parsed.source.sender) == "5511988887777:3");
    assert(parsed.encs.length == 1 && parsed.encs[0].get("type") == "pkmsg");
}

unittest {
    // Full round-trip over the wire: Alice builds a <message> to Bob's device, it goes through the
    // WAP codec, Bob parses the envelope and decrypts the payload from his store.
    const ap = tempDir ~ "/wa-env-a-" ~ thisProcessID.to!string ~ ".db";
    const bp = tempDir ~ "/wa-env-b-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (p; [ap, bp]) foreach (s; ["", "-wal", "-shm"]) if (exists(p ~ s)) remove(p ~ s);

    auto alice = Device.create();
    auto bob = Device.create();
    auto aStore = new Store(ap);
    auto bStore = new Store(bp);

    auto bobOneTime = KeyPair.generate();
    bStore.putPreKey(55, bobOneTime);
    PreKeyBundle bundle = {
        registrationId: bob.registrationId, identityKey: bob.identityKey.pub,
        signedPreKeyId: bob.signedPreKey.id, signedPreKey: bob.signedPreKey.key.pub,
        signedPreKeySignature: bob.signedPreKey.signature,
        hasOneTime: true, preKeyId: 55, preKey: bobOneTime.pub
    };

    auto bobDevice = Jid.deviceJid("5511988887777", Jid.Domain.whatsapp, 0);
    auto aliceDevice = Jid.deviceJid("5511955554444", Jid.Domain.whatsapp, 0);

    ubyte[] proto = ProtoWriter().str(1, "ola pelo envelope").buf;
    auto enc = encryptEncToStore(aStore, alice, signalAddress(bobDevice), proto, &bundle);
    auto stanza = buildMessageStanza("MSG1", bobDevice, "text", [EncTarget(bobDevice, enc)]);

    auto wire = encodeStanza(stanza);
    auto back = decodeStanza(wire);
    assert(back.tag == "message" && back.get("id") == "MSG1");

    // Bob receives it: the <enc> sits under <participants>/<to>; pull it up as a direct child,
    // which is how the server delivers a 1:1 to the recipient.
    auto delivered = node("message", [["id", "MSG1"], ["t", "1700000001"], ["type", "text"]]);
    delivered.attrs ~= Attr("from", Value(aliceDevice));
    auto toNode = back.child("participants").children[0];
    delivered.children ~= toNode.children[0];   // the <enc>

    auto parsed = parseMessageStanza(delivered, "5511988887777");
    auto plains = decryptMessage(bStore, bob, parsed);
    assert(plains.length == 1 && plains[0] == proto);
}
