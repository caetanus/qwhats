/// The chats/messages/contacts store the UI reads — the Go core's store.go, ported: the same
/// tables and the same JSON (Msg/Chat/Contact as WhatsApp Web's models), so the UI cannot tell the
/// cores apart. Messages are kept as their Msg JSON plus the raw protobuf; add-ons (reactions,
/// edits, revokes) change their parent, or wait as orphans until it arrives.
module wa.app.chatstore;

import std.json;
import std.conv : to;
import std.string : strip, split, join, indexOf, startsWith;
import std.algorithm : endsWith;
import wa.model : Addon, previewBody;
import wa.store.sql : Db;

private enum schema = `
CREATE TABLE IF NOT EXISTS msgs(
  account TEXT, key TEXT, remote TEXT, id TEXT, t INTEGER, type TEXT, star INTEGER DEFAULT 0,
  json TEXT, raw BLOB, PRIMARY KEY(account, key));
CREATE INDEX IF NOT EXISTS msgs_by_chat ON msgs(account, remote, t);
CREATE INDEX IF NOT EXISTS msgs_by_id ON msgs(account, remote, id);
CREATE VIRTUAL TABLE IF NOT EXISTS msgs_fts USING fts5(account UNINDEXED, key UNINDEXED, remote UNINDEXED, body);
CREATE TABLE IF NOT EXISTS reactions(
  account TEXT, remote TEXT, parent TEXT, sender TEXT, text TEXT, t INTEGER, fromMe INTEGER,
  PRIMARY KEY(account, remote, parent, sender));
CREATE TABLE IF NOT EXISTS orphans(
  account TEXT, remote TEXT, parent TEXT, kind TEXT, json TEXT, t INTEGER);
CREATE INDEX IF NOT EXISTS orphans_by_parent ON orphans(account, remote, parent);
CREATE TABLE IF NOT EXISTS chats(
  account TEXT, id TEXT, name TEXT DEFAULT '', t INTEGER DEFAULT 0,
  unreadCount INTEGER DEFAULT 0, unreadMentionCount INTEGER DEFAULT 0, markedUnread INTEGER DEFAULT 0,
  archive INTEGER DEFAULT 0, pin INTEGER DEFAULT 0, muteExpiration INTEGER DEFAULT 0,
  isReadOnly INTEGER DEFAULT 0, isAnnounceGrpRestrict INTEGER DEFAULT 0, ephemeralDuration INTEGER DEFAULT 0,
  endOfHistoryTransferType INTEGER DEFAULT 0, draftMessage TEXT DEFAULT '', isParentGroup INTEGER DEFAULT 0,
  clearedAt INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
  PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS contacts(
  account TEXT, id TEXT, name TEXT DEFAULT '', shortName TEXT DEFAULT '', pushname TEXT DEFAULT '',
  verifiedName TEXT DEFAULT '', isBusiness INTEGER DEFAULT 0, blocked INTEGER DEFAULT 0,
  phoneNumber TEXT DEFAULT '', status TEXT DEFAULT '', pic TEXT DEFAULT '',
  PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS groups(account TEXT, id TEXT, json TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS chat_pins(account TEXT, chat TEXT, msg TEXT, until INTEGER, PRIMARY KEY(account, chat));
CREATE TABLE IF NOT EXISTS status_seen(account TEXT, key TEXT, PRIMARY KEY(account, key));
CREATE TABLE IF NOT EXISTS status_mute(account TEXT, id TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS msg_marks(account TEXT, key TEXT, star INTEGER DEFAULT -1, deleted INTEGER DEFAULT 0,
  PRIMARY KEY(account, key));
CREATE TABLE IF NOT EXISTS chat_read(account TEXT, chat TEXT, t INTEGER, PRIMARY KEY(account, chat));
CREATE TABLE IF NOT EXISTS fp_stickers(account TEXT, id TEXT, pack TEXT, raw BLOB, file TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS group_parent(account TEXT, id TEXT, parent TEXT, PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS sticker_packs(account TEXT, pack TEXT, name TEXT, publisher TEXT, t INTEGER,
  PRIMARY KEY(account, pack));
CREATE TABLE IF NOT EXISTS sticker_pack_items(account TEXT, pack TEXT, filehash TEXT, msg TEXT, t INTEGER,
  PRIMARY KEY(account, pack, filehash));
CREATE TABLE IF NOT EXISTS sticker_meta(account TEXT, filehash TEXT, pack TEXT, name TEXT, publisher TEXT,
  PRIMARY KEY(account, filehash));
CREATE TABLE IF NOT EXISTS fav_stickers(account TEXT, filehash TEXT, t INTEGER, PRIMARY KEY(account, filehash));
`;

private string g(JSONValue o, string k) {
    if (o.type != JSONType.object) return "";
    auto p = k in o;
    return p is null || p.type != JSONType.string ? "" : p.str;
}
private long gi(JSONValue o, string k) {
    if (o.type != JSONType.object) return 0;
    auto p = k in o;
    if (p is null) return 0;
    if (p.type == JSONType.integer) return p.integer;
    if (p.type == JSONType.uinteger) return cast(long) p.uinteger;
    return 0;
}
private bool gb(JSONValue o, string k) {
    if (o.type != JSONType.object) return false;
    auto p = k in o;
    return p !is null && p.type == JSONType.true_;
}
/// Set a key, Go-omitempty style (zero values remove it).
private void put(ref JSONValue o, string k, JSONValue v) {
    const empty = v.type == JSONType.null_ || (v.type == JSONType.string && v.str.length == 0)
        || (v.type == JSONType.false_) || (v.type == JSONType.integer && v.integer == 0)
        || (v.type == JSONType.array && v.array.length == 0);
    if (empty) { if (k in o) o.object.remove(k); }
    else o[k] = v;
}

final class ChatStore {
    Db db;

    this(Db db) {
        this.db = db;
        db.exec(schema);
    }

    // ── messages ─────────────────────────────────────────────────────────────────────────────

