/// SMS/MMS in qwhats-dcore, through KDE Connect (the kc package) — opt-in: nothing touches the
/// session bus until the app sends Sms.enable (its "SMS pelo KDE Connect" setting), and without
/// kdeconnect installed or a paired phone the rest of the core is unaffected.
///   Sms.enable {on}            → status        Sms.status → status
///   Sms.threads                → [thread]      Sms.messages {thread, count} → [message]
///   Sms.send {thread | addresses, body, files} Sms.attachment {partId, uid} → {path}
/// Events: Sms:status, Sms:thread (a thread's latest message changed), Sms:message (live ones).
module sms;

import std.json;
import std.conv : to;
import core.time : seconds, msecs;
import vibe.core.core : runTask, sleep;
import kc.client;
import kc.contacts;

/// A number as people read it: "+55 11 98765-4321", "(11) 98765-4321"; short codes and
/// alphanumeric senders ("BRADESCO", "29001") as they come.
string phoneLabel(string a) {
    import std.algorithm : any;
    import std.ascii : isAlpha, isDigit;
    import wa.app.chatstore : formatPhone;
    if (a.any!(c => isAlpha(c))) return a;
    char[] d;
    foreach (c; a) if (isDigit(c)) d ~= c;
    const digits = d.idup;
    if (digits.length <= 6) return a;
    if (a.length && a[0] == '+') return formatPhone(digits);
    if (digits.length == 11 || digits.length == 10)   // a local number: (DDD) XXXXX-XXXX
        return "(" ~ digits[0 .. 2] ~ ") " ~ digits[2 .. $ - 4] ~ "-" ~ digits[$ - 4 .. $];
    if (digits.length == 12 || digits.length == 13) return formatPhone(digits);
    return a;
}

unittest {
    assert(phoneLabel("+5511987654321") == "+55 11 98765-4321");
    assert(phoneLabel("5511987654321") == "+55 11 98765-4321");
    assert(phoneLabel("11987654321") == "(11) 98765-4321");
    assert(phoneLabel("1133334444") == "(11) 3333-4444");
    assert(phoneLabel("29001") == "29001");
    assert(phoneLabel("BRADESCO") == "BRADESCO");
}

final class SmsBridge {
    private KdeConnect kc;
    private Contacts contacts;
    private void delegate(string, JSONValue) emit;
    private string cacheDir;
    private string error;
    private long enabledAt;                       // unix ms: messages newer than this are live
    private SmsMessage[int][long] byThread;       // threadID → uID → message
    private bool[long] loadedThreads;
    private string[string] attachments;           // uniqueIdentifier → downloaded path
    private long openThread = -1;                 // the thread whose messages were asked last (being read)
    // KDE Connect has no "mark as read" for the phone (plugins/sms: request, request_conversation(s),
    // request_attachment only): what was read here is kept here — thread → read up to (unix ms)
    private long[long] readUpTo;
    private string readPath;

    this(void delegate(string, JSONValue) emit, string cacheDir, string readPath) {
        this.emit = emit;
        this.cacheDir = cacheDir;
        this.readPath = readPath;
        loadReadMarks();
    }

    private void loadReadMarks() {
        import std.file : exists, readText;
        try {
            if (!exists(readPath)) return;
            foreach (k, v; parseJSON(readText(readPath)).object) readUpTo[k.to!long] = v.integer;
        } catch (Exception) {}
    }

    private void saveReadMarks() {
        import std.file : write, rename, mkdirRecurse;
        import std.path : dirName;
        JSONValue o = JSONValue.emptyObject;
        foreach (k, v; readUpTo) o[k.to!string] = v;
        try {
            mkdirRecurse(readPath.dirName);
            write(readPath ~ ".tmp", o.toString());
            rename(readPath ~ ".tmp", readPath);
        } catch (Exception) {}
    }

    private bool unreadHere(ref const SmsMessage m) {
        if (m.fromMe || m.read) return false;
        auto r = m.threadID in readUpTo;
        return r is null || m.date > *r;
    }

