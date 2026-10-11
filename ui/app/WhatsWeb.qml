// WhatsWeb — web.whatsapp.com in QtWebEngine, with everything a desktop client needs that a bare
// WebEngineView does not do. solid-qml escape hatch: the TSX sets the properties and gets the
// signals; it calls the functions through `ref`.
//
//  - PERSISTENT profile (WebEngineProfilePrototype, Qt 6.9+): cookies + IndexedDB on disk, so the
//    QR login survives restarts. Permissions are kept on disk too.
//  - User agent without the "QtWebEngine/x" token: WhatsApp refuses browsers it does not know
//    ("WhatsApp works with Google Chrome…"); the rest of the string is Chromium's own, so the
//    version it advertises is the engine's real one.
//  - Calls: camera and microphone are granted to WhatsApp's own origin (setting autoGrantMedia),
//    anything else is asked through `permissionAsk`. Screen sharing goes through
//    `desktopMediaRequested` → `screenPick` (on Wayland Chromium's PipeWire capturer hands the
//    choice to the desktop portal).
//  - Notifications: the page's `new Notification(…)` arrives in profile.presentNotification and
//    leaves as `notify(key, …)`; the TSX shows it on the desktop and answers with
//    clickNotification(key) / replyNotification(key, text).
//  - Downloads go to `downloadDir` (Chromium makes the name unique there) and are reported as
//    `downloadEvent(json)`: start, progress (≤ 4/s per file), done.
//  - Links leave for the system browser; a popup WhatsApp opens for itself (a call window) gets a
//    window of ours on the same profile.
import QtQuick
import QtQuick.Window
import QtWebEngine