    /// stored: a Msg without what handOut adds (names are looked up when handed out).
    static JSONValue stored(JSONValue m) {
        auto o = JSONValue(m.object.dup);
        foreach (k; ["senderName", "templateNames", "templateKnown", "chatName", "senderPic"]) if (k in o) o.object.remove(k);
        if (auto q = "quotedMsg" in o) {
            auto qq = JSONValue(q.object.dup);
            if ("authorName" in qq) qq.object.remove("authorName");
            o["quotedMsg"] = qq;
        }
        return o;
    }

    /// putMsg: insert or replace a message (a real one replaces a `ciphertext` placeholder). App-state
    /// marks recorded before the message arrived win: a deleted-for-me one is not stored (false), a
    /// starred / unstarred one takes that star.
    bool putMsg(ref JSONValue m, const(ubyte)[] raw) {
        int star;
        bool deleted;
        if (mark(g(m, "account"), g(m, "id"), star, deleted)) {
            if (deleted) return false;
            if (star == 1) m["star"] = true;
            else if (star == 0 && "star" in m) m.object.remove("star");
        }
        auto sm = stored(m);
        putStored(sm, raw);
        return true;
    }
    private void putStored(JSONValue m, const(ubyte)[] raw) {
        const account = g(m, "account"), key = g(m, "id"), remote = g(m, "remote"), id = g(m, "msgId");
        const type = g(m, "type");
        if (type != "ciphertext")
            db.run(`DELETE FROM msgs WHERE account=? AND remote=? AND id=? AND type='ciphertext' AND key!=?`,
                account, remote, id, key);
        db.run(`INSERT INTO msgs(account, key, remote, id, t, type, star, json, raw) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account, key) DO UPDATE SET t=excluded.t, type=excluded.type, star=excluded.star,
              json=excluded.json, raw=COALESCE(excluded.raw, msgs.raw)`,
            account, key, remote, id, gi(m, "t"), type, gb(m, "star"), m.toString(), raw);
        index(m);
    }

    private void index(JSONValue m) {
        db.run(`DELETE FROM msgs_fts WHERE account=? AND key=?`, g(m, "account"), g(m, "id"));
        string body = (g(m, "body") ~ " " ~ g(m, "caption") ~ " " ~ g(m, "pollName")).strip;
        if (auto md = "mediaData" in m) body ~= " " ~ g(*md, "filename");
        if (body.strip.length && g(m, "type") != "revoked")
            db.run(`INSERT INTO msgs_fts(account, key, remote, body) VALUES(?,?,?,?)`,
                g(m, "account"), g(m, "id"), g(m, "remote"), body);
    }

    /// updateMsg: rewrite a stored message (its protobuf stays).
    void updateMsg(JSONValue m) {
        m = stored(m);
        db.run(`UPDATE msgs SET json=?, type=?, star=?, t=? WHERE account=? AND key=?`,
            m.toString(), g(m, "type"), gb(m, "star"), gi(m, "t"), g(m, "account"), g(m, "id"));
        index(m);
    }

    bool msg(string account, string key, out JSONValue m, out ubyte[] raw) {
        return msgWhere(`account=? AND key=?`, m, raw, account, key);
    }
    /// msgByID: a message by chat + bare id (add-ons name their parent this way).
    bool msgByID(string account, string remote, string id, out JSONValue m) {
        ubyte[] raw;
        return msgWhere(`account=? AND remote=? AND id=? ORDER BY type='ciphertext' LIMIT 1`, m, raw, account, remote, id);
    }
    private bool msgWhere(Args...)(string where, out JSONValue m, out ubyte[] raw, Args args) {
        bool found;
        foreach (ref r; db.query(`SELECT json, raw FROM msgs WHERE ` ~ where, args)) {
            try m = parseJSON(r.text(0)); catch (Exception) return false;
            raw = r.blob(1);
            found = true;
            break;
        }
        return found;
    }

    // ── app-state marks (star / delete for me), kept for messages that arrive after them ─────────

    void setStarMark(string account, string key, bool starred) {
        db.run(`INSERT INTO msg_marks(account, key, star) VALUES(?,?,?)
            ON CONFLICT(account, key) DO UPDATE SET star=excluded.star`, account, key, starred ? 1 : 0);
    }
    void setDeleteMark(string account, string key) {
        db.run(`INSERT INTO msg_marks(account, key, deleted) VALUES(?,?,1)
            ON CONFLICT(account, key) DO UPDATE SET deleted=1`, account, key);
    }
    /// mark: star is -1 (none), 0 or 1.
    bool mark(string account, string key, out int star, out bool deleted) {
        foreach (ref r; db.query(`SELECT star, deleted FROM msg_marks WHERE account=? AND key=?`, account, key)) {
            star = cast(int) r.int64(0);
            deleted = r.int64(1) != 0;
            return true;
        }
        star = -1;
        return false;
    }

    /// markRead: the phone read the chat up to t; unread = incoming messages after that.
    void markRead(string account, string chat, long t) {
        db.run(`INSERT INTO chat_read(account, chat, t) VALUES(?,?,?)
            ON CONFLICT(account, chat) DO UPDATE SET t=MAX(chat_read.t, excluded.t)`, account, chat, t);
        t = readAt(account, chat);   // an older replayed mark must not bring unread back
        const n = db.scalarInt(`SELECT count(*) FROM msgs WHERE account=? AND remote=? AND t>?
            AND json_extract(json, '$.fromMe') IS NOT 1`, account, chat, t);
        db.run(`UPDATE chats SET unreadCount=?, unreadMentionCount=0, markedUnread=0 WHERE account=? AND id=?`,
            n, account, chat);
    }
    long readAt(string account, string chat) {
        return db.scalarInt(`SELECT COALESCE(MAX(t), 0) FROM chat_read WHERE account=? AND chat=?`, account, chat);
    }

