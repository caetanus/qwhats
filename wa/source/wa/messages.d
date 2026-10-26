/// Store-backed message crypto: the glue that lets a connected client decrypt an incoming `<enc>`
/// and encrypt an outgoing one while keeping each peer's double-ratchet session and one-time
/// pre-keys in our SQLite store. The surrounding `<message>` stanza (routing, device lists,
/// receipts) is a separate layer; this is the part that touches the ratchet and the store.
module wa.messages;

import wa.binary.node;
import wa.crypto : KeyPair;
import wa.device : Device;
import wa.message : pad;
import wa.signal : parsePreKeyMessage;
import wa.signal.enc : decryptEnc, encNode;
import wa.signal.session : CipherText, PreKeyBundle, SessionRecord, SessionState;
import wa.store.db : Store;

/// Decrypt an `<enc>` from `address` (the peer device's Signal address, e.g. "5511…:3"), using and
/// updating the session record stored for it. As libsignal/whatsmeow: the one-time pre-key a
/// `pkmsg` names is consumed only when it built a new session, and a `pkmsg` with state="false"
/// is decrypted without storing the session. Returns the unpadded WhatsApp `Message` protobuf.
ubyte[] decryptEncFromStore(Store store, ref const Device dev, string address, const ref Node enc) {
    SessionRecord rec;
    if (store.hasSession(address)) rec = SessionRecord.deserialize(store.session(address));
    auto findOneTime = delegate const(ubyte)[](uint id) {
        KeyPair kp;
        return store.preKey(id, kp) ? kp.priv[].dup : null;
    };
    bool newSession;
    uint usedPreKey;
    auto plain = decryptEnc(rec, dev, enc, findOneTime, newSession, usedPreKey);
    const stateless = enc.get("type") == "pkmsg" && enc.get("state") == "false";
    if (!stateless) store.putSession(address, rec.serialize());
    if (usedPreKey) store.removePreKey(usedPreKey);   // one-time keys are used once
    return plain;
}

/// Encrypt a WhatsApp `Message` protobuf for `address`, using the stored session (or starting one
/// from `bundle` when there is none, or when a bundle is given to replace it — ProcessBundle
/// archives the current state), and return the `<enc>` node. The updated record is saved.
Node encryptEncToStore(Store store, ref const Device dev, string address,
    const(ubyte)[] messageProto, const PreKeyBundle* bundle = null) {
    SessionRecord rec;
    if (store.hasSession(address)) rec = SessionRecord.deserialize(store.session(address));
    if (bundle !is null) {
        rec.promote(SessionState.initiate(dev, *bundle));
    } else if (!rec.current.established) {
        import wa.signal : SignalException;
        throw new SignalException("no session with " ~ address ~ " and no bundle to start one");
    }
    auto ct = rec.current.encrypt(pad(messageProto));
    store.putSession(address, rec.serialize());
    return encNode(ct);
}

/// The store key of one member's sender key in one group (libsignal's SenderKeyName).
string senderKeyName(string groupJid, string senderAddress) { return groupJid ~ "::" ~ senderAddress; }

/// A peer handed us its sender key for a group (from a decrypted Message's field 2).
void processSenderKeyDistributionToStore(Store store, string groupJid, string senderAddress, const(ubyte)[] axolotl) {
    import wa.signal.group : SenderKeyRecord, parseSenderKeyDistribution;
    const name = senderKeyName(groupJid, senderAddress);
    auto raw = store.senderKey(name);
    auto rec = raw is null ? SenderKeyRecord.init : SenderKeyRecord.deserialize(raw);
    rec.process(parseSenderKeyDistribution(axolotl));
    store.putSenderKey(name, rec.serialize());
}

/// Decrypt a group `<enc type="skmsg">` with the sender's stored sender key; returns the unpadded
/// Message protobuf. Throws when we never got that sender's key (it must be re-requested).
ubyte[] decryptGroupEncFromStore(Store store, string groupJid, string senderAddress, const ref Node enc) {
    import wa.message : unpad;
    import wa.signal.group : SenderKeyRecord;
    import wa.signal : SignalException;
    const name = senderKeyName(groupJid, senderAddress);
    auto raw = store.senderKey(name);
    if (raw is null) throw new SignalException("no sender key for " ~ senderAddress ~ " in this group");
    auto rec = SenderKeyRecord.deserialize(raw);
    auto plain = rec.decrypt(enc.bytes);
    store.putSenderKey(name, rec.serialize());
    return unpad(plain, enc.get("v", "2") == "3" ? 3 : 2).dup;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.proto : ProtoWriter;
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
}

