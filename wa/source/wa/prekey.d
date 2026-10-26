/// The pre-key exchange with the server, in the `encrypt` IQ namespace, exactly as WhatsApp Web and
/// whatsmeow do it:
///   - uploadPreKeysIQ(): publish our identity, a batch of one-time pre-keys, and our signed
///     pre-key, so other devices can start sessions with us while we are offline.
///   - fetchPreKeysIQ() / parsePreKeyBundle(): ask the server for a peer's bundle and turn the
///     `<user>` node of the reply into a PreKeyBundle we can feed to SessionState.initiate().
/// Pre-key ids go on the wire as 3 big-endian bytes; the registration id as 4.
module wa.prekey;

import wa.binary.node;
import wa.crypto : KeyPair;
import wa.device : Device, djbType;
import wa.signal.session : PreKeyBundle;

class PreKeyException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// One of our published one-time pre-keys: an id and its key pair (only the public half is sent).
struct PreKey {
    uint id;
    KeyPair key;
}

private Node leaf(string tag, const(ubyte)[] content) {
    Node n = Node(tag);
    n.hasBytes = true;
    n.bytes = content.idup;
    return n;
}

private ubyte[] be(uint v, size_t n) {
    ubyte[] o;
    o.length = n;
    foreach (i; 0 .. n) o[n - 1 - i] = cast(ubyte)(v >> (8 * i));
    return o;
}

private uint fromBE(const(ubyte)[] b) {
    uint v;
    foreach (x; b) v = (v << 8) | x;
    return v;
}

/// Parse "user@server" or "user:device@server" into a Jid (enough for a <user jid=…> request).
private Jid parseJid(string s) {
    import std.string : indexOf;
    import std.conv : to;
    const at = s.indexOf('@');
    if (at < 0) return Jid.pair(null, s);
    string local = s[0 .. at];
    string server = s[at + 1 .. $];
    const colon = local.indexOf(':');
    if (colon < 0) return Jid.pair(local, server);
    const dom = server == "lid" ? Jid.Domain.lid : Jid.Domain.whatsapp;
    return Jid.deviceJid(local[0 .. colon], dom, local[colon + 1 .. $].to!ushort);
}

/// A `<key>`/`<skey>` node: id (3 bytes), value (32 bytes), and — for a signed pre-key — a 64-byte
/// signature, which also switches the tag to `skey`.
Node preKeyNode(uint id, const ubyte[32] pub, const(ubyte)[] signature = null) {
    Node n = Node(signature is null ? "key" : "skey");
    n.children ~= leaf("id", be(id, 3));
    n.children ~= leaf("value", pub[]);
    if (signature !is null) n.children ~= leaf("signature", signature);
    return n;
}

