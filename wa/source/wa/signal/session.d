/// A live Signal session: the double-ratchet state between us and one peer device, plus the state
/// machine that drives it. This is the stateful layer over the pure maths in `wa.signal`:
///   - initiate(): we start a session from a peer's pre-key bundle (the sender X3DH).
///   - fromPreKeyMessage(): a session appears because a peer messaged us first (the receiver X3DH).
///   - encrypt()/decrypt(): ratchet forward, one message at a time, with a DH step whenever the
///     peer advertises a new ratchet key, and a small cache of skipped message keys for out-of-order
///     delivery. serialize()/deserialize() persist the whole thing into our own store.
///
/// The ratchet bookkeeping mirrors libsignal (SessionState / getOrCreate{ChainKey,MessageKeys}); the
/// maths it calls is pinned to libsignal's vectors in `wa.signal`.
module wa.signal.session;

import wa.crypto : KeyPair, aesCbcDecrypt, aesCbcEncrypt, hmacSha256;
import wa.device : Device, serializedKey;
import wa.proto : ProtoReader, ProtoWriter;
import wa.signal;

enum size_t maxReceiverChains = 5;      // libsignal keeps the five most recent
enum size_t maxSkippedKeys = 2000;      // bound the out-of-order cache
enum uint maxFutureMessages = 2000;     // refuse a counter this far ahead of the chain

/// A symmetric chain key and how many times it has been ratcheted.
struct Chain {
    ubyte[32] key;
    uint index;
}

/// A receiving chain, keyed by the peer ratchet key that seeded it.
struct ReceiverChain {
    ubyte[32] ratchetKey;
    Chain chain;
}

/// A message key derived ahead of its message (out-of-order delivery), kept until used.
struct SkippedKey {
    ubyte[32] ratchetKey;
    uint index;
    MessageKeys keys;
}

/// The peer's pre-key bundle, as fetched from the server, for starting a session.
struct PreKeyBundle {
    uint registrationId;
    ubyte[32] identityKey;
    uint signedPreKeyId;
    ubyte[32] signedPreKey;
    ubyte[64] signedPreKeySignature;
    bool hasOneTime;
    uint preKeyId;
    ubyte[32] preKey;
}

/// A ciphertext ready for the wire: its Signal type (2 = whisper, 3 = pre-key) and the bytes.
struct CipherText {
    uint type;
    ubyte[] wire;
}

/// The full double-ratchet state for one peer device.
struct SessionState {
    ubyte[32] rootKey;
    KeyPair sendingRatchet;
    Chain sendingChain;
    bool hasSendingChain;
    uint previousCounter;
    ReceiverChain[] receiverChains;     // newest first
    SkippedKey[] skipped;
    ubyte[32] localIdentity;            // our identity public key
    ubyte[32] remoteIdentity;           // the peer's identity public key
    uint localRegistrationId;
    uint remoteRegistrationId;
    bool established;
    ubyte[32] baseKey;                  // the X3DH base key this session was built from (its identity)

    // the unacknowledged pre-key state: while set, our outgoing messages are PreKeySignalMessages so
    // the peer can build the session. Cleared once we receive from them (which proves they built it).
    bool pending;
    bool pendingHasOneTime;
    uint pendingPreKeyId;
    uint pendingSignedPreKeyId;
    ubyte[32] pendingBaseKey;

    // ---- establishment ------------------------------------------------------------------------

    /// Start a session to a peer from their bundle (we are the initiator). Verifies the signed
    /// pre-key signature, runs the sender X3DH, and ratchets once so our first message carries a
    /// fresh ratchet key. Throws on a bad signature.
    static SessionState initiate(ref const Device dev, const PreKeyBundle b) {
        import wa.crypto : xeddsaVerify;
        if (!xeddsaVerify(b.identityKey, serializedKey(b.signedPreKey), b.signedPreKeySignature))
            throw new SignalException("pre-key bundle signature does not verify");

        auto ourBase = KeyPair.generate();
        const rc = x3dhSender(dev.identityKey.priv, ourBase.priv, b.identityKey, b.signedPreKey,
            b.hasOneTime ? b.preKey[] : null);
        ubyte[32] root = rc[0 .. 32];
        ubyte[32] x3dhChain = rc[32 .. 64];

        SessionState s;
        s.localIdentity = dev.identityKey.pub;
        s.remoteIdentity = b.identityKey;
        s.localRegistrationId = dev.registrationId;
        s.remoteRegistrationId = b.registrationId;

        s.sendingRatchet = KeyPair.generate();
        const rr = rootRatchet(root, b.signedPreKey, s.sendingRatchet.priv);
        s.rootKey = rr[0 .. 32];
        s.sendingChain = Chain(rr[32 .. 64], 0);
        s.hasSendingChain = true;
        // the X3DH chain is the peer's first sending chain — remember it as a receiver chain
        s.receiverChains = [ReceiverChain(b.signedPreKey, Chain(x3dhChain, 0))];

        s.pending = true;
        s.baseKey = ourBase.pub;
        s.pendingBaseKey = ourBase.pub;
        s.pendingSignedPreKeyId = b.signedPreKeyId;
        s.pendingHasOneTime = b.hasOneTime;
        s.pendingPreKeyId = b.preKeyId;
        s.established = true;
        return s;
    }