    /// Favorite stickers (app-state favoriteSticker), by the file's SHA-256 in base64.
    void setFavSticker(string account, string filehash, bool fav, long t) {
        if (fav) db.run(`INSERT INTO fav_stickers(account, filehash, t) VALUES(?,?,?)
            ON CONFLICT(account, filehash) DO UPDATE SET t=excluded.t`, account, filehash, t);
        else db.run(`DELETE FROM fav_stickers WHERE account=? AND filehash=?`, account, filehash);
    }
    /// A community's group → its community (from history's Conversation.parentGroupID), kept apart
    /// from the group metadata: it is still known when we can no longer query the group.
    void setGroupParent(string account, string id, string parent) {
        db.run(`INSERT OR REPLACE INTO group_parent(account, id, parent) VALUES(?,?,?)`, account, id, parent);
    }
    string groupParent(string account, string id) {
        return db.scalarText(`SELECT parent FROM group_parent WHERE account=? AND id=?`, account, id);
    }
    bool isFavSticker(string account, string filehash) {
        return db.scalarInt(`SELECT count(*) FROM fav_stickers WHERE account=? AND filehash=?`, account, filehash) > 0;
    }

    void deleteMsg(string account, string key) {
        db.run(`DELETE FROM msgs WHERE account=? AND key=?`, account, key);
        db.run(`DELETE FROM msgs_fts WHERE account=? AND key=?`, account, key);
    }

    private JSONValue[] msgList(Args...)(string q, Args args) {
        JSONValue[] out_;
        foreach (ref r; db.query(q, args)) try out_ ~= parseJSON(r.text(0)); catch (Exception) {}
        return out_;
    }

    /// msgsByType: the newest messages of some types across every chat, statuses left out (the
    /// calls panel: call_log; the media panel: image/video, document) — core/panels.go msgsByType.
    /// One query per type (the binder takes a fixed argument list), merged newest first.
    JSONValue[] msgsByType(string account, string[] types, int limit) {
        import std.algorithm : sort;
        if (limit <= 0 || limit > 500) limit = 100;
        JSONValue[] all;
        foreach (ty; types)
            all ~= msgList(`SELECT json FROM msgs WHERE account=? AND remote!='status@broadcast' AND type=? ORDER BY t DESC LIMIT ?`,
                account, ty, limit);
        all.sort!((x, y) => x["t"].integer > y["t"].integer);
        return all.length > limit ? all[0 .. limit] : all;
    }

    /// linkMsgs: text messages with a link, newest first (the media panel's Links) — core/panels.go.
    JSONValue[] linkMsgs(string account, int limit) {
        if (limit <= 0 || limit > 500) limit = 200;
        return msgList(`SELECT json FROM msgs WHERE account=? AND remote!='status@broadcast' AND type='chat'
            AND (json LIKE '%"matchedText"%' OR json LIKE '%http://%' OR json LIKE '%https://%') ORDER BY t DESC LIMIT ?`,
            account, limit);
    }

