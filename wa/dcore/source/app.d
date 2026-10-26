// qwhats-dcore: the D replacement for qwhats-core (core/main.go). Same contract: JSON-RPC 2.0 on
// stdio, one object per line — requests from the app on stdin, responses and collection events
// (notifications, no "id") on stdout; diagnostics on stderr. When stdin closes, it exits.
//
// This first cut serves the READ side (chats, messages, contacts, search) from wa.app's chat store
// and keeps the account connected (receiving only). Methods that would send something answer
// "not implemented" until each one is checked against whatsmeow.
//
//	qwhats-dcore --data ~/.local/share/qml-whats/dcore [--store DEVICE.DB] [--chats CHATS.DB]
import std.stdio;
import std.json;
import std.conv : to;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import vibe.core.core : runTask, runEventLoop, exitEventLoop, sleep;
import core.time : msecs;
import wa.store.db : Store;
import wa.store.sql : Db;
import wa.app.chatstore : ChatStore, formatPhone;
import wa.app.client : Client, clientLog;
import wa.app.views : Views;
import sms : SmsBridge;
import recorder : Recorder;
import applock : AppLock;

__gshared Mutex inMu;
__gshared string[] inbox;     // request lines from the stdin thread
__gshared bool inClosed;

Client client;
Views views;
ChatStore chats;
SmsBridge smsBridge;
Recorder rec;
AppLock appLock;

void write(JSONValue v) {
    try { stdout.writeln(v.toString()); stdout.flush(); } catch (Exception) {}
}

void emit(string method, JSONValue params) {
    JSONValue o = ["jsonrpc": JSONValue("2.0"), "method": JSONValue(method), "params": params];
    write(o);
}

void reply(JSONValue id, JSONValue result, string error) {
    if (id.type == JSONType.null_) return;   // a notification from the app: no answer
    JSONValue o = ["jsonrpc": JSONValue("2.0"), "id": id];
    if (error.length) o["error"] = JSONValue(["code": JSONValue(-32_000), "message": JSONValue(error)]);
    else o["result"] = result;
    write(o);
}

string ps(JSONValue p, string k) { auto v = k in p; return v is null || v.type != JSONType.string ? "" : v.str; }
long pi(JSONValue p, string k) {
    auto v = k in p;
    if (v is null) return 0;
    return v.type == JSONType.integer ? v.integer : v.type == JSONType.uinteger ? cast(long) v.uinteger
        : v.type == JSONType.float_ ? cast(long) v.floating : 0;
}

bool pb(JSONValue p, string k) { auto v = k in p; return v !is null && v.type == JSONType.true_; }

string[] strs(JSONValue p, string k) {
    string[] out_;
    if (auto v = k in p) if (v.type == JSONType.array) foreach (x; v.array) if (x.type == JSONType.string) out_ ~= x.str;
    return out_;
}

JSONValue arr(JSONValue[] a) { return a.length ? JSONValue(a) : parseJSON("[]"); }

JSONValue accountList() {
    JSONValue e = ["id": JSONValue("main"), "state": JSONValue(client.state), "me": JSONValue(client.me())];
    const pn = ps(chats.contact("main", client.me()), "pushname");
    if (pn.length) e["pushname"] = pn;
    return JSONValue([e]);
}

/// 1:1 chats WhatsApp moved from the phone number to the contact's LID, as earlier builds stored
/// them: the number's chat carried the history's read-only mark (the phone keeps the old one locked),
/// and messages that came before the pair was known sit under a "…@lid" chat nobody sees (the list
/// shows the number's). The chat is one, by number: unlocked, and each LID chat folded into it.
void repairLidTwins(Store store) {
    string[] unlock;
    string[2][] twins;
    foreach (ref r; chats.db.query(`SELECT id FROM chats WHERE account='main' AND isReadOnly=1 AND id LIKE '%@s.whatsapp.net'`)) {
        const id = r.text(0);
        if (store.lidForPN(id[0 .. $ - "@s.whatsapp.net".length]).length) unlock ~= id;
    }
    foreach (ref r; chats.db.query(`SELECT id FROM chats WHERE account='main' AND id LIKE '%@lid'`)) {
        const id = r.text(0);
        const pn = store.pnForLID(id[0 .. $ - "@lid".length]);
        if (pn.length) twins ~= [id, pn ~ "@s.whatsapp.net"];
    }
    foreach (id; unlock) chats.setChat("main", id, "isReadOnly", false);
    size_t moved;
    foreach (t; twins) {
        try moved += chats.mergeLidChat("main", t[0], t[1]);
        catch (Exception e) stderr.writeln("qwhats-dcore: merging a LID chat: ", e.msg);
    }
    if (unlock.length || twins.length)
        stderr.writefln("qwhats-dcore: LID twins: %d chat(s) unlocked, %d LID chat(s) folded in (%d message(s) moved)",
            unlock.length, twins.length, moved);
}

