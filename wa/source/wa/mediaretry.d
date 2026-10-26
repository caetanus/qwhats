/// Media the servers no longer have (403/404/410, or a file that no longer matches its hash): the
/// sender's phone is asked to upload it again (whatsmeow mediaretry.go, WhatsApp Web's "poke").
///   request:  `<receipt id=MSG to=OUR_JID type=server-error><encrypt><enc_p/><enc_iv/></encrypt>
///              <rmr jid=CHAT from_me participant?/></receipt>` — enc_p is the ServerErrorReceipt
///              {stanzaID} under AES-GCM (key: HKDF(mediaKey, "WhatsApp Media Retry Notification"),
///              the message id as additional data)
///   answer:   `<notification type=mediaretry id=MSG><rmr …/><encrypt>…</encrypt>` (or `<error code>`)
///              — the MediaRetryNotification {stanzaID, directPath, result} under the same key.
module wa.mediaretry;

import wa.binary.node;
import wa.crypto : aesGcmDecrypt, aesGcmEncrypt, hkdf, randomBytes;
import wa.proto : ProtoReader, ProtoWriter;

ubyte[] mediaRetryKey(const(ubyte)[] mediaKey) {
    return hkdf(mediaKey, null, cast(const(ubyte)[]) "WhatsApp Media Retry Notification", 32);
}

/// the encrypted ServerErrorReceipt {stanzaID = 1}
ubyte[] encryptRetryReceipt(string msgId, const(ubyte)[] mediaKey, const(ubyte)[] iv) {
    const plain = ProtoWriter().str(1, msgId).buf;
    return aesGcmEncrypt(mediaRetryKey(mediaKey), iv, plain, cast(const(ubyte)[]) msgId);
}

/// whatsmeow SendMediaRetryReceipt. `participant`: the sender in a group or a status (broadcast)
/// chat — whatsmeow's IsGroup covers both.
Node mediaRetryReceipt(string msgId, const(ubyte)[] mediaKey, Jid ownUser, Jid chat, bool fromMe, Jid participant,
        const(ubyte)[] iv = null) {
    if (iv.length == 0) iv = randomBytes(12);
    auto enc = Node("encrypt");
    auto p = Node("enc_p");
    p.bytes = encryptRetryReceipt(msgId, mediaKey, iv).idup;
    p.hasBytes = true;
    auto v = Node("enc_iv");
    v.bytes = iv.idup;
    v.hasBytes = true;
    enc.children ~= p;
    enc.children ~= v;
    auto rmr = Node("rmr");
    rmr.attrs ~= Attr("jid", Value(Jid.pair(chat.user, chat.server)));
    rmr.attrs ~= Attr("from_me", Value(fromMe ? "true" : "false"));
    if (participant.user.length && (chat.server == "g.us" || chat.server == "broadcast"))
        rmr.attrs ~= Attr("participant", Value(Jid.pair(participant.user, participant.server)));
    Node r = Node("receipt");
    r.attrs ~= Attr("id", Value(msgId));
    r.attrs ~= Attr("to", Value(Jid.pair(ownUser.user, ownUser.server)));
    r.attrs ~= Attr("type", Value("server-error"));
    r.children ~= enc;
    r.children ~= rmr;
    return r;
}

/// A parsed `mediaretry` notification (whatsmeow events.MediaRetry).
struct MediaRetry {
    string msgId;
    Jid chat, participant;
    bool fromMe;
    int errorCode = -1;       // the phone's <error code> (2: no longer on the phone), -1 none
    const(ubyte)[] ciphertext, iv;
}

MediaRetry parseMediaRetry(const ref Node n) {
    import std.conv : to;
    import wa.envelope : jidAttr;
    MediaRetry e;
    e.msgId = n.get("id");
    const rmr = n.child("rmr");
    if (rmr is null) throw new Exception("media retry notification without <rmr>");
    e.chat = jidAttr(*rmr, "jid");
    e.fromMe = rmr.get("from_me") == "true";
    if (rmr.attr("participant") !is null) e.participant = jidAttr(*rmr, "participant");
    if (const er = n.child("error")) {
        try e.errorCode = er.get("code").to!int; catch (Exception) e.errorCode = 0;
        return e;
    }
    const enc = n.child("encrypt");
    const p = enc !is null ? enc.child("enc_p") : null;
    const v = enc !is null ? enc.child("enc_iv") : null;
    if (p is null || v is null) throw new Exception("media retry notification without enc_p/enc_iv");
    e.ciphertext = p.bytes;
    e.iv = v.bytes;
    return e;
}

