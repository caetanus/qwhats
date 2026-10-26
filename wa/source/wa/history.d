/// What the phone sends a freshly linked device, inside protocol messages from our own account:
///   - appStateSyncKeyShare: the keys that decrypt the app-state patches (contacts, names, pins,
///     mutes, archive…). Kept in the store's app_state_keys.
///   - historySyncNotification: a chunk of chat history — either inline (zlib) or a pointer to an
///     encrypted blob on the media servers ("WhatsApp History Keys"), zlib inside. The decompressed
///     HistorySync protobuf is kept in the store's history table for the app to read later.
/// Field numbers from whatsmeow's waE2E / waHistorySync protos.
module wa.history;

import std.zlib : uncompress;
import wa.message : innerMessage, MessageField;
import wa.proto : ProtoReader;

class HistoryException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// The ProtocolMessage (field 12) inside a Message, after peeling wrappers; null if none.
const(ubyte)[] protocolMessage(const(ubyte)[] messageProto) {
    auto r = ProtoReader(innerMessage(messageProto));
    return r.has(MessageField.protocol) ? r.get(MessageField.protocol).bytes : null;
}

// ProtocolMessage fields
enum uint pmType = 2, pmHistorySyncNotification = 6, pmAppStateSyncKeyShare = 7;

/// One app-state sync key: AppStateSyncKey { keyID{ keyID=1 }=1; keyData{ keyData=1;
/// fingerprint=2; timestamp=3 }=2 }.
struct AppStateKey {
    ubyte[] id;
    ubyte[] data;
    ubyte[] fingerprint;
    long timestamp;
}

/// The keys in an appStateSyncKeyShare (AppStateSyncKeyShare { repeated keys = 1; }).
AppStateKey[] parseAppStateKeyShare(const(ubyte)[] protocolMsg) {
    auto pm = ProtoReader(protocolMsg);
    if (!pm.has(pmAppStateSyncKeyShare)) return null;
    AppStateKey[] keys;
    foreach (f; ProtoReader(pm.get(pmAppStateSyncKeyShare).bytes)) {
        if (f.number != 1) continue;
        auto k = ProtoReader(f.bytes);
        AppStateKey key;
        if (k.has(1)) key.id = ProtoReader(k.get(1).bytes).get(1).bytes.dup;
        if (k.has(2)) {
            auto d = ProtoReader(k.get(2).bytes);
            key.data = d.get(1).bytes.dup;
            key.fingerprint = d.get(2).bytes.dup;
            key.timestamp = cast(long) d.get(3).value;
        }
        if (key.id.length && key.data.length) keys ~= key;
    }
    return keys;
}

/// HistorySyncNotification (the fields we use).
struct HistoryNotification {
    ubyte[] fileSha256;
    ulong fileLength;
    ubyte[] mediaKey;
    ubyte[] fileEncSha256;
    string directPath;
    uint syncType;
    uint chunkOrder;
    uint progress;
    ubyte[] inlinePayload;      // initialHistBootstrapInlinePayload (zlib), when present
}

bool hasHistoryNotification(const(ubyte)[] protocolMsg) {
    return ProtoReader(protocolMsg).has(pmHistorySyncNotification);
}

HistoryNotification parseHistoryNotification(const(ubyte)[] protocolMsg) {
    auto pm = ProtoReader(protocolMsg);
    if (!pm.has(pmHistorySyncNotification)) throw new HistoryException("no historySyncNotification");
    auto r = ProtoReader(pm.get(pmHistorySyncNotification).bytes);
    HistoryNotification n;
    n.fileSha256 = r.get(1).bytes.dup;
    n.fileLength = r.get(2).value;
    n.mediaKey = r.get(3).bytes.dup;
    n.fileEncSha256 = r.get(4).bytes.dup;
    n.directPath = cast(string) r.get(5).bytes.idup;
    n.syncType = cast(uint) r.get(6).value;
    n.chunkOrder = cast(uint) r.get(7).value;
    n.progress = cast(uint) r.get(9).value;
    n.inlinePayload = r.get(11).bytes.dup;
    return n;
}

/// The raw notification bytes (to queue a download for later).
const(ubyte)[] historyNotificationBytes(const(ubyte)[] protocolMsg) {
    return ProtoReader(protocolMsg).get(pmHistorySyncNotification).bytes;
}

/// Parse a queued notification from its raw bytes (as stored by historyNotificationBytes).
HistoryNotification parseHistoryNotificationRaw(const(ubyte)[] raw) {
    import wa.proto : ProtoWriter;
    return parseHistoryNotification(ProtoWriter().bytes(pmHistorySyncNotification, raw).buf);
}

/// The decompressed HistorySync protobuf for a notification. `download(directPath, encSha256)`
/// fetches the encrypted blob when the payload is not inline; it may be null for inline-only use.
ubyte[] historySyncPayload(const ref HistoryNotification n,
    ubyte[] delegate(string directPath, const(ubyte)[] encSha256) download) {
    import wa.media : decryptMedia, historyAppInfo;
    const(ubyte)[] compressed;
    if (n.inlinePayload.length) {
        compressed = n.inlinePayload;
    } else {
        if (download is null) throw new HistoryException("history blob needs a download");
        if (n.directPath.length == 0 || n.mediaKey.length != 32)
            throw new HistoryException("history notification has no direct path / media key");
        auto file = download(n.directPath, n.fileEncSha256);
        compressed = decryptMedia(file, n.mediaKey, historyAppInfo, n.fileEncSha256, n.fileSha256);
    }
    return cast(ubyte[]) uncompress(compressed);
}

