/// The live client: login, the stanza loop and everything it answers (receipts, retries, prekeys,
/// keepalive, history, app-state), feeding the UI's chat store through wa.app.ingest — the
/// orchestration of the protocol pieces, as whatsmeow's Client does it. Extracted from wa-probe.
module wa.app.client;

import std.stdio : File, stdout;
import std.json : JSONValue, JSONType, parseJSON;
import vibe.core.core : runTask;
import core.time : Duration;
import wa.binary;
import wa.device;
import wa.socket.frames;
import wa.socket.handshake;
import wa.store.db : Store;
import wa.prekey : uploadPreKeysIQ;
import wa.envelope : parseMessageStanza, signalAddress, IncomingMessage, jidAttr, parseJidString;
import wa.messages : decryptEncFromStore, decryptGroupEncFromStore, processSenderKeyDistributionToStore;
import wa.receipt : ackStanza, messageReceipt;
import wa.proto : ProtoReader, ProtoWriter;
import wa.send : Connection, invalidateDevices, sendPeerMessage, unavailableMessageRequest;
import wa.retry : handleRetryReceipt, RetryState;
import wa.lid : learnFromMessage, lidEncryptionIdentity = encryptionIdentity, storeLIDPNMapping;
import wa.tctoken : isBot, storePrivacyTokens, tokenStorageKey, tcTokenExpired, issuePrivacyTokenIQ;
import wa.message : messageKinds, senderKeyDistribution, conversationText;
import wa.history;
import wa.media : httpGet, mediaURL, mediaConnIQ, parseMediaConnHosts, historyMmsType;
import wa.app.chatstore : ChatStore;
import wa.app.ingest : Ingest;
import wa.groups : GroupInfo, GroupChange;
import wa.appstate_send : PatchInfo, MsgKey;

/// Where the client logs (stdout for wa-probe; qwhats-dcore sends it to stderr, stdout being JSON-RPC).
__gshared File clientLog;
shared static this() { clientLog = stdout; }
private void logf(A...)(string fmt, A a) { try { clientLog.writefln(fmt, a); clientLog.flush(); } catch (Exception) {} }
private void logln(A...)(A a) { try { clientLog.writeln(a); clientLog.flush(); } catch (Exception) {} }

final class Client {
    Store store;
    Device dev;
    ChatStore chats;
    Ingest ingest;
    string account;
    string state = "OPENING";
    int status = 1;          // 0 once a login was accepted (the last attempt)
    bool stopping;
    void delegate(string method, JSONValue params) emit;
    // the live connection (null between connections): what the UI's actions send through
    ClientConn conn;
    NoiseSocket sock;
    string[string] privacy;      // privacy settings, category → value (wa.privacy)
    bool privacyLoaded;
    bool appStateBusy;           // a fetch or a send of app state is running (one at a time)
    bool appStateQueueRunning;
    string cacheDir;             // decrypted media go to <cacheDir>/media
    bool fetchPicturesOnConnect; // qwhats-dcore: fetch missing profile pictures once connected
    // groupCache (whatsmeow getCachedGroupData): members as the server lists them + addressing mode
    struct GroupMembers { string[] members; bool lid; }
    GroupMembers[string] groupCache;
    string[] mediaHosts;         // media_conn hosts, valid until mediaHostsUntil (its ttl)
    long mediaHostsUntil;
    bool mediaHostsFetching;     // one media_conn query at a time (whatsmeow mediaConnLock)
    string mediaAuth;            // media_conn auth (uploads)
    bool[string] authorPicsAsked;   // group senders whose picture we asked for this session
    long[string] historyAsked;      // chat|oldest id → when we last asked the phone for older messages
    JSONValue storeCache;        // WhatsApp's sticker store list, and when it was fetched
    long storeCacheAt;
    // the serve loop's app-state fetch and blob download, for sendAppState
    void delegate(string name, bool fullSync, bool onlyIfNotSynced) syncOneDg;
    ubyte[] delegate(const(ubyte)[] blobRef) blobDg;

    this(Store store, ChatStore chats, string account, void delegate(string, JSONValue) emit) {
        this.store = store;
        this.chats = chats;
        this.account = account;
        this.emit = emit;
        dev = store.loadDevice();
        ingest = new Ingest(chats, store, account, userPart(dev.jid) ~ "@s.whatsapp.net", emit);
    }

    void setState(string s) {
        state = s;
        try emit("Conn:change", JSONValue(["account": JSONValue(account), "state": JSONValue(s)])); catch (Exception) {}
    }

    /// Our own JIDs: phone-number and LID ("…@lid"; empty until the server tells us).
    string me() { return userPart(dev.jid) ~ "@s.whatsapp.net"; }
    string meLid() { return dev.lid.length ? userPart(dev.lid) ~ "@lid" : ""; }

    /// "5511…:3@s.whatsapp.net" → "5511…"; same for the LID ("136…:3@lid" → "136…")
    static string userPart(string j) {
        import std.string : indexOf;
        if (const at = j.indexOf('@')) if (at > 0) j = j[0 .. at];
        if (const colon = j.indexOf(':')) if (colon > 0) j = j[0 .. colon];
        return j;
    }

    /// Log in and serve until a stop outcome (logged out, replaced), reconnecting as whatsmeow does.
    void run() { stopping = false; serveForever(dev, store); }

    /// The phone unlinked us (the Go core's repair): the old device's keys go, and the UI goes back to
    /// the QR (its connect starts pairing).
    void forget() {
        stopping = true;
        try store.wipe(); catch (Exception e) logln("   wipe: ", e.msg);
        dev = Device.init;
        setState("UNPAIRED");
    }

    bool pairing;           // the QR flow is running
    void delegate() onPaired;   // the app's views learn our new JIDs

    /// connect (the Go core's): a paired device is already being served; an unpaired one starts the
    /// QR flow (whatsmeow GetQRChannel): `qr` events with the code and its PNG, rotating as WhatsApp
    /// Web does (60 s, then 20 s per ref); every ref used up → `qr` expired and TIMEOUT.
    void connect() {
        if (dev.paired || pairing) return;
        pairing = true;
        runTask(() nothrow {
            try pairFlow();
            catch (Exception e) {
                logln("pairing: ", e.msg);
                try setState("UNPAIRED"); catch (Exception) {}
            }
            pairing = false;
        });
    }

    private void pairFlow() {
        import vibe.core.core : sleep;
        import core.time : seconds;
        import wa.pairing : pairingQRs, handlePairSuccess;
        auto d = Device.create();
        auto fs = new FrameSocket();
        auto s = handshake(fs, d, WAVersion());
        bool done, closed;
        static void hangUp(NoiseSocket s) nothrow { try s.close(); catch (Exception) {} }
        pairSock = s;
        pairDev = &d;
        linking = null;
        scope (exit) { closed = true; pairSock = null; pairDev = null; pairReady = false; linking = null; hangUp(s); }
        setState("PAIRING");
        logln("pairing: waiting for the server's refs");
        for (;;) {
            auto plain = s.receive();
            if (plain is null) {
                if (!done) {
                    emit("qr", JSONValue(["account": JSONValue(account), "code": JSONValue(""), "expired": JSONValue(true)]));
                    setState("TIMEOUT");
                    logln("pairing: the QR codes ran out");
                }
                return;
            }
            auto n = decodeStanza(plain);
            // the phone-number hello's answer (pairPhone waits for it)
            if (n.tag == "iq" && helloId.length && n.get("id") == helloId) { auto a = new Node; *a = n; helloAnswer = a; continue; }
            // the phone accepted the typed code: finish (whatsmeow handleCodePairNotification)
            if (n.tag == "notification" && n.get("type") == "link_code_companion_reg") {
                auto nack = ackStanza(n);
                s.send(encodeStanza(nack));
                if (linking is null) { logln("pairing: a code notification without a pending code"); continue; }
                import wa.paircode : finishPhoneLinking;
                ubyte[32] adv;
                try {
                    auto fin = finishPhoneLinking(*linking, n, d.identityKey, pairIqId(), adv);
                    d.advSecret = adv;
                    s.send(encodeStanza(fin));
                    logln("pairing: code accepted on the phone — finishing");
                } catch (Exception e) logln("pairing: code finish: ", e.msg);
                continue;
            }
            if (n.tag != "iq" || n.get("type") != "set") continue;
            auto ack = node("iq", [["to", "s.whatsapp.net"], ["type", "result"], ["id", n.get("id")]]);
            ack.attrs[0].value = Value(Jid.pair(null, "s.whatsapp.net"));
            if (const pd = n.child("pair-device")) {
                s.send(encodeStanza(ack));
                auto refs = pairingQRs(d, *pd);
                if (refs.length == 0) throw new Exception("pair-device without refs");
                pairReady = true;
                runTask((string[] refs) nothrow {
                    try {
                        foreach (i, q; refs) {
                            if (done || closed) return;
                            emitQR(q, i == 0 ? 60 : 20);
                            sleep(i == 0 ? 60.seconds : 20.seconds);
                        }
                        // every ref shown: the server is told nothing more, we hang up (whatsmeow's timeout)
                        if (!done && !closed) s.close();
                    } catch (Exception) {}
                }, refs);
                continue;
            }
            if (n.child("pair-success")) {
                auto reply = handlePairSuccess(d, n);
                s.send(encodeStanza(reply));
                // saved BEFORE anything else: without these keys the linked device is orphaned
                store.saveDevice(d);
                if (!store.loadDevice().paired) throw new Exception("the new device was not saved");
                done = true;
                dev = d;
                ingest.me = me();
                if (onPaired !is null) onPaired();
                logln("paired — logging in as the new device");
                emit("paired", JSONValue(["account": JSONValue(account), "id": JSONValue(me())]));
                setState("OPENING");
                // the server answers the sign with <stream:error code=515>: then log in, as whatsmeow
                foreach (_; 0 .. 5) {
                    auto p3 = s.receive();
                    if (p3 is null || decodeStanza(p3).tag == "stream:error") break;
                }
                s.close();
                runTask(() nothrow {
                    try run(); catch (Exception e) { try logln("client: ", e.msg); catch (Exception) {} }
                });
                return;
            }
        }
    }

    import wa.paircode : PhoneLinking;
    NoiseSocket pairSock;       // the pairing connection, while the QR flow runs
    Device* pairDev;
    bool pairReady;             // the server sent its refs: the connection is fully up
    PhoneLinking* linking;      // a phone-number code waiting for the phone
    string helloId;
    Node* helloAnswer;

    private static string pairIqId() {
        import std.digest : toHexString;
        import wa.crypto : randomBytes;
        return "pc." ~ toHexString(randomBytes(6)).idup;
    }

    /// pairPhone (whatsmeow PairPhone, as the Go core calls it): "Link with phone number" — the
    /// 8-character code ("ABCD-EFGH") the phone's user types in. The QR flow carries it (started here
    /// if it is not running); the phone's answer is finished in pairFlow.
    string pairPhone(string phone) {
        import vibe.core.core : sleep;
        import core.time : msecs, seconds, MonoTime;
        import wa.paircode : startPhoneLinking, pairingRef, shownCode;
        if (dev.paired) throw new Exception("already linked");
        connect();
        const ready = MonoTime.currTime + 20.seconds;
        while (!pairReady) {
            if (MonoTime.currTime > ready) throw new Exception("could not reach WhatsApp to link");
            sleep(100.msecs);
        }
        auto pl = new PhoneLinking;
        helloId = pairIqId();
        helloAnswer = null;
        auto s = pairSock;
        if (s is null || pairDev is null) throw new Exception("the linking connection closed");
        auto iq = startPhoneLinking(phone, pairDev.noiseKey.pub, chromeDisplayName, helloId, *pl);
        s.send(encodeStanza(iq));
        const answered = MonoTime.currTime + 20.seconds;
        while (helloAnswer is null) {
            if (MonoTime.currTime > answered || pairSock is null) { helloId = null; throw new Exception("no answer to the phone linking request"); }
            sleep(50.msecs);
        }
        auto r = *helloAnswer;
        helloId = null;
        helloAnswer = null;
        pl.pairingRef = pairingRef(r);
        linking = pl;
        logln("pairing: phone-number code issued");
        return shownCode(pl.code);
    }

    /// what a phone-code pairing shows on the phone (the Go core's chromeName: "<browser> (<os>)")
    enum chromeDisplayName = "Chrome (Linux QWhats)";

    /// a QR code as the UI shows it (the Go core's): a PNG in WhatsApp Web's colours (dark teal, no
    /// quiet zone, high error correction under the logo), a new file per code so the image reloads
    private void emitQR(string code, int timeout) {
        import std.file : dirEntries, SpanMode, remove, mkdirRecurse, write;
        import std.path : buildPath;
        import std.conv : to;
        import std.datetime.systime : Clock;
        import wa.qrsvg : qrSvg;
        mkdirRecurse(cacheDir);
        foreach (e; dirEntries(cacheDir, "qr-" ~ account ~ "-*", SpanMode.shallow)) try remove(e.name); catch (Exception) {}
        string img = buildPath(cacheDir, "qr-" ~ account ~ "-" ~ Clock.currStdTime.to!string(36) ~ ".svg");
        const svg = qrSvg(code);
        if (svg.length) write(img, svg);
        else { logln("   QR: the code could not be encoded"); img = ""; }
        emit("qr", JSONValue(["account": JSONValue(account), "code": JSONValue(code), "image": JSONValue(img),
            "timeout": JSONValue(timeout)]));
    }

    /// Connect as an already-paired device and, on <success>, run the serve loop (pre-keys + active +
    /// stanza handling). Prints only tags and attribute names for the account's own stanzas.
    /// What to do after a connection ends (whatsmeow handleStreamError / handleConnectFailure /
    /// autoReconnect).
    enum Outcome { reconnect, reconnectNow, stop }

    /// <failure reason>: only 500/503 are retried; logged out (401/403/406), temp ban (402), client
    /// outdated (405) and anything else stop.
    Outcome classifyFailure(const ref Node n) {
        const r = n.get("reason");
        if (r == "500" || r == "503") return Outcome.reconnect;
        if (r == "401" || r == "403" || r == "406") { logln("   logged out (", r, ") — this device is gone; pair again"); forget(); }
        else if (r == "402") logln("   TEMPORARY BAN (code ", n.get("code"), ", expires in ", n.get("expire"), " s)");
        else if (r == "405") logln("   client outdated (405)");
        return Outcome.stop;
    }

    /// <stream:error>: 515 → reconnect now; device_removed / replaced → stop; others (503, unknown) →
    /// the normal automatic reconnect.
    Outcome classifyStreamError(const ref Node n) {
        const code = n.get("code");
        const conflict = n.child("conflict");
        const ctype = conflict !is null ? conflict.get("type") : "";
        if (code == "515") return Outcome.reconnectNow;
        if (code == "401" && ctype == "device_removed") { logln("   device removed — pair again"); forget(); return Outcome.stop; }
        if (ctype == "replaced") { logln("   replaced by another connection of this device — not reconnecting"); setState("CONFLICT"); return Outcome.stop; }
        return Outcome.reconnect;
    }

    /// Connect as an already-paired device and, on <success>, run the serve loop. Returns what the
    /// caller should do next.
    Outcome loginAndServe(ref Device dev, Store store) {
        FrameSocket fs;
        NoiseSocket sock;
        try {
            fs = new FrameSocket();
            sock = handshake(fs, dev, WAVersion());
        } catch (Exception e) {
            logln("connect failed: ", e.msg);
            return Outcome.reconnect;
        }
        scope (exit) sock.close();
        logln("noise handshake done (login)");
        foreach (_; 0 .. 5) {
            auto plain = sock.receive();
            if (plain is null) { logln("server closed"); return Outcome.reconnect; }
            auto n = decodeStanza(plain);
            string keys;
            foreach (a; n.attrs) keys ~= " " ~ a.key;
            logf("<- <%s%s> %s", n.tag, keys,
                n.tag == "failure" || n.tag == "stream:error" ? "reason=" ~ n.get("reason") ~ " code=" ~ n.get("code") : "");
            if (n.tag == "success") {
                logln("login accepted");
                status = 0;
                setState("CONNECTED");
                return serveLoop(sock, dev, store, n);
            }
            if (n.tag == "failure") { status = 1; return classifyFailure(n); }
            if (n.tag == "stream:error") { status = 1; return classifyStreamError(n); }
        }
        return Outcome.reconnect;
    }

    /// loginAndServe with whatsmeow's automatic reconnect: 2 s × consecutive errors between tries,
    /// reset by every successful login; stops on a stop outcome.
    void serveForever(ref Device dev, Store store) {
        import vibe.core.core : sleep;
        import core.time : seconds;
        uint errors;
        for (;;) {
            const before = status;
            status = 1;
            // a socket or protocol error escaping the connection is a disconnect: reconnect, never end
            // the loop silently (the UI would keep showing CONNECTED with nothing behind it)
            Outcome o;
            try o = loginAndServe(dev, store);
            catch (Exception e) {
                logf("connection error: %s", e.msg);
                o = Outcome.reconnect;
            } catch (Error e) {
                // a library's assertion (vibe-http's pool once) must not end the client for good: it is
                // logged loudly and retried with the usual growing wait
                logf("connection error (internal, %s): %s", typeid(e).name, e.msg);
                o = Outcome.reconnect;
            }
            if (status == 0) errors = 0;            // that attempt logged in
            if (o == Outcome.stop) { logln("not reconnecting"); return; }
            if (stopping) return;
            setState("OPENING");
            if (o == Outcome.reconnect) {
                logf("reconnecting in %d s", errors * 2);
                sleep((errors * 2).seconds);
                errors++;
            } else logln("reconnecting now (515)");
        }
    }

