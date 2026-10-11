// Where things live and what must be in the environment BEFORE Qt starts: the XDG folders, the
// spell-check dictionaries (Chromium reads only its own .bdic format, converted once from the
// system's hunspell .dic/.aff), Chromium's flags, and the icons in the UI's colours. Qt-free.
module qmlwhats.env;

import std.path : buildPath, baseName, stripExtension, dirName;
import std.process : environment;
import std.file;
import std.string : strip, replace, startsWith;

string home() { return environment.get("HOME", "/tmp"); }
string configDir() { return buildPath(environment.get("XDG_CONFIG_HOME", buildPath(home(), ".config")), "qml-whats"); }
string dataDir() { return buildPath(environment.get("XDG_DATA_HOME", buildPath(home(), ".local", "share")), "qml-whats"); }
/// The remote-control socket (qmlwhats.rpc): in the per-user runtime directory.
string rpcSocketPath() {
    return buildPath(environment.get("XDG_RUNTIME_DIR", buildPath("/tmp", "qwhats-" ~ uidString())), "qwhats.sock");
}
private string uidString() {
    import core.sys.posix.unistd : getuid;
    import std.conv : to;
    return getuid().to!string;
}
string cacheDir() { return buildPath(environment.get("XDG_CACHE_HOME", buildPath(home(), ".cache")), "qml-whats"); }

/// The user's Downloads folder (xdg-user-dirs, in the user's language), + "QWhats".
string defaultDownloadDir() {
    return buildPath(xdgUserDir("DOWNLOAD", buildPath(home(), "Downloads")), "QWhats");
}

/// Where downloads went before 2026-10-11: a settings file still naming it moves to the new default.
string oldDownloadDir() {
    return buildPath(xdgUserDir("DOWNLOAD", buildPath(home(), "Downloads")), "WhatsApp");
}

/// XDG_<KEY>_DIR from ~/.config/user-dirs.dirs: `XDG_DOWNLOAD_DIR="$HOME/Transferências"`.
string xdgUserDir(string key, string fallback) {
    const f = buildPath(environment.get("XDG_CONFIG_HOME", buildPath(home(), ".config")), "user-dirs.dirs");
    if (!exists(f)) return fallback;
    try return parseUserDir(readText(f), key, home(), fallback);
    catch (Exception) return fallback;
}

string parseUserDir(string text, string key, string homeDir, string fallback) {
    import std.algorithm : splitter;
    const want = "XDG_" ~ key ~ "_DIR=";
    foreach (line; text.splitter('\n')) {
        auto l = line.strip;
        if (!l.startsWith(want)) continue;
        auto v = l[want.length .. $].strip;
        if (v.length >= 2 && v[0] == '"' && v[$ - 1] == '"') v = v[1 .. $ - 1];
        v = v.replace("$HOME", homeDir);
        return v.length ? v : fallback;
    }
    return fallback;
}

unittest {
    const t = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_DOWNLOAD_DIR=\"$HOME/Transferências\"\n";
    assert(parseUserDir(t, "DOWNLOAD", "/home/u", "x") == "/home/u/Transferências");
    assert(parseUserDir(t, "MUSIC", "/home/u", "x") == "x");
}

/// Spell-check: every hunspell dictionary on the system converted to Chromium's .bdic under our
/// data folder (once — a later run only converts new ones), and QTWEBENGINE_DICTIONARIES_PATH set to
/// it. Returns the language names the profile can be given ("pt-BR", "en-US").
string[] prepareDictionaries() {
    import std.process : execute;
    import std.algorithm : sort, uniq;
    import std.array : array;
    const outDir = buildPath(dataDir(), "qtwebengine_dictionaries");
    const tool = "/usr/lib/qt6/qwebengine_convert_dict";
    string[] langs;
    try mkdirRecurse(outDir);
    catch (Exception) return langs;
    // already converted (or dropped in by hand)
    foreach (e; dirEntries(outDir, "*.bdic", SpanMode.shallow)) langs ~= baseName(e.name).stripExtension;
    const sources = ["/usr/share/hunspell", "/usr/share/myspell/dicts", "/usr/share/myspell", buildPath(dataDir(), "hunspell")];
    foreach (dir; sources) {
        if (!exists(dir) || !isDir(dir)) continue;
        foreach (e; dirEntries(dir, "*.dic", SpanMode.shallow)) {
            const stem = e.name.stripExtension;
            const lang = baseName(stem).replace("_", "-");
            if (lang.startsWith("hyph") || !exists(stem ~ ".aff")) continue;   // hyphenation patterns, not a dictionary
            const bdic = buildPath(outDir, lang ~ ".bdic");
            if (!exists(bdic) && exists(tool)) {
                const r = execute([tool, e.name, bdic]);
                if (r.status != 0 || !exists(bdic)) continue;
            }
            if (exists(bdic)) langs ~= lang;
        }
    }
    environment["QTWEBENGINE_DICTIONARIES_PATH"] = outDir;
    return langs.sort.uniq.array;
}

