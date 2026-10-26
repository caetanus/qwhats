/// The read views the UI asks for — the Go core's fullChat / listed / contactList / profile, ported.
/// They decorate stored rows the way the chat list and the panels expect (titles, last message
/// preview, unknown-contact flag, read-only groups, pinned message).
module wa.app.views;

import std.json;
import std.algorithm : endsWith, sort, map;
import wa.store.sql : Row;
import std.string : indexOf, toLower;
import std.datetime.systime : Clock;
import wa.app.chatstore;
import wa.app.ingest : Ingest;
import wa.model : previewBody;

enum string metaAIJid = "13135550002@s.whatsapp.net";

/// isBotJID: a bot id, or one of the bots' phone numbers.
bool isBotJID(string id) {
    import wa.pb.botmap : botJIDMap;
    import wa.tctoken : isBot;
    import wa.envelope : parseJidString;
    auto j = parseJidString(id);
    if (isBot(j)) return true;
    const user = id.indexOf('@') > 0 ? id[0 .. id.indexOf('@')] : id;
    if (id.endsWith("@bot") && (user in botJIDMap) !is null) return true;
    if (id.endsWith("@s.whatsapp.net")) foreach (b, pn; botJIDMap) if (pn == user) return true;
    return false;
}

private string js(JSONValue o, string k) {
    auto p = k in o;
    return p is null || p.type != JSONType.string ? "" : p.str;
}
private long ji(JSONValue o, string k) {
    auto p = k in o;
    if (p is null) return 0;
    return p.type == JSONType.integer ? p.integer : p.type == JSONType.uinteger ? cast(long) p.uinteger : 0;
}
private bool jb(JSONValue o, string k) {
    auto p = k in o;
    return p !is null && p.type == JSONType.true_;
}

/// LastMsg: the one-line form of a message in the chat list / pinned bar.
private JSONValue lastMsg(JSONValue m, bool withAckAndSubtype) {
    JSONValue l = JSONValue.emptyObject;
    l["id"] = js(m, "id");
    l["type"] = js(m, "type");
    if (withAckAndSubtype && js(m, "subtype").length) l["subtype"] = js(m, "subtype");
    l["body"] = oneLine(previewBody(m));
    l["fromMe"] = jb(m, "fromMe");
    if (js(m, "author").length) l["author"] = js(m, "author");
    if (js(m, "senderName").length) l["senderName"] = js(m, "senderName");
    l["ack"] = withAckAndSubtype ? ji(m, "ack") : 0;
    l["t"] = ji(m, "t");
    return l;
}

private int statusRank(JSONValue a) { return jb(a, "isMe") ? 0 : jb(a, "muted") ? 3 : !jb(a, "viewed") ? 1 : 2; }

final class Views {
    Ingest ing;
    string ownLidJid;   // our LID user JID ("…@lid"), for isMe
    // the global search's people index: decorated chats/contacts and their folded names, rebuilt at
    // most every 15 s (each search used to decorate every chat and query every contact anew)
    private JSONValue[] srChats, srContacts;
    private string[] srChatHay, srContactHay;
    private long srAt;

    this(Ingest ing, string ownLidJid) {
        this.ing = ing;
        this.ownLidJid = ownLidJid;
        ing.chatView = &fullChat;
        ing.chatListed = &listed;
    }

    private ChatStore cs() { return ing.cs; }
    private string acc() { return ing.account; }
    bool isMe(string id) { return id == ing.me || (ownLidJid.length && id == ownLidJid); }