    /// A minimal live client loop, driven by the user on a secondary account (ToS risk on the primary).
    /// It publishes a batch of pre-keys so peers can start sessions, then acks every routed stanza and
    /// tries to decrypt incoming <message>s — printing ONLY metadata (never chat content), and sending
    /// a delivery receipt on success. This is the orchestration that composes the tested protocol
    /// pieces (prekey IQ, envelope, signal, receipt); it needs a real server, so it is opt-in.
    Outcome serveLoop(NoiseSocket sock, ref Device dev, Store store, const ref Node success) {
        Outcome outcome = Outcome.reconnect;   // a plain disconnect: automatic reconnect
        import std.conv : to;
        import std.string : indexOf;
        import vibe.core.core : runTask, sleep;
        import core.time : seconds, msecs, minutes, MonoTime;
        import std.random : uniform;
        import std.datetime.systime : Clock;
        import wa.signal : OldCounterException;
        import wa.receipt : retryReceipt, RetryKeys;

        auto conn = new ClientConn(sock);
        this.conn = conn;
        this.sock = sock;
        scope (exit) { this.conn = null; this.sock = null; }
        privacyLoaded = false;   // refetched per connection, on first use
        const started = MonoTime.currTime;
        // the UI's store, fed by what arrives (wa.app.ingest)
        import wa.app.ingest : MsgInfo;
        alias chatStore = chats;
        bool closed;
        scope (exit) closed = true;

        // "5511…:3@s.whatsapp.net" → "5511…"; same for the LID ("136…:3@lid" → "136…")
        static string userPart(string j) {
            if (const at = j.indexOf('@')) if (at > 0) j = j[0 .. at];
            if (const colon = j.indexOf(':')) if (colon > 0) j = j[0 .. colon];
            return j;
        }
        // whatsmeow handleConnectSuccess: keep the LID the server tells us when we have none
        if (dev.lid.length == 0 && success.get("lid").length) {
            dev.lid = success.get("lid");
            store.saveDevice(dev);
            logln("   stored our LID from <success>");
        }
        const ownUser = userPart(dev.jid);
        const ownLid = userPart(dev.lid);
        auto ownJid = Jid.pair(ownUser, "s.whatsapp.net");
        // a fresh chat store starts from the history this device already received
        if (chatStore.db.scalarInt("SELECT count(*) FROM msgs") == 0) {
            auto blobs = store.historyPayloads();
            foreach (b; blobs) ingest.storeHistory(b);
            logf("   chat store seeded from %d history blobs: %d chats, %d messages", blobs.length,
                chatStore.db.scalarInt("SELECT count(*) FROM chats"), chatStore.db.scalarInt("SELECT count(*) FROM msgs"));
        }
        if (ownLid.length) store.putLIDMapping(ownLid, ownUser);   // handleConnectSuccess's own pair
        // backfill from history stored by earlier builds: LID mappings and the NCT salt
        if (store.meta("history_backfill_v1") == 0) {
            size_t pairs;
            foreach (payload; store.historyPayloads()) {
                foreach (pl; phoneLidMappings(payload)) { store.putLIDMapping(pl[1], pl[0]); pairs++; }
                if (auto salt = nctSalt(payload)) if (salt.length) store.putBlob("nct_salt", salt);
            }
            store.setMeta("history_backfill_v1", 1);
            logf("   history backfill: %d LID mappings, NCT salt %s", pairs, store.blob("nct_salt").length ? "found" : "absent");
        }

        // an IQ to the server with a whatsmeow-style id ("<b>.<b>-<n>")
        Node serverIQ(string xmlns, string type_, Node[] children = null) {
            auto q = node("iq", [["id", conn.nextId()], ["xmlns", xmlns], ["type", type_], ["to", "s.whatsapp.net"]]);
            q.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
            q.attr("to").isJid = true;
            q.children = children;
            return q;
        }
        static bool iqOK(const ref Node r) { return r.get("type") == "result"; }

        // ── pre-keys (whatsmeow prekeys.go: 812 at first, 50 later, refill under 5, ≥10 min apart) ──
        enum wantedPreKeys = 50, minPreKeys = 5, initialPreKeys = 812;
        bool uploading;
        int serverPreKeyCount() {    // -1 = error (whatsmeow then skips the upload)
            auto r = conn.sendIQ(serverIQ("encrypt", "get", [Node("count")]));
            const c = r.child("count");
            if (!iqOK(r) || c is null) return -1;
            try return c.get("value", "-1").to!int; catch (Exception) return -1;
        }
        void uploadPreKeys(bool initial) {
            if (uploading) return;
            uploading = true;
            scope (exit) uploading = false;
            const last = store.meta("last_prekey_upload");
            if (last && Clock.currTime.toUnixTime - last < 600 && serverPreKeyCount() >= wantedPreKeys) {
                logln("   prekey upload skipped (recent upload, server has enough)");
                return;
            }
            auto keys = store.getOrGenPreKeys(initial ? initialPreKeys : wantedPreKeys);
            auto up = uploadPreKeysIQ(dev, keys, conn.nextId());
            auto r = conn.sendIQ(up, 75.seconds);
            if (!iqOK(r)) { logf("   prekey upload FAILED: %s", r.toString()[0 .. $ > 200 ? 200 : $]); return; }
            store.markPreKeysUploaded(keys[$ - 1].id);
            store.setMeta("last_prekey_upload", Clock.currTime.toUnixTime);
            logf("-> uploaded %d pre-keys (ids %d..%d)", keys.length, keys[0].id, keys[$ - 1].id);
        }

        // ── post-connect, as handleConnectSuccess's goroutine: count → maybe upload → active ──
        runTask(() nothrow {
            // the prekey check may fail on its own; set active is sent regardless (handleConnectSuccess)
            try {
                const db = store.uploadedPreKeyCount();
                const server = serverPreKeyCount();
                logf("   prekeys: %d uploaded in our store, %d on the server", db, server);
                if (server < 0) logln("   prekey count failed — not uploading");
                else if (server < minPreKeys || db < minPreKeys) {
                    uploadPreKeys(db == 0 && server == 0);
                    logf("   prekeys on the server after upload: %d", serverPreKeyCount());
                }
            } catch (Exception e) {
                try logln("   prekey check failed: ", e.msg); catch (Exception) {}
            }
            try {
                auto r = conn.sendIQ(serverIQ("passive", "set", [Node("active")]));
                logln(iqOK(r) ? "-> set active (left passive mode)" : "-> set active FAILED");
            } catch (Exception e) {
                try logln("-> set active failed: ", e.msg); catch (Exception) {}
            }
            // the app (not a background receiver) is "available", as the Go core on Connected
            if (announceAvailable) try sendAvailable(); catch (Exception e) logln("   presence: ", e.msg);
            if (fetchPicturesOnConnect) {
                try fetchPictures(); catch (Exception e) logln("   pictures: ", e.msg);
                try fetchBusinessNames(); catch (Exception e) logln("   business names: ", e.msg);
                try channels(); catch (Exception e) logln("   channels: ", e.msg);
            }
        });

        // ── keepalive (keepalive.go): empty w:p IQ every 20–30 s, 10 s deadline; drop after 3 min ──
        runTask(() nothrow {
            try {
                auto lastOK = MonoTime.currTime;
                while (!closed) {
                    sleep(uniform(20_000, 30_000).msecs);
                    if (closed) break;
                    try {
                        conn.sendIQ(serverIQ("w:p", "get"), 10.seconds);   // any answer counts
                        lastOK = MonoTime.currTime;
                    } catch (Exception e) {
                        logln("   keepalive: ", e.msg);
                    }
                    if (MonoTime.currTime - lastOK > 3.minutes) {
                        logln("   keepalive failing for 3 min — closing the connection");
                        sock.close();
                        break;
                    }
                }
            } catch (Exception) {}
        });

        // protocol receipts (SendProtocolMessageReceipt): <receipt id type to=our own JID>
        void protocolReceipt(string id, string type_) {
            auto r = node("receipt", [["id", id], ["type", type_]]);
            r.attrs ~= Attr("to", Value(ownJid));
            sock.send(encodeStanza(r));
        }

        mediaHosts = null;   // a new connection asks again
        ubyte[] download(string path, const(ubyte)[] enc) { return downloadAs(path, enc, historyMmsType); }
        void storeHistory(string msgId, const ref HistoryNotification hn) {
            auto payload = historySyncPayload(hn, &download);
            const s = summarize(payload);
            store.putHistory(msgId, s.chunkOrder, s.syncType, payload);
            ingest.storeHistory(payload);
            foreach (pl; phoneLidMappings(payload)) store.putLIDMapping(pl[1], pl[0]);
            if (auto salt = nctSalt(payload)) if (salt.length) store.putBlob("nct_salt", salt);
            logf("   history %s chunk %d (%d%%): %d conversations, %d messages, %d push names, %d statuses",
                syncTypeName(s.syncType), s.chunkOrder, s.progress, s.conversations, s.messages, s.pushnames, s.statuses);
        }

        // ── app-state sync (fetchAppState): snapshot on the first sync, then patches ──
        struct AppStateJob { string name; bool onlyIfNotSynced; }
        AppStateJob[] appStateQueue;
        ubyte[] appStateBlob(const(ubyte)[] refBytes) {
            import sv = wa.pb.serversync;
            import wa.media : decryptMedia;
            auto r = ProtoReader(refBytes);
            alias E = sv.ExternalBlobReference;
            auto file = downloadAs(cast(string) r.get(E.directPath).bytes.idup, r.get(E.fileEncSHA256).bytes, "md-app-state");
            return decryptMedia(file, r.get(E.mediaKey).bytes, "WhatsApp App State Keys", r.get(E.fileEncSHA256).bytes,
                r.get(E.fileSHA256).bytes);
        }
        // requestMissingAppStateKeys: each key id asked of the phone at most once per 24 h (persisted)
        string keyMetaName(const(ubyte)[] id) { import std.digest : toHexString; return "appstate_keyreq_" ~ toHexString(id).idup; }
        void requestKeys(ubyte[][] ids) {
            static import wa.appstate;
            import std.datetime.systime : Clock;
            const now = Clock.currTime.toUnixTime;
            ubyte[][] ask;
            foreach (id; ids) if (now - store.meta(keyMetaName(id)) >= 24 * 3600) ask ~= id.dup;
            if (ask.length == 0) { logln("   app-state keys already requested in the last 24 h"); return; }
            logf("   asking the phone for %d app-state key(s)", ask.length);
            // marked before sending (as whatsmeow does): a timeout must not re-ask within 24 h, and a
            // key share that beats the ack must be recognised as requested
            foreach (id; ask) store.setMeta(keyMetaName(id), now);
            try {
                sendPeerMessage(conn, store, dev, wa.appstate.appStateKeyRequest(ask));
            } catch (Exception e2) logln("   key request failed: ", e2.msg);
        }
        bool isMismatch(Exception e) {
            import std.algorithm : canFind;
            return e.msg.canFind("LTHash mismatch") || e.msg.canFind("patch MAC mismatch");
        }
        void syncAppStateOne(string name, bool fullSync, bool onlyIfNotSynced) {
            import wa.appstate;
            if (fullSync) store.deleteAppStateVersion(name);
            HashState st;
            st.ver = store.appStateVersion(name, st.hash);
            if (st.ver == 0) fullSync = true;
            else if (onlyIfNotSynced) return;
            bool wantSnapshot = fullSync, hasMore = true;
            auto dec = Decoder(store);
            size_t total;
            while (hasMore) {
                auto r = conn.sendIQ(syncIQ(name, st.ver, wantSnapshot, conn.nextId()));
                const syncN = r.child("sync");
                const coll = syncN !is null ? syncN.child("collection") : null;
                if (coll is null) { logf("   app-state %s: no <collection> in the reply (%s)", name, r.get("type")); return; }
                auto list = parsePatchList(*coll, &appStateBlob);
                if (!wantSnapshot && list.snapshot.length) { logf("   app-state %s: unexpected snapshot", name); return; }
                wantSnapshot = false;
                hasMore = list.hasMore;
                Mutation[] muts;
                try muts = dec.decodePatches(list, st, (const(Mutation)[] unit) { ingest.onAppState(unit); });
                catch (AppStateKeyMissing e) {
                    logf("   app-state %s: missing key", name);
                    auto ids = missingKeyIds(store, list);
                    requestKeys(ids.length ? ids : e.keyIds);
                    return;
                }
                catch (AppStateException e) {
                    // fetchAppState: a hash/patch MAC mismatch on an incremental sync retries once from the
                    // snapshot; never an APP_STATE_FATAL_EXCEPTION (that logs every device out)
                    if (!fullSync && isMismatch(e)) {
                        logf("   app-state %s: %s — one full resync", name, e.msg);
                        syncAppStateOne(name, true, false);
                        return;
                    }
                    throw e;
                }
                total += muts.length;
            }
            logf("   app-state %s synced to v%d (%d mutations)", name, st.ver, total);
        }
        syncOneDg = &syncAppStateOne;
        blobDg = &appStateBlob;
        void syncAppState(string[] names, bool onlyIfNotSynced) {
            foreach (nm; names) appStateQueue ~= AppStateJob(nm, onlyIfNotSynced);
            if (appStateQueueRunning) return;
            appStateQueueRunning = true;
            runTask(() nothrow {
                try {
                    scope (exit) appStateQueueRunning = false;
                    while (appStateQueue.length) {
                        const job = appStateQueue[0];
                        appStateQueue = appStateQueue[1 .. $];
                        const name = job.name;
                        // one fetch or send at a time (a send waits for this, and this for a send)
                        while (appStateBusy) sleep(50.msecs);
                        appStateBusy = true;
                        scope (exit) appStateBusy = false;
                        try syncAppStateOne(name, false, job.onlyIfNotSynced);
                        catch (Exception e) logf("   app-state %s FAILED: %s", name, e.msg);
                    }
                } catch (Exception) {}
            });
        }

        // community parents from the history already received (read since this build): once
        if (store.meta("group_parent_backfill_v1") == 0) {
            store.setMeta("group_parent_backfill_v1", 1);
            size_t n;
            foreach (payload; store.historyPayloads()) {
                import hs = wa.pb.historysync;
                foreach (f; ProtoReader(payload)) if (f.number == hs.HistorySync.conversations) {
                    auto conv = ProtoReader(f.bytes);
                    const parent = cast(string) conv.get(hs.Conversation.parentGroupID).bytes.idup;
                    if (parent.length) {
                        chats.setGroupParent(account, cast(string) conv.get(hs.Conversation.ID).bytes.idup, parent);
                        n++;
                    }
                }
            }
            logf("   community parents from history: %d", n);
        }
        // our own name lives in critical_block's setting_pushName, read only since this build: one full
        // resync of that small collection (once)
        if (store.meta("appstate_pushname_v1") == 0 && store.appStateKeyCount() > 0) {
            store.setMeta("appstate_pushname_v1", 1);
            runTask(() nothrow {
                try {
                    while (appStateBusy) sleep(50.msecs);
                    appStateBusy = true;
                    scope (exit) appStateBusy = false;
                    syncAppStateOne("critical_block", true, false);
                } catch (Exception e) { try logln("   critical_block resync: ", e.msg); catch (Exception) {} }
            });
        }
        // collections never synced although we hold the keys (keys shared before this build): sync once
        {
            import wa.appstate : allPatchNames;
            bool pending;
            foreach (nm; allPatchNames) { ubyte[128] h; if (store.appStateVersion(nm, h) == 0) pending = true; }
            // only collections still at v0 (synced ones rely on server_sync notifications), and at most
            // every 6 h: a failed attempt is retried on a later login instead of being given up
            import std.datetime.systime : Clock;
            const now = Clock.currTime.toUnixTime;
            if (pending && store.appStateKeyCount() > 0 && now - store.meta("appstate_login_sync") >= 6 * 3600) {
                store.setMeta("appstate_login_sync", now);
                syncAppState(allPatchNames.dup, true);
            }
        }

        // handleProtocolMessage: only for our own messages; hist_sync receipt per history notification,
        // peer_msg receipt for category=peer
        void handleProtocol(string msgId, const(ubyte)[] proto, bool categoryPeer, ushort senderDevice) {
            auto p = protocolMessage(proto);
            if (p is null) return;
            // the phone's answer to a placeholder resend (an <unavailable> message we asked it for):
            // each result carries the message as a WebMessageInfo (handlePlaceholderResendResponse)
            if (senderDevice == 0) {
                static import wa.pb.e2e, wa.pb.web, wa.pb.common;
                alias PR = wa.pb.e2e.PeerDataOperationRequestResponseMessage;
                auto pr = ProtoReader(ProtoReader(p).get(wa.pb.e2e.ProtocolMessage.peerDataOperationRequestResponseMessage).bytes);
                if (pr.get(PR.peerDataOperationRequestType).value == wa.pb.e2e.PeerDataOperationRequestType.PLACEHOLDER_MESSAGE_RESEND)
                    foreach (f; pr) if (f.number == PR.peerDataOperationResult) {
                        const wmb = ProtoReader(ProtoReader(f.bytes).get(PR.PeerDataOperationResult.placeholderMessageResendResponse).bytes)
                            .get(PR.PeerDataOperationResult.PlaceholderMessageResendResponse.webMessageInfoBytes).bytes;
                        if (wmb.length == 0) { logln("   placeholder resend: empty result"); continue; }
                        try {
                            import wa.envelope : parseJidString;
                            const remote = cast(string) ProtoReader(ProtoReader(wmb).get(wa.pb.web.WebMessageInfo.key).bytes)
                                .get(wa.pb.common.MessageKey.remoteJID).bytes.idup;
                            MsgInfo mi;
                            const(ubyte)[] message, raw;
                            JSONValue m;
                            if (ingest.parseWebMessage(parseJidString(remote), wmb, mi, message, raw)
                                && ingest.onMessage(mi, message, raw, false, m))
                                logf("   placeholder resend: recovered %s (%s)", mi.id, m["type"].str);
                        } catch (Exception e) logln("   placeholder resend failed: ", e.msg);
                    }
            }
            if (hasHistoryNotification(p)) {
                auto hn = parseHistoryNotification(p);
                auto raw = historyNotificationBytes(p).dup;
                runTask(() nothrow {
                    try {
                        try storeHistory(msgId, hn);
                        catch (Exception e) {
                            logf("   history failed (%s) — queued", e.msg);
                            store.putPendingHistory(msgId, raw);
                        }
                    } catch (Exception) {}
                });
                protocolReceipt(msgId, "hist_sync");
            }
            if (auto keys = parseAppStateKeyShare(p)) {
                // handleAppStateSyncKeyShare: a key we asked for → resync everything, else only unsynced
                bool requested;
                foreach (ref k; keys) {
                    store.putAppStateKey(k.id, k.data, k.timestamp, k.fingerprint);
                    if (store.meta(keyMetaName(k.id)) > 0) requested = true;
                }
                logf("   stored %d app-state keys (total %d)%s", keys.length, store.appStateKeyCount(),
                    requested ? " — requested ones" : "");
                import wa.appstate : allPatchNames;
                syncAppState(allPatchNames.dup, !requested);
            }
            if (categoryPeer) protocolReceipt(msgId, "peer_msg");
        }

        RetryState retryState;   // incoming retry bookkeeping (handleRetryReceipt)

        // retry receipts (sendRetryReceipt): per-id counter, give up at 5, keys from the 2nd try or
        // when a group sender key is missing
        int[string] messageRetries;
        void sendRetry(const ref Node n, const ref IncomingMessage info, bool forceKeys) {
            int inMsg;
            if (n.children.length == 1 && n.children[0].tag == "enc")
                try inMsg = n.children[0].get("count", "0").to!int; catch (Exception) {}
            auto cnt = ++messageRetries[info.id];
            if (cnt == 1 && inMsg > 0) { cnt = inMsg + 1; messageRetries[info.id] = cnt; }
            if (cnt >= 5) { logln("   no more retry receipts for ", info.id); return; }
            const peer = info.type_ == "peer_msg" && info.source.isFromMe;
            if (cnt > 1 || forceKeys) {
                if (dev.account.length == 0) {
                    // whatsmeow always has Store.Account here; without it we can't send the same <keys>
                    logln("   retry receipt WITHOUT keys: this device has no stored account identity (re-pair)");
                    auto r = retryReceipt(n, cnt, dev.registrationId, peer);
                    sock.send(encodeStanza(r));
                    return;
                }
                auto one = store.genOnePreKey();
                RetryKeys k;
                k.identityPub = dev.identityKey.pub;
                k.oneTimeId = one.id;
                k.oneTimePub = one.key.pub;
                k.signedId = dev.signedPreKey.id;
                k.signedPub = dev.signedPreKey.key.pub;
                k.signedSig = dev.signedPreKey.signature;
                k.account = dev.account;
                auto r = retryReceipt(n, cnt, dev.registrationId, peer, &k);
                sock.send(encodeStanza(r));
            } else {
                auto r = retryReceipt(n, cnt, dev.registrationId, peer);
                sock.send(encodeStanza(r));
            }
            logf("-> retry receipt #%d for %s", cnt, info.id);
        }

        // a decrypted payload parses as a protobuf (whatsmeow's proto.Unmarshal check → nack 491)
        static bool validProto(const(ubyte)[] b) {
            try { foreach (f; ProtoReader(b)) {} return true; } catch (Exception) return false;
        }

        // ── a <message>, as whatsmeow's handleEncryptedMessage / decryptMessages ──
        void handleMessage(const ref Node n) {
            auto info = parseMessageStanza(n, ownUser, ownLid);
            logf("<- message id=%s from=%s:%s type=%s group=%s fromMe=%s encs=%d",
                info.id, info.source.sender.user.maskTail, info.source.sender.device,
                info.type_, info.source.isGroup, info.source.isFromMe, info.encs.length);
            if (n.child("unavailable") !is null && info.encs.length == 0) {
                // ask our phone for it (immediateRequestMessageFromPhone), then ack
                logf("   unavailable (%s) — requesting it from the phone", n.child("unavailable").get("type"));
                auto un = n;
                auto chatS = info.source.chat.toString();
                auto senderJ = info.source.sender;
                auto mid = info.id;
                runTask(() nothrow {
                    try {
                        try sendPeerMessage(conn, store, dev, unavailableMessageRequest(chatS, senderJ, mid, ownUser, ownLid));
                        catch (Exception e) logln("   phone request failed: ", e.msg);
                        auto a = ackStanza(un);
                        sock.send(encodeStanza(a));
                    } catch (Exception) {}
                });
                return;
            }
            // LID bookkeeping (handleEncryptedMessage / decryptMessages' encryption identity)
            learnFromMessage(store, info);
            const senderAddr = signalAddress(lidEncryptionIdentity(store, info));
            const chatJid = info.source.chat.toString();
            bool recognized, protobufFailed, containsDirect;
            foreach (ref enc; info.encs) {
                recognized = true;
                const t = enc.get("type");
                if (t.length == 0) continue;
                ubyte[] proto;
                try {
                    if (t == "pkmsg" || t == "msg") {
                        containsDirect = true;
                        proto = decryptEncFromStore(store, dev, senderAddr, enc);
                    } else if (t == "skmsg" && info.source.isGroup) {
                        proto = decryptGroupEncFromStore(store, chatJid, senderAddr, enc);
                    } else if (t == "msmsg" && isBot(info.source.sender)) {
                        throw new Exception("bot message secret not supported");
                    } else {
                        logf("   %s: unhandled enc type", t);
                        continue;
                    }
                } catch (OldCounterException e) {
                    logf("   %s: %s — skipped", t, e.msg);
                    continue;
                } catch (Exception e) {
                    logf("   decrypt %s failed: %s", t, e.msg);
                    if (t == "msmsg") {
                        auto a = ackStanza(n, 495);           // NackMissingMessageSecret
                        sock.send(encodeStanza(a));
                    } else {
                        const missingSenderKey = t == "skmsg" && !containsDirect
                            && e.msg.indexOf("no sender key") >= 0;
                        sendRetry(n, info, missingSenderKey);
                        auto a = ackStanza(n);
                        sock.send(encodeStanza(a));
                    }
                    return;                                   // stop at the first failure
                }
                if (!validProto(proto)) { protobufFailed = true; continue; }
                protobufFailed = false;
                logf("   decrypted %s: %d bytes → %s", t, proto.length, messageKinds(proto));
                if (!(info.source.isFromMe && protocolMessage(proto) !is null))
                    store.putMessage(chatJid, info.id, senderAddr, info.timestamp, info.source.isFromMe, proto);
                if (const text = conversationText(proto)) if (text.length)
                    logf("   text: %s", text);
                string gid;
                const(ubyte)[] axolotl;
                if (info.source.isGroup && senderKeyDistribution(proto, gid, axolotl)) {
                    processSenderKeyDistributionToStore(store, chatJid, senderAddr, axolotl);
                    logln("   stored the sender's group key");
                }
                if (info.source.isFromMe) handleProtocol(info.id, proto, n.get("category") == "peer", info.source.sender.device);
                // the UI's store (wa.app.ingest)
                try {
                    MsgInfo mi;
                    mi.chat = info.source.chat;
                    mi.sender = info.source.sender;
                    mi.senderAlt = info.source.senderAlt;
                    mi.recipientAlt = info.source.recipientAlt;
                    mi.isFromMe = info.source.isFromMe;
                    mi.isGroup = info.source.isGroup;
                    mi.id = info.id;
                    mi.pushName = info.pushName;
                    mi.verifiedName = info.verifiedName;
                    mi.t = info.timestamp;
                    JSONValue storedMsg;
                    if (ingest.onMessage(mi, proto, proto, false, storedMsg))
                        logf("   → chat store: %s", storedMsg["type"].str);
                } catch (Exception e) logln("   chat store: ", e.msg);
            }
            if (!recognized) {
                auto a = ackStanza(n, 488);                  // NackUnrecognizedStanza
                sock.send(encodeStanza(a));
            } else if (protobufFailed) {
                auto a = ackStanza(n, 491);                  // NackInvalidProtobuf
                sock.send(encodeStanza(a));
            } else {
                // sendMessageReceipt: own → sender/peer_msg; others → inactive (no presence sent)
                const rtype = info.source.isFromMe ? (info.type_ == "peer_msg" ? "peer_msg" : "sender") : "inactive";
                auto r = messageReceipt(n, rtype);
                sock.send(encodeStanza(r));
            }
        }

        // ── notifications we act on; all are acked by the caller ──
        void handleNotification(const ref Node n) {
            const type = n.get("type");
            if (type == "server_sync") {
                // handleAppStateNotification: refetch each named collection
                string[] names;
                foreach (ref c; n.children) if (c.tag == "collection" && c.get("name").length) names ~= c.get("name");
                logf("<- server_sync: %s", names);
                syncAppState(names, false);
                return;
            }
            if (type == "w:gp2") {
                // a group changed (members, settings): its cached member list goes
                auto from = jidAttr(n, "from");
                groupCache.remove(Jid.pair(from.user, from.server).toString());
                import wa.groups : parseGroupChange;
                try onGroupChange(parseGroupChange(n));
                catch (Exception e) logln("   group notification: ", e.msg);
                return;
            }
            if (type == "account_sync") {
                // handleAccountSyncNotification: <privacy> changes apply over the cached settings
                foreach (ref c; n.children) {
                    if (c.tag == "privacy" && privacyLoaded) {
                        import wa.privacy : applyPrivacy;
                        applyPrivacy(c, privacy);
                        logln("<- privacy settings changed");
                    } else if (c.tag == "devices") {
                        // our own device list changed (handleOwnDevicesNotification): drop it from the
                        // cache, both sides; the next send asks again
                        invalidateDevices(ownUser ~ "@s.whatsapp.net");
                        if (ownLid.length) invalidateDevices(ownLid ~ "@lid");
                        logln("<- our devices changed — cache dropped");
                    }
                }
                return;
            }
            if (type == "mediaretry") {
                try onMediaRetry(n); catch (Exception e) logln("   media retry: ", e.msg);
                return;
            }
            if (type == "privacy_token") {
                logf("<- privacy token(s) stored: %d", storePrivacyTokens(store, n));
                return;
            }
            if (type == "devices") {
                // a contact's device list changed: drop its cached list (and learn its LID pair)
                auto from = jidAttr(n, "from");
                if (n.attr("lid") !is null) {
                    auto l = jidAttr(n, "lid");
                    storeLIDPNMapping(store, l, from);
                    invalidateDevices(Jid.pair(l.user, l.server).toString());
                }
                invalidateDevices(Jid.pair(from.user, from.server).toString());
                logf("<- devices changed for %s — cache dropped", from.user.maskTail);
                return;
            }
            if (type != "encrypt") { logf("<- notification %s", type); return; }
            auto from = jidAttr(n, "from");
            if (from.user.length == 0 && from.server == "s.whatsapp.net") {
                if (const c = n.child("count")) {
                    const left = c.get("value", "-1").to!int;
                    logf("<- encrypt notification: %d one-time prekeys left on the server", left);
                    if (left >= 0 && left < minPreKeys)
                        runTask(() nothrow { try uploadPreKeys(false); catch (Exception) {} });
                }
            } else if (n.child("identity") !is null) {
                store.deleteAllSessionsOf(from.user);
                // our sessions live under the LID: drop that side too
                const other = from.server == "lid" ? store.pnForLID(from.user) : store.lidForPN(from.user);
                if (other.length) store.deleteAllSessionsOf(other);
                logf("<- identity change for %s — dropped its sessions/identities", from.user.maskTail);
                // re-issue our privacy token if we had issued one inside the window
                const key = tokenStorageKey(store, from);
                const sts = store.privacySenderTS(key);
                if (sts && !tcTokenExpired(sts, Clock.currTime.toUnixTime))
                    runTask(() nothrow {
                        try conn.sendIQ(issuePrivacyTokenIQ(parseJidString(key), sts, conn.nextId()));
                        catch (Exception) {}
                    });
            }
        }

        foreach (_; 0 .. 1_000_000) {
            auto plain = sock.receive();
            if (plain is null) {
                logf("server closed after %s s", (MonoTime.currTime - started).total!"seconds");
                return outcome;
            }
            auto n = decodeStanza(plain);
            switch (n.tag) {
                case "message":
                    handleMessage(n);
                    break;
                case "ack":
                    // the server's answer to something we sent (our reply: class=message, maybe error)
                    if (n.get("id") in conn.waiting) conn.results[n.get("id")] = n;
                    if (n.get("class") == "message")
                        logf("<- ack class=message id=%s%s%s", n.get("id"),
                            n.attr("error") ? " ERROR=" ~ n.get("error") : "",
                            n.attr("phash") ? " phash=" ~ n.get("phash") : "");
                    break;
                case "receipt":
                    if (n.get("type") == "retry") {
                        // re-encrypt and resend for that device, then ack (whatsmeow tryHandleRetryReceipt)
                        auto rn = n;
                        runTask(() nothrow {
                            try {
                                try logf("<- retry receipt for %s: %s", rn.get("id"),
                                    handleRetryReceipt(conn, store, dev, rn, retryState, Clock.currTime.toUnixTime));
                                catch (Exception e) logf("<- retry receipt for %s FAILED: %s", rn.get("id"), e.msg);
                                auto ra = ackStanza(rn);
                                sock.send(encodeStanza(ra));
                            } catch (Exception) {}
                        });
                        break;
                    }
                    try ingest.onReceipt(n, [ownUser, ownLid]); catch (Exception e) logln("   receipt ingest: ", e.msg);
                    auto rack = ackStanza(n);
                    sock.send(encodeStanza(rack));
                    break;
                case "notification":
                    handleNotification(n);
                    auto nack_ = ackStanza(n);
                    sock.send(encodeStanza(nack_));
                    break;
                case "status":
                    auto sack = ackStanza(n);
                    sock.send(encodeStanza(sack));
                    break;
                case "presence":   // whatsmeow handlePresence (not acked)
                    try onPresence(n); catch (Exception e) logln("   presence: ", e.msg);
                    break;
                case "chatstate":  // whatsmeow handleChatState (not acked)
                    try onChatState(n); catch (Exception e) logln("   chatstate: ", e.msg);
                    break;
                case "call":
                    auto cack = ackStanza(n);
                    sock.send(encodeStanza(cack));
                    logln("<- call (acked)");
                    break;
                case "iq":
                    if (n.get("id") in conn.waiting) { conn.results[n.get("id")] = n; break; }
                    if (n.get("type") == "get" && (n.get("xmlns") == "urn:xmpp:ping" || n.child("ping"))) {
                        auto pong = node("iq", [["id", n.get("id")], ["type", "result"], ["to", "s.whatsapp.net"]]);
                        pong.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
                        pong.attr("to").isJid = true;
                        sock.send(encodeStanza(pong));
                    }
                    break;
                case "stream:error", "failure":
                    logf("<- %s code=%s reason=%s %s", n.tag, n.get("code"), n.get("reason"),
                        n.children.length ? "<" ~ n.children[0].tag ~ " type=" ~ n.children[0].get("type") ~ ">" : "");
                    outcome = n.tag == "failure" ? classifyFailure(n) : classifyStreamError(n);
                    break;
                default:
                    logf("<- <%s> (ignored)", n.tag);
                    break;
            }
        }
        return outcome;
    }

