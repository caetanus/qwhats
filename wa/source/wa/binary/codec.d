/// WhatsApp's binary XML (WAP) encoder and decoder, written after WhatsApp Web's own WAWap module
/// (encodeStanza / decodeStanza): list headers, the single-byte and dictionary tokens, nibble and hex
/// packed strings, binary lengths, and the four JID forms. A stanza is one flags byte (bit 2: the
/// rest is zlib-compressed) followed by one node.
module wa.binary.codec;

import wa.binary.dict;
import wa.binary.node;

// the tags (WAWap's constants)
enum : ubyte {
    LIST_EMPTY = 0,
    DICTIONARY_0 = 236, DICTIONARY_1 = 237, DICTIONARY_2 = 238, DICTIONARY_3 = 239,
    INTEROP_JID = 245, FB_JID = 246, AD_JID = 247,
    LIST_8 = 248, LIST_16 = 249, JID_PAIR = 250, HEX_8 = 251,
    BINARY_8 = 252, BINARY_20 = 253, BINARY_32 = 254, NIBBLE_8 = 255,
}

private enum ubyte flagCompressed = 2;

class WapException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

// ---- encoding --------------------------------------------------------------------------------------

/// A stanza on the wire: flags byte 0, then the node.
ubyte[] encodeStanza(const ref Node n) {
    auto w = Writer();
    w.put(0);
    w.writeNode(n);
    return w.buf;
}

private struct Writer {
    ubyte[] buf;

    void put(ubyte b) { buf ~= b; }
    void put16(uint v) { buf ~= cast(ubyte)(v >> 8); buf ~= cast(ubyte) v; }
    void put32(uint v) { put16(v >> 16); put16(v & 0xffff); }

    void listHeader(size_t n) {
        if (n < 256) { put(LIST_8); put(cast(ubyte) n); }
        else if (n < 65536) { put(LIST_16); put16(cast(uint) n); }
        else throw new WapException("list too long");
    }

    void writeNode(const ref Node n) {
        size_t size = 1 + n.attrs.length * 2 + ((n.children.length || n.hasBytes) ? 1 : 0);
        listHeader(size);
        writeString(n.tag);
        foreach (a; n.attrs) {
            writeString(a.key);
            writeValue(a.value);
        }
        if (n.children.length) {
            listHeader(n.children.length);
            foreach (ref c; n.children) writeNode(c);
        } else if (n.hasBytes) {
            writeBytes(n.bytes);
        }
    }

    void writeValue(const ref Value v) {
        if (v.isJid) writeJid(v.jid);
        else writeString(v.str);
    }

    void writeJid(const ref Jid j) {
        final switch (j.kind) {
            case Jid.Kind.device:
                put(AD_JID);
                put(cast(ubyte) j.domain);
                put(cast(ubyte) j.device);
                writeString(j.user);
                break;
            case Jid.Kind.fb:
                put(FB_JID);
                writeString(j.user);
                put16(j.device);
                writeString("msgr");
                break;
            case Jid.Kind.interop:
                put(INTEROP_JID);
                writeString(j.user);
                put16(j.device);
                put16(j.integrator);
                break;
            case Jid.Kind.pair:
                put(JID_PAIR);
                if (j.user is null) put(LIST_EMPTY);
                else writeString(j.user);
                writeString(j.server);
                break;
        }
    }

    // WAWap.le: "" as empty binary, a token, a packed string, or UTF-8 bytes
    void writeString(string s) {
        if (s.length == 0) { put(BINARY_8); put(0); return; }
        if (auto i = s in singleIndex) { put(cast(ubyte)(*i + 1)); return; }
        foreach (d, idx; dictIndex)
            if (auto i = s in idx) { put(cast(ubyte)(DICTIONARY_0 + d)); put(cast(ubyte) *i); return; }
        if (s.length < 128) {
            if (!onlyNibble(s)) {
                if (onlyHex(s)) { writePacked(s, HEX_8); return; }
            } else {
                writePacked(s, NIBBLE_8);
                return;
            }
        }
        writeLength(s.length);
        buf ~= cast(const(ubyte)[]) s;
    }