    /// fullChat: a stored chat row as the chat list shows it.
    JSONValue fullChat(JSONValue c) {
        const id = js(c, "id"), kind = js(c, "kind");
        auto k = cs.contact(acc, id);
        if (js(c, "name").length == 0) {
            if (kind == "user")
                c["name"] = chatTitle(id, js(k, "name"), js(k, "verifiedName"), js(k, "pushname"), js(k, "phoneNumber"));
            else c["name"] = id.indexOf('@') > 0 ? id[0 .. id.indexOf('@')] : id;
        }
        if (const p = js(k, "profilePicThumb")) if (p.length && p != "-") c["profilePicThumb"] = p;
        if (kind == "user" && !isBotJID(id) && id != metaAIJid)
            if (js(k, "name").length == 0 && js(k, "verifiedName").length == 0) c["unknown"] = true;
        if (id == metaAIJid) c["name"] = "Meta AI";
        if (kind == "newsletter") {
            JSONValue g;
            if (cs.group(acc, id, g)) {
                if (const sz = ji(g, "size")) c["subscribers"] = sz;
                const bare = id.indexOf('@') > 0 ? id[0 .. id.indexOf('@')] : id;
                if (js(c, "name").length == 0 || js(c, "name") == bare) c["name"] = js(g, "subject");
            }
        }
        if (id.endsWith("@broadcast")) c["isReadOnly"] = true;
        if (kind == "group") {
            JSONValue g;
            if (cs.group(acc, id, g)) {
                if (const parent = js(g, "parentGroup")) if (parent.length) {
                    c["parentGroup"] = parent;
                    if (jb(g, "announce")) c["isAnnounceGroup"] = true;
                    const pp = js(cs.contact(acc, parent), "profilePicThumb");
                    if (pp.length && pp != "-") c["parentPic"] = pp;
                }
                if (auto ps = "participants" in g) if (ps.type == JSONType.array && ps.array.length) {
                    bool inGroup, admin;
                    foreach (p; ps.array) if (isMe(js(p, "id"))) {
                        inGroup = true;
                        admin = jb(p, "isAdmin") || jb(p, "isSuperAdmin");
                    }
                    if (!inGroup) c["isReadOnly"] = true;
                    else {
                        // the server's member list is newer than history's readOnly (left, then back in)
                        c["isReadOnly"] = false;
                        // set either way: the stored flag comes from `announce` alone, and an admin may send
                        c["isAnnounceGrpRestrict"] = jb(g, "announce") && !admin;
                    }
                }
            }
        }
        string pinKey;
        long until;
        cs.chatPin(acc, id, pinKey, until);
        if (pinKey.length && until > Clock.currTime.toUnixTime) {
            JSONValue pm;
            ubyte[] raw;
            if (cs.msg(acc, pinKey, pm, raw)) c["pinnedMsg"] = lastMsg(ing.handOut(pm), false);
        }
        JSONValue m;
        if (cs.lastMsg(acc, id, m)) {
            m = ing.handOut(m);
            c["lastMsg"] = lastMsg(m, true);
            const mt = ji(m, "t");
            if (mt > 0 && mt < ji(c, "t") && kind == "group") c["t"] = mt;   // a membership notice moved it
        }
        return c;
    }

    /// listed: whether a chat belongs in the chat list (status has its own tab; personal chats
    /// only once a message was exchanged; businesses and bots always; known groups/communities).
    bool listed(JSONValue c) {
        const id = js(c, "id"), kind = js(c, "kind");
        if (id == "status@broadcast") return false;
        if (("lastMsg" in c) || ji(c, "pin") > 0 || ji(c, "unreadCount") > 0 || jb(c, "markedUnread")
            || js(c, "draftMessage").length) return true;
        if (kind != "user") return (kind == "group" && ji(c, "t") > 0) || kind == "community";
        auto k = cs.contact(acc, id);
        if (js(k, "verifiedName").length || jb(k, "isBusiness")) return true;
        return isBotJID(id);
    }

    /// Chat.list
    JSONValue[] chatList() {
        JSONValue[] out_;
        foreach (c; cs.chats(acc)) {
            auto f = fullChat(c);
            if (listed(f)) out_ ~= f;
        }
        return out_;
    }