    // ── actions the UI asks for (each mirrors whatsmeow; checked before going live) ─────────────

    /// The privacy settings, fetched once per connection (TryFetchPrivacySettings).
    bool loadPrivacy() {
        if (privacyLoaded) return true;
        if (conn is null) return false;
        import wa.privacy : privacyIQ, applyPrivacy;
        auto r = conn.sendIQ(privacyIQ(conn.nextId()));
        const p = r.child("privacy");
        if (r.get("type") != "result" || p is null) return false;
        string[string] s;
        applyPrivacy(*p, s);
        privacy = s;
        privacyLoaded = true;
        return true;
    }

    /// sendSeen (WAWebChatSeenBridge / the Go core's sendSeen): read receipts for the chat's unread
    /// incoming messages — grouped by sender in groups, at most 256 ids per receipt — then the chat's
    /// unread count is cleared. Nothing is sent when nothing is unread. Read receipts turned off (or
    /// a channel) → read-self, as whatsmeow MarkRead; settings that cannot be read → nothing sent.
    void sendSeen(string chatId) {
        import std.algorithm : canFind, min, max;
        import std.datetime.systime : Clock;
        import wa.receipt : readReceipt;
        import wa.privacy : readReceiptsOff;
        if (conn is null) throw new Exception("not connected");
        JSONValue c;
        if (!chats.chat(account, chatId, c)) throw new Exception("no chat " ~ chatId);
        const unread = c["unreadCount"].integer;
        const marked = ("markedUnread" in c) && c["markedUnread"].type == JSONType.true_;
        if (unread <= 0) {
            if (marked) markChatRead(chatId, true);
            return;
        }
        if (!loadPrivacy()) throw new Exception("privacy settings unavailable — not sending read receipts");
        auto chat = parseJidString(chatId);
        const readSelf = readReceiptsOff(privacy) || chat.server == "newsletter";
        static immutable skip = ["gp2", "e2e_notification", "call_log", "notification_template", "ciphertext"];
        string[][string] bySender;
        string[] order;
        foreach (m; chats.msgs(account, chatId, 0, cast(int) min(unread + 20, 500))) {
            if (m["fromMe"].type == JSONType.true_ || skip.canFind(m["type"].str)) continue;
            string sender;
            if (chat.server == "g.us" && ("author" in m)) sender = m["author"].str;
            if (sender !in bySender) order ~= sender;
            bySender[sender] ~= m["msgId"].str;
        }
        const t = Clock.currTime.toUnixTime;
        size_t sent;
        foreach (sender; order) {
            auto ids = bySender[sender];
            if (ids.length > unread) ids = ids[$ - cast(size_t) unread .. $];
            while (ids.length) {   // WhatsApp Web sends at most 256 ids per receipt
                const k = min(ids.length, 256);
                auto r = readReceipt(ids[0 .. k], chat, sender.length ? parseJidString(sender) : Jid.init, t, readSelf);
                sock.send(encodeStanza(r));
                sent += k;
                ids = ids[k .. $];
            }
        }
        logf("-> %s receipts for %d message(s) in %s", readSelf ? "read-self" : "read", sent, chatId.maskTail);
        chats.setChat(account, chatId, "unreadCount", 0L);
        chats.setChat(account, chatId, "unreadMentionCount", 0L);
        if (marked) markChatRead(chatId, true);
        ingest.emitChat(chatId);
    }

