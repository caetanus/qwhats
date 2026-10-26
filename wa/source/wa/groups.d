/// Group metadata (whatsmeow group.go): `<iq xmlns=w:g2 type=get to=GROUP><query request=interactive/>`
/// and parseGroupNode / parseParticipant — subject, description, creator, announce/locked,
/// disappearing timer, community parent, and the participants with their PN↔LID pairs.
module wa.groups;

import std.conv : to;
import wa.binary.node;
import wa.envelope : jidAttr;

Node groupInfoIQ(Jid group, string iqId) {
    auto q = Node("query");
    q.attrs ~= Attr("request", Value("interactive"));
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:g2"));
    iq.attrs ~= Attr("type", Value("get"));
    iq.attrs ~= Attr("to", Value(Jid.pair(group.user, group.server)));
    iq.children ~= q;
    return iq;
}

struct GroupParticipant {
    Jid jid, phoneNumber, lid;
    bool isAdmin, isSuperAdmin;
}

struct GroupInfo {
    Jid jid, owner;
    string name, topic;
    long nameSetAt, created;
    bool isAnnounce, isLocked, isParent, isEphemeral;
    uint disappearingTimer;
    Jid linkedParent;
    string addressingMode;   // "lid" or "pn"
    GroupParticipant[] participants;
}

private Jid optJid(const ref Node n, string key) {
    auto v = n.attr(key);
    if (v is null) return Jid.init;
    return jidAttr(n, key);
}
private long optLong(const ref Node n, string key) {
    try return n.get(key, "0").to!long; catch (Exception) return 0;
}

/// parseGroupNode: the <group> of the answer.
GroupInfo parseGroupNode(const ref Node g) {
    GroupInfo gi;
    gi.jid = Jid.pair(g.get("id"), "g.us");
    gi.owner = optJid(g, "creator");
    gi.name = g.get("subject");
    gi.nameSetAt = optLong(g, "s_t");
    gi.created = optLong(g, "creation");
    gi.addressingMode = g.get("addressing_mode");
    foreach (ref c; g.children) {
        switch (c.tag) {
            case "participant":
                GroupParticipant p;
                const t = c.get("type");
                p.isAdmin = t == "admin" || t == "superadmin";
                p.isSuperAdmin = t == "superadmin";
                p.jid = jidAttr(c, "jid");
                if (p.jid.server == "lid") { p.lid = p.jid; p.phoneNumber = optJid(c, "phone_number"); }
                else if (p.jid.server == "s.whatsapp.net") { p.phoneNumber = p.jid; p.lid = optJid(c, "lid"); }
                gi.participants ~= p;
                break;
            case "description":
                if (const b = c.child("body")) gi.topic = cast(string) b.bytes.idup;
                break;
            case "announcement": gi.isAnnounce = true; break;
            case "locked": gi.isLocked = true; break;
            case "ephemeral":
                gi.isEphemeral = true;
                gi.disappearingTimer = cast(uint) optLong(c, "expiration");
                break;
            case "linked_parent": gi.linkedParent = optJid(c, "jid"); break;
            case "parent": gi.isParent = true; break;
            default: break;
        }
    }
    return gi;
}

unittest {
    import wa.envelope : parseJidString;
    auto q = groupInfoIQ(parseJidString("123-456@g.us"), "1.2-3");
    assert(q.get("xmlns") == "w:g2" && q.get("to") == "123-456@g.us" && q.child("query").get("request") == "interactive");
    Node g = Node("group");
    g.attrs ~= Attr("id", Value("123-456"));
    g.attrs ~= Attr("subject", Value("Família"));
    g.attrs ~= Attr("s_t", Value("1700000000"));
    Node p = Node("participant");
    p.attrs ~= Attr("jid", Value(parseJidString("99@lid")));
    p.attrs ~= Attr("phone_number", Value(parseJidString("5511@s.whatsapp.net")));
    p.attrs ~= Attr("type", Value("superadmin"));
    g.children ~= p;
    Node e = Node("ephemeral");
    e.attrs ~= Attr("expiration", Value("86400"));
    g.children ~= e;
    Node d = Node("description");
    Node b = Node("body");
    b.bytes = cast(const(ubyte)[]) "regras";
    b.hasBytes = true;
    d.children ~= b;
    g.children ~= d;
    auto gi = parseGroupNode(g);
    assert(gi.jid.toString() == "123-456@g.us" && gi.name == "Família" && gi.nameSetAt == 1_700_000_000);
    assert(gi.participants.length == 1 && gi.participants[0].isSuperAdmin && gi.participants[0].isAdmin);
    assert(gi.participants[0].phoneNumber.toString() == "5511@s.whatsapp.net" && gi.participants[0].lid.toString() == "99@lid");
    assert(gi.isEphemeral && gi.disappearingTimer == 86400 && gi.topic == "regras");
}

