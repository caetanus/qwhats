/// Turning what arrives into the UI's store — the Go core's account.go onMessage / storeHistory /
/// handOut / canonical, ported. A live or history message becomes a Msg (wa.model) in the chat
/// store (wa.app.chatstore), add-ons change their parent, chats move, contacts learn push names,
/// and `emit` tells the UI (Msg:add, Msg:change, Chat:change, Contact:change, History:progress).
///
/// Known omissions for now: Meta AI's streamed answer pieces (bot edit-type), the verified business
/// name carried by live <message>s, status (story) specifics.
module wa.app.ingest;

import std.json;
import std.conv : to;
import std.string : indexOf, endsWith;
import wa.app.chatstore : ChatStore, formattedName, formatPhone;
import wa.binary.node : Jid;
static import wa.binary.node;
static import wa.appstate;
import wa.envelope : parseJidString;
import wa.model;
import wa.proto : ProtoReader;
import wa.store.db : Store;
import e2e = wa.pb.e2e;
import hs = wa.pb.historysync;
import web = wa.pb.web;
static import wa.pb.common;

/// Who/where/when of a message, as whatsmeow's MessageInfo.
struct MsgInfo {
    Jid chat, sender, senderAlt, recipientAlt;
    bool isFromMe, isGroup;
    string id, pushName;
    string verifiedName;   // a business's (the message's <verified_name>)
    long t;
    long editT;   // a history entry that is an edit (MESSAGE_EDIT, whatsmeow ParseWebMessage): its time
    long editMs;  // … and its timestampMS (edits are ordered by it)
}

final class Ingest {
    ChatStore cs;
    Store keys;          // the Signal store: LID ↔ PN mappings
    string account;      // our account id (the Go core uses the phone-number JID)
    string me;           // our canonical JID ("5511…@s.whatsapp.net")
    void delegate(string method, JSONValue params) emit;

    this(ChatStore cs, Store keys, string account, string me, void delegate(string, JSONValue) emit) {
        this.cs = cs;
        this.keys = keys;
        this.account = account;
        this.me = me;
        this.emit = emit is null ? (string m, JSONValue p) {} : emit;
    }

    /// canonical: a bot's chat is its number; a LID becomes its phone number when known.
    string canonical(Jid j) {
        import wa.pb.botmap : botJIDMap;
        if (j.server == "bot") {
            if (auto pn = j.user in botJIDMap) return *pn ~ "@s.whatsapp.net";
        }
        if (j.server == "lid") {
            if (const pn = keys.pnForLID(j.user)) if (pn.length) return pn ~ "@s.whatsapp.net";
        }
        return Jid.pair(j.user, j.server).toString();
    }

    // ── one message ──────────────────────────────────────────────────────────────────────────