    /// A session built because a peer sent us a PreKeySignalMessage (we are the responder). This is
    /// the receiver X3DH (libsignal's processV3): it sets up the root key and our signed pre-key as
    /// the initial sending ratchet. The message itself is then decrypted with decrypt().
    static SessionState fromPreKeyMessage(ref const Device dev, const PreKeySignalMessage pk,
        const(ubyte)[] oneTimePriv) {
        const rc = x3dhReceiver(dev.identityKey.priv, dev.signedPreKey.key.priv, oneTimePriv,
            pk.identityKey, pk.baseKey);
        SessionState s;
        s.rootKey = rc[0 .. 32];
        s.sendingRatchet = dev.signedPreKey.key;
        s.sendingChain = Chain(rc[32 .. 64], 0);
        s.hasSendingChain = true;
        s.localIdentity = dev.identityKey.pub;
        s.remoteIdentity = pk.identityKey;
        s.localRegistrationId = dev.registrationId;
        s.remoteRegistrationId = pk.registrationId;
        s.established = true;
        s.baseKey = pk.baseKey;
        return s;
    }

    // ---- receive ------------------------------------------------------------------------------

    private ReceiverChain* findReceiverChain(const ubyte[32] ratchetKey) return {
        foreach (ref rc; receiverChains)
            if (rc.ratchetKey == ratchetKey) return &rc;
        return null;
    }

    private void trimSkipped() {
        while (skipped.length > maxSkippedKeys) skipped = skipped[1 .. $];
    }

    /// The DH ratchet step on receiving a never-seen ratchet key: derive the new receiving chain,
    /// advance the root key, and open a fresh sending chain. Returns a pointer to the new chain.
    private ReceiverChain* ratchetOnReceive(const ubyte[32] theirRatchet) return {
        const recv = rootRatchet(rootKey, theirRatchet, sendingRatchet.priv);
        auto newEph = KeyPair.generate();
        const send = rootRatchet(recv[0 .. 32], theirRatchet, newEph.priv);
        rootKey = send[0 .. 32];
        previousCounter = hasSendingChain && sendingChain.index > 0 ? sendingChain.index - 1 : 0;
        sendingRatchet = newEph;
        sendingChain = Chain(send[32 .. 64], 0);
        hasSendingChain = true;
        receiverChains = ReceiverChain(theirRatchet, Chain(recv[32 .. 64], 0)) ~ receiverChains;
        if (receiverChains.length > maxReceiverChains)
            receiverChains = receiverChains[0 .. maxReceiverChains];
        return &receiverChains[0];
    }

    private MessageKeys deriveForCounter(ReceiverChain* rc, uint counter) {
        if (rc.chain.index > counter) {
            // a message we skipped past earlier (out of order) — it must be in the cache
            foreach (i, ref sk; skipped)
                if (sk.ratchetKey == rc.ratchetKey && sk.index == counter) {
                    auto keys = sk.keys;
                    skipped = skipped[0 .. i] ~ skipped[i + 1 .. $];
                    return keys;
                }
            throw new OldCounterException("duplicate or too-old message counter");
        }
        if (counter - rc.chain.index > maxFutureMessages)
            throw new SignalException("message counter too far into the future");
        while (rc.chain.index < counter) {
            skipped ~= SkippedKey(rc.ratchetKey, rc.chain.index, messageKeys(rc.chain.key));
            trimSkipped();
            rc.chain.key = nextChainKey(rc.chain.key);
            rc.chain.index++;
        }
        auto keys = messageKeys(rc.chain.key);
        rc.chain.key = nextChainKey(rc.chain.key);
        rc.chain.index++;
        return keys;
    }

