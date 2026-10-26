/// Signal sender keys — group messaging, as libsignal's groups package (and WhatsApp) do it. Each
/// group member has its own sender key per group: a chain key that ratchets once per message and a
/// signing key pair. The member hands it to the others once, in a SenderKeyDistributionMessage
/// (sent inside an ordinary 1:1 Signal message); afterwards its group messages travel as
/// SenderKeyMessages (`<enc type="skmsg">`), encrypted with the chain and signed with XEdDSA.
///
///   chain:   messageSeed = HMAC(chainKey, 0x01); next chainKey = HMAC(chainKey, 0x02)
///   key:     HKDF(messageSeed, salt = ∅, "WhisperGroup", 48) = iv(16) ‖ cipherKey(32)
///   SKDM:    0x33 ‖ proto { id = 1; iteration = 2; chainKey = 3; signingKey = 4 (0x05 ‖ 32) }
///   message: 0x33 ‖ proto { id = 1; iteration = 2; ciphertext = 3 } ‖ XEdDSA(0x33 ‖ proto)
module wa.signal.group;

import wa.crypto : KeyPair, aesCbcDecrypt, aesCbcEncrypt, hkdf, hmacSha256, randomBytes, xeddsaSign, xeddsaVerify;
import wa.device : serializedKey;
import wa.proto : ProtoReader, ProtoWriter;
import wa.signal : OldCounterException, SignalException, currentVersion, stripType;

enum size_t maxSenderKeyStates = 5;
enum uint maxGroupFutureMessages = 2000;
enum size_t maxSkippedGroupKeys = 2000;

struct SenderMessageKey {
    uint iteration;
    ubyte[16] iv;
    ubyte[32] cipherKey;
}

SenderMessageKey senderMessageKey(uint iteration, const ubyte[32] chainKey) {
    const ubyte[1] seed = [0x01];
    const base = hmacSha256(chainKey[], seed[]);
    auto x = hkdf(base[], null, cast(const(ubyte)[]) "WhisperGroup", 48);
    SenderMessageKey k;
    k.iteration = iteration;
    k.iv = x[0 .. 16];
    k.cipherKey = x[16 .. 48];
    return k;
}

ubyte[32] nextSenderChainKey(const ubyte[32] chainKey) {
    const ubyte[1] seed = [0x02];
    return hmacSha256(chainKey[], seed[]);
}

/// One sender-key generation (a member can rotate; we keep the five newest, as libsignal).
struct SenderKeyState {
    uint keyId;
    uint iteration;
    ubyte[32] chainKey;
    ubyte[32] signingPub;
    bool hasPriv;              // our own key: we can sign
    ubyte[32] signingPriv;
    SenderMessageKey[] skipped;
}

/// The SenderKeyDistributionMessage fields.
struct SenderKeyDistribution {
    uint keyId;
    uint iteration;
    ubyte[32] chainKey;
    ubyte[32] signingKey;
}

SenderKeyDistribution parseSenderKeyDistribution(const(ubyte)[] wire) {
    if (wire.length < 2 || wire[0] != currentVersion) throw new SignalException("bad sender key distribution version");
    auto r = ProtoReader(wire[1 .. $]);
    SenderKeyDistribution d;
    d.keyId = cast(uint) r.get(1).value;
    d.iteration = cast(uint) r.get(2).value;
    auto ck = r.get(3).bytes;
    if (ck.length != 32) throw new SignalException("bad sender chain key");
    d.chainKey = ck[0 .. 32];
    d.signingKey = stripType(r.get(4).bytes);
    return d;
}

ubyte[] serializeSenderKeyDistribution(const SenderKeyDistribution d) {
    auto w = ProtoWriter().varint(1, d.keyId).varint(2, d.iteration).bytes(3, d.chainKey[])
        .bytes(4, serializedKey(d.signingKey));
    return cast(ubyte[])[currentVersion] ~ w.buf;
}

/// All of one member's sender keys in one group.
struct SenderKeyRecord {
    SenderKeyState[] states;     // newest first

    bool empty() const { return states.length == 0; }

