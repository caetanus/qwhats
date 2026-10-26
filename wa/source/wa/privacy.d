/// Our privacy settings (whatsmeow privacysettings.go): fetched with `<iq xmlns=privacy type=get>
/// <privacy/>`, kept as category → value, and updated by `<notification type=account_sync><privacy>`.
module wa.privacy;

import wa.binary.node;

/// The query (TryFetchPrivacySettings).
Node privacyIQ(string id) {
    Node q = Node("iq");
    q.attrs ~= Attr("id", Value(id));
    q.attrs ~= Attr("xmlns", Value("privacy"));
    q.attrs ~= Attr("type", Value("get"));
    q.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    q.children ~= Node("privacy");
    return q;
}

/// parsePrivacySettings: each <category name value> under a <privacy> node, applied over `into`.
void applyPrivacy(const ref Node privacy, ref string[string] into) {
    foreach (ref c; privacy.children)
        if (c.tag == "category" && c.get("name").length) into[c.get("name")] = c.get("value");
}

/// Whether read receipts are off ("none"): reads are then sent as read-self.
bool readReceiptsOff(const string[string] s) {
    auto v = "readreceipts" in s;
    return v !is null && *v == "none";
}

unittest {
    Node p = Node("privacy");
    Node c = Node("category");
    c.attrs ~= Attr("name", Value("readreceipts"));
    c.attrs ~= Attr("value", Value("none"));
    p.children ~= c;
    string[string] s;
    applyPrivacy(p, s);
    assert(readReceiptsOff(s));
    assert(privacyIQ("1.2-3").child("privacy") !is null);
}