unittest {
    // Group path through the store: Alice's sender key is distributed to Bob (as the field-2
    // payload of a 1:1 message would carry it), then her skmsg decrypts from Bob's store.
    import wa.signal.group : SenderKeyRecord, serializeSenderKeyDistribution;
    const bp = tempDir ~ "/wa-msg-g-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(bp ~ s)) remove(bp ~ s);
    auto bStore = new Store(bp);

    auto alice = SenderKeyRecord.createOwn();
    processSenderKeyDistributionToStore(bStore, "g1@g.us", "alice:0",
        serializeSenderKeyDistribution(alice.distribution()));
    foreach (text; ["primeira", "segunda"]) {
        Node enc = Node("enc");
        enc.attrs ~= Attr("v", Value("2"));
        enc.attrs ~= Attr("type", Value("skmsg"));
        enc.hasBytes = true;
        enc.bytes = alice.encrypt(pad(ProtoWriter().str(1, text).buf)).idup;
        auto got = decryptGroupEncFromStore(bStore, "g1@g.us", "alice:0", enc);
        assert(got == ProtoWriter().str(1, text).buf);
    }
}

unittest {
    // Two stores, two devices: Alice starts a session from Bob's bundle, sends through her store;
    // Bob decrypts through his store (consuming his one-time pre-key), replies, Alice decrypts.
    // Everything is reloaded from the store between steps, proving persistence end to end.
    const ap = tempDir ~ "/wa-msg-a-" ~ thisProcessID.to!string ~ ".db";
    const bp = tempDir ~ "/wa-msg-b-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (p; [ap, bp]) foreach (s; ["", "-wal", "-shm"]) if (exists(p ~ s)) remove(p ~ s);

    auto alice = Device.create();
    auto bob = Device.create();
    auto aStore = new Store(ap);
    auto bStore = new Store(bp);

    // Bob publishes a one-time pre-key into his store; Alice gets his bundle out of band
    auto bobOneTime = KeyPair.generate();
    bStore.putPreKey(55, bobOneTime);
    assert(bStore.preKeyCount() == 1);

    PreKeyBundle bundle = {
        registrationId: bob.registrationId, identityKey: bob.identityKey.pub,
        signedPreKeyId: bob.signedPreKey.id, signedPreKey: bob.signedPreKey.key.pub,
        signedPreKeySignature: bob.signedPreKey.signature,
        hasOneTime: true, preKeyId: 55, preKey: bobOneTime.pub
    };
    const bobAddr = "bob:0";
    const aliceAddr = "alice:0";

    // Alice -> Bob
    ubyte[] m1 = ProtoWriter().str(1, "oi bob, pelo store").buf;
    auto enc1 = encryptEncToStore(aStore, alice, bobAddr, m1, &bundle);
    auto wire1 = encodeStanza(enc1);
    auto back1 = decodeStanza(wire1);
    auto got1 = decryptEncFromStore(bStore, bob, aliceAddr, back1);
    assert(got1 == m1);
    assert(bStore.preKeyCount() == 0);          // the one-time key was consumed
    assert(aStore.hasSession(bobAddr) && bStore.hasSession(aliceAddr));

    // Bob -> Alice (now a plain "msg"), reloaded from Bob's store
    ubyte[] m2 = ProtoWriter().str(1, "oi alice").buf;
    auto enc2 = encryptEncToStore(bStore, bob, aliceAddr, m2);
    assert(enc2.get("type") == "msg");
    auto back2 = decodeStanza(encodeStanza(enc2));
    auto got2 = decryptEncFromStore(aStore, alice, bobAddr, back2);
    assert(got2 == m2);

    // Alice -> Bob again, sessions purely from the stores
    ubyte[] m3 = ProtoWriter().str(1, "beleza entao").buf;
    auto enc3 = encryptEncToStore(aStore, alice, bobAddr, m3);
    auto back3 = decodeStanza(encodeStanza(enc3));
    auto got3 = decryptEncFromStore(bStore, bob, aliceAddr, back3);
    assert(got3 == m3);
}