    /// msgs: a chat's window, oldest first (before: only messages older than this time).
    /// `beforeKey`: the oldest message shown — the page continues strictly before it in the same
    /// (t, rowid) order, so a second holding more messages than a page is not skipped or repeated.
    /// msgsAfter: the page right after a message (oldest first) — scrolling down from a search jump.
    JSONValue[] msgsAfter(string account, string remote, string afterKey, int limit) {
        if (limit <= 0 || limit > 500) limit = 60;
        long kt = -1, krow;
        foreach (ref r; db.query(`SELECT t, rowid FROM msgs WHERE account=? AND key=?`, account, afterKey)) { kt = r.int64(0); krow = r.int64(1); }
        if (kt < 0) return null;
        return msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND t>=? AND (t>? OR (t=? AND rowid>?))
            ORDER BY t ASC, rowid ASC LIMIT ?`, account, remote, kt, kt, kt, krow, limit);
    }

    /// `inclusive`: the page ends at that message (a search hit: it must be in the window).
    JSONValue[] msgs(string account, string remote, long before, int limit, string beforeKey = null, bool inclusive = false) {
        if (limit <= 0 || limit > 500) limit = 60;
        if (before <= 0) before = 1L << 62;
        long kt = -1, krow;
        if (beforeKey.length)
            foreach (ref r; db.query(`SELECT t, rowid FROM msgs WHERE account=? AND key=?`, account, beforeKey)) { kt = r.int64(0); krow = r.int64(1); }
        auto l = kt >= 0
            ? msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND t<=? AND (t<? OR (t=? AND rowid` ~ (inclusive ? "<=" : "<")
                ~ `?)) ORDER BY t DESC, rowid DESC LIMIT ?`, account, remote, kt, kt, kt, krow, limit)
            : msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND t<? ORDER BY t DESC, rowid DESC LIMIT ?`,
                account, remote, before, limit);
        import std.algorithm : reverse;
        reverse(l);
        return l;
    }

    bool oldestMsg(string account, string remote, out JSONValue m) {
        auto l = msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND type NOT IN
            ('gp2','e2e_notification','notification_template','call_log') ORDER BY t ASC LIMIT 1`, account, remote);
        if (l.length == 0) return false;
        m = l[0];
        return true;
    }

    /// lastMsg: the chat's newest message (the chat list's preview) — not the security notices,
    /// nor who joined or left (as WhatsApp Web).
    bool lastMsg(string account, string remote, out JSONValue m) {
        auto l = msgList(`SELECT json FROM msgs WHERE account=? AND remote=? AND type!='e2e_notification'
            AND NOT (type='gp2' AND json_extract(json, '$.subtype') IN
              ('add','remove','leave','invite','linked_group_join','community_link','member_add_mode'))
            ORDER BY t DESC, rowid DESC LIMIT 1`, account, remote);
        if (l.length == 0) return false;
        m = l[0];
        return true;
    }

    JSONValue[] search(string account, string query, string remote, int limit) {
        if (limit <= 0 || limit > 200) limit = 30;
        if (remote.length)
            return msgList(`SELECT m.json FROM msgs_fts f JOIN msgs m ON m.account=f.account AND m.key=f.key
                WHERE msgs_fts MATCH ? AND f.account=? AND f.remote=? ORDER BY m.t DESC LIMIT ?`, query, account, remote, limit);
        return msgList(`SELECT m.json FROM msgs_fts f JOIN msgs m ON m.account=f.account AND m.key=f.key
            WHERE msgs_fts MATCH ? AND f.account=? ORDER BY m.t DESC LIMIT ?`, query, account, limit);
    }

    /// clearChat: the chat's messages up to t go (keepStarred keeps starred ones).
    string[] clearChat(string account, string remote, long t, bool keepStarred) {
        string[] keys;
        auto q = `SELECT key FROM msgs WHERE account=? AND remote=? AND t<=?` ~ (keepStarred ? ` AND star=0` : ``);
        foreach (ref r; db.query(q, account, remote, t)) keys ~= r.text(0);
        foreach (k; keys) deleteMsg(account, k);
        return keys;
    }

    // ── add-ons ──────────────────────────────────────────────────────────────────────────────

    /// applyAddon: a reaction, edit or revoke changes its parent; parked when the parent is not
    /// here yet. Returns whether a parent changed (and gives it).
    bool applyAddon(string account, string remote, const Addon a, string sender, bool fromMe, out JSONValue parent) {
        if (!msgByID(account, remote, a.parentId, parent)) {
            JSONValue j = ["Kind": JSONValue(a.kind), "ParentID": JSONValue(a.parentId), "Sender": JSONValue(sender),
                "FromMe": JSONValue(fromMe), "Text": JSONValue(a.text), "T": JSONValue(a.t)];
            if (a.edited.type == JSONType.object) j["Edited"] = a.edited;
            if (a.tMs > 0) j["TMs"] = a.tMs;
            db.run(`INSERT INTO orphans(account, remote, parent, kind, json, t) VALUES(?,?,?,?,?,?)`,
                account, remote, a.parentId, a.kind, j.toString(), a.t);
            return false;
        }
        switch (a.kind) {
            case "reaction":
                if (a.text.length == 0)
                    db.run(`DELETE FROM reactions WHERE account=? AND remote=? AND parent=? AND sender=?`,
                        account, remote, a.parentId, sender);
                else
                    db.run(`INSERT INTO reactions(account, remote, parent, sender, text, t, fromMe) VALUES(?,?,?,?,?,?,?)
                        ON CONFLICT(account, remote, parent, sender) DO UPDATE SET text=excluded.text, t=excluded.t`,
                        account, remote, a.parentId, sender, a.text, a.t, fromMe);
                put(parent, "reactions", JSONValue(aggReactions(account, remote, a.parentId)));
                break;
            case "edit":
                // only a newer edit changes it: a late one (an orphan adopted after a history copy
                // already brought a later edit, a re-delivery) would put old text back. Ordered in ms
                // (latestEditMs; a history edit only knows its second: that second × 1000)
                {
                    const incoming = a.tMs > 0 ? a.tMs : a.t * 1000;
                    long stored = -1;
                    if (auto lm = "latestEditMs" in parent) { if (lm.type == JSONType.integer) stored = lm.integer; }
                    else if (auto le = "latestEditSenderTimestamp" in parent) { if (le.type == JSONType.integer) stored = le.integer * 1000; }
                    if (incoming > 0 && stored >= 0 && incoming <= stored) return false;
                    if (incoming > 0) put(parent, "latestEditMs", JSONValue(incoming));
                }
                if (a.edited.type == JSONType.object) {
                    if (g(parent, "type") == "chat") put(parent, "body", JSONValue(g(a.edited, "body")));
                    else put(parent, "caption", JSONValue(previewBody(a.edited)));
                    auto ml = "mentionedJidList" in a.edited;
                    put(parent, "mentionedJidList", ml is null ? JSONValue(null) : *ml);
                }
                parent["isEdited"] = true;
                put(parent, "latestEditSenderTimestamp", JSONValue(a.t));
                break;
            case "revoke":
                parent["type"] = "revoked";
                string rs = "sender_revoke";
                // in a group, someone other than the author revoking it is an admin
                if (!gb(parent, "fromMe") && g(parent, "author").length && sender.length && sender != g(parent, "author"))
                    rs = "admin_revoke";
                parent["revokeSender"] = rs;
                foreach (k; ["body", "caption", "mediaData", "quotedMsg", "reactions", "title", "description",
                        "thumbnail", "matchedText", "pollName", "pollOptions", "vcardList"])
                    if (k in parent) parent.object.remove(k);
                break;
            default:
                return false;
        }
        updateMsg(parent);
        return true;
    }

    /// adoptOrphans: the add-ons that arrived before m, applied now (history arrives out of order).
    bool adoptOrphans(ref JSONValue m) {
        struct O { long rowid; Addon a; string sender; bool fromMe; }
        O[] list;
        foreach (ref r; db.query(`SELECT rowid, json FROM orphans WHERE account=? AND remote=? AND parent=? ORDER BY t`,
                g(m, "account"), g(m, "remote"), g(m, "msgId"))) {
            JSONValue j;
            try j = parseJSON(r.text(1)); catch (Exception) continue;
            O o;
            o.rowid = r.int64(0);
            o.a.kind = g(j, "Kind");
            o.a.parentId = g(j, "ParentID");
            o.a.text = g(j, "Text");
            o.a.t = gi(j, "T");
            o.a.tMs = gi(j, "TMs");
            if (auto e = "Edited" in j) o.a.edited = *e;
            o.sender = g(j, "Sender");
            o.fromMe = gb(j, "FromMe");
            list ~= o;
        }
        if (list.length == 0) return false;
        foreach (o; list) {
            db.run(`DELETE FROM orphans WHERE rowid=?`, o.rowid);
            JSONValue p;
            if (applyAddon(g(m, "account"), g(m, "remote"), o.a, o.sender, o.fromMe, p)) m = p;
        }
        return true;
    }

    /// aggReactions: one entry per emoji with its senders, the most reacted first.
    JSONValue[] aggReactions(string account, string remote, string parent) {
        import std.algorithm : sort;
        string[] order;
        string[][string] senders;
        bool[string] mine;
        foreach (ref r; db.query(`SELECT sender, text, fromMe FROM reactions WHERE account=? AND remote=? AND parent=? ORDER BY t`,
                account, remote, parent)) {
            const text = r.text(1);
            if (text !in senders) { order ~= text; senders[text] = null; }
            senders[text] ~= r.text(0);
            mine[text] = mine.get(text, false) || r.int64(2) != 0;
        }
        // stable sort by sender count, descending
        import std.algorithm : SwapStrategy;
        sort!((a, b) => senders[a].length > senders[b].length, SwapStrategy.stable)(order);
        JSONValue[] out_;
        foreach (e; order) {
            JSONValue[] ss;
            foreach (s; senders[e]) ss ~= JSONValue(s);
            out_ ~= JSONValue(["aggregateEmoji": JSONValue(e), "senders": JSONValue(ss), "hasReactionByMe": JSONValue(mine[e])]);
        }
        return out_;
    }

    /// raiseAck: receipts only ever move a message's ack up.
    JSONValue[] raiseAck(string account, string remote, string[] ids, int ack) {
        JSONValue[] changed;
        foreach (id; ids) {
            JSONValue m;
            if (msgByID(account, remote, id, m) && gb(m, "fromMe") && ack > gi(m, "ack")) {
                m["ack"] = ack;
                updateMsg(m);
                changed ~= m;
            }
        }
        return changed;
    }

    // ── chats ────────────────────────────────────────────────────────────────────────────────

    private enum chatCols = `id, name, t, unreadCount, unreadMentionCount, markedUnread, archive, pin, muteExpiration,
        isReadOnly, isAnnounceGrpRestrict, ephemeralDuration, endOfHistoryTransferType, draftMessage, isParentGroup, account`;

    bool chat(string account, string id, out JSONValue c) {
        auto l = chatList(`account=? AND id=?`, account, id);
        if (l.length == 0) return false;
        c = l[0];
        return true;
    }
    JSONValue[] chats(string account) {
        return chatList(`account=? AND deleted=0 AND t>0 ORDER BY pin DESC, t DESC`, account);
    }
    private JSONValue[] chatList(Args...)(string where, Args args) {
        JSONValue[] out_;
        foreach (ref r; db.query(`SELECT ` ~ chatCols ~ ` FROM chats WHERE ` ~ where, args)) {
            JSONValue c = JSONValue.emptyObject;
            c["id"] = r.text(0);
            c["account"] = r.text(15);
            c["kind"] = chatKind(r.text(0), r.int64(14) != 0);
            c["name"] = r.text(1);
            c["t"] = r.int64(2);
            c["unreadCount"] = r.int64(3);
            c["unreadMentionCount"] = r.int64(4);
            c["markedUnread"] = r.int64(5) != 0;
            c["archive"] = r.int64(6) != 0;
            c["pin"] = r.int64(7);
            c["muteExpiration"] = r.int64(8);
            c["isReadOnly"] = r.int64(9) != 0;
            c["isAnnounceGrpRestrict"] = r.int64(10) != 0;
            c["ephemeralDuration"] = r.int64(11);
            c["endOfHistoryTransferType"] = r.int64(12);
            if (r.text(13).length) c["draftMessage"] = r.text(13);
            out_ ~= c;
        }
        return out_;
    }

    /// ensureChat: the chat exists (a message to or from a new chat creates it).
    void ensureChat(string account, string id) {
        db.run(`INSERT INTO chats(account, id) VALUES(?,?) ON CONFLICT(account, id) DO NOTHING`, account, id);
    }

    /// bumpChat: a message moved the chat — its time, and the unread count for an incoming one.
    void bumpChat(JSONValue m, bool countUnread, bool mentionsMe) {
        ensureChat(g(m, "account"), g(m, "remote"));
        long inc, men;
        // a late message older than the phone's read mark is already read
        if (countUnread && !gb(m, "fromMe") && gi(m, "t") > readAt(g(m, "account"), g(m, "remote"))) {
            inc = 1;
            if (mentionsMe) men = 1;
        }
        db.run(`UPDATE chats SET t=MAX(t, ?), unreadCount=unreadCount+?, unreadMentionCount=unreadMentionCount+?, deleted=0
            WHERE account=? AND id=?`, gi(m, "t"), inc, men, g(m, "account"), g(m, "remote"));
    }

    /// setChat: one column (app-state actions and group metadata write these).
    void setChat(T)(string account, string id, string column, T value) {
        import std.algorithm : canFind;
        static immutable cols = ["name", "t", "unreadCount", "unreadMentionCount", "markedUnread", "archive", "pin",
            "muteExpiration", "isReadOnly", "isAnnounceGrpRestrict", "ephemeralDuration", "endOfHistoryTransferType",
            "draftMessage", "isParentGroup", "clearedAt", "deleted"];
        if (!cols.canFind(column)) return;
        ensureChat(account, id);
        db.run(`UPDATE chats SET ` ~ column ~ `=? WHERE account=? AND id=?`, value, account, id);
    }
    void setChatName(string account, string id, string name) { if (name.length) setChat(account, id, "name", name); }

    // ── contacts ─────────────────────────────────────────────────────────────────────────────

    JSONValue contact(string account, string id) {
        string name, shortName, pushname, verifiedName, phone, status, pic;
        bool biz, blocked;
        foreach (ref r; db.query(`SELECT name, shortName, pushname, verifiedName, isBusiness, blocked, phoneNumber, status, pic
                FROM contacts WHERE account=? AND id=?`, account, id)) {
            name = r.text(0); shortName = r.text(1); pushname = r.text(2); verifiedName = r.text(3);
            biz = r.int64(4) != 0; blocked = r.int64(5) != 0; phone = r.text(6); status = r.text(7); pic = r.text(8);
            break;
        }
        if (phone.length == 0 && id.endsWith("@s.whatsapp.net")) phone = id[0 .. id.indexOf('@')];
        JSONValue c = JSONValue.emptyObject;
        c["id"] = id;
        c["account"] = account;
        put(c, "name", JSONValue(name));
        put(c, "shortName", JSONValue(shortName));
        put(c, "pushname", JSONValue(pushname));
        put(c, "verifiedName", JSONValue(verifiedName));
        put(c, "isBusiness", JSONValue(biz));
        put(c, "isContactBlocked", JSONValue(blocked));
        put(c, "phoneNumber", JSONValue(phone));
        put(c, "status", JSONValue(status));
        put(c, "profilePicThumb", JSONValue(pic));
        c["formattedName"] = formattedName(id, name, verifiedName, pushname, phone);
        return c;
    }

    /// setContact: one column (empty strings never erase what is known).
    void setContact(T)(string account, string id, string column, T value) {
        import std.algorithm : canFind;
        static immutable cols = ["name", "shortName", "pushname", "verifiedName", "isBusiness", "blocked",
            "phoneNumber", "status", "pic"];
        if (!cols.canFind(column)) return;
        static if (is(T : const(char)[])) { if (value.length == 0) return; }
        db.run(`INSERT INTO contacts(account, id) VALUES(?,?) ON CONFLICT(account, id) DO NOTHING`, account, id);
        db.run(`UPDATE contacts SET ` ~ column ~ `=? WHERE account=? AND id=?`, value, account, id);
    }

    // ── groups, pins, statuses ───────────────────────────────────────────────────────────────

    bool group(string account, string id, out JSONValue gm) {
        const j = db.scalarText(`SELECT json FROM groups WHERE account=? AND id=?`, account, id);
        if (j.length == 0) return false;
        try gm = parseJSON(j); catch (Exception) return false;
        return true;
    }
    void putGroup(JSONValue gm) {
        const account = g(gm, "account"), id = g(gm, "id");
        db.run(`INSERT INTO groups(account, id, json) VALUES(?,?,?) ON CONFLICT(account, id) DO UPDATE SET json=excluded.json`,
            account, id, gm.toString());
        setChatName(account, id, g(gm, "subject"));
        setChat(account, id, "isAnnounceGrpRestrict", gb(gm, "announce"));
        setChat(account, id, "ephemeralDuration", gi(gm, "ephemeralDuration"));
        setChat(account, id, "isParentGroup", gb(gm, "isParentGroup"));
    }
    bool statusSeen(string account, string key) {
        return db.scalarInt(`SELECT count(*) FROM status_seen WHERE account=? AND key=?`, account, key) > 0;
    }
    void markStatusSeen(string account, string key) {
        db.run(`INSERT OR IGNORE INTO status_seen(account, key) VALUES(?, ?)`, account, key);
    }
    bool statusMuted(string account, string id) {
        return db.scalarInt(`SELECT count(*) FROM status_mute WHERE account=? AND id=?`, account, id) > 0;
    }
    void setStatusMuted(string account, string id, bool muted) {
        if (muted) db.run(`INSERT OR IGNORE INTO status_mute(account, id) VALUES(?, ?)`, account, id);
        else db.run(`DELETE FROM status_mute WHERE account=? AND id=?`, account, id);
    }
    void setChatPin(string account, string chat, string msg, long until) {
        if (msg.length == 0) { db.run(`DELETE FROM chat_pins WHERE account=? AND chat=?`, account, chat); return; }
        db.run(`INSERT INTO chat_pins(account, chat, msg, until) VALUES(?,?,?,?)
            ON CONFLICT(account, chat) DO UPDATE SET msg=excluded.msg, until=excluded.until`, account, chat, msg, until);
    }
    void chatPin(string account, string chat, out string msg, out long until) {
        string m;
        long u;
        foreach (ref r; db.query(`SELECT msg, until FROM chat_pins WHERE account=? AND chat=?`, account, chat)) {
            m = r.text(0);
            u = r.int64(1);
            break;
        }
        msg = m;
        until = u;
    }

    /// mergeLidChat: a 1:1 chat stored under the contact's LID before its phone number was known
    /// (`lid` "…@lid") folds into the number's chat (`pn` "…@s.whatsapp.net"), as canonical() would
    /// have filed it: each message moves with its new key (one already there under the number — the
    /// same message seen both ways — wins, the LID copy goes), and everything keyed by them follows
    /// (search, marks, pins, sticker items, reactions, orphans, the read mark). Returns the messages
    /// moved. One transaction.
    size_t mergeLidChat(string account, string lid, string pn) {
        import wa.model : msgKey;
        size_t moved;
        db.transaction({
            struct Row { string key, id; bool fromMe; }
            Row[] rows;
            foreach (ref r; db.query(`SELECT key, id, json FROM msgs WHERE account=? AND remote=?`, account, lid)) {
                bool fm;
                try fm = parseJSON(r.text(2))["fromMe"].type == JSONType.true_; catch (Exception) {}
                rows ~= Row(r.text(0), r.text(1), fm);
            }
            foreach (ref row; rows) {
                const nk = msgKey(row.fromMe, pn, row.id, "");
                const taken = db.scalarInt(`SELECT count(*) FROM msgs WHERE account=? AND key=?`, account, nk) > 0;
                if (taken) {
                    db.run(`DELETE FROM msgs WHERE account=? AND key=?`, account, row.key);
                    db.run(`DELETE FROM msgs_fts WHERE account=? AND key=?`, account, row.key);
                    db.run(`DELETE FROM msg_marks WHERE account=? AND key=?`, account, row.key);
                    continue;
                }
                JSONValue m;
                foreach (ref r; db.query(`SELECT json FROM msgs WHERE account=? AND key=?`, account, row.key)) { m = parseJSON(r.text(0)); break; }
                m["id"] = nk;
                m["remote"] = pn;
                if (row.fromMe) { if ("to" in m) m["to"] = pn; }
                else { if ("from" in m) m["from"] = pn; }
                db.run(`UPDATE msgs SET key=?, remote=?, json=? WHERE account=? AND key=?`, nk, pn, m.toString(), account, row.key);
                db.run(`UPDATE msgs_fts SET key=?, remote=? WHERE account=? AND key=?`, nk, pn, account, row.key);
                db.run(`UPDATE OR REPLACE msg_marks SET key=? WHERE account=? AND key=?`, nk, account, row.key);
                db.run(`UPDATE chat_pins SET msg=? WHERE account=? AND msg=?`, nk, account, row.key);
                db.run(`UPDATE sticker_pack_items SET msg=? WHERE account=? AND msg=?`, nk, account, row.key);
                moved++;
            }
            db.run(`UPDATE OR REPLACE reactions SET remote=? WHERE account=? AND remote=?`, pn, account, lid);
            db.run(`UPDATE orphans SET remote=? WHERE account=? AND remote=?`, pn, account, lid);
            db.run(`UPDATE OR IGNORE chat_pins SET chat=? WHERE account=? AND chat=?`, pn, account, lid);
            db.run(`DELETE FROM chat_pins WHERE account=? AND chat=?`, account, lid);
            // the read mark: the later of the two
            const readL = readAt(account, lid);
            if (readL > readAt(account, pn)) markRead(account, pn, readL);
            db.run(`DELETE FROM chat_read WHERE account=? AND chat=?`, account, lid);
            // the chat row: the number's keeps its settings; it gains the later time and the unread
            // count; with none under the number, the LID's row becomes it
            if (db.scalarInt(`SELECT count(*) FROM chats WHERE account=? AND id=?`, account, pn) == 0)
                db.run(`UPDATE chats SET id=? WHERE account=? AND id=?`, pn, account, lid);
            else {
                db.run(`UPDATE chats SET t=max(t, (SELECT t FROM chats WHERE account=? AND id=?)),
                    unreadCount=unreadCount + (SELECT unreadCount FROM chats WHERE account=? AND id=?)
                    WHERE account=? AND id=?`, account, lid, account, lid, account, pn);
                db.run(`DELETE FROM chats WHERE account=? AND id=?`, account, lid);
            }
        });
        return moved;
    }
}