    /// onMessage: store one message (live or from history). `message` is the content to convert,
    /// `raw` the protobuf to keep. Returns the stored Msg (false when it was an add-on, a pin or
    /// not a message).
    bool onMessage(MsgInfo info, const(ubyte)[] message, const(ubyte)[] raw, bool history, out JSONValue outMsg) {
        string remote = canonical(info.chat), author = canonical(info.sender);
        // a @lid the store cannot map yet: the message itself may carry the phone-number twin
        if (author.endsWith("@lid") && info.senderAlt.server == "s.whatsapp.net")
            author = Jid.pair(info.senderAlt.user, "s.whatsapp.net").toString();
        if (remote.endsWith("@lid") && !info.isGroup) {
            if (!info.isFromMe && author.endsWith("@s.whatsapp.net")) remote = author;
            else if (info.recipientAlt.server == "s.whatsapp.net")
                remote = Jid.pair(info.recipientAlt.user, "s.whatsapp.net").toString();
        }
        if (info.pushName.length && !info.isFromMe) {
            cs.setContact(account, author, "pushname", info.pushName);
            if (!history) emit("Contact:change", cs.contact(account, author));
        }
        // a business's messages carry its verified name (WhatsApp Web's verifiedName): the chat's title
        if (info.verifiedName.length && !info.isFromMe) {
            cs.setContact(account, author, "verifiedName", info.verifiedName);
            cs.setContact(account, author, "isBusiness", true);
            if (!history) emit("Contact:change", cs.contact(account, author));
        }

        // a message pinned (or unpinned) in the chat: the chat's pinned bar, until it expires
        bool vo;
        auto um = ProtoReader(unwrap(message, vo));
        if (um.has(e2e.Message.pinInChatMessage)) {
            auto pin = ProtoReader(um.get(e2e.Message.pinInChatMessage).bytes);
            const targetId = cast(string) ProtoReader(pin.get(e2e.PinInChatMessage.key).bytes)
                .get(wa.pb.common.MessageKey.ID).bytes.idup;
            JSONValue target;
            const key = cs.msgByID(account, remote, targetId, target) ? target["id"].str : "";
            if (pin.get(e2e.PinInChatMessage.type).value == e2e.PinInChatMessage.Type.PIN_FOR_ALL) {
                long secs = cast(long) ProtoReader(ProtoReader(message).get(e2e.Message.messageContextInfo).bytes)
                    .get(e2e.MessageContextInfo.messageAddOnDurationInSecs).value;
                if (secs <= 0) secs = 7 * 86_400;
                if (key.length) cs.setChatPin(account, remote, key, info.t + secs);
            } else cs.setChatPin(account, remote, "", 0);
            if (!history) emitChat(remote);
            return false;
        }

        Addon ad;
        if (addon(message, ad)) {
            if (ad.t == 0) ad.t = info.t;
            JSONValue p;
            if (cs.applyAddon(account, remote, ad, author, info.isFromMe, p) && !history) {
                emit("Msg:change", handOut(p));
                emitChat(remote);
            }
            return false;
        }

        JSONValue n;
        if (!content(message, n)) return false;
        envelope(n, account, info.id, info.isFromMe, info.t, info.pushName, remote, author);
        if (history) n["isMdHistoryMsg"] = true;
        if (info.editT > 0) {
            n["isEdited"] = true;
            n["latestEditSenderTimestamp"] = info.editT;
            n["latestEditMs"] = info.editMs > 0 ? info.editMs : info.editT * 1000;
        }
        if (auto ed = "ephemeralDuration" in n) if (ed.integer > 0) n["expiredTimestamp"] = info.t + ed.integer;
        {
            // an older copy of a message we have (a history chunk overlapping live messages, a
            // re-delivery): what happened to it since stays — revoked stays revoked, an edit keeps
            // its text, a downloaded file stays, the highest ack and the star are kept. A
            // "ciphertext" placeholder is simply replaced.
            JSONValue cur;
            ubyte[] rawCur;
            const have = cs.msg(account, n["id"].str, cur, rawCur);
            // a history edit's raw is the MESSAGE_EDIT envelope, which downloadMedia cannot unwrap:
            // the stored original's raw stays (null keeps it), else the edited content itself
            if (info.editT > 0) raw = have && rawCur.length ? null : message;
            if (have && ("type" in cur) && cur["type"].str != "ciphertext") {
                if (cur["type"].str == "revoked") return false;
                // an edit (chatstore applyAddon "edit") owns body/caption/mentionedJidList and its stamp:
                // the stored set replaces the incoming one whole — a field the edit removed stays
                // removed — unless the incoming copy is itself a newer edit (a history MESSAGE_EDIT)
                long storedEdit = 0;   // ms
                if (auto lm = "latestEditMs" in cur) { if (lm.type == JSONType.integer) storedEdit = lm.integer; }
                else if (auto le = "latestEditSenderTimestamp" in cur) { if (le.type == JSONType.integer) storedEdit = le.integer * 1000; }
                const incomingNewer = info.editT > 0 && (info.editMs > 0 ? info.editMs : info.editT * 1000) > storedEdit;
                if (auto ie = "isEdited" in cur) if (ie.type == JSONType.true_ && !incomingNewer)
                    foreach (k; ["body", "caption", "mentionedJidList", "isEdited", "latestEditSenderTimestamp", "latestEditMs"]) {
                        if (k in n.object) n.object.remove(k);
                        if (auto v = k in cur) n[k] = *v;
                    }
                // an edit does not move the message in time: it keeps its own timestamp
                if (info.editT > 0) if (auto ct = "t" in cur) n["t"] = *ct;
                if (auto cm = "mediaData" in cur) if (auto nm = "mediaData" in n)
                    foreach (k; ["renderableUrl", "mediaStage"]) if (auto v = k in *cm) (*nm)[k] = *v;
                if (auto ca = "ack" in cur) if (!("ack" in n) || ca.integer > n["ack"].integer) n["ack"] = *ca;
                if (auto st = "star" in cur) n["star"] = *st;
            }
        }
        if (!cs.putMsg(n, raw)) return false;   // deleted for me (app-state) before it arrived
        cs.adoptOrphans(n);
        if (n["type"].str == "notification_template" && ("subtype" in n) && n["subtype"].str == "ephemeral_setting")
            cs.setChat(account, remote, "ephemeralDuration", ("ephemeralDuration" in n) ? n["ephemeralDuration"].integer : 0);
        outMsg = n;
        if (history) return true;
        bool mentionsMe;
        if (auto ml = "mentionedJidList" in n) foreach (j; ml.array) if (j.str == me) mentionsMe = true;
        cs.bumpChat(n, true, mentionsMe);
        // our own message from another device (the phone): replying reads the chat, as WhatsApp
        // counts it — what came before is no longer unread
        if (info.isFromMe) readUpTo(remote, info.t);
        emit("Msg:add", handOut(n));
        emitChat(remote);
        return true;
    }