/// openChat (the Go core's): a chat for this id even before it has messages, announced.
JSONValue openChat(string id) {
    chats.ensureChat("main", id);
    JSONValue c;
    chats.chat("main", id, c);
    auto full = views.fullChat(c);
    emit("Chat:change", full);
    return full;
}

/// Community.view (the Go core's communityView): the announcements group ("Avisos") on top, the
/// groups we are in, and the ones we may join with their member counts, the biggest first.
JSONValue communityView(string id) {
    import std.algorithm : sort;
    const acc = "main";
    if (id.length == 0) throw new Exception("missing parameter");
    JSONValue v = ["id": JSONValue(id), "name": JSONValue(views.chatName(id)), "joined": parseJSON("[]"),
        "available": parseJSON("[]")];
    const pic = client.communityPic(id);
    if (pic.length) v["pic"] = pic;
    JSONValue[] joined, available;
    foreach (s; client.subGroups(id)) {
        const sid = s.jid.toString();
        if (s.isDefault || client.inGroup(sid)) {
            chats.ensureChat(acc, sid);
            chats.setChatName(acc, sid, s.name);
            JSONValue c;
            chats.chat(acc, sid, c);
            auto fc = views.fullChat(c);
            if (s.isDefault) { fc["name"] = "Avisos"; v["announce"] = fc; }
            else joined ~= fc;
            continue;
        }
        available ~= JSONValue(["id": JSONValue(sid), "name": JSONValue(s.name)]);
    }
    // their member counts, four questions in flight at a time (as the Go core)
    {
        import vibe.core.core : runTask, Task;
        auto sizes = new long[available.length];
        for (size_t i = 0; i < available.length; i += 4) {
            Task[] batch;
            foreach (k; i .. (i + 4 < available.length ? i + 4 : available.length))
                batch ~= runTask((size_t k, string sid) nothrow {
                    try sizes[k] = client.linkedGroupSize(id, sid); catch (Exception) {}
                }, k, available[k]["id"].str);
            foreach (t; batch) t.join();
        }
        foreach (k, ref a; available) if (sizes[k] > 0) a["size"] = sizes[k];
    }
    available.sort!((a, b) => ("size" in a ? a["size"].integer : 0) > ("size" in b ? b["size"].integer : 0));
    if (joined.length) v["joined"] = joined;
    if (available.length) v["available"] = available;
    return v;
}