/// chatKind: Chat.kind from the id's server (WhatsApp Web derives it the same way).
string chatKind(string jid, bool isParent) {
    if (jid.endsWith("@g.us")) return isParent ? "community" : "group";
    if (jid.endsWith("@broadcast")) return "broadcast";
    if (jid.endsWith("@newsletter")) return "newsletter";
    return "user";
}

/// formatPhone: "+55 11 98888-7777" for Brazil, "+1 NNN-NNN-NNNN" for NANP, "+<cc><rest>" else.
string formatPhone(string n) {
    if (n.startsWith("+")) n = n[1 .. $];
    if (n.startsWith("55") && (n.length == 12 || n.length == 13)) {
        const local = n[4 .. $];
        const cut = local.length - 4;
        return "+55 " ~ n[2 .. 4] ~ " " ~ local[0 .. cut] ~ "-" ~ local[cut .. $];
    }
    if (n.startsWith("1") && n.length == 11) return "+1 " ~ n[1 .. 4] ~ "-" ~ n[4 .. 7] ~ "-" ~ n[7 .. $];
    return "+" ~ n;
}

/// formattedName: WhatsApp Web's precedence — address book, verified business, ~push name, phone.
string formattedName(string id, string name, string verifiedName, string pushname, string phone) {
    if (name.length) return name;
    if (verifiedName.length) return "~" ~ verifiedName;
    if (pushname.length) return "~" ~ pushname;
    if (phone.length) return formatPhone(phone);
    if (id.endsWith("@lid")) return "Contato do WhatsApp";
    const at = id.indexOf('@');
    return at < 0 ? id : id[0 .. at];
}

