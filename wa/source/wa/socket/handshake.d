/// Opening a connection: the Noise XX handshake with WhatsApp's server, its certificate chain checked
/// against WhatsApp's root key, and our ClientPayload — registration for a new device, login for a
/// paired one — presented as WhatsApp Web in Chrome on Linux (WAWebClientPayload).
module wa.socket.handshake;

import wa.crypto;
import wa.proto;
import wa.device;
import wa.socket.frames;
import wa.socket.noise;

/// WhatsApp's Noise root key: it signs the intermediate certificate (issuer serial 0).
immutable ubyte[32] waCertRoot = [0x14, 0x23, 0x75, 0x57, 0x4d, 0x0a, 0x58, 0x71, 0x66, 0xaa, 0xe7, 0x1e,
    0xbe, 0x51, 0x64, 0x37, 0xc4, 0xa2, 0x8b, 0x73, 0xe3, 0x69, 0x5c, 0x6c, 0xe1, 0xf7, 0xf9, 0x54, 0x5d,
    0xa8, 0xee, 0x6b];

/// The WhatsApp Web version we speak as (WAWebBuildConstants; the core keeps the current one).
struct WAVersion {
    uint primary = 2, secondary = 3000, tertiary = 1051155679;
    string toString() const {
        import std.format : format;
        return format("%d.%d.%d", primary, secondary, tertiary);
    }
}

/// Chrome's identity (as core/chrome.go).
enum chromeMajor = 148;

class HandshakeException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// The encrypted connection, after the handshake.
final class NoiseSocket {
    FrameSocket frames;
    NoiseTransport transport;

    import vibe.core.sync : TaskMutex;
    private TaskMutex sendLock;

    this(FrameSocket f, NoiseTransport t) { frames = f; transport = t; sendLock = new TaskMutex; }

    /// Seal and write one frame. Serialized: several tasks (the stanza loop, the keepalive) may
    /// send, and the Noise write counter must match the order frames hit the wire.
    void send(const(ubyte)[] plain) {
        sendLock.lock();
        scope (exit) sendLock.unlock();
        frames.send(transport.seal(plain));
    }
    /// The next plaintext frame; null when closed.
    ubyte[] receive() {
        auto f = frames.receive();
        return f is null ? null : transport.open(f);
    }
    void close() { frames.close(); }
}

NoiseSocket handshake(FrameSocket fs, ref const Device dev, WAVersion ver) {
    auto eph = KeyPair.generate();
    NoiseHandshake nh;
    nh.start(noisePattern, connHeader);
    nh.authenticate(eph.pub);
    fs.send(ProtoWriter().message(2, ProtoWriter().bytes(1, eph.pub)).buf);

    auto resp = fs.receive();
    if (resp is null) throw new HandshakeException("connection closed during the handshake");
    auto hello = ProtoReader(ProtoReader(resp).get(3).bytes);
    const serverEph = hello.get(1).bytes, serverStatic = hello.get(2).bytes, certSealed = hello.get(3).bytes;
    if (serverEph.length != 32 || serverStatic is null || certSealed is null)
        throw new HandshakeException("incomplete server hello");
    ubyte[32] se = serverEph;

    nh.authenticate(se);
    nh.mixSharedSecret(eph.priv, se);
    auto staticKey = nh.decrypt(serverStatic);
    if (staticKey.length != 32) throw new HandshakeException("bad server static key");
    ubyte[32] ss = staticKey;
    nh.mixSharedSecret(eph.priv, ss);
    verifyCertChain(nh.decrypt(certSealed), ss);

    auto myStatic = nh.encrypt(dev.noiseKey.pub);
    nh.mixSharedSecret(dev.noiseKey.priv, se);
    auto payload = nh.encrypt(clientPayload(dev, ver));
    fs.send(ProtoWriter().message(4, ProtoWriter().bytes(1, myStatic).bytes(2, payload)).buf);
    return new NoiseSocket(fs, nh.finish());
}

/// The leaf certificate must be WhatsApp's (signed by an intermediate signed by the root), within
/// its dates, and certify the static key the server just sent.
void verifyCertChain(const(ubyte)[] chain, const ubyte[32] serverStatic) {
    import std.datetime.systime : Clock;
    auto c = ProtoReader(chain);
    auto leaf = ProtoReader(c.get(1).bytes), inter = ProtoReader(c.get(2).bytes);
    const leafDetails = leaf.get(1).bytes, leafSig = leaf.get(2).bytes;
    const interDetails = inter.get(1).bytes, interSig = inter.get(2).bytes;
    if (leafSig.length != 64 || interSig.length != 64 || leafDetails is null || interDetails is null)
        throw new HandshakeException("incomplete certificate chain");
    if (!xeddsaVerify(waCertRoot, interDetails, interSig[0 .. 64]))
        throw new HandshakeException("intermediate certificate not signed by WhatsApp");
    auto id = ProtoReader(interDetails), ld = ProtoReader(leafDetails);
    if (id.get(2).value != 0) throw new HandshakeException("unexpected intermediate issuer");
    const interKey = id.get(3).bytes;
    if (interKey.length != 32) throw new HandshakeException("bad intermediate key");
    if (!xeddsaVerify(interKey[0 .. 32], leafDetails, leafSig[0 .. 64]))
        throw new HandshakeException("leaf certificate not signed by the intermediate");
    if (ld.get(2).value != id.get(1).value) throw new HandshakeException("leaf issued by another intermediate");
    if (ld.get(3).bytes != serverStatic[]) throw new HandshakeException("certificate is for another key");
    const now = Clock.currTime.toUnixTime;
    foreach (d; [id, ld]) {
        const nb = d.get(4).value, na = d.get(5).value;
        if ((nb && now < nb) || (na && now > na)) throw new HandshakeException("certificate out of its dates");
    }
}