private Node groupIQ(string type_, Jid to, Node content, string iqId) {
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:g2"));
    iq.attrs ~= Attr("type", Value(type_));
    iq.attrs ~= Attr("to", Value(Jid.pair(to.user, to.server)));
    iq.children ~= content;
    return iq;
}

/// A new group's member (whatsmeow CreateGroup): its JID, its phone number when the JID is a LID, and
/// the privacy token we hold for it.
struct NewMember {
    Jid jid, phoneNumber;
    const(ubyte)[] token;
}

/// whatsmeow CreateGroup (a plain group, its defaults): `<iq xmlns=w:g2 type=set to=g.us>
/// <create subject=NAME><participant jid [phone_number]>[<privacy>TOKEN</privacy>]</participant>…
/// <member_add_mode>all_member_add</member_add_mode><ephemeral expiration=0/>
/// <membership_approval_mode><group_join state=off/></membership_approval_mode></create>`.
/// The answer's <group> is parseGroupNode's.
Node createGroupIQ(string name, const NewMember[] members, string iqId) {
    auto c = Node("create");
    if (name.length) c.attrs ~= Attr("subject", Value(name));
    foreach (ref m; members) {
        auto p = Node("participant");
        p.attrs ~= Attr("jid", Value(Jid.pair(m.jid.user, m.jid.server)));
        if (m.phoneNumber.user.length) p.attrs ~= Attr("phone_number", Value(Jid.pair(m.phoneNumber.user, m.phoneNumber.server)));
        if (m.token.length) {
            auto t = Node("privacy");
            t.bytes = m.token.idup;
            t.hasBytes = true;
            p.children ~= t;
        }
        c.children ~= p;
    }
    auto mode = Node("member_add_mode");
    mode.bytes = cast(const(ubyte)[]) "all_member_add";
    mode.hasBytes = true;
    c.children ~= mode;
    auto eph = Node("ephemeral");
    eph.attrs ~= Attr("expiration", Value("0"));
    c.children ~= eph;
    auto gj = Node("group_join");
    gj.attrs ~= Attr("state", Value("off"));
    auto ap = Node("membership_approval_mode");
    ap.children ~= gj;
    c.children ~= ap;
    return groupIQ("set", Jid.pair(null, "g.us"), c, iqId);
}

/// A community's group (whatsmeow GroupLinkTarget).
struct SubGroup {
    Jid jid;
    string name;
    bool isDefault;   // the announcements group
}

/// whatsmeow GetSubGroups: `<iq xmlns=w:g2 type=get to=COMMUNITY><sub_groups/>`.
Node subGroupsIQ(Jid community, string iqId) { return groupIQ("get", community, Node("sub_groups"), iqId); }

/// The answer's <sub_groups><group id|jid subject><default_sub_group/>?</group>…
SubGroup[] parseSubGroups(const ref Node r) {
    SubGroup[] out_;
    const sg = r.child("sub_groups");
    if (sg is null) throw new Exception("no <sub_groups> in the answer");
    foreach (ref g; sg.children) {
        if (g.tag != "group") continue;
        SubGroup s;
        s.jid = optJid(g, "jid");
        if (s.jid.user.length == 0) s.jid = Jid.pair(g.get("id"), "g.us");
        s.name = g.get("subject");
        s.isDefault = g.child("default_sub_group") !is null;
        out_ ~= s;
    }
    return out_;
}

/// A community group's member count, which a non-member may ask its community for (get_linked_group):
/// `<iq xmlns=w:g2 type=get to=COMMUNITY><query_linked type=sub_group jid=SUB/>`.
Node queryLinkedIQ(Jid community, Jid sub, string iqId) {
    auto q = Node("query_linked");
    q.attrs ~= Attr("type", Value("sub_group"));
    q.attrs ~= Attr("jid", Value(Jid.pair(sub.user, sub.server)));
    return groupIQ("get", community, q, iqId);
}

/// the first size="N" anywhere in the answer (the Go core's linkedGroupSize), 0 if none
long linkedSize(const ref Node n) {
    if (n.attr("size") !is null) {
        try { const k = n.get("size").to!long; if (k > 0) return k; } catch (Exception) {}
    }
    foreach (ref c; n.children) if (const k = linkedSize(c)) return k;
    return 0;
}

/// WASmaxGroupsJoinLinkedGroupRPC: in, through the community (no invite needed):
/// `<iq xmlns=w:g2 type=set to=COMMUNITY><join_linked_group jid=SUB/>`.
Node joinLinkedGroupIQ(Jid community, Jid sub, string iqId) {
    auto j = Node("join_linked_group");
    j.attrs ~= Attr("jid", Value(Jid.pair(sub.user, sub.server)));
    return groupIQ("set", community, j, iqId);
}