/// chatTitle: a 1:1 chat's title in the list — address-book name, verified name, push name, number.
string chatTitle(string id, string name, string verifiedName, string pushname, string phone) {
    if (name.length) return name;
    if (verifiedName.length) return verifiedName;
    if (pushname.length) return pushname;
    if (phone.length) return formatPhone(phone);
    if (id.endsWith("@lid")) return "Contato do WhatsApp";
    const at = id.indexOf('@');
    return at < 0 ? id : id[0 .. at];
}

/// oneLine: a preview is one line — breaks and runs of spaces become one space; a markdown table
/// reads as its first row ("a · b"), headings lose their #, no ** around bold.
string oneLine(string s) {
    import std.string : strip, replace;
    import std.array : array;
    import std.algorithm : map, filter;
    import std.uni : isWhite;
    string[] outv;
    bool inTable;
    foreach (l; s.split("\n")) {
        auto t = l.strip;
        if (t.length > 1 && t[0] == '|' && t[$ - 1] == '|') {
            import std.string : strip;
            bool onlyRule = true;
            foreach (ch; t) if (ch != '|' && ch != '-' && ch != ':' && ch != ' ') { onlyRule = false; break; }
            if (!inTable && !onlyRule) {
                auto cells = t[1 .. $ - 1].split("|").map!(c => c.strip).array;
                outv ~= cells.join(" · ");
            }
            inTable = true;
            continue;
        }
        inTable = false;
        size_t i;
        while (i < t.length && t[i] == '#') i++;
        if (i > 0 && i < t.length && t[i] == ' ') t = t[i .. $];
        outv ~= t;
    }
    auto joined = outv.join(" ").replace("**", "");
    import std.array : split;
    return joined.split.join(" ");
}