/// Chromium's switches, added to whatever the user already exports. Chromium keeps only the LAST
/// --enable-features, so the features are merged into one list (a second switch would silently drop
/// the first's).
///  - WebRTCPipeWireCapturer: screen sharing on Wayland (the desktop portal picks the screen/window).
///  - SharedArrayBuffer: WhatsApp's calls need it (WAWebVoipGatingUtils.getUnsupportedBrowserReason
///    answers "missing_shared_array_buffer" without it: "browser not supported for calls"). Chrome
///    gives it only to cross-origin-isolated pages, and web.whatsapp.com is not one (COOP
///    same-origin-allow-popups); this is the switch behind Chrome's own
///    SharedArrayBufferUnrestrictedAccessAllowed policy. The risk it opens (timing side channels across
///    origins in one process) is small here: this browser only ever shows WhatsApp — links leave for
///    the system browser.
void chromiumFlags(bool software) {
    import std.array : split, join, array;
    import std.algorithm : canFind, filter, startsWith;
    string[] parts = environment.get("QTWEBENGINE_CHROMIUM_FLAGS", "").split(" ").filter!(p => p.length).array;
    string[] features = ["WebRTCPipeWireCapturer", "SharedArrayBuffer"];
    string[] rest;
    foreach (p; parts) {
        enum key = "--enable-features=";
        if (p.startsWith(key)) { foreach (f; p[key.length .. $].split(",")) if (f.length && !features.canFind(f)) features ~= f; }
        else rest ~= p;
    }
    if (software && !rest.canFind("--disable-gpu")) rest ~= "--disable-gpu";
    environment["QTWEBENGINE_CHROMIUM_FLAGS"] = (rest ~ ("--enable-features=" ~ features.join(","))).join(" ");
}

/// The page's prefers-color-scheme (Chromium reads it once, at start: changing it means a restart).
/// "dark" / "light", or "" to leave Chromium's own.
void colorSchemeFlag(string scheme) {
    if (scheme != "dark" && scheme != "light") return;
    string flags = environment.get("QTWEBENGINE_CHROMIUM_FLAGS", "");
    flags = (flags.length ? flags ~ " " : "") ~ "--blink-settings=preferredColorScheme=" ~ (scheme == "dark" ? "0" : "1");
    environment["QTWEBENGINE_CHROMIUM_FLAGS"] = flags;
}

/// Lucide's SVGs (stroke="currentColor") in each of the UI's colours, written under
/// <dir>/<variant>/<name>.svg. Returns <dir>.
string writeIcons(string dir, const string[2][] variants, const string[2][] icons) {
    foreach (v; variants) {
        const vdir = buildPath(dir, v[0]);
        mkdirRecurse(vdir);
        foreach (ic; icons) {
            const path = buildPath(vdir, ic[0] ~ ".svg");
            const svg = ic[1].replace("currentColor", v[1]);
            if (!exists(path) || readText(path) != svg) write(path, svg);
        }
    }
    return dir;
}

/// The environment for programs QWhats starts (the system's file opener, the file manager, a
/// restart): the AppImage's AppRun points LD_LIBRARY_PATH at the bundled libraries, which must not
/// leak into them — a PDF viewer would load QWhats' Qt. AppRun keeps the original in
/// QWHATS_ORIG_LD_LIBRARY_PATH ("__unset__" when there was none). Outside an AppImage: unchanged.
string[string] childEnv() {
    auto env = environment.toAA();
    if (auto orig = "QWHATS_ORIG_LD_LIBRARY_PATH" in env) {
        if (*orig == "__unset__") env.remove("LD_LIBRARY_PATH");
        else env["LD_LIBRARY_PATH"] = *orig;
        env.remove("QWHATS_ORIG_LD_LIBRARY_PATH");
    }
    return env;
}

unittest {
    environment["QWHATS_ORIG_LD_LIBRARY_PATH"] = "__unset__";
    environment["LD_LIBRARY_PATH"] = "/appdir/usr/lib";
    auto e = childEnv();
    assert("LD_LIBRARY_PATH" !in e && "QWHATS_ORIG_LD_LIBRARY_PATH" !in e);
    environment["QWHATS_ORIG_LD_LIBRARY_PATH"] = "/opt/x";
    assert(childEnv()["LD_LIBRARY_PATH"] == "/opt/x");
    environment.remove("QWHATS_ORIG_LD_LIBRARY_PATH");
    environment.remove("LD_LIBRARY_PATH");
}

/// file:// URL of a local path (percent-encoding what a URL cannot carry raw).
string fileUrl(string path) {
    import std.uri : encode;
    return "file://" ~ encode(path);
}

unittest {
    environment["QTWEBENGINE_CHROMIUM_FLAGS"] = "--foo --enable-features=Bar,SharedArrayBuffer";
    chromiumFlags(false);
    assert(environment["QTWEBENGINE_CHROMIUM_FLAGS"] == "--foo --enable-features=WebRTCPipeWireCapturer,SharedArrayBuffer,Bar");
    environment.remove("QTWEBENGINE_CHROMIUM_FLAGS");
    chromiumFlags(true);
    assert(environment["QTWEBENGINE_CHROMIUM_FLAGS"] == "--disable-gpu --enable-features=WebRTCPipeWireCapturer,SharedArrayBuffer");
}