    /// Sms.markRead: everything in the thread up to now counts as read in QWhats
    JSONValue markRead(JSONValue p) {
        needEnabled();
        const id = threadArg(p);
        long upTo = nowMs;
        if (auto t = id in byThread) foreach (m; *t) if (m.date > upTo) upTo = m.date;
        readUpTo[id] = upTo;
        saveReadMarks();
        if (id in byThread) emit("Sms:thread", threadJSON(id));
        return JSONValue(true);
    }

    bool enabled() const { return kc !is null; }

    JSONValue status() {
        JSONValue s = ["enabled": JSONValue(kc !is null)];
        if (kc !is null) {
            s["device"] = kc.deviceName;
            s["reachable"] = kc.reachable;
        }
        if (error.length) s["error"] = error;
        return s;
    }

    JSONValue enable(bool on) {
        if (!on) {
            if (kc !is null) { kc.close(); kc = null; }
            byThread = null;
            loadedThreads = null;
            mmsParts = null;
            attachments = null;
            dirty = null;
            error = null;
            emit("Sms:status", status());
            return status();
        }
        if (kc !is null) return status();
        try {
            kc = new KdeConnect();
        } catch (Exception e) {
            error = e.msg;
            kc = null;
            return status();
        }
        error = null;
        enabledAt = nowMs;
        kc.log = (string m) { import std.stdio : stderr; try stderr.writeln("sms: ", m); catch (Exception) {} };
        kc.onMessage = &onMessage;
        kc.onLoaded = (long id, ulong n) { loadedThreads[id] = true; };
        // a thread deleted on the phone: gone here too (the UI drops it from the SMS list)
        kc.onRemoved = (long id) {
            if (auto t = id in byThread) foreach (u, _; *t) mmsParts.remove("sms:" ~ id.to!string ~ ":" ~ u.to!string);
            byThread.remove(id);
            dirty.remove(id);
            if (openThread == id) openThread = -1;
            emit("Sms:threadRemoved", JSONValue(["id": JSONValue("sms:" ~ id.to!string)]));
        };
        kc.onAttachment = (string path, string uid) { attachments[uid] = path; };
        // never call kc from its own signal dispatch (its calls wait on that dispatch): a task
        kc.onReachable = (bool r) {
            emit("Sms:status", status());
            if (r) runTask(() nothrow { try refresh(); catch (Exception) {} });
        };
        auto k = kc;
        runTask(() nothrow {
            try k.run();
            catch (Exception e) { import std.stdio : stderr; try stderr.writeln("sms: ", e.msg); catch (Exception) {} }
        });
        contacts = new Contacts;
        contacts.load(kc.deviceID);
        foreach (m; kc.activeConversations()) store(m);
        refresh();
        emit("Sms:status", status());
        return status();
    }

    /// Ask the phone for its threads and contacts again (answers arrive as signals)
    private void refresh() {
        // the connection of this moment: SMS may be turned off (kc null) while a call waits
        auto k = kc;
        if (k is null || !k.reachable) return;
        try {
            k.syncContacts();
            if (kc !is k) return;
            k.requestAllConversationThreads();
        } catch (Exception e) {
            if (kc is k) error = e.msg;
            return;
        }
        // the vCards land on disk a little after the request
        runTask(() nothrow {
            try { sleep(5.seconds); if (k !is null && kc is k) contacts.load(k.deviceID); } catch (Exception) {}
        });
    }

    private static long nowMs() {
        import std.datetime.systime : Clock;
        return Clock.currTime.toUnixTime!long * 1000;
    }

    /// at most this many messages per thread in memory (the phone keeps them all; older pages are
    /// asked again when scrolled to): bodies and MMS thumbnails do not pile up over a long session
    enum perThreadCap = 400;