    /// A distribution message from a peer: add (or refresh) that key generation.
    void process(const SenderKeyDistribution d) {
        foreach (i, ref st; states)
            if (st.keyId == d.keyId) { states = states[0 .. i] ~ states[i + 1 .. $]; break; }
        SenderKeyState st;
        st.keyId = d.keyId;
        st.iteration = d.iteration;
        st.chainKey = d.chainKey;
        st.signingPub = d.signingKey;
        states = st ~ states;
        if (states.length > maxSenderKeyStates) states = states[0 .. maxSenderKeyStates];
    }

    /// Our own sender key for a group, created fresh (libsignal GroupSessionBuilder.Create).
    static SenderKeyRecord createOwn() {
        auto signing = KeyPair.generate();
        auto r = randomBytes(4);
        SenderKeyState st;
        st.keyId = (cast(uint) r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3];   // KeyHelper.GenerateSenderKeyID: any uint32
        st.chainKey = randomBytes(32)[0 .. 32];
        st.signingPub = signing.pub;
        st.signingPriv = signing.priv;
        st.hasPriv = true;
        SenderKeyRecord rec;
        rec.states = [st];
        return rec;
    }

    /// The distribution message for our current key (to send to every member once).
    SenderKeyDistribution distribution() const {
        if (empty) throw new SignalException("no sender key");
        const st = states[0];
        return SenderKeyDistribution(st.keyId, st.iteration, st.chainKey, st.signingPub);
    }

    /// Encrypt with our own current key; returns the signed SenderKeyMessage wire bytes.
    ubyte[] encrypt(const(ubyte)[] plaintext) {
        if (empty || !states[0].hasPriv) throw new SignalException("no own sender key to encrypt with");
        auto st = &states[0];
        const k = senderMessageKey(st.iteration, st.chainKey);
        auto ct = aesCbcEncrypt(k.cipherKey[], k.iv[], plaintext);
        auto body = ProtoWriter().varint(1, st.keyId).varint(2, st.iteration).bytes(3, ct);
        ubyte[] signed = cast(ubyte[])[currentVersion] ~ body.buf;
        const sig = xeddsaSign(st.signingPriv, signed);
        st.chainKey = nextSenderChainKey(st.chainKey);
        st.iteration++;
        return signed ~ sig[];
    }

    /// Decrypt a peer's SenderKeyMessage, advancing (and caching skipped keys of) its chain.
    ubyte[] decrypt(const(ubyte)[] wire) {
        if (empty) throw new SignalException("no sender key for this sender");
        if (wire.length < 1 + 64 || wire[0] != currentVersion) throw new SignalException("bad sender key message");
        const signed = wire[0 .. $ - 64];
        ubyte[64] sig = wire[$ - 64 .. $][0 .. 64];
        auto r = ProtoReader(signed[1 .. $]);
        const keyId = cast(uint) r.get(1).value;
        const iteration = cast(uint) r.get(2).value;
        const ct = r.get(3).bytes;

        SenderKeyState* st;
        foreach (ref s; states) if (s.keyId == keyId) { st = &s; break; }
        if (st is null) throw new SignalException("no sender key state for this key id");
        if (!xeddsaVerify(st.signingPub, signed, sig)) throw new SignalException("sender key message signature invalid");

        SenderMessageKey key;
        if (st.iteration > iteration) {
            bool found;
            foreach (i, ref k; st.skipped)
                if (k.iteration == iteration) {
                    key = k;
                    st.skipped = st.skipped[0 .. i] ~ st.skipped[i + 1 .. $];
                    found = true;
                    break;
                }
            if (!found) throw new OldCounterException("duplicate or too-old group message");
        } else {
            if (iteration - st.iteration > maxGroupFutureMessages)
                throw new SignalException("group message too far into the future");
            while (st.iteration < iteration) {
                st.skipped ~= senderMessageKey(st.iteration, st.chainKey);
                if (st.skipped.length > maxSkippedGroupKeys) st.skipped = st.skipped[1 .. $];
                st.chainKey = nextSenderChainKey(st.chainKey);
                st.iteration++;
            }
            key = senderMessageKey(st.iteration, st.chainKey);
            st.chainKey = nextSenderChainKey(st.chainKey);
            st.iteration++;
        }
        return aesCbcDecrypt(key.cipherKey[], key.iv[], ct);
    }