    /// sendAppState (whatsmeow): our patch on top of the stored version; a 409 conflict applies the
    /// server's newer patches from the answer and retries once; then the collection is fetched (our
    /// own patch comes back and is applied like any other).
    void sendAppState(const ref PatchInfo info) {
        import vibe.core.core : sleep;
        import core.time : msecs, seconds;
        import std.datetime.systime : Clock;
        import wa.appstate;
        import wa.appstate_send : encodePatch, sendPatchIQ;
        if (conn is null) throw new Exception("not connected");
        while (appStateBusy) sleep(50.msecs);
        appStateBusy = true;
        scope (exit) appStateBusy = false;
        foreach (attempt; 0 .. 2) {
            HashState st;
            st.ver = store.appStateVersion(info.name, st.hash);
            if (st.ver == 0) throw new Exception("app state " ~ info.name ~ " was never synced");
            const from = st.ver;
            const nowMs = (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000;   // Unix ms
            auto patch = encodePatch(store, info, st, nowMs);
            auto r = conn.sendIQ(sendPatchIQ(info.name, from, patch, conn.nextId()), 30.seconds);
            const syncN = r.child("sync");
            const coll = syncN !is null ? syncN.child("collection") : null;
            if (coll is null) throw new Exception("app state send: no <collection> in the answer (" ~ r.get("type") ~ ")");
            if (coll.get("type") == "error") {
                const err = coll.child("error");
                if (err !is null && err.get("code") == "409" && attempt == 0) {
                    logf("   app-state %s: conflict (409) — applying the newer patches, then retrying", info.name);
                    auto list = parsePatchList(*coll, blobDg);
                    HashState cur;
                    cur.ver = store.appStateVersion(info.name, cur.hash);
                    Decoder(store).decodePatches(list, cur, (const(Mutation)[] unit) { ingest.onAppState(unit); });
                    continue;
                }
                throw new Exception("app state update failed (" ~ info.name ~ "): " ~ (err !is null ? err.get("code") ~ " " ~ err.get("text") : "error"));
            }
            logf("-> app-state %s: patch v%d accepted", info.name, st.ver);
            syncOneDg(info.name, false, false);
            // the fetch must have brought our patch back: otherwise the next send would build on a
            // version the server already has
            ubyte[128] h;
            if (store.appStateVersion(info.name, h) < st.ver)
                throw new Exception("app state " ~ info.name ~ ": sent, but the fetch did not bring it back");
            return;
        }
    }

/// trySendAppState: the change to the phone and the other devices; false (logged) when it could
    /// not go — the action still holds here (see sendStatusMute: an account whose regular_high copy on
    /// the server is inconsistent takes no patches there)
    bool trySendAppState(const ref PatchInfo info, string what) {
        try { sendAppState(info); return true; }
        catch (Exception e) { logf("   %s kept on this device only: %s", what, e.msg); return false; }
    }

/// The media hosts (refreshMediaConn: kept for the answer's ttl).
    string[] hosts() {
        import std.datetime.systime : Clock;
        import std.conv : to;
        import vibe.core.core : sleep;
        import core.time : msecs;
        // concurrent downloads wait for the one query in flight instead of each asking
        while (mediaHostsFetching) sleep(20.msecs);
        const now = Clock.currTime.toUnixTime;
        if (mediaHosts.length && now < mediaHostsUntil) return mediaHosts;
        if (conn is null) throw new Exception("not connected");
        mediaHostsFetching = true;
        scope (exit) mediaHostsFetching = false;
        auto r = conn.sendIQ(mediaConnIQ(conn.nextId()));
        auto got = parseMediaConnHosts(r);
        if (const mc = r.child("media_conn")) mediaAuth = mc.get("auth");
        if (got.length == 0) throw new Exception("media_conn: no hosts in the answer");
        mediaHosts = got;
        long ttl = 300;
        if (const mc = r.child("media_conn")) try ttl = mc.get("ttl", "300").to!long; catch (Exception) {}
        mediaHostsUntil = now + ttl;
        logf("<- media hosts: %d (ttl %d s)", mediaHosts.length, ttl);
        return mediaHosts;
    }

    /// DownloadMediaWithPath: each host in turn; a 403/404/410 (expired or gone) ends the attempt.
    ubyte[] downloadAs(string path, const(ubyte)[] enc, string mmsType) {
        import std.algorithm : canFind;
        if (path.length == 0 || path[0] != '/') throw new Exception("media download path does not start with slash");
        Exception last;
        foreach (h; hosts()) {
            try return httpGet(mediaURL(h, path, enc, mmsType));
            catch (Exception e) {
                logf("   download via %s failed: %s", h, e.msg);
                if (e.msg.canFind("HTTP 403") || e.msg.canFind("HTTP 404") || e.msg.canFind("HTTP 410")) throw e;
                last = e;
            }
        }
        throw last !is null ? last : new Exception("no media hosts");
    }

    /// downloadMedia (WhatsApp Web's download manager / the Go core's): the message's media,
    /// decrypted and verified, into the cache; the stored message gets renderableUrl + RESOLVED.
    /// Expired media (403/404/410, or a hash that no longer matches) → ERROR_MISSING for now (asking
    /// the sender's phone to upload it again is a send, not done yet).
    JSONValue downloadMedia(string key) {
        import std.file : exists, write, mkdirRecurse;
        import std.path : buildPath, extension;
        import std.digest.sha : sha256Of;
        import std.digest : toHexString, LetterCase;
        import std.algorithm : canFind;
        import std.string : toLower, indexOf;
        import wa.model : unwrap;
        import wa.media : decryptMedia;
        import e2e = wa.pb.e2e;
        JSONValue m;
        ubyte[] raw;
        if (!chats.msg(account, key, m, raw)) throw new Exception("no message " ~ key);
        if ("mediaData" !in m) throw new Exception("no media in this message");
        if (auto u = "renderableUrl" in m["mediaData"]) if (u.str.length && exists(u.str)) return ingest.handOut(m);
        if (raw.length == 0) throw new Exception("the original message is not stored");
        auto mr = mediaRef(raw);
        const appInfo = mr.appInfo, mms = mr.mms;
        const mediaKey = mr.mediaKey, encSha = mr.encSha, sha = mr.sha;
        // a path the sender's phone gave us after a media retry wins over the message's own
        string path = mr.path;
        if (auto dp = "retryPath" in m["mediaData"]) if (dp.str.length) path = dp.str;
        if (path.length == 0) throw new Exception("no URL present");

        const stageBefore = ("mediaStage" in m["mediaData"]) ? m["mediaData"]["mediaStage"].str : "INIT";
        m["mediaData"]["mediaStage"] = "FETCHING";
        emit("Msg:change", ingest.handOut(m));
        ubyte[] data;
        try {
            auto file = downloadAs(path, encSha, mms);
            if (encSha.length == 0) {
                // unencrypted (channel media; whatsmeow drops the key when there is no encrypted
                // hash): only the plain hash is checked
                import std.digest.sha : sha256Of;
                if (sha.length && (sha.length != 32 || sha256Of(file)[] != sha))
                    throw new Exception("unencrypted media SHA-256 mismatch");
                data = file;
            } else {
                // downloadAndDecrypt: the plain SHA-256 must be there and match
                if (sha.length != 32) throw new Exception("decrypted media SHA-256 mismatch (no hash)");
                data = decryptMedia(file, mediaKey, appInfo, encSha, sha);
            }
        } catch (Exception e) {
            logf("   download %s: %s", m["type"].str, e.msg);
            // gone from the servers (expired, or the hash no longer matches): missing; anything else
            // (network, no hosts) leaves it as it was, to be asked again
            const gone = e.msg.canFind("HTTP 403") || e.msg.canFind("HTTP 404") || e.msg.canFind("HTTP 410")
                || e.msg.canFind("SHA-256 mismatch") || e.msg.canFind("HMAC mismatch");
            // the message as it is now (edited, revoked, reacted to while we waited): only its media stage changes
            JSONValue cur;
            ubyte[] curRaw;
            // gone: the sender's phone is asked to upload it again (once per message and session);
            // its answer (a mediaretry notification) brings a new path and downloads it
            if (gone && mediaKey.length && key !in poked && conn !is null && chats.msg(account, key, cur, curRaw)
                    && "mediaData" in cur) {
                try {
                    sendMediaRetry(key, mediaKey);
                    poked[key] = true;
                    cur["mediaData"]["mediaStage"] = "NEED_POKE";
                    chats.updateMsg(cur);
                    auto out_ = ingest.handOut(cur);
                    emit("Msg:change", out_);
                    return out_;
                } catch (Exception pe) logf("   media retry request: %s", pe.msg);
            }
            if (chats.msg(account, key, cur, curRaw) && "mediaData" in cur) {
                cur["mediaData"]["mediaStage"] = gone ? "ERROR_MISSING" : stageBefore;
                if (gone) chats.updateMsg(cur);
                emit("Msg:change", ingest.handOut(cur));
            }
            throw e;
        }
        // mediaPath: <cache>/media/<sha256(account+key)[:12] hex><extension>
        const dir = buildPath(cacheDir, "media");
        mkdirRecurse(dir);
        string ext;
        if (auto fn = "filename" in m["mediaData"]) ext = extension(fn.str);
        if (ext.length == 0) if (auto mt = "mimetype" in m["mediaData"]) {
            auto t = mt.str;
            if (const semi = t.indexOf(';')) if (semi > 0) t = t[0 .. semi];
            static immutable string[string] exts = ["image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp",
                "image/gif": ".gif", "video/mp4": ".mp4", "video/3gpp": ".3gp", "audio/ogg": ".ogg", "audio/mpeg": ".mp3",
                "audio/mp4": ".m4a", "audio/aac": ".aac", "application/pdf": ".pdf"];
            if (auto e = t.toLower in exts) ext = *e;
        }
        auto digest = sha256Of(account ~ key);
        const file = buildPath(dir, toHexString!(LetterCase.lower)(digest[0 .. 12]).idup ~ ext);
        // the message as it is now: revoked or gone while the file came — nothing to show, nothing
        // written over it; else only its media fields change (edits/reactions meanwhile are kept)
        JSONValue cur;
        ubyte[] curRaw;
        if (!chats.msg(account, key, cur, curRaw)) throw new Exception("the message is gone: " ~ key);
        if ("mediaData" !in cur || cur["type"].str == "revoked") throw new Exception("the message no longer has this media");
        write(file, data);
        cur["mediaData"]["renderableUrl"] = file;
        cur["mediaData"]["mediaStage"] = "RESOLVED";
        chats.updateMsg(cur);
        auto out_ = ingest.handOut(cur);
        emit("Msg:change", out_);
        logf("<- media %s: %d bytes", m["type"].str, data.length);
        return out_;
    }

/// A message's media part and its keys (whatsmeow DownloadAny: the first media part; a sticker
    /// uses the image keys).
    private struct MediaRef {
        string appInfo, mms, path;
        const(ubyte)[] mediaKey, encSha, sha;
    }
    private static MediaRef mediaRef(const(ubyte)[] raw) {
        import wa.model : unwrap;
        import e2e = wa.pb.e2e;
        bool vo;
        auto inner = ProtoReader(unwrap(raw, vo));
        MediaRef r;
        ubyte[] part;
        uint fPath, fKey, fEnc, fSha;
        if (inner.has(e2e.Message.imageMessage)) {
            part = inner.get(e2e.Message.imageMessage).bytes.dup; r.appInfo = "WhatsApp Image Keys"; r.mms = "image";
            fPath = e2e.ImageMessage.directPath; fKey = e2e.ImageMessage.mediaKey; fEnc = e2e.ImageMessage.fileEncSHA256; fSha = e2e.ImageMessage.fileSHA256;
        } else if (inner.has(e2e.Message.videoMessage)) {
            part = inner.get(e2e.Message.videoMessage).bytes.dup; r.appInfo = "WhatsApp Video Keys"; r.mms = "video";
            fPath = e2e.VideoMessage.directPath; fKey = e2e.VideoMessage.mediaKey; fEnc = e2e.VideoMessage.fileEncSHA256; fSha = e2e.VideoMessage.fileSHA256;
        } else if (inner.has(e2e.Message.audioMessage)) {
            part = inner.get(e2e.Message.audioMessage).bytes.dup; r.appInfo = "WhatsApp Audio Keys"; r.mms = "audio";
            fPath = e2e.AudioMessage.directPath; fKey = e2e.AudioMessage.mediaKey; fEnc = e2e.AudioMessage.fileEncSHA256; fSha = e2e.AudioMessage.fileSHA256;
        } else if (inner.has(e2e.Message.documentMessage)) {
            part = inner.get(e2e.Message.documentMessage).bytes.dup; r.appInfo = "WhatsApp Document Keys"; r.mms = "document";
            fPath = e2e.DocumentMessage.directPath; fKey = e2e.DocumentMessage.mediaKey; fEnc = e2e.DocumentMessage.fileEncSHA256; fSha = e2e.DocumentMessage.fileSHA256;
        } else if (inner.has(e2e.Message.stickerMessage)) {
            part = inner.get(e2e.Message.stickerMessage).bytes.dup; r.appInfo = "WhatsApp Image Keys"; r.mms = "image";
            fPath = e2e.StickerMessage.directPath; fKey = e2e.StickerMessage.mediaKey; fEnc = e2e.StickerMessage.fileEncSHA256; fSha = e2e.StickerMessage.fileSHA256;
        } else throw new Exception("nothing downloadable in this message");
        auto pr = ProtoReader(part);
        r.path = cast(string) pr.get(fPath).bytes.idup;
        r.mediaKey = pr.get(fKey).bytes.dup;
        r.encSha = pr.get(fEnc).bytes.dup;
        r.sha = pr.get(fSha).bytes.dup;
        return r;
    }

    bool[string] poked;   // messages whose media we asked the sender's phone for (this session)

    /// SendMediaRetryReceipt for a stored message
    private void sendMediaRetry(string key, const(ubyte)[] mediaKey) {
        import wa.mediaretry : mediaRetryReceipt;
        auto t = target(key);
        auto r = mediaRetryReceipt(t.msgId, mediaKey, Jid.pair(userPart(dev.jid), "s.whatsapp.net"), parseJidString(t.chat),
            t.fromMe, parseJidString(t.sender));
        sock.send(encodeStanza(r));
        logf("-> media retry asked (%s)", t.chat.maskTail);
    }

    /// onMediaRetry (the Go core's): the sender's phone uploaded the media again — the new path is
    /// kept beside the message and the file downloaded now; a phone that no longer has it: missing.
    void onMediaRetry(const ref Node n) {
        import wa.mediaretry : parseMediaRetry, decryptMediaRetry;
        auto e = parseMediaRetry(n);
        const remote = e.chat.server == "broadcast" || e.chat.server == "g.us" ? e.chat.toString() : ingest.canonical(e.chat);
        JSONValue m;
        if (!chats.msgByID(account, remote, e.msgId, m)) { logf("<- media retry for an unknown message"); return; }
        const key = m["id"].str;
        JSONValue cur;
        ubyte[] raw;
        if (!chats.msg(account, key, cur, raw) || "mediaData" !in cur || raw.length == 0) return;
        string path;
        try path = decryptMediaRetry(e, mediaRef(raw).mediaKey);
        catch (Exception ex) {
            logf("<- media retry: %s", ex.msg);
            cur["mediaData"]["mediaStage"] = "ERROR_MISSING";
            chats.updateMsg(cur);
            emit("Msg:change", ingest.handOut(cur));
            return;
        }
        cur["mediaData"]["retryPath"] = path;
        chats.updateMsg(cur);
        logf("<- media uploaded again: downloading");
        runTask((string key) nothrow {
            try downloadMedia(key); catch (Exception ex) { try logf("   download after retry: %s", ex.msg); catch (Exception) {} }
        }, cast(string) key.idup);
    }

/// requestProfilePicFromServer (the Go core's): the preview picture into <cache>/pics; "-" marks
    /// "none" when the server says unchanged-and-nothing. A picture already on disk is not asked again.
    JSONValue requestProfilePic(string id) {
        import std.file : exists, write, mkdirRecurse;
        import std.path : buildPath;
        import std.array : replace;
        import std.datetime.systime : Clock;
        import wa.profile : profilePictureIQ, parseProfilePicture, PictureResult;
        import wa.tctoken : currentTCToken;
        auto c = chats.contact(account, id);
        const pic = ("profilePicThumb" in c) ? c["profilePicThumb"].str : "";
        if (pic == "-" || (pic.length && exists(pic))) return c;
        if (conn is null) throw new Exception("not connected");
        auto j = parseJidString(id);
        const tok = currentTCToken(store, j, Clock.currTime.toUnixTime);
        auto r = conn.sendIQ(profilePictureIQ(j, true, tok, conn.nextId()));
        string url, picId;
        final switch (parseProfilePicture(r, url, picId)) {
            case PictureResult.unchanged:
                chats.setContact(account, id, "pic", "-");
                return chats.contact(account, id);
            case PictureResult.notSet: throw new Exception("profile picture not set");
            case PictureResult.unauthorized: throw new Exception("profile picture hidden from us");
            case PictureResult.error: throw new Exception("profile picture query failed");
            case PictureResult.found: break;
        }
        auto data = httpGet(url);   // a plain CDN link: profile pictures are not encrypted
        const dir = buildPath(cacheDir, "pics");
        mkdirRecurse(dir);
        const file = buildPath(dir, id.replace("@", "_").replace(":", "_") ~ "-" ~ picId ~ ".jpg");
        write(file, data);
        chats.setContact(account, id, "pic", file);
        auto out_ = chats.contact(account, id);
        emit("Contact:change", out_);
        return out_;
    }

/// sendTextMsgToChat (WAWebSendTextMsgChatAction / the Go core's): text, optionally replying to
    /// a stored message (quoted = its key) and mentioning; extendedTextMessage when there is any
    /// context (reply, mentions, disappearing timer), else conversation. Stored first at ack CLOCK,
    /// SENT (with the server's time) once the server acks it, FAILED if not. 1:1 chats only for now.
    JSONValue sendText(string chatId, string text, string quoted, string[] mentions) {
        import std.datetime.systime : Clock;
        import wa.proto : ProtoWriter;
        import wa.model : content, envelope, unwrap;
        import wa.send : sendDM, newMessageId;
        import e2e = wa.pb.e2e;
        if (conn is null) throw new Exception("not connected");
        auto chat = parseJidString(chatId);
        if (chat.server != "s.whatsapp.net" && chat.server != "lid" && chat.server != "g.us")
            throw new Exception("qwhats-dcore: sending to " ~ chat.server ~ " chats is not implemented yet");
        {
            import wa.app.views : isBotJID;
            if (isBotJID(chatId)) throw new Exception("qwhats-dcore: sending to bots is not implemented yet");
        }
        auto ci = ProtoWriter();
        bool useCI;
        if (quoted.length) {
            JSONValue q;
            ubyte[] qraw;
            if (!chats.msg(account, quoted, q, qraw)) throw new Exception("no message " ~ quoted);
            ci.str(e2e.ContextInfo.stanzaID, q["msgId"].str);
            // the quoted message's sender: us (without device), its group author, or the chat
            string participant;
            if (q["fromMe"].type == JSONType.true_) participant = me();
            else if ("author" in q) participant = q["author"].str;
            else participant = q["remote"].str;
            ci.str(e2e.ContextInfo.participant, participant);
            if (qraw.length) {
                bool vo;
                ci.bytes(e2e.ContextInfo.quotedMessage, unwrap(qraw, vo));
            }
            useCI = true;
        }
        foreach (mj; mentions) { ci.str(e2e.ContextInfo.mentionedJID, mj); useCI = true; }
        JSONValue c;
        if (chats.chat(account, chatId, c) && ("ephemeralDuration" in c) && c["ephemeralDuration"].integer > 0) {
            ci.varint(e2e.ContextInfo.expiration, cast(ulong) c["ephemeralDuration"].integer);
            useCI = true;
        }
        ubyte[] msg = useCI
            ? ProtoWriter().bytes(e2e.Message.extendedTextMessage,
                ProtoWriter().str(e2e.ExtendedTextMessage.text, text).bytes(e2e.ExtendedTextMessage.contextInfo, ci.buf).buf).buf
            : ProtoWriter().str(e2e.Message.conversation, text).buf;

        return deliver(chatId, msg);
    }

/// fetchPictures (the Go core's, on connect): ours, then each chat's without one yet — one at a
    /// time, 300 ms apart, while connected; channels are skipped (their metadata has the picture).
    /// "none" and "hidden from us" are remembered as "-" so they are not asked again.
    void fetchPictures() {
        import vibe.core.core : sleep;
        import core.time : msecs;
        import std.algorithm : canFind;
        bool hasPic(string id) {
            auto c = chats.contact(account, id);
            return ("profilePicThumb" in c) && c["profilePicThumb"].str.length;
        }
        void one(string id, bool again) {
            if (again) chats.setContact(account, id, "pic", "");
            bool none;
            try {
                auto c = requestProfilePic(id);
                none = ("profilePicThumb" in c) && c["profilePicThumb"].str == "-";
            } catch (Exception e) {
                if (e.msg.canFind("not set") || e.msg.canFind("hidden")) none = true;
                else {
                    logf("   picture %s: %s", id.maskTail, e.msg);
                    if (again) chats.setContact(account, id, "pic", "-");
                    return;
                }
            }
            if (!none) return;
            chats.setContact(account, id, "pic", "-");
            // a community's group without a picture of its own shows the community's (WhatsApp Web)
            import std.algorithm : endsWith;
            if (id.endsWith("@g.us")) {
                JSONValue g;
                if (!chats.group(account, id, g)) try g = sendQueryGroup(id); catch (Exception e) logf("   group info: %s", e.msg);
                string parent = (g.type == JSONType.object && ("parentGroup" in g)) ? g["parentGroup"].str : "";
                if (parent.length == 0) parent = chats.groupParent(account, id);   // history knows it even when we left
                if (parent.length) {
                    const p = communityPic(parent);
                    if (p.length) chats.setContact(account, id, "pic", p);
                }
            }
        }
        if (!hasPic(me())) one(me(), false);
        size_t n;
        foreach (c; chats.chats(account)) {
            if (conn is null) return;
            const id = c["id"].str;
            if (c["kind"].str == "newsletter") continue;
            // a group marked "none" is asked again once a session: the mark may come from a failure
            const pic = ("profilePicThumb" in chats.contact(account, id)) ? chats.contact(account, id)["profilePicThumb"].str : "";
            const retryGroup = pic == "-" && c["kind"].str == "group";
            if (hasPic(id) && !retryGroup) continue;
            // only the chats the list shows (fewer queries than the Go core, which asks for all)
            if (ingest.chatView !is null && ingest.chatListed !is null && !ingest.chatListed(ingest.chatView(c))) continue;
            one(id, retryGroup);
            ingest.emitChat(id);
            n++;
            sleep(300.msecs);
        }
        logf("   pictures: asked for %d chat(s)", n);
    }

/// sendStatusSeen (WAWebStatusSeen / the Go core's): the author's read receipt for one status
    /// update — marked seen here first; read-self when our read receipts are off; nothing sent when
    /// the privacy settings cannot be read.
    void sendStatusSeen(string key) {
        import std.datetime.systime : Clock;
        import wa.receipt : readReceipt;
        import wa.privacy : readReceiptsOff;
        JSONValue m;
        ubyte[] raw;
        if (!chats.msg(account, key, m, raw)) throw new Exception("unknown status");
        chats.markStatusSeen(account, key);
        if (conn is null) throw new Exception("not connected");
        const author = ("author" in m) ? m["author"].str : "";
        if (author.length == 0) throw new Exception("status without an author");
        if (!loadPrivacy()) throw new Exception("privacy settings unavailable — not sending the status receipt");
        auto r = readReceipt([m["msgId"].str], parseJidString("status@broadcast"), parseJidString(author),
            Clock.currTime.toUnixTime, readReceiptsOff(privacy));
        sock.send(encodeStanza(r));
        logf("-> status seen (%s)", r.get("type"));
    }

/// sendQueryGroup (the Go core's): the group's metadata from the server, stored (with its
    /// members' PN↔LID pairs, as whatsmeow's cacheGroupInfo) and announced.
    JSONValue sendQueryGroup(string id) {
        import wa.groups : groupInfoIQ, parseGroupNode;
        if (conn is null) throw new Exception("not connected");
        auto r = conn.sendIQ(groupInfoIQ(parseJidString(id), conn.nextId()));
        if (r.get("type") == "error") {
            const e = r.child("error");
            const code = e !is null ? e.get("code") : "";
            // not in it any more: no writing there (as WhatsApp shows a group we left)
            if (code == "403") { chats.setChat(account, id, "isReadOnly", true); ingest.emitChat(id); }
            throw new Exception(code == "404" ? "group not found" : code == "403" ? "not in the group" : "group query failed " ~ code);
        }
        const gn = r.child("group");
        if (gn is null) throw new Exception("no <group> in the answer");
        return storeGroup(parseGroupNode(*gn));
    }

    /// a group's metadata (a query's answer, or the <create> of a group we were added to): stored
    /// with its members' PN↔LID pairs (whatsmeow cacheGroupInfo), and announced
    JSONValue storeGroup(GroupInfo gi) {
        import wa.lid : storeLIDPNMapping;
        const id = gi.jid.toString();
        foreach (ref p; gi.participants)
            if (p.lid.user.length && p.phoneNumber.user.length) storeLIDPNMapping(store, p.lid, p.phoneNumber);
        {
            GroupMembers gm;
            foreach (ref p; gi.participants) gm.members ~= Jid.pair(p.jid.user, p.jid.server).toString();
            gm.lid = gi.addressingMode == "lid";
            groupCache[id] = gm;
        }
        // groupFrom
        JSONValue[] ps;
        foreach (ref p; gi.participants) {
            const pid = ingest.canonical(p.phoneNumber.user.length ? p.phoneNumber : p.jid);
            ps ~= JSONValue(["id": JSONValue(pid), "isAdmin": JSONValue(p.isAdmin), "isSuperAdmin": JSONValue(p.isSuperAdmin)]);
        }
        JSONValue g = ["id": JSONValue(gi.jid.toString()), "account": JSONValue(account), "subject": JSONValue(gi.name),
            "restrict": JSONValue(gi.isLocked), "announce": JSONValue(gi.isAnnounce),
            "ephemeralDuration": JSONValue(gi.isEphemeral ? cast(long) gi.disappearingTimer : 0L),
            "size": JSONValue(cast(long) ps.length), "isParentGroup": JSONValue(gi.isParent),
            "participants": ps.length ? JSONValue(ps) : parseJSON("[]")];
        if (gi.nameSetAt) g["subjectTime"] = gi.nameSetAt;
        if (gi.topic.length) g["desc"] = gi.topic;
        if (gi.owner.user.length) g["owner"] = ingest.canonical(gi.owner);
        if (gi.created) g["creation"] = gi.created;
        if (gi.linkedParent.user.length) g["parentGroup"] = gi.linkedParent.toString();
        chats.putGroup(g);
        // whether we are in it now (the history's readOnly may be from before we came back)
        {
            bool inGroup;
            foreach (ref p; gi.participants) {
                const u = p.phoneNumber.user.length ? p.phoneNumber.user : p.jid.user;
                if (u == userPart(dev.jid) || (dev.lid.length && (p.jid.user == userPart(dev.lid) || p.lid.user == userPart(dev.lid))))
                    inGroup = true;
            }
            if (gi.participants.length) chats.setChat(account, id, "isReadOnly", !inGroup);
        }
        emit("GroupMetadata:change", g);
        ingest.emitChat(id);
        return g;
    }


    // ── presence: online / last seen and typing / recording (the UI's Presence:change) ───────────

    private struct Pres {
        bool online, deny;
        long t;
        string[] typing, recording;
    }
    private Pres[string] presence;          // by chat (or person)
    bool announceAvailable;                 // the app: <presence available> on connect (a background receiver: no)
    private ulong[string] chatStateSeq;     // chat|who → the composing it last heard
    private ulong chatStateCounter;

    private JSONValue presJSON(string id) {
        auto p = presence[id];
        JSONValue[] ty, rec;
        foreach (x; p.typing) ty ~= JSONValue(x);
        foreach (x; p.recording) rec ~= JSONValue(x);
        JSONValue j = ["id": JSONValue(id), "account": JSONValue(account), "isOnline": JSONValue(p.online),
            "typingUserIds": ty.length ? JSONValue(ty) : parseJSON("[]"), "recordingUserIds": rec.length ? JSONValue(rec) : parseJSON("[]")];
        if (p.t) j["t"] = p.t;
        if (p.deny) j["deny"] = true;
        return j;
    }

    private static string[] without(string[] l, string x) {
        string[] o;
        foreach (v; l) if (v != x) o ~= v;
        return o;
    }

    /// <presence from type="unavailable"? last>: online, or offline with a last-seen time ("deny":
    /// hidden by their privacy) — the Go core's events.Presence
    private void onPresence(ref const Node n) {
        import std.conv : to;
        const id = ingest.canonical(parseJidString(n.get("from")));
        if (id !in presence) presence[id] = Pres.init;
        auto p = &presence[id];
        const unavailable = n.get("type") == "unavailable";
        p.online = !unavailable;
        const last = n.get("last");
        long lastT;
        if (last.length && last != "deny") { try lastT = last.to!long; catch (Exception) {} }
        if (lastT) p.t = lastT;
        p.deny = unavailable && lastT == 0;
        emit("Presence:change", presJSON(id));
    }

    /// <chatstate from participant?><composing media="audio"?/> | <paused/></chatstate>: typing or
    /// recording in a chat (onChatPresence); a composing not heard again in 25 s ends by itself
    private void onChatState(ref const Node n) {
        import vibe.core.core : runTask, sleep;
        import core.time : seconds;
        if (n.children.length != 1) return;
        auto from = parseJidString(n.get("from"));
        const chat = ingest.canonical(from);
        const who = from.server == "g.us" && n.get("participant").length ? ingest.canonical(parseJidString(n.get("participant"))) : chat;
        if (chat !in presence) presence[chat] = Pres.init;
        auto p = &presence[chat];
        p.typing = without(p.typing, who);
        p.recording = without(p.recording, who);
        const st = n.children[0];
        if (st.tag == "composing") {
            if (st.get("media") == "audio") p.recording ~= who; else p.typing ~= who;
            ulong seq = ++chatStateCounter;
            string k = chat ~ "|" ~ who, chatS = chat, whoS = who;
            chatStateSeq[k] = seq;
            runTask((string chat, string who, string k, ulong seq) nothrow {
                try {
                    sleep(25.seconds);
                    if (chatStateSeq.get(k, 0) != seq) return;
                    if (auto q = chat in presence) {
                        q.typing = without(q.typing, who);
                        q.recording = without(q.recording, who);
                        emit("Presence:change", presJSON(chat));
                    }
                } catch (Exception) {}
            }, chatS, whoS, k, seq);
        }
        emit("Presence:change", presJSON(chat));
    }

    /// SubscribePresence (whatsmeow): <presence type="subscribe" to> with the privacy token when we
    /// have a fresh one (without one, whatsmeow subscribes anyway)
    void subscribePresence(string id) {
        import wa.tctoken : currentTCToken;
        import std.datetime.systime : Clock;
        auto c = conn;
        if (c is null) throw new Exception("not connected");
        auto j = parseJidString(id);
        auto req = node("presence", [["type", "subscribe"], ["to", id]]);
        req.attr("to").jid = Jid.pair(j.user, j.server);
        req.attr("to").isJid = true;
        const tok = currentTCToken(store, j, Clock.currTime.toUnixTime);
        if (tok.length) {
            Node t = Node("tctoken");
            t.bytes = tok.idup;
            t.hasBytes = true;
            req.children ~= t;
        }
        c.sendNode(req);
    }

    /// SendPresence available (the Go core does it on connect): without it the server sends us no one's
    /// presence. whatsmeow needs the push name for it.
    private void sendAvailable() {
        auto c = conn;
        if (c is null) return;
        auto me_ = chats.contact(account, me());
        const name = me_.type == JSONType.object && ("pushname" in me_) && me_["pushname"].type == JSONType.string
            ? me_["pushname"].str : "";
        if (!name.length) { logln("   presence: no push name yet, not announced"); return; }
        c.sendNode(node("presence", [["type", "available"], ["name", name]]));
        logln("-> presence available");
    }

    // ── the message menu's actions (the Go core's actions.go / extras.go) ─────────────────────────

    /// The message an action is about (the Go core's target): its chat and who sent it — us (our own
    /// JID, no device), the author in a group, else the chat itself.
    private struct Target {
        JSONValue m;
        string chat, sender, msgId;
        bool fromMe;
        long t;
    }

    private Target target(string key) {
        Target t;
        ubyte[] raw;
        if (!chats.msg(account, key, t.m, raw)) throw new Exception("no message " ~ key);
        t.chat = t.m["remote"].str;
        t.msgId = t.m["msgId"].str;
        t.fromMe = ("fromMe" in t.m) && t.m["fromMe"].type == JSONType.true_;
        t.t = ("t" in t.m) ? t.m["t"].integer : 0;
        if (t.fromMe) t.sender = userPart(dev.jid) ~ "@s.whatsapp.net";
        else if (("author" in t.m) && t.m["author"].str.length) t.sender = t.m["author"].str;
        else t.sender = t.chat;
        return t;
    }

    /// BuildMessageKey (whatsmeow): ours unless the sender is someone else; the participant (no
    /// device) only for someone else's message outside 1:1 chats
    private ubyte[] messageKey(ref const Target t) {
        static import wa.actions;
        return wa.actions.messageKey(t.chat, t.sender, t.msgId, userPart(dev.jid), dev.lid.length ? userPart(dev.lid) : "");
    }

    /// A protocol message (reaction, revoke, edit, pin) sent as it is — no chat message stored for it
    private void sendRaw(string chatId, const(ubyte)[] msg) {
        import wa.send : sendDM, sendGroup, newMessageId, SendReport;
        auto c = conn;
        if (c is null) throw new Exception("not connected");
        auto chat = parseJidString(chatId);
        const id = newMessageId(userPart(dev.jid));
        if (chat.server == "g.us") {
            if (chatId !in groupCache) sendQueryGroup(chatId);
            auto gm = groupCache[chatId];
            auto rep = sendGroup(c, store, dev, chat, gm.members, gm.lid, msg, id);
            if (rep.serverPHash.length && rep.serverPHash != rep.phash) groupCache.remove(chatId);
        } else sendDM(c, store, dev, chat, msg, null, id);
    }

    private static long nowMs() {
        import std.datetime.systime : Clock;
        return Clock.currStdTime / 10_000 - 62_135_596_800_000L;
    }

    /// sendReactionToMsg (WAWebSendReactionMsgAction; BuildReaction): "" takes the reaction back
    void sendReaction(string key, string text) {
        import e2e = wa.pb.e2e;
        import wa.model : Addon;
        static import wa.actions;
        auto t = target(key);
        const ms = nowMs;
        const msg = wa.actions.reactionMessage(messageKey(t), text, ms);
        if (t.chat == "status@broadcast") {
            // someone's status: pairwise to the author's devices and ours (WAWebSendStatusReactionAction)
            import wa.send : sendStatusDirect;
            if (t.fromMe) throw new Exception("no reactions to our own status");
            auto c = conn;
            if (c is null) throw new Exception("not connected");
            sendStatusDirect(c, store, dev, parseJidString(t.sender), msg);
        } else sendRaw(t.chat, msg);
        Addon a;
        a.kind = "reaction";
        a.parentId = t.msgId;
        a.text = text;
        a.t = ms / 1000;
        JSONValue p;
        if (chats.applyAddon(account, t.chat, a, me(), true, p)) emit("Msg:change", ingest.handOut(p));
    }

    /// sendRevoke (WAWebRevokeMsgAction; BuildRevoke): delete for everyone. A batch goes on past a
    /// message that fails; only an all-failed batch is an error.
    void sendRevoke(string[] keys) {
        import e2e = wa.pb.e2e;
        import wa.model : Addon;
        string firstErr;
        size_t done;
        foreach (k; keys) {
            try {
                static import wa.actions;
                auto t = target(k);
                sendRaw(t.chat, wa.actions.revokeMessage(messageKey(t)));
                Addon a;
                a.kind = "revoke";
                a.parentId = t.msgId;
                JSONValue p;
                if (chats.applyAddon(account, t.chat, a, me(), true, p)) emit("Msg:change", ingest.handOut(p));
                ingest.emitChat(t.chat);
                done++;
            } catch (Exception e) {
                logf("   revoke %s: %s", k.maskTail, e.msg);
                if (!firstErr.length) firstErr = e.msg;
            }
        }
        if (done == 0 && firstErr.length) throw new Exception(firstErr);
    }

    /// editMessage (BuildEdit): a new text for one of my messages (WhatsApp allows 15 minutes)
    void editMessage(string key, string text) {
        import e2e = wa.pb.e2e;
        import wa.model : Addon;
        auto t = target(key);
        if (!t.fromMe) throw new Exception("only your own messages can be edited");
        static import wa.actions;
        const ms = nowMs;
        sendRaw(t.chat, wa.actions.editMessage(t.chat, t.msgId, text, ms));
        Addon a;
        a.kind = "edit";
        a.parentId = t.msgId;
        a.edited = JSONValue(["type": JSONValue("chat"), "body": JSONValue(text)]);
        a.t = ms / 1000;
        a.tMs = ms;
        JSONValue p;
        if (chats.applyAddon(account, t.chat, a, me(), true, p)) {
            emit("Msg:change", ingest.handOut(p));
            ingest.emitChat(t.chat);
        }
    }

    /// sendStarMsgs (WAWebChatSendStarMsgsBridge; appstate BuildStar)
    JSONValue sendStarMsgs(string[] keys, bool star) {
        import wa.appstate_send : buildStar;
        bool synced = true;
        foreach (k; keys) {
            auto t = target(k);
            auto info = buildStar(t.chat, t.sender, t.msgId, t.fromMe, star);
            if (!trySendAppState(info, "star")) synced = false;
            chats.setStarMark(account, k, star);   // a later history copy keeps it
            auto m = t.m;
            if (star) m["star"] = true;
            else if ("star" in m) m.object.remove("star");
            chats.updateMsg(m);
            emit("Msg:change", ingest.handOut(m));
        }
        return JSONValue(["synced": JSONValue(synced)]);
    }

    /// sendDeleteMsgs (WAWebChatSendDeleteMsgsBridge): delete for me — one app-state patch
    JSONValue sendDeleteMsgs(string[] keys, bool deleteMedia) {
        import wa.appstate_send : buildDeleteForMe, PatchInfo;
        PatchInfo patch;
        Target[] ts;
        foreach (k; keys) {
            Target t;
            try t = target(k); catch (Exception e) { logf("   delete %s: %s", k.maskTail, e.msg); continue; }
            const group = parseJidString(t.chat).server == "g.us";
            auto one = buildDeleteForMe(t.chat, t.msgId, t.fromMe, group && !t.fromMe ? t.sender : "0", deleteMedia, t.t);
            if (patch.name.length == 0) patch = one;
            else patch.mutations ~= one.mutations;
            ts ~= t;
        }
        if (!ts.length) throw new Exception("no deletable messages");
        const synced = trySendAppState(patch, "delete for me");
        foreach (ref t; ts) {
            const key = t.m["id"].str;
            chats.setDeleteMark(account, key);   // a later history copy does not bring it back
            chats.deleteMsg(account, key);
            emit("Msg:remove", JSONValue(["account": JSONValue(account), "id": JSONValue(key), "remote": JSONValue(t.chat)]));
            ingest.emitChat(t.chat);
        }
        return JSONValue(["synced": JSONValue(synced)]);
    }

    /// sendPinInChat (WAWebPinMsgAction): pinned for everyone for a while (24 h, 7 or 30 days), or
    /// unpinned
    void sendPinInChat(string key, bool pin, long seconds) {
        import e2e = wa.pb.e2e;
        import std.datetime.systime : Clock;
        auto t = target(key);
        static import wa.actions;
        if (seconds <= 0) seconds = 7 * 86_400;
        sendRaw(t.chat, wa.actions.pinMessage(messageKey(t), pin, seconds, nowMs));
        if (pin) chats.setChatPin(account, t.chat, t.m["id"].str, Clock.currTime.toUnixTime + seconds);
        else chats.setChatPin(account, t.chat, "", 0);
        ingest.emitChat(t.chat);
    }

    /// markPlayed (WAWebMarkPlayedMsgAction): someone's voice note was listened to
    void markPlayed(string key) {
        import wa.receipt : typedReceipt;
        import std.datetime.systime : Clock;
        auto t = target(key);
        if (t.fromMe) return;
        auto c = conn;
        if (c is null) throw new Exception("not connected");
        auto chat = parseJidString(t.chat);
        const sender = chat.server == "g.us" ? parseJidString(t.sender) : Jid.init;
        c.sendNode(typedReceipt([t.msgId], chat, sender, Clock.currTime.toUnixTime, "played"));
    }

    /// send (WAWebSendMsgChatAction.addAndSendMsgToChat / the Go core's send): stored first at ack
    /// CLOCK, SENT (with the server's time) once the server acks it, FAILED if not. `localFile`: a
    /// media file we already have (its message is RESOLVED to it, no download needed).
    JSONValue deliver(string chatId, const(ubyte)[] msg, const(ubyte)[] localFileData = null) {
        import std.datetime.systime : Clock;
        import wa.model : content, envelope;
        import wa.send : sendDM, newMessageId;
        auto chat = parseJidString(chatId);
        const id = newMessageId(userPart(dev.jid));
        JSONValue n;
        if (!content(msg, n)) throw new Exception("not a message");
        envelope(n, account, id, true, Clock.currTime.toUnixTime, "", chatId, me());
        n["ack"] = 0;   // CLOCK
        chats.putMsg(n, msg);
        chats.bumpChat(n, false, false);
        emit("Msg:add", ingest.handOut(n));
        ingest.emitChat(chatId);
        try {
            import wa.send : SendReport, sendGroup;
            SendReport rep;
            if (chat.server == "g.us") {
                if (chatId !in groupCache) sendQueryGroup(chatId);
                auto gm = groupCache[chatId];
                rep = sendGroup(conn, store, dev, chat, gm.members, gm.lid, msg, id);
                // a different participant hash: our member list is stale (whatsmeow drops the cache)
                if (rep.serverPHash.length && rep.serverPHash != rep.phash) {
                    logf("   group %s: participant hash differs — member cache dropped", chatId.maskTail);
                    groupCache.remove(chatId);
                }
            } else rep = sendDM(conn, store, dev, chat, msg, null, id);
            logf("-> sent %s to %d device(s) (%d new session(s))", id, rep.devices, rep.preKeyMessages);
            foreach (sk; rep.skipped) logf("   skipped %s", sk);
            n["ack"] = 1;   // SENT
            if (rep.t > 0) n["t"] = rep.t;
        } catch (Exception e) {
            logf("-> send %s FAILED: %s", id, e.msg);
            // the message as it is now (a receipt may have come meanwhile): failed only if never acked
            JSONValue curF;
            ubyte[] rawF;
            if (chats.msg(account, n["id"].str, curF, rawF)) n = curF;
            if (!("ack" in n) || n["ack"].integer <= 0) n["ack"] = -1;   // FAILED
            chats.updateMsg(n);
            emit("Msg:change", ingest.handOut(n));
            throw e;
        }
        {
            // receipts processed while we waited for the server's ack (delivered, read) are not undone,
            // nor anything else that changed the message meanwhile: only the send's own outcome goes in
            const sentT = n["t"].integer;
            JSONValue cur;
            ubyte[] rawCur;
            if (chats.msg(account, n["id"].str, cur, rawCur)) {
                if (!("ack" in cur) || cur["ack"].integer < 1) cur["ack"] = 1;
                cur["t"] = sentT;
                n = cur;
            }
        }
        chats.updateMsg(n);
        auto out_ = ingest.handOut(n);
        emit("Msg:change", out_);
        ingest.emitChat(chatId);
        return out_;
    }

/// sendMediaMsgToChat (the Go core's): a file as image / video / voice note (ptt) / audio /
    /// document, picked by its type as WhatsApp Web does; encrypted and uploaded (whatsmeow Upload),
    /// then sent like any message. Our own copy is the file itself (RESOLVED, no download).
    JSONValue sendMedia(string chatId, string path, string caption, string quoted, bool asPtt, bool asDocument, long seconds) {
        import std.file : read, exists;
        import std.path : baseName, extension;
        import std.string : toLower, startsWith;
        import std.json : parseJSON;
        import std.datetime.systime : Clock;
        import wa.media : encryptMedia, uploadURL, httpPost;
        import wa.proto : ProtoWriter;
        import e2e = wa.pb.e2e;
        if (conn is null) throw new Exception("not connected");
        if (!exists(path)) throw new Exception("no file " ~ path);
        auto data = cast(ubyte[]) read(path);
        string mimetype = mimeTypeOf(path);
        enum Kind { image, video, audio, document }
        Kind kind = Kind.document;
        if (asDocument) {}
        else if (asPtt || mimetype.startsWith("audio/")) kind = Kind.audio;
        else if (mimetype.startsWith("image/") && mimetype != "image/gif") kind = Kind.image;
        else if (mimetype.startsWith("video/")) kind = Kind.video;
        static immutable string[4] appInfos = ["WhatsApp Image Keys", "WhatsApp Video Keys", "WhatsApp Audio Keys", "WhatsApp Document Keys"];
        static immutable string[4] mmsTypes = ["image", "video", "audio", "document"];

        // Upload: encrypt, POST to the first media host with the media_conn auth
        auto enc = encryptMedia(data, appInfos[kind]);
        auto hs = hosts();
        auto answer = parseJSON(httpPost(uploadURL(hs[0], mmsTypes[kind], enc.fileEncSHA256, mediaAuth), enc.upload));
        const url = ("url" in answer) ? answer["url"].str : "";
        const directPath = ("direct_path" in answer) ? answer["direct_path"].str : "";
        if (directPath.length == 0) throw new Exception("upload: no direct_path in the answer");
        logf("<- uploaded %s (%d bytes)", mmsTypes[kind], data.length);

        // context: the reply (stanza id + its sender, as the Go core) and the disappearing timer
        auto ci = ProtoWriter();
        if (quoted.length) {
            JSONValue q;
            ubyte[] qraw;
            if (chats.msg(account, quoted, q, qraw)) {
                ci.str(e2e.ContextInfo.stanzaID, q["msgId"].str);
                string participant = q["fromMe"].type == JSONType.true_ ? me()
                    : ("author" in q) ? q["author"].str : q["remote"].str;
                ci.str(e2e.ContextInfo.participant, participant);
            }
        }
        JSONValue c;
        if (chats.chat(account, chatId, c) && ("ephemeralDuration" in c) && c["ephemeralDuration"].integer > 0)
            ci.varint(e2e.ContextInfo.expiration, cast(ulong) c["ephemeralDuration"].integer);

        ubyte[] inner;
        uint field;
        final switch (kind) {
            case Kind.image:
                alias I = e2e.ImageMessage;
                uint w, h;
                ubyte[] thumb;
                pictureInfo(path, w, h, thumb);
                auto m = ProtoWriter().str(I.URL, url).str(I.mimetype, mimetype).str(I.caption, caption)
                    .bytes(I.fileSHA256, enc.fileSHA256).varint(I.fileLength, enc.fileLength)
                    .varint(I.height, h).varint(I.width, w)
                    .bytes(I.mediaKey, enc.mediaKey).bytes(I.fileEncSHA256, enc.fileEncSHA256).str(I.directPath, directPath);
                if (thumb.length) m.bytes(I.JPEGThumbnail, thumb);
                m.bytes(I.contextInfo, ci.buf);
                inner = m.buf; field = e2e.Message.imageMessage;
                break;
            case Kind.video:
                alias V = e2e.VideoMessage;
                inner = ProtoWriter().str(V.URL, url).str(V.mimetype, mimetype).bytes(V.fileSHA256, enc.fileSHA256)
                    .varint(V.fileLength, enc.fileLength).bytes(V.mediaKey, enc.mediaKey).str(V.caption, caption)
                    .bytes(V.fileEncSHA256, enc.fileEncSHA256).str(V.directPath, directPath).bytes(V.contextInfo, ci.buf).buf;
                field = e2e.Message.videoMessage;
                break;
            case Kind.audio:
                alias A = e2e.AudioMessage;
                if (asPtt) mimetype = "audio/ogg; codecs=opus";
                auto m = ProtoWriter().str(A.URL, url).str(A.mimetype, mimetype).bytes(A.fileSHA256, enc.fileSHA256)
                    .varint(A.fileLength, enc.fileLength).varint(A.seconds, cast(ulong) seconds).boolean(A.PTT, asPtt)
                    .bytes(A.mediaKey, enc.mediaKey).bytes(A.fileEncSHA256, enc.fileEncSHA256).str(A.directPath, directPath)
                    .varint(A.mediaKeyTimestamp, cast(ulong) Clock.currTime.toUnixTime).bytes(A.contextInfo, ci.buf);
                // a voice note carries its waveform (64 levels): phones draw it, iPhones need it
                if (asPtt) if (auto wf = waveformOf(path)) m.bytes(A.waveform, wf);
                inner = m.buf; field = e2e.Message.audioMessage;
                break;
            case Kind.document:
                alias D = e2e.DocumentMessage;
                const name = baseName(path);
                inner = ProtoWriter().str(D.URL, url).str(D.mimetype, mimetype).str(D.title, name)
                    .bytes(D.fileSHA256, enc.fileSHA256).varint(D.fileLength, enc.fileLength).bytes(D.mediaKey, enc.mediaKey)
                    .str(D.fileName, name).bytes(D.fileEncSHA256, enc.fileEncSHA256).str(D.directPath, directPath)
                    .bytes(D.contextInfo, ci.buf).str(D.caption, caption).buf;
                field = e2e.Message.documentMessage;
                break;
        }
        auto msg = ProtoWriter().bytes(field, inner).buf;
        auto out_ = deliver(chatId, msg);
        // we have the file already: no download needed (the Go core's mediaPath)
        try {
            import std.file : write, mkdirRecurse;
            import std.path : buildPath;
            import std.digest.sha : sha256Of;
            import std.digest : toHexString, LetterCase;
            JSONValue n;
            ubyte[] raw;
            if (chats.msg(account, out_["id"].str, n, raw) && ("mediaData" in n)) {
                const dir = buildPath(cacheDir, "media");
                mkdirRecurse(dir);
                auto digest = sha256Of(account ~ out_["id"].str);
                const file = buildPath(dir, toHexString!(LetterCase.lower)(digest[0 .. 12]).idup ~ extension(path).toLower);
                write(file, data);
                n["mediaData"]["renderableUrl"] = file;
                n["mediaData"]["mediaStage"] = "RESOLVED";
                chats.updateMsg(n);
                out_ = ingest.handOut(n);
                emit("Msg:change", out_);
            }
        } catch (Exception e) logf("   media copy: %s", e.msg);
        return out_;
    }

/// forwardMessages (the Go core's): every message to every chat, as forwarded (isForwarded, the
    /// forwarding score + 1, the chat's disappearing timer); a plain text goes as an extended text. A
    /// batch skips what it cannot forward instead of stopping at the first failure.
    JSONValue forwardMessages(string[] keys, string[] targets) {
        import wa.model : unwrap;
        import wa.proto : ProtoWriter, replaceField;
        import e2e = wa.pb.e2e;
        JSONValue[] out_;
        string firstErr;
        void fail(string k, string err) {
            logf("   forward %s: %s", k, err);
            if (firstErr.length == 0) firstErr = err;
        }
        static immutable uint[] kinds = [e2e.Message.extendedTextMessage, e2e.Message.imageMessage, e2e.Message.videoMessage,
            e2e.Message.audioMessage, e2e.Message.documentMessage, e2e.Message.stickerMessage, e2e.Message.locationMessage,
            e2e.Message.contactMessage, e2e.Message.contactsArrayMessage, e2e.Message.ptvMessage];
        foreach (k; keys) {
            JSONValue m;
            ubyte[] raw;
            if (!chats.msg(account, k, m, raw) || raw.length == 0) { fail(k, "cannot be forwarded (not stored)"); continue; }
            bool vo;
            ubyte[] inner = unwrap(raw, vo).dup;
            // conversation → extendedTextMessage { text }
            auto ir = ProtoReader(inner);
            if (ir.has(e2e.Message.conversation)) {
                const text = ir.get(e2e.Message.conversation).bytes;
                inner = replaceField(replaceField(inner, e2e.Message.conversation, null), e2e.Message.extendedTextMessage,
                    ProtoWriter().bytes(e2e.ExtendedTextMessage.text, text).buf);
            }
            const score = ("forwardingScore" in m) ? m["forwardingScore"].integer : 0;
            foreach (target; targets) {
                if (target == "status@broadcast") { fail(k, "posting to status is not implemented yet"); continue; }
                auto ci = ProtoWriter().varint(e2e.ContextInfo.forwardingScore, cast(ulong)(score + 1))
                    .boolean(e2e.ContextInfo.isForwarded, true);
                JSONValue c;
                if (chats.chat(account, target, c) && ("ephemeralDuration" in c) && c["ephemeralDuration"].integer > 0)
                    ci.varint(e2e.ContextInfo.expiration, cast(ulong) c["ephemeralDuration"].integer);
                // setContext: the first kind present gets the new context (field 17 in all of them)
                ubyte[] fwd;
                auto r2 = ProtoReader(inner);
                foreach (kind; kinds) if (r2.has(kind)) {
                    fwd = replaceField(inner, kind, replaceField(r2.get(kind).bytes, 17, ci.buf));
                    break;
                }
                if (fwd is null) { fail(k, "this kind of message cannot be forwarded"); continue; }
                try {
                    auto sent = deliver(target, fwd);
                    // the same file: no download for our copy
                    if (("mediaData" in m) && ("renderableUrl" in m["mediaData"])) {
                        JSONValue n;
                        ubyte[] nraw;
                        if (chats.msg(account, sent["id"].str, n, nraw) && ("mediaData" in n)) {
                            n["mediaData"]["renderableUrl"] = m["mediaData"]["renderableUrl"];
                            n["mediaData"]["mediaStage"] = "RESOLVED";
                            chats.updateMsg(n);
                            sent = ingest.handOut(n);
                            emit("Msg:change", sent);
                        }
                    }
                    out_ ~= sent;
                } catch (Exception e) fail(k, e.msg);
            }
        }
        if (out_.length == 0 && firstErr.length) throw new Exception(firstErr);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// saveMedia (the Go core's): the media, downloaded if needed, copied to `dir` (~/Downloads by
    /// default) as "WhatsApp[ Status] YYYY-MM-DD HH.MM.SS[ (n)].ext".
    JSONValue saveMedia(string key, string dir) {
        import std.file : exists, mkdirRecurse, copy;
        import std.path : buildPath, extension, expandTilde;
        import std.datetime.systime : SysTime;
        import std.format : format;
        auto m = downloadMedia(key);
        const src = ("mediaData" in m) && ("renderableUrl" in m["mediaData"]) ? m["mediaData"]["renderableUrl"].str : "";
        if (src.length == 0) throw new Exception("o arquivo ainda não está disponível");
        if (dir.length == 0) dir = "~/Downloads".expandTilde;
        mkdirRecurse(dir);
        const kind = m["remote"].str == "status@broadcast" ? "WhatsApp Status" : "WhatsApp";
        auto t = SysTime.fromUnixTime(m["t"].integer);
        const base = format("%s %04d-%02d-%02d %02d.%02d.%02d", kind, t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second);
        const ext = extension(src);
        string dst = buildPath(dir, base ~ ext);
        for (int i = 2; exists(dst); i++) dst = buildPath(dir, format("%s (%d)%s", base, i, ext));
        copy(src, dst);
        return JSONValue(["path": JSONValue(dst)]);
    }

/// getStatus (the Go core's): the user's "about" text from a user-info usync, stored on the contact.
    JSONValue getStatus(string id) {
        import wa.usync : userInfoIQ, parseUsyncStatus;
        if (conn is null) throw new Exception("not connected");
        auto j = parseJidString(id);
        const user = Jid.pair(j.user, j.server).toString();
        auto r = conn.sendIQ(userInfoIQ([user], conn.nextId(), conn.nextId()));
        if (r.get("type") == "error") throw new Exception("user info query failed");
        auto st = parseUsyncStatus(r);
        if (auto s = user in st) chats.setContact(account, id, "status", *s);
        auto c = chats.contact(account, id);
        emit("Contact:change", c);
        return c;
    }

/// fetchBusinessNames: 1:1 chats with no name to show (not in the address book, no verified name)
    /// are asked for their business profile (usync `<business><verified_name>`, as whatsmeow's
    /// GetUserInfo reads it) — a business answers with its verified name, the chat's title from then
    /// on. A person's own profile name cannot be asked for: it only comes with their messages.
    /// Gently (the server answers 429 rate-overlimit to a burst): each number once, at most 30 a day,
    /// 10 per query and 3 s apart; a 429 stops it for a day.
    void fetchBusinessNames() {
        import vibe.core.core : sleep;
        import core.time : seconds;
        import std.datetime.systime : Clock;
        import wa.usync : businessNameIQ, parseUsyncVerifiedNames;
        const now = Clock.currTime.toUnixTime;
        if (store.meta("biz_names_pause_until") > now) return;
        const day = now / 86_400;
        long budget = store.meta("biz_names_day") == day ? 30 - store.meta("biz_names_today") : 30;
        if (budget <= 0) return;
        string[] todo;
        foreach (ref r; chats.db.query(`SELECT c.id FROM chats c LEFT JOIN contacts k ON k.account=c.account AND k.id=c.id
                WHERE c.account=? AND c.id LIKE '%@s.whatsapp.net' AND c.t > 0 AND c.deleted=0
                AND ifnull(k.name,'')='' AND ifnull(k.verifiedName,'')='' ORDER BY c.t DESC`, account)) {
            const id = r.text(0);
            if (store.meta("biz_asked:" ~ id) == 0) todo ~= id;
            if (todo.length >= budget) break;
        }
        size_t found, asked;
        for (size_t i = 0; i < todo.length && conn !is null; i += 10) {
            if (i) sleep(3.seconds);
            const batch = todo[i .. (i + 10 < todo.length ? i + 10 : todo.length)];
            auto r = conn.sendIQ(businessNameIQ(batch, conn.nextId(), conn.nextId()));
            if (r.get("type") == "error") {
                const e = r.child("error");
                const code = e !is null ? e.get("code") : "";
                logf("   business names: refused (%s) — not asking again today", code);
                store.setMeta("biz_names_pause_until", now + 86_400);
                break;
            }
            foreach (id; batch) store.setMeta("biz_asked:" ~ id, now);
            asked += batch.length;
            foreach (id, name; parseUsyncVerifiedNames(r)) {
                chats.setContact(account, id, "verifiedName", name);
                chats.setContact(account, id, "isBusiness", true);
                emit("Contact:change", chats.contact(account, id));
                ingest.emitChat(id);
                found++;
            }
        }
        if (asked) {
            store.setMeta("biz_names_today", (store.meta("biz_names_day") == day ? store.meta("biz_names_today") : 0) + cast(long) asked);
            store.setMeta("biz_names_day", day);
            logf("   business names: %d of %d unnamed chat(s) asked are businesses", found, asked);
        }
    }

    /// The senders shown in a group without a picture yet: asked in the background, one at a time
    /// (300 ms apart, once a session each); each answer goes out as a Contact:change.
    void fetchAuthorPics(string[] authors) {
        import vibe.core.core : sleep;
        import core.time : msecs;
        import std.algorithm : canFind;
        string[] todo;
        foreach (a; authors) {
            if (a.length == 0 || a in authorPicsAsked) continue;
            auto k = chats.contact(account, a);
            if (("profilePicThumb" in k) && k["profilePicThumb"].str.length) continue;
            authorPicsAsked[a] = true;
            todo ~= a;
        }
        if (todo.length == 0) return;
        runTask((string[] ids) nothrow {
            foreach (id; ids) {
                try {
                    if (conn is null) return;
                    try requestProfilePic(id);
                    catch (Exception e) {
                        if (e.msg.canFind("not set") || e.msg.canFind("hidden")) chats.setContact(account, id, "pic", "-");
                    }
                    sleep(300.msecs);
                } catch (Exception) {}
            }
        }, todo);
    }

    /// loadEarlierMsgs (the Go core's): older messages from the store; when it has fewer than asked,
    /// the phone is asked for 50 before our oldest (HISTORY_SYNC_ON_DEMAND) — they arrive as an
    /// on-demand history chunk. One ask per chat and oldest message a minute (the UI may repeat it).
    JSONValue loadEarlierMsgs(string chatId, long before, int limit, string beforeKey = null) {
        import std.datetime.systime : Clock;
        import wa.send : historySyncRequest, sendPeerMessage;
        if (limit < 50) limit = 50;
        JSONValue[] out_;
        foreach (m; chats.msgs(account, chatId, before, limit, beforeKey)) out_ ~= ingest.handOut(m);
        if (out_.length < limit && conn !is null) {
            string id;
            bool fromMe;
            long t;
            foreach (ref r; chats.db.query(`SELECT json FROM msgs WHERE account=? AND remote=? ORDER BY t ASC LIMIT 1`, account, chatId)) {
                auto m = parseJSON(r.text(0));
                id = ("msgId" in m) ? m["msgId"].str : "";
                fromMe = ("fromMe" in m) && m["fromMe"].type == JSONType.true_;
                t = ("t" in m) ? m["t"].integer : 0;
            }
            const now = Clock.currTime.toUnixTime;
            const k = chatId ~ "|" ~ id;
            if (id.length && now - historyAsked.get(k, 0) >= 60) {
                historyAsked[k] = now;
                try {
                    sendPeerMessage(conn, store, dev, historySyncRequest(chatId, id, fromMe, 50, t));
                    logf("-> asked the phone for older messages of %s", chatId.maskTail);
                } catch (Exception e) logf("   history request: %s", e.msg);
            }
        }
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// profilePicFull (the Go core's): the full-size picture (the viewer's), as a cached file; "" when
    /// there is none or it is hidden from us.
    JSONValue profilePicFull(string id) {
        import std.file : exists, write, mkdirRecurse;
        import std.path : buildPath;
        import std.array : replace;
        import std.datetime.systime : Clock;
        import wa.profile : profilePictureIQ, parseProfilePicture, PictureResult;
        import wa.tctoken : currentTCToken;
        if (conn is null) throw new Exception("not connected");
        auto j = parseJidString(id);
        const tok = currentTCToken(store, j, Clock.currTime.toUnixTime);
        auto r = conn.sendIQ(profilePictureIQ(j, false, tok, conn.nextId()));
        string url, picId;
        if (parseProfilePicture(r, url, picId) != PictureResult.found) return JSONValue(["path": JSONValue("")]);
        const dir = buildPath(cacheDir, "pics");
        mkdirRecurse(dir);
        const file = buildPath(dir, id.replace("@", "_").replace(":", "_") ~ "-full-" ~ picId ~ ".jpg");
        if (!exists(file)) write(file, httpGet(url));
        return JSONValue(["path": JSONValue(file)]);
    }

    /// communityPic (the Go core's): a community's picture file, asked as a community; "" if none.
    string communityPic(string id) {
        import std.file : exists, write, mkdirRecurse;
        import std.path : buildPath;
        import std.array : replace;
        import wa.profile : communityPictureIQ, parseProfilePicture, PictureResult;
        auto c = chats.contact(account, id);
        const have = ("profilePicThumb" in c) ? c["profilePicThumb"].str : "";
        if (have.length && have != "-" && exists(have)) return have;
        if (conn is null) return "";
        try {
            auto r = conn.sendIQ(communityPictureIQ(parseJidString(id), conn.nextId()));
            string url, picId;
            if (parseProfilePicture(r, url, picId) != PictureResult.found) return "";
            auto data = httpGet(url);
            const dir = buildPath(cacheDir, "pics");
            mkdirRecurse(dir);
            const file = buildPath(dir, id.replace("@", "_").replace(":", "_") ~ "-" ~ picId ~ ".jpg");
            write(file, data);
            chats.setContact(account, id, "pic", file);
            return file;
        } catch (Exception e) { logf("   community picture %s: %s", id.maskTail, e.msg); return ""; }
    }

/// iqError: an error answer's "what (code)", "" for a result
    private static string iqError(const ref Node r, string what) {
        if (r.get("type") != "error") return "";
        const e = r.child("error");
        return what ~ (e !is null && e.get("code").length ? " (" ~ e.get("code") ~ ")" : "");
    }

    /// createGroup (WAWebCreateGroupAction / whatsmeow CreateGroup): the group, stored and announced as
    /// sendQueryGroup's; a LID member goes with its phone number, each with the privacy token we hold.
    JSONValue createGroup(string name, string[] participants) {
        import std.string : strip;
        import std.datetime.systime : Clock;
        import wa.groups : createGroupIQ, NewMember, parseGroupNode;
        import wa.tctoken : currentTCToken;
        if (name.strip.length == 0 || participants.length == 0) throw new Exception("a group needs a name and participants");
        if (conn is null) throw new Exception("not connected");
        NewMember[] ms;
        foreach (p; participants) {
            NewMember m;
            auto j = parseJidString(p);
            m.jid = Jid.pair(j.user, j.server);
            if (j.server == "lid") {
                const pn = store.pnForLID(j.user);
                if (pn.length) m.phoneNumber = Jid.pair(pn, "s.whatsapp.net");
            }
            m.token = currentTCToken(store, m.jid, Clock.currTime.toUnixTime);
            ms ~= m;
        }
        auto r = conn.sendIQ(createGroupIQ(name, ms, conn.nextId()));
        { const e = iqError(r, "group not created"); if (e.length) throw new Exception(e); }
        const gn = r.child("group");
        if (gn is null) throw new Exception("no <group> in the answer");
        const id = parseGroupNode(*gn).jid.toString();
        logf("-> group created (%d members)", ms.length);
        // its metadata as sendQueryGroup stores it (the answer's <group> is the same)
        JSONValue g;
        try g = sendQueryGroup(id);
        catch (Exception e) logf("   new group info: %s", e.msg);
        chats.ensureChat(account, id);
        chats.setChatName(account, id, name);
        return g;
    }

    /// GetSubGroups: a community's groups (the announcements one marked isDefault)
    auto subGroups(string community) {
        import wa.groups : subGroupsIQ, parseSubGroups;
        if (conn is null) throw new Exception("not connected");
        auto r = conn.sendIQ(subGroupsIQ(parseJidString(community), conn.nextId()));
        { const e = iqError(r, "community groups query failed"); if (e.length) throw new Exception(e); }
        return parseSubGroups(r);
    }

    /// linkedGroupSize (the Go core's): a community group's member count, 0 if unknown
    long linkedGroupSize(string community, string sub) {
        import wa.groups : queryLinkedIQ, linkedSize;
        if (conn is null) return 0;
        try {
            auto r = conn.sendIQ(queryLinkedIQ(parseJidString(community), parseJidString(sub), conn.nextId()));
            { const e = iqError(r, "linked group"); if (e.length) { logln("   ", e); return 0; } }
            return linkedSize(r);
        } catch (Exception e) { logln("   linked group: ", e.msg); return 0; }
    }

    /// inGroup (the Go core's): we are among the stored participants
    bool inGroup(string id) {
        JSONValue g;
        if (!chats.group(account, id, g) || ("participants" !in g) || g["participants"].type != JSONType.array) return false;
        const mine = me(), lid = meLid();
        foreach (p; g["participants"].array) {
            const pid = ("id" in p) ? p["id"].str : "";
            if (pid == mine || (lid.length && pid == lid)) return true;
        }
        return false;
    }

    /// joinCommunityGroup (the Go core's): in, through the community (no invite needed), then its
    /// metadata, and WhatsApp Web's "you joined" row.
    void joinCommunityGroup(string community, string sub) {
        import wa.groups : joinLinkedGroupIQ;
        if (conn is null) throw new Exception("not connected");
        auto r = conn.sendIQ(joinLinkedGroupIQ(parseJidString(community), parseJidString(sub), conn.nextId()));
        { const e = iqError(r, "could not join the group"); if (e.length) throw new Exception(e); }
        try sendQueryGroup(sub);
        catch (Exception e) logf("   joined group info: %s", e.msg);
        if (!inGroup(sub)) throw new Exception("the community did not let us in (it may need an admin's approval)");
        logln("-> joined a community group");
        systemRow(sub, "gp2", "linked_group_join", [me()]);
    }

    /// systemRow (the Go core's): a gp2 / e2e / call_log message made on our side, as WhatsApp Web
    /// makes them. People joining and leaving don't move the chat (WhatsApp keeps its time and preview
    /// on the last real message): the notice is only in the conversation.
    void systemRow(string remote, string type_, string subtype, const(string)[] params, long at = 0, string from = "") {
        import std.datetime.systime : Clock;
        import std.algorithm : canFind;
        import std.conv : to;
        import wa.model : envelope;
        const now = Clock.currTime;
        const id = subtype ~ "-" ~ (from.length ? from : (now.toUnixTime!long * 1_000_000_000 + now.fracSecs.total!"nsecs").to!string);
        const t = at > 0 ? at : now.toUnixTime;
        JSONValue m = JSONValue.emptyObject;
        m["type"] = type_;
        m["subtype"] = subtype;
        if (params.length) {
            JSONValue[] ps;
            foreach (p; params) ps ~= JSONValue(p);
            m["templateParams"] = ps;
        }
        envelope(m, account, id, false, t, "", remote, params.length ? params[0] : "");
        if (!chats.putMsg(m, null)) return;
        static immutable membership = ["add", "remove", "leave", "invite", "linked_group_join", "community_link", "member_add_mode"];
        if (!(type_ == "gp2" && membership.canFind(subtype))) chats.bumpChat(m, false, false);
        emit("Msg:add", ingest.handOut(m));
        ingest.emitChat(remote);
    }

    /// onGroupInfo (the Go core's): a group change becomes the stored metadata and WhatsApp Web's gp2
    /// rows (templateParams: who did it, then whom or what); a group we were added to (<create>) is
    /// stored as a query's answer would be.
    void onGroupChange(GroupChange e) {
        import std.conv : to;
        import wa.lid : storeLIDPNMapping;
        foreach (pr; e.lidPairs) storeLIDPNMapping(store, pr[0], pr[1]);
        if (e.isCreate) {
            storeGroup(e.created);
            logln("<- added to a group");
            return;
        }
        const id = e.jid.toString();
        JSONValue g;
        if (!chats.group(account, id, g) || g.type != JSONType.object) g = JSONValue.emptyObject;
        g["id"] = id;
        g["account"] = account;
        if ("participants" !in g || g["participants"].type != JSONType.array) g["participants"] = parseJSON("[]");
        const by = e.sender.user.length ? ingest.canonical(e.sender) : "";
        string[] who(Jid[] l) {
            string[] o = [by];
            foreach (j; l) o ~= ingest.canonical(j);
            return o;
        }
        const t = e.t;
        if (e.hasName) {
            g["subject"] = e.name;
            g["subjectTime"] = e.nameSetAt;
            chats.setChatName(account, id, e.name);
            systemRow(id, "gp2", "subject", [by, e.name], t, e.id);
        }
        if (e.hasTopic) {
            g["desc"] = e.topic;
            systemRow(id, "gp2", "description", [by], t, e.id);
        }
        if (e.announce >= 0) {
            g["announce"] = e.announce == 1;
            systemRow(id, "gp2", "announce", [by, e.announce == 1 ? "true" : "false"], t, e.id);
        }
        if (e.locked >= 0) {
            g["restrict"] = e.locked == 1;
            systemRow(id, "gp2", "restrict", [by, e.locked == 1 ? "true" : "false"], t, e.id);
        }
        if (e.hasEphemeral) {
            const d = e.ephemeral ? cast(long) e.timer : 0L;
            g["ephemeralDuration"] = d;
            systemRow(id, "gp2", "ephemeral", [by, d.to!string], t, e.id);
        }
        if (e.join.length) {
            systemRow(id, "gp2", "add", who(e.join), t, e.id);
            foreach (j; e.join) {
                const pid = ingest.canonical(j);
                bool have;
                foreach (p; g["participants"].array) if (("id" in p) && p["id"].str == pid) have = true;
                if (!have) g["participants"].array ~= JSONValue(["id": JSONValue(pid), "isAdmin": JSONValue(false),
                    "isSuperAdmin": JSONValue(false)]);
                if (pid == me() || pid == meLid()) chats.setChat(account, id, "isReadOnly", false);
            }
        }
        if (e.leave.length) {
            const ws = who(e.leave);
            const sub = e.leave.length == 1 && by.length && by == ws[1] ? "leave" : "remove";
            systemRow(id, "gp2", sub, ws, t, e.id);
            bool[string] gone;
            foreach (pid; ws[1 .. $]) {
                gone[pid] = true;
                if (pid == me() || (meLid().length && pid == meLid())) chats.setChat(account, id, "isReadOnly", true);
            }
            JSONValue[] keep;
            foreach (p; g["participants"].array) if (!(("id" in p) && (p["id"].str in gone))) keep ~= p;
            g["participants"] = keep.length ? JSONValue(keep) : parseJSON("[]");
        }
        void setAdmin(Jid[] l, bool admin) {
            foreach (j; l) {
                const pid = ingest.canonical(j);
                foreach (ref p; g["participants"].array) if (("id" in p) && p["id"].str == pid) p["isAdmin"] = admin;
            }
        }
        if (e.promote.length) { systemRow(id, "gp2", "promote", who(e.promote), t, e.id); setAdmin(e.promote, true); }
        if (e.demote.length) { systemRow(id, "gp2", "demote", who(e.demote), t, e.id); setAdmin(e.demote, false); }
        g["size"] = cast(long) g["participants"].array.length;
        chats.putGroup(g);
        emit("GroupMetadata:change", g);
        ingest.emitChat(id);
        logln("<- group changed");
    }

    /// logout (whatsmeow Logout): this device removed from the account, the connection ended for good,
    /// and its keys deleted (the chat store stays, as the Go core leaves it).
    void logout() {
        import wa.groups : logoutIQ;
        if (conn is null) throw new Exception("not connected");
        if (dev.jid.length == 0) throw new Exception("not logged in");
        auto r = conn.sendIQ(logoutIQ(parseJidString(dev.jid), conn.nextId()));
        { const e = iqError(r, "logout failed"); if (e.length) throw new Exception(e); }
        stopping = true;
        try sock.close(); catch (Exception) {}
        forget();
        logln("-> logged out: this device was removed and its keys deleted");
    }

/// Our "about" (Recado), as WhatsApp Web sets it (WAWebSetAboutJob).
    JSONValue setAbout(string text) {
        import wa.profile : setAboutIQ;
        if (conn is null) throw new Exception("not connected");
        auto r = conn.sendIQ(setAboutIQ(text, conn.nextId()));
        if (r.get("type") != "result") {
            const e = r.child("error");
            throw new Exception("about not changed" ~ (e !is null ? " (" ~ e.get("code") ~ ")" : ""));
        }
        chats.setContact(account, me(), "status", text);
        auto c = chats.contact(account, me());
        emit("Contact:change", c);
        logln("-> about changed");
        return c;
    }

    /// Our profile picture: the image cropped to a centred square, 640×640 JPEG (WhatsApp's size),
    /// sent as WhatsApp Web does; then our picture is fetched again.
    JSONValue setProfilePicture(string path) {
        import std.process : execute;
        import std.file : exists;
        import wa.profile : setOwnPictureIQ;
        import core.time : seconds;
        if (conn is null) throw new Exception("not connected");
        if (!exists(path)) throw new Exception("no file " ~ path);
        auto j = execOff(["ffmpeg", "-v", "error", "-i", path, "-vf",
            "crop='min(iw,ih)':'min(iw,ih)',scale=640:640", "-frames:v", "1", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]);
        if (j.status != 0 || j.output.length == 0) throw new Exception("this image cannot be read");
        // ffmpeg ran on a worker: the connection may have dropped meanwhile
        auto c = conn;
        if (c is null) throw new Exception("not connected");
        auto r = c.sendIQ(setOwnPictureIQ(cast(const(ubyte)[]) j.output, c.nextId()), 30.seconds);
        if (r.get("type") != "result") {
            const e = r.child("error");
            throw new Exception("picture not changed" ~ (e !is null ? " (" ~ e.get("code") ~ ")" : ""));
        }
        logln("-> profile picture changed");
        chats.setContact(account, me(), "pic", "");
        try return requestProfilePic(me()); catch (Exception) return chats.contact(account, me());
    }

/// channels (the Go core's): the followed newsletters (GetSubscribedNewsletters), completed with
    /// their own metadata when the list lacks the follower count or the picture (GetNewsletterInfo);
    /// kept like group metadata (name, description, followers) and their picture as the avatar.
    JSONValue channels() {
        import std.file : write, mkdirRecurse;
        import std.path : buildPath;
        import std.array : replace;
        import std.conv : to;
        import wa.mex;
        if (conn is null) throw new Exception("not connected");
        auto data = mexData(conn.sendIQ(mexIQ(querySubscribedNewsletters, "{}", conn.nextId())));
        JSONValue[] out_;
        auto list = ("xwa2_newsletter_subscribed" in data) ? data["xwa2_newsletter_subscribed"].array : null;
        static string sget(JSONValue o, string a, string b = null) {
            if (o.type != JSONType.object) return "";
            auto x = a in o;
            if (x is null) return "";
            if (b is null) return x.type == JSONType.string ? x.str : "";
            auto y = (x.type == JSONType.object) ? (b in *x) : null;
            return y !is null && y.type == JSONType.string ? y.str : "";
        }
        static long subscribers(JSONValue tm) {
            auto s = sget(tm, "subscribers_count");
            try return s.length ? s.to!long : 0; catch (Exception) return 0;
        }
        foreach (n; list) {
            const id = sget(n, "id");
            if (id.length == 0) continue;
            auto tm = ("thread_metadata" in n) ? n["thread_metadata"] : JSONValue.emptyObject;
            if (subscribers(tm) == 0 || (sget(tm, "preview", "url").length == 0 && sget(tm, "preview", "direct_path").length == 0)) {
                try {
                    auto full = mexData(conn.sendIQ(mexIQ(queryFetchNewsletter, newsletterInfoVariables(id), conn.nextId())));
                    if (auto f = "xwa2_newsletter" in full) if (f.type == JSONType.object) if (auto ftm = "thread_metadata" in *f) {
                        if (subscribers(*ftm) > 0) tm["subscribers_count"] = (*ftm)["subscribers_count"];
                        if (sget(*ftm, "preview", "url").length || sget(*ftm, "preview", "direct_path").length) tm["preview"] = (*ftm)["preview"];
                    }
                } catch (Exception e) logf("   channel %s: %s", id.maskTail, e.msg);
            }
            const name = sget(tm, "name", "text"), desc = sget(tm, "description", "text");
            JSONValue ch = ["id": JSONValue(id), "name": JSONValue(name), "subscribers": JSONValue(subscribers(tm)),
                "verified": JSONValue(sget(tm, "verification") == "verified")];
            if (desc.length) ch["description"] = desc;
            if (const inv = sget(tm, "invite")) if (inv.length) ch["invite"] = inv;
            JSONValue g = ["id": JSONValue(id), "account": JSONValue(account), "subject": JSONValue(name),
                "restrict": JSONValue(false), "announce": JSONValue(false), "ephemeralDuration": JSONValue(0L),
                "size": JSONValue(subscribers(tm)), "isParentGroup": JSONValue(false), "participants": parseJSON("[]")];
            if (desc.length) g["desc"] = desc;
            chats.putGroup(g);
            // the picture: its URL, else the media host + its direct path
            auto k = chats.contact(account, id);
            const have = ("profilePicThumb" in k) ? k["profilePicThumb"].str : "";
            string url = sget(tm, "preview", "url");
            if (url.length == 0 && sget(tm, "preview", "direct_path").length) url = "https://mmg.whatsapp.net" ~ sget(tm, "preview", "direct_path");
            if ((have.length == 0 || have == "-") && url.length) {
                try {
                    auto bytes = httpGet(url);
                    const dir = buildPath(cacheDir, "pics");
                    mkdirRecurse(dir);
                    const file = buildPath(dir, id.replace("@", "_") ~ "-" ~ sget(tm, "preview", "id") ~ ".jpg");
                    write(file, bytes);
                    chats.setContact(account, id, "pic", file);
                } catch (Exception e) logf("   channel picture %s: %s", id.maskTail, e.msg);
            }
            const pic = ("profilePicThumb" in chats.contact(account, id)) ? chats.contact(account, id)["profilePicThumb"].str : "";
            if (pic.length && pic != "-") ch["pic"] = pic;
            out_ ~= ch;
            ingest.emitChat(id);
        }
        // channels in our chat list we no longer follow: their own metadata, for the picture
        bool[string] followed;
        foreach (ch; out_) followed[ch["id"].str] = true;
        foreach (c; chats.chats(account)) {
            const id = c["id"].str;
            if (c["kind"].str != "newsletter" || id in followed) continue;
            auto k = chats.contact(account, id);
            const have = ("profilePicThumb" in k) ? k["profilePicThumb"].str : "";
            if (have.length) continue;
            try {
                auto full = mexData(conn.sendIQ(mexIQ(queryFetchNewsletter, newsletterInfoVariables(id), conn.nextId())));
                auto f = ("xwa2_newsletter" in full) ? full["xwa2_newsletter"] : JSONValue(null);
                auto tm = (f.type == JSONType.object && ("thread_metadata" in f)) ? f["thread_metadata"] : JSONValue.emptyObject;
                string url = sget(tm, "preview", "url");
                if (url.length == 0 && sget(tm, "preview", "direct_path").length) url = "https://mmg.whatsapp.net" ~ sget(tm, "preview", "direct_path");
                if (url.length == 0) { chats.setContact(account, id, "pic", "-"); continue; }
                auto bytes = httpGet(url);
                const dir = buildPath(cacheDir, "pics");
                mkdirRecurse(dir);
                const file = buildPath(dir, id.replace("@", "_") ~ "-" ~ sget(tm, "preview", "id") ~ ".jpg");
                write(file, bytes);
                chats.setContact(account, id, "pic", file);
                ingest.emitChat(id);
            } catch (Exception e) {
                import std.algorithm : canFind;
                logf("   channel %s: %s", id.maskTail, e.msg);
                // "Not Allowed" (gone, or closed to us): nothing to ask again next time
                if (e.msg.canFind("\"error_code\":405")) chats.setContact(account, id, "pic", "-");
            }
        }
        logf("<- channels: %d followed", out_.length);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

// ── sticker packs (local: our own groups of stickers for the panel; nothing is sent) ──────

    /// A stored sticker's file hash and its pack (read from the file, downloaded if needed; cached).
    bool stickerInfo(string key, out string filehash, out string pack, out string name, out string publisher) {
        import std.file : read, exists;
        filehash = ingest.stickerFileHash(key);
        if (filehash.length == 0) return false;
        foreach (ref r; chats.db.query(`SELECT pack, name, publisher FROM sticker_meta WHERE account=? AND filehash=?`, account, filehash)) {
            pack = r.text(0); name = r.text(1); publisher = r.text(2);
            return true;
        }
        JSONValue m;
        ubyte[] raw;
        string file;
        if (chats.msg(account, key, m, raw) && ("mediaData" in m) && ("renderableUrl" in m["mediaData"])) file = m["mediaData"]["renderableUrl"].str;
        if (file.length == 0 || !exists(file)) {
            auto d = downloadMedia(key);
            file = ("mediaData" in d) && ("renderableUrl" in d["mediaData"]) ? d["mediaData"]["renderableUrl"].str : "";
        }
        if (file.length == 0) return false;
        if (!stickerPackOf(cast(const(ubyte)[]) read(file), pack, name, publisher)) {
            pack = "single:" ~ filehash;   // no pack inside: a pack of its own
            name = ""; publisher = "";
        }
        chats.db.run(`INSERT OR REPLACE INTO sticker_meta(account, filehash, pack, name, publisher) VALUES(?,?,?,?,?)`,
            account, filehash, pack, name, publisher);
        return true;
    }

/// Sticker.list (the Go core's stickerList): the stickers sent and received, newest first, each
    /// file once; Lottie stickers (application/was) are left out — not drawable here.
    JSONValue stickerList(int limit) {
        import wa.model : unwrap;
        import e2e = wa.pb.e2e;
        if (limit <= 0 || limit > 200) limit = 80;
        bool[string] seen;
        JSONValue[] out_;
        string[] keys;
        foreach (ref r; chats.db.query(`SELECT key FROM msgs WHERE account=? AND type='sticker' ORDER BY t DESC LIMIT 600`, account))
            keys ~= r.text(0);
        foreach (k; keys) {
            JSONValue m;
            ubyte[] raw;
            if (!chats.msg(account, k, m, raw) || raw.length == 0) continue;
            bool vo;
            auto st = ProtoReader(ProtoReader(unwrap(raw, vo)).get(e2e.Message.stickerMessage).bytes);
            if (cast(string) st.get(e2e.StickerMessage.mimetype).bytes == "application/was") continue;
            const sha = st.get(e2e.StickerMessage.fileSHA256).bytes;
            if (sha.length == 0) continue;
            const h = cast(string) sha.idup;
            if (h in seen) continue;
            seen[h] = true;
            out_ ~= ingest.handOut(m);
            if (out_.length >= limit) break;
        }
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// StickerPack.info: the pack a sticker belongs to (to name it before adding).
    JSONValue stickerPackInfo(string key) {
        string fh, pack, name, pub;
        if (!stickerInfo(key, fh, pack, name, pub)) throw new Exception("not a stored sticker");
        JSONValue o = ["id": JSONValue(pack), "name": JSONValue(name), "publisher": JSONValue(pub)];
        if (chats.db.scalarInt(`SELECT count(*) FROM sticker_packs WHERE account=? AND pack=?`, account, pack) > 0)
            o["added"] = true;
        return o;
    }

    /// StickerPack.add: the sticker's pack, under `name`, with every sticker of that pack we have
    /// (the downloaded ones now; the rest are downloaded in the background and join as they come).
    JSONValue addStickerPack(string key, string name) {
        import std.datetime.systime : Clock;
        string fh, pack, packName, pub;
        if (!stickerInfo(key, fh, pack, packName, pub)) throw new Exception("not a stored sticker");
        if (name.length == 0) name = packName.length ? packName : "Figurinhas";
        const now = Clock.currTime.toUnixTime;
        chats.db.run(`INSERT INTO sticker_packs(account, pack, name, publisher, t) VALUES(?,?,?,?,?)
            ON CONFLICT(account, pack) DO UPDATE SET name=excluded.name`, account, pack, name, pub, now);
        chats.db.run(`INSERT OR IGNORE INTO sticker_pack_items(account, pack, filehash, msg, t) VALUES(?,?,?,?,?)`,
            account, pack, fh, key, now);
        import std.algorithm : startsWith;
        if (!pack.startsWith("single:")) {
            // the other stickers we have: known metadata first, then the rest in the background
            string[] pending;
            foreach (ref r; chats.db.query(`SELECT key, json FROM msgs WHERE account=? AND type='sticker' ORDER BY t DESC LIMIT 1000`, account)) {
                const k = r.text(0);
                const h = ingest.stickerFileHash(k);
                if (h.length == 0) continue;
                const known = chats.db.scalarText(`SELECT pack FROM sticker_meta WHERE account=? AND filehash=?`, account, h);
                if (known == pack) chats.db.run(`INSERT OR IGNORE INTO sticker_pack_items(account, pack, filehash, msg, t) VALUES(?,?,?,?,?)`,
                    account, pack, h, k, now);
                else if (known.length == 0) pending ~= k;
            }
            if (pending.length) runTask((string[] keys, string pk) nothrow {
                foreach (k; keys) {
                    try {
                        string h, p2, n2, pb2;
                        if (stickerInfo(k, h, p2, n2, pb2) && p2 == pk) {
                            import std.datetime.systime : Clock;
                            chats.db.run(`INSERT OR IGNORE INTO sticker_pack_items(account, pack, filehash, msg, t) VALUES(?,?,?,?,?)`,
                                account, pk, h, k, Clock.currTime.toUnixTime);
                            emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(pk)]));
                        }
                    } catch (Exception) {}
                }
            }, pending, pack);
        }
        emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(pack)]));
        return stickerPacks();
    }

    /// StickerPack.addTo: this one sticker into a pack we already have (no new tab, and none of the
    /// sticker's own pack comes along).
    JSONValue addStickerTo(string key, string pack) {
        import std.datetime.systime : Clock;
        string fh, own, n, pb;
        if (!stickerInfo(key, fh, own, n, pb)) throw new Exception("not a stored sticker");
        if (chats.db.scalarInt(`SELECT count(*) FROM sticker_packs WHERE account=? AND pack=?`, account, pack) == 0)
            throw new Exception("no such sticker pack");
        chats.db.run(`INSERT OR IGNORE INTO sticker_pack_items(account, pack, filehash, msg, t) VALUES(?,?,?,?,?)`,
            account, pack, fh, key, Clock.currTime.toUnixTime);
        emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(pack)]));
        return stickerPacks();
    }

    /// StickerPack.list: our packs, newest first, each with its stickers (handed-out messages).
    JSONValue stickerPacks() {
        JSONValue[] out_;
        string[3][] packs;
        foreach (ref r; chats.db.query(`SELECT pack, name, publisher FROM sticker_packs WHERE account=? ORDER BY t DESC`, account))
            packs ~= [r.text(0), r.text(1), r.text(2)];
        foreach (p; packs) {
            JSONValue[] items;
            string[] keys;
            foreach (ref r; chats.db.query(`SELECT msg FROM sticker_pack_items WHERE account=? AND pack=? ORDER BY t`, account, p[0]))
                keys ~= r.text(0);
            foreach (k; keys) {
                import std.algorithm : startsWith;
                if (k.startsWith("fp:")) {
                    // a sticker of WhatsApp's own packs: its file, ready
                    const file = chats.db.scalarText(`SELECT file FROM fp_stickers WHERE account=? AND id=?`, account, k);
                    if (file.length) items ~= JSONValue(["id": JSONValue(k), "type": JSONValue("sticker"),
                        "mediaData": JSONValue(["renderableUrl": JSONValue(file), "mediaStage": JSONValue("RESOLVED")])]);
                    continue;
                }
                JSONValue m;
                ubyte[] raw;
                if (chats.msg(account, k, m, raw)) items ~= ingest.handOut(m);
            }
            JSONValue o = ["id": JSONValue(p[0]), "name": JSONValue(p[1]), "publisher": JSONValue(p[2]),
                "stickers": items.length ? JSONValue(items) : parseJSON("[]")];
            out_ ~= o;
        }
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

/// StickerStore.list (WAWebFetchFirstPartyStickerPacksAction): WhatsApp's own sticker packs, from
    /// static.whatsapp.net (kept an hour) — id, name, publisher, animated, and the tray picture's URL.
    JSONValue stickerStore() {
        import std.datetime.systime : Clock;
        import std.json : parseJSON;
        import wa.media : queryEscape;
        const now = Clock.currTime.toUnixTime;
        if (storeCache.type == JSONType.array && now - storeCacheAt < 3600) return storeCache;
        auto list = parseJSON(cast(string) httpGet("https://static.whatsapp.net/sticker?cat=sticker_store_data&id=all&lg=pt_BR&country=BR"));
        JSONValue[] out_;
        if (list.type == JSONType.array) foreach (p; list.array) {
            if (p.type != JSONType.object || ("sticker-pack-id" !in p)) continue;
            if (("lottie" in p) && p["lottie"].type == JSONType.integer && p["lottie"].integer == 1) continue;   // not drawable here
            JSONValue o = ["id": JSONValue(p["sticker-pack-id"].str),
                "name": JSONValue(("name" in p) ? p["name"].str : ""),
                "publisher": JSONValue(("publisher" in p) ? p["publisher"].str : ""),
                "animated": JSONValue(("animated" in p) && p["animated"].type == JSONType.integer && p["animated"].integer == 1)];
            const tray = ("tray-image-id" in p) ? p["tray-image-id"].str : "";
            if (tray.length) o["tray"] = "https://static.whatsapp.net/sticker?cat=sticker_preview_png&id=" ~ queryEscape(tray);
            out_ ~= o;
        }
        storeCache = out_.length ? JSONValue(out_) : parseJSON("[]");
        storeCacheAt = now;
        return storeCache;
    }

    /// StickerPack.addStore: one of WhatsApp's packs (sticker_pack_data), under `name`: each sticker
    /// downloaded with its keys (as any media) and kept with its StickerMessage, ready to send.
    JSONValue addStorePack(string packId, string name) {
        import std.json : parseJSON;
        import std.base64 : Base64;
        import std.file : write, mkdirRecurse, exists;
        import std.path : buildPath;
        import std.datetime.systime : Clock;
        import wa.media : decryptMedia, queryEscape;
        import wa.proto : ProtoWriter;
        import std.array : replace;
        import e2e = wa.pb.e2e;
        auto data = parseJSON(cast(string) httpGet("https://static.whatsapp.net/sticker?lottie=1&cat=sticker_pack_data&id="
            ~ queryEscape(packId) ~ "&lg=pt_BR"));
        if (data.type != JSONType.array || data.array.length == 0) throw new Exception("sticker pack not found");
        auto p = data.array[0];
        string g(JSONValue o, string k) { auto v = k in o; return v !is null && v.type == JSONType.string ? v.str : ""; }
        long n(JSONValue o, string k) { auto v = k in o; return v is null ? 0 : v.type == JSONType.integer ? v.integer : 0; }
        if (name.length == 0) name = g(p, "name");
        const animated = n(p, "animated") == 1;
        const now = Clock.currTime.toUnixTime;
        chats.db.run(`INSERT INTO sticker_packs(account, pack, name, publisher, t) VALUES(?,?,?,?,?)
            ON CONFLICT(account, pack) DO UPDATE SET name=excluded.name`, account, packId, name, g(p, "publisher"), now);
        const dir = buildPath(cacheDir, "stickers");
        mkdirRecurse(dir);
        size_t got;
        if (auto items = "stickers" in p) if (items.type == JSONType.array) foreach (s; items.array) {
            try {
                const fileHash = Base64.decode(g(s, "file-hash")), encHash = Base64.decode(g(s, "enc-file-hash")),
                    mediaKey = Base64.decode(g(s, "media-key"));
                const directPath = g(s, "direct-path");
                if (directPath.length == 0 || mediaKey.length == 0) continue;
                const id = "fp:" ~ packId ~ ":" ~ g(s, "file-hash");
                string file = buildPath(dir, g(s, "file-hash").replace("/", "_").replace("+", "-") ~ ".webp");
                if (!exists(file)) write(file, decryptMedia(downloadAs(directPath, encHash, "image"), mediaKey, "WhatsApp Image Keys", encHash, fileHash));
                alias S = e2e.StickerMessage;
                auto st = ProtoWriter().str(S.URL, g(s, "url")).bytes(S.fileSHA256, fileHash).bytes(S.fileEncSHA256, encHash)
                    .bytes(S.mediaKey, mediaKey).str(S.mimetype, g(s, "mimetype").length ? g(s, "mimetype") : "image/webp")
                    .varint(S.height, cast(ulong) n(s, "height")).varint(S.width, cast(ulong) n(s, "width"))
                    .str(S.directPath, directPath).varint(S.fileLength, cast(ulong) n(s, "file-size"))
                    .varint(S.mediaKeyTimestamp, cast(ulong) now);
                if (animated) st.boolean(S.isAnimated, true);
                chats.db.run(`INSERT OR REPLACE INTO fp_stickers(account, id, pack, raw, file) VALUES(?,?,?,?,?)`,
                    account, id, packId, st.buf, file);
                chats.db.run(`INSERT OR IGNORE INTO sticker_pack_items(account, pack, filehash, msg, t) VALUES(?,?,?,?,?)`,
                    account, packId, g(s, "file-hash"), id, now);
                got++;
            } catch (Exception e) logf("   store sticker: %s", e.msg);
        }
        logf("<- sticker pack %s: %d sticker(s)", name, got);
        emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(packId)]));
        return stickerPacks();
    }

    void renameStickerPack(string pack, string name) {
        chats.db.run(`UPDATE sticker_packs SET name=? WHERE account=? AND pack=?`, name, account, pack);
        emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(pack)]));
    }
    void removeStickerPack(string pack) {
        chats.db.run(`DELETE FROM sticker_packs WHERE account=? AND pack=?`, account, pack);
        chats.db.run(`DELETE FROM fp_stickers WHERE account=? AND pack=?`, account, pack);
        chats.db.run(`DELETE FROM sticker_pack_items WHERE account=? AND pack=?`, account, pack);
        emit("StickerPack:change", JSONValue(["account": JSONValue(account), "id": JSONValue(pack)]));
    }

    /// sendSticker (the Go core's): a stored sticker sent again — the same file (direct path, keys,
    /// hashes), its context replaced by the chat's disappearing timer if any; no re-upload.
    JSONValue sendSticker(string chatId, string key) {
        import wa.model : unwrap;
        import wa.proto : ProtoWriter, replaceField;
        import std.algorithm : startsWith;
        import e2e = wa.pb.e2e;
        JSONValue m;
        ubyte[] raw;
        const(ubyte)[] st;
        if (key.startsWith("fp:")) {
            // one of WhatsApp's own stickers: its StickerMessage as the store gives it (no upload)
            foreach (ref r; chats.db.query(`SELECT raw, file FROM fp_stickers WHERE account=? AND id=?`, account, key)) {
                st = r.blob(0).dup;
                m = JSONValue(["mediaData": JSONValue(["renderableUrl": JSONValue(r.text(1))])]);
            }
            if (st.length == 0) throw new Exception("sticker not stored");
        } else {
            if (!chats.msg(account, key, m, raw) || raw.length == 0) throw new Exception("sticker not stored");
            bool vo;
            st = ProtoReader(unwrap(raw, vo)).get(e2e.Message.stickerMessage).bytes;
        }
        if (st.length == 0) throw new Exception("not a sticker");
        ubyte[] ci;
        JSONValue c;
        if (chats.chat(account, chatId, c) && ("ephemeralDuration" in c) && c["ephemeralDuration"].integer > 0)
            ci = ProtoWriter().varint(e2e.ContextInfo.expiration, cast(ulong) c["ephemeralDuration"].integer).buf;
        auto sticker = replaceField(st, e2e.StickerMessage.contextInfo, ci.length ? ci : null);
        auto sent = deliver(chatId, ProtoWriter().bytes(e2e.Message.stickerMessage, sticker).buf);
        if (("mediaData" in m) && ("renderableUrl" in m["mediaData"])) {
            JSONValue n;
            ubyte[] nraw;
            if (chats.msg(account, sent["id"].str, n, nraw) && ("mediaData" in n)) {
                n["mediaData"]["renderableUrl"] = m["mediaData"]["renderableUrl"];
                n["mediaData"]["mediaStage"] = "RESOLVED";
                chats.updateMsg(n);
                sent = ingest.handOut(n);
                emit("Msg:change", sent);
            }
        }
        return sent;
    }

    /// lastKey: the chat's last message's time and key, for a message range (the Go core's lastKey).
    private long lastKey(string chatId, out MsgKey key, out bool hasKey) {
        import std.datetime.systime : Clock;
        JSONValue m;
        if (!chats.lastMsg(account, chatId, m)) return Clock.currTime.toUnixTime;
        // BuildMessageKey: fromMe when we sent it; the participant (without device) only for someone
        // else's message outside 1:1 chats (s.whatsapp.net / lid / msgr)
        key.remoteJid = chatId;
        key.id = m["msgId"].str;
        key.fromMe = m["fromMe"].type == JSONType.true_;
        const server = parseJidString(chatId).server;
        if (!key.fromMe && ("author" in m) && server != "s.whatsapp.net" && server != "lid" && server != "msgr") {
            auto a = parseJidString(m["author"].str);
            key.participant = Jid.pair(a.user, a.server).toString();
        }
        hasKey = true;
        return m["t"].integer;
    }

    /// fetchThumbnail (the Go core's): a link preview's large picture (DownloadThumbnail — whatsmeow
    /// only knows it for ExtendedTextMessage: thumbnail-link), else for a video of up to 20 MB the video
    /// itself and a frame of it (ffmpeg, on a worker). Images and documents only have their inline one.
    JSONValue fetchThumbnail(string key) {
        import std.file : write, mkdirRecurse, exists;
        import std.path : buildPath;
        import std.digest.sha : sha256Of;
        import std.digest : toHexString, LetterCase;
        import wa.model : unwrap;
        import wa.media : decryptMedia;
        import e2e = wa.pb.e2e;
        JSONValue m;
        ubyte[] raw;
        if (!chats.msg(account, key, m, raw)) throw new Exception("no message " ~ key);
        string jstr(JSONValue o, string k) { auto v = k in o; return v && v.type == JSONType.string ? v.str : ""; }
        bool jbool(JSONValue o, string k) { auto v = k in o; return v && v.type == JSONType.true_; }
        const dir = buildPath(cacheDir, "thumbs");
        mkdirRecurse(dir);
        const stem = toHexString!(LetterCase.lower)(sha256Of(account ~ key)[0 .. 12]).idup;
        // the stored message as it is now, with only `field` set (an edit or revoke meanwhile is kept)
        JSONValue settle(void delegate(ref JSONValue) set) {
            JSONValue cur;
            ubyte[] rawCur;
            if (!chats.msg(account, key, cur, rawCur)) throw new Exception("the message is gone: " ~ key);
            set(cur);
            chats.updateMsg(cur);
            auto out_ = ingest.handOut(cur);
            emit("Msg:change", out_);
            return out_;
        }
        if (jstr(m, "type") == "chat" && !jstr(m, "linkThumb").length && (jbool(m, "linkHQ") || jstr(m, "matchedText").length)) {
            if (raw.length == 0) throw new Exception("the original message is not stored");
            bool vo;
            auto e = ProtoReader(ProtoReader(unwrap(raw, vo)).get(e2e.Message.extendedTextMessage).bytes);
            const path = cast(string) e.get(e2e.ExtendedTextMessage.thumbnailDirectPath).bytes.idup;
            if (!path.length) return ingest.handOut(m);   // only the small inline picture
            auto enc = e.get(e2e.ExtendedTextMessage.thumbnailEncSHA256).bytes, sha = e.get(e2e.ExtendedTextMessage.thumbnailSHA256).bytes;
            auto mk = e.get(e2e.ExtendedTextMessage.mediaKey).bytes;
            ubyte[] data;
            try {
                auto file = downloadAs(path, enc, "thumbnail-link");
                data = enc.length && mk.length ? decryptMedia(file, mk, "WhatsApp Link Thumbnail Keys", enc, sha) : file;
            } catch (Exception ex) {
                logf("   link thumbnail: %s", ex.msg);
                return ingest.handOut(m);
            }
            const p = buildPath(dir, stem ~ "-link.jpg");
            write(p, data);
            const w = e.get(e2e.ExtendedTextMessage.thumbnailWidth).value, h = e.get(e2e.ExtendedTextMessage.thumbnailHeight).value;
            return settle((ref JSONValue cur) {
                cur["linkThumb"] = p;
                cur["linkHQ"] = true;
                if (w) cur["thumbWidth"] = w;
                if (h) cur["thumbHeight"] = h;
            });
        }
        if (!("mediaData" in m) || jstr(m["mediaData"], "thumbnailHQ").length) return ingest.handOut(m);
        // most videos carry only the ~100 px inline thumbnail: a short one is fetched whole (it opens
        // at once then) and an early frame of it becomes the thumbnail
        long size;
        if (auto sz = "size" in m["mediaData"]) size = sz.type == JSONType.integer ? sz.integer : 0;
        if (jstr(m, "type") != "video" || size > 20L << 20) return ingest.handOut(m);
        auto got = downloadMedia(key);
        if (!("mediaData" in got) || !jstr(got["mediaData"], "renderableUrl").length) return got;
        const frame = buildPath(dir, stem ~ "-frame.jpg");
        auto r = execOff(["ffmpeg", "-loglevel", "error", "-y", "-ss", "0.3", "-i", got["mediaData"]["renderableUrl"].str,
            "-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "3", frame]);
        if (r.status != 0 || !exists(frame)) return got;
        return settle((ref JSONValue cur) { if ("mediaData" in cur) cur["mediaData"]["thumbnailHQ"] = frame; });
    }

    /// Newsletter.refresh (the Go core's refreshChannel; whatsmeow GetNewsletterMessages): the channel's
    /// last 50 messages from its server — new ones stored, every one with its reaction counts, views
    /// and forwards — then the chat's window from the store
    JSONValue refreshChannel(string id) {
        import std.algorithm : sort;
        import std.conv : to;
        import wa.model : content, envelope;
        auto c = conn;
        if (c is null) throw new Exception("not connected");
        auto j = parseJidString(id);
        auto iq = node("iq", [["id", c.nextId()], ["type", "get"], ["xmlns", "newsletter"], ["to", "s.whatsapp.net"]]);
        iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
        iq.attr("to").isJid = true;
        auto ms = node("messages", [["type", "jid"], ["jid", id], ["count", "50"]]);
        ms.attr("jid").jid = Jid.pair(j.user, j.server);
        ms.attr("jid").isJid = true;
        iq.children ~= ms;
        auto r = c.sendIQ(iq);
        const list = r.child("messages");
        if (r.get("type") != "result" || list is null) throw new Exception("newsletter messages: no <messages> in the answer");
        foreach (ref mn; list.children) {
            if (mn.tag != "message") continue;
            const msgId = mn.get("id");
            JSONValue m;
            bool have = chats.msgByID(account, id, msgId, m);
            if (!have) {
                const pt = mn.child("plaintext");
                if (pt is null || !pt.hasBytes) continue;
                JSONValue n;
                if (!content(pt.bytes, n)) continue;
                long t;
                try t = mn.get("t").to!long; catch (Exception) {}
                envelope(n, account, msgId, false, t, "", id, id);
                chats.putMsg(n, pt.bytes);
                chats.bumpChat(n, false, false);
                m = n;
                have = true;
            }
            JSONValue[] reacts;
            if (const rs = mn.child("reactions")) foreach (ref rc; rs.children) {
                long count;
                try count = rc.get("count").to!long; catch (Exception) {}
                if (count > 0) reacts ~= JSONValue(["emoji": JSONValue(rc.get("code")), "count": JSONValue(count)]);
            }
            reacts.sort!((a, b) => a["count"].integer > b["count"].integer);
            if (reacts.length) m["newsletterReactions"] = reacts; else if ("newsletterReactions" in m) m.object.remove("newsletterReactions");
            foreach (tag, field; ["views_count": "viewsCount", "forwards_count": "forwardsCount"])
                if (const cn = mn.child(tag)) { try m[field] = cn.get("count").to!long; catch (Exception) {} }
            chats.updateMsg(m);
        }
        JSONValue[] out_;
        foreach (m; chats.msgs(account, id, 0, 80)) out_ ~= ingest.handOut(m);
        ingest.emitChat(id);
        return out_.length ? JSONValue(out_) : parseJSON("[]");
    }

    /// sendDelete (the Go core's): the chat deleted on every device (BuildDeleteChat up to its last
    /// message), its messages gone here, the chat dropped from the list
    JSONValue deleteChat(string chatId) {
        import wa.appstate_send : buildDeleteChat;
        import std.datetime.systime : Clock;
        MsgKey k;
        bool has;
        const t = lastKey(chatId, k, has);
        auto info = buildDeleteChat(chatId, t, has ? &k : null, false);
        const synced = trySendAppState(info, "chat delete");
        ingest.cleared(chatId, Clock.currTime.toUnixTime, false);
        chats.setChat(account, chatId, "deleted", true);
        emit("Chat:remove", JSONValue(["account": JSONValue(account), "id": JSONValue(chatId)]));
        return JSONValue(["synced": JSONValue(synced)]);
    }

    /// setArchive (WAWebSetArchiveChatAction): archiving also unpins.
    void setArchive(string chatId, bool archive) {
        import wa.appstate_send : buildArchive;
        MsgKey k;
        bool has;
        const t = lastKey(chatId, k, has);
        auto info = buildArchive(chatId, archive, t, has ? &k : null);
        sendAppState(info);
        chats.setChat(account, chatId, "archive", archive);
        if (archive) chats.setChat(account, chatId, "pin", 0L);
        ingest.emitChat(chatId);
    }

    /// setPin (WAWebChatPinBridge.setPin): at most 3 pinned chats.
    void setPin(string chatId, bool pin) {
        import std.datetime.systime : Clock;
        import wa.appstate_send : buildPin;
        if (pin) {
            size_t n;
            foreach (c; chats.chats(account)) if (c["pin"].integer > 0 && c["id"].str != chatId) n++;
            if (n >= 3) throw new Exception("só dá para fixar 3 conversas");
        }
        auto info = buildPin(chatId, pin);
        sendAppState(info);
        chats.setChat(account, chatId, "pin", pin ? Clock.currTime.toUnixTime : 0L);
        ingest.emitChat(chatId);
    }

    /// sendConversationMute: expiration 0 = unmute, < 0 = forever, else until that time (seconds).
    /// Like sendStatusMute, it holds here even when the sync fails (regular_high, see there): {synced}.
    JSONValue sendConversationMute(string chatId, long expiration) {
        import wa.appstate_send : buildMute;
        chats.setChat(account, chatId, "muteExpiration", expiration);
        ingest.emitChat(chatId);
        auto info = expiration == 0 ? buildMute(chatId, false, 0)
            : buildMute(chatId, true, expiration < 0 ? -1 : expiration * 1000);
        return JSONValue(["synced": JSONValue(trySendAppState(info, "chat mute"))]);
    }

    /// sendStatusMute (the Go core's): mute / unmute someone's status updates. The mute holds here even when the sync fails: an account whose regular_high copy on the server
    /// no longer matches its own MAC (seen: the snapshot's LTHash, recomputed with whatsmeow too, does not
    /// give the MAC the server holds) cannot take patches — WhatsApp's way out of that logs every
    /// companion out. Returns {synced}: whether the phone and the other devices got it.
    JSONValue sendStatusMute(string id, bool muted) {
        import wa.appstate_send : buildUserStatusMute;
        chats.setStatusMuted(account, id, muted);
        emit("Status:change", JSONValue(["account": JSONValue(account), "id": JSONValue(id)]));
        auto j = parseJidString(id);
        auto info = buildUserStatusMute(Jid.pair(j.user, j.server).toString(), muted);
        return JSONValue(["synced": JSONValue(trySendAppState(info, "status mute"))]);
    }

    /// "Adicionar aos favoritos" / "Remover dos favoritos" on a sticker (WAWebFavoriteStickerAction).
    void setFavoriteSticker(string key, bool favorite) {
        import std.base64 : Base64;
        import std.datetime.systime : Clock;
        import wa.model : unwrap;
        import wa.appstate_send : buildFavoriteSticker;
        import e2e = wa.pb.e2e;
        JSONValue m;
        ubyte[] raw;
        if (!chats.msg(account, key, m, raw) || raw.length == 0) throw new Exception("sticker not stored");
        bool vo;
        auto st = ProtoReader(ProtoReader(unwrap(raw, vo)).get(e2e.Message.stickerMessage).bytes);
        alias S = e2e.StickerMessage;
        const sha = st.get(S.fileSHA256).bytes;
        if (sha.length == 0) throw new Exception("not a sticker");
        const mimetype = cast(string) st.get(S.mimetype).bytes.idup;
        if (mimetype == "application/was") throw new Exception("Lottie stickers cannot be favorited here");
        const filehash = cast(string) Base64.encode(sha);
        ushort devNo;
        {
            import std.string : indexOf;
            import std.conv : to;
            const at = dev.jid.indexOf('@'), colon = dev.jid.indexOf(':');
            if (colon > 0 && at > colon) try devNo = dev.jid[colon + 1 .. at].to!ushort; catch (Exception) {}
        }
        auto info = buildFavoriteSticker(filehash, st.get(S.fileEncSHA256).bytes, st.get(S.mediaKey).bytes, mimetype,
            cast(uint) st.get(S.height).value, cast(uint) st.get(S.width).value,
            cast(string) st.get(S.directPath).bytes.idup, favorite, devNo);
        sendAppState(info);
        chats.setFavSticker(account, filehash, favorite, Clock.currTime.toUnixTime * 1000);
        emit("Msg:change", ingest.handOut(m));
    }

    /// markUnread (WAWebUpdateUnreadChatAction.markUnread) / markRead.
    void markChatRead(string chatId, bool read) {
        import wa.appstate_send : buildMarkChatAsRead;
        MsgKey k;
        bool has;
        const t = lastKey(chatId, k, has);
        auto info = buildMarkChatAsRead(chatId, read, t, has ? &k : null);
        sendAppState(info);
        chats.setChat(account, chatId, "markedUnread", !read);
        ingest.emitChat(chatId);
    }
}

/// The client's side of wa.send.Connection: IQ results are handed over by the stanza loop.
final class ClientConn : Connection {
    NoiseSocket sock;
    bool[string] waiting;
    Node[string] results;
    uint counter;
    string prefix;      // whatsmeow uniqueID: "<random byte>.<random byte>-"
    this(NoiseSocket s) {
        import wa.crypto : randomBytes;
        import std.conv : to;
        sock = s;
        auto r = randomBytes(2);
        prefix = r[0].to!string ~ "." ~ r[1].to!string ~ "-";
    }
    string nextId() { import std.conv : to; return prefix ~ (++counter).to!string; }
    void sendNode(Node n) { sock.send(encodeStanza(n)); }
    Node sendIQ(Node iq) { import core.time : seconds; return sendIQ(iq, 20.seconds); }
    void expectAck(string id) { waiting[id] = true; }
    /// The <ack> for a stanza we sent (the stanza loop hands it over by id).
    Node waitAck(string id, Duration timeout) {
        import vibe.core.core : sleep;
        import core.time : msecs, MonoTime;
        waiting[id] = true;
        scope (exit) waiting.remove(id);
        const deadline = MonoTime.currTime + timeout;
        while (MonoTime.currTime < deadline) {
            if (auto r = id in results) { auto n = *r; results.remove(id); return n; }
            sleep(50.msecs);
        }
        throw new Exception("no ack for " ~ id);
    }
    Node sendIQ(Node iq, Duration timeout) {
        import vibe.core.core : sleep;
        import core.time : msecs, MonoTime;
        const id = iq.get("id");
        waiting[id] = true;
        scope (exit) waiting.remove(id);
        sock.send(encodeStanza(iq));
        const deadline = MonoTime.currTime + timeout;
        while (MonoTime.currTime < deadline) {
            if (auto r = id in results) { auto n = *r; results.remove(id); return n; }
            sleep(50.msecs);
        }
        throw new Exception("IQ " ~ id ~ " timed out");
    }
}

/// Mask all but the first three digits of a user id for the log (we don't print full numbers).
string maskTail(string user) {
    if (user.length <= 3) return user;
    return user[0 .. 3] ~ "***";
}


/// mime.TypeByExtension: the system's /etc/mime.types, else a small built-in table;
/// application/octet-stream when unknown.

/// std.process.execute on a worker thread: an ffmpeg/ffprobe run must not stall the core's event
/// loop (one thread) — sending a long voice note used to freeze every other request meanwhile.
struct ProcOut { int status; string output; }

/// The environment for the system's tools we run (ffmpeg, ffprobe): inside the AppImage, our
/// LD_LIBRARY_PATH points at the bundled libraries, which a system program must not load — AppRun
/// keeps the original in QWHATS_ORIG_LD_LIBRARY_PATH ("__unset__": there was none). Outside it: as is.
string[string] toolEnv() {
    import std.process : environment;
    auto env = environment.toAA();
    if (auto orig = "QWHATS_ORIG_LD_LIBRARY_PATH" in env) {
        if (*orig == "__unset__") env.remove("LD_LIBRARY_PATH");
        else env["LD_LIBRARY_PATH"] = *orig;
    }
    return env;
}

ProcOut execOff(string[] args) {
    import vibe.core.concurrency : async, isWeaklyIsolated;
    static ProcOut run(immutable(string)[] a) {
        import std.process : execute, Config;
        auto r = execute(a, toolEnv(), Config.newEnv);
        return ProcOut(r.status, r.output);
    }
    static assert(isWeaklyIsolated!(typeof(&run)), "execOff must run on a worker thread");
    return async(&run, args.idup).getResult();
}

string mimeTypeOf(string path) {
    import std.path : extension;
    import std.string : toLower, split, strip;
    import std.file : exists, readText;
    const ext = extension(path).toLower;
    if (ext.length < 2) return "application/octet-stream";
    static immutable string[string] builtin = [".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
        ".webp": "image/webp", ".gif": "image/gif", ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime",
        ".ogg": "audio/ogg", ".opus": "audio/ogg", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac",
        ".pdf": "application/pdf", ".txt": "text/plain; charset=utf-8", ".zip": "application/zip"];
    if (exists("/etc/mime.types"))
        try foreach (line; readText("/etc/mime.types").split("\n")) {
            auto l = line.strip;
            if (l.length == 0 || l[0] == '#') continue;
            auto parts = l.split;
            foreach (e; parts[1 .. $]) if ("." ~ e == ext) return parts[0];
        } catch (Exception) {}
    if (auto t = ext in builtin) return *t;
    return "application/octet-stream";
}

/// pictureInfo (the Go core's): the picture's size and a 72-px-wide JPEG thumbnail (via ffprobe/ffmpeg).
void pictureInfo(string path, out uint w, out uint h, out ubyte[] thumb) {
    import std.process : execute;
    import std.string : strip, split;
    import std.conv : to;
    try {
        auto p = execOff(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
            "-of", "csv=p=0:s=x", path]);
        if (p.status == 0) {
            auto wh = p.output.strip.split("x");
            if (wh.length >= 2) { w = wh[0].to!uint; h = wh[1].strip.to!uint; }
        }
        auto t = execOff(["ffmpeg", "-v", "error", "-i", path, "-vf", "scale=72:-1", "-frames:v", "1", "-q:v", "8",
            "-f", "image2", "-c:v", "mjpeg", "pipe:1"]);
        if (t.status == 0 && t.output.length) thumb = cast(ubyte[]) t.output.dup;
    } catch (Exception) {}
}

