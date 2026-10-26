// wa-vectool: read a peer's pre-key bundle as JSON (and the plaintexts to send) on stdin, start a
// Signal session with the D core, encrypt each plaintext (WhatsApp-padded), and print the wire
// bytes as JSON. core/cmd/signalsend drives this and decrypts the output with libsignal, proving
// what our stack sends is exactly what a real WhatsApp client would accept.
import std.stdio, std.json, std.conv, std.array;
import wa.device : Device;
import wa.crypto : KeyPair;
import wa.message : pad;
import wa.signal.session : SessionState, PreKeyBundle;

ubyte[N] hexN(size_t N)(string h) {
    ubyte[N] o;
    foreach (i; 0 .. N) o[i] = cast(ubyte) h[2 * i .. 2 * i + 2].to!ubyte(16);
    return o;
}

/// --group: create our own sender key, encrypt the given plaintexts, print {skdm, messages} for
/// core/cmd/senderkeyvec -verify (libsignal decrypts what the D core sends to a group).
void groupMode(string[] plaintexts) {
    import wa.signal.group : SenderKeyRecord, serializeSenderKeyDistribution;
    static string hex(const(ubyte)[] b) { string s; foreach (x; b) s ~= format("%02x", x); return s; }
    auto rec = SenderKeyRecord.createOwn();
    auto skdm = serializeSenderKeyDistribution(rec.distribution());
    JSONValue[] msgs;
    foreach (p; plaintexts)
        msgs ~= JSONValue(["serialized": JSONValue(hex(rec.encrypt(cast(ubyte[]) p))), "plaintext": JSONValue(p)]);
    JSONValue outv = ["skdm": JSONValue(hex(skdm)), "messages": JSONValue(msgs)];
    writeln(outv.toString());
}

/// --model-check DB: run wa.model.content over every stored raw Message of the Go core's DB and
/// compare the content fields with the JSON the Go core produced. Prints counts only (no content).
void modelCheck(string dbPath) {
    import std.process : execute;
    import std.base64 : Base64;
    import std.string : splitLines, indexOf;
    import wa.model : content, historyContent;
    // sqlite3 CLI: id, hex(raw), json — read-only
    auto r = execute(["sqlite3", "-readonly", "-separator", "\t", dbPath,
        "SELECT key, hex(raw), json FROM msgs WHERE raw IS NOT NULL AND length(raw) > 0"]);
    if (r.status != 0) { writeln("sqlite3 failed: ", r.output); return; }
    static immutable string[] keys = ["type", "body", "caption", "title", "description", "matchedText",
        "pollName", "loc", "isForwarded", "forwardingScore", "footer", "isLive"];
    static immutable string[] mediaKeys = ["mimetype", "size", "width", "height", "duration", "filename",
        "pageCount", "isGif", "isAnimated", "isViewOnce", "waveform", "preview"];
    size_t rows, compared, notMsg, skipped;
    size_t[string] miss;
    string[][string] examples;
    foreach (line; r.output.splitLines) {
        const t1 = line.indexOf('\t');
        if (t1 < 0) continue;
        const t2 = line.indexOf('\t', t1 + 1);
        if (t2 < 0) continue;
        const key = line[0 .. t1];
        const hexs = line[t1 + 1 .. t2];
        JSONValue want;
        try want = parseJSON(line[t2 + 1 .. $]); catch (Exception) continue;
        rows++;
        // later edits/revokes/stubs change the stored JSON away from the raw content
        if ("isEdited" in want || want["type"].str == "revoked" || want["type"].str == "gp2"
            || want["type"].str == "e2e_notification" || want["type"].str == "call_log") { skipped++; continue; }
        auto raw = new ubyte[hexs.length / 2];
        foreach (i; 0 .. raw.length) raw[i] = cast(ubyte) hexs[2 * i .. 2 * i + 2].to!ubyte(16);
        JSONValue got;
        string hid;
        if (!content(historyContent(raw, hid), got)) { notMsg++; miss["(not a message)"]++; if (examples.get("(not a message)", null).length < 5) examples["(not a message)"] ~= key; continue; }
        compared++;
        void cmp(string name, JSONValue* a, JSONValue* b) {
            const sa = a is null ? "" : a.toString, sb = b is null ? "" : b.toString;
            if (sa != sb) {
                if (name == "mediaData.preview") writefln("   preview lengths: ours %d, Go %d", sa.length, sb.length);
                miss[name]++;
                if (examples.get(name, null).length < 3) examples[name] ~= key;
            }
        }
        foreach (k; keys) cmp(k, k in got, k in want);
        auto gm = "mediaData" in got, wm = "mediaData" in want;
        if ((gm is null) != (wm is null)) cmp("mediaData(presence)", gm, wm);
        else if (gm !is null) foreach (k; mediaKeys) cmp("mediaData." ~ k, k in *gm, k in *wm);
        auto gq = "quotedMsg" in got, wq = "quotedMsg" in want;
        cmp("quotedMsg.id", gq is null ? null : "id" in *gq, wq is null ? null : "id" in *wq);
        cmp("quotedMsg.type", gq is null ? null : "type" in *gq, wq is null ? null : "type" in *wq);
        cmp("quotedMsg.body", gq is null ? null : "body" in *gq, wq is null ? null : "body" in *wq);
        auto gb = "buttons" in got, wb = "buttons" in want;
        cmp("buttons", gb, wb);
        cmp("vcardList", "vcardList" in got, "vcardList" in want);
        cmp("mentionedJidList", "mentionedJidList" in got, "mentionedJidList" in want);
        cmp("pollOptions", "pollOptions" in got, "pollOptions" in want);
        cmp("lat", "lat" in got, "lat" in want);
    }
    writefln("rows %d, compared %d, skipped (edited/revoked/system) %d, not a message %d", rows, compared, skipped, notMsg);
    if (miss.length == 0) { writeln("ALL FIELDS MATCH"); return; }
    foreach (k, v; miss) writefln("  mismatch %-24s %6d   e.g. %s", k, v, examples.get(k, null));
}