    void writeBytes(const(ubyte)[] b) {
        writeLength(b.length);
        buf ~= b;
    }

    void writeLength(size_t n) {
        if (n < 256) { put(BINARY_8); put(cast(ubyte) n); }
        else if (n < 1 << 20) { put(BINARY_20); put(cast(ubyte)(n >> 16 & 0xff)); put(cast(ubyte)(n >> 8 & 0xff)); put(cast(ubyte)(n & 0xff)); }
        else if (n < 1UL << 32) { put(BINARY_32); put32(cast(uint) n); }
        else throw new WapException("binary too long for WAP");
    }

    void writePacked(string s, ubyte kind) {
        put(kind);
        ubyte count = cast(ubyte)((s.length + 1) / 2);
        if (s.length % 2) count |= 128;
        put(count);
        ubyte cur;
        foreach (i, char ch; s) {
            ubyte v = packNibble(ch, kind);
            if (i % 2 == 0) {
                cur = cast(ubyte)(v << 4);
                if (i == s.length - 1) put(cast(ubyte)(cur | 15));
            } else {
                put(cast(ubyte)(cur | v));
            }
        }
    }
}

private ubyte packNibble(char c, ubyte kind) {
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (kind == NIBBLE_8) {
        if (c == '-') return 10;
        if (c == '.') return 11;
    } else if (c >= 'A' && c <= 'F') {
        return cast(ubyte)(c - 'A' + 10);
    }
    throw new WapException("cannot pack character " ~ c);
}

private bool onlyNibble(string s) {
    foreach (char c; s) if (!((c >= '0' && c <= '9') || c == '-' || c == '.')) return false;
    return true;
}

private bool onlyHex(string s) {
    foreach (char c; s) if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}

private immutable size_t[string] singleIndex;
private immutable size_t[string][4] dictIndex;

shared static this() {
    size_t[string] s;
    foreach (i, t; singleByteTokens) s[t] = i;
    singleIndex = cast(immutable) s;
    foreach (d; 0 .. 4) {
        size_t[string] m;
        foreach (i, t; dictionaries[d]) m[t] = i;
        dictIndex[d] = cast(immutable) m;
    }
}

// ---- decoding --------------------------------------------------------------------------------------

/// A stanza from the wire: its flags byte, then the node (inflated first when compressed).
Node decodeStanza(const(ubyte)[] data) {
    if (data.length == 0) throw new WapException("empty stanza");
    const flags = data[0];
    const(ubyte)[] body = data[1 .. $];
    if (flags & flagCompressed) {
        import std.zlib : uncompress;
        body = cast(const(ubyte)[]) uncompress(body);
    }
    auto r = Reader(body);
    return r.readNode();
}

private struct Reader {
    const(ubyte)[] buf;
    size_t pos;

    ubyte u8() {
        if (pos >= buf.length) throw new WapException("stanza ends early");
        return buf[pos++];
    }
    uint u16() { return (cast(uint) u8() << 8) | u8(); }
    uint u32() { return (u16() << 16) | u16(); }
    const(ubyte)[] take(size_t n) {
        if (pos + n > buf.length) throw new WapException("stanza ends early");
        auto b = buf[pos .. pos + n];
        pos += n;
        return b;
    }

    size_t listSize(ubyte tag) {
        if (tag == LIST_EMPTY) return 0;
        if (tag == LIST_8) return u8();
        if (tag == LIST_16) return u16();
        throw new WapException("not a list");
    }

    Node readNode() {
        const t = u8();
        size_t n;
        if (t == LIST_8) n = u8();
        else if (t == LIST_16) n = u16();
        else throw new WapException("node expected");
        if (n == 0) throw new WapException("empty node");
        Node node;
        node.tag = readString();
        n -= 1;
        while (n > 1) {
            const key = readString();
            node.attrs ~= Attr(key, readAny().v);
            n -= 2;
        }
        if (n == 1) readContent(node);
        return node;
    }