/// The `<iq type=set xmlns=encrypt>` that publishes our pre-keys. `initial` only affects how many
/// keys we would generate; the batch is passed in.
Node uploadPreKeysIQ(ref const Device dev, const PreKey[] oneTime, string iqId) {
    Node list = Node("list");
    foreach (ref pk; oneTime) list.children ~= preKeyNode(pk.id, pk.key.pub);

    auto iq = node("iq", [["id", iqId], ["xmlns", "encrypt"], ["type", "set"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= leaf("registration", be(dev.registrationId, 4));
    iq.children ~= leaf("type", [djbType]);
    iq.children ~= leaf("identity", dev.identityKey.pub[]);
    iq.children ~= list;
    iq.children ~= preKeyNode(dev.signedPreKey.id, dev.signedPreKey.key.pub, dev.signedPreKey.signature[]);
    return iq;
}

/// The `<iq type=get xmlns=encrypt>` that asks for the bundles of the given peer JIDs.
Node fetchPreKeysIQ(const string[] jids, string iqId) {
    Node key = Node("key");
    foreach (j; jids) {
        auto u = node("user", [["jid", j], ["reason", "identity"]]);
        u.attr("jid").jid = parseJid(j);
        u.attr("jid").isJid = true;
        key.children ~= u;
    }
    auto iq = node("iq", [["id", iqId], ["xmlns", "encrypt"], ["type", "get"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= key;
    return iq;
}

private const(ubyte)[] leafBytes(const Node* n, string tag, size_t want = 0) {
    const c = n.child(tag);
    if (c is null || !c.hasBytes) throw new PreKeyException("missing <" ~ tag ~ ">");
    if (want && c.bytes.length != want)
        throw new PreKeyException("<" ~ tag ~ "> has wrong length");
    return c.bytes;
}

/// Parse a `<user>` node from a fetch reply into a bundle. The signed pre-key is required; the
/// one-time `<key>` is optional (the server may be out of them).
PreKeyBundle parsePreKeyBundle(const ref Node user) {
    if (user.child("error") !is null) throw new PreKeyException("server returned <error> for user");
    // whatsmeow accepts either the keys directly under <user> or wrapped in <keys>
    const keys = user.child("keys") !is null ? user.child("keys") : &user;

    PreKeyBundle b;
    // the registration sits beside <keys> (a retry receipt) or with the keys (a fetch reply)
    const reg = user.child("registration") !is null ? &user : keys;
    b.registrationId = fromBE(leafBytes(reg, "registration", 4));
    b.identityKey = leafBytes(keys, "identity", 32)[0 .. 32];

    const skey = keys.child("skey");
    if (skey is null) throw new PreKeyException("missing <skey>");
    b.signedPreKeyId = fromBE(leafBytes(skey, "id", 3));
    b.signedPreKey = leafBytes(skey, "value", 32)[0 .. 32];
    b.signedPreKeySignature = leafBytes(skey, "signature", 64)[0 .. 64];

    if (const key = keys.child("key")) {
        b.hasOneTime = true;
        b.preKeyId = fromBE(leafBytes(key, "id", 3));
        b.preKey = leafBytes(key, "value", 32)[0 .. 32];
    }
    return b;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.crypto : xeddsaVerify;
    import wa.device : serializedKey;
}

unittest {
    // Build the upload IQ for a fresh device, round-trip it through the real WAP codec, and read the
    // pre-keys back out — the server sees exactly these bytes.
    auto dev = Device.create();
    PreKey[] ot;
    foreach (i; 0 .. 3) ot ~= PreKey(i + 1, KeyPair.generate());

    auto iq = uploadPreKeysIQ(dev, ot, "1");
    auto back = decodeStanza(encodeStanza(iq));
    assert(back.get("xmlns") == "encrypt" && back.get("type") == "set");
    assert(back.child("identity").bytes == dev.identityKey.pub[]);
    assert(back.child("registration").bytes.length == 4);
    const list = back.child("list");
    assert(list !is null && list.children.length == 3);
    assert(list.children[0].child("id").bytes.length == 3);
    assert(list.children[0].child("value").bytes == ot[0].key.pub[]);
    const skey = back.child("skey");
    assert(skey !is null && skey.child("signature").bytes == dev.signedPreKey.signature[]);
    assert(fromBE(skey.child("id").bytes) == dev.signedPreKey.id);
}

unittest {
    // A peer's bundle, as the server would frame it, parses back and its signed pre-key verifies.
    auto peer = Device.create();
    auto peerOneTime = KeyPair.generate();

    Node user = node("user", [["jid", "5511999999999@s.whatsapp.net"]]);
    user.children ~= leaf("registration", be(peer.registrationId, 4));
    user.children ~= leaf("identity", peer.identityKey.pub[]);
    user.children ~= preKeyNode(42, peerOneTime.pub);
    user.children ~= preKeyNode(peer.signedPreKey.id, peer.signedPreKey.key.pub, peer.signedPreKey.signature[]);

    auto back = decodeStanza(encodeStanza(user));
    auto b = parsePreKeyBundle(back);
    assert(b.registrationId == peer.registrationId);
    assert(b.identityKey == peer.identityKey.pub);
    assert(b.hasOneTime && b.preKeyId == 42 && b.preKey == peerOneTime.pub);
    assert(b.signedPreKeyId == peer.signedPreKey.id && b.signedPreKey == peer.signedPreKey.key.pub);
    assert(xeddsaVerify(b.identityKey, serializedKey(b.signedPreKey), b.signedPreKeySignature));
}