    /// Contact.list: the address book (named phone-number contacts), sorted by name.
    JSONValue[] contactList() {
        string[] ids;
        foreach (ref r; cs.db.query(`SELECT id FROM contacts WHERE account=? AND name!='' AND id LIKE '%@s.whatsapp.net'`, acc))
            ids ~= r.text(0);
        JSONValue[] out_;
        foreach (id; ids) if (id != ing.me) out_ ~= cs.contact(acc, id);
        sort!((a, b) => toLower(js(a, "name")) < toLower(js(b, "name")))(out_);
        return out_;
    }

/// Status.list (the Go core's statusList): the last 24 hours of status@broadcast by author —
    /// mine first, then the unseen ("Recentes"), the seen ("Vistas"), the muted ("Silenciados"),
    /// newest first within each.
    JSONValue[] statusList() {
        import std.datetime.systime : Clock;
        const since = Clock.currTime.toUnixTime - 24 * 3600;
        JSONValue[string] by;
        string[] order;
        foreach (ref r; cs.db.query(`SELECT json FROM msgs WHERE account=? AND remote='status@broadcast' AND t>? AND type!='revoked' ORDER BY t ASC`, acc, since)) {
            JSONValue m;
            try m = parseJSON(r.text(0)); catch (Exception) continue;
            const fromMe = jb(m, "fromMe");
            string who = js(m, "author");
            if (who.length == 0 && !fromMe) continue;   // stored before statuses kept their author
            if (fromMe || who.length == 0) who = ing.me;
            if (who !in by) {
                auto k = cs.contact(acc, who);
                string name = js(k, "formattedName");
                if (name.length == 0) name = chatTitle(who, js(k, "name"), js(k, "verifiedName"), js(k, "pushname"), js(k, "phoneNumber"));
                JSONValue a = ["id": JSONValue(who), "name": JSONValue(name), "t": JSONValue(0L), "items": parseJSON("[]")];
                if (isMe(who)) { a["isMe"] = true; a["name"] = "Meu status"; }
                a["viewed"] = true;
                if (cs.statusMuted(acc, who)) a["muted"] = true;
                const pp = js(k, "profilePicThumb");
                if (pp.length && pp != "-") a["profilePicThumb"] = pp;
                by[who] = a;
                order ~= who;
            }
            auto item = ing.handOut(m);
            const viewed = isMe(who) || cs.statusSeen(acc, js(m, "id"));
            if (viewed) item["viewed"] = true;
            JSONValue a = by[who];
            if (!viewed) a["viewed"] = false;
            JSONValue[] items = a["items"].array;
            items ~= item;
            a["items"] = JSONValue(items);
            a["t"] = ji(m, "t");
            by[who] = a;
        }
        JSONValue[] out_;
        foreach (id; order) {
            auto a = by[id];
            if (!jb(a, "viewed")) a.object.remove("viewed");   // omitempty
            out_ ~= a;
        }
        // insertion sort by (rank, newest first), as the Go core
        for (size_t i = 1; i < out_.length; i++)
            for (size_t k = i; k > 0 && (statusRank(out_[k]) < statusRank(out_[k - 1])
                    || (statusRank(out_[k]) == statusRank(out_[k - 1]) && ji(out_[k], "t") > ji(out_[k - 1], "t"))); k--) {
                auto tmp = out_[k];
                out_[k] = out_[k - 1];
                out_[k - 1] = tmp;
            }
        return out_;
    }

/// namedGroup (the Go core's): participants named ("Você" for me), me first, then admins, then by
    /// name; size = the participants.
    JSONValue namedGroup(JSONValue g) {
        JSONValue[] ps;
        if (auto pp = "participants" in g) if (pp.type == JSONType.array) foreach (p; pp.array) {
            auto q = JSONValue(p.object.dup);
            if (isMe(js(q, "id"))) { q["isMe"] = true; q["name"] = "Você"; }
            else {
                const n = js(cs.contact(acc, js(q, "id")), "formattedName");
                if (n.length) q["name"] = n;
            }
            ps ~= q;
        }
        static string key(JSONValue p) {
            import std.string : toLower;
            auto n = js(p, "name");
            if (n.length && n[0] == '~') n = n[1 .. $];
            return n.toLower;
        }
        import std.algorithm : sort, SwapStrategy;
        sort!((a, b) => jb(a, "isMe") != jb(b, "isMe") ? jb(a, "isMe")
            : jb(a, "isAdmin") != jb(b, "isAdmin") ? jb(a, "isAdmin") : key(a) < key(b), SwapStrategy.stable)(ps);
        g["participants"] = ps.length ? JSONValue(ps) : parseJSON("[]");
        g["size"] = cast(long) ps.length;
        return g;
    }

