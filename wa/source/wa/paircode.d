/// Linking with a phone number instead of a QR (whatsmeow pair-code.go, WhatsApp's "Link with phone
/// number"): we show an 8-character code, the phone's user types it in, and both sides prove they
/// share it.
///   1. companion_hello: our ephemeral public key, AES-CTR-wrapped under PBKDF2(code) — the server
///      answers with a pairing ref; the code is shown as "ABCD-EFGH".
///   2. the phone's notification link_code_companion_reg: its own wrapped ephemeral key and its
///      identity. We unwrap it, derive the key-bundle key (X25519 + HKDF), send our identity, the
///      phone's identity and fresh randomness under AES-GCM (companion_finish), and keep the ADV
///      secret the following <pair-success> is checked with (wa.pairing).
module wa.paircode;

import wa.binary.node;
import wa.crypto : KeyPair, aesCtr, aesGcmEncrypt, hkdf, pbkdf2Sha256, randomBytes, sharedSecret;

/// What step 2 needs from step 1.
struct PhoneLinking {
    Jid jid;            // the phone number's account
    KeyPair ephemeral;
    string code;        // the 8 characters, without the dash
    string pairingRef;
}

private immutable alphabet = "123456789ABCDEFGHJKLMNPQRSTVWXYZ";   // no 0, I, O, U

/// 5 bytes → 8 characters of WhatsApp's linking base32
string linkingCode(const ubyte[5] b) {
    ulong v;
    foreach (x; b) v = (v << 8) | x;
    char[8] o;
    foreach (i; 0 .. 8) o[i] = alphabet[(v >> (35 - 5 * i)) & 31];
    return o.idup;
}

/// salt(32) ‖ iv(16) ‖ AES-CTR(PBKDF2-SHA256(code, salt, 131072), iv, pub)
ubyte[] wrapKey(string code, const(ubyte)[] salt, const(ubyte)[] iv, const(ubyte)[] pub) {
    const key = pbkdf2Sha256(cast(const(ubyte)[]) code, salt, 2 << 16, 32);
    return salt.dup ~ iv ~ aesCtr(key, iv, pub);
}

ubyte[32] unwrapKey(string code, const(ubyte)[] wrapped) {
    if (wrapped.length < 80) throw new Exception("wrapped key too short");
    const key = pbkdf2Sha256(cast(const(ubyte)[]) code, wrapped[0 .. 32], 2 << 16, 32);
    ubyte[32] o = aesCtr(key, wrapped[32 .. 48], wrapped[48 .. 80])[0 .. 32];
    return o;
}

/// whatsmeow PairPhone's IQ: `<iq xmlns=md type=set to=s.whatsapp.net><link_code_companion_reg
/// jid=PHONE stage=companion_hello should_show_push_notification=true>…`
Node companionHelloIQ(Jid phone, const(ubyte)[] wrappedEphemeral, const ubyte[32] noisePub, string platformId,
        string platformDisplay, string iqId) {
    auto r = Node("link_code_companion_reg");
    r.attrs ~= Attr("jid", Value(phone));
    r.attrs ~= Attr("stage", Value("companion_hello"));
    r.attrs ~= Attr("should_show_push_notification", Value("true"));
    r.children ~= bytesNode("link_code_pairing_wrapped_companion_ephemeral_pub", wrappedEphemeral);
    r.children ~= bytesNode("companion_server_auth_key_pub", noisePub[]);
    r.children ~= bytesNode("companion_platform_id", cast(const(ubyte)[]) platformId);
    r.children ~= bytesNode("companion_platform_display", cast(const(ubyte)[]) platformDisplay);
    r.children ~= bytesNode("link_code_pairing_nonce", [0]);
    return mdIQ(r, iqId);
}