/// DeviceProps as Chrome on Linux sends them (os, the browser's version, CHROME) with the history
/// sync settings whatsmeow sends (the ones WhatsApp Web sends the same way).
ubyte[] deviceProps() {
    auto ver = ProtoWriter().varint(1, chromeMajor).varint(2, 0).varint(3, 0);
    auto hist = ProtoWriter()
        .varint(3, 10240).boolean(4, true)
        .boolean(6, true).boolean(7, true).boolean(8, true).boolean(9, true).boolean(10, true)
        .boolean(11, true).boolean(12, true).boolean(14, true).boolean(15, true)
        .varint(19, 60).boolean(21, true).boolean(22, true);
    return ProtoWriter().str(1, "DQWhats").message(2, ver).varint(3, 1 /* CHROME */)
        .boolean(4, false).message(5, hist).buf;
}

/// ClientPayload: registration data for a new device, our JID for a paired one.
ubyte[] clientPayload(ref const Device dev, WAVersion ver) {
    import std.digest.md : md5Of;
    import std.conv : to;
    import std.algorithm : findSplit;
    auto appVersion = ProtoWriter().varint(1, ver.primary).varint(2, ver.secondary).varint(3, ver.tertiary);
    auto ua = ProtoWriter()
        .varint(1, 14 /* WEB */).message(2, appVersion)
        .str(3, "000").str(4, "000").str(5, "0.1").str(6, "").str(7, "Desktop").str(8, "0.1")
        .varint(10, 0 /* RELEASE */).str(11, "pt").str(12, "BR");
    auto web = ProtoWriter().varint(4, 0 /* WEB_BROWSER */);

    ProtoWriter p;
    if (!dev.paired) {
        ubyte[4] reg = [cast(ubyte)(dev.registrationId >> 24), cast(ubyte)(dev.registrationId >> 16),
                        cast(ubyte)(dev.registrationId >> 8), cast(ubyte) dev.registrationId];
        const k = dev.signedPreKey.id;
        ubyte[3] skeyId = [cast(ubyte)(k >> 16), cast(ubyte)(k >> 8), cast(ubyte) k];
        auto pairing = ProtoWriter()
            .bytes(1, reg).bytes(2, [djbType]).bytes(3, dev.identityKey.pub)
            .bytes(4, skeyId).bytes(5, dev.signedPreKey.key.pub).bytes(6, dev.signedPreKey.signature)
            .bytes(7, md5Of(ver.toString())).bytes(8, deviceProps());
        p.boolean(3, false).message(5, ua).message(6, web).varint(12, 1).varint(13, 1)
         .message(19, pairing).boolean(33, false);
    } else {
        // "5511…:3@s.whatsapp.net": the user number and the device
        auto at = dev.jid.findSplit("@");
        auto user = at[0].findSplit(":");
        const device = user[2].length ? user[2].to!uint : 0;
        p.varint(1, user[0].to!ulong).boolean(3, true).message(5, ua).message(6, web)
         .varint(12, 1).varint(13, 1).varint(18, device).int64(24, 1).boolean(33, true).boolean(41, true);
    }
    return p.buf;
}

unittest {
    // with WA_PAYLOADOUT set, the registration payload and its inputs go to a file for whatsmeow to
    // rebuild and compare (go run ./cmd/payloadvec FILE)
    import std.process : environment;
    import std.json : JSONValue;
    import std.digest : toHexString, LetterCase;
    auto dev = Device.create();
    auto p = clientPayload(dev, WAVersion());
    assert(p.length > 100);
    if (auto path = environment.get("WA_PAYLOADOUT")) {
        import std.file : write;
        JSONValue j;
        j["Identity"] = toHexString!(LetterCase.lower)(dev.identityKey.pub).idup;
        j["SkeyPub"] = toHexString!(LetterCase.lower)(dev.signedPreKey.key.pub).idup;
        j["SkeySig"] = toHexString!(LetterCase.lower)(dev.signedPreKey.signature).idup;
        j["Payload"] = toHexString!(LetterCase.lower)(p).idup;
        j["RegID"] = dev.registrationId;
        j["SkeyID"] = dev.signedPreKey.id;
        write(path, j.toString());
    }
}