/// waveformOf (the Go core's): 64 RMS levels 0..100 of the audio, normalised to its peak.
/// A voice note's 64-bar waveform (0..100). Decoded and measured entirely on a worker thread, the PCM
/// streamed in 0.1 s blocks at 8 kHz (RMS, as the Go core's waveformOf): a two-hour note no longer holds its whole
/// decoded audio, nor runs millions of samples on the event loop.
ubyte[] waveformOf(string path) {
    import vibe.core.concurrency : async, isWeaklyIsolated;
    static immutable(ubyte)[] work(immutable(string) path) {
        import std.process : pipeProcess, Redirect, wait, Config;
        import std.math : sqrt, round;
        double[] blocks;              // mean energy of every 800 samples (0.1 s at 8 kHz)
        double acc = 0;
        size_t cnt;
        int carry = -1;               // a sample split across two chunks
        try {
            auto pp = pipeProcess(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", "8000",
                "-f", "s16le", "pipe:1"], Redirect.stdout, toolEnv(), Config.newEnv);
            foreach (chunk; pp.stdout.byChunk(8192)) {
                size_t i;
                if (carry >= 0 && chunk.length) {
                    const v = cast(double) cast(short)(carry | (chunk[0] << 8));
                    acc += v * v; cnt++; carry = -1; i = 1;
                }
                for (; i + 1 < chunk.length; i += 2) {
                    const v = cast(double) cast(short)(chunk[i] | (chunk[i + 1] << 8));
                    acc += v * v;
                    if (++cnt == 800) { blocks ~= acc / cnt; acc = 0; cnt = 0; }
                }
                if (i < chunk.length) carry = chunk[i];
            }
            if (wait(pp.pid) != 0) return null;
        } catch (Exception) return null;
        if (cnt) blocks ~= acc / cnt;
        if (blocks.length < 2) return null;
        double[64] vals = 0;
        double peak = 0;
        foreach (b; 0 .. 64) {
            const from = b * blocks.length / 64, to = (b + 1) * blocks.length / 64;
            double sum = 0;
            foreach (k; from .. to) sum += blocks[k];
            if (to > from) vals[b] = sqrt(sum / (to - from));
            if (vals[b] > peak) peak = vals[b];
        }
        auto wf = new ubyte[64];
        foreach (b; 0 .. 64) if (peak > 0) wf[b] = cast(ubyte) round(100 * vals[b] / peak);
        return cast(immutable) wf;
    }
    static assert(isWeaklyIsolated!(typeof(&work)), "the waveform must be measured on a worker");
    try return async(&work, path).getResult().dup;
    catch (Exception) return null;
}

