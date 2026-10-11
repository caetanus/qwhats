// The UI's `app`: the settings (read as JSON, changed one key at a time), where things live, the
// icons, and the requests from a second launch. Everything web — the WhatsApp page, calls,
// downloads, notifications — is the UI's own (QtWebEngine, in ui/app/WhatsWeb.qml); D owns what
// must exist before Qt starts or must outlive a session.
module qmlwhats.backend;

import qtmoc;
import std.json;
import std.path : buildPath;
import settings = qmlwhats.settings;
import qmlwhats.env;
import qmlwhats.tray;
import qmlwhats.rpc;

/// The icons the UI uses, embedded at compile time (-J assets/icons).
private enum ICONS = ["message-circle", "download", "settings", "refresh-cw", "x", "file-text", "external-link",
                      "folder-open", "zoom-in", "zoom-out", "monitor", "app-window", "bell", "bell-off", "check",
                      "mic", "video", "phone", "trash-2", "search", "minus", "plus", "maximize-2", "circle-alert"];

private string[2][] iconTable() {
    string[2][] t;
    static foreach (n; ICONS) t ~= [n, import(n ~ ".svg")];
    return t;
}

/// The palette the icons are drawn in (matches app.css).
private immutable string[2][] VARIANTS = [["fg", "#d1d7db"], ["muted", "#8696a0"], ["accent", "#21c063"], ["on", "#0b141a"], ["danger", "#f15c6d"]];

@QObject class App {
    Signal!() settingsChanged;
    Signal!() raiseRequested;
    Signal!() pathsChanged;
    Signal!() darkChanged;
    Signal!() trayChanged;
    /// A remote-control request for the UI: answer it with rpcReply(conn, idJson, …).
    Signal!(int, string, string, string) rpcRequest;

    /// The settings object as JSON (qmlwhats.settings has the keys and their defaults).
    @Property("settingsChanged") string settingsJson = "{}";
    /// file:// folder of the icons: `<iconBase>/<variant>/<name>.svg`.
    @Property("pathsChanged") string iconBase = "";
    /// file:// URLs of the window/tray icon (plain, and with the unread dot).
    @Property("pathsChanged") string appIcon = "";
    @Property("pathsChanged") string appIconUnread = "";
    /// Where Chromium keeps the session (cookies, IndexedDB: the WhatsApp login) and its cache.
    @Property("pathsChanged") string profilePath = "";
    @Property("pathsChanged") string cachePath = "";
    /// Spell-check languages available on this system, as a JSON array.
    @Property("pathsChanged") string dictionariesJson = "[]";
    /// The page loaded at start (--url overrides it, for tests).
    @Property("pathsChanged") string startUrl = "https://web.whatsapp.com/";
    /// Start in the tray (--hidden, or the setting).
    @Property("pathsChanged") bool startHidden = false;
    /// Running from an AppImage that is not the installed copy: offer to install it (first run).
    @Property("settingsChanged") bool installAsk = false;
    /// Where install() puts it.
    @Property("pathsChanged") string installTarget = "";
    /// A --grab run: the window closes for real when the host quits after its one frame.
    @Property("pathsChanged") bool oneShot = false;
    /// Where account profiles live (<profileRoot>/profiles/<id>; the first account keeps profilePath).
    @Property("pathsChanged") string profileRoot = "";
    /// The remote-control socket, "" while remote control is off.
    @Property("settingsChanged") string rpcSocket = "";
    /// --eval FILE: JavaScript run in the page once it has loaded, its result logged (development).
    @Property("pathsChanged") string evalScript = "";
    /// Bumped each time another launch asks this window to come up.
    @Property("raiseRequested") int raiseCount = 0;
    /// The effective look: the "theme" setting, or the desktop's own when it is "system".
    @Property("darkChanged") bool dark = true;
    /// The tray icon is shown by a bar (closing the window can hide it there).
    @Property("trayChanged") bool trayAvailable = false;
    /// Bumped by a click on the tray icon (the UI shows or hides the window).
    @Property("trayChanged") int trayClicks = 0;