    /// Decrypt a type-2 SignalMessage against this session, advancing the ratchet. Throws on a MAC
    /// mismatch, a replayed/old counter, or malformed input. The bytes are the Signal plaintext.
    ubyte[] decrypt(const(ubyte)[] wire) {
        if (!established) throw new SignalException("session not established");
        auto m = parseSignalMessage(wire);
        auto rc = findReceiverChain(m.ratchetKey);
        if (rc is null) rc = ratchetOnReceive(m.ratchetKey);
        const keys = deriveForCounter(rc, m.counter);

        ubyte[] macInput = serializedKey(remoteIdentity) ~ serializedKey(localIdentity) ~ m.macBase;
        const full = hmacSha256(keys.macKey[], macInput);
        if (full[0 .. 8] != m.mac[]) throw new SignalException("signal message MAC mismatch");

        auto plain = aesCbcDecrypt(keys.cipherKey[], keys.iv[], m.ciphertext);
        pending = false;    // the peer has clearly built the session; stop sending pre-key messages
        return plain;
    }

    /// Decrypt a PreKeySignalMessage: build the session if it is new, then decrypt the wrapped
    /// SignalMessage. `oneTimePriv` is the private half of the one-time pre-key the message named
    /// (null if it named none).
    static ubyte[] decryptPreKey(ref SessionState s, ref const Device dev,
        const PreKeySignalMessage pk, const(ubyte)[] oneTimePriv) {
        if (!s.established) s = SessionState.fromPreKeyMessage(dev, pk, oneTimePriv);
        return s.decrypt(pk.message);
    }

    // ---- send ---------------------------------------------------------------------------------

    /// Encrypt a Signal plaintext (already WhatsApp-padded by the caller) to the peer, advancing our
    /// sending chain. While the session is pending, the result is a PreKeySignalMessage (type 3);
    /// afterwards a plain SignalMessage (type 2).
    CipherText encrypt(const(ubyte)[] plaintext) {
        if (!established || !hasSendingChain) throw new SignalException("session not ready to send");
        const keys = messageKeys(sendingChain.key);
        const counter = sendingChain.index;
        sendingChain.key = nextChainKey(sendingChain.key);
        sendingChain.index++;

        auto cipher = aesCbcEncrypt(keys.cipherKey[], keys.iv[], plaintext);
        auto body = ProtoWriter()
            .bytes(1, serializedKey(sendingRatchet.pub))
            .varint(2, counter)
            .varint(3, previousCounter)
            .bytes(4, cipher);
        ubyte[] macBase = cast(ubyte[])[currentVersion] ~ body.buf;
        ubyte[] macInput = serializedKey(localIdentity) ~ serializedKey(remoteIdentity) ~ macBase;
        const full = hmacSha256(keys.macKey[], macInput);
        ubyte[] signalWire = macBase ~ full[0 .. 8];

        if (pending) {
            auto pw = ProtoWriter();
            if (pendingHasOneTime) pw.varint(1, pendingPreKeyId);
            pw.bytes(2, serializedKey(pendingBaseKey));
            pw.bytes(3, serializedKey(localIdentity));
            pw.bytes(4, signalWire);
            pw.varint(5, localRegistrationId);
            pw.varint(6, pendingSignedPreKeyId);
            return CipherText(3, cast(ubyte[])[currentVersion] ~ pw.buf);
        }
        return CipherText(2, signalWire);
    }

    // ---- persistence --------------------------------------------------------------------------

    /// Serialize the whole state to bytes for our store (our own layout; not libsignal's).
    ubyte[] serialize() const {
        auto w = ProtoWriter();
        w.bytes(1, rootKey[]);
        w.bytes(2, sendingRatchet.priv[]);
        w.bytes(3, sendingRatchet.pub[]);
        w.bytes(4, sendingChain.key[]);
        w.varint(5, sendingChain.index);
        w.boolean(6, hasSendingChain);
        w.varint(7, previousCounter);
        w.bytes(8, localIdentity[]);
        w.bytes(9, remoteIdentity[]);
        w.varint(10, localRegistrationId);
        w.varint(11, remoteRegistrationId);
        w.boolean(12, established);
        w.boolean(13, pending);
        w.boolean(14, pendingHasOneTime);
        w.varint(15, pendingPreKeyId);
        w.varint(16, pendingSignedPreKeyId);
        w.bytes(17, pendingBaseKey[]);
        w.bytes(20, baseKey[]);
        foreach (ref rc; receiverChains) {
            auto c = ProtoWriter().bytes(1, rc.ratchetKey[]).bytes(2, rc.chain.key[]).varint(3, rc.chain.index);
            w.bytes(18, c.buf);
        }
        foreach (ref sk; skipped) {
            auto c = ProtoWriter().bytes(1, sk.ratchetKey[]).varint(2, sk.index)
                .bytes(3, sk.keys.cipherKey[]).bytes(4, sk.keys.macKey[]).bytes(5, sk.keys.iv[]);
            w.bytes(19, c.buf);
        }
        return w.buf;
    }

