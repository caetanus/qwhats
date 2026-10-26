/// QR pairing as a companion device, the way WhatsApp Web's WAWebAltDeviceLinkingApi /
/// libsignal ADV flow does it:
///   1. the server sends <iq type=set><pair-device> with rotating <ref>s; each becomes a QR the
///      phone scans — `ref,base64(noiseKeyPub),base64(identityKeyPub),base64(advSecret)`.
///   2. once scanned, the server sends <iq type=set><pair-success> with the account's signed device
///      identity (ADV). We check its HMAC against our adv secret, verify the account's signature over
///      our identity, counter-sign it with our identity, store our JID, and ack with <pair-device-sign>.
module wa.pairing;

import std.base64 : Base64;
import std.conv : to;
import wa.binary.node;
import wa.crypto : hmacSha256, xeddsaSign, xeddsaVerify;
import wa.device;
import wa.proto : ProtoReader, ProtoWriter;

class PairingException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// The QR payloads for a <pair-device> stanza: one per <ref>, in order (the first is current, the
/// rest are the next rotations). Each is shown as a QR until the phone scans one.
string[] pairingQRs(ref const Device dev, const ref Node pairDevice) {
    const b64 = (const(ubyte)[] b) => cast(string) Base64.encode(b);
    const tail = "," ~ b64(dev.noiseKey.pub[]) ~ "," ~ b64(dev.identityKey.pub[]) ~ "," ~ b64(dev.advSecret[]);
    string[] out_;
    foreach (ref c; pairDevice.children)
        if (c.tag == "ref" && c.hasBytes)
            out_ ~= cast(string) c.bytes.idup ~ tail;
    return out_;
}

/// The ADV account signature's signed message: 0x06 0x00 ‖ device details ‖ our identity public key.
private ubyte[] accountMessage(const(ubyte)[] details, const ubyte[32] ourIdentityPub) {
    return cast(ubyte[])[6, 0] ~ details ~ ourIdentityPub[];
}

/// Our device signature's signed message: 0x06 0x01 ‖ device details ‖ our identity ‖ account key.
private ubyte[] deviceMessage(const(ubyte)[] details, const ubyte[32] ourIdentityPub, const(ubyte)[] accountKey) {
    return cast(ubyte[])[6, 1] ~ details ~ ourIdentityPub[] ~ accountKey;
}

/// Handle <iq type=set><pair-success>: verify the account's ADV identity, counter-sign it, store the
/// JID on `dev`, and return the <iq type=result> to send back. Throws PairingException on any failure
/// (bad HMAC, bad account signature, malformed stanza) — the connection should then be dropped.
Node handlePairSuccess(ref Device dev, const ref Node iq) {
    const ps = iq.child("pair-success");
    if (ps is null) throw new PairingException("no <pair-success>");
    const di = ps.child("device-identity");
    if (di is null || !di.hasBytes) throw new PairingException("no <device-identity>");

    // ADVSignedDeviceIdentityHMAC { bytes details = 1; bytes hmac = 2; }
    auto hmacMsg = ProtoReader(di.bytes);
    const details = hmacMsg.get(1).bytes;
    const theirHmac = hmacMsg.get(2).bytes;
    if (details.length == 0 || theirHmac.length != 32) throw new PairingException("malformed device-identity");
    const ourHmac = hmacSha256(dev.advSecret[], details);
    if (ourHmac[] != theirHmac[]) throw new PairingException("device-identity HMAC mismatch");

    // ADVSignedDeviceIdentity { bytes details = 1; bytes accountSignatureKey = 2;
    //                           bytes accountSignature = 3; bytes deviceSignature = 4; }
    auto sdi = ProtoReader(details);
    const advDetails = sdi.get(1).bytes;         // ADVDeviceIdentity
    const accountKey = sdi.get(2).bytes;         // the account's identity public key (32)
    const accountSig = sdi.get(3).bytes;         // 64
    if (advDetails.length == 0 || accountKey.length != 32 || accountSig.length != 64)
        throw new PairingException("malformed signed device-identity");

    ubyte[32] accountKeyFixed = accountKey[0 .. 32];
    ubyte[64] accountSigFixed = accountSig[0 .. 64];
    if (!xeddsaVerify(accountKeyFixed, accountMessage(advDetails, dev.identityKey.pub), accountSigFixed))
        throw new PairingException("account signature does not verify");

    // our counter-signature over the same identity, then the identity sent back WITHOUT the account
    // key (field 2 dropped, as WhatsApp Web does), carrying our device signature (field 4)
    const deviceSig = xeddsaSign(dev.identityKey.priv, deviceMessage(advDetails, dev.identityKey.pub, accountKey));
    // whatsmeow keeps the full identity (with the account key) as Store.Account
    dev.account = ProtoWriter().bytes(1, advDetails).bytes(2, accountKey).bytes(3, accountSig)
        .bytes(4, deviceSig[]).buf;
    auto resp = ProtoWriter()
        .bytes(1, advDetails)
        .bytes(3, accountSig)
        .bytes(4, deviceSig[]);

    // ADVDeviceIdentity { uint32 rawId = 1; uint64 timestamp = 2; uint32 keyIndex = 3; } — the key index
    const keyIndex = ProtoReader(advDetails).get(3).value;

    // our account JID, from <device jid=…> (and the LID, when present)
    const devNode = ps.child("device");
    if (devNode is null) throw new PairingException("no <device> in pair-success");
    dev.jid = devNode.get("jid");
    if (dev.jid.length == 0) throw new PairingException("no jid in <device>");
    dev.lid = devNode.get("lid");
    if (const biz = ps.child("biz")) { /* a business account: name in biz attrs, ignored here */ }

    // <iq to=s.whatsapp.net type=result id=…><pair-device-sign>
    //   <device-identity key-index="N">resp</device-identity></pair-device-sign></iq>
    Node identity;
    identity.tag = "device-identity";
    identity.attrs ~= Attr("key-index", Value(to!string(keyIndex)));
    identity.hasBytes = true;
    identity.bytes = resp.buf;

    Node sign;
    sign.tag = "pair-device-sign";
    sign.children ~= identity;

    auto ack = node("iq", [["to", "s.whatsapp.net"], ["type", "result"], ["id", iq.get("id")]]);
    ack.attrs[0].value = Value(Jid.pair(null, "s.whatsapp.net"));
    ack.children ~= sign;
    return ack;
}
