/// The primitives WhatsApp's protocol is built from: SHA-256, HMAC-SHA256, HKDF (RFC 5869),
/// AES-256-GCM and AES-256-CBC (OpenSSL), X25519 and XEdDSA — Signal's signatures made with a
/// Curve25519 key (libsodium's Ed25519 arithmetic), as WhatsApp Web's WACryptoCurve / libsignal.
module wa.crypto;

import libsodium.crypto_hash_sha256;
import libsodium.crypto_hash_sha512;
import libsodium.crypto_auth_hmacsha256;
import libsodium.crypto_auth_hmacsha512;
import libsodium.crypto_scalarmult_curve25519;
import libsodium.crypto_scalarmult_ed25519;
import libsodium.crypto_core_ed25519;
import libsodium.crypto_sign_ed25519;
import libsodium.randombytes;
import libsodium.core : sodium_init;

class CryptoException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

shared static this() {
    if (sodium_init() < 0) throw new CryptoException("libsodium failed to start");
}

ubyte[] randomBytes(size_t n) {
    auto b = new ubyte[n];
    randombytes_buf(b.ptr, n);
    return b;
}

ubyte[32] sha256(scope const(ubyte)[] data) {
    ubyte[32] h;
    crypto_hash_sha256(h.ptr, data.ptr, data.length);
    return h;
}

/// HMAC-SHA256 with a key of any length.
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[][] parts...) {
    crypto_auth_hmacsha256_state st;
    crypto_auth_hmacsha256_init(&st, key.ptr, key.length);
    foreach (p; parts) crypto_auth_hmacsha256_update(&st, p.ptr, p.length);
    ubyte[32] mac;
    crypto_auth_hmacsha256_final(&st, mac.ptr);
    return mac;
}

/// HMAC-SHA512 with a key of any length (the app-state content MAC).
ubyte[64] hmacSha512(scope const(ubyte)[] key, scope const(ubyte)[][] parts...) {
    crypto_auth_hmacsha512_state st;
    crypto_auth_hmacsha512_init(&st, key.ptr, key.length);
    foreach (p; parts) crypto_auth_hmacsha512_update(&st, p.ptr, p.length);
    ubyte[64] mac;
    crypto_auth_hmacsha512_final(&st, mac.ptr);
    return mac;
}

unittest {
    // RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?"
    import std.format : format;
    auto mac = hmacSha512(cast(ubyte[]) "Jefe", cast(ubyte[]) "what do ya want for nothing?");
    string hexs;
    foreach (b; mac[0 .. 8]) hexs ~= format("%02x", b);
    assert(hexs == "164b7a7bfcf819e2");
}

/// RFC 5869: `length` bytes from `ikm`; an empty salt is 32 zero bytes.
ubyte[] hkdf(scope const(ubyte)[] ikm, scope const(ubyte)[] salt, scope const(ubyte)[] info, size_t length) {
    ubyte[32] zero;
    const prk = hmacSha256(salt.length ? salt : zero[], ikm);
    ubyte[] okm;
    ubyte[] t;
    for (ubyte i = 1; okm.length < length; i++) {
        const ubyte[1] c = [i];
        t = hmacSha256(prk[], t, info, c[]).dup;
        okm ~= t;
    }
    return okm[0 .. length];
}

// ---- AES (OpenSSL's EVP) ----------------------------------------------------------------------------

import deimos.openssl.evp;

private struct Evp {
    EVP_CIPHER_CTX* ctx;
    this(bool _) {
        ctx = EVP_CIPHER_CTX_new();
        if (!ctx) throw new CryptoException("EVP_CIPHER_CTX_new");
    }
    ~this() { if (ctx) EVP_CIPHER_CTX_free(ctx); }
    @disable this(this);
    void check(int r, string what) { if (r != 1) throw new CryptoException(what); }
}

/// AES-256-GCM: ciphertext with its 16-byte tag appended.
ubyte[] aesGcmEncrypt(scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] plain, scope const(ubyte)[] aad = null) {
    if (key.length != 32 || iv.length != 12) throw new CryptoException("AES-GCM wants a 32-byte key and a 12-byte IV");
    auto e = Evp(true);
    e.check(EVP_EncryptInit_ex(e.ctx, EVP_aes_256_gcm(), null, key.ptr, iv.ptr), "gcm init");
    int n;
    if (aad.length) e.check(EVP_EncryptUpdate(e.ctx, null, &n, aad.ptr, cast(int) aad.length), "gcm aad");
    auto out_ = new ubyte[plain.length + 16];
    int len;
    if (plain.length) e.check(EVP_EncryptUpdate(e.ctx, out_.ptr, &len, plain.ptr, cast(int) plain.length), "gcm encrypt");
    e.check(EVP_EncryptFinal_ex(e.ctx, out_.ptr + len, &n), "gcm final");
    e.check(EVP_CIPHER_CTX_ctrl(e.ctx, EVP_CTRL_GCM_GET_TAG, 16, out_.ptr + plain.length), "gcm tag");
    return out_;
}