    /// Community.list (the Go core's communities): the communities in the chat list, and every group
    /// whose parent is one — a community known only through its groups named from its metadata, else
    /// asked of the server (`queryName`), else "Comunidade"
    JSONValue[] communities(string delegate(string) queryName = null) {
        JSONValue[] out_;
        size_t[string] index;
        auto list = chatList();
        foreach (c; list) if (js(c, "kind") == "community") {
            index[js(c, "id")] = out_.length;
            out_ ~= JSONValue(["id": JSONValue(js(c, "id")), "name": JSONValue(js(c, "name")), "groups": parseJSON("[]")]);
        }
        foreach (c; list) {
            if (js(c, "kind") != "group") continue;
            string parent = cs.groupParent(acc, js(c, "id"));
            if (!parent.length) {
                JSONValue gm;
                if (cs.group(acc, js(c, "id"), gm)) parent = js(gm, "parentGroup");
            }
            if (!parent.length) continue;
            auto i = parent in index;
            if (i is null) {
                string name;
                JSONValue pg;
                if (cs.group(acc, parent, pg)) name = js(pg, "subject");
                if (!name.length && queryName !is null) try name = queryName(parent); catch (Exception) {}
                if (!name.length) name = "Comunidade";
                index[parent] = out_.length;
                out_ ~= JSONValue(["id": JSONValue(parent), "name": JSONValue(name), "groups": parseJSON("[]")]);
                i = parent in index;
            }
            out_[*i]["groups"].array ~= c;
        }
        foreach (ref cm; out_) {
            const pic = js(cs.contact(acc, js(cm, "id")), "profilePicThumb");
            if (pic.length && pic != "-") cm["pic"] = pic;
        }
        return out_;
    }

    /// a chat's title as the chat list shows it (core/panels.go chatName)
    string chatName(string id) {
        JSONValue c;
        if (cs.chat(acc, id, c)) return js(fullChat(c), "name");
        auto k = cs.contact(acc, id);
        return chatTitle(id, js(k, "name"), js(k, "verifiedName"), js(k, "pushname"), js(k, "phoneNumber"));
    }

    /// Msg.byType / Msg.links: handed out, each with its chat's name
    JSONValue[] panelMsgs(JSONValue[] list) {
        JSONValue[] out_;
        string[string] names;
        foreach (m; list) {
            auto h = ing.handOut(m);
            const r = js(h, "remote");
            if (r !in names) names[r] = chatName(r);
            h["chatName"] = names[r];
            out_ ~= h;
        }
        return out_;
    }

    /// Msg.list: a chat's window, handed out.
    /// Msg.list afterId: the page after a message, handed out
    JSONValue[] msgListAfter(string chat, string afterKey, int limit) {
        JSONValue[] out_;
        foreach (m; cs.msgsAfter(acc, chat, afterKey, limit)) out_ ~= ing.handOut(m);
        return out_;
    }

    JSONValue[] msgList(string chat, long before, int limit, string throughKey = null) {
        JSONValue[] out_;
        foreach (m; cs.msgs(acc, chat, before, limit, throughKey, throughKey.length > 0)) out_ ~= ing.handOut(m);
        return out_;
    }