    /// readUpTo: the chat read up to `t` here (another of our devices read it, or we wrote in it): no
    /// unread count, no unread mark, and a later copy of an older message (history) stays read
    void readUpTo(string remote, long t) {
        cs.markRead(account, remote, t);
        cs.setChat(account, remote, "unreadCount", 0L);
        cs.setChat(account, remote, "unreadMentionCount", 0L);
        cs.setChat(account, remote, "markedUnread", false);
    }

    // ── history ──────────────────────────────────────────────────────────────────────────────

    /// ParseWebMessage: a history entry's MsgInfo, and its content (the edit rule applied).
    bool parseWebMessage(Jid chat, const(ubyte)[] webMsg, out MsgInfo info, out const(ubyte)[] message,
        out const(ubyte)[] raw) {
        alias W = web.WebMessageInfo;
        alias K = wa.pb.common.MessageKey;
        auto w = ProtoReader(webMsg);
        auto key = ProtoReader(w.get(W.key).bytes);
        info.chat = chat;
        info.isFromMe = key.get(K.fromMe).value != 0;
        info.isGroup = chat.server == "g.us";
        info.id = cast(string) key.get(K.ID).bytes.idup;
        info.pushName = cast(string) w.get(W.pushName).bytes.idup;
        info.t = cast(long) w.get(W.messageTimestamp).value;
        if (info.isFromMe) {
            const orig = cast(string) w.get(W.originalSelfAuthorUserJIDString).bytes.idup;
            if (orig.length) info.sender = parseJidString(orig);
            else info.sender = parseJidString(me);
        } else if (chat.server == "s.whatsapp.net" || chat.server == "lid" || chat.server == "newsletter") {
            info.sender = chat;
        } else {
            auto p = cast(string) w.get(W.participant).bytes.idup;
            if (p.length == 0) p = cast(string) key.get(K.participant).bytes.idup;
            if (p.length == 0) return false;
            info.sender = parseJidString(p);
        }
        raw = w.get(W.message).bytes;
        long editMs;
        bool isEdit;
        message = historyContent(raw, info.id, editMs, isEdit);
        if (isEdit) {   // the edited content, under the edited message's id (the same id or not)
            info.editT = info.t;
            info.editMs = editMs > 0 ? editMs : info.t * 1000;
        }
        return true;
    }