/// A sticker file's pack (the WebP's EXIF JSON: sticker-pack-id / -name / -publisher, as WhatsApp's
/// sticker apps write it); false when the file carries none.
bool stickerPackOf(const(ubyte)[] file, out string id, out string name, out string publisher) {
    import std.json : parseJSON, JSONType;
    import std.string : indexOf;
    const s = cast(const(char)[]) file;
    auto i = s.indexOf(`{"sticker-pack-id"`);
    if (i < 0) {
        const k = s.indexOf("sticker-pack-id");
        if (k < 0) return false;
        foreach_reverse (j; 0 .. k) if (s[j] == '{') { i = j; break; }
        if (i < 0) return false;
    }
    int depth;
    size_t end;
    bool inStr, esc;
    foreach (j; cast(size_t) i .. s.length) {
        const c = s[j];
        if (inStr) { if (esc) esc = false; else if (c == '\\') esc = true; else if (c == '"') inStr = false; continue; }
        if (c == '"') inStr = true;
        else if (c == '{') depth++;
        else if (c == '}' && --depth == 0) { end = j + 1; break; }
    }
    if (end == 0) return false;
    try {
        auto o = parseJSON(s[i .. end]);
        string g(string k) { auto v = k in o; return v !is null && v.type == JSONType.string ? v.str : ""; }
        id = g("sticker-pack-id");
        name = g("sticker-pack-name");
        publisher = g("sticker-pack-publisher");
        return id.length > 0;
    } catch (Exception) return false;
}

unittest {
    string id, name, pub;
    auto f = cast(const(ubyte)[]) "RIFF....WEBPVP8X....EXIF..II*.\x00\x00{\"sticker-pack-id\":\"abc.123\",\"sticker-pack-name\":\"Gatos {fofos}\",\"sticker-pack-publisher\":\"Ana\",\"emojis\":[\"🐱\"]}\x00\x00";
    assert(stickerPackOf(f, id, name, pub) && id == "abc.123" && name == "Gatos {fofos}" && pub == "Ana");
    assert(!stickerPackOf(cast(const(ubyte)[]) "RIFF....WEBPVP8 ", id, name, pub));
}
