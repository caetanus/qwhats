/// WhatsApp's GraphQL over the socket (whatsmeow sendMexIQ): `<iq xmlns=w:mex type=get
/// to=s.whatsapp.net><query query_id=ID>{"variables":…}</query></iq>`, answered by a <result> with the
/// JSON {"data":…,"errors":…} (the "argo" binary format is refused, as whatsmeow does).
module wa.mex;

import std.json;
import wa.binary.node;

/// The web client's query ids (our ClientPayload carries WebInfo, so no desktop ids).
enum string querySubscribedNewsletters = "6388546374527196";   // variables {} → xwa2_newsletter_subscribed
enum string queryFetchNewsletter = "6563316087068696";         // → xwa2_newsletter

Node mexIQ(string queryId, string variablesJson, string iqId) {
    auto q = Node("query");
    q.attrs ~= Attr("query_id", Value(queryId));
    q.bytes = cast(const(ubyte)[]) (`{"variables":` ~ variablesJson ~ `}`).idup;
    q.hasBytes = true;
    Node iq = Node("iq");
    iq.attrs ~= Attr("id", Value(iqId));
    iq.attrs ~= Attr("xmlns", Value("w:mex"));
    iq.attrs ~= Attr("type", Value("get"));
    iq.attrs ~= Attr("to", Value(Jid.pair(null, "s.whatsapp.net")));
    iq.children ~= q;
    return iq;
}

/// The answer's "data" (throws on a missing result, argo, or GraphQL errors).
JSONValue mexData(const Node r) {
    if (r.get("type") == "error") throw new Exception("mex query failed");
    const res = r.child("result");
    if (res is null) throw new Exception("mex: no <result>");
    if (res.get("format") == "argo") throw new Exception("mex: argo answers are not supported");
    auto j = parseJSON(cast(string) res.bytes);
    if (auto e = "errors" in j) if (e.type == JSONType.array && e.array.length) throw new Exception("mex: graphql error " ~ e.toString());
    return ("data" in j) ? j["data"] : JSONValue(null);
}

/// GetNewsletterInfo's variables, as Go's json.Marshal orders them (map keys sorted).
string newsletterInfoVariables(string jid) {
    return `{"fetch_creation_time":true,"fetch_full_image":true,"fetch_viewer_metadata":true,"input":{"key":`
        ~ JSONValue(jid).toString() ~ `,"type":"JID"}}`;
}

unittest {
    auto q = mexIQ(queryFetchNewsletter, newsletterInfoVariables("123@newsletter"), "1.2-3");
    assert(q.get("xmlns") == "w:mex" && q.child("query").get("query_id") == queryFetchNewsletter);
    assert(cast(string) q.child("query").bytes == `{"variables":{"fetch_creation_time":true,"fetch_full_image":true,"fetch_viewer_metadata":true,"input":{"key":"123@newsletter","type":"JID"}}}`);
    Node r = Node("iq");
    r.attrs ~= Attr("type", Value("result"));
    Node res = Node("result");
    res.bytes = cast(const(ubyte)[]) `{"data":{"xwa2_newsletter_subscribed":[]}}`;
    res.hasBytes = true;
    r.children ~= res;
    assert(mexData(r)["xwa2_newsletter_subscribed"].array.length == 0);
}