/// HistorySync.syncType names (waHistorySync.HistorySync_HistorySyncType).
string syncTypeName(uint t) {
    switch (t) {
        case 0: return "INITIAL_BOOTSTRAP";
        case 1: return "INITIAL_STATUS_V3";
        case 2: return "FULL";
        case 3: return "RECENT";
        case 4: return "PUSH_NAME";
        case 5: return "NON_BLOCKING_DATA";
        case 6: return "ON_DEMAND";
        default: { import std.conv : to; return "TYPE_" ~ t.to!string; }
    }
}

/// HistorySync.nctSalt (field 19): the salt of the cstoken HMAC; null when absent.
const(ubyte)[] nctSalt(const(ubyte)[] historySync) {
    auto r = ProtoReader(historySync);
    return r.has(19) ? r.get(19).bytes : null;
}

/// HistorySync.phoneNumberToLidMappings (field 15: { pnJID = 1; lidJID = 2 }) as (pn user, lid user).
string[2][] phoneLidMappings(const(ubyte)[] historySync) {
    import std.string : indexOf;
    static string userOf(string j) { const at = j.indexOf('@'); return at < 0 ? j : j[0 .. at]; }
    string[2][] out_;
    foreach (f; ProtoReader(historySync)) {
        if (f.number != 15) continue;
        auto m = ProtoReader(f.bytes);
        const pn = userOf(cast(string) m.get(1).bytes), lid = userOf(cast(string) m.get(2).bytes);
        if (pn.length && lid.length) out_ ~= [pn, lid];
    }
    return out_;
}

/// Counts in a HistorySync — never content: HistorySync { syncType=1; conversations=2 (each with
/// messages=2); statusV3Messages=3; chunkOrder=5; progress=6; pushnames=7 }.
struct HistorySummary {
    uint syncType;
    uint chunkOrder;
    uint progress;
    size_t conversations;
    size_t messages;
    size_t pushnames;
    size_t statuses;
}

HistorySummary summarize(const(ubyte)[] historySync) {
    HistorySummary s;
    foreach (f; ProtoReader(historySync)) {
        switch (f.number) {
            case 1: s.syncType = cast(uint) f.value; break;
            case 2:
                s.conversations++;
                foreach (c; ProtoReader(f.bytes)) if (c.number == 2) s.messages++;
                break;
            case 3: s.statuses++; break;
            case 5: s.chunkOrder = cast(uint) f.value; break;
            case 6: s.progress = cast(uint) f.value; break;
            case 7: s.pushnames++; break;
            default: break;
        }
    }
    return s;
}

unittest {
    import std.zlib : compress;
    import wa.proto : ProtoWriter;

    // a HistorySync with 2 conversations (3 messages) and 1 pushname, inline in a notification
    auto conv1 = ProtoWriter().str(1, "a@s.whatsapp.net").bytes(2, [1]).bytes(2, [2]).buf;
    auto conv2 = ProtoWriter().str(1, "b@s.whatsapp.net").bytes(2, [3]).buf;
    auto hs = ProtoWriter().varint(1, 0).bytes(2, conv1).bytes(2, conv2).varint(5, 1).varint(6, 40)
        .bytes(7, ProtoWriter().str(1, "a@s.whatsapp.net").str(2, "A").buf).buf;
    auto notif = ProtoWriter().varint(6, 0).varint(7, 1).varint(9, 40).bytes(11, cast(ubyte[]) compress(hs)).buf;
    auto pm = ProtoWriter().varint(pmType, 5).bytes(pmHistorySyncNotification, notif).buf;
    auto msg = ProtoWriter().bytes(MessageField.protocol, pm).buf;

    auto p = protocolMessage(msg);
    assert(hasHistoryNotification(p));
    auto n = parseHistoryNotification(p);
    assert(n.syncType == 0 && n.chunkOrder == 1 && n.progress == 40 && n.inlinePayload.length);
    auto payload = historySyncPayload(n, null);
    assert(payload == hs);
    auto s = summarize(payload);
    assert(s.conversations == 2 && s.messages == 3 && s.pushnames == 1 && s.progress == 40);
    assert(parseHistoryNotificationRaw(historyNotificationBytes(p)).progress == 40);

    // app-state key share: one key
    auto keyData = ProtoWriter().bytes(1, [9, 9, 9]).bytes(2, ProtoWriter().varint(1, 7).buf).varint(3, 1700).buf;
    auto key = ProtoWriter().bytes(1, ProtoWriter().bytes(1, [0, 0, 1]).buf).bytes(2, keyData).buf;
    auto share = ProtoWriter().bytes(1, key).buf;
    auto pm2 = ProtoWriter().varint(pmType, 6).bytes(pmAppStateSyncKeyShare, share).buf;
    auto keys = parseAppStateKeyShare(pm2);
    assert(keys.length == 1 && keys[0].id == [0, 0, 1] && keys[0].data == [9, 9, 9] && keys[0].timestamp == 1700);
}