    // ---- persistence (our own layout) ----

    ubyte[] serialize() const {
        auto w = ProtoWriter();
        foreach (ref st; states) {
            auto s = ProtoWriter().varint(1, st.keyId).varint(2, st.iteration).bytes(3, st.chainKey[])
                .bytes(4, st.signingPub[]).boolean(5, st.hasPriv);
            if (st.hasPriv) s.bytes(6, st.signingPriv[]);
            foreach (ref k; st.skipped)
                s.bytes(7, ProtoWriter().varint(1, k.iteration).bytes(2, k.iv[]).bytes(3, k.cipherKey[]).buf);
            w.bytes(1, s.buf);
        }
        return w.buf;
    }

    static SenderKeyRecord deserialize(const(ubyte)[] data) {
        SenderKeyRecord rec;
        foreach (f; ProtoReader(data)) {
            if (f.number != 1) continue;
            SenderKeyState st;
            foreach (g; ProtoReader(f.bytes)) {
                switch (g.number) {
                    case 1: st.keyId = cast(uint) g.value; break;
                    case 2: st.iteration = cast(uint) g.value; break;
                    case 3: st.chainKey = g.bytes[0 .. 32]; break;
                    case 4: st.signingPub = g.bytes[0 .. 32]; break;
                    case 5: st.hasPriv = g.value != 0; break;
                    case 6: st.signingPriv = g.bytes[0 .. 32]; break;
                    case 7:
                        auto k = ProtoReader(g.bytes);
                        SenderMessageKey mk;
                        mk.iteration = cast(uint) k.get(1).value;
                        mk.iv = k.get(2).bytes[0 .. 16];
                        mk.cipherKey = k.get(3).bytes[0 .. 32];
                        st.skipped ~= mk;
                        break;
                    default: break;
                }
            }
            rec.states ~= st;
        }
        return rec;
    }
}

version (unittest) import std.json, std.file, std.path, std.conv;

unittest {
    // D ↔ D: Alice creates her key, Bob processes the distribution, messages decrypt — including
    // out of order — and the record survives persistence.
    auto alice = SenderKeyRecord.createOwn();
    auto skdm = serializeSenderKeyDistribution(alice.distribution());
    SenderKeyRecord bob;
    bob.process(parseSenderKeyDistribution(skdm));

    auto m0 = alice.encrypt(cast(ubyte[]) "zero");
    auto m1 = alice.encrypt(cast(ubyte[]) "um");
    auto m2 = alice.encrypt(cast(ubyte[]) "dois");
    assert(cast(string) bob.decrypt(m2) == "dois");
    bob = SenderKeyRecord.deserialize(bob.serialize());
    assert(cast(string) bob.decrypt(m0) == "zero");
    assert(cast(string) bob.decrypt(m1) == "um");

    // a tampered message fails the signature
    auto bad = alice.encrypt(cast(ubyte[]) "x");
    bad[5] ^= 1;
    bool threw;
    try bob.decrypt(bad); catch (SignalException) threw = true;
    assert(threw);
}

unittest {
    // libsignal → D: decrypt group messages a real libsignal GroupCipher produced
    // (tests/senderkey-vectors.json, generated by core/cmd/senderkeyvec).
    static ubyte[] unhex(string h) {
        auto o = new ubyte[h.length / 2];
        foreach (i; 0 .. o.length) o[i] = cast(ubyte) h[2 * i .. 2 * i + 2].to!ubyte(16);
        return o;
    }
    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "tests", "senderkey-vectors.json");
    if (!exists(path)) return;
    auto v = parseJSON(readText(path));
    SenderKeyRecord rec;
    rec.process(parseSenderKeyDistribution(unhex(v["skdm"].str)));
    // deliver in the order listed (the generator shuffles to exercise skipped keys)
    foreach (m; v["messages"].array)
        assert(cast(string) rec.decrypt(unhex(m["serialized"].str)) == m["plaintext"].str);
}