    /// Set by restart(): main starts a new process once this one has ended.
    bool restartRequested;
    private Tray tray;
    private int unread;

    private JSONValue current, defs;
    private string settingsFile;

    void setUp(string[] dictionaries, string url, bool hidden, string evalFile = null) {
        if (evalFile.length) {
            import std.file : readText;
            try evalScript = readText(evalFile);
            catch (Exception) {}
        }
        defs = settings.defaults(defaultDownloadDir());
        settingsFile = buildPath(configDir(), "settings.json");
        current = settings.load(settingsFile, defs);
        if (current["downloadDir"].str == oldDownloadDir()) current["downloadDir"] = defs["downloadDir"];
        settingsJson = current.toString();
        profilePath = buildPath(dataDir(), "profile");
        profileRoot = dataDir();
        cachePath = buildPath(cacheDir(), "web");
        dictionariesJson = JSONValue(dictionaries).toString();
        if (url.length) startUrl = url;
        startHidden = hidden || current["startHidden"].boolean;
        try iconBase = fileUrl(writeIcons(buildPath(cacheDir(), "icons"), VARIANTS, iconTable()));
        catch (Exception e) {
            import std.stdio : stderr;
            stderr.writeln("qml-whats: icons not written: ", e.msg);
        }
        writeAppIcons();
        applyTheme();
        applyRemote();
        installTarget = buildPath(home(), ".local", "bin", "qwhats");
        updateInstallAsk();
        colorSchemeFlag(pageScheme());   // before the first web view: Chromium reads it once
        tray = new Tray(new TrayGlue(this));
        if (tray.open()) { updateTray(); rebuildMenu(); }
        import qt.quick.qguiapplication : QGuiApplication;
        QGuiApplication.styleHints().connectColorSchemeChanged((s) { updateDark(); });
    }

    /// The app's colour scheme for Qt — and through it for Chromium, which gives the page
    /// prefers-color-scheme from it (WhatsApp on "Padrão do sistema" follows, live).
    private void applyTheme() {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.colorscheme : ColorScheme;
        auto hints = QGuiApplication.styleHints();
        const t = current["theme"].str;
        if (t == "dark") hints.setColorScheme(ColorScheme.Dark);
        else if (t == "light") hints.setColorScheme(ColorScheme.Light);
        else hints.unsetColorScheme();
        updateDark();
    }

    /// The scheme the page is started with: the setting, or the desktop's at launch.
    private string pageScheme() {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.colorscheme : ColorScheme;
        const t = current["theme"].str;
        if (t == "dark" || t == "light") return t;
        const c = QGuiApplication.styleHints().colorScheme();
        return c == ColorScheme.Dark ? "dark" : c == ColorScheme.Light ? "light" : "";
    }

    /// Bus traffic of the tray and remote-control requests (called from main's timer).
    void pump() {
        if (tray !is null) tray.drain();
        if (rpc is null) return;
        foreach (req; rpc.poll()) {
            JSONValue id, params;
            string method, err;
            if (!parseRequest(req.line, id, method, params, err)) { rpc.reply(req.conn, err); continue; }
            if (handleHere(req.conn, id, method, params)) continue;
            rpcRequest.emit(req.conn, method, params.toString(), id.toString());
        }
    }

    private RpcServer rpc;

    /// Remote control on or off (setting "remoteControl").
    private void applyRemote() {
        const on = current["remoteControl"].boolean;
        if (on && rpc is null) {
            rpc = new RpcServer;
            if (!rpc.open(rpcSocketPath())) {
                import std.stdio : stderr;
                stderr.writeln("qml-whats: remote control socket not opened: ", rpcSocketPath());
                rpc = null;
            }
        } else if (!on && rpc !is null) {
            rpc.close();
            rpc = null;
        }
        rpcSocket = rpc is null ? "" : rpc.path;
    }

