// SPDX-License-Identifier: BSL-1.0
//
// THE solid-qml HOST, IN D. A D application owns `main`; its UI is solid-qml TSX transpiled to a
// Window document. solid-qml's own embedding API (SolidQmlEmbed, exported by libsolidqml) does
// the arming — CSS engine + widget types, browser/Node shims, the engine-scoped theme and layout
// services — and this module drives it through the DSide binding (spec/solidqml.json), where Qt
// Quick and SolidQmlEmbed are generated together: the `QQmlEngine` handed to `init` is the same D
// type `QQmlApplicationEngine` derives from.
module solidqml.host;

import qt.quick.qguiapplication, qt.quick.qcoreapplication, qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext, qt.quick.qquickwindow, qt.quick.qsurfaceformat, qt.quick.qtimer;
import qt.quick.qurl, qt.quick.qstring, qt.quick.applicationattribute;
import sqe = qt.quick.functions;   // SolidQmlEmbed::init / loadCss / attachWindow
import cxxrt;
import std.stdio : stderr, writeln;

mixin(qtdApplication!"QGuiApplication");

/// What to load and how. Paths are filesystem paths: generated QML is loaded from disk.
struct SolidQmlOptions {
    string appName = "solid-qml";
    string qml;              /// the generated root (App.generated.qml) — its root must be a Window
    string css;              /// the ONE stylesheet (solidQmlUi writes app.css: base + generated)
    string[] importPaths;    /// extra QML import roots (e.g. solid-qml's qml/ for opt-in widgets)
    string capabilities = "desktop";   /// node-shim profile: "browser" | "desktop" | "trusted"
    int width = -1;          /// override the Window's width
    int height = -1;
    string grab;             /// render one frame to this PNG and exit (QT_QPA_PLATFORM=offscreen)
    int grabMs = 1200;       /// how long the scene settles before the grab (relayout is deferred)
}

/// Run a solid-qml document. `setup` runs after the engine is armed and BEFORE the document
/// loads — the place to publish D backends (`ctx.setContextProperty("mail", …)`).
/// Returns the process exit code.
int runSolidQml(SolidQmlOptions o, void delegate(QQmlApplicationEngine, QQmlContext) setup = null) {
    // QtWebEngine's one pre-app requirement for QML use (the C++ loader sets it unconditionally
    // too): shared GL contexts, so a <WebView> / WebEngineView can compose. Dependency-free.
    QCoreApplication.setAttribute(ApplicationAttribute.AA_ShareOpenGLContexts, true);
    cast(void) createApp(o.appName);

    // Translucent windows composite correctly only with an alpha channel (as the C++ loader asks).
    auto fmt = QSurfaceFormat.defaultFormat();
    fmt.setAlphaBufferSize(8);
    QSurfaceFormat.setDefaultFormat(fmt);

    auto engine = new QQmlApplicationEngine();
    foreach (p; o.importPaths) engine.addImportPath(p);
    {
        auto none = QUrl.__make();   // appDir: default (the application's directory)
        auto caps = QString(o.capabilities);
        sqe.init(engine, none, caps);
    }
    if (o.css.length) {
        auto css = QUrl.fromLocalFile(o.css);
        sqe.loadCss(engine, css);
    }
    if (setup !is null) setup(engine, engine.rootContext());

    auto url = QUrl.fromLocalFile(o.qml);
    engine.load(url);
    auto roots = engine.rootObjects();
    if (roots.length == 0) {
        stderr.writeln("solid-qml: no root object loaded from ", o.qml);
        return 1;
    }
    // rootObjects() hands the Window back as a QObject; the holder promotes that view.
    auto window = QQuickWindow.wrap(roots[$ - 1].ptr());
    if (window is null) {
        stderr.writeln("solid-qml: the root object of ", o.qml, " is not a Window");
        return 1;
    }
    if (o.width > 0) window.setWidth(o.width);
    if (o.height > 0) window.setHeight(o.height);
    sqe.attachWindow(engine, window);   // `@media`/`vw`/`vh` track the window, live on resize

    if (o.grab.length) {
        // Let the scene settle (CSS load + relayout are deferred via Qt.callLater), grab, quit.
        auto timer = new QTimer();
        timer.setSingleShot(true);
        timer.connectTimeout(() {
            auto frame = window.grabWindow();
            if (frame.save(o.grab, null, -1)) writeln("solid-qml: wrote ", o.grab);
            else stderr.writeln("solid-qml: failed to write ", o.grab);
            QCoreApplication.quit();
        });
        timer.start(o.grabMs);
    }
    return QCoreApplication.exec();
}
