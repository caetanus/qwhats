/// WhatsApp's Noise: Noise_XX_25519_AESGCM_SHA256 with WhatsApp's prologue ("WA", 6, the
/// dictionary version), as WhatsApp Web's WANoiseHandshake / WANoiseSocket. The handshake hash is
/// the AES-GCM associated data; keys come from HKDF-SHA256 over the chaining key; the IV is a
/// 32-bit big-endian counter in the last 4 of 12 bytes, restarted at every new key.
module wa.socket.noise;

import wa.crypto;

enum string noisePattern = "Noise_XX_25519_AESGCM_SHA256\0\0\0\0";

ubyte[12] counterIV(uint count) {
    ubyte[12] iv;
    iv[8] = cast(ubyte)(count >> 24);
    iv[9] = cast(ubyte)(count >> 16);
    iv[10] = cast(ubyte)(count >> 8);
    iv[11] = cast(ubyte) count;
    return iv;
}

struct NoiseHandshake {
    ubyte[] hash;
    ubyte[] salt;
    ubyte[] key;
    uint counter;

    void start(string pattern, const(ubyte)[] prologue) {
        auto p = cast(const(ubyte)[]) pattern;
        hash = p.length == 32 ? p.dup : sha256(p).dup;
        salt = hash.dup;
        key = hash.dup;
        counter = 0;
        authenticate(prologue);
    }

    void authenticate(const(ubyte)[] data) { hash = sha256(hash ~ data).dup; }

    ubyte[] encrypt(const(ubyte)[] plain) {
        auto c = aesGcmEncrypt(key, counterIV(counter++), plain, hash);
        authenticate(c);
        return c;
    }

    ubyte[] decrypt(const(ubyte)[] sealed) {
        auto p = aesGcmDecrypt(key, counterIV(counter++), sealed, hash);
        authenticate(sealed);
        return p;
    }

    void mixIntoKey(const(ubyte)[] data) {
        counter = 0;
        auto k = hkdf(data, salt, null, 64);
        salt = k[0 .. 32];
        key = k[32 .. 64];
    }

    void mixSharedSecret(const ubyte[32] priv, const ubyte[32] pub) { mixIntoKey(sharedSecret(priv, pub)[]); }

    /// The transport keys: (write, read).
    NoiseTransport finish() {
        auto k = hkdf(null, salt, null, 64);
        return NoiseTransport(k[0 .. 32], k[32 .. 64]);
    }
}

/// The established channel's two directions, each with its own counter.
struct NoiseTransport {
    ubyte[] writeKey, readKey;
    uint writeCounter, readCounter;

    ubyte[] seal(const(ubyte)[] plain) { return aesGcmEncrypt(writeKey, counterIV(writeCounter++), plain); }
    ubyte[] open(const(ubyte)[] sealed) { return aesGcmDecrypt(readKey, counterIV(readCounter++), sealed); }
}

unittest {
    // both ends of XX agree on the transport keys (a responder written from the same steps)
    import wa.binary.dict : dictVersion;
    const ubyte[] prologue = ['W', 'A', 6, dictVersion];
    auto ce = KeyPair.generate(), cs = KeyPair.generate(), se = KeyPair.generate(), ss = KeyPair.generate();
    NoiseHandshake c, s;
    c.start(noisePattern, prologue);
    s.start(noisePattern, prologue);
    c.authenticate(ce.pub); s.authenticate(ce.pub);
    // server hello: e, ee, s, es, payload
    s.authenticate(se.pub);
    s.mixSharedSecret(se.priv, ce.pub);
    auto encStatic = s.encrypt(ss.pub);
    s.mixSharedSecret(ss.priv, ce.pub);
    auto encCert = s.encrypt(cast(ubyte[]) "cert");
    c.authenticate(se.pub);
    c.mixSharedSecret(ce.priv, se.pub);
    ubyte[32] gotStatic = c.decrypt(encStatic);
    assert(gotStatic == ss.pub);
    c.mixSharedSecret(ce.priv, gotStatic);
    assert(c.decrypt(encCert) == cast(ubyte[]) "cert");
    // client finish: s, se, payload
    auto encMine = c.encrypt(cs.pub);
    c.mixSharedSecret(cs.priv, se.pub);
    auto encPayload = c.encrypt(cast(ubyte[]) "payload");
    ubyte[32] theirs = s.decrypt(encMine);
    s.mixSharedSecret(se.priv, theirs);
    assert(s.decrypt(encPayload) == cast(ubyte[]) "payload");
    auto ct = c.finish(), st = s.finish();
    assert(ct.writeKey == st.writeKey && ct.readKey == st.readKey);
    // the server reads with the client's write key
    auto server = NoiseTransport(st.readKey, st.writeKey);
    assert(server.open(ct.seal(cast(ubyte[]) "ping")) == cast(ubyte[]) "ping");
    assert(ct.open(server.seal(cast(ubyte[]) "pong")) == cast(ubyte[]) "pong");
}