/// AES-256-GCM: the plaintext, or a CryptoException when the tag does not verify.
ubyte[] aesGcmDecrypt(scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] sealed, scope const(ubyte)[] aad = null) {
    if (key.length != 32 || iv.length != 12) throw new CryptoException("AES-GCM wants a 32-byte key and a 12-byte IV");
    if (sealed.length < 16) throw new CryptoException("AES-GCM ciphertext too short");
    const body = sealed[0 .. $ - 16];
    ubyte[16] tag = sealed[$ - 16 .. $];
    auto e = Evp(true);
    e.check(EVP_DecryptInit_ex(e.ctx, EVP_aes_256_gcm(), null, key.ptr, iv.ptr), "gcm init");
    int n;
    if (aad.length) e.check(EVP_DecryptUpdate(e.ctx, null, &n, aad.ptr, cast(int) aad.length), "gcm aad");
    auto out_ = new ubyte[body.length];
    int len;
    if (body.length) e.check(EVP_DecryptUpdate(e.ctx, out_.ptr, &len, body.ptr, cast(int) body.length), "gcm decrypt");
    e.check(EVP_CIPHER_CTX_ctrl(e.ctx, EVP_CTRL_GCM_SET_TAG, 16, tag.ptr), "gcm tag");
    if (EVP_DecryptFinal_ex(e.ctx, out_.ptr + len, &n) != 1) throw new CryptoException("AES-GCM: bad tag");
    return out_;
}

/// AES-256-CBC with PKCS#7 padding (Signal's messages, WhatsApp's media and app state).
ubyte[] aesCbcEncrypt(scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] plain) {
    return cbc(true, key, iv, plain);
}
ubyte[] aesCbcDecrypt(scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] data) {
    return cbc(false, key, iv, data);
}

private ubyte[] cbc(bool enc, scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] input) {
    if (key.length != 32 || iv.length != 16) throw new CryptoException("AES-CBC wants a 32-byte key and a 16-byte IV");
    auto e = Evp(true);
    e.check(EVP_CipherInit_ex(e.ctx, EVP_aes_256_cbc(), null, key.ptr, iv.ptr, enc ? 1 : 0), "cbc init");
    auto out_ = new ubyte[input.length + 16];
    int len, fin;
    if (input.length) e.check(EVP_CipherUpdate(e.ctx, out_.ptr, &len, input.ptr, cast(int) input.length), "cbc update");
    if (EVP_CipherFinal_ex(e.ctx, out_.ptr + len, &fin) != 1) throw new CryptoException("AES-CBC: bad padding");
    return out_[0 .. len + fin];
}

/// AES-256-CTR (no padding; the same call encrypts and decrypts) — the phone-code pairing's wrapping.
ubyte[] aesCtr(scope const(ubyte)[] key, scope const(ubyte)[] iv, scope const(ubyte)[] input) {
    if (key.length != 32 || iv.length != 16) throw new CryptoException("AES-CTR wants a 32-byte key and a 16-byte IV");
    auto e = Evp(true);
    e.check(EVP_EncryptInit_ex(e.ctx, EVP_aes_256_ctr(), null, key.ptr, iv.ptr), "ctr init");
    auto out_ = new ubyte[input.length];
    int len, fin;
    if (input.length) e.check(EVP_EncryptUpdate(e.ctx, out_.ptr, &len, input.ptr, cast(int) input.length), "ctr update");
    e.check(EVP_EncryptFinal_ex(e.ctx, out_.ptr + len, &fin), "ctr final");
    return out_[0 .. len + fin];
}

/// PBKDF2-HMAC-SHA256 (OpenSSL), `length` bytes.
ubyte[] pbkdf2Sha256(scope const(ubyte)[] password, scope const(ubyte)[] salt, int iterations, size_t length) {
    auto out_ = new ubyte[length];
    if (PKCS5_PBKDF2_HMAC(cast(const(char)*) password.ptr, cast(int) password.length, salt.ptr, cast(int) salt.length,
            iterations, EVP_sha256(), cast(int) length, out_.ptr) != 1)
        throw new CryptoException("PBKDF2 failed");
    return out_;
}