Item {
    id: root
    property string profilePath: ""
    property string cachePath: ""
    property string startUrl: "https://web.whatsapp.com/"
    property string downloadDir: ""
    property real zoom: 1.0
    property bool autoGrantMedia: true
    property bool spellcheck: true
    property var spellLangs: []
    property int idleReloadMinutes: 30   // reload after this long without input (0: never)
    property bool busy: false            // the TSX has a download running: no reload now
    // Sounds off: WhatsApp's sounds (a message's ding, the ringtone) are muted — but never a call
    // in progress: the page counts its own live microphone/camera tracks (__qwLive, from the
    // profile script below) and a call is heard whatever this says.
    property bool sounds: true
    property bool inCall: false
    readonly property bool muted: !sounds && !inCall

    signal unreadCount(int n)
    signal notify(int key, string title, string body)
    signal notifyClosed(int key)
    signal downloadEvent(string json)
    signal permissionAsk(string json)
    signal screenPick(string json)
    signal loadState(string json)
    signal fullScreen(bool on)
    signal linkHover(string url)
    signal pageTheme(bool dark)
    signal idleReloaded()
    signal documentChanged(string json)   // {open, name, path}: the document pane beside the chat

    implicitWidth: 800
    implicitHeight: 600

    // ---- the profile --------------------------------------------------------------------------
    WebEngineProfilePrototype {
        id: proto
        storageName: "qml-whats"
        persistentStoragePath: root.profilePath
        cachePath: root.cachePath
        httpCacheType: WebEngineProfile.DiskHttpCache
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        persistentPermissionsPolicy: WebEngineProfile.PersistentPermissionsPolicy.StoreOnDisk
    }
    property var profile: null

    function setUpProfile() {
        var p = proto.instance();
        // "… QtWebEngine/6.11.2 Chrome/140.0.… Safari/537.36" → the same without the QtWebEngine token
        p.httpUserAgent = p.httpUserAgent.replace(/\s*QtWebEngine\/\S+/, "");
        // ...and the same in the Client Hints (navigator.userAgentData, Sec-CH-UA): Chromium-based
        // QtWebEngine announces only "Chromium", and WhatsApp keeps calls to the browsers it names —
        // "Google Chrome" is added, with the engine's real version, as Chrome itself sends it.
        try {
            var ch = p.clientHints;
            var list = ch.fullVersionList || {};
            var full = list["Chromium"] || ch.fullVersion || "";
            if (full !== "") {
                ch.fullVersionList = { "Google Chrome": full, "Chromium": full, "Not=A?Brand": "24.0.0.0" };
                ch.fullVersion = full;
            }
        } catch (e) {
            console.warn("qml-whats: client hints not set:", e);
        }
        var langs = Qt.locale().uiLanguages.slice(0, 3);
        if (langs.indexOf("en-US") < 0) langs.push("en-US");
        p.httpAcceptLanguage = langs.join(",");
        p.downloadPath = root.downloadDir;
        p.presentNotification.connect(root.present);
        // In every page of the profile (calls open their own windows), from the first script on:
        // how many microphone/camera tracks are live — a call is going on when any is.
        try {
            var sc = WebEngine.script();
            sc.name = "qwhats-live-media";
            sc.injectionPoint = WebEngineScript.DocumentCreation;
            sc.worldId = WebEngineScript.MainWorld;   // it wraps the page's own getUserMedia
            sc.runsOnSubFrames = true;
            sc.sourceCode = "(function(){if(window.__qwLive!==undefined)return;window.__qwLive=0;"
                + "var md=navigator.mediaDevices;if(!md||!md.getUserMedia)return;var gum=md.getUserMedia.bind(md);"
                + "md.getUserMedia=function(c){return gum(c).then(function(st){st.getTracks().forEach(function(t){"
                + "window.__qwLive++;var done=false;function end(){if(!done){done=true;window.__qwLive--;}}"
                + "t.addEventListener('ended',end);var stop=t.stop.bind(t);t.stop=function(){end();stop();};});return st;});};})();";
            p.userScripts.insert(sc);
        } catch (e) {
            console.warn("qml-whats: live-media script not installed:", e);   // only "Sons" loses its call guard
        }
        p.downloadRequested.connect(root.downloadStarted);
        root.profile = p;
        root.applySpell();
    }
    function applySpell() {
        if (!profile) return;
        var langs = [];
        var src = spellLangs || [];
        for (var i = 0; i < src.length; ++i) langs.push(src[i]);
        profile.spellCheckLanguages = langs;
        profile.spellCheckEnabled = spellcheck && langs.length > 0;
    }
    onSpellcheckChanged: applySpell()
    onSpellLangsChanged: applySpell()
    onDownloadDirChanged: if (profile) profile.downloadPath = downloadDir

    // The view is BORN with the profile (a page created on the default profile keeps it), so it is
    // made here, once the profile exists, and only then given its URL.
    property var view: null
    property var docView: null
    Component.onCompleted: {
        setUpProfile();
        view = viewComponent.createObject(root, { profile: root.profile });
        docView = docViewComponent.createObject(docBody, { profile: root.profile });
        view.url = root.startUrl;
    }

    // ---- the view -----------------------------------------------------------------------------
    Component {
      id: viewComponent
      WebEngineView {
        id: view
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; right: docPane.left }
        zoomFactor: root.zoom
        audioMuted: root.muted
        settings.pluginsEnabled: true                     // Chromium's PDF viewer is a plugin: off, a PDF only downloads
        backgroundColor: "#111b21"
        settings.javascriptCanAccessClipboard: true
        settings.javascriptCanPaste: true
        settings.playbackRequiresUserGesture: false      // the ringtone of an incoming call
        settings.fullScreenSupportEnabled: true           // a video, a video call
        settings.screenCaptureEnabled: true               // sharing the screen in a call
        settings.pdfViewerEnabled: true
        settings.focusOnNavigationEnabled: true
        settings.webRTCPublicInterfacesOnly: false

        onTitleChanged: {
            console.info("qml-whats: title", title);
            var m = /^\((\d+)\)/.exec(title);
            root.unreadCount(m ? parseInt(m[1]) : 0);
        }
        onLoadingChanged: (info) => {
            if (info.status !== WebEngineView.LoadStartedStatus)
                console.info("qml-whats: load", info.status === WebEngineView.LoadSucceededStatus ? "ok" : "failed (" + info.errorString + ")", info.url);
            // Keyboard focus to the page once it is there: Ctrl+V (a screenshot) and typing go to
            // WhatsApp without a click first.
            if (info.status === WebEngineView.LoadSucceededStatus) view.forceActiveFocus();
            // --eval FILE (development): the script's result, logged
            if (info.status === WebEngineView.LoadSucceededStatus && typeof app !== "undefined" && app.evalScript !== "")
                view.runJavaScript(app.evalScript, function (r) { console.info("EVAL", typeof r === "string" ? r : JSON.stringify(r)); });
            root.loadState(JSON.stringify({ loading: view.loading, progress: view.loadProgress,
            error: info.status === WebEngineView.LoadFailedStatus ? info.errorString : "" }));
        }
        onLoadProgressChanged: root.loadState(JSON.stringify({ loading: view.loading, progress: view.loadProgress, error: "" }))
        onLinkHovered: (url) => root.linkHover(url.toString())
        // The page's console stays quiet except errors (and the diagnostic page's DIAG lines).
        onJavaScriptConsoleMessage: (level, message, line, source) => {
            if (message.indexOf("DIAG") === 0 || level === WebEngineView.ErrorMessageLevel)
                console.info("js:", message.substring(0, 300));
        }

        // The renderer died (OOM, GPU reset): back in a second instead of a dead grey page.
        onRenderProcessTerminated: (status, code) => { console.warn("qml-whats: renderer ended", status, code); revive.start(); }

        onPermissionRequested: (permission) => root.decide(permission)
        onDesktopMediaRequested: (request) => root.askScreen(request)
        onFullScreenRequested: (request) => { request.accept(); root.fullScreen(request.toggleOn); }

        onNewWindowRequested: (request) => root.newWindow(request)
        onNavigationRequested: (request) => {
            var u = request.url.toString();
            if (!request.isMainFrame || root.trusted(u) || /^(blob|data|about|file):/i.test(u)) return;
            // a link clicked in a message, never followed inside the app
            request.reject();
            if (/^(https?|mailto|tel):/i.test(u)) Qt.openUrlExternally(request.url);
        }
      }
    }
    // WhatsApp's own theme (body.dark), so the app's rail matches the page beside it.
    property int dark: -1
    Timer {
        interval: 1500
        running: root.view !== null
        repeat: true
        onTriggered: root.view.runJavaScript("!!(document.body && document.body.classList.contains('dark'))", function (r) {
            var d = r ? 1 : 0;
            if (d !== root.dark) { root.dark = d; root.pageTheme(!!r); }
        })
    }
    // Is a call going on? (the main page or a call window has live capture tracks)
    Timer {
        interval: 1000
        repeat: true
        running: root.view !== null && !root.sounds
        onTriggered: {
            var views = [root.view];
            for (var i = 0; i < root.windows.length; ++i) if (root.windows[i].view) views.push(root.windows[i].view);
            var live = 0, pending = views.length;
            views.forEach(function (v) {
                v.runJavaScript("window.__qwLive|0", function (n) {
                    live += (n | 0);
                    if (--pending === 0) root.inCall = live > 0;
                });
            });
        }
    }

    // ---- the idle reload --------------------------------------------------------------------
    // WhatsApp Web left open for hours goes stale (messages late, the socket half-dead, memory
    // up). After `idleReloadMinutes` without a key, click, wheel or mouse move in the page, it is
    // reloaded — never during a call (audio playing, a call window open), never over a draft in
    // the composer, never while something downloads or loads. The page itself keeps the input
    // clock (a listener installed by the first poll and after every load); a clock jump after a
    // suspend counts as idle time, which is right: that is when the page is most stale.
    property int popups: 0
    property double lastReload: Date.now()
    Timer {
        interval: 60000
        repeat: true
        running: root.view !== null && root.idleReloadMinutes > 0
        onTriggered: root.view.runJavaScript(root.idleScript, function (ms) { root.checkIdle(ms) })
    }
    readonly property string idleScript: "(function(){"
        + "if(!window.__qwIdle){window.__qwIdle=Date.now();"
        + "['keydown','mousedown','mousemove','wheel','touchstart'].forEach(function(e){document.addEventListener(e,function(){window.__qwIdle=Date.now()},true)});}"
        + "var b=document.querySelector('#main footer div[contenteditable=\"true\"]');"
        + "if(b&&b.innerText.trim().length)return -1;"
        + "return Date.now()-window.__qwIdle;})()"
    function checkIdle(ms) {
        var limit = idleReloadMinutes * 60000;
        if (typeof ms !== "number" || ms < limit || limit <= 0) return;
        if (busy || popups > 0 || view.recentlyAudible || view.loading) return;
        if (Date.now() - lastReload < limit) return;
        lastReload = Date.now();
        console.log("qml-whats: idle for", Math.round(ms / 60000), "min — reloading WhatsApp");
        view.reload();
        root.idleReloaded();
    }
    Timer { id: revive; interval: 1000; onTriggered: root.view.reload() }

    // A window the page opens: WhatsApp's own (a call, about:blank it then fills) and a document it
    // opens as blob:/data: (a PDF clicked in a chat: Chromium's viewer shows it) get a window of ours
    // on the same profile — a blob: URL resolves only there; a web link goes to the system browser.
    function newWindow(request) {
        var u = request.requestedUrl.toString();
        console.info("qml-whats: new window", request.destination, u.substring(0, 120));
        if (/^(blob|data):/i.test(u) && docView) {
            // a document clicked in a chat (WhatsApp opens it as blob:): beside the chat
            docView.acceptAsNewWindow(request);
            showDocument("Documento", "", u);
            return;
        }
        if (trusted(u) || u === "" || u === "about:blank") {
            var w = popupComponent.createObject(null, { profile: root.profile });
            windows.push(w);   // JS-owned and parentless: without a reference the GC takes the window
            root.popups++;
            w.view.acceptAsNewWindow(request);
            w.show();
            w.raise();
            w.requestActivate();
        } else if (/^(https?|mailto|tel):/i.test(u)) {
            Qt.openUrlExternally(request.requestedUrl);
        }
    }
    property var windows: []
    function forget(w) {
        var i = windows.indexOf(w);
        if (i >= 0) windows.splice(i, 1);
    }

    // WhatsApp's own pages, and the origin of a --url given for tests.
    function trusted(u) { return isWhatsApp(u) || (originOf(u) !== "" && originOf(u) === originOf(startUrl)); }
    function originOf(u) {
        var m = /^(https?:\/\/[^\/]+)/i.exec(u);
        return m ? m[1].toLowerCase() : "";
    }
    function isWhatsApp(u) { return /^https:\/\/([a-z0-9-]+\.)*(whatsapp\.com|whatsapp\.net)(\/|$)/i.test(u); }

    // ---- permissions --------------------------------------------------------------------------
    property var pending: null   // the one permission waiting for the user
    function decide(permission) {
        var T = WebEnginePermission.PermissionType;
        var t = permission.permissionType;
        var ours = trusted(permission.origin.toString());
        console.info("qml-whats: permission", t, permission.origin, ours ? "(trusted)" : "");
        if (ours && (t === T.Notifications || t === T.ClipboardReadWrite)) { permission.grant(); return; }
        if (ours && autoGrantMedia && (t === T.MediaAudioCapture || t === T.MediaVideoCapture || t === T.MediaAudioVideoCapture
                                       || t === T.DesktopVideoCapture || t === T.DesktopAudioVideoCapture)) { permission.grant(); return; }
        if (t === T.Unsupported || t === T.Geolocation || t === T.MouseLock || t === T.LocalFontsAccess) { permission.deny(); return; }
        if (pending) pending.deny();
        pending = permission;
        var kind = t === T.MediaAudioCapture ? "mic" : t === T.MediaVideoCapture ? "camera" : t === T.MediaAudioVideoCapture ? "camera+mic"
                 : t === T.DesktopVideoCapture || t === T.DesktopAudioVideoCapture ? "screen" : "other";
        root.permissionAsk(JSON.stringify({ kind: kind, origin: permission.origin.toString() }));
    }
    function answerPermission(grant) {
        if (!pending) return;
        if (grant) pending.grant(); else pending.deny();
        pending = null;
    }

    // ---- screen sharing -----------------------------------------------------------------------
    property var screenRequest: null
    function namesOf(model) {
        var out = [];
        if (!model) return out;
        for (var i = 0; i < model.rowCount(); ++i) out.push("" + model.data(model.index(i, 0), Qt.DisplayRole));
        return out;
    }
    function askScreen(request) {
        console.info("qml-whats: screen share asked");
        if (screenRequest) screenRequest.cancel();
        screenRequest = request;
        root.screenPick(JSON.stringify({ screens: namesOf(request.screensModel), windows: namesOf(request.windowsModel) }));
    }
    function pickScreen(kind, index) {
        var r = screenRequest;
        screenRequest = null;
        if (!r) return;
        if (kind === "screen") r.selectScreen(r.screensModel.index(index, 0));
        else if (kind === "window") r.selectWindow(r.windowsModel.index(index, 0));
        else r.cancel();
    }

    // ---- notifications ------------------------------------------------------------------------
    property var notes: ({})
    property int nextNote: 1
    function present(n) {
        var key = nextNote++;
        notes[key] = n;          // keeps the object alive (and reachable for click/close)
        n.closed.connect(function () { if (notes[key]) { delete notes[key]; root.notifyClosed(key); } });
        n.show();
        root.notify(key, n.title, n.message);
    }
    // The desktop notification was clicked: the page opens that chat.
    function clickNotification(key) {
        var n = notes[key];
        if (n) n.click();
    }
    function dropNotification(key) {
        var n = notes[key];
        if (!n) return;
        delete notes[key];
        n.close();
    }
    // An inline reply: open the chat, then type into its composer and send.
    property string replyText: ""
    function replyNotification(key, text) {
        clickNotification(key);
        replyText = text;
        typeReply.restart();
    }
    Timer {
        id: typeReply
        interval: 700   // the chat opens
        onTriggered: root.view.runJavaScript(root.sendScript(root.replyText))
    }
    function sendScript(text) {
        return "(function(t){"
            + "var box=document.querySelector('#main footer div[contenteditable=\"true\"]')||document.querySelector('footer div[contenteditable=\"true\"]');"
            + "if(!box)return false;box.focus();document.execCommand('insertText',false,t);"
            + "setTimeout(function(){var i=document.querySelector('#main footer span[data-icon=\"send\"],#main footer span[data-icon=\"wds-ic-send-filled\"]');"
            + "var b=i?i.closest('button'):document.querySelector('#main footer button[aria-label=\"Send\"],#main footer button[aria-label=\"Enviar\"]');"
            + "if(b)b.click();else box.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));},200);"
            + "return true;})(" + JSON.stringify(text) + ")";
    }

    // ---- downloads ----------------------------------------------------------------------------
    property var downloads: ({})
    function report(d, type) {
        root.downloadEvent(JSON.stringify({
            type: type, id: d.id, name: d.downloadFileName, dir: d.downloadDirectory,
            path: d.downloadDirectory + "/" + d.downloadFileName, mime: d.mimeType,
            received: d.receivedBytes, total: d.totalBytes,
            state: d.state === WebEngineDownloadRequest.DownloadCompleted ? "done"
                 : d.state === WebEngineDownloadRequest.DownloadCancelled ? "cancelled"
                 : d.state === WebEngineDownloadRequest.DownloadInterrupted ? "failed" : "running",
            error: d.state === WebEngineDownloadRequest.DownloadInterrupted ? d.interruptReasonString : ""
        }));
    }
    function downloadStarted(d) {
        console.info("qml-whats: download", d.mimeType, d.downloadFileName, d.url.toString().substring(0, 80));
        // The pane was given something it cannot show (a .docx as blob:): it became this download.
        if (docOpen && docPath === "" && d.url.toString() === docSource) closeDocument();
        if (d.isSavePageDownload) { d.cancel(); return; }
        if (root.downloadDir !== "") d.downloadDirectory = root.downloadDir;
        d.accept();
        downloads[d.id] = d;
        var last = 0;
        d.receivedBytesChanged.connect(function () {
            var now = Date.now();
            if (now - last < 250) return;
            last = now;
            root.report(d, "progress");
        });
        d.isFinishedChanged.connect(function () {
            if (!d.isFinished) return;
            root.report(d, "done");
            delete downloads[d.id];
        });
        report(d, "start");
    }
    function cancelDownload(id) {
        var d = downloads[id];
        if (d) d.cancel();
    }

    // ---- the document pane ------------------------------------------------------------------
    // A PDF opens BESIDE the chat, in Chromium's viewer, on WhatsApp's own profile (a blob: URL the
    // page made resolves only there). From WhatsApp (blob:) or from the downloads panel (file:).
    property bool docOpen: false
    property bool docWide: false
    property string docName: ""
    property string docPath: ""      // the local file, "" for one WhatsApp handed over as blob:
    property string docSource: ""
    function showDocument(name, path, source) {
        docName = name;
        docPath = path;
        docSource = source;
        docOpen = true;
        documentChanged(JSON.stringify({ open: true, name: name, path: path }));
    }
    function openDocument(url, name, path) {
        if (!docView) return;
        docView.url = url;
        showDocument(name, path, url);
    }
    function closeDocument() {
        docOpen = false;
        docWide = false;
        if (docView) docView.url = "about:blank";
        documentChanged(JSON.stringify({ open: false, name: "", path: "" }));
    }
    function icon(name, variant) { return typeof app !== "undefined" ? app.iconBase + "/" + variant + "/" + name + ".svg" : ""; }

    Rectangle {
        id: docPane
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        width: root.docOpen ? Math.round(root.width * (root.docWide ? 0.72 : 0.48)) : 0
        visible: root.docOpen
        color: "#111b21"
        Rectangle { width: 1; anchors { left: parent.left; top: parent.top; bottom: parent.bottom } color: "#2a3942"; z: 2 }
        Rectangle {
            id: docBar
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 52
            color: "#202c33"
            Row {
                anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                spacing: 10
                Image { source: root.icon("file-text", "accent"); width: 20; height: 20; sourceSize: Qt.size(40, 40); anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: root.docName
                    color: "#e9edef"
                    font.pixelSize: 14
                    elide: Text.ElideMiddle
                    width: docBar.width - 16 - 30 - tools.width - 24
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Row {
                id: tools
                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 2
                DocButton { name: "external-link"; tip: "Abrir no aplicativo padrão"; shown: root.docPath !== ""; onClicked: Qt.openUrlExternally(root.docSource) }
                DocButton { name: "folder-open"; tip: "Mostrar na pasta"; shown: root.docPath !== ""; onClicked: app.reveal(root.docPath) }
                DocButton { name: "maximize-2"; tip: "Ampliar"; on: root.docWide; onClicked: root.docWide = !root.docWide }
                DocButton { name: "x"; tip: "Fechar documento"; onClicked: root.closeDocument() }
            }
        }
        Item {
            id: docBody
            anchors { left: parent.left; leftMargin: 1; right: parent.right; top: docBar.bottom; bottom: parent.bottom }
        }
    }
    component DocButton: Rectangle {
        id: b
        property string name
        property string tip
        property bool on: false
        property bool shown: true
        signal clicked()
        visible: shown
        width: 34; height: 34; radius: 17
        color: hover.hovered ? "#2a3942" : "transparent"
        Image { anchors.centerIn: parent; width: 18; height: 18; sourceSize: Qt.size(36, 36); source: root.icon(b.name, b.on ? "accent" : "muted") }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: b.clicked() }
    }
    Component {
        id: docViewComponent
        WebEngineView {
            anchors.fill: parent
            backgroundColor: "#111b21"
            settings.pluginsEnabled: true
            settings.pdfViewerEnabled: true
            onTitleChanged: {
                // a blob: document is titled by Chromium after its file name when it has one
                if (root.docPath === "" && title !== "" && !/^[0-9a-f-]{36}$/i.test(title) && title.indexOf("blob:") !== 0)
                    root.docName = title;
            }
            onLoadingChanged: (info) => { if (info.status !== WebEngineView.LoadStartedStatus) console.info("qml-whats: document load", info.status, info.url.toString().substring(0, 100)); }
            onNewWindowRequested: (request) => root.newWindow(request)
            onNavigationRequested: (request) => {
                var u = request.url.toString();
                if (!request.isMainFrame || /^(blob|data|about|file|chrome-extension):/i.test(u) || root.trusted(u)) return;
                request.reject();
                if (/^(https?|mailto):/i.test(u)) Qt.openUrlExternally(request.url);
            }
        }
    }

    // ---- for the TSX --------------------------------------------------------------------------
    function reload() { if (view) view.reload(); }
    function hardReload() { if (view) view.reloadAndBypassCache(); }
    function exitFullScreen() { if (view) view.triggerWebAction(WebEngineView.ExitFullScreen); }
    function focusPage() { if (view) view.forceActiveFocus(); }
    function devTools() {
        if (!view) return;
        var w = devToolsComponent.createObject(null);
        windows.push(w);
        view.devToolsView = w.view;
        w.show();
    }

    // ---- the windows WhatsApp opens for itself ------------------------------------------------
    Component {
        id: popupComponent
        Window {
            id: popup
            property alias view: pv
            property var profile
            width: 900
            height: 680
            color: "#111b21"
            title: pv.title || "WhatsApp"
            WebEngineView {
                id: pv
                anchors.fill: parent
                profile: popup.profile
                settings.playbackRequiresUserGesture: false
                audioMuted: root.muted
                settings.fullScreenSupportEnabled: true
                settings.screenCaptureEnabled: true
                settings.pdfViewerEnabled: true
                settings.pluginsEnabled: true
                settings.javascriptCanAccessClipboard: true
                settings.javascriptCanPaste: true
                onPermissionRequested: (permission) => root.decide(permission)
                onDesktopMediaRequested: (request) => root.askScreen(request)
                onFullScreenRequested: (request) => { request.accept(); if (request.toggleOn) popup.showFullScreen(); else popup.showNormal(); }
                onWindowCloseRequested: popup.destroy()
                onNewWindowRequested: (request) => root.newWindow(request)
                onLoadingChanged: (info) => { if (info.status !== WebEngineView.LoadStartedStatus) console.info("qml-whats: popup load", info.status, info.url.toString().substring(0, 120)); }
                // A blank popup that turns out to lead outside WhatsApp (a link opened via
                // window.open): to the system browser, and the window goes away.
                onNavigationRequested: (request) => {
                    var u = request.url.toString();
                    if (!request.isMainFrame || root.trusted(u) || /^(blob|data|about):/i.test(u)) return;
                    request.reject();
                    if (/^(https?|mailto|tel):/i.test(u)) Qt.openUrlExternally(request.url);
                    popup.destroy();
                }
            }
            onClosing: popup.destroy()
            Component.onDestruction: { root.popups--; root.forget(popup); }
        }
    }
    Component {
        id: devToolsComponent
        Window {
            property alias view: dv
            width: 1000
            height: 700
            title: "DevTools — WhatsApp"
            WebEngineView { id: dv; anchors.fill: parent }
        }
    }
}