    /// What D answers itself: the settings, quitting.
    private bool handleHere(int conn, JSONValue id, string method, JSONValue params) {
        JSONValue res;
        switch (method) {
            case "settings.get":
                res = current;
                break;
            case "settings.set": {
                auto k = "key" in params.object, v = "value" in params.object;
                if (k is null || v is null || k.type != JSONType.string) { rpc.reply(conn, rpcError(id, -32602, "params: {key, value}")); return true; }
                if (k.str == "remoteControl") { rpc.reply(conn, rpcError(id, -32602, "remoteControl is set in the app only")); return true; }
                if (!settings.apply(current, defs, k.str, v.toString())) { rpc.reply(conn, rpcError(id, -32602, "unknown key or wrong type")); return true; }
                set(k.str, v.toString());
                res = current[k.str];
                break;
            }
            case "app.quit":
                res = JSONValue(true);
                rpcReply(conn, id.toString(), res.toString(), "");
                quit();
                return true;
            default:
                return false;
        }
        rpcReply(conn, id.toString(), res.toString(), "");
        return true;
    }

    // ---- installing the AppImage ---------------------------------------------------------------
    /// The AppImage file this process runs from ("" when not an AppImage).
    static string appImage() {
        import std.process : environment;
        return environment.get("APPIMAGE", "");
    }

    private void updateInstallAsk() {
        import std.file : exists;
        import std.path : absolutePath, buildNormalizedPath;
        const img = appImage();
        const installed = img.length && buildNormalizedPath(absolutePath(img)) == buildNormalizedPath(installTarget);
        const ask = img.length && !installed && !current["installDeclined"].boolean;
        if (ask != installAsk) { installAsk = ask; settingsChanged.emit(); }
    }

    /// Move the running AppImage to ~/.local/bin/qwhats, with a launcher in the applications menu and
    /// the icon; then start the installed copy in place of this one. Empty `error` on success.
    Signal!(string) installDone;
    @Slot void install() {
        import std.file : copy, rename, setAttributes, mkdirRecurse, write, exists, remove;
        import std.path : dirName;
        import std.conv : octal;
        const img = appImage();
        if (!img.length) { installDone.emit("not running from an AppImage"); return; }
        try {
            mkdirRecurse(dirName(installTarget));
            // MOVED, not copied (the user's call): one QWhats on the disk, in ~/.local. A rename when it
            // is on the same filesystem; else a copy and the original removed. This process runs on —
            // its open file outlives the name.
            const tmp = installTarget ~ ".new";
            try rename(img, tmp);
            catch (Exception) { copy(img, tmp); remove(img); }
            setAttributes(tmp, octal!755);
            rename(tmp, installTarget);   // atomic: a running old copy keeps its inode
            const icons = buildPath(home(), ".local", "share", "icons", "hicolor", "scalable", "apps");
            mkdirRecurse(icons);
            write(buildPath(icons, "qwhats.svg"), import("app.svg"));
            const apps = buildPath(home(), ".local", "share", "applications");
            mkdirRecurse(apps);
            write(buildPath(apps, "qwhats.desktop"), desktopEntry(installTarget));
            refreshDesktopCaches(apps, buildPath(home(), ".local", "share", "icons", "hicolor"));
        } catch (Exception e) {
            installDone.emit(e.msg);
            return;
        }
        installDone.emit("");
        restartFrom = installTarget;
        restart();
    }

    /// Never ask again (the user said so).
    @Slot void declineInstall() { set("installDeclined", "true"); updateInstallAsk(); }
    /// Not now: hide the offer for this run.
    @Slot void laterInstall() { installAsk = false; settingsChanged.emit(); }

    /// The program a restart starts: this binary, or the AppImage it came from (its mount goes away
    /// with this process), or the freshly installed copy.
    string restartFrom;
    string restartExe() {
        import std.file : thisExePath;
        if (restartFrom.length) return restartFrom;
        const img = appImage();
        return img.length ? img : thisExePath;
    }

    static string desktopEntry(string exe) {
        return "[Desktop Entry]\nType=Application\nName=QWhats\nGenericName=WhatsApp\n"
             ~ "Comment=WhatsApp para Linux — chamadas, PDFs, notificações, várias contas\n"
             ~ "Exec=" ~ exe ~ " %U\nIcon=qwhats\nTerminal=false\nCategories=Network;InstantMessaging;Chat;\n"
             ~ "StartupWMClass=qwhats\nKeywords=whatsapp;chat;mensagens;\n";
    }