    /// stored: 0 new, 1 changed (type, read, body or parts), 2 unchanged
    private int store(ref SmsMessage m) {
        import std.algorithm : sort;
        auto t = m.threadID in byThread;
        if (t is null) { byThread[m.threadID] = null; t = m.threadID in byThread; }
        int what = 0;
        if (auto old = m.uID in *t)
            what = (old.type != m.type || old.read != m.read || old.body != m.body || old.attachments != m.attachments) ? 1 : 2;
        (*t)[m.uID] = m;
        // the thread being read keeps everything it paged in (pruning it would undo the paging)
        if (m.threadID != openThread && (*t).length > perThreadCap + 50) prune(m.threadID);
        return what;
    }

    /// A thread back to its newest perThreadCap messages (and their MMS parts)
    private void prune(long threadID) {
        import std.algorithm : sort;
        auto t = threadID in byThread;
        if (t is null || (*t).length <= perThreadCap) return;
        auto uids = (*t).keys;
        uids.sort!((a, b) => (*t)[a].date < (*t)[b].date);
        foreach (u; uids[0 .. $ - perThreadCap]) {
            mmsParts.remove("sms:" ~ threadID.to!string ~ ":" ~ u.to!string);
            (*t).remove(u);
        }
    }

    /// Sms.leave: the user went to a WhatsApp chat — the SMS thread read is no longer protected
    void leave() {
        if (openThread >= 0) prune(openThread);
        openThread = -1;
    }

    // a thread's summary goes out once per burst (loading a thread delivers its messages one by one)
    private bool[long] dirty;
    private bool flushing;

    private void touched(long threadID) {
        dirty[threadID] = true;
        if (flushing) return;
        flushing = true;
        runTask(() nothrow {
            try {
                sleep(150.msecs);
                auto ids = dirty.keys;
                dirty = null;
                foreach (id; ids) if (id in byThread) emit("Sms:thread", threadJSON(id));
            } catch (Exception) {}
            flushing = false;
        });
    }

    private void onMessage(SmsMessage m, bool created) {
        const what = store(m);
        touched(m.threadID);
        if (what == 0 && m.date >= enabledAt) emit("Sms:message", messageJSON(m));
        // a message we have that changed (queued → sent/failed, read): the open thread's bubble
        else if (what == 1) emit("Msg:change", messageJSON(m));
    }

    private SmsMessage latest(long threadID) {
        SmsMessage best;
        foreach (m; byThread[threadID]) if (m.date >= best.date) best = m;
        return best;
    }

    // ---- JSON for the app ----------------------------------------------------------------------

    private string nameOf(string address) {
        if (contacts !is null) if (auto n = contacts.name(address)) if (n.length) return n;
        return phoneLabel(address);
    }

    /// The contact's photo saved under the cache (the UI shows files), or null
    private string picOf(string address) {
        import std.file : exists, write, mkdirRecurse;
        import std.path : buildPath;
        if (contacts is null) return null;
        auto c = contacts.find(address);
        if (c is null || !c.photo.length) return null;
        const dir = buildPath(cacheDir, "sms-pics");
        const path = buildPath(dir, numberKey(address) ~ ".jpg");
        try {
            if (!exists(path)) { mkdirRecurse(dir); write(path, c.photo); }
        } catch (Exception) { return null; }
        return path;
    }

    /// A thread as the UI's Chat (kind "sms"), its latest message as lastMsg
    JSONValue threadJSON(long threadID) {
        import std.array : join;
        auto m = latest(threadID);
        string[] names;
        foreach (a; m.addresses) names ~= nameOf(a);
        size_t unread;
        foreach (ref x; byThread[threadID]) if (unreadHere(x)) unread++;
        const id = "sms:" ~ threadID.to!string;
        JSONValue last = [
            "id": JSONValue(msgId(m)),
            "type": JSONValue("chat"),
            "body": JSONValue(m.body.length ? m.body : (m.attachments.length ? "📎 MMS" : "")),
            "fromMe": JSONValue(m.fromMe),
            "ack": JSONValue(ackOf(m)),
            "t": JSONValue(m.date / 1000),
        ];
        JSONValue t = [
            "id": JSONValue(id),
            "kind": JSONValue("sms"),
            "name": JSONValue(names.length ? names.join(", ") : "?"),
            "t": JSONValue(m.date / 1000),
            "unreadCount": JSONValue(unread),
            "markedUnread": JSONValue(false),
            "archive": JSONValue(false),
            "pin": JSONValue(0),
            "muteExpiration": JSONValue(0),
            "isReadOnly": JSONValue(false),
            "lastMsg": last,
            "addresses": JSONValue(m.addresses.length ? m.addresses : []),
            "isGroup": JSONValue(m.isGroup || m.addresses.length > 1),
        ];
        if (m.addresses.length == 1) if (auto p = picOf(m.addresses[0])) t["profilePicThumb"] = p;
        return t;
    }