/// Step 1: a new code and its hello. `phone`: digits only, international.
Node startPhoneLinking(string phone, const ubyte[32] noisePub, string platformDisplay, string iqId, out PhoneLinking pl) {
    import std.ascii : isDigit;
    import std.algorithm : filter;
    import std.conv : to;
    const digits = phone.filter!(c => c.isDigit).to!string;
    if (digits.length <= 6) throw new Exception("phone number too short");
    if (digits[0] == '0') throw new Exception("the phone number must be international (country code first)");
    pl.jid = Jid.pair(digits, "s.whatsapp.net");
    pl.ephemeral = KeyPair.generate();
    ubyte[5] c = randomBytes(5)[0 .. 5];
    pl.code = linkingCode(c);
    const wrapped = wrapKey(pl.code, randomBytes(32), randomBytes(16), pl.ephemeral.pub[]);
    return companionHelloIQ(pl.jid, wrapped, noisePub, "1", platformDisplay, iqId);
}

/// the server's answer to the hello: its pairing ref
string pairingRef(const ref Node r) {
    if (r.get("type") != "result") {
        const e = r.child("error");
        throw new Exception("phone linking refused" ~ (e !is null ? " (" ~ e.get("code") ~ ")" : ""));
    }
    const reg = r.child("link_code_companion_reg");
    const ref_ = reg !is null ? reg.child("link_code_pairing_ref") : null;
    if (ref_ is null || !ref_.hasBytes) throw new Exception("no link_code_pairing_ref in the answer");
    return cast(string) ref_.bytes.idup;
}

/// "ABCDEFGH" → "ABCD-EFGH", as shown
string shownCode(string code) { return code[0 .. 4] ~ "-" ~ code[4 .. $]; }

/// Step 2's crypto with its randomness given (whatsmeow handleCodePairNotification): the wrapped
/// key bundle and the ADV secret.
void finishCrypto(const ref PhoneLinking pl, const(ubyte)[] primaryWrapped, const(ubyte)[] primaryIdentityPub,
        const KeyPair identity, const(ubyte)[] advRandom, const(ubyte)[] kbSalt, const(ubyte)[] kbNonce,
        out ubyte[] wrappedBundle, out ubyte[32] advSecret) {
    if (primaryIdentityPub.length != 32) throw new Exception("bad primary identity key");
    const primaryPub = unwrapKey(pl.code, primaryWrapped);
    const shared_ = sharedSecret(pl.ephemeral.priv, primaryPub);
    const kbKey = hkdf(shared_[], kbSalt, cast(const(ubyte)[]) "link_code_pairing_key_bundle_encryption_key", 32);
    const plain = identity.pub[] ~ primaryIdentityPub ~ advRandom;
    wrappedBundle = kbSalt.dup ~ kbNonce ~ aesGcmEncrypt(kbKey, kbNonce, plain);
    ubyte[32] pid = primaryIdentityPub[0 .. 32];
    const idShared = sharedSecret(identity.priv, pid);
    advSecret = hkdf(shared_[] ~ idShared[] ~ advRandom, null, cast(const(ubyte)[]) "adv_secret", 32)[0 .. 32];
}

/// Step 2: the phone's notification → the companion_finish IQ; `advSecret` is the device's from now on.
Node finishPhoneLinking(const ref PhoneLinking pl, const ref Node notification, const KeyPair identity, string iqId,
        out ubyte[32] advSecret) {
    const reg = notification.child("link_code_companion_reg");
    if (reg is null) throw new Exception("no link_code_companion_reg in the notification");
    const ref_ = reg.child("link_code_pairing_ref");
    if (ref_ is null || cast(string) ref_.bytes != pl.pairingRef) throw new Exception("pairing ref mismatch");
    const w = reg.child("link_code_pairing_wrapped_primary_ephemeral_pub");
    const pid = reg.child("primary_identity_pub");
    if (w is null || w.bytes.length < 80) throw new Exception("no primary ephemeral key in the notification");
    if (pid is null) throw new Exception("no primary identity in the notification");
    ubyte[] bundle;
    finishCrypto(pl, w.bytes, pid.bytes, identity, randomBytes(32), randomBytes(32), randomBytes(12), bundle, advSecret);
    auto r = Node("link_code_companion_reg");
    r.attrs ~= Attr("jid", Value(pl.jid));
    r.attrs ~= Attr("stage", Value("companion_finish"));
    r.children ~= bytesNode("link_code_pairing_wrapped_key_bundle", bundle);
    r.children ~= bytesNode("companion_identity_public", identity.pub[]);
    r.children ~= bytesNode("link_code_pairing_ref", ref_.bytes);
    return mdIQ(r, iqId);
}