    // the content: child nodes, or bytes (a JID or a token string as its text)
    void readContent(ref Node node) {
        const t = u8();
        if (t == LIST_EMPTY) return;
        if (t == LIST_8 || t == LIST_16) {
            const count = t == LIST_8 ? u8() : u16();
            foreach (_; 0 .. count) node.children ~= readNode();
            return;
        }
        pos--;
        auto v = readAny();
        node.hasBytes = true;
        node.bytes = v.isBinary ? v.bin : cast(const(ubyte)[]) v.v.toString();
    }

    struct Read {
        Value v;
        bool isBinary;
        const(ubyte)[] bin;
    }

    // WAWap.pe
    Read readAny() {
        const t = u8();
        switch (t) {
            case LIST_EMPTY:
                return Read(Value(cast(string) null));
            case BINARY_8: { auto b = take(u8()); return Read(Value(cast(string) b.idup), true, b); }
            case BINARY_20: {
                const a = u8(), b = u8(), c = u8();
                auto d = take(((a & 15) << 16) + (b << 8) + c);
                return Read(Value(cast(string) d.idup), true, d);
            }
            case BINARY_32: { auto d = take(u32()); return Read(Value(cast(string) d.idup), true, d); }
            case JID_PAIR: {
                auto user = readAny();
                string server = readString();
                string u = user.v.str.length || user.isBinary ? user.v.str : null;
                return Read(Value(Jid.pair(u, server)));
            }
            case FB_JID: {
                string user = readString();
                const dev = cast(ushort) u16();
                readString(); // "msgr"
                return Read(Value(Jid(Jid.Kind.fb, user, "msgr", dev)));
            }
            case INTEROP_JID: {
                string user = readString();
                const dev = cast(ushort) u16();
                const integ = cast(ushort) u16();
                readString(); // "interop"
                return Read(Value(Jid(Jid.Kind.interop, user, "interop", dev, Jid.Domain.whatsapp, integ)));
            }
            case AD_JID: {
                const dom = u8();
                Jid.Domain d;
                if (dom == 0) d = Jid.Domain.whatsapp;
                else if (dom == 1) d = Jid.Domain.lid;
                else if ((dom & 1) == 0 && (dom & 128) != 0) d = Jid.Domain.hosted;
                else if (dom == 129) d = Jid.Domain.hostedLid;
                else throw new WapException("bad JID domain");
                const dev = u8();
                string user = readString();
                return Read(Value(Jid.deviceJid(user, d, dev)));
            }
            case NIBBLE_8: return Read(Value(unpack("0123456789-.����")));
            case HEX_8: return Read(Value(unpack("0123456789ABCDEF")));
            default:
                if (t >= DICTIONARY_0 && t <= DICTIONARY_3) {
                    const d = t - DICTIONARY_0;
                    const i = u8();
                    if (i >= dictionaries[d].length) throw new WapException("bad dictionary index");
                    return Read(Value(dictionaries[d][i]));
                }
                if (t == 0 || t >= 240 || t - 1 >= singleByteTokens.length) throw new WapException("bad token");
                return Read(Value(singleByteTokens[t - 1]));
        }
    }

    string unpack(dstring alphabet) {
        const b = u8();
        const odd = b >> 7;
        const count = b & 127;
        dchar[] out_;
        foreach (_; 0 .. count) {
            const x = u8();
            out_ ~= alphabet[x >> 4];
            out_ ~= alphabet[x & 15];
        }
        if (odd) out_ = out_[0 .. $ - 1];
        import std.conv : to;
        return out_.to!string;
    }

    string readString() {
        auto r = readAny();
        if (r.v.isJid) throw new WapException("string expected");
        return r.v.str;
    }
}
