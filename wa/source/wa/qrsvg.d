/// The pairing QR as an SVG, drawn from libqrencode (linked, so the app needs no `qrencode` program):
/// WhatsApp Web's look — high error correction (the logo drawn over the middle does not stop a scan),
/// no quiet zone, WhatsApp's dark teal on white.
module wa.qrsvg;

private extern (C) nothrow @nogc {
    struct QRcode { int version_; int width; ubyte* data; }
    QRcode* QRcode_encodeString(const(char)* string, int version_, int level, int hint, int casesensitive);
    void QRcode_free(QRcode* qrcode);
}
private enum QR_ECLEVEL_H = 3, QR_MODE_8 = 2;

/// `code` as an SVG document (one path of unit squares on a white square, `size` px), "" if it cannot
/// be encoded.
string qrSvg(string code, int size = 456, string colour = "#122E31") {
    import std.string : toStringz;
    import std.conv : to;
    import std.array : appender;
    auto q = QRcode_encodeString(code.toStringz, 0, QR_ECLEVEL_H, QR_MODE_8, 1);
    if (q is null) return "";
    scope (exit) QRcode_free(q);
    const w = q.width;
    auto path = appender!string;
    foreach (y; 0 .. w)
        foreach (x; 0 .. w)
            if (q.data[y * w + x] & 1) path ~= "M" ~ x.to!string ~ " " ~ y.to!string ~ "h1v1h-1z";
    return `<svg xmlns="http://www.w3.org/2000/svg" width="` ~ size.to!string ~ `" height="` ~ size.to!string
        ~ `" viewBox="0 0 ` ~ w.to!string ~ ` ` ~ w.to!string ~ `" shape-rendering="crispEdges">`
        ~ `<rect width="` ~ w.to!string ~ `" height="` ~ w.to!string ~ `" fill="#FFFFFF"/>`
        ~ `<path fill="` ~ colour ~ `" d="` ~ path.data ~ `"/></svg>`;
}

unittest {
    import std.algorithm : canFind, startsWith;
    const svg = qrSvg("2@abc,def,ghi,jkl");
    assert(svg.startsWith("<svg") && svg.canFind(`fill="#122E31"`) && svg.canFind("h1v1h-1z"));
    // a pairing payload (~200 bytes) needs a version well above 1 (21 modules)
    import std.regex : matchFirst;
    import std.array : replicate;
    import std.conv : to;
    auto m = qrSvg("2@" ~ "A".replicate(200)).matchFirst(`viewBox="0 0 (\d+)`);
    assert(!m.empty && m[1].to!int > 21);
}