unittest {
    // mergeLidChat: a message only under the LID moves (new key, remote, from); one under both stays
    // once; the chat row folds into the number's
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-chats-lid-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto cs = new ChatStore(new Db(path));
    enum acc = "me", lid = "136@lid", pn = "5511@s.whatsapp.net";
    JSONValue a = ["id": JSONValue("false_136@lid_A1"), "account": JSONValue(acc), "remote": JSONValue(lid),
        "from": JSONValue(lid), "msgId": JSONValue("A1"), "t": JSONValue(100), "type": JSONValue("chat"),
        "body": JSONValue("so pelo lid"), "fromMe": JSONValue(false)];
    JSONValue b = ["id": JSONValue("true_136@lid_B1"), "account": JSONValue(acc), "remote": JSONValue(lid),
        "to": JSONValue(lid), "msgId": JSONValue("B1"), "t": JSONValue(200), "type": JSONValue("chat"),
        "body": JSONValue("nos dois"), "fromMe": JSONValue(true)];
    JSONValue b2 = ["id": JSONValue("true_5511@s.whatsapp.net_B1"), "account": JSONValue(acc), "remote": JSONValue(pn),
        "to": JSONValue(pn), "msgId": JSONValue("B1"), "t": JSONValue(200), "type": JSONValue("chat"),
        "body": JSONValue("nos dois"), "fromMe": JSONValue(true)];
    cs.putMsg(a, [1]);
    cs.putMsg(b, null);
    cs.putMsg(b2, null);
    cs.bumpChat(a, true, false);
    cs.bumpChat(b2, false, false);
    cs.setStarMark(acc, "false_136@lid_A1", true);
    assert(cs.mergeLidChat(acc, lid, pn) == 1);
    JSONValue back;
    ubyte[] raw;
    assert(cs.msg(acc, "false_5511@s.whatsapp.net_A1", back, raw) && back["remote"].str == pn && back["from"].str == pn && raw == [1]);
    assert(!cs.msg(acc, "false_136@lid_A1", back, raw) && !cs.msg(acc, "true_136@lid_B1", back, raw));
    assert(cs.msg(acc, "true_5511@s.whatsapp.net_B1", back, raw));
    int star;
    bool del;
    assert(cs.mark(acc, "false_5511@s.whatsapp.net_A1", star, del) && star == 1);
    JSONValue c;
    assert(!cs.chat(acc, lid, c) && cs.chat(acc, pn, c) && c["unreadCount"].integer == 1);
    assert(cs.search(acc, "pelo", pn, 10).length == 1);
}