/// whatsmeow Logout: `<iq xmlns=md type=set to=s.whatsapp.net><remove-companion-device jid=OWN_DEVICE
/// reason=user_initiated/>`.
Node logoutIQ(Jid ownDevice, string iqId) {
    auto r = Node("remove-companion-device");
    r.attrs ~= Attr("jid", Value(ownDevice));
    r.attrs ~= Attr("reason", Value("user_initiated"));
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("md"));
    iq.attrs ~= Attr("type", Value("set"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.children ~= r;
    return iq;
}

unittest {
    import wa.envelope : parseJidString;
    NewMember a = {jid: parseJidString("99@lid"), phoneNumber: parseJidString("5511@s.whatsapp.net"), token: [7, 8]};
    NewMember b = {jid: parseJidString("5522@s.whatsapp.net")};
    auto q = createGroupIQ("Turma", [a, b], "i-1");
    assert(q.get("xmlns") == "w:g2" && q.get("type") == "set" && q.get("to") == "g.us");
    const c = q.child("create");
    assert(c.get("subject") == "Turma" && c.children.length == 5);
    assert(c.children[0].get("jid") == "99@lid" && c.children[0].get("phone_number") == "5511@s.whatsapp.net");
    assert(c.children[0].child("privacy").bytes == [7, 8]);
    assert(c.children[1].get("jid") == "5522@s.whatsapp.net" && c.children[1].attr("phone_number") is null
        && c.children[1].children.length == 0);
    assert(c.children[2].tag == "member_add_mode" && c.children[2].bytes == cast(const(ubyte)[]) "all_member_add");
    assert(c.children[3].tag == "ephemeral" && c.children[3].get("expiration") == "0");
    assert(c.children[4].child("group_join").get("state") == "off");

    const comm = parseJidString("120363@g.us"), sub = parseJidString("120364@g.us");
    auto s = subGroupsIQ(comm, "i-2");
    assert(s.get("to") == "120363@g.us" && s.get("type") == "get" && s.children[0].tag == "sub_groups");
    Node r = Node("iq");
    Node sg = Node("sub_groups");
    Node g1 = Node("group");
    g1.attrs ~= Attr("id", Value("120365"));
    g1.attrs ~= Attr("subject", Value("Avisos da turma"));
    g1.children ~= Node("default_sub_group");
    Node g2 = Node("group");
    g2.attrs ~= Attr("jid", Value(sub));
    g2.attrs ~= Attr("subject", Value("Geral"));
    sg.children ~= g1;
    sg.children ~= g2;
    r.children ~= sg;
    auto subs = parseSubGroups(r);
    assert(subs.length == 2 && subs[0].isDefault && subs[0].jid.toString() == "120365@g.us" && subs[0].name == "Avisos da turma");
    assert(!subs[1].isDefault && subs[1].jid.toString() == "120364@g.us");

    auto l = queryLinkedIQ(comm, sub, "i-3");
    assert(l.child("query_linked").get("type") == "sub_group" && l.child("query_linked").get("jid") == "120364@g.us");
    Node la = Node("iq");
    Node lg = Node("linked_groups");
    Node lgg = Node("group");
    lgg.attrs ~= Attr("size", Value("42"));
    lg.children ~= lgg;
    la.children ~= lg;
    assert(linkedSize(la) == 42 && linkedSize(r) == 0);

    auto j = joinLinkedGroupIQ(comm, sub, "i-4");
    assert(j.get("type") == "set" && j.get("to") == "120363@g.us" && j.child("join_linked_group").get("jid") == "120364@g.us");

    auto o = logoutIQ(parseJidString("5511:3@s.whatsapp.net"), "i-5");
    assert(o.get("xmlns") == "md" && o.child("remove-companion-device").get("jid") == "5511:3@s.whatsapp.net"
        && o.child("remove-companion-device").get("reason") == "user_initiated");
}

/// A group change notification (whatsmeow parseGroupChange / events.GroupInfo), or — a single
/// <create> child — a group we were added to (events.JoinedGroup: `created` holds its metadata).
struct GroupChange {
    string id;          // the notification's id (a redelivery makes the same rows)
    Jid jid, sender;
    long t;
    bool hasName, hasTopic, hasEphemeral, ephemeral, deleted;
    string name, topic;
    long nameSetAt;
    int announce = -1, locked = -1;   // -1 unchanged, 0/1 the new value
    uint timer;
    Jid[] join, leave, promote, demote;
    Jid[2][] lidPairs;                 // (lid, pn) learned from the participant lists
    bool isCreate;
    GroupInfo created;
}

private Jid[] participantList(const ref Node n, ref Jid[2][] pairs) {
    Jid[] out_;
    foreach (ref c; n.children) {
        if (c.tag != "participant" || c.attr("jid") is null) continue;
        auto j = jidAttr(c, "jid");
        out_ ~= j;
        if (j.server == "lid") {
            auto pn = optJid(c, "phone_number");
            if (pn.user.length) pairs ~= [j, pn];
        } else if (j.server == "s.whatsapp.net") {
            auto l = optJid(c, "lid");
            if (l.user.length) pairs ~= [l, j];
        }
    }
    return out_;
}

GroupChange parseGroupChange(const ref Node n) {
    GroupChange g;
    g.id = n.get("id");
    g.jid = optJid(n, "from");
    g.sender = optJid(n, "participant");
    g.t = optLong(n, "t");
    if (n.children.length == 1 && n.children[0].tag == "create") {
        const gn = n.children[0].child("group");
        if (gn is null) throw new Exception("group create notification without <group>");
        g.isCreate = true;
        g.created = parseGroupNode(*gn);
        if (g.created.addressingMode.length == 0) g.created.addressingMode = n.get("addressing_mode");
        foreach (ref p; g.created.participants)
            if (p.lid.user.length && p.phoneNumber.user.length) g.lidPairs ~= [p.lid, p.phoneNumber];
        return g;
    }
    foreach (ref c; n.children) {
        switch (c.tag) {
            case "add": g.join = participantList(c, g.lidPairs); break;
            case "remove": g.leave = participantList(c, g.lidPairs); break;
            case "promote": g.promote = participantList(c, g.lidPairs); break;
            case "demote": g.demote = participantList(c, g.lidPairs); break;
            case "locked": g.locked = 1; break;
            case "unlocked": g.locked = 0; break;
            case "announcement": g.announce = 1; break;
            case "not_announcement": g.announce = 0; break;
            case "delete": g.deleted = true; break;
            case "subject":
                g.hasName = true;
                g.name = c.get("subject");
                g.nameSetAt = optLong(c, "s_t");
                break;
            case "description":
                g.hasTopic = true;
                if (c.child("delete") is null)
                    if (const b = c.child("body")) g.topic = cast(string) b.bytes.idup;
                break;
            case "ephemeral":
                g.hasEphemeral = g.ephemeral = true;
                g.timer = cast(uint) optLong(c, "expiration");
                break;
            case "not_ephemeral": g.hasEphemeral = true; break;
            default: break;
        }
    }
    return g;
}

unittest {
    import wa.envelope : parseJidString;
    Node n = Node("notification");
    n.attrs ~= Attr("from", Value(parseJidString("120363@g.us")));
    n.attrs ~= Attr("participant", Value(parseJidString("99@lid")));
    n.attrs ~= Attr("t", Value("1700000000"));
    Node add = Node("add");
    Node p = Node("participant");
    p.attrs ~= Attr("jid", Value(parseJidString("98@lid")));
    p.attrs ~= Attr("phone_number", Value(parseJidString("5511@s.whatsapp.net")));
    add.children ~= p;
    n.children ~= add;
    Node sub = Node("subject");
    sub.attrs ~= Attr("subject", Value("Novo nome"));
    sub.attrs ~= Attr("s_t", Value("1700000001"));
    n.children ~= sub;
    n.children ~= Node("announcement");
    n.children ~= Node("unlocked");
    Node e = Node("ephemeral");
    e.attrs ~= Attr("expiration", Value("604800"));
    n.children ~= e;
    Node d = Node("description");
    d.children ~= Node("delete");
    n.children ~= d;
    auto g = parseGroupChange(n);
    assert(!g.isCreate && g.jid.toString() == "120363@g.us" && g.sender.toString() == "99@lid" && g.t == 1_700_000_000);
    assert(g.join.length == 1 && g.join[0].toString() == "98@lid");
    assert(g.lidPairs.length == 1 && g.lidPairs[0][1].toString() == "5511@s.whatsapp.net");
    assert(g.hasName && g.name == "Novo nome" && g.nameSetAt == 1_700_000_001);
    assert(g.announce == 1 && g.locked == 0 && g.hasEphemeral && g.ephemeral && g.timer == 604_800);
    assert(g.hasTopic && g.topic == "" && g.leave.length == 0);

    Node c = Node("notification");
    c.attrs ~= Attr("from", Value(parseJidString("120364@g.us")));
    Node cr = Node("create");
    Node grp = Node("group");
    grp.attrs ~= Attr("id", Value("120364"));
    grp.attrs ~= Attr("subject", Value("Turma"));
    cr.children ~= grp;
    c.children ~= cr;
    auto j = parseGroupChange(c);
    assert(j.isCreate && j.created.jid.toString() == "120364@g.us" && j.created.name == "Turma");
}
