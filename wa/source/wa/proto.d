/// The protobuf wire format, by hand: WhatsApp's messages (handshake, ClientPayload, certificates,
/// later Message/ADV/history) are written and read field by field, as WhatsApp Web's own
/// encodeProtobuf / decodeProtobuf do from their specs, without generated code.
module wa.proto;

enum Wire : ubyte { varint = 0, fixed64 = 1, bytes = 2, fixed32 = 5 }

class ProtoException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Writes fields in the order given (protobuf's canonical order is by field number: call it so).
struct ProtoWriter {
    ubyte[] buf;

    private void rawVarint(ulong v) {
        while (v >= 0x80) { buf ~= cast(ubyte)(v | 0x80); v >>= 7; }
        buf ~= cast(ubyte) v;
    }
    private void key(uint field, Wire w) { rawVarint((cast(ulong) field << 3) | w); }

    ref ProtoWriter varint(uint field, ulong v) return { key(field, Wire.varint); rawVarint(v); return this; }
    /// int32/int64: negatives as their 64-bit two's complement, as protobuf does
    ref ProtoWriter int64(uint field, long v) return { return varint(field, cast(ulong) v); }
    ref ProtoWriter boolean(uint field, bool v) return { return varint(field, v ? 1 : 0); }
    ref ProtoWriter bytes(uint field, const(ubyte)[] b) return {
        key(field, Wire.bytes);
        rawVarint(b.length);
        buf ~= b;
        return this;
    }
    ref ProtoWriter str(uint field, string s) return { return bytes(field, cast(const(ubyte)[]) s); }
    ref ProtoWriter message(uint field, const ProtoWriter m) return { return bytes(field, m.buf); }
    ref ProtoWriter fixed32(uint field, uint v) return {
        key(field, Wire.fixed32);
        foreach (i; 0 .. 4) buf ~= cast(ubyte)(v >> (8 * i));
        return this;
    }
    ref ProtoWriter fixed64(uint field, ulong v) return {
        key(field, Wire.fixed64);
        foreach (i; 0 .. 8) buf ~= cast(ubyte)(v >> (8 * i));
        return this;
    }
}

/// Re-encode the fields of `msg` with field `replace` dropped and `with_` written (as bytes) in its
/// place in field-number order — how a Message's sub-message gets a new value, others untouched.
ubyte[] replaceField(const(ubyte)[] msg, uint replace, const(ubyte)[] with_) {
    auto w = ProtoWriter();
    bool written;
    foreach (f; ProtoReader(msg)) {
        if (f.number == replace) continue;
        if (!written && with_ !is null && f.number > replace) { w.bytes(replace, with_); written = true; }
        final switch (f.wire) {
            case Wire.varint: w.varint(f.number, f.value); break;
            case Wire.fixed64: w.fixed64(f.number, f.value); break;
            case Wire.fixed32: w.fixed32(f.number, cast(uint) f.value); break;
            case Wire.bytes: w.bytes(f.number, f.bytes); break;
        }
    }
    if (!written && with_ !is null) w.bytes(replace, with_);
    return w.buf;
}

unittest {
    auto m = ProtoWriter().str(1, "a").varint(5, 7).str(20, "z").buf;
    auto r = replaceField(m, 17, [9]);
    assert(r == ProtoWriter().str(1, "a").varint(5, 7).bytes(17, [9]).str(20, "z").buf);
    assert(replaceField(r, 17, [8]) == ProtoWriter().str(1, "a").varint(5, 7).bytes(17, [8]).str(20, "z").buf);
}

/// One field read off the wire.
struct Field {
    uint number;
    Wire wire;
    ulong value;              // varint and fixed values
    const(ubyte)[] bytes;     // length-delimited content

    long int64() const { return cast(long) value; }
    bool boolean() const { return value != 0; }
    string str() const { return cast(string) bytes.idup; }
}

/// Iterates a message's fields: foreach (f; ProtoReader(data)) switch (f.number) …
struct ProtoReader {
    const(ubyte)[] data;

    int opApply(scope int delegate(Field) dg) {
        size_t pos;
        ulong varint() {
            ulong v;
            uint shift;
            while (true) {
                if (pos >= data.length) throw new ProtoException("truncated varint");
                const b = data[pos++];
                if (shift >= 64) throw new ProtoException("varint too long");
                v |= cast(ulong)(b & 0x7f) << shift;
                if (!(b & 0x80)) return v;
                shift += 7;
            }
        }
        ulong fixed(size_t n) {
            if (pos + n > data.length) throw new ProtoException("truncated fixed field");
            ulong v;
            foreach (i; 0 .. n) v |= cast(ulong) data[pos + i] << (8 * i);
            pos += n;
            return v;
        }
        while (pos < data.length) {
            const k = varint();
            Field f;
            f.number = cast(uint)(k >> 3);
            f.wire = cast(Wire)(k & 7);
            final switch (f.wire) {
                case Wire.varint: f.value = varint(); break;
                case Wire.fixed64: f.value = fixed(8); break;
                case Wire.fixed32: f.value = fixed(4); break;
                case Wire.bytes:
                    const n = varint();
                    if (n > data.length - pos) throw new ProtoException("truncated bytes field");
                    f.bytes = data[pos .. pos + cast(size_t) n];
                    pos += cast(size_t) n;
                    break;
            }
            if (f.wire != Wire.varint && f.wire != Wire.fixed64 && f.wire != Wire.fixed32 && f.wire != Wire.bytes)
                throw new ProtoException("unsupported wire type");
            if (auto r = dg(f)) return r;
        }
        return 0;
    }

    /// The first occurrence of a field (null bytes / zero when absent).
    Field get(uint number) {
        foreach (f; this) if (f.number == number) return f;
        return Field.init;
    }
    bool has(uint number) {
        foreach (f; this) if (f.number == number) return true;
        return false;
    }
}

unittest {
    ProtoWriter inner;
    inner.varint(1, 300).str(2, "hi");
    ProtoWriter w;
    w.message(2, inner).boolean(3, true).int64(4, -1).fixed32(5, 0xdeadbeef);
    // 300 = ac 02; -1 is ten bytes
    assert(inner.buf == [0x08, 0xac, 0x02, 0x12, 0x02, 'h', 'i']);
    auto r = ProtoReader(w.buf);
    assert(ProtoReader(r.get(2).bytes).get(1).value == 300);
    assert(ProtoReader(r.get(2).bytes).get(2).str == "hi");
    assert(r.get(3).boolean);
    assert(r.get(4).int64 == -1);
    assert(r.get(5).value == 0xdeadbeef);
    assert(!r.has(9));
}