unittest {
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-chats-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto cs = new ChatStore(new Db(path));
    enum acc = "me";
    JSONValue m1 = ["id": JSONValue("false_5511@s.whatsapp.net_A1"), "account": JSONValue(acc),
        "remote": JSONValue("5511@s.whatsapp.net"), "msgId": JSONValue("A1"), "t": JSONValue(100),
        "type": JSONValue("chat"), "body": JSONValue("ola mundo"), "fromMe": JSONValue(false), "ack": JSONValue(2)];
    cs.putMsg(m1, [1, 2]);
    cs.bumpChat(m1, true, false);
    JSONValue back;
    assert(cs.msgByID(acc, "5511@s.whatsapp.net", "A1", back) && back["body"].str == "ola mundo");
    assert(cs.search(acc, "mundo", "", 10).length == 1);
    JSONValue c;
    assert(cs.chat(acc, "5511@s.whatsapp.net", c) && c["unreadCount"].integer == 1 && c["kind"].str == "user");

    // a reaction that arrives before its message waits as an orphan, then applies
    Addon r;
    r.kind = "reaction"; r.parentId = "A2"; r.text = "👍"; r.t = 120;
    JSONValue p;
    assert(!cs.applyAddon(acc, "5511@s.whatsapp.net", r, "5511@s.whatsapp.net", false, p));
    JSONValue m2 = ["id": JSONValue("true_5511@s.whatsapp.net_A2"), "account": JSONValue(acc),
        "remote": JSONValue("5511@s.whatsapp.net"), "msgId": JSONValue("A2"), "t": JSONValue(110),
        "type": JSONValue("chat"), "body": JSONValue("oi"), "fromMe": JSONValue(true), "ack": JSONValue(1)];
    cs.putMsg(m2, null);
    assert(cs.adoptOrphans(m2) && m2["reactions"].array.length == 1 && m2["reactions"][0]["aggregateEmoji"].str == "👍");
    // receipts raise our ack; a revoke clears the content
    assert(cs.raiseAck(acc, "5511@s.whatsapp.net", ["A2"], 3).length == 1);
    Addon rv;
    rv.kind = "revoke"; rv.parentId = "A1";
    assert(cs.applyAddon(acc, "5511@s.whatsapp.net", rv, "5511@s.whatsapp.net", false, p));
    assert(p["type"].str == "revoked" && "body" !in p && cs.search(acc, "mundo", "", 10).length == 0);
    assert(cs.msgs(acc, "5511@s.whatsapp.net", 0, 10).length == 2);

    // app-state marks that come before their messages: deleted-for-me is never stored, a star sticks
    cs.setDeleteMark(acc, "false_5511@s.whatsapp.net_A3");
    JSONValue m3 = ["id": JSONValue("false_5511@s.whatsapp.net_A3"), "account": JSONValue(acc),
        "remote": JSONValue("5511@s.whatsapp.net"), "msgId": JSONValue("A3"), "t": JSONValue(130),
        "type": JSONValue("chat"), "body": JSONValue("apagada"), "fromMe": JSONValue(false)];
    assert(!cs.putMsg(m3, null) && !cs.msgByID(acc, "5511@s.whatsapp.net", "A3", back));
    cs.setStarMark(acc, "false_5511@s.whatsapp.net_A4", true);
    JSONValue m4 = ["id": JSONValue("false_5511@s.whatsapp.net_A4"), "account": JSONValue(acc),
        "remote": JSONValue("5511@s.whatsapp.net"), "msgId": JSONValue("A4"), "t": JSONValue(140),
        "type": JSONValue("chat"), "body": JSONValue("estrela"), "fromMe": JSONValue(false)];
    assert(cs.putMsg(m4, null) && cs.msgByID(acc, "5511@s.whatsapp.net", "A4", back) && back["star"].type == JSONType.true_);
    // read up to t=135: only the later incoming message (A4) stays unread
    cs.markRead(acc, "5511@s.whatsapp.net", 135);
    assert(cs.chat(acc, "5511@s.whatsapp.net", c) && c["unreadCount"].integer == 1 && cs.readAt(acc, "5511@s.whatsapp.net") == 135);
    // an older replayed mark keeps the newer one; a late message older than it is not unread
    cs.markRead(acc, "5511@s.whatsapp.net", 50);
    assert(cs.chat(acc, "5511@s.whatsapp.net", c) && c["unreadCount"].integer == 1 && cs.readAt(acc, "5511@s.whatsapp.net") == 135);
    JSONValue late = ["id": JSONValue("false_5511@s.whatsapp.net_A5"), "account": JSONValue(acc),
        "remote": JSONValue("5511@s.whatsapp.net"), "msgId": JSONValue("A5"), "t": JSONValue(120),
        "type": JSONValue("chat"), "body": JSONValue("atrasada"), "fromMe": JSONValue(false)];
    cs.putMsg(late, null);
    cs.bumpChat(late, true, false);
    assert(cs.chat(acc, "5511@s.whatsapp.net", c) && c["unreadCount"].integer == 1);

    cs.setContact(acc, "5511988887777@s.whatsapp.net", "pushname", "Fulano");
    assert(cs.contact(acc, "5511988887777@s.whatsapp.net")["formattedName"].str == "~Fulano");
    assert(formatPhone("5511988887777") == "+55 11 98888-7777" && formatPhone("12025550123") == "+1 202-555-0123");
    assert(oneLine("# Título\n| a | b |\n|---|---|\n| 1 | 2 |\n**negrito**  aqui") == "Título a · b negrito aqui");
}
