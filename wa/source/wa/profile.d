/// Profile pictures (whatsmeow GetProfilePictureInfo): `<iq xmlns=w:profile:picture type=get
/// to=s.whatsapp.net target=JID><picture query=url type=preview|image [id]>[<tctoken>]</picture>`;
/// the answer's <picture url id type direct_path> points at a plain (unencrypted) CDN file.
module wa.profile;

import wa.binary.node;

Node profilePictureIQ(Jid target, bool preview, const(ubyte)[] tctoken, string iqId, string existingId = null) {
    auto p = Node("picture");
    p.attrs ~= Attr("query", Value("url"));
    p.attrs ~= Attr("type", Value(preview ? "preview" : "image"));
    if (existingId.length) p.attrs ~= Attr("id", Value(existingId));
    if (tctoken.length) {
        auto t = Node("tctoken");
        t.bytes = tctoken.dup;
        t.hasBytes = true;
        p.children ~= t;
    }
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:profile:picture"));
    iq.attrs ~= Attr("type", Value("get"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.attrs ~= Attr("target", Value(Jid.pair(target.user, target.server)));
    iq.children ~= p;
    return iq;
}

/// WAWebSetAboutJob: `<iq xmlns=status type=set to=s.whatsapp.net><status>TEXT</status></iq>`.
Node setAboutIQ(string text, string iqId) {
    auto st = Node("status");
    st.bytes = cast(const(ubyte)[]) text.idup;
    st.hasBytes = true;
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("status"));
    iq.attrs ~= Attr("type", Value("set"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.children ~= st;
    return iq;
}

/// WhatsApp Web's own picture change: `<iq xmlns=w:profile:picture type=set to=s.whatsapp.net>
/// <picture type=image>JPEG</picture></iq>` (no target: that is only for a group's).
Node setOwnPictureIQ(const(ubyte)[] jpeg, string iqId) {
    auto p = Node("picture");
    p.attrs ~= Attr("type", Value("image"));
    p.bytes = jpeg.idup;
    p.hasBytes = true;
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:profile:picture"));
    iq.attrs ~= Attr("type", Value("set"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.children ~= p;
    return iq;
}

/// A community's picture (GetProfilePictureInfo IsCommunity): `<iq xmlns=w:g2 type=get to=COMMUNITY>
/// <pictures><picture query=url type=preview parent_group_jid=COMMUNITY/></pictures>`; the answer's
/// <picture> comes wrapped in <pictures>.
Node communityPictureIQ(Jid community, string iqId) {
    auto p = Node("picture");
    p.attrs ~= Attr("query", Value("url"));
    p.attrs ~= Attr("type", Value("preview"));
    p.attrs ~= Attr("parent_group_jid", Value(Jid.pair(community.user, community.server)));
    auto ps = Node("pictures");
    ps.children ~= p;
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:g2"));
    iq.attrs ~= Attr("type", Value("get"));
    iq.attrs ~= Attr("to", Value(Jid.pair(community.user, community.server)));
    iq.children ~= ps;
    return iq;
}

/// What the answer says: a picture, none set / hidden from us, or unchanged (304).
enum PictureResult { found, notSet, unauthorized, unchanged, error }

PictureResult parseProfilePicture(const ref Node r, out string url, out string id) {
    if (r.get("type") == "error") {
        const e = r.child("error");
        const code = e !is null ? e.get("code") : "";
        if (code == "401") return PictureResult.unauthorized;
        if (code == "404") return PictureResult.notSet;
        return PictureResult.error;
    }
    const wrapped = r.child("pictures");
    const p = wrapped !is null ? wrapped.child("picture") : r.child("picture");
    if (p is null) return PictureResult.error;
    if (p.get("status") == "304") return PictureResult.unchanged;
    if (p.get("status") == "204") return PictureResult.notSet;
    url = p.get("url");
    id = p.get("id");
    return url.length ? PictureResult.found : PictureResult.error;
}

unittest {
    import wa.envelope : parseJidString;
    auto q = profilePictureIQ(parseJidString("5511:2@s.whatsapp.net"), true, [1, 2], "a.b-1");
    assert(q.get("xmlns") == "w:profile:picture" && q.get("target") == "5511@s.whatsapp.net");
    const p = q.child("picture");
    assert(p.get("type") == "preview" && p.get("query") == "url" && p.child("tctoken").bytes == [1, 2]);
    Node r = Node("iq");
    r.attrs ~= Attr("type", Value("result"));
    Node pic = Node("picture");
    pic.attrs ~= Attr("url", Value("https://pps.whatsapp.net/x"));
    pic.attrs ~= Attr("id", Value("123"));
    r.children ~= pic;
    string url, id;
    assert(parseProfilePicture(r, url, id) == PictureResult.found && id == "123");
}
