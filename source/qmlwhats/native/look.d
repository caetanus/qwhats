// The UI's `look`: WhatsApp's own artwork for the native screen (icons, the chat wallpaper doodle),
// tinted on demand. The SVGs come from WhatsApp Web (tools/wa-icons.mjs) and are drawn with
// `currentColor`; a QML Image cannot recolour an SVG, so each (icon, colour) pair the UI asks for is
// written once as its own file, with the colour baked in.
module qmlwhats.native.look;

import qtmoc;
import std.file : exists, readText, write, mkdirRecurse;
import std.path : buildPath, dirName;
import std.string : replace, toLower;
import std.conv : to;

@QObject class Look {
    Signal!() changed;

    /// file:// folder of the tinted files: `<base>/<name>-<colour>.svg` once ensure() has run.
    @Property("changed") string base = "";
    /// The artwork was found (tools/wa-icons.mjs has been run): without it the UI draws plain shapes.
    @Property("changed") bool ok = false;
    /// Where the UI may write its own files (recorded voice notes, pasted images).
    @Property("changed") string cacheDir = "";
    /// file:// folder of the map tile providers for Qt Location's osm plugin (writeMapProviders).
    @Property("changed") string mapProviders = "";
    /// The last image pasted with Ctrl+V, saved as PNG ("" when the clipboard had no image).
    @Property("pastedChanged") string pasted = "";
    Signal!() pastedChanged;

    private string src, dst;
    private bool[string] done;

    void setUp(string artDir, string cacheDir) {
        src = artDir;
        dst = buildPath(cacheDir, "wa-tinted");
        mkdirRecurse(dst);
        this.cacheDir = buildPath(cacheDir, "outbox");
        mkdirRecurse(this.cacheDir);
        mapProviders = "file://" ~ writeMapProviders(buildPath(cacheDir, "map-providers"));
        ok = exists(buildPath(src, "icons", "chats.svg"));
        base = "file://" ~ dst;
        changed.emit();
    }

    /// "Copiar" in a message's menu: the text to the clipboard.
    @Slot void copyText(string text) {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.qclipboard : QClipboard;
        auto cb = QGuiApplication.clipboard();
        if (cb !is null) cb.setText(text, QClipboard.Mode.Clipboard);
    }

    /// "Copiar imagem" in a picture's menu: the file's bytes as its own image type, handed to the
    /// desktop's clipboard tool (wl-copy on Wayland, xclip on X11). Not through a QMimeData made
    /// here: the D wrapper keeps owning it and frees it under the clipboard (it crashed the app).
    @Slot void copyImage(string path) {
        import std.process : spawnProcess, environment, Config;
        import std.stdio : File, stderr;
        import std.path : extension;
        if (path.length > 7 && path[0 .. 7] == "file://") path = path[7 .. $];
        if (!exists(path)) { stderr.writeln("qwhats: copyImage: no file ", path); return; }
        string mime;
        switch (extension(path).toLower) {
            case ".jpg", ".jpeg": mime = "image/jpeg"; break;
            case ".png": mime = "image/png"; break;
            case ".webp": mime = "image/webp"; break;
            case ".gif": mime = "image/gif"; break;
            default: mime = "image/png"; break;
        }
        const wayland = environment.get("WAYLAND_DISPLAY", "").length > 0;
        const cmd = wayland ? ["wl-copy", "--type", mime] : ["xclip", "-selection", "clipboard", "-t", mime];
        try {
            // the tool keeps serving the clipboard after we let go of it (detached, not waited for)
            spawnProcess(cmd, File(path, "rb"), File("/dev/null", "w"), stderr, null, Config.detached);
        } catch (Exception e) stderr.writeln("qwhats: copyImage: ", e.msg);
    }

    /// Ctrl+V in the composer: an image on the clipboard (a screenshot, a copied picture) becomes a
    /// PNG for the send preview, as WhatsApp Web pastes images.
    @Slot void pasteImage() {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.qclipboard : QClipboard;
        import std.datetime : Clock;
        import std.file : write;
        import std.stdio : stderr;
        import std.string : startsWith, splitLines, strip, indexOf;
        import std.algorithm : canFind;
        pasted = "";
        auto cb = QGuiApplication.clipboard();
        auto md = cb is null ? null : cb.mimeData(QClipboard.Mode.Clipboard);
        const stamp = Clock.currTime.toUnixTime.to!string;
        string[] fmts = md is null ? null : md.formats();
        stderr.writeln("qwhats: paste formats ", fmts);
        // a file copied in the file manager: its path (sent as it is, photo or document)
        if (md !is null && md.hasUrls()) {
            foreach (u; md.urls()) {
                if (!u.isLocalFile()) continue;
                const f = u.toLocalFile().toString();
                if (exists(f)) { pasted = f; break; }
            }
        }
        // the image itself: Qt's own conversion, else the raw bytes of the first image/* format
        if (pasted == "" && md !is null && md.hasImage()) {
            auto img = cb.image(QClipboard.Mode.Clipboard);
            const path = buildPath(cacheDir, "pasted-" ~ stamp ~ ".png");
            if (!img.isNull() && img.save(path, "PNG", -1)) pasted = path;
        }
        if (pasted == "" && md !is null) {
            foreach (f; fmts) {
                if (!f.startsWith("image/")) continue;
                auto b = md.data(f).toBytes();
                if (b.length == 0) continue;
                string ext = f["image/".length .. $];
                if (ext == "jpeg") ext = "jpg";
                if (ext.indexOf('+') >= 0 || ext.indexOf(';') >= 0) ext = "png";
                const path = buildPath(cacheDir, "pasted-" ~ stamp ~ "." ~ ext);
                write(path, b);
                pasted = path;
                break;
            }
        }
        // a path or file:// URL as text (some file managers copy files that way)
        if (pasted == "" && md !is null && fmts.canFind("text/plain")) {
            foreach (line; md.text().toString().splitLines()) {
                string f = line.strip();
                if (f.startsWith("file://")) f = f["file://".length .. $];
                if (f.startsWith("/") && exists(f)) { pasted = f; break; }
            }
        }
        stderr.writeln("qwhats: pasted ", pasted == "" ? "(nothing)" : pasted);
        pastedChanged.emit();
    }

