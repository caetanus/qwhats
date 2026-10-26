/// WhatsApp's encrypted media (and history-sync blobs, which travel the same way). A message carries
/// a 32-byte media key, the file's SHA-256 before and after encryption, and a direct path on the
/// media servers. The key expands (HKDF-SHA256, info = the media type's "app info") into
/// iv(16) ‖ cipherKey(32) ‖ macKey(32) ‖ refKey; the downloaded file is AES-256-CBC ciphertext
/// followed by a 10-byte HMAC-SHA256(macKey, iv ‖ ciphertext). Hosts come from the `w:m`
/// media_conn IQ. Mirrors whatsmeow's download.go (getMediaKeys/validateMedia/DownloadMediaWithPath).
module wa.media;

import wa.binary.node;
import wa.crypto : aesCbcDecrypt, hkdf, hmacSha256, sha256;

class MediaException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// HKDF "app info" per media type (whatsmeow MediaType) and its mms-type for the download URL.
enum string historyAppInfo = "WhatsApp History Keys";
enum string historyMmsType = "md-msg-hist";
enum string imageAppInfo = "WhatsApp Image Keys";
enum string videoAppInfo = "WhatsApp Video Keys";
enum string audioAppInfo = "WhatsApp Audio Keys";
enum string documentAppInfo = "WhatsApp Document Keys";

enum size_t mediaMacLength = 10;

struct MediaKeys {
    ubyte[16] iv;
    ubyte[32] cipherKey;
    ubyte[32] macKey;
}

MediaKeys mediaKeys(const(ubyte)[] mediaKey, string appInfo) {
    auto x = hkdf(mediaKey, null, cast(const(ubyte)[]) appInfo, 112);
    MediaKeys k;
    k.iv = x[0 .. 16];
    k.cipherKey = x[16 .. 48];
    k.macKey = x[48 .. 80];
    return k;
}

/// Verify and decrypt a downloaded media file (ciphertext ‖ 10-byte MAC). `encSha256` is the hash
/// of the whole downloaded file, `sha256Plain` of the decrypted result; either may be null to skip.
ubyte[] decryptMedia(const(ubyte)[] file, const(ubyte)[] mediaKey, string appInfo,
    const(ubyte)[] encSha256 = null, const(ubyte)[] sha256Plain = null) {
    if (file.length <= mediaMacLength) throw new MediaException("media file too short");
    if (encSha256.length == 32 && sha256(file)[] != encSha256)
        throw new MediaException("encrypted media SHA-256 mismatch");
    const k = mediaKeys(mediaKey, appInfo);
    const body = file[0 .. $ - mediaMacLength];
    const mac = file[$ - mediaMacLength .. $];
    const full = hmacSha256(k.macKey[], k.iv[], body);
    if (full[0 .. mediaMacLength] != mac) throw new MediaException("media HMAC mismatch");
    auto plain = aesCbcDecrypt(k.cipherKey[], k.iv[], body);
    if (sha256Plain.length == 32 && sha256(plain)[] != sha256Plain)
        throw new MediaException("decrypted media SHA-256 mismatch");
    return plain;
}