    /// storeHistory: a HistorySync chunk — push names, chats with their state, their messages
    /// (with reactions, acks and stars), the statuses of the last 24 h.
    void storeHistory(const(ubyte)[] historySync) {
        alias H = hs.HistorySync;
        alias C = hs.Conversation;
        alias W = web.WebMessageInfo;
        auto h = ProtoReader(historySync);
        foreach (f; h) if (f.number == H.pushnames) {
            auto pn = ProtoReader(f.bytes);
            const id = cast(string) pn.get(hs.Pushname.ID).bytes;
            if (id.length) cs.setContact(account, canonical(parseJidString(id)), "pushname",
                cast(string) pn.get(hs.Pushname.pushname).bytes.idup);
        }
        const onDemand = h.get(H.syncType).value == hs.HistorySync.HistorySyncType.ON_DEMAND;
        size_t n;
        string[] touched;
        cs.db.transaction({
            foreach (f; h) if (f.number == H.conversations) {
                auto conv = ProtoReader(f.bytes);
                auto jid = parseJidString(cast(string) conv.get(C.ID).bytes);
                if (jid.server == "lid") {
                    const pn = cast(string) conv.get(C.pnJID).bytes;
                    if (pn.length) jid = parseJidString(pn);
                }
                const id = canonical(jid);
                cs.ensureChat(account, id);
                cs.setChatName(account, id, cast(string) conv.get(C.name).bytes.idup);
                if (const parent = cast(string) conv.get(C.parentGroupID).bytes.idup) if (parent.length)
                    cs.setGroupParent(account, id, parent);
                if (!onDemand) {
                    // the phone's read mark (app-state) is newer than this copy: keep its count
                    if (cs.readAt(account, id) < cast(long) conv.get(C.conversationTimestamp).value) {
                        cs.setChat(account, id, "unreadCount", cast(long) conv.get(C.unreadCount).value);
                        cs.setChat(account, id, "unreadMentionCount", cast(long) conv.get(C.unreadMentionCount).value);
                    }
                    // app-state is authoritative for read marks, archive and pin (regular_low) and mute
                    // (regular_high): once synced, the history's older copy must not overwrite them
                    if (!appStateSynced("regular_low")) {
                        cs.setChat(account, id, "markedUnread", conv.get(C.markedAsUnread).value != 0);
                        cs.setChat(account, id, "archive", conv.get(C.archived).value != 0);
                        cs.setChat(account, id, "pin", cast(long) conv.get(C.pinned).value);
                    }
                    if (!appStateSynced("regular_high")) {
                        long mute = cast(long) conv.get(C.muteEndTime).value;
                        import std.datetime.systime : Clock;
                        if (mute > 0 && mute < Clock.currTime.toUnixTime) mute = 0;
                        cs.setChat(account, id, "muteExpiration", mute);
                    }
                    // a 1:1 chat by phone number that WhatsApp moved to the contact's LID is kept by
                    // the phone read-only (the LID one is live); here both are the one chat (canonical),
                    // so that leftover's mark must not lock it
                    const movedToLid = jid.server == "s.whatsapp.net" && keys.lidForPN(jid.user).length > 0;
                    if (!movedToLid) cs.setChat(account, id, "isReadOnly", conv.get(C.readOnly).value != 0);
                    cs.setChat(account, id, "ephemeralDuration", cast(long) conv.get(C.ephemeralExpiration).value);
                    cs.setChat(account, id, "endOfHistoryTransferType", cast(long) conv.get(C.endOfHistoryTransferType).value);
                    cs.setChat(account, id, "isParentGroup", conv.get(C.isParentGroup).value != 0);
                }
                long newest = cast(long) conv.get(C.conversationTimestamp).value;
                // a clear / delete (app-state) already removed everything up to clearedAt: the history
                // must not bring it back (a clear keeps starred messages, a delete does not)
                const clearedAt = cs.db.scalarInt(`SELECT clearedAt FROM chats WHERE account=? AND id=?`, account, id);
                const chatDeleted = cs.db.scalarInt(`SELECT deleted FROM chats WHERE account=? AND id=?`, account, id) != 0;
                foreach (mf; conv) if (mf.number == C.messages) {
                    auto wmb = ProtoReader(mf.bytes).get(hs.HistorySyncMsg.message).bytes;
                    if (wmb.length == 0) continue;
                    auto wm = ProtoReader(wmb);
                    const fromMe = ProtoReader(wm.get(W.key).bytes).get(wa.pb.common.MessageKey.fromMe).value != 0;
                    const vn = cast(string) wm.get(W.verifiedBizName).bytes.idup;
                    if (vn.length && !fromMe && !id.endsWith("@g.us")) {
                        cs.setContact(account, id, "verifiedName", vn);
                        cs.setContact(account, id, "isBusiness", 1);
                    }
                    MsgInfo info;
                    const(ubyte)[] message, raw;
                    if (!parseWebMessage(jid, wmb, info, message, raw)) continue;
                    if (clearedAt > 0 && info.t <= clearedAt) {
                        // the app-state's star (if any) decides, not the history's older copy
                        import wa.model : msgKey;
                        int ms;
                        bool md;
                        cs.mark(account, msgKey(info.isFromMe, id, info.id, canonical(info.sender)), ms, md);
                        const starred = ms >= 0 ? ms == 1 : wm.get(W.starred).value != 0;
                        if (chatDeleted || !starred) continue;
                    }
                    const stub = wm.get(W.messageStubType).value;
                    const st = stubOf(stub);
                    if (st[0].length && raw.length == 0) {
                        // a system row (who joined, security code changed, missed call…)
                        JSONValue[] params;
                        foreach (pf; wm) if (pf.number == W.messageStubParameters) {
                            string pstr = cast(string) pf.bytes.idup;
                            const pj = parseJidString(pstr);
                            if (pstr.indexOf('@') > 0 && pj.user.length) pstr = canonical(pj);
                            params ~= JSONValue(pstr);
                        }
                        JSONValue sm = JSONValue.emptyObject;
                        sm["type"] = st[0];
                        sm["subtype"] = st[1];
                        if (params.length) sm["templateParams"] = params;
                        sm["isMdHistoryMsg"] = true;
                        envelope(sm, account, info.id, info.isFromMe, info.t, info.pushName, canonical(info.chat),
                            canonical(info.sender));
                        if (!cs.putMsg(sm, null)) continue;
                        if (info.t > newest) newest = info.t;
                        n++;
                        continue;
                    }
                    JSONValue m;
                    if (!onMessage(info, message, raw, true, m)) continue;
                    foreach (rf; wm) if (rf.number == W.reactions) {
                        auto r = ProtoReader(rf.bytes);
                        auto rk = ProtoReader(r.get(e2e.ReactionMessage.key).bytes);
                        string sender = me;
                        if (rk.get(wa.pb.common.MessageKey.fromMe).value == 0) {
                            sender = id;
                            const pp = cast(string) rk.get(wa.pb.common.MessageKey.participant).bytes;
                            if (pp.length) sender = canonical(parseJidString(pp));
                        }
                        Addon ra;
                        ra.kind = "reaction";
                        ra.parentId = m["msgId"].str;
                        ra.text = cast(string) r.get(e2e.ReactionMessage.text).bytes.idup;
                        ra.t = cast(long) r.get(e2e.ReactionMessage.senderTimestampMS).value / 1000;
                        JSONValue p;
                        cs.applyAddon(account, m["remote"].str, ra, sender, rk.get(wa.pb.common.MessageKey.fromMe).value != 0, p);
                    }
                    JSONValue cur;
                    ubyte[] rawCur;
                    if (cs.msg(account, m["id"].str, cur, rawCur)) {
                        if (cur["fromMe"].type == JSONType.true_) cur["ack"] = ackOf(wm.get(W.status).value);
                        int markStar;
                        bool markDel;
                        cs.mark(account, cur["id"].str, markStar, markDel);   // app-state's star wins
                        const starred = markStar >= 0 ? markStar == 1 : wm.get(W.starred).value != 0;
                        if (starred) cur["star"] = true;
                        else if ("star" in cur) cur.object.remove("star");
                        cs.updateMsg(cur);
                    }
                    if (m["t"].integer > newest) newest = m["t"].integer;
                    n++;
                }
                cs.db.run(`UPDATE chats SET t=MAX(t, ?) WHERE account=? AND id=?`, newest, account, id);
                touched ~= id;
            }
            // the statuses of the last 24 hours, sent once when a device links (INITIAL_STATUS_V3)
            foreach (f; h) if (f.number == H.statusV3Messages) {
                MsgInfo info;
                const(ubyte)[] message, raw;
                if (!parseWebMessage(Jid.pair("status", "broadcast"), f.bytes, info, message, raw)) continue;
                JSONValue m;
                if (onMessage(info, message, raw, true, m)) n++;
            }
        });
        JSONValue ev = ["account": JSONValue(account),
            "type": JSONValue(syncTypeName(cast(uint) h.get(H.syncType).value)),
            "progress": JSONValue(h.get(H.progress).value), "chats": JSONValue(touched.length), "msgs": JSONValue(n)];
        if (onDemand && touched.length == 1) ev["chat"] = touched[0];
        emit("History:progress", ev);
    }