/// handle: one request → (result, error).
JSONValue handle(string method, JSONValue p, out string error) {
    const acc = "main";
    // an SMS thread ("sms:…") never reaches WhatsApp's side: sent there, it would be stored as a
    // chat that does not exist (an image to "sms:402" did — then a ghost chat nobody could remove)
    {
        import std.algorithm : startsWith, any;
        if (!method.startsWith("Sms.") && method != "downloadMedia") {
            bool smsId(JSONValue v) { return v.type == JSONType.string && v.str.startsWith("sms:"); }
            foreach (k, v; p.object) {
                if (smsId(v) || (v.type == JSONType.array && v.array.any!(x => smsId(x)))) {
                    error = method ~ ": an SMS thread goes through Sms.* (" ~ k ~ ")";
                    return JSONValue(null);
                }
            }
        }
    }
    switch (method) {
        case "ping": return JSONValue("pong");
        case "account.list": return accountList();
        case "getState": return JSONValue(["state": JSONValue(client.state)]);
        case "connect":
            client.connect();
            return JSONValue(["state": JSONValue(client.state)]);
        case "Chat.list": return arr(views.chatList());
        case "Chat.get":
            JSONValue c;
            if (!chats.chat(acc, ps(p, "id"), c)) { error = "no chat " ~ ps(p, "id"); return JSONValue(null); }
            return views.fullChat(c);
        case "Msg.list":
            auto list = ps(p, "afterId").length
                ? views.msgListAfter(ps(p, "chat"), ps(p, "afterId"), cast(int) pi(p, "limit"))
                : views.msgList(ps(p, "chat"), pi(p, "before"), cast(int) pi(p, "limit"), ps(p, "throughId"));
            {
                import std.algorithm : endsWith;
                if (ps(p, "chat").endsWith("@g.us")) {
                    string[] authors;
                    foreach (m; list) if (("author" in m) && ("fromMe" !in m || m["fromMe"].type != JSONType.true_)) authors ~= m["author"].str;
                    client.fetchAuthorPics(authors);
                }
            }
            return arr(list);
        case "Msg.search": return arr(views.search(ps(p, "query"), ps(p, "chat"), cast(int) pi(p, "limit")));
        case "Search.run": return views.searchRun(ps(p, "query"), ps(p, "chat"), cast(int) pi(p, "limit"));
        case "Contact.get": return chats.contact(acc, ps(p, "id"));
        case "Contact.list":
            // the address book: pictures of the people without a chat yet, in the background
            auto cl = views.contactList();
            string[] ids;
            foreach (k; cl) if ("id" in k) ids ~= k["id"].str;
            client.fetchAuthorPics(ids);
            return arr(cl);
        case "profilePicFull": return client.profilePicFull(ps(p, "id"));
        case "loadEarlierMsgs": return client.loadEarlierMsgs(ps(p, "chat"), pi(p, "before"), cast(int) pi(p, "limit"), ps(p, "beforeId"));
        case "GroupMetadata.get":
            JSONValue g;
            if (!chats.group(acc, ps(p, "id"), g)) g = client.sendQueryGroup(ps(p, "id"));
            return views.namedGroup(g);
        case "sendQueryGroup":
            return client.sendQueryGroup(ps(p, "id"));
        case "Msg.starred":
            JSONValue[] out_;
            int limit = cast(int) pi(p, "limit");
            if (limit <= 0) limit = 200;
            foreach (ref r; chats.db.query(`SELECT json FROM msgs WHERE account=? AND star=1 ORDER BY t DESC LIMIT ?`, acc, limit))
                try out_ ~= client.ingest.handOut(parseJSON(r.text(0))); catch (Exception) {}
            return arr(out_);
        case "Profile.get":
            const me = client.me();
            const user = me[0 .. me.length - "@s.whatsapp.net".length];
            JSONValue pr = ["id": JSONValue(me), "pushname": JSONValue(ps(chats.contact(acc, me), "pushname")),
                "phoneNumber": JSONValue(formatPhone(user))];
            // our picture (fetchPictures asks for it first; ask now if it is not here yet)
            auto k = chats.contact(acc, me);
            string pic = ps(k, "profilePicThumb");
            if (pic.length == 0) try pic = ps(client.requestProfilePic(me), "profilePicThumb"); catch (Exception) {}
            if (pic.length && pic != "-") pr["profilePicThumb"] = pic;
            string about = ps(k, "status");
            if (about.length == 0) try about = ps(client.getStatus(me), "status"); catch (Exception) {}
            if (about.length) pr["status"] = about;
            return pr;
        case "openChat":
            const id = ps(p, "id");
            if (id.length == 0) { error = "missing parameter"; return JSONValue(null); }
            return openChat(id);
        case "updateDraftMessageChat":
            chats.setChat(acc, ps(p, "chat"), "draftMessage", ps(p, "draft"));
            return JSONValue(true);
        case "sendSeen":
            client.sendSeen(ps(p, "chat"));
            return JSONValue(true);
        case "requestProfilePicFromServer":
            return client.requestProfilePic(ps(p, "id"));
        case "sendTextMsgToChat":
            string[] mentions;
            if (auto ml = "mentionedJidList" in p) if (ml.type == JSONType.array) foreach (x; ml.array) mentions ~= x.str;
            if (ps(p, "chat").length == 0 || ps(p, "text").length == 0) { error = "missing parameter"; return JSONValue(null); }
            return client.sendText(ps(p, "chat"), ps(p, "text"), ps(p, "quotedMsg"), mentions);
        case "sendStatusMute":
            client.sendStatusMute(ps(p, "id"), pb(p, "muted"));
            return JSONValue(true);
        case "forwardMessages":
            string[] msgs, targets;
            if (auto a = "msgs" in p) if (a.type == JSONType.array) foreach (x; a.array) msgs ~= x.str;
            if (auto a = "chats" in p) if (a.type == JSONType.array) foreach (x; a.array) targets ~= x.str;
            return client.forwardMessages(msgs, targets);
        case "saveMedia":
            return client.saveMedia(ps(p, "msg"), ps(p, "path"));
        case "setAbout":
            return client.setAbout(ps(p, "text"));
        case "setProfilePicture":
            return client.setProfilePicture(ps(p, "path"));
        case "getStatus":
            return client.getStatus(ps(p, "id"));
        case "StickerPack.info": return client.stickerPackInfo(ps(p, "msg"));
        case "StickerPack.add": return client.addStickerPack(ps(p, "msg"), ps(p, "name"));
        case "StickerPack.addTo": return client.addStickerTo(ps(p, "msg"), ps(p, "pack"));
        case "StickerPack.list": return client.stickerPacks();
        case "StickerStore.list": return client.stickerStore();
        case "StickerPack.addStore": return client.addStorePack(ps(p, "id"), ps(p, "name"));
        case "StickerPack.rename":
            client.renameStickerPack(ps(p, "id"), ps(p, "name"));
            return JSONValue(true);
        case "StickerPack.remove":
            client.removeStickerPack(ps(p, "id"));
            return JSONValue(true);
        case "sendSticker":
            return client.sendSticker(ps(p, "chat"), ps(p, "msg"));
        case "Channel.list":
            return client.channels();
        case "setFavoriteSticker":
            client.setFavoriteSticker(ps(p, "msg"), pb(p, "favorite"));
            return JSONValue(true);
        case "sendStatusSeen":
            client.sendStatusSeen(ps(p, "msg"));
            return JSONValue(true);
        case "sendMediaMsgToChat":
            if (ps(p, "chat").length == 0 || ps(p, "path").length == 0) { error = "missing parameter"; return JSONValue(null); }
            return client.sendMedia(ps(p, "chat"), ps(p, "path"), ps(p, "caption"), ps(p, "quotedMsg"),
                pb(p, "asPtt"), pb(p, "asDocument"), pi(p, "seconds"));
        case "downloadMedia":
            {
                import std.algorithm : startsWith;
                if (ps(p, "msg").startsWith("sms:")) return smsBridge.downloadMedia(ps(p, "msg"));
            }
            return client.downloadMedia(ps(p, "msg"));
        case "setArchive":
            client.setArchive(ps(p, "chat"), pb(p, "archive"));
            return JSONValue(true);
        case "setPin":
            client.setPin(ps(p, "chat"), pb(p, "pin"));
            return JSONValue(true);
        case "sendConversationMute":
            client.sendConversationMute(ps(p, "chat"), pi(p, "expiration"));
            return JSONValue(true);
        case "markUnread":
            client.markChatRead(ps(p, "chat"), false);
            return JSONValue(true);
        // panels not ported yet: empty, so the UI still opens them
        case "Status.list": return arr(views.statusList());
        case "Sticker.list": return client.stickerList(cast(int) pi(p, "limit"));
        case "Msg.byType":
            {
                string[] types;
                if (auto t = "types" in p) foreach (x; t.array) types ~= x.str;
                return arr(views.panelMsgs(chats.msgsByType(acc, types, cast(int) pi(p, "limit"))));
            }
        case "Msg.links": return arr(views.panelMsgs(chats.linkMsgs(acc, cast(int) pi(p, "limit"))));
        case "Community.list":
            return arr(views.communities((string id) {
                auto g = client.sendQueryGroup(id);
                return ("subject" in g) && g["subject"].type == JSONType.string ? g["subject"].str : "";
            }));
        case "Community.view": return communityView(ps(p, "id"));
        case "joinCommunityGroup":
            {
                const sub = ps(p, "chat");
                if (ps(p, "id").length == 0 || sub.length == 0) { error = "missing parameter"; return JSONValue(null); }
                client.joinCommunityGroup(ps(p, "id"), sub);
                return openChat(sub);
            }
        case "createGroup":
            {
                auto g = client.createGroup(ps(p, "name"), strs(p, "participants"));
                const id = ps(g, "id");
                if (id.length == 0) { error = "group created, but its id is unknown"; return JSONValue(null); }
                return openChat(id);
            }
        case "logout": client.logout(); return JSONValue(true);
        case "pairPhone": return JSONValue(["code": JSONValue(client.pairPhone(ps(p, "phone")))]);
        // the app lock (core/extras.go: an scrypt hash in <data>/applock.json)
        case "AppLock.status": return JSONValue(["enabled": JSONValue(appLock.enabled())]);
        case "AppLock.set": appLock.set(ps(p, "password")); return JSONValue(true);
        case "AppLock.check": return JSONValue(["ok": JSONValue(appLock.check(ps(p, "password")))]);
        case "AppLock.clear": appLock.clear(ps(p, "password")); return JSONValue(true);
        // SMS through KDE Connect (opt-in: the app sends Sms.enable when its setting is on)
        case "Sms.enable": return smsBridge.enable(pb(p, "on"));
        case "Sms.status": return smsBridge.status();
        case "Sms.threads": return smsBridge.threads();
        case "Sms.messages": return smsBridge.messages(p);
        case "Sms.send": return smsBridge.send(p);
        case "Sms.attachment": return smsBridge.attachment(p);
        case "Sms.markRead": return smsBridge.markRead(p);
        // the message menu (core/actions.go, core/extras.go)
        case "sendReactionToMsg": client.sendReaction(ps(p, "msg"), ps(p, "reactionText")); return JSONValue(true);
        case "sendRevoke": client.sendRevoke(strs(p, "msgs")); return JSONValue(true);
        case "editMessage": client.editMessage(ps(p, "msg"), ps(p, "text")); return JSONValue(true);
        case "sendStarMsgs": client.sendStarMsgs(strs(p, "msgs"), pb(p, "star")); return JSONValue(true);
        case "sendDeleteMsgs": client.sendDeleteMsgs(strs(p, "msgs"), pb(p, "deleteMedia")); return JSONValue(true);
        case "sendPinInChat": client.sendPinInChat(ps(p, "msg"), pb(p, "pin"), pi(p, "seconds")); return JSONValue(true);
        case "markPlayed": client.markPlayed(ps(p, "msg")); return JSONValue(true);
        case "subscribeUserPresence": client.subscribePresence(ps(p, "id")); return JSONValue(true);
        case "sendDelete": client.deleteChat(ps(p, "chat")); return JSONValue(true);
        case "fetchThumbnail": return client.fetchThumbnail(ps(p, "msg"));
        case "Newsletter.refresh": return client.refreshChannel(ps(p, "id"));
        // voice notes (core/recorder.go)
        case "startRecording": return rec.start(!("denoise" in p) || pb(p, "denoise"), ps(p, "denoiseModel"));
        case "stopRecording": return rec.stop(pb(p, "send"));
        case "Sms.contacts": return smsBridge.contactList();
        case "Sms.leave": smsBridge.leave(); return JSONValue(true);
        default:
            error = "method not implemented in qwhats-dcore yet: " ~ method;
            return JSONValue(null);
    }
}

