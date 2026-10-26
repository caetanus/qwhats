/// WhatsApp's binary XML (WAP): the stanza model and its codec.
module wa.binary;

public import wa.binary.node;
public import wa.binary.codec;

unittest {
    import std.json : parseJSON;
    import std.digest : toHexString, LetterCase;
    import std.format : format;
    // whatsmeow's own encoding of each node (core/cmd/wapvec): decoding and re-encoding gives the
    // same bytes, so our codec writes what WhatsApp's servers and whatsmeow read
    auto vectors = parseJSON(import("wap-vectors.json"));
    foreach (v; vectors.array) {
        const name = v["name"].str;
        const hex = v["hex"].str;
        ubyte[] raw;
        foreach (i; 0 .. hex.length / 2) {
            import std.conv : to;
            raw ~= hex[i * 2 .. i * 2 + 2].to!ubyte(16);
        }
        Node n = decodeStanza(raw);
        auto again = encodeStanza(n);
        assert(again == raw, format("%s: %s\n  got  %s\n  want %s", name, n.toString(), toHexString!(LetterCase.lower)(again), hex));
    }
}

unittest {
    // BINARY_32: a content of 1 MiB or more
    Node n = Node("enc");
    n.hasBytes = true;
    n.bytes = new ubyte[(1 << 20) + 5];
    auto b = encodeStanza(n);
    assert(b[4] == BINARY_32);
    auto back = decodeStanza(b);
    assert(back.bytes.length == (1 << 20) + 5);
}

unittest {
    // the JID forms read back as written
    Node n = Node("message");
    n.attrs ~= Attr("to", Value(Jid.deviceJid("5511999999999", Jid.Domain.whatsapp, 7)));
    n.attrs ~= Attr("participant", Value(Jid.deviceJid("100200300400500", Jid.Domain.lid, 2)));
    n.attrs ~= Attr("from", Value(Jid.pair(null, "s.whatsapp.net")));
    auto back = decodeStanza(encodeStanza(n));
    assert(back.get("to") == "5511999999999:7@s.whatsapp.net");
    assert(back.get("participant") == "100200300400500:2@lid");
    assert(back.get("from") == "s.whatsapp.net");
}
