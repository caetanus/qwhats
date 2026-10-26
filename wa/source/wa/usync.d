/// usync: the `usync` IQ that discovers a contact's devices, so we know every device to encrypt a
/// message for (a WhatsApp account is multi-device — the phone plus each linked companion). This is
/// whatsmeow's GetUserDevices query: `<iq xmlns=usync type=get>` carrying a `<usync>` with a
/// `<query><devices version=2/></query>` and a `<list>` of `<user jid=…/>`; the reply's
/// `<user><devices><device-list><device id=N/>…` lists each device.
module wa.usync;

import std.conv : to;
import wa.binary.node;
import wa.envelope : parseJidString;

/// A usync IQ (whatsmeow usync()): `<usync sid mode last=true index=0 context>` with the query
/// nodes and a `<list>` of `<user jid=…/>` (JIDs reduced to user@server).
Node usyncIQ(const string[] userJids, string mode, string context, Node[] query, string sid, string iqId) {
    Node list = Node("list");
    foreach (j; userJids) {
        auto jid = parseJidString(j);
        auto nonAd = Jid.pair(jid.user, jid.server == "lid" ? "lid" : "s.whatsapp.net");
        auto u = Node("user");
        u.attrs ~= Attr("jid", Value(nonAd));
        list.children ~= u;
    }
    Node q = Node("query");
    q.children = query;

    Node usync = Node("usync");
    usync.attrs ~= Attr("sid", Value(sid));
    usync.attrs ~= Attr("mode", Value(mode));
    usync.attrs ~= Attr("last", Value("true"));
    usync.attrs ~= Attr("index", Value("0"));
    usync.attrs ~= Attr("context", Value(context));
    usync.children ~= q;
    usync.children ~= list;

    auto iq = node("iq", [["id", iqId], ["xmlns", "usync"], ["type", "get"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= usync;
    return iq;
}

/// The device-list query (GetUserDevices): mode=query, context=message, <devices version=2/>.
Node deviceQueryIQ(const string[] userJids, string sid, string iqId) {
    auto devices = Node("devices");
    devices.attrs ~= Attr("version", Value("2"));
    return usyncIQ(userJids, "query", "message", [devices], sid, iqId);
}

/// The user-info query (GetUserInfo): mode=full, context=background, asking for the business
/// name, status, picture, devices and LID.
Node userInfoIQ(const string[] userJids, string sid, string iqId) {
    auto business = Node("business");
    business.children ~= Node("verified_name");
    auto devices = Node("devices");
    devices.attrs ~= Attr("version", Value("2"));
    return usyncIQ(userJids, "full", "background",
        [business, Node("status"), Node("picture"), devices, Node("lid")], sid, iqId);
}

/// Only the business profile's verified name (the user-info query cut to `<business>`): what an
/// unnamed chat's title needs, and nothing else asked of the server.
Node businessNameIQ(const string[] userJids, string sid, string iqId) {
    auto business = Node("business");
    business.children ~= Node("verified_name");
    return usyncIQ(userJids, "full", "background", [business], sid, iqId);
}

/// user JID → status text ("about"), from the `<status>` of each `<user>` (whatsmeow parseUserInfo).
string[string] parseUsyncStatus(const ref Node iqResult) {
    string[string] out_;
    const usync = iqResult.child("usync");
    const list = usync !is null ? usync.child("list") : null;
    if (list is null) return out_;
    foreach (ref u; list.children) {
        if (u.tag != "user") continue;
        const st = u.child("status");
        if (st is null) continue;
        auto j = jidOf(u);
        out_[Jid.pair(j.user, j.server).toString()] = cast(string) st.bytes.idup;
    }
    return out_;
}

/// A business's verified name from its certificate (whatsmeow parseVerifiedNameContent): the
/// `<verified_name>` bytes are a VerifiedNameCertificate {details = 1}, whose Details carry
/// verifiedName = 4. "" when absent or unreadable. The node is the one in a message or in a usync
/// `<business>`.
string verifiedNameOf(const(Node)* vn) {
    import wa.proto : ProtoReader;
    if (vn is null || !vn.hasBytes || vn.bytes.length == 0) return "";
    try {
        auto cert = ProtoReader(vn.bytes);
        auto details = ProtoReader(cert.get(1).bytes);
        return cast(string) details.get(4).bytes.idup;
    } catch (Exception) return "";
}

/// user JID → verified business name, from each `<user><business><verified_name>` of a user-info usync
string[string] parseUsyncVerifiedNames(const ref Node iqResult) {
    string[string] out_;
    const usync = iqResult.child("usync");
    const list = usync !is null ? usync.child("list") : null;
    if (list is null) return out_;
    foreach (ref u; list.children) {
        if (u.tag != "user") continue;
        const b = u.child("business");
        if (b is null) continue;
        const name = verifiedNameOf(b.child("verified_name"));
        if (name.length == 0) continue;
        auto j = jidOf(u);
        out_[Jid.pair(j.user, j.server).toString()] = name;
    }
    return out_;
}

unittest {
    import wa.proto : ProtoWriter;
    const details = ProtoWriter().varint(1, 42).str(2, "smb:wa").str(4, "Loja Exemplo").buf;
    auto vn = Node("verified_name");
    vn.bytes = ProtoWriter().bytes(1, details).bytes(2, [1, 2, 3]).buf.idup;
    vn.hasBytes = true;
    assert(verifiedNameOf(&vn) == "Loja Exemplo");
    auto empty = Node("verified_name");
    assert(verifiedNameOf(&empty) == "" && verifiedNameOf(null) == "");

    Node r = Node("iq");
    Node us = Node("usync");
    Node list = Node("list");
    Node u = Node("user");
    u.attrs ~= Attr("jid", Value(parseJidString("5511988887777@s.whatsapp.net")));
    Node b = Node("business");
    b.children ~= vn;
    u.children ~= b;
    Node plain = Node("user");
    plain.attrs ~= Attr("jid", Value(parseJidString("5511@s.whatsapp.net")));
    plain.children ~= Node("business");
    list.children ~= u;
    list.children ~= plain;
    us.children ~= list;
    r.children ~= us;
    auto names = parseUsyncVerifiedNames(r);
    assert(names.length == 1 && names["5511988887777@s.whatsapp.net"] == "Loja Exemplo");
}

/// phone-number user → LID user, from the `<lid val=…/>` of each `<user>` in a usync result.
string[string] parseUsyncLIDs(const ref Node iqResult) {
    string[string] out_;
    const usync = iqResult.child("usync");
    const list = usync !is null ? usync.child("list") : null;
    if (list is null) return out_;
    foreach (ref u; list.children) {
        if (u.tag != "user") continue;
        const l = u.child("lid");
        if (l is null) continue;
        auto lv = l.attr("val");
        if (lv is null) continue;
        auto lid = lv.isJid ? lv.jid : parseJidString(lv.str);
        auto pn = jidOf(u);
        if (lid.user.length && pn.user.length) out_[pn.user] = lid.user;
    }
    return out_;
}

/// The device JIDs for one `<user jid=…>` node from a usync reply: `<devices><device-list><device
/// id=N/>…`. The returned JIDs carry the user and each device number (hosted devices are mapped to
/// the hosted server, as whatsmeow does).
Jid[] parseDeviceList(const ref Node user) {
    auto jid = jidOf(user);
    const devices = user.child("devices");
    if (devices is null) return null;
    const list = devices.child("device-list");
    if (list is null) return null;

    Jid[] out_;
    foreach (ref d; list.children) {
        if (d.tag != "device") continue;
        const idStr = d.get("id");
        if (idStr.length == 0) continue;
        ushort dev;
        try dev = idStr.to!ushort; catch (Exception) continue;
        const hosted = d.get("is_hosted") == "true";
        auto domain = jid.server == "lid"
            ? (hosted ? Jid.Domain.hostedLid : Jid.Domain.lid)
            : (hosted ? Jid.Domain.hosted : Jid.Domain.whatsapp);
        out_ ~= Jid.deviceJid(jid.user, domain, dev);
    }
    return out_;
}

/// Every device across all `<user>` nodes of a usync `<iq>` result (digs through `<usync><list>`).
Jid[] parseUsyncDevices(const ref Node iqResult) {
    const usync = iqResult.child("usync");
    const list = usync !is null ? usync.child("list") : null;
    if (list is null) return null;
    Jid[] out_;
    foreach (ref u; list.children)
        if (u.tag == "user") out_ ~= parseDeviceList(u);
    return out_;
}

private Jid jidOf(const ref Node user) {
    auto v = user.attr("jid");
    if (v is null) return Jid.init;
    return v.isJid ? v.jid : parseJidString(v.str);
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
}

unittest {
    // Build the query, round-trip it through the codec, and check its shape.
    auto iq = deviceQueryIQ(["5511988887777@s.whatsapp.net"], "sid123", "iq-1");
    auto back = decodeStanza(encodeStanza(iq));
    assert(back.get("xmlns") == "usync" && back.get("type") == "get");
    const usync = back.child("usync");
    assert(usync !is null && usync.get("mode") == "query" && usync.get("sid") == "sid123");
    assert(usync.child("query").child("devices").get("version") == "2");
    const list = usync.child("list");
    assert(list.children.length == 1 && list.children[0].tag == "user");
    assert(list.children[0].get("jid") == "5511988887777@s.whatsapp.net");
}

unittest {
    // the user-info query asks for the LID, and its reply maps the number to it
    auto q = userInfoIQ(["5511988887777@s.whatsapp.net"], "s1", "i1");
    auto qb = decodeStanza(encodeStanza(q));
    const us = qb.child("usync");
    assert(us.get("mode") == "full" && us.get("context") == "background");
    assert(us.child("query").child("lid") !is null && us.child("query").child("devices").get("version") == "2");

    auto user = node("user");
    user.attrs ~= Attr("jid", Value(Jid.pair("5511988887777", "s.whatsapp.net")));
    auto lid = Node("lid");
    lid.attrs ~= Attr("val", Value(Jid.pair("136000111", "lid")));
    user.children ~= lid;
    Node list = Node("list");
    list.children ~= user;
    Node usync = Node("usync");
    usync.children ~= list;
    auto iq = node("iq", [["type", "result"]]);
    iq.children ~= usync;
    auto back = decodeStanza(encodeStanza(iq));
    assert(parseUsyncLIDs(back)["5511988887777"] == "136000111");
}

unittest {
    // Parse a synthetic reply: one user with devices 0 and 3.
    auto user = node("user");
    user.attrs ~= Attr("jid", Value(Jid.pair("5511988887777", "s.whatsapp.net")));
    Node dl = Node("device-list");
    foreach (id; ["0", "3"]) {
        auto d = Node("device");
        d.attrs ~= Attr("id", Value(id));
        dl.children ~= d;
    }
    Node devices = Node("devices");
    devices.children ~= dl;
    user.children ~= devices;

    Node list = Node("list");
    list.children ~= user;
    Node usync = Node("usync");
    usync.children ~= list;
    auto iq = node("iq", [["type", "result"]]);
    iq.children ~= usync;

    auto back = decodeStanza(encodeStanza(iq));
    auto devs = parseUsyncDevices(back);
    assert(devs.length == 2);
    assert(devs[0].user == "5511988887777" && devs[0].device == 0);
    assert(devs[1].device == 3);
    import wa.envelope : signalAddress;
    assert(signalAddress(devs[1]) == "5511988887777:3");
}