    private static void refreshDesktopCaches(string apps, string icons) {
        import std.process : spawnProcess, wait, Config;
        import std.stdio : File, stdin;
        auto devnull = File("/dev/null", "w");
        foreach (cmd; [["update-desktop-database", apps], ["gtk-update-icon-cache", "-f", "-t", icons]])
            try wait(spawnProcess(cmd, stdin, devnull, devnull, childEnv(), Config.newEnv));
            catch (Exception) {}
    }

    /// The UI's answer to a request: `resultJson`, or `error` (a message) when it failed.
    @Slot void rpcReply(int conn, string idJson, string resultJson, string error) {
        if (rpc is null) return;
        JSONValue id;
        try id = parseJSON(idJson.length ? idJson : "null");
        catch (JSONException) id = JSONValue(null);
        if (error.length) {
            import std.algorithm : startsWith;
            rpc.reply(conn, rpcError(id, error.startsWith("method not found") ? -32601 : -32000, error));
            return;
        }
        JSONValue r = ["jsonrpc": JSONValue("2.0")];
        r["id"] = id;
        try r["result"] = parseJSON(resultJson.length ? resultJson : "null");
        catch (JSONException) r["result"] = JSONValue(resultJson);
        rpc.reply(conn, r.toString());
    }

    /// Delete an account's profile (its login, its cache). Never the first account's.
    @Slot void removeProfile(string id) {
        import std.file : rmdirRecurse, exists;
        import std.regex : matchFirst;
        if (id == "main" || !matchFirst(id, `^[a-z0-9-]{1,40}$`)) return;
        foreach (dir; [buildPath(dataDir(), "profiles", id), buildPath(cacheDir(), "profiles", id)])
            try if (exists(dir)) rmdirRecurse(dir);
            catch (Exception) {}
    }

    private void updateTray() {
        import std.conv : to;
        tray.setIcon(buildPath(cacheDir(), "app", unread > 0 ? "app-unread.svg" : "app.svg"),
                     unread > 0 ? unread.to!string ~ (unread == 1 ? " conversa não lida" : " conversas não lidas") : "Nenhuma mensagem nova");
    }

    private void rebuildMenu() {
        if (tray is null) return;
        tray.setMenu([
            MenuEntry(1, "Abrir QWhats"),
            MenuEntry(2, "", true),
            MenuEntry(3, "Notificações", false, true, current["notifications"].boolean),
            MenuEntry(4, "Sons", false, true, current["sounds"].boolean),
            MenuEntry(5, "", true),
            MenuEntry(6, "Fechar QWhats"),
        ]);
    }

    /// The unread count (the window title's "(3)"): the tray icon gets its dot and tooltip.
    @Slot void setUnread(int n) {
        if (n == unread) return;
        unread = n;
        if (tray !is null) updateTray();
    }

    /// End this process and start a new one (a new theme reaches the page only at start).
    @Slot void restart() {
        restartRequested = true;
        quit();
    }

    /// Leave for good. exit(), not quit(): in Qt 6 quit() first asks every window to close and gives
    /// up if one refuses — and ours refuses on purpose (closing hides it in the tray), so "Fechar
    /// QWhats" only hid the window. exit() ends the event loop without asking.
    @Slot void quit() {
        import qt.quick.qcoreapplication : QCoreApplication;
        QCoreApplication.exit(0);
    }

    // from the tray
    void trayActivated() { trayClicks = trayClicks + 1; trayChanged.emit(); }
    void trayRegistered(bool ok) { if (ok != trayAvailable) { trayAvailable = ok; trayChanged.emit(); } }
    void trayMenu(int id) {
        if (id == 1) message("raise");
        else if (id == 3) set("notifications", current["notifications"].boolean ? "false" : "true");
        else if (id == 4) set("sounds", current["sounds"].boolean ? "false" : "true");
        else if (id == 6) quit();
    }