    // ── app-state (syncd) ────────────────────────────────────────────────────────────────────

    bool appStateSynced(string name) {
        ubyte[128] h;
        return keys.appStateVersion(name, h) > 0;
    }

    /// Apply decoded app-state mutations (whatsmeow dispatchAppState + the Go core's handlers):
    /// mute, pin, archive, contact names, read marks, stars, deletes, clears, status mutes, and the
    /// NCT salt. Only SET mutations act, except the salt (a REMOVE clears it).
    void onAppState(const wa.appstate.Mutation[] muts) {
        import sav = wa.pb.syncaction;
        import std.datetime.systime : Clock;
        import std.process : environment;
        const dumpPath = environment.get("WA_APPSTATE_DUMP");
        foreach (ref mu; muts) {
            if (mu.index.length == 0) continue;
            auto v = ProtoReader(mu.action);
            if (dumpPath.length) {
                import std.stdio : File;
                import std.digest : toHexString;
                try File(dumpPath, "a").writeln(mu.operation, "\t", mu.index, "\t", toHexString(mu.action));
                catch (Exception) {}
            }
            if (mu.index.length == 1 && mu.index[0] == "nct_salt_sync") {
                // SET stores the salt (an empty one is ignored), REMOVE clears it
                if (mu.operation == 0) {
                    const salt = ProtoReader(v.get(sav.SyncActionValue.nctSaltSyncAction).bytes).get(sav.NctSaltSyncAction.salt).bytes;
                    if (salt.length) keys.putBlob("nct_salt", salt);
                } else keys.deleteBlob("nct_salt");
                continue;
            }
            if (mu.index.length == 1 && mu.index[0] == "setting_pushName" && mu.operation == 0) {
                // our own name (PushNameSetting)
                const name = cast(string) ProtoReader(v.get(sav.SyncActionValue.pushNameSetting).bytes).get(sav.PushNameSetting.name).bytes.idup;
                if (name.length) {
                    cs.setContact(account, me, "pushname", name);
                    emit("Contact:change", cs.contact(account, me));
                }
                continue;
            }
            if (mu.index.length == 2 && mu.index[0] == "favoriteSticker") {
                // WAWebStickersFavoriteSyncAction: SET with stickerAction.isFavorite; the index is the
                // file's SHA-256 (base64)
                if (mu.operation == 0) {
                    auto sa = ProtoReader(v.get(sav.SyncActionValue.stickerAction).bytes);
                    cs.setFavSticker(account, mu.index[1], sa.get(sav.StickerAction.isFavorite).value != 0,
                        cast(long) v.get(sav.SyncActionValue.timestamp).value);
                }
                continue;
            }
            if (mu.operation != 0 || mu.index.length < 2) continue;
            try applyOne(mu, v);
            catch (Exception e) {
                import std.stdio : stderr;
                try stderr.writeln("app-state ", mu.index[0], ": ", e.msg); catch (Exception) {}
            }
        }
    }

