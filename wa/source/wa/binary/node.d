/// The stanza model of WhatsApp's binary XML (WAP), as WhatsApp Web's WAWap.WapNode: a tag, its
/// attributes (strings or JIDs) and a content that is either child nodes or bytes.
module wa.binary.node;

import std.conv : to;

/// A WhatsApp address as the wire carries it (WAWapJid): a plain user@server pair, a device JID
/// (JID_U: user, domain, device), a Messenger (FB) JID or an interop JID.
struct Jid {
    enum Kind : ubyte { pair, device, fb, interop }
    /// WAWapJid.DomainType, the byte a device JID carries.
    enum Domain : ubyte { whatsapp = 0, lid = 1, hosted = 128, hostedLid = 129 }

    Kind kind;
    string user;        // null: a server-only JID ("s.whatsapp.net", "g.us")
    string server;      // pair: the server; device: derived from the domain
    ushort device;
    Domain domain;
    ushort integrator;  // interop

    static Jid pair(string user, string server) { return Jid(Kind.pair, user, server); }

    static Jid deviceJid(string user, Domain domain, ushort device) {
        return Jid(Kind.device, user, serverOf(domain), device, domain);
    }

    static string serverOf(Domain d) {
        final switch (d) {
            case Domain.whatsapp: return "s.whatsapp.net";
            case Domain.lid: return "lid";
            case Domain.hosted: return "hosted";
            case Domain.hostedLid: return "hosted.lid";
        }
    }

    /// "user@server", "user:device@server" (WhatsApp Web's toString).
    string toString() const {
        final switch (kind) {
            case Kind.pair:
                return user is null ? server : user ~ "@" ~ server;
            case Kind.device:
                return device == 0 ? user ~ "@" ~ server : user ~ ":" ~ device.to!string ~ "@" ~ server;
            case Kind.fb:
                return user ~ ":" ~ device.to!string ~ "@msgr";
            case Kind.interop:
                return integrator.to!string ~ "-" ~ user ~ ":" ~ device.to!string ~ "@interop";
        }
    }
}

/// An attribute value: a string or a JID (the encoder writes them differently).
struct Value {
    bool isJid;
    string str;
    Jid jid;

    this(string s) { str = s; }
    this(Jid j) { isJid = true; jid = j; }

    string toString() const { return isJid ? jid.toString() : str; }
}

struct Attr {
    string key;
    Value value;
}

/// A stanza node. Attribute order is kept: WhatsApp Web writes them in insertion order.
struct Node {
    string tag;
    Attr[] attrs;
    Node[] children;      // content as child nodes …
    const(ubyte)[] bytes; // … or as bytes (strings decode to their UTF-8 bytes, as WhatsApp Web does)
    bool hasBytes;        // bytes present (possibly empty), as opposed to no content

    Value* attr(string key) inout {
        foreach (ref a; cast(Attr[]) attrs)
            if (a.key == key) return &a.value;
        return null;
    }

    string get(string key, string fallback = "") const {
        foreach (a; attrs)
            if (a.key == key) return a.value.toString();
        return fallback;
    }

    /// The first child with this tag (null when there is none).
    inout(Node)* child(string tag) inout {
        foreach (ref c; children)
            if (c.tag == tag) return &c;
        return null;
    }

    /// The XML-ish debug form WhatsApp Web logs.
    string toString() const {
        import std.array : appender;
        import std.format : formattedWrite;
        auto w = appender!string;
        w ~= "<" ~ tag;
        foreach (a; attrs) w.formattedWrite(` %s="%s"`, a.key, a.value.toString());
        if (children.length) {
            w ~= ">";
            foreach (c; children) w ~= c.toString();
            w ~= "</" ~ tag ~ ">";
        } else if (hasBytes) {
            w.formattedWrite(">%s</%s>", printable(bytes), tag);
        } else {
            w ~= " />";
        }
        return w[];
    }
}

private string printable(const(ubyte)[] b) {
    import std.utf : validate;
    import std.format : format;
    try {
        auto s = cast(string) b.idup;
        validate(s);
        return s;
    } catch (Exception) {
        return format("<%d bytes>", b.length);
    }
}

/// Builds a node: node("iq", ["id": "1", "type": "get"]) or with a JID value via attrJid.
Node node(string tag, string[2][] attrs = null, Node[] children = null) {
    Node n = Node(tag);
    foreach (a; attrs) n.attrs ~= Attr(a[0], Value(a[1]));
    n.children = children;
    return n;
}