    /// Rebuild a state from serialize()'s bytes.
    static SessionState deserialize(const(ubyte)[] data) {
        SessionState s;
        auto r = ProtoReader(data);
        foreach (f; r) {
            switch (f.number) {
                case 1: s.rootKey = f.bytes[0 .. 32]; break;
                case 2: s.sendingRatchet.priv = f.bytes[0 .. 32]; break;
                case 3: s.sendingRatchet.pub = f.bytes[0 .. 32]; break;
                case 4: s.sendingChain.key = f.bytes[0 .. 32]; break;
                case 5: s.sendingChain.index = cast(uint) f.value; break;
                case 6: s.hasSendingChain = f.value != 0; break;
                case 7: s.previousCounter = cast(uint) f.value; break;
                case 8: s.localIdentity = f.bytes[0 .. 32]; break;
                case 9: s.remoteIdentity = f.bytes[0 .. 32]; break;
                case 10: s.localRegistrationId = cast(uint) f.value; break;
                case 11: s.remoteRegistrationId = cast(uint) f.value; break;
                case 12: s.established = f.value != 0; break;
                case 13: s.pending = f.value != 0; break;
                case 14: s.pendingHasOneTime = f.value != 0; break;
                case 15: s.pendingPreKeyId = cast(uint) f.value; break;
                case 16: s.pendingSignedPreKeyId = cast(uint) f.value; break;
                case 17: s.pendingBaseKey = f.bytes[0 .. 32]; break;
                case 20: s.baseKey = f.bytes[0 .. 32]; break;
                case 18:
                    auto c = ProtoReader(f.bytes);
                    ReceiverChain rc;
                    rc.ratchetKey = c.get(1).bytes[0 .. 32];
                    rc.chain.key = c.get(2).bytes[0 .. 32];
                    rc.chain.index = cast(uint) c.get(3).value;
                    s.receiverChains ~= rc;
                    break;
                case 19:
                    auto c = ProtoReader(f.bytes);
                    SkippedKey sk;
                    sk.ratchetKey = c.get(1).bytes[0 .. 32];
                    sk.index = cast(uint) c.get(2).value;
                    sk.keys.cipherKey = c.get(3).bytes[0 .. 32];
                    sk.keys.macKey = c.get(4).bytes[0 .. 32];
                    sk.keys.iv = c.get(5).bytes[0 .. 16];
                    s.skipped ~= sk;
                    break;
                default: break;
            }
        }
        return s;
    }
}

/// All the session states with one peer device, as libsignal's SessionRecord: the current one and
/// up to 40 archived ones (a peer that reinstalled, or re-keyed after a retry, starts a new state
/// while messages for the old one may still arrive).
struct SessionRecord {
    enum size_t maxArchived = 40;
    SessionState current;
    SessionState[] previous;     // newest first

    private static SessionState clone(const ref SessionState s) { return SessionState.deserialize(s.serialize()); }

    /// processV3's "already have a session for this base key?" (current or archived).
    bool hasState(const ubyte[32] baseKey) const {
        if (current.established && current.baseKey == baseKey) return true;
        foreach (ref p; previous) if (p.baseKey == baseKey) return true;
        return false;
    }

    /// PromoteState: make `s` current, archiving the current one (when it is a real session).
    void promote(SessionState s) {
        if (current.established) previous = current ~ previous;
        if (previous.length > maxArchived) previous = previous[0 .. maxArchived];
        current = s;
    }

    /// DecryptWithRecord: the current state first, then the archived ones (promoting the one that
    /// works). An old counter ends the attempt at once (OldCounterException), as libsignal does.
    ubyte[] decrypt(const(ubyte)[] wire) {
        try {
            auto c = clone(current);
            auto plain = c.decrypt(wire);
            current = c;
            return plain;
        } catch (OldCounterException e) {
            throw e;
        } catch (Exception) {}
        foreach (i, ref p; previous) {
            try {
                auto c = clone(p);
                auto plain = c.decrypt(wire);
                previous = previous[0 .. i] ~ previous[i + 1 .. $];
                promote(c);
                return plain;
            } catch (OldCounterException e) {
                throw e;
            } catch (Exception) {}
        }
        throw new SignalException("no valid session state for this message");
    }