/// DecryptMediaRetryNotification: the new direct path; throws when the phone could not (no longer
/// has it: code 2) or the answer is not a success.
string decryptMediaRetry(const ref MediaRetry e, const(ubyte)[] mediaKey) {
    import std.conv : to;
    if (e.errorCode >= 0 && e.ciphertext.length == 0)
        throw new Exception(e.errorCode == 2 ? "the media is no longer on the sender's phone"
            : "media retry failed (code " ~ e.errorCode.to!string ~ ")");
    const plain = aesGcmDecrypt(mediaRetryKey(mediaKey), e.iv, e.ciphertext, cast(const(ubyte)[]) e.msgId);
    auto r = ProtoReader(plain);
    const result = r.has(3) ? r.get(3).value : 0;
    const path = cast(string) r.get(2).bytes.idup;
    if (result != 1 || path.length == 0)
        throw new Exception("media retry: the phone answered " ~ result.to!string);
    return path;
}

unittest {
    // vectors from core/cmd/mediaretryvec (whatsmeow's own code, fixed IVs)
    import std.digest : toHexString, LetterCase;
    import std.conv : hexString;
    import wa.envelope : parseJidString;
    static ubyte[] fill(size_t n, ubyte start) { auto b = new ubyte[n]; foreach (i, ref x; b) x = cast(ubyte)(start + i); return b; }
    static string hex(const(ubyte)[] b) { return toHexString!(LetterCase.lower)(b).idup; }
    const mk = fill(32, 0x10), id = "3EB0ABCDEF0123456789";
    assert(hex(mediaRetryKey(mk)) == "c338d935b0e6478e9e0928c983c39fc651f42a9debee3d2b9f6d47caf3ca3aeb");
    assert(hex(encryptRetryReceipt(id, mk, fill(12, 0xa0)))
        == "46c407f4ce288007c4d6da93557989c74b7eb12d81386aa32abc8b20b35714d30c03e95c12be");

    auto r = mediaRetryReceipt(id, mk, parseJidString("5511@s.whatsapp.net"), parseJidString("status@broadcast"), false,
        parseJidString("5522@s.whatsapp.net"), fill(12, 0xa0));
    assert(r.get("type") == "server-error" && r.get("to") == "5511@s.whatsapp.net" && r.get("id") == id);
    assert(r.child("rmr").get("jid") == "status@broadcast" && r.child("rmr").get("participant") == "5522@s.whatsapp.net"
        && r.child("rmr").get("from_me") == "false");
    auto dm = mediaRetryReceipt(id, mk, parseJidString("5511@s.whatsapp.net"), parseJidString("5533@s.whatsapp.net"), true,
        parseJidString("5511@s.whatsapp.net"));
    assert(dm.child("rmr").attr("participant") is null && dm.child("encrypt").child("enc_iv").bytes.length == 12);

    Node n = Node("notification");
    n.attrs ~= Attr("id", Value(id));
    n.attrs ~= Attr("type", Value("mediaretry"));
    Node rmr = Node("rmr");
    rmr.attrs ~= Attr("jid", Value(parseJidString("status@broadcast")));
    rmr.attrs ~= Attr("from_me", Value("false"));
    rmr.attrs ~= Attr("participant", Value(parseJidString("5522@s.whatsapp.net")));
    n.children ~= rmr;
    Node enc = Node("encrypt");
    Node p = Node("enc_p");
    p.bytes = cast(immutable(ubyte)[]) hexString!("1bcfc1cfd262e756b49777e26216ac14cd51e17263bba7f64904e31586e3b106"
        ~ "0fac9fe34a68de13c638b2dfa05694517288515a27e2ef57a5d1873a0f249fdf18e74794aa47677dbabe");
    p.hasBytes = true;
    Node v = Node("enc_iv");
    v.bytes = fill(12, 0xb0).idup;
    v.hasBytes = true;
    enc.children ~= p;
    enc.children ~= v;
    n.children ~= enc;
    auto e = parseMediaRetry(n);
    assert(e.msgId == id && e.chat.toString() == "status@broadcast" && e.participant.toString() == "5522@s.whatsapp.net");
    assert(decryptMediaRetry(e, mk) == "/v/t62.7118-24/new-path?ccb=11-4");

    Node gone = Node("notification");
    gone.attrs ~= Attr("id", Value(id));
    gone.children ~= rmr;
    Node er = Node("error");
    er.attrs ~= Attr("code", Value("2"));
    gone.children ~= er;
    auto g = parseMediaRetry(gone);
    bool threw;
    try decryptMediaRetry(g, mk); catch (Exception ex) threw = true;
    assert(g.errorCode == 2 && threw);
}