unittest {
    // RFC 7914 §11: PBKDF2-HMAC-SHA256("passwd", "salt", 1, 64)
    import std.digest : toHexString, LetterCase;
    assert(toHexString!(LetterCase.lower)(pbkdf2Sha256(cast(const(ubyte)[]) "passwd", cast(const(ubyte)[]) "salt", 1, 64))[0 .. 32]
        == "55ac046e56e3089fec1691c22544b605");
    ubyte[32] k;
    ubyte[16] iv;
    const msg = cast(const(ubyte)[]) "the same call both ways";
    assert(aesCtr(k[], iv[], aesCtr(k[], iv[], msg)) == msg);
}

// ---- Curve25519 --------------------------------------------------------------------------------------

/// A Curve25519 key pair (WhatsApp's identity, noise, pre-keys, ephemerals).
struct KeyPair {
    ubyte[32] priv;   // clamped
    ubyte[32] pub;

    static KeyPair generate() {
        KeyPair k;
        randombytes_buf(k.priv.ptr, 32);
        k.priv[0] &= 248;
        k.priv[31] &= 127;
        k.priv[31] |= 64;
        crypto_scalarmult_curve25519_base(k.pub.ptr, k.priv.ptr);
        return k;
    }

    static KeyPair fromPrivate(const ubyte[32] priv) {
        KeyPair k;
        k.priv = priv;
        crypto_scalarmult_curve25519_base(k.pub.ptr, k.priv.ptr);
        return k;
    }
}

/// X25519; a CryptoException for a low-order peer key (an all-zero secret).
ubyte[32] sharedSecret(const ubyte[32] priv, const ubyte[32] pub) {
    ubyte[32] s;
    if (crypto_scalarmult_curve25519(s.ptr, priv.ptr, pub.ptr) != 0) throw new CryptoException("X25519: bad public key");
    return s;
}

/// XEdDSA signature (Signal's curve25519_sign): an Ed25519 signature under the Edwards form of the
/// Curve25519 key, with that form's sign bit kept in the signature's last byte.
ubyte[64] xeddsaSign(const ubyte[32] priv, scope const(ubyte)[] msg) {
    ubyte[32] edPub;
    if (crypto_scalarmult_ed25519_base_noclamp(edPub.ptr, priv.ptr) != 0) throw new CryptoException("XEdDSA: bad key");
    const signBit = edPub[31] & 0x80;

    // r = SHA-512(0xFE ‖ 0xFF×31 ‖ a ‖ M ‖ Z) mod L, Z random (Signal's crypto_sign_modified)
    ubyte[32] prefix = 0xff;
    prefix[0] = 0xfe;
    auto z = randomBytes(64);
    ubyte[64] rh;
    crypto_hash_sha512_state hs;
    crypto_hash_sha512_init(&hs);
    crypto_hash_sha512_update(&hs, prefix.ptr, 32);
    crypto_hash_sha512_update(&hs, priv.ptr, 32);
    crypto_hash_sha512_update(&hs, msg.ptr, msg.length);
    crypto_hash_sha512_update(&hs, z.ptr, 64);
    crypto_hash_sha512_final(&hs, rh.ptr);
    ubyte[32] r;
    crypto_core_ed25519_scalar_reduce(r.ptr, rh.ptr);

    ubyte[64] sig;
    if (crypto_scalarmult_ed25519_base_noclamp(sig.ptr, r.ptr) != 0) throw new CryptoException("XEdDSA: bad nonce");

    // h = SHA-512(R ‖ A ‖ M) mod L; S = r + h·a mod L
    ubyte[64] hh;
    crypto_hash_sha512_init(&hs);
    crypto_hash_sha512_update(&hs, sig.ptr, 32);
    crypto_hash_sha512_update(&hs, edPub.ptr, 32);
    crypto_hash_sha512_update(&hs, msg.ptr, msg.length);
    crypto_hash_sha512_final(&hs, hh.ptr);
    ubyte[32] h, a, ha;
    crypto_core_ed25519_scalar_reduce(h.ptr, hh.ptr);
    ubyte[64] wide;
    wide[0 .. 32] = priv[];
    crypto_core_ed25519_scalar_reduce(a.ptr, wide.ptr);
    crypto_core_ed25519_scalar_mul(ha.ptr, h.ptr, a.ptr);
    crypto_core_ed25519_scalar_add(sig.ptr + 32, r.ptr, ha.ptr);
    sig[63] = cast(ubyte)((sig[63] & 0x7f) | signBit);
    return sig;
}