    private static string msgId(ref const SmsMessage m) {
        return "sms:" ~ m.threadID.to!string ~ ":" ~ m.uID.to!string;
    }

    /// WAWebAck: what the phone says of a message we sent
    private static int ackOf(ref const SmsMessage m) {
        if (!m.fromMe) return 3;
        if (m.type == typeFailed) return -1;
        if (m.type == typeOutbox || m.type == typeQueued) return 0;
        return 1;
    }

    /// A message as the UI's Msg: text ("chat"), or an MMS picture ("image", its thumbnail as the
    /// preview, the full file through downloadMedia)
    JSONValue messageJSON(ref const SmsMessage m) {
        import std.algorithm : startsWith;
        JSONValue j = [
            "id": JSONValue(msgId(m)),
            "remote": JSONValue("sms:" ~ m.threadID.to!string),
            "fromMe": JSONValue(m.fromMe),
            "t": JSONValue(m.date / 1000),
            "type": JSONValue("chat"),
            "ack": JSONValue(ackOf(m)),
            "body": JSONValue(m.body),
        ];
        foreach (ref a; m.attachments) {
            mmsParts[msgId(m)] = a;
            if (a.mimeType.startsWith("image/")) {
                j["type"] = "image";
                if (m.body.length) j["caption"] = m.body;
                JSONValue md = ["mimetype": JSONValue(a.mimeType), "preview": JSONValue(a.base64Thumbnail),
                    "mediaStage": JSONValue("INIT")];
                if (auto have = a.uniqueIdentifier in attachments) {
                    md["renderableUrl"] = *have;
                    md["mediaStage"] = "RESOLVED";
                }
                j["mediaData"] = md;
                break;
            }
        }
        if (j["type"].str == "chat" && m.attachments.length && !m.body.length) j["body"] = "📎 MMS (" ~ m.attachments[0].mimeType ~ ")";
        // in a group, who sent it (the phone lists the sender first among the addresses)
        if (!m.fromMe && m.addresses.length > 1) {
            j["author"] = m.addresses[0];
            j["senderName"] = nameOf(m.addresses[0]);
        }
        return j;
    }

    private SmsAttachment[string] mmsParts;   // message id → its first part

    // ---- requests ------------------------------------------------------------------------------

    private void needEnabled() { if (kc is null) throw new Exception("SMS desativado (Configurações → SMS pelo KDE Connect)"); }

    private static long threadArg(JSONValue p) {
        import std.algorithm : startsWith;
        auto v = "thread" in p;
        if (v is null) throw new Exception("missing thread");
        if (v.type == JSONType.integer) return v.integer;
        string s = v.str;
        if (s.startsWith("sms:")) s = s[4 .. $];
        return s.to!long;
    }