/// The `<iq xmlns=w:m type=set><media_conn/></iq>` that asks for the media hosts.
Node mediaConnIQ(string iqId) {
    auto iq = node("iq", [["id", iqId], ["xmlns", "w:m"], ["type", "set"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= Node("media_conn");
    return iq;
}

/// The host names out of a media_conn result.
string[] parseMediaConnHosts(const ref Node result) {
    const mc = result.child("media_conn");
    if (mc is null) return null;
    string[] hosts;
    foreach (ref h; mc.children)
        if (h.tag == "host" && h.get("hostname").length) hosts ~= h.get("hostname");
    return hosts;
}

/// The download URL for a direct path on a host (whatsmeow's DownloadMediaWithPath).
string mediaURL(string host, string directPath, const(ubyte)[] encSha256, string mmsType) {
    import std.base64 : Base64URL;
    return "https://" ~ host ~ directPath ~ "&hash=" ~ cast(string) Base64URL.encode(encSha256)
        ~ "&mms-type=" ~ mmsType ~ "&__wa-mms=";
}

/// GET a media URL with WhatsApp Web's Origin/Referer, returning the body. Throws on non-200.
ubyte[] httpGet(string url) {
    import vibe.http.client : requestHTTP, HTTPMethod;
    import vibe.stream.operations : readAll;
    import std.conv : to;
    ubyte[] body;
    int status;
    requestHTTP(url, (scope req) {
        req.method = HTTPMethod.GET;
        req.headers["Origin"] = "https://web.whatsapp.com";
        req.headers["Referer"] = "https://web.whatsapp.com/";
    }, (scope res) {
        status = res.statusCode;
        if (status == 200) body = res.bodyReader.readAll();
        else res.dropBody();
    });
    if (status != 200) throw new MediaException("media download HTTP " ~ status.to!string);
    return body;
}

unittest {
    // Self-consistency: encrypt the way WhatsApp does (pad, CBC, iv‖ct MAC, 10 bytes) and decrypt.
    import wa.crypto : aesCbcEncrypt, randomBytes;
    auto mediaKey = randomBytes(32);
    const k = mediaKeys(mediaKey, historyAppInfo);
    auto plain = cast(ubyte[]) "um blob de historico, comprimido em zlib na vida real";
    auto ct = aesCbcEncrypt(k.cipherKey[], k.iv[], plain);
    auto mac = hmacSha256(k.macKey[], k.iv[], ct)[0 .. mediaMacLength];
    auto file = ct ~ mac;
    auto back = decryptMedia(file, mediaKey, historyAppInfo, sha256(file)[], sha256(plain)[]);
    assert(back == plain);

    // a flipped byte must fail the MAC; a wrong app info derives different keys
    auto bad = file.dup; bad[3] ^= 1;
    bool threw;
    try decryptMedia(bad, mediaKey, historyAppInfo); catch (MediaException) threw = true;
    assert(threw);
    threw = false;
    try decryptMedia(file, mediaKey, imageAppInfo); catch (MediaException) threw = true;
    assert(threw);

    assert(mediaURL("mmg.whatsapp.net", "/v/t62?x=1", [0xfb, 0xff], "md-msg-hist")
        == "https://mmg.whatsapp.net/v/t62?x=1&hash=-_8=&mms-type=md-msg-hist&__wa-mms=");
}

/// An encrypted upload (whatsmeow Upload): a random media key, the file encrypted with its derived
/// keys, a 10-byte MAC appended; the hashes the message carries.
struct EncryptedMedia {
    ubyte[] upload;          // ciphertext ‖ mac10 — what is POSTed
    ubyte[] mediaKey, fileSHA256, fileEncSHA256;
    ulong fileLength;
}

EncryptedMedia encryptMedia(const(ubyte)[] plain, string appInfo) {
    import wa.crypto : aesCbcEncrypt, randomBytes;
    EncryptedMedia e;
    e.fileLength = plain.length;
    e.mediaKey = randomBytes(32);
    e.fileSHA256 = sha256(plain)[].dup;
    const k = mediaKeys(e.mediaKey, appInfo);
    auto ct = aesCbcEncrypt(k.cipherKey[], k.iv[], plain);
    const mac = hmacSha256(k.macKey[], k.iv[], ct);
    // appended in place (no third full-size copy of the file: plaintext, ciphertext and a
    // concatenated upload buffer were all alive at once for a big document)
    e.upload = ct;
    e.upload ~= mac[0 .. mediaMacLength];
    e.fileEncSHA256 = sha256(e.upload)[].dup;
    return e;
}

/// rawUpload's URL: https://<host>/mms/<mms type>/<token>?auth=<auth>&token=<token>, the token being
/// the base64url (padded) of the encrypted file's SHA-256 (url.Values.Encode: keys sorted, escaped).
string uploadURL(string host, string mmsType, const(ubyte)[] fileEncSHA256, string auth) {
    import std.base64 : Base64URL;
    import std.uri : encodeComponent;
    const token = cast(string) Base64URL.encode(fileEncSHA256);
    return "https://" ~ host ~ "/mms/" ~ mmsType ~ "/" ~ token
        ~ "?auth=" ~ queryEscape(auth) ~ "&token=" ~ queryEscape(token);
}

/// Go's url.QueryEscape: unreserved characters stay, space → '+', the rest %XX.
string queryEscape(string s) {
    import std.format : format;
    string o;
    foreach (char c; s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
            o ~= c;
        else if (c == ' ') o ~= '+';
        else o ~= format("%%%02X", cast(ubyte) c);
    }
    return o;
}

/// POST the upload with WhatsApp Web's Origin/Referer; returns the JSON answer (url, direct_path).
string httpPost(string url, const(ubyte)[] body) {
    import vibe.http.client : requestHTTP, HTTPMethod;
    import vibe.stream.operations : readAllUTF8;
    import std.conv : to;
    string answer;
    int status;
    requestHTTP(url, (scope req) {
        req.method = HTTPMethod.POST;
        req.headers["Origin"] = "https://web.whatsapp.com";
        req.headers["Referer"] = "https://web.whatsapp.com/";
        req.writeBody(body);
    }, (scope res) {
        status = res.statusCode;
        if (status == 200) answer = res.bodyReader.readAllUTF8();
        else res.dropBody();
    });
    if (status != 200) throw new MediaException("upload failed with status code " ~ status.to!string);
    return answer;
}

unittest {
    // what we encrypt for upload decrypts with our own download path (hashes and MAC included)
    auto plain = cast(const(ubyte)[]) "uma imagem qualquer, de verdade é um JPEG";
    auto e = encryptMedia(plain, "WhatsApp Image Keys");
    assert(decryptMedia(e.upload, e.mediaKey, "WhatsApp Image Keys", e.fileEncSHA256, e.fileSHA256) == plain);
    assert(queryEscape("a b/c+=") == "a+b%2Fc%2B%3D");
    auto u = uploadURL("mmg.whatsapp.net", "image", e.fileEncSHA256, "AU th/x=");
    assert(u.length > 40 && u[0 .. 34] == "https://mmg.whatsapp.net/mms/image" && u.canFindStr("&token="));
}

private bool canFindStr(string s, string sub) { import std.algorithm : canFind; return s.canFind(sub); }