    /// Writes `<name>-<key>.svg` painted `color` (#rrggbb, or rgba(r, g, b, a)) unless it exists.
    /// `name` is an icon (icons/<name>.svg) or "doodle" (the chat wallpaper). The UI calls this right
    /// before it uses the path (keyOf gives the same key in TSX: the colour, lower-case, letters only).
    @Slot void ensure(string name, string color) {
        const file = name ~ "-" ~ keyOf(color) ~ ".svg";
        if (file in done) return;
        done[file] = true;
        const target = buildPath(dst, file);
        if (exists(target)) return;
        string from = name == "doodle" ? buildPath(src, "doodle.svg") : buildPath(src, "icons", name ~ ".svg");
        // icons WhatsApp has no counterpart for (the SMS tab's) are our own, in git: assets/icons
        if (!exists(from)) from = buildPath(dirName(src), "icons", name ~ ".svg");
        if (!exists(from)) return;
        string hex; double alpha;
        parse(color, hex, alpha);
        string svg = readText(from);
        if (alpha < 1) {
            const a = alpha.to!string;
            svg = svg.replace(`fill="currentColor"`, `fill="` ~ hex ~ `" fill-opacity="` ~ a ~ `"`)
                     .replace(`stroke="currentColor"`, `stroke="` ~ hex ~ `" stroke-opacity="` ~ a ~ `"`);
        }
        svg = svg.replace("currentColor", hex);
        try write(target, svg);
        catch (Exception) {}
    }
}

/// The location bubble's maps: Esri's Light Gray and Dark Gray canvases (OpenStreetMap's own tiles
/// look dated; CARTO's now want an API key). Their URLs are z/y/x, which the osm plugin only takes
/// from a provider file: "street" is the light map, "night-transit" the dark one.
string writeMapProviders(string dir) {
    mkdirRecurse(dir);
    void provider(string name, string service, string id) {
        write(buildPath(dir, name), `{"UrlTemplate": "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/` ~ service
            ~ `/MapServer/tile/%z/%y/%x", "ImageFormat": "jpg", "QImageFormat": "RGB888", "ID": "` ~ id
            ~ `", "MaximumZoomLevel": 16, "MapCopyRight": "Esri", "DataCopyRight": "Esri, HERE, Garmin, © OpenStreetMap contributors"}` ~ "\n");
    }
    try {
        provider("street", "World_Light_Gray_Base", "esri-light-gray");
        provider("night-transit", "World_Dark_Gray_Base", "esri-dark-gray");
    } catch (Exception) {}
    return dir;
}

/// "#21C063" → "21c063"; "rgba(255, 255, 255, .6)" → "rgba2552552556".
string keyOf(string color) {
    string k;
    foreach (c; color.toLower)
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) k ~= c;
    return k;
}

private void parse(string color, out string hex, out double alpha) {
    import std.format : format;
    import std.algorithm : map, splitter;
    import std.array : array;
    import std.string : strip, startsWith;
    alpha = 1;
    hex = color;
    if (!color.startsWith("rgb")) return;
    const inner = color[color.indexOfChar('(') + 1 .. $ - 1];
    auto parts = inner.splitter(',').map!(s => s.strip).array;
    hex = format("#%02x%02x%02x", parts[0].to!int, parts[1].to!int, parts[2].to!int);
    if (parts.length > 3) alpha = parts[3].to!double;
}

private size_t indexOfChar(string s, char c) {
    foreach (i, ch; s) if (ch == c) return i;
    return 0;
}

unittest {
    assert(keyOf("#21C063") == "21c063");
    assert(keyOf("rgba(255, 255, 255, .6)") == "rgba2552552556");
    string h; double a;
    parse("rgba(255, 255, 255, .6)", h, a);
    assert(h == "#ffffff" && a > 0.59 && a < 0.61);
    parse("#0A0A0A", h, a);
    assert(h == "#0A0A0A" && a == 1);
}