    /// DecryptMessage(PreKeySignalMessage): build a new state unless one exists for its base key
    /// (`newSession` reports it — only then is the one-time pre-key consumed), then decrypt.
    ubyte[] decryptPreKey(ref const Device dev, const PreKeySignalMessage pk, const(ubyte)[] oneTimePriv,
        out bool newSession) {
        // a state stored by an earlier build has no base key: adopt it if it decrypts this message
        if (current.established && current.baseKey == (ubyte[32]).init) {
            try {
                auto c = clone(current);
                auto plain = c.decrypt(pk.message);
                c.baseKey = pk.baseKey;
                current = c;
                return plain;
            } catch (OldCounterException e) {
                throw e;
            } catch (Exception) {}
        }
        if (!hasState(pk.baseKey)) {
            promote(SessionState.fromPreKeyMessage(dev, pk, oneTimePriv));
            newSession = true;
        }
        return decrypt(pk.message);
    }

    ubyte[] serialize() const {
        auto w = ProtoWriter();
        w.bytes(100, current.serialize());
        foreach (ref p; previous) w.bytes(101, p.serialize());
        return w.buf;
    }

    /// Reads both the record layout and a bare SessionState stored by earlier builds.
    static SessionRecord deserialize(const(ubyte)[] data) {
        SessionRecord r;
        auto rd = ProtoReader(data);
        if (!rd.has(100)) { r.current = SessionState.deserialize(data); return r; }
        foreach (f; rd) {
            if (f.number == 100) r.current = SessionState.deserialize(f.bytes);
            else if (f.number == 101) r.previous ~= SessionState.deserialize(f.bytes);
        }
        return r;
    }
}

version (unittest) {
    import wa.message : pad, unpad;

    // a throwaway device with a usable identity + signed pre-key, for the self-consistency tests
    private Device testDevice() {
        return Device.create();
    }

    private PreKeyBundle bundleFor(ref const Device dev, bool withOneTime, KeyPair oneTime, uint oneTimeId) {
        PreKeyBundle b;
        b.registrationId = dev.registrationId;
        b.identityKey = dev.identityKey.pub;
        b.signedPreKeyId = dev.signedPreKey.id;
        b.signedPreKey = dev.signedPreKey.key.pub;
        b.signedPreKeySignature = dev.signedPreKey.signature;
        b.hasOneTime = withOneTime;
        if (withOneTime) { b.preKeyId = oneTimeId; b.preKey = oneTime.pub; }
        return b;
    }
}

unittest {
    // Full D-to-D conversation: Alice initiates to Bob, they talk back and forth across several DH
    // ratchets, and every message decrypts to exactly what was sent. This proves the ratchet
    // bookkeeping (new chains, previousCounter, chain advance) is internally consistent.
    auto alice = testDevice();
    auto bob = testDevice();
    auto bobOneTime = KeyPair.generate();

    auto aliceS = SessionState.initiate(alice, bundleFor(bob, true, bobOneTime, 77));

    // Alice -> Bob: the first (pre-key) message
    auto c0 = aliceS.encrypt(pad(cast(ubyte[]) "oi bob"));
    assert(c0.type == 3);
    auto pk0 = parsePreKeyMessage(c0.wire);
    SessionState bobS;
    auto p0 = SessionState.decryptPreKey(bobS, bob, pk0, bobOneTime.priv[]);
    assert(cast(string) unpad(p0) == "oi bob");

    // another from Alice before Bob replies (still pre-key, same chain, counter 1)
    auto c1 = aliceS.encrypt(pad(cast(ubyte[]) "ainda eu"));
    assert(c1.type == 3);
    assert(cast(string) unpad(bobS.decrypt(parsePreKeyMessage(c1.wire).message)) == "ainda eu");

    // Bob -> Alice: a reply (type 2, Bob's new ratchet key → Alice does a DH ratchet on receive)
    auto r0 = bobS.encrypt(pad(cast(ubyte[]) "oi alice"));
    assert(r0.type == 2);
    assert(cast(string) unpad(aliceS.decrypt(r0.wire)) == "oi alice");

    // Alice -> Bob again: now a plain whisper message on a fresh chain (Alice ratcheted on r0)
    auto c2 = aliceS.encrypt(pad(cast(ubyte[]) "beleza"));
    assert(c2.type == 2);
    assert(cast(string) unpad(bobS.decrypt(c2.wire)) == "beleza");

    // Bob -> Alice, two in a row
    auto r1 = bobS.encrypt(pad(cast(ubyte[]) "um"));
    auto r2 = bobS.encrypt(pad(cast(ubyte[]) "dois"));
    assert(cast(string) unpad(aliceS.decrypt(r1.wire)) == "um");
    assert(cast(string) unpad(aliceS.decrypt(r2.wire)) == "dois");
}

