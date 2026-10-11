// qml-whats: a WhatsApp client for Linux. The application is D (DSide), its UI solid-qml TSX (ui/)
// hosted by solid-qml-d, and WhatsApp itself is web.whatsapp.com in QtWebEngine with a persistent
// profile — the login survives restarts, calls get the camera and the microphone, documents open
// on their own (PDFs inside the app), notifications are the desktop's.
import solidqml.host;
import cppq = qt.quick.qobject;   // the C++ QObject, renamed: `@QObject` is qtmoc's UDA
import qt.quick.qtimer : QTimer;
import qtmoc : newQObject, qobjOf;
import qmlwhats.backend : App;
import qmlwhats.single : SingleInstance;
import qmlwhats.env;
import std.getopt;
import std.stdio : stderr;
import std.path : buildPath, dirName;
import std.file : thisExePath;

private QTimer pollTimer;

/// `qwhats --rpc METHOD [--params JSON]`: one request to the running app (Settings › Controle remoto
/// must be on), its answer on stdout. Exit 1 when the app cannot be reached.
int rpcClient(string method, string params) {
    import std.socket;
    import std.json;
    import std.stdio : writeln, stderr;
    try {
        auto c = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        scope (exit) c.close();
        c.connect(new UnixAddress(rpcSocketPath()));
        JSONValue req = ["jsonrpc": JSONValue("2.0"), "id": JSONValue(1), "method": JSONValue(method)];
        req["params"] = parseJSON(params);
        c.send(req.toString() ~ "\n");
        char[] got;
        char[65536] buf;
        for (;;) {
            const n = c.receive(buf[]);
            if (n <= 0) break;
            got ~= buf[0 .. n];
            if (got.length && got[$ - 1] == '\n') break;
        }
        writeln(got.length ? got[0 .. $ - 1] : "");
        return 0;
    } catch (Exception e) {
        stderr.writeln("qwhats: remote control not reachable (", rpcSocketPath(), "): ", e.msg,
                       " — is QWhats running with Configurações › Controle remoto on?");
        return 1;
    }
}   // held here: an unparented timer whose wrapper is collected never fires

int main(string[] args) {
    SolidQmlOptions o;
    o.appName = "qwhats";   // X11 WM_CLASS and the app name: matches Wayland's app_id (qwhats.desktop)
    string ui = buildPath(dirName(thisExePath), "qml");   // the UI next to the binary
    string url;          // --url: load this instead of web.whatsapp.com (tests)
    bool hidden;         // --hidden: start in the tray
    bool multi;          // --new-instance: do not hand over to a running window (tests)
    bool software;       // --software: no GPU (offscreen probes)
    string evalFile;     // --eval FILE: run this JavaScript in the page once loaded (development)
    string rpcMethod;    // --rpc METHOD [--params JSON]: call the running app's remote control, print the answer
    string rpcParams = "{}";
    getopt(args, "ui", &ui, "width", &o.width, "height", &o.height, "grab", &o.grab, "grab-ms", &o.grabMs,
           "url", &url, "hidden", &hidden, "new-instance", &multi, "software", &software, "eval", &evalFile, "rpc", &rpcMethod, "params", &rpcParams);
    if (rpcMethod.length) return rpcClient(rpcMethod, rpcParams);

    auto single = new SingleInstance;
    if (!multi && !o.grab.length && !single.claim("raise")) return 0;   // the running window comes up instead

    chromiumFlags(software || o.grab.length > 0);
    auto dicts = prepareDictionaries();   // before Qt: Chromium reads the path once

    o.qml = ui ~ "/Main.qml";   // plain Qt Quick (ui/qml/); no stylesheet


    auto app = newQObject!App();
    const code = runSolidQml(o, (engine, ctx) {
        // Wayland's app_id / X11's class: the launcher (qwhats.desktop) and its icon match the window.
        import qt.quick.qguiapplication : QGuiApplication;
        QGuiApplication.setDesktopFileName("qwhats");
        QGuiApplication.setApplicationDisplayName("QWhats");
        app.oneShot = o.grab.length > 0;
        app.setUp(dicts, url, hidden, evalFile);
        ctx.setContextProperty("app", cppq.QObject.wrap(qobjOf(app)));
        pollTimer = new QTimer();
        int tick;
        pollTimer.connectTimeout(() {
            app.pump();                                         // the tray's bus, every 50 ms
            if (++tick % 6 == 0) foreach (m; single.poll()) app.message(m);
        });
        pollTimer.start(50);
    });
    stderr.writeln("qml-whats: event loop ended (", code, ")");
    if (app.restartRequested) {
        // a new process (a new theme reaches Chromium only at start): the name is given up first
        import std.process : spawnProcess, Config;
        import std.file : thisExePath;
        single.close();
        try spawnProcess([app.restartExe()] ~ args[1 .. $], childEnv(), Config.detached | Config.newEnv);
        catch (Exception e) {
            import std.stdio : stderr;
            stderr.writeln("qml-whats: restart failed: ", e.msg);
        }
    }
    // Out without the D runtime's and Qt's teardown: QtWebEngine's shutdown from a D finalizer can
    // hang the process after the window is gone — a ghost that still holds the single-instance
    // name, so the next launch "raises" a window that no longer exists. The profile is on disk
    // already (Chromium writes as it goes), the settings file is written on every change.
    import core.sys.posix.unistd : _exit;
    import std.stdio : stdout;
    stdout.flush();
    stderr.flush();
    _exit(code);
    assert(0);
}