private Node bytesNode(string tag, const(ubyte)[] b) {
    auto n = Node(tag);
    n.bytes = b.idup;
    n.hasBytes = true;
    return n;
}

private Node mdIQ(Node content, string iqId) {
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("md"));
    iq.attrs ~= Attr("type", Value("set"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.children ~= content;
    return iq;
}

unittest {
    // vectors from core/cmd/paircodevec (whatsmeow's own derivations, fixed randomness)
    import std.digest : toHexString, LetterCase;
    import std.conv : hexString;
    static ubyte[] fill(size_t n, ubyte start) { auto b = new ubyte[n]; foreach (i, ref x; b) x = cast(ubyte)(start + i); return b; }
    static string hex(const(ubyte)[] b) { return toHexString!(LetterCase.lower)(b).idup; }
    ubyte[5] c = fill(5, 0xa0)[0 .. 5];
    PhoneLinking pl;
    pl.code = linkingCode(c);
    assert(pl.code == "M3HT69X5" && shownCode(pl.code) == "M3HT-69X5");
    ubyte[32] priv = fill(32, 1)[0 .. 32];
    pl.ephemeral = KeyPair.fromPrivate(priv);
    assert(hex(pl.ephemeral.pub[]) == "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c");
    assert(hex(wrapKey(pl.code, fill(32, 0x40), fill(16, 0x70), pl.ephemeral.pub[]))
        == "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f707172737475767778797a7b7c7d7e7f"
         ~ "615cd3533b9c366495128ef57eb25e9d845fec0c8e81afcc5500299611a3c881");
    const primWrapped = cast(const(ubyte)[]) hexString!("909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
        ~ "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf075b98ce28c2b890118177cb6cdd655e200e28ba10fd7b0f35a018e077d21494");
    const primIdent = cast(const(ubyte)[]) hexString!"0233f006ef4bed144ea0a5bb46c7067c7c2acec5f8cc811f3df59fdcd5ac7614";
    ubyte[32] ipriv = fill(32, 0x31)[0 .. 32];
    ubyte[] bundle;
    ubyte[32] adv;
    finishCrypto(pl, primWrapped, primIdent, KeyPair.fromPrivate(ipriv), fill(32, 0x11), fill(32, 0x61), fill(12, 0xe0), bundle, adv);
    assert(hex(bundle) == "6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80e0e1e2e3e4e5e6e7e8e9eaeb"
        ~ "22a23b4058a7ce1e0d0b19e4585a5f2d18ae2460e51b4e92a849aad7558e9d92658df208de2f1a329320778c7f6d68df97781ccb02c3"
        ~ "781c2526e26fb120cef4973238386ca01a5a4676ffd6089f8748167f47d4b542ada14b6207c2decbfcb646f9ba6c2b352753fc0e2719"
        ~ "2ae5acab");
    assert(hex(adv[]) == "a58558f7b7c057a0f974ff3871bf3184b09cfa0429d96227198aeb5dde008c62");

    PhoneLinking out_;
    ubyte[32] noise;
    auto hello = startPhoneLinking("+55 (11) 99999-0000", noise, "Chrome (Linux)", "i-1", out_);
    const reg = hello.child("link_code_companion_reg");
    assert(hello.get("xmlns") == "md" && reg.get("jid") == "5511999990000@s.whatsapp.net" && reg.get("stage") == "companion_hello");
    assert(reg.child("link_code_pairing_wrapped_companion_ephemeral_pub").bytes.length == 80 && out_.code.length == 8);
    assert(unwrapKey(out_.code, reg.child("link_code_pairing_wrapped_companion_ephemeral_pub").bytes) == out_.ephemeral.pub);
}