    private void applyOne(const ref wa.appstate.Mutation mu, ProtoReader v) {
        import sav = wa.pb.syncaction;
        import std.datetime.systime : Clock;
        {
            static immutable jidIndexes = ["mute", "pin_v1", "archive", "contact", "markChatAsRead", "star",
                "deleteMessageForMe", "clearChat", "deleteChat", "userStatusMute"];
            import std.algorithm : canFind;
            if (!jidIndexes.canFind(mu.index[0])) return;
            const id = canonical(parseJidString(mu.index[1]));
            const tsMs = cast(long) v.get(sav.SyncActionValue.timestamp).value;
            ProtoReader act(uint f) { return ProtoReader(v.get(f).bytes); }
            switch (mu.index[0]) {
                case "mute":
                    auto a = act(sav.SyncActionValue.muteAction);
                    long exp;
                    if (a.get(sav.MuteAction.muted).value) {
                        exp = cast(long) a.get(sav.MuteAction.muteEndTimestamp).value / 1000;
                        if (exp <= 0) exp = -1;
                    }
                    cs.setChat(account, id, "muteExpiration", exp);
                    emitChat(id);
                    break;
                case "pin_v1":
                    cs.setChat(account, id, "pin", act(sav.SyncActionValue.pinAction).get(sav.PinAction.pinned).value ? tsMs / 1000 : 0L);
                    emitChat(id);
                    break;
                case "archive":
                    cs.setChat(account, id, "archive", act(sav.SyncActionValue.archiveChatAction).get(sav.ArchiveChatAction.archived).value != 0);
                    emitChat(id);
                    break;
                case "contact":
                    auto a = act(sav.SyncActionValue.contactAction);
                    cs.setContact(account, id, "name", cast(string) a.get(sav.ContactAction.fullName).bytes.idup);
                    cs.setContact(account, id, "shortName", cast(string) a.get(sav.ContactAction.firstName).bytes.idup);
                    emit("Contact:change", cs.contact(account, id));
                    break;
                case "markChatAsRead":
                    auto ra = act(sav.SyncActionValue.markChatAsReadAction);
                    if (ra.get(sav.MarkChatAsReadAction.read).value) {
                        // read up to the range's last message (else the action's time)
                        long rt = cast(long) ProtoReader(ra.get(sav.MarkChatAsReadAction.messageRange).bytes)
                            .get(sav.SyncActionMessageRange.lastMessageTimestamp).value;
                        if (rt == 0) rt = tsMs / 1000;
                        cs.markRead(account, id, rt);
                    } else cs.setChat(account, id, "markedUnread", true);
                    emitChat(id);
                    break;
                case "star":
                    if (mu.index.length < 5) break;
                    const starred = act(sav.SyncActionValue.starAction).get(sav.StarAction.starred).value != 0;
                    const key = indexKey(id, mu.index);
                    cs.setStarMark(account, key, starred);
                    JSONValue m;
                    if (findIndexed(id, mu.index, key, m)) {
                        if (starred) m["star"] = true;
                        else if ("star" in m) m.object.remove("star");
                        cs.updateMsg(m);
                        emit("Msg:change", handOut(m));
                    }
                    break;
                case "deleteMessageForMe":
                    if (mu.index.length < 5) break;
                    const key = indexKey(id, mu.index);
                    cs.setDeleteMark(account, key);
                    JSONValue m;
                    if (findIndexed(id, mu.index, key, m)) {
                        cs.deleteMsg(account, m["id"].str);
                        emit("Msg:remove", JSONValue(["account": JSONValue(account), "id": m["id"], "remote": JSONValue(id)]));
                        emitChat(id);
                    }
                    break;
                case "clearChat":
                    long t = cast(long) ProtoReader(act(sav.SyncActionValue.clearChatAction).get(sav.ClearChatAction.messageRange).bytes)
                        .get(sav.SyncActionMessageRange.lastMessageTimestamp).value;
                    if (t == 0) t = Clock.currTime.toUnixTime;
                    cleared(id, t, true);
                    break;
                case "deleteChat":
                    long dt = cast(long) ProtoReader(act(sav.SyncActionValue.deleteChatAction).get(sav.DeleteChatAction.messageRange).bytes)
                        .get(sav.SyncActionMessageRange.lastMessageTimestamp).value;
                    if (dt == 0) dt = Clock.currTime.toUnixTime;
                    cleared(id, dt, false);
                    cs.setChat(account, id, "deleted", true);
                    emit("Chat:remove", JSONValue(["account": JSONValue(account), "id": JSONValue(id)]));
                    break;
                case "userStatusMute":
                    cs.setStatusMuted(account, id, act(sav.SyncActionValue.userStatusMuteAction).get(sav.UserStatusMuteAction.muted).value != 0);
                    emit("Status:change", JSONValue(["account": JSONValue(account), "id": JSONValue(id)]));
                    break;
                default:
                    break;
            }
        }
    }