/// --ingest-check DCORE_DB GO_DB: replay the history blobs stored by the D core into a scratch chat
/// store with wa.app.ingest, then compare with the Go core's store for the same messages and chats.
/// Prints counts only (no content).
void ingestCheck(string dcoreDb, string goDb, string scratchDir) {
    import std.file : copy, exists, remove, mkdirRecurse;
    import std.path : buildPath;
    import std.process : execute;
    import std.string : splitLines, indexOf;
    import wa.store.db : Store;
    import wa.store.sql : Db;
    import wa.app.chatstore : ChatStore;
    import wa.app.ingest : Ingest;
    mkdirRecurse(scratchDir);
    const keysCopy = buildPath(scratchDir, "dcore-copy.db"), chats = buildPath(scratchDir, "dcore-chats.db");
    foreach (f; [keysCopy, chats]) foreach (sfx; ["", "-wal", "-shm"]) if (exists(f ~ sfx)) remove(f ~ sfx);
    // copy through sqlite's backup so the WAL is included
    auto bk = execute(["sqlite3", dcoreDb, ".backup '" ~ keysCopy ~ "'"]);
    if (bk.status != 0) { writeln("backup failed: ", bk.output); return; }
    auto keys = new Store(keysCopy);
    auto cs = new ChatStore(new Db(chats));
    auto dev = keys.loadDevice();
    import std.string : split;
    const ownPN = dev.jid[0 .. dev.jid.indexOf(':') > 0 ? dev.jid.indexOf(':') : dev.jid.indexOf('@')];
    size_t events;
    auto ing = new Ingest(cs, keys, "main", ownPN ~ "@s.whatsapp.net", (string m, JSONValue p) { events++; });
    auto blobs = keys.historyPayloads();
    foreach (b; blobs) ing.storeHistory(b);
    writefln("ingested %d history blobs: %d chats, %d messages", blobs.length,
        cs.db.scalarInt("SELECT count(*) FROM chats"), cs.db.scalarInt("SELECT count(*) FROM msgs"));

    // the same keys in the Go store
    auto ours = new Db(chats);
    ours.exec("ATTACH DATABASE 'file:" ~ goDb ~ "?mode=ro' AS go");
    writefln("messages in both stores: %d", ours.scalarInt(
        "SELECT count(*) FROM msgs m JOIN go.msgs g ON g.account=m.account AND g.key=m.key"));
    static immutable fields = ["type", "subtype", "body", "caption", "fromMe", "author", "t", "msgId", "remote",
        "from", "to", "notifyName", "isForwarded", "pollName", "title", "loc"];
    size_t[string] miss;
    string[][string] ex;
    size_t cmp;
    foreach (ref r; ours.query("SELECT m.key, m.json, g.json FROM msgs m JOIN go.msgs g ON g.account=m.account AND g.key=m.key")) {
        JSONValue a, b;
        try { a = parseJSON(r.text(1)); b = parseJSON(r.text(2)); } catch (Exception) continue;
        cmp++;
        foreach (k; fields) {
            auto pa = k in a, pb = k in b;
            const sa = pa is null ? "" : pa.toString, sb = pb is null ? "" : pb.toString;
            if (sa != sb) { miss[k]++; if (ex.get(k, null).length < 2) ex[k] ~= r.text(0); }
        }
        auto qa = "quotedMsg" in a, qb = "quotedMsg" in b;
        if ((qa is null) != (qb is null) || (qa !is null && (*qa)["id"].str != (*qb)["id"].str)) miss["quotedMsg.id"]++;
        auto ra = "reactions" in a, rb = "reactions" in b;
        if ((ra is null ? 0 : ra.array.length) != (rb is null ? 0 : rb.array.length)) miss["reactions(count)"]++;
    }
    writefln("compared %d messages", cmp);
    foreach (k, v; miss) writefln("  mismatch %-18s %6d  e.g. %s", k, v, ex.get(k, null));
    // chats: names and flags
    size_t chatsBoth, nameMiss, unreadMiss, archMiss, pinMiss;
    foreach (ref r; ours.query("SELECT c.name, g.name, c.unreadCount, g.unreadCount, c.archive, g.archive, c.pin, g.pin
            FROM chats c JOIN go.chats g ON g.account=c.account AND g.id=c.id")) {
        chatsBoth++;
        if (r.text(0).length && r.text(0) != r.text(1)) nameMiss++;
        if (r.int64(2) != r.int64(3)) unreadMiss++;
        if (r.int64(4) != r.int64(5)) archMiss++;
        if (r.int64(6) != r.int64(7)) pinMiss++;
    }
    writefln("chats in both: %d — name differs %d, unread differs %d, archive differs %d, pin differs %d",
        chatsBoth, nameMiss, unreadMiss, archMiss, pinMiss);
    writefln("events emitted: %d", events);
}

void main(string[] args) {
    if (args.length > 3 && args[1] == "--ingest-check") {
        ingestCheck(args[2], args[3], args.length > 4 ? args[4] : "/tmp/claude-1000/-home-caetano-lab-qml-whats/6a51996a-a4a8-48c3-b05f-bf556e485f9b/scratchpad/ingest");
        return;
    }
    if (args.length > 1 && args[1] == "--group") { groupMode(args[2 .. $]); return; }
    if (args.length > 2 && args[1] == "--model-check") { modelCheck(args[2]); return; }
    auto j = parseJSON(cast(string) stdin.byLineCopy.join("\n"));
    PreKeyBundle b;
    b.registrationId = cast(uint) j["registrationId"].integer;
    b.identityKey = hexN!32(j["identityKey"].str);
    b.signedPreKeyId = cast(uint) j["signedPreKeyId"].integer;
    b.signedPreKey = hexN!32(j["signedPreKey"].str);
    b.signedPreKeySignature = hexN!64(j["signedPreKeySignature"].str);
    b.hasOneTime = j["hasOneTime"].boolean;
    if (b.hasOneTime) {
        b.preKeyId = cast(uint) j["preKeyId"].integer;
        b.preKey = hexN!32(j["preKey"].str);
    }

    auto alice = Device.create();
    auto s = SessionState.initiate(alice, b);

    JSONValue[] msgs;
    foreach (p; j["plaintexts"].array) {
        auto c = s.encrypt(pad(cast(ubyte[]) p.str));
        string hex;
        foreach (x; c.wire) hex ~= format("%02x", x);
        msgs ~= JSONValue(["type": JSONValue(c.type), "serialized": JSONValue(hex)]);
    }
    JSONValue outv = ["messages": JSONValue(msgs)];
    writeln(outv.toString());
}

import std.format : format;
