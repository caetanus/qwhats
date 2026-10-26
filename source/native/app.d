// QWhats native (docs/native-client.md): WhatsApp without Chromium. The UI is solid-qml TSX
// (ui/native/) hosted by solid-qml-d; WhatsApp itself is qwhats-core (Go + whatsmeow) as a child
// process, relayed by `core` (CoreBridge). `app` is the same backend as the WebEngine client
// (icons, tray, settings, theme).
import solidqml.host;
import cppq = qt.quick.qobject;
import qt.quick.qtimer : QTimer;
import qtmoc : newQObject, qobjOf;
import qmlwhats.backend : App;
import qmlwhats.native.corebridge : CoreBridge;
import qmlwhats.native.look : Look;
import qmlwhats.env;
import std.getopt;
import std.path : buildPath, dirName;
import std.file : thisExePath, exists, mkdirRecurse;
import std.stdio : stderr;

private QTimer pumpTimer;

int main(string[] args) {
    // File choosers through xdg-desktop-portal (the desktop's own dialog, sandbox-friendly): Qt only
    // asks the portal under this platform theme. The desktop's own setting (often qt5ct, which has no
    // Qt 6 plugin) would leave Qt's built-in dialog.
    import std.process : environment;
    environment["QT_QPA_PLATFORMTHEME"] = "xdgdesktopportal";
    SolidQmlOptions o;
    o.appName = "qwhats";
    const here = dirName(thisExePath);
    string ui = buildPath(here, "qml-native");
    // the D core beside the binary (the AppImage ships it), else the Go core
    string coreExe = buildPath(here, "qwhats-dcore");
    if (!exists(coreExe)) coreExe = buildPath(here, "qwhats-core");
    if (!exists(coreExe)) coreExe = buildPath(here, "build-core", "qwhats-core");   // the build tree
    string data = buildPath(dataDir(), "native");
    string cache = buildPath(cacheDir(), "native");
    string art = buildPath(here, "assets", "wa");   // WhatsApp's artwork: tools/wa-icons.mjs (not in git)
    bool demo;   // --demo: the core's fake account (made-up chats, no network) — UI work and screenshots
    getopt(args, "ui", &ui, "core", &coreExe, "data", &data, "cache", &cache, "art", &art,
           "width", &o.width, "height", &o.height, "grab", &o.grab, "grab-ms", &o.grabMs, "demo", &demo);
    // a whatsapp:// link (the .desktop registers x-scheme-handler/whatsapp, passing it as %u)
    string url;
    foreach (a; args[1 .. $]) if (a.length > 9 && a[0 .. 9] == "whatsapp:") url = a;
    // one native window per user: a second launch hands its link (or a raise) to the first and exits
    import qmlwhats.single : SingleInstance;
    auto single = new SingleInstance("qwhats-native");
    if (!o.grab.length && !demo && !single.claim(url.length ? "open " ~ url : "raise")) return 0;
    mkdirRecurse(data);
    mkdirRecurse(cache);
    o.qml = ui ~ "/App.generated.qml";
    o.css = ui ~ "/app.css";
    o.importPaths = [ui ~ "/imports"];

    auto app = newQObject!App();
    auto core = newQObject!CoreBridge();
    auto look = newQObject!Look();
    // a second launch ("raise"): the window comes back — shown, on top, focused
    void delegate() raiseWindow = () {};
    const code = runSolidQml(o, (engine, ctx) {
        raiseWindow = () {
            import qt.quick.qquickwindow : QQuickWindow;
            auto roots = engine.rootObjects();
            if (roots.length == 0) return;
            auto w = QQuickWindow.wrap(roots[$ - 1].ptr());
            if (w is null) return;
            w.showNormal();
            w.raise();
            w.requestActivate();
        };
        import qt.quick.qguiapplication : QGuiApplication;
        QGuiApplication.setDesktopFileName("qwhats-native");
        QGuiApplication.setApplicationDisplayName("QWhats");
        app.oneShot = o.grab.length > 0;
        app.setUp([], "", false);
        ctx.setContextProperty("app", cppq.QObject.wrap(qobjOf(app)));
        ctx.setContextProperty("core", cppq.QObject.wrap(qobjOf(core)));
        look.setUp(art, cache);
        ctx.setContextProperty("look", cppq.QObject.wrap(qobjOf(look)));
        core.start(coreExe, data, cache, demo ? ["--demo"] : null);
        import std.json : JSONValue;
        if (url.length) core.inject("App:openUrl", JSONValue(["url": JSONValue(url)]));
        pumpTimer = new QTimer();
        uint tick;
        pumpTimer.connectTimeout(() {
            if (++tick % 6 == 0)
                foreach (m; single.poll()) {
                    if (m.length > 5 && m[0 .. 5] == "open ")
                        core.inject("App:openUrl", JSONValue(["url": JSONValue(m[5 .. $])]));
                    else if (m == "raise") {
                        core.inject("App:raise", JSONValue.emptyObject);
                        raiseWindow();
                    }
                }
            core.pump();
            app.pump();
        });
        pumpTimer.start(30);
    });
    stderr.writeln("qwhats-native: event loop ended (", code, ")");
    single.close();
    core.stop();
    import core.sys.posix.unistd : _exit;
    import std.stdio : stdout;
    stdout.flush();
    stderr.flush();
    _exit(code);
    assert(0);
}