    JSONValue threads() {
        import std.algorithm : sort;
        if (kc is null) return parseJSON("[]");
        JSONValue[] out_;
        foreach (id, _; byThread) out_ ~= threadJSON(id);
        out_.sort!((a, b) => a["t"].integer > b["t"].integer);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// The thread's last `count` messages: asks the phone, waits up to 6 s for them to load
    JSONValue messages(JSONValue p) {
        import std.algorithm : sort;
        needEnabled();
        const id = threadArg(p);
        if (openThread >= 0 && openThread != id) prune(openThread);   // the thread left goes back under the cap
        openThread = id;
        int count = 50;
        if (auto c = "count" in p) if (c.type == JSONType.integer) count = cast(int) c.integer;
        loadedThreads.remove(id);
        if (kc.reachable) {
            kc.requestConversation(id, 0, count);
            foreach (_; 0 .. 60) { if (id in loadedThreads) break; sleep(100.msecs); }
        }
        SmsMessage[] list;
        if (auto t = id in byThread) foreach (m; *t) list ~= m;
        list.sort!((a, b) => a.date < b.date);
        if (list.length > count) list = list[$ - count .. $];
        JSONValue[] out_;
        foreach (ref m; list) out_ ~= messageJSON(m);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// Sms.contacts: who a new message can go to — the phone's contacts (vCards) and every number
    /// with a thread, by name
    JSONValue contactList() {
        import std.algorithm : sort;
        if (kc is null) return parseJSON("[]");
        bool[string] seen;
        JSONValue[] out_;
        void add(string name, string number) {
            // one entry per person: a thread's "11987…" and the contact's "+55 11 987…" are one
            // keyed by the contact's own spelling of this very line (a contact's mobile and landline
            // stay two entries)
            string k = numberKey(number);
            if (auto c = contacts !is null ? contacts.find(number) : null)
                foreach (cn; c.numbers) if (sameLine(numberKey(cn), k)) { k = numberKey(cn); break; }
            if (!k.length || k in seen) return;
            seen[k] = true;
            out_ ~= JSONValue(["name": JSONValue(name), "number": JSONValue(number), "label": JSONValue(phoneLabel(number))]);
        }
        if (contacts !is null) foreach (k, c; contacts.byNumber) foreach (n; c.numbers) if (numberKey(n) == k) { add(c.name, n); break; }
        foreach (id, t; byThread) foreach (m; t) { foreach (a; m.addresses) add(nameOf(a), a); break; }
        out_.sort!((a, b) => a["name"].str < b["name"].str);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    JSONValue send(JSONValue p) {
        needEnabled();
        if (!kc.reachable) throw new Exception("celular fora de alcance (KDE Connect)");
        string body;
        if (auto b = "body" in p) body = b.str;
        string[] files;
        if (auto f = "files" in p) foreach (x; f.array) files ~= x.str;
        if (!body.length && !files.length) throw new Exception("nothing to send");
        if ("thread" in p) kc.reply(threadArg(p), body, files);
        else {
            string[] addrs;
            if (auto a = "addresses" in p) foreach (x; a.array) addrs ~= x.str;
            if (!addrs.length) throw new Exception("missing thread or addresses");
            kc.send(addrs, body, files);
        }
        return JSONValue(true);
    }

    /// downloadMedia for an "sms:" message: the MMS part's full file, as the UI's mediaData
    JSONValue downloadMedia(string msgId) {
        import std.algorithm : findSplit;
        auto a = msgId in mmsParts;
        if (a is null) throw new Exception("no MMS part for " ~ msgId);
        attachment(JSONValue(["partId": JSONValue(a.partID), "uid": JSONValue(a.uniqueIdentifier)]));
        // the whole message again, its picture now a file: to the open thread, and as the answer
        auto parts = msgId["sms:".length .. $].findSplit(":");
        if (auto t = parts[0].to!long in byThread)
            if (auto m = parts[2].to!int in *t) {
                auto j = messageJSON(*m);
                emit("Msg:change", j);
                return j;
            }
        throw new Exception("MMS message not in memory: " ~ msgId);
    }

    /// An MMS part's full file: downloaded by the daemon into its cache (up to 60 s)
    JSONValue attachment(JSONValue p) {
        needEnabled();
        const uid = ("uid" in p) ? p["uid"].str : "";
        long partId;
        if (auto v = "partId" in p) partId = v.integer;
        if (auto have = uid in attachments) return JSONValue(["path": JSONValue(*have)]);
        kc.requestAttachment(partId, uid);
        foreach (_; 0 .. 600) {
            if (auto have = uid in attachments) return JSONValue(["path": JSONValue(*have)]);
            sleep(100.msecs);
        }
        throw new Exception("attachment did not arrive");
    }
}
