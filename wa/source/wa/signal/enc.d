/// The `<enc>` node that carries a Signal ciphertext inside a `<message>` stanza, and its inverse.
/// This is the bridge between the double ratchet (wa.signal.session) and the wire: on the way out a
/// CipherText becomes `<enc v="2" type="msg|pkmsg">…</enc>`; on the way in such a node is decrypted
/// back to a WhatsApp `Message` protobuf (unpadded). Matches whatsmeow's encryptMessageForDevice /
/// decryptDM: type "pkmsg" is a PreKeySignalMessage, "msg" a SignalMessage, and v="2" is padded.
module wa.signal.enc;

import wa.binary.node;
import wa.device : Device;
import wa.message : unpad;
import wa.signal : PreKeySignalMessage, parsePreKeyMessage;
import wa.signal.session : CipherText, SessionRecord, SessionState;

class EncException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Build the `<enc>` node for a ciphertext (v="2", type from the ciphertext's Signal type).
Node encNode(const CipherText ct) {
    Node n = Node("enc");
    n.attrs ~= Attr("v", Value("2"));
    n.attrs ~= Attr("type", Value(ct.type == 3 ? "pkmsg" : "msg"));
    n.hasBytes = true;
    n.bytes = ct.wire.idup;
    return n;
}

/// Decrypt an `<enc>` node against a session record, returning the unpadded WhatsApp `Message`
/// protobuf bytes. For a "pkmsg" a new session state is built when its base key is new
/// (`newSession` reports it, so the caller consumes that one-time pre-key); `findOneTimePriv`
/// yields the private half of the one-time pre-key the message names (null if none / not found).
ubyte[] decryptEnc(ref SessionRecord rec, ref const Device dev, const ref Node enc,
    const(ubyte)[] delegate(uint preKeyId) findOneTimePriv, out bool newSession, out uint preKeyId) {
    if (enc.tag != "enc" || !enc.hasBytes) throw new EncException("not an <enc> node");
    const type = enc.get("type");
    const int v = enc.get("v", "2") == "3" ? 3 : 2;

    ubyte[] plain;
    if (type == "pkmsg") {
        auto pk = parsePreKeyMessage(enc.bytes);
        const(ubyte)[] oneTime = pk.hasPreKeyId && findOneTimePriv !is null
            ? findOneTimePriv(pk.preKeyId) : null;
        plain = rec.decryptPreKey(dev, pk, oneTime, newSession);
        if (newSession && pk.hasPreKeyId) preKeyId = pk.preKeyId;
    } else if (type == "msg") {
        plain = rec.decrypt(enc.bytes);
    } else {
        throw new EncException("unsupported <enc type=\"" ~ type ~ "\">");
    }
    return unpad(plain, v).dup;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.crypto : KeyPair;
    import wa.message : pad;
    import wa.proto : ProtoWriter;
    import wa.signal.session : PreKeyBundle;
}

unittest {
    // End to end at the wire level: Alice encrypts a Message, wraps it in <enc>, it round-trips the
    // WAP codec, and Bob decrypts the node back to the same Message protobuf.
    auto alice = Device.create();
    auto bob = Device.create();
    auto bobOneTime = KeyPair.generate();

    PreKeyBundle b;
    b.registrationId = bob.registrationId;
    b.identityKey = bob.identityKey.pub;
    b.signedPreKeyId = bob.signedPreKey.id;
    b.signedPreKey = bob.signedPreKey.key.pub;
    b.signedPreKeySignature = bob.signedPreKey.signature;
    b.hasOneTime = true;
    b.preKeyId = 55;
    b.preKey = bobOneTime.pub;

    SessionRecord aliceS;
    aliceS.promote(SessionState.initiate(alice, b));

    // a real-ish payload: Message { conversation = "oi pelo fio" }
    ubyte[] msgProto = ProtoWriter().str(1, "oi pelo fio").buf;
    auto ct = aliceS.current.encrypt(pad(msgProto));
    auto node = encNode(ct);
    assert(node.get("type") == "pkmsg" && node.get("v") == "2");

    auto encoded = encodeStanza(node);
    auto back = decodeStanza(encoded);
    SessionRecord bobS;
    bool fresh;
    uint usedId;
    auto got = decryptEnc(bobS, bob, back, (uint id) => id == 55 ? bobOneTime.priv[] : null, fresh, usedId);
    assert(fresh && usedId == 55);
    assert(got == msgProto);

    // a follow-up is a plain "msg" once Bob has replied (Alice ratchets); check that path too
    auto reply = bobS.current.encrypt(pad(ProtoWriter().str(1, "oi de volta").buf));
    assert(reply.type == 2);
    auto replyEncNode = encNode(reply);
    auto replyEncoded = encodeStanza(replyEncNode);
    auto replyNode = decodeStanza(replyEncoded);
    auto gotReply = decryptEnc(aliceS, alice, replyNode, null, fresh, usedId);
    assert(!fresh);
    assert(gotReply == ProtoWriter().str(1, "oi de volta").buf);
}