    /// indexKey: the stored key of the message a star / deleteMessageForMe index names —
    /// [action, chat, msgId, fromMe "1"/"0", sender ("0" unless someone else's group message)].
    private string indexKey(string chat, const(string)[] index) {
        import wa.model : msgKey;
        const fromMe = index[3] == "1";
        string sender = index[4] == "0" ? "" : canonical(parseJidString(index[4]));
        return msgKey(fromMe, chat, index[2], sender);
    }
    /// findIndexed: that message — by its exact key, else the only one with that id whose direction
    /// (and, in a group, author) match.
    private bool findIndexed(string chat, const(string)[] index, string key, out JSONValue m) {
        ubyte[] raw;
        if (cs.msg(account, key, m, raw)) return true;
        JSONValue c;
        if (!cs.msgByID(account, chat, index[2], c)) return false;
        const fromMe = index[3] == "1";
        if ((c["fromMe"].type == JSONType.true_) != fromMe) return false;
        if (!fromMe && index[4] != "0" && ("author" in c) && c["author"].str != canonical(parseJidString(index[4])))
            return false;
        m = c;
        return true;
    }

    /// cleared: a chat's messages up to t removed (keeping starred ones on a clear), unread reset.
    void cleared(string remote, long t, bool keepStarred) {
        foreach (k; cs.clearChat(account, remote, t, keepStarred))
            emit("Msg:remove", JSONValue(["account": JSONValue(account), "id": JSONValue(k), "remote": JSONValue(remote)]));
        cs.setChat(account, remote, "clearedAt", t);
        cs.setChat(account, remote, "unreadCount", 0L);
        emitChat(remote);
    }

    // ── receipts ─────────────────────────────────────────────────────────────────────────────

    /// A <receipt>: delivered/read/played raise our messages' ack; read-self marks the chat read.
    /// `ownUsers` are our phone-number and LID users (a receipt from us names the chat as recipient).
    void onReceipt(const ref wa.binary.node.Node n, string[] ownUsers) {
        import wa.envelope : jidAttr;
        import std.algorithm : canFind;
        const type = n.get("type");
        int ack;
        switch (type) {
            case "", "sender": ack = ackReceived; break;
            case "read", "read-self": ack = ackRead; break;
            case "played", "played-self": ack = ackPlayed; break;
            default: return;
        }
        auto from = jidAttr(n, "from");
        Jid chatJ = from;
        if (from.server != "g.us" && from.server != "broadcast" && ownUsers.canFind(from.user)
            && n.attr("recipient") !is null)
            chatJ = jidAttr(n, "recipient");
        const remote = canonical(chatJ);
        // our own read, on another device (the phone): a read-self (our read receipts off), or a read
        // receipt that comes from us — in a 1:1 chat as from=us recipient=chat, in a group with
        // participant=us. The chat is read here too.
        bool selfRead = type == "read-self";
        if (type == "read") {
            if (from.server != "g.us" && ownUsers.canFind(from.user)) selfRead = true;
            if (n.attr("participant") !is null && ownUsers.canFind(jidAttr(n, "participant").user)) selfRead = true;
        }
        if (selfRead) {
            import std.conv : to;
            long t;
            try t = n.get("t").to!long; catch (Exception) {}
            if (t == 0) { import std.datetime.systime : Clock; t = Clock.currTime.toUnixTime; }
            readUpTo(remote, t);
            emitChat(remote);
            if (type == "read-self") return;
        }
        string[] ids = [n.get("id")];
        if (const l = n.child("list")) foreach (ref it; l.children) if (it.tag == "item" && it.get("id").length) ids ~= it.get("id");
        foreach (m; cs.raiseAck(account, remote, ids, ack)) emit("Msg:change", handOut(m));
        emitChat(remote);
    }

    // ── out to the UI ────────────────────────────────────────────────────────────────────────