    private void updateDark() {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.colorscheme : ColorScheme;
        const t = current["theme"].str;
        const d = t == "dark" || (t != "light" && QGuiApplication.styleHints().colorScheme() != ColorScheme.Light);
        if (d == dark) return;
        dark = d;
        darkChanged.emit();
    }

    private void writeAppIcons() {
        import std.file : write, mkdirRecurse, exists, readText;
        const dir = buildPath(cacheDir(), "app");
        try {
            mkdirRecurse(dir);
            void put(string name, string svg) {
                const p = buildPath(dir, name);
                if (!exists(p) || readText(p) != svg) write(p, svg);
            }
            put("app.svg", import("app.svg"));
            put("app-unread.svg", import("app-unread.svg"));
            appIcon = fileUrl(buildPath(dir, "app.svg"));
            appIconUnread = fileUrl(buildPath(dir, "app-unread.svg"));
        } catch (Exception) {}
    }

    /// Change one setting (`valueJson`: its new value as JSON) and keep it.
    @Slot void set(string key, string valueJson) {
        if (!settings.apply(current, defs, key, valueJson)) return;
        try settings.save(settingsFile, current);
        catch (Exception e) {
            import std.stdio : stderr;
            stderr.writeln("qml-whats: settings not saved: ", e.msg);
        }
        settingsJson = current.toString();
        settingsChanged.emit();
        if (key == "theme") applyTheme();
        if (key == "notifications" || key == "sounds") rebuildMenu();
        if (key == "remoteControl") applyRemote();
    }

    /// Make sure the download folder exists (the profile writes into it).
    @Slot void ensureDir(string path) {
        import std.file : mkdirRecurse;
        try mkdirRecurse(path);
        catch (Exception) {}
    }

    /// Show a file in the file manager, selected (org.freedesktop.FileManager1), else open its folder.
    @Slot void reveal(string path) {
        import std.process : spawnProcess, Config;
        import std.path : dirName;
        import std.stdio : File, stdin;
        auto devnull = File("/dev/null", "w");
        try {
            spawnProcess(["dbus-send", "--session", "--dest=org.freedesktop.FileManager1", "--type=method_call",
                          "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
                          "array:string:" ~ fileUrl(path), "string:"], stdin, devnull, devnull, childEnv(), Config.detached | Config.newEnv);
        } catch (Exception) {
            try spawnProcess(["xdg-open", dirName(path)], stdin, devnull, devnull, childEnv(), Config.detached | Config.newEnv);
            catch (Exception) {}
        }
    }

    /// Open a URL (a web link, a file) with the system's handler — in a clean environment (childEnv),
    /// never Qt.openUrlExternally, whose xdg-open would inherit the AppImage's LD_LIBRARY_PATH.
    @Slot void openExternal(string url) {
        import std.process : spawnProcess, Config;
        import std.stdio : File, stdin;
        import std.algorithm : startsWith;
        if (!(url.startsWith("http://") || url.startsWith("https://") || url.startsWith("mailto:")
              || url.startsWith("tel:") || url.startsWith("file://"))) return;
        auto devnull = File("/dev/null", "w");
        try spawnProcess(["xdg-open", url], stdin, devnull, devnull, childEnv(), Config.detached | Config.newEnv);
        catch (Exception e) {
            import std.stdio : stderr;
            stderr.writeln("qml-whats: xdg-open failed: ", e.msg);
        }
    }

    /// Delete a downloaded file (the downloads panel's trash button).
    @Slot void removeFile(string path) {
        import std.file : remove, exists, isFile;
        try if (exists(path) && isFile(path)) remove(path);
        catch (Exception) {}
    }

    /// A message from another launch (qmlwhats.single).
    void message(string m) {
        if (m == "raise") {
            raiseCount = raiseCount + 1;
            raiseRequested.emit();
        }
    }
}

/// The tray's callbacks, into the backend (a DSide @QObject cannot itself implement a D interface).
final class TrayGlue : TrayControl {
    private App app;
    this(App a) { app = a; }
    void activate() { app.trayActivated(); }
    void secondary() { app.trayActivated(); }
    void menuClicked(int id) { app.trayMenu(id); }
    void registered(bool ok) { app.trayRegistered(ok); }
}