unittest {
    // Out-of-order delivery: a later message arrives first; the skipped key is cached and the
    // earlier message still decrypts when it shows up.
    auto alice = testDevice();
    auto bob = testDevice();
    auto aliceS = SessionState.initiate(alice, bundleFor(bob, false, KeyPair.init, 0));

    auto a = aliceS.encrypt(pad(cast(ubyte[]) "um"));
    auto b = aliceS.encrypt(pad(cast(ubyte[]) "dois"));
    auto c = aliceS.encrypt(pad(cast(ubyte[]) "tres"));

    SessionState bobS;
    auto pkA = parsePreKeyMessage(a.wire);
    SessionState.decryptPreKey(bobS, bob, pkA, null);   // establish + msg 0

    // deliver 2 before 1
    assert(cast(string) unpad(bobS.decrypt(parsePreKeyMessage(c.wire).message)) == "tres");
    assert(cast(string) unpad(bobS.decrypt(parsePreKeyMessage(b.wire).message)) == "dois");
}

unittest {
    // Persistence: a session survives a serialize/deserialize round-trip and keeps decrypting.
    auto alice = testDevice();
    auto bob = testDevice();
    auto aliceS = SessionState.initiate(alice, bundleFor(bob, false, KeyPair.init, 0));

    auto a = aliceS.encrypt(pad(cast(ubyte[]) "antes"));
    SessionState bobS;
    SessionState.decryptPreKey(bobS, bob, parsePreKeyMessage(a.wire), null);

    auto blob = bobS.serialize();
    auto restored = SessionState.deserialize(blob);

    auto b = aliceS.encrypt(pad(cast(ubyte[]) "depois"));
    assert(cast(string) unpad(restored.decrypt(parsePreKeyMessage(b.wire).message)) == "depois");
}

unittest {
    // A peer "reinstalls": a pkmsg with a new base key arrives while we hold a session for the old
    // one. The record builds a new state, archives the old, and a late message from the old
    // session still decrypts (DecryptWithRecord over the archived states).
    auto alice = testDevice();
    auto bob = testDevice();
    auto oldAlice = SessionState.initiate(alice, bundleFor(bob, false, KeyPair.init, 0));
    auto m1 = oldAlice.encrypt(pad(cast(ubyte[]) "sessao velha 1"));
    auto m2 = oldAlice.encrypt(pad(cast(ubyte[]) "sessao velha 2"));   // delivered late

    SessionRecord bobRec;
    bool fresh;
    assert(cast(string) unpad(bobRec.decryptPreKey(bob, parsePreKeyMessage(m1.wire), null, fresh)) == "sessao velha 1");
    assert(fresh);
    // the same base key again → no new state, the pre-key would not be consumed twice
    auto m1b = oldAlice.encrypt(pad(cast(ubyte[]) "de novo"));
    assert(cast(string) unpad(bobRec.decryptPreKey(bob, parsePreKeyMessage(m1b.wire), null, fresh)) == "de novo");
    assert(!fresh);

    auto newAlice = SessionState.initiate(alice, bundleFor(bob, false, KeyPair.init, 0));  // reinstall
    auto n1 = newAlice.encrypt(pad(cast(ubyte[]) "sessao nova"));
    assert(cast(string) unpad(bobRec.decryptPreKey(bob, parsePreKeyMessage(n1.wire), null, fresh)) == "sessao nova");
    assert(fresh && bobRec.previous.length == 1);

    bobRec = SessionRecord.deserialize(bobRec.serialize());      // survives persistence
    assert(cast(string) unpad(bobRec.decrypt(parsePreKeyMessage(m2.wire).message)) == "sessao velha 2");

    // a bare SessionState stored by an earlier build loads as the record's current state
    auto legacy = SessionRecord.deserialize(bobRec.current.serialize());
    assert(legacy.current.established && legacy.previous.length == 0);
}