/// XEdDSA verification (Signal's curve25519_verify).
bool xeddsaVerify(const ubyte[32] pub, scope const(ubyte)[] msg, const ubyte[64] signature) {
    ubyte[32] edPub = montgomeryToEdwards(pub);
    edPub[31] |= signature[63] & 0x80;
    ubyte[64] sig = signature;
    sig[63] &= 0x7f;
    return crypto_sign_ed25519_verify_detached(sig.ptr, msg.ptr, msg.length, edPub.ptr) == 0;
}

/// y = (u − 1) / (u + 1) mod 2^255 − 19, little-endian, sign bit clear.
private ubyte[32] montgomeryToEdwards(const ubyte[32] u) {
    import std.bigint : BigInt, powmod;
    static BigInt fromLE(const(ubyte)[] b) {
        BigInt x = 0;
        foreach_reverse (c; b) x = x * 256 + c;
        return x;
    }
    const p = (BigInt(1) << 255) - 19;
    ubyte[32] masked = u;
    masked[31] &= 0x7f;
    const x = fromLE(masked[]) % p;
    const y = ((x - 1 + p) % p) * powmod(x + 1, p - 2, p) % p;
    ubyte[32] o;
    BigInt t = y;
    foreach (i; 0 .. 32) {
        o[i] = cast(ubyte)(t % 256);
        t /= 256;
    }
    return o;
}

unittest {
    // RFC 5869 test case 1
    import std.digest : toHexString, LetterCase;
    ubyte[] ikm = new ubyte[22];
    ikm[] = 0x0b;
    ubyte[] salt = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    ubyte[] info = [0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9];
    assert(toHexString!(LetterCase.lower)(hkdf(ikm, salt, info, 42))
        == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");

    // GCM and CBC round trips, a tampered tag refused
    auto key = randomBytes(32), iv = randomBytes(12);
    auto sealed = aesGcmEncrypt(key, iv, cast(ubyte[]) "hello", cast(ubyte[]) "ad");
    assert(aesGcmDecrypt(key, iv, sealed, cast(ubyte[]) "ad") == cast(ubyte[]) "hello");
    sealed[0] ^= 1;
    import std.exception : assertThrown;
    assertThrown!CryptoException(aesGcmDecrypt(key, iv, sealed, cast(ubyte[]) "ad"));
    auto civ = randomBytes(16);
    assert(aesCbcDecrypt(key, civ, aesCbcEncrypt(key, civ, cast(ubyte[]) "sixteen bytes!!!x")) == cast(ubyte[]) "sixteen bytes!!!x");

    // X25519 agrees; XEdDSA verifies its own signatures and refuses a changed message
    auto a = KeyPair.generate(), b = KeyPair.generate();
    assert(sharedSecret(a.priv, b.pub) == sharedSecret(b.priv, a.pub));
    foreach (_; 0 .. 16) {
        auto k = KeyPair.generate();
        auto s = xeddsaSign(k.priv, cast(ubyte[]) "message");
        assert(xeddsaVerify(k.pub, cast(ubyte[]) "message", s));
        assert(!xeddsaVerify(k.pub, cast(ubyte[]) "messagf", s));
    }
}

unittest {
    // libsignal's own signatures (core/cmd/cryptovec) verify here; with WA_SIGNOUT set, signatures
    // made here are written for libsignal to check (go run ./cmd/cryptovec -verify FILE)
    import std.json : parseJSON;
    import std.conv : to;
    static ubyte[] unhex(string h) {
        ubyte[] b;
        foreach (i; 0 .. h.length / 2) b ~= h[i * 2 .. i * 2 + 2].to!ubyte(16);
        return b;
    }
    foreach (v; parseJSON(import("xeddsa-vectors.json")).array) {
        ubyte[32] pub = unhex(v["Pub"].str);
        ubyte[64] sig = unhex(v["Sig"].str);
        auto msg = unhex(v["Msg"].str);
        assert(xeddsaVerify(pub, msg, sig));
        sig[5] ^= 1;
        assert(!xeddsaVerify(pub, msg, sig));
    }
    import std.process : environment;
    if (auto path = environment.get("WA_SIGNOUT")) {
        import std.stdio : File;
        import std.digest : toHexString, LetterCase;
        auto f = File(path, "w");
        foreach (i; 0 .. 32) {
            auto k = KeyPair.generate();
            auto msg = randomBytes(i * 5);
            auto s = xeddsaSign(k.priv, msg);
            f.writefln("%s %s %s", toHexString!(LetterCase.lower)(k.pub), toHexString!(LetterCase.lower)(msg), toHexString!(LetterCase.lower)(s));
        }
    }
}