    /// Search.run: the search box, in the database — chats whose title or number has every word of
    /// the query (accents and case ignored), and messages by full-text search: each word as a prefix
    /// ("cas" finds "casa"), ranked by BM25, each with its matched excerpt as StyledText (the match
    /// bold and green). `scope` limits the messages to one chat (and leaves chats out).
    JSONValue searchRun(string query, string inChat, int limit) {
        import std.uni : toLower, normalize, NFD, isMark, isAlpha, isNumber;
        import std.array : array, join, replace;
        import std.algorithm : filter, all, canFind, splitter;
        import std.conv : to;
        if (limit <= 0 || limit > 100) limit = 50;
        static string fold(string s) {
            import std.uni : toLower, normalize, NFD, isMark;
            import std.algorithm : filter;
            import std.conv : to;
            return normalize!NFD(s).filter!(c => !isMark(c)).to!string.toLower;
        }
        // the words (letters / digits runs)
        string[] words;
        {
            string cur;
            foreach (dchar c; query) {
                if (isAlpha(c) || isNumber(c)) cur ~= c;
                else if (cur.length) { words ~= cur; cur = null; }
            }
            if (cur.length) words ~= cur;
        }
        JSONValue res = JSONValue.emptyObject;
        JSONValue[] chatsOut, msgsOut;
        if (words.length && inChat.length == 0) {
            auto fw = words.map!(w => fold(w)).array;
            bool[string] have;
            {
                import std.datetime.systime : Clock;
                const now = Clock.currTime.toUnixTime!long;
                if (now - srAt >= 15 || srChats.length + srContacts.length == 0) {
                    srChats = null; srChatHay = null; srContacts = null; srContactHay = null;
                    // people only: groups, communities and channels are found by their messages
                    foreach (c; chatList()) if (js(c, "kind") == "user") { srChats ~= c; srChatHay ~= fold(js(c, "name") ~ " " ~ js(c, "id")); }
                    foreach (k; contactList()) { srContacts ~= k; srContactHay ~= fold(js(k, "name") ~ " " ~ js(k, "pushname") ~ " " ~ js(k, "id")); }
                    srAt = now;
                }
            }
            foreach (i, c; srChats) {
                if (fw.all!(w => srChatHay[i].canFind(w))) { chatsOut ~= c; have[js(c, "id")] = true; }
                if (chatsOut.length >= 30) break;
            }
            // the address book: people with no chat yet, as chat-shaped entries (the list draws both)
            foreach (i, k; srContacts) {
                if (chatsOut.length >= 40) break;
                const id = js(k, "id");
                if (id in have) continue;
                if (!fw.all!(w => srContactHay[i].canFind(w))) continue;
                JSONValue c = ["id": JSONValue(id), "kind": JSONValue("user"), "name": JSONValue(js(k, "name"))];
                const pp = js(k, "profilePicThumb");
                if (pp.length && pp != "-") c["profilePicThumb"] = pp;
                chatsOut ~= c;
            }
        }
        if (words.length) {
            string fts;
            foreach (i, w; words) fts ~= (i ? " " : "") ~ `"` ~ w.replace(`"`, `""`) ~ `"*`;
            auto sql = `SELECT m.json, snippet(msgs_fts, 3, char(2), char(3), '…', 12), bm25(msgs_fts)
                FROM msgs_fts JOIN msgs m ON m.account=msgs_fts.account AND m.key=msgs_fts.key
                WHERE msgs_fts MATCH ? AND msgs_fts.account=?` ~ (inChat.length ? ` AND msgs_fts.remote=?` : ``)
                ~ ` ORDER BY bm25(msgs_fts) LIMIT ?`;
            static string html(string s) {
                return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                    .replace("\x02", `<b><font color="#21C063">`).replace("\x03", "</font></b>");
            }
            void take(ref Row r) {
                JSONValue m;
                try m = parseJSON(r.text(0)); catch (Exception) return;
                auto h = ing.handOut(m);
                h["snippet"] = html(r.text(1));
                JSONValue c;
                if (cs.chat(acc, js(m, "remote"), c)) {
                    auto fc = fullChat(c);
                    h["chatName"] = js(fc, "name");
                    const pp = js(fc, "profilePicThumb");
                    if (pp.length && pp != "-") h["chatPic"] = pp;
                }
                msgsOut ~= h;
            }
            try {
                if (inChat.length) foreach (ref r; cs.db.query(sql, fts, acc, inChat, limit)) take(r);
                else foreach (ref r; cs.db.query(sql, fts, acc, limit)) take(r);
            } catch (Exception) {}   // a query FTS5 cannot parse: no message hits
        }
        res["chats"] = chatsOut.length ? JSONValue(chatsOut) : parseJSON("[]");
        res["msgs"] = msgsOut.length ? JSONValue(msgsOut) : parseJSON("[]");
        return res;
    }

    /// Msg.search
    JSONValue[] search(string query, string chat, int limit) {
        JSONValue[] out_;
        foreach (m; cs.search(acc, query, chat, limit)) out_ ~= ing.handOut(m);
        return out_;
    }
}