    /// handOut: a Msg as the UI reads it, with the author's display name (and picture for voice notes).
    JSONValue handOut(JSONValue m) {
        auto o = JSONValue(m.object.dup);
        const fromMe = ("fromMe" in o) && o["fromMe"].type == JSONType.true_;
        const author = ("author" in o) ? o["author"].str : "";
        const remote = o["remote"].str;
        if (!fromMe && author.length) {
            auto k = cs.contact(account, author);
            o["senderName"] = k["formattedName"].str;
            if (remote.endsWith("@g.us")) {
                if (("name" !in k) && ("phoneNumber" in k)) o["senderPhone"] = formatPhone(k["phoneNumber"].str);
                if (auto pic = "profilePicThumb" in k) if (pic.str != "-") o["senderPic"] = pic.str;
            }
        }
        // a system notice's people, as names (the Go core's TemplateNames: "Você", else the contact's
        // formatted name) — and whether each one is known to us (address book, push name, verified
        // name) or just a number / "Contato do WhatsApp": the UI folds runs of unknown joins/leaves
        if (auto tp = "templateParams" in o) if (tp.type == JSONType.array && tp.array.length) {
            JSONValue[] names, known;
            string meLid;
            {
                const at = me.indexOf('@');
                if (at > 0) if (const l = keys.lidForPN(me[0 .. at])) if (l.length) meLid = l ~ "@lid";
            }
            foreach (p; tp.array) {
                const id = p.type == JSONType.string ? p.str : "";
                if (id.length && (id == me || (meLid.length && id == meLid))) {
                    names ~= JSONValue("Você");
                    known ~= JSONValue(true);
                } else if (id.indexOf('@') > 0) {
                    auto k = cs.contact(account, id);
                    names ~= JSONValue(k["formattedName"].str);
                    const named = (("name" in k) && k["name"].str.length) || (("pushname" in k) && k["pushname"].str.length)
                        || (("verifiedName" in k) && k["verifiedName"].str.length);
                    known ~= JSONValue(named);
                } else if (id.length == 0) {
                    names ~= JSONValue("");     // no one (a join without an actor): nothing known
                    known ~= JSONValue(false);
                } else {
                    names ~= JSONValue(id);
                    known ~= JSONValue(true);
                }
            }
            o["templateNames"] = names;
            o["templateKnown"] = known;
        }
        const type = o["type"].str;
        if (type == "ptt" || type == "audio") {
            string who = author;
            if (fromMe) who = me;
            else if (who.length == 0) who = remote;
            auto k = cs.contact(account, who);
            if (auto pic = "profilePicThumb" in k) if (pic.str != "-") o["senderPic"] = pic.str;
        }
        // a status from someone whose updates are muted: no notification for it
        if (remote == "status@broadcast" && author.length && cs.statusMuted(account, author)) o["isStatusMuted"] = true;
        if (("type" in o) && o["type"].str == "sticker") {
            const h = stickerFileHash(o["id"].str);
            if (h.length && cs.isFavSticker(account, h)) o["isFavoriteSticker"] = true;
            // its pack, when we added it (the menu then offers removing instead of adding)
            if (h.length) {
                const pack = cs.db.scalarText(`SELECT p.pack FROM sticker_meta m JOIN sticker_packs p ON p.account=m.account AND p.pack=m.pack
                    WHERE m.account=? AND m.filehash=?`, account, h);
                if (pack.length) o["stickerPack"] = pack;
            }
        }
        return o;
    }

    /// A stored sticker's file SHA-256 in base64 (the favoriteSticker index), "" when unknown.
    string stickerFileHash(string key) {
        import std.base64 : Base64;
        import e2e = wa.pb.e2e;
        JSONValue m;
        ubyte[] raw;
        if (!cs.msg(account, key, m, raw) || raw.length == 0) return "";
        bool vo;
        auto inner = ProtoReader(unwrap(raw, vo));
        const st = inner.get(e2e.Message.stickerMessage).bytes;
        if (st.length == 0) return "";
        const sha = ProtoReader(st).get(e2e.StickerMessage.fileSHA256).bytes;
        return sha.length ? cast(string) Base64.encode(sha) : "";
    }

    /// The chat list's decoration (wa.app.views sets these): a Chat:change carries the full chat,
    /// and only for chats the list shows — as the Go core's emitChat.
    JSONValue delegate(JSONValue) chatView;
    bool delegate(JSONValue) chatListed;

    void emitChat(string id) {
        JSONValue c;
        if (!cs.chat(account, id, c)) return;
        if (chatView is null) { emit("Chat:change", c); return; }
        auto full = chatView(c);
        if (chatListed is null || chatListed(full)) emit("Chat:change", full);
    }
}

private string syncTypeName(uint t) {
    import wa.history : syncTypeName;
    return syncTypeName(t);
}