int main(string[] args) {
    import std.getopt : getopt;
    import std.path : buildPath, expandTilde, absolutePath;
    import std.file : mkdirRecurse, exists;
    string data = "~/.local/share/qml-whats/dcore", cache = "~/.cache/qml-whats/dcore", storePath, chatsPath;
    bool offline;   // --offline: serve the stored data without connecting (tests, while another session runs)
    getopt(args, "data", &data, "cache", &cache, "store", &storePath, "chats", &chatsPath, "offline", &offline);
    data = data.expandTilde.absolutePath;
    if (storePath.length == 0) storePath = buildPath(data, "accounts", "main", "device.db");
    if (chatsPath.length == 0) chatsPath = buildPath(data, "wa.db");
    storePath = storePath.expandTilde.absolutePath;
    chatsPath = chatsPath.expandTilde.absolutePath;
    clientLog = stderr;   // stdout is the JSON-RPC channel
    {
        // vibe's own log (e.g. vibe-http warnings) defaults to stdout: keep it off the JSON channel
        import vibe.core.log : setLogLevel, registerLogger, FileLogger, LogLevel;
        setLogLevel(LogLevel.none);
        auto fl = cast(shared) new FileLogger(stderr, stderr);
        fl.minLevel = LogLevel.warn;
        registerLogger(fl);
    }

    {
        import std.path : dirName;
        mkdirRecurse(storePath.dirName);   // a new store pairs by QR
    }
    auto store = new Store(storePath);
    chats = new ChatStore(new Db(chatsPath));
    // SMS threads leaked into WhatsApp's store before the guard in handle(): out, on every start
    chats.db.exec(`DELETE FROM msgs_fts WHERE remote LIKE 'sms:%'; DELETE FROM msgs WHERE remote LIKE 'sms:%';
        DELETE FROM orphans WHERE remote LIKE 'sms:%'; DELETE FROM chats WHERE id LIKE 'sms:%';
        DELETE FROM chat_pins WHERE chat LIKE 'sms:%'; DELETE FROM chat_read WHERE chat LIKE 'sms:%';`);
    client = new Client(store, chats, "main", (string m, JSONValue p) { emit(m, p); });
    repairLidTwins(store);
    client.cacheDir = cache.expandTilde.absolutePath;
    client.fetchPicturesOnConnect = true;
    client.announceAvailable = true;
    views = new Views(client.ingest, client.meLid());
    client.onPaired = () { views.ownLidJid = client.meLid(); };
    {
        import std.path : expandTilde;
        // RNNoise models: ours, then the native app's data folder (where the Go core kept them)
        rec = new Recorder((string m, JSONValue p) { emit(m, p); }, client.cacheDir,
            [buildPath(data, "models"), "~/.local/share/qml-whats/native/models".expandTilde]);
    }
    appLock = new AppLock(data);
    smsBridge = new SmsBridge((string m, JSONValue p) { emit(m, p); }, client.cacheDir, buildPath(data, "sms-read.json"));

    inMu = new Mutex;
    auto reader = new Thread({
        foreach (line; stdin.byLineCopy) {
            inMu.lock();
            inbox ~= line;
            inMu.unlock();
        }
        inMu.lock();
        inClosed = true;
        inMu.unlock();
    });
    reader.isDaemon = true;
    reader.start();

    runTask(() nothrow {
        try {
            emit("ready", JSONValue(["accounts": accountList()]));
            // not paired: the UI's connect starts the QR flow
            if (!offline && client.dev.paired)
                runTask(() nothrow { try client.run(); catch (Exception e) { try stderr.writeln("client: ", e.msg); catch (Exception) {} } });
            else if (!offline) client.setState("UNPAIRED");
            for (;;) {
                string[] batch;
                bool closed;
                inMu.lock();
                batch = inbox;
                inbox = null;
                closed = inClosed;
                inMu.unlock();
                foreach (line; batch) {
                    JSONValue r;
                    try r = parseJSON(line);
                    catch (Exception) {
                        write(JSONValue(["jsonrpc": JSONValue("2.0"), "id": JSONValue(null),
                            "error": JSONValue(["code": JSONValue(-32_700), "message": JSONValue("parse error")])]));
                        continue;
                    }
                    auto id = ("id" in r) ? r["id"] : JSONValue(null);
                    string method = ("method" in r) && r["method"].type == JSONType.string ? r["method"].str : "";
                    auto params = ("params" in r) && r["params"].type == JSONType.object ? r["params"] : JSONValue.emptyObject;
                    // each request in its own task (the Go core: a goroutine each), so a download or a
                    // send does not hold the others
                    runTask((JSONValue id, string method, JSONValue params) nothrow {
                        string err;
                        JSONValue res;
                        try res = handle(method, params, err);
                        catch (Exception e) err = e.msg.length ? e.msg : typeid(e).name;
                        try reply(id, res, err); catch (Exception) {}
                    }, id, method.idup, params);
                }
                if (closed) break;   // stdin closed: the app is gone
                sleep(10.msecs);
            }
        } catch (Exception) {}
        exitEventLoop();
    });
    runEventLoop();
    // stdin closed (the app is gone): out now. The worker threads (ffmpeg runs, waveforms) would keep
    // the process alive, and the app expects its core to end with it.
    rec.shutdown();
    import core.sys.posix.unistd : _exit;
    try { stdout.flush(); stderr.flush(); } catch (Exception) {}
    _exit(0);
    assert(0);
}
