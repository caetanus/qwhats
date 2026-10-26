/// Privacy tokens (whatsmeow tctoken.go / cstoken.go). A contact hands us a "trusted_contact"
/// token (notification type=privacy_token); we attach it as <tctoken> to every 1:1 message while it
/// is fresh (4 weekly buckets, ~28 days). Without one we attach <cstoken> = HMAC-SHA256(NCT salt,
/// "<lid>@lid") — the salt arrives in history sync. After sending, we issue our own token to the
/// peer once per weekly bucket. Tokens are kept under the peer's LID.
module wa.tctoken;

import wa.binary.node;
import wa.store.db : Store;

enum long tcTokenBucketDuration = 604_800;   // one week
enum long tcTokenNumBuckets = 4;

long tcTokenCutoff(long now) {
    const current = now / tcTokenBucketDuration;
    return (current - (tcTokenNumBuckets - 1)) * tcTokenBucketDuration;
}
bool tcTokenExpired(long ts, long now) { return ts == 0 || ts < tcTokenCutoff(now); }
bool shouldSendNewTCToken(long senderTs, long now) {
    return senderTs == 0 || now / tcTokenBucketDuration > senderTs / tcTokenBucketDuration;
}

/// types.JID.IsBot: the bot server, or the bot phone-number ranges (device 0).
bool isBot(const Jid j) {
    import std.algorithm : all;
    import std.ascii : isDigit;
    if (j.server == "bot") return true;
    if (j.server != "s.whatsapp.net" || j.device != 0) return false;
    const u = j.user;
    if (!u.all!isDigit) return false;
    return (u.length == 11 && u[0 .. 7] == "1313555") || (u.length == 11 && u[0 .. 9] == "131655500");
}

/// Whether a chat gets tctoken/cstoken at all (users and LIDs, not the PSA "0", not bots).
bool tokenEligible(const Jid j) {
    return (j.server == "s.whatsapp.net" || j.server == "lid") && j.user != "0" && !isBot(j);
}

/// The key tokens are stored under: the LID user JID when we know it (resolveTCTokenStorageLID).
string tokenStorageKey(Store store, const Jid j) {
    if (j.server == "s.whatsapp.net") {
        if (const lid = store.lidForPN(j.user)) if (lid.length) return lid ~ "@lid";
    }
    return Jid.pair(j.user, j.server).toString();
}

/// ensureTCToken: the stored token for the chat if still within the window, else null.
const(ubyte)[] currentTCToken(Store store, const Jid chat, long now) {
    long ts, senderTs;
    auto tok = store.privacyToken(tokenStorageKey(store, chat), ts, senderTs);
    if (tok.length && !tcTokenExpired(ts, now)) return tok;
    return null;
}

/// generateCsToken: HMAC-SHA256(NCT salt, "<lid>@lid"), or null without a salt / a LID.
const(ubyte)[] csToken(Store store, const Jid chat) {
    import wa.crypto : hmacSha256;
    if (!tokenEligible(chat)) return null;
    auto salt = store.blob("nct_salt");
    if (salt.length == 0) return null;
    string lid;
    if (chat.server == "lid") lid = chat.user;
    else if (const l = store.lidForPN(chat.user)) lid = l;
    if (lid.length == 0) return null;
    return hmacSha256(salt, cast(const(ubyte)[]) (lid ~ "@lid")).dup;
}

/// The <iq xmlns=privacy type=set><tokens><token jid t type=trusted_contact/></tokens></iq>.
Node issuePrivacyTokenIQ(const Jid user, long ts, string iqId) {
    import std.conv : to;
    auto t = Node("token");
    t.attrs ~= Attr("jid", Value(Jid.pair(user.user, user.server)));
    t.attrs ~= Attr("t", Value(ts.to!string));
    t.attrs ~= Attr("type", Value("trusted_contact"));
    auto tokens = Node("tokens");
    tokens.children ~= t;
    auto iq = node("iq", [["id", iqId], ["xmlns", "privacy"], ["type", "set"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= tokens;
    return iq;
}

/// handlePrivacyTokenNotification: store each trusted_contact token under the sender's LID.
/// Returns how many tokens were stored.
int storePrivacyTokens(Store store, const ref Node notification) {
    import wa.envelope : jidAttr;
    import std.conv : to;
    const tokens = notification.child("tokens");
    if (tokens is null) return 0;
    auto sender = jidAttr(notification, "from");
    string key;
    if (notification.attr("sender_lid") !is null) {
        auto sl = jidAttr(notification, "sender_lid");
        key = Jid.pair(sl.user, sl.server).toString();
    } else key = tokenStorageKey(store, sender);
    int n;
    foreach (ref t; tokens.children) {
        if (t.tag != "token" || t.get("type") != "trusted_contact" || !t.hasBytes) continue;
        long ts;
        try ts = t.get("t", "0").to!long; catch (Exception) {}
        store.putPrivacyToken(key, t.bytes, ts);
        n++;
    }
    return n;
}

unittest {
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    import wa.binary.codec : encodeStanza, decodeStanza;
    const path = tempDir ~ "/wa-tc-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto store = new Store(path);
    const now = 1_761_000_000L;

    assert(isBot(Jid.pair("13135551234", "s.whatsapp.net")) && !isBot(Jid.pair("5511999", "s.whatsapp.net")));
    assert(!tokenEligible(Jid.pair("0", "s.whatsapp.net")) && tokenEligible(Jid.pair("136", "lid")));

    // a token arrives for a PN sender whose LID we know → stored under the LID, used for both
    store.putLIDMapping("136777", "5511999");
    auto n = node("notification", [["type", "privacy_token"]]);
    n.attrs ~= Attr("from", Value(Jid.pair("5511999", "s.whatsapp.net")));
    auto tok = Node("token");
    tok.attrs ~= Attr("jid", Value(Jid.pair("5511000", "s.whatsapp.net")));
    tok.attrs ~= Attr("t", Value((now - 100).to!string));
    tok.attrs ~= Attr("type", Value("trusted_contact"));
    tok.hasBytes = true;
    tok.bytes = [7, 7];
    auto tokens = Node("tokens");
    tokens.children ~= tok;
    n.children ~= tokens;
    auto back = decodeStanza(encodeStanza(n));
    assert(storePrivacyTokens(store, back) == 1);
    assert(currentTCToken(store, Jid.pair("136777", "lid"), now) == [7, 7]);
    assert(currentTCToken(store, Jid.pair("5511999", "s.whatsapp.net"), now) == [7, 7]);
    assert(currentTCToken(store, Jid.pair("136777", "lid"), now + 40 * 86_400) is null);   // expired

    // cstoken needs the NCT salt and a LID
    assert(csToken(store, Jid.pair("136777", "lid")) is null);
    store.putBlob("nct_salt", [1, 2, 3]);
    import wa.crypto : hmacSha256;
    assert(csToken(store, Jid.pair("5511999", "s.whatsapp.net")) == hmacSha256([1, 2, 3], cast(ubyte[]) "136777@lid")[]);

    assert(shouldSendNewTCToken(0, now) && !shouldSendNewTCToken(now, now + 10)
        && shouldSendNewTCToken(now, now + tcTokenBucketDuration + 10));
}
