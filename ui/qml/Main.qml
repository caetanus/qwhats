// QWhats' window, in plain Qt Quick: WhatsApp itself (WhatsWeb.qml, QtWebEngine) with a slim rail
// beside it, the downloads and settings panels, the permission and screen-sharing bars, the desktop
// notifications. The D backend is `app` (source/qmlwhats/backend.d); notifications are the host's
// `solidNotifications` (org.freedesktop.Notifications, with inline reply).
//
// (The first version of this screen was solid-qml TSX — ui/app/WhatsApp.tsx. Its CSS engine re-laid
// out a hovered button in the wrong place, so the rail flickered and clicks missed; until that is
// fixed the shell is plain QML: nothing here goes through a layout engine but Qt Quick's own.)
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls.Basic

Window {
    id: win
    width: 1240
    height: 820
    minimumWidth: 640
    minimumHeight: 420
    visible: true
    title: unread > 0 ? "(" + unread + ") WhatsApp" : "WhatsApp"
    color: pal.bg

    // ---- state ------------------------------------------------------------------------------
    readonly property var s: JSON.parse(app.settingsJson)
    readonly property var dictionaries: JSON.parse(app.dictionariesJson)
    // ---- accounts: one WhatsApp page (and Chromium profile) per account, all alive at once so every
    // account notifies. The model is kept in step with the setting by id, so changing any other
    // setting never rebuilds (and reloads) the pages.
    readonly property var accountList: s.accounts
    readonly property string current: s.currentAccount
    ListModel { id: accountModel }
    function syncAccounts() {
        var want = accountList;
        for (var i = accountModel.count - 1; i >= 0; --i) {
            var id = accountModel.get(i).accId, keep = false;
            for (var j = 0; j < want.length; ++j) if (want[j].id === id) keep = true;
            if (!keep) accountModel.remove(i);
        }
        for (var k = 0; k < want.length; ++k) {
            var at = -1;
            for (var m = 0; m < accountModel.count; ++m) if (accountModel.get(m).accId === want[k].id) at = m;
            if (at < 0) accountModel.append({ accId: want[k].id, accName: want[k].name });
            else if (accountModel.get(at).accName !== want[k].name) accountModel.setProperty(at, "accName", want[k].name);
        }
        refreshWeb();
    }
    onAccountListChanged: syncAccounts()
    Component.onCompleted: syncAccounts()
    function nameOf(acc) { for (var i = 0; i < accountList.length; ++i) if (accountList[i].id === acc) return accountList[i].name; return acc; }
    function pageOf(acc) {
        for (var i = 0; i < pageRep.count; ++i) { var it = pageRep.itemAt(i); if (it && it.acc === acc) return it; }
        return null;
    }
    property var web: null                 // the current account's page
    function refreshWeb() { web = pageOf(current); }
    onCurrentChanged: refreshWeb()
    function switchAccount(acc) {
        if (acc === current || !pageOf(acc)) return;
        setting("currentAccount", acc);
    }
    function addAccount() {
        var id = "a" + Date.now().toString(36);
        var list = accountList.slice();
        list.push({ id: id, name: "Conta " + (list.length + 1) });
        setting("accounts", list);
        setting("currentAccount", id);
        panel = "";
    }
    function renameAccount(acc, name) {
        name = name.trim();
        if (name === "" || name === nameOf(acc)) return;
        setting("accounts", accountList.map(function (a) { return a.id === acc ? { id: a.id, name: name } : a; }));
    }
    function removeAccount(acc) {
        if (acc === "main") return;
        if (current === acc) setting("currentAccount", "main");
        setting("accounts", accountList.filter(function (a) { return a.id !== acc; }));
        removeLater.acc = acc;
        removeLater.restart();
    }
    Timer { id: removeLater; property string acc; interval: 2000; onTriggered: app.removeProfile(acc) }   // once its page is gone
    property var unreadBy: ({})
    property int unread: 0
    function setUnread(acc, n) {
        var u = Object.assign({}, unreadBy);
        u[acc] = n;
        unreadBy = u;
        var t = 0;
        for (var k in u) t += u[k];
        unread = t;
    }
    property string panel: ""            // "" | "downloads" | "settings"
    property var downloads: []           // newest first
    property int seen: 0                 // downloads finished since the panel was last open
    readonly property int running: downloads.filter(function (d) { return d.state === "running"; }).length
    property var perm: ({ kind: "", origin: "", acc: "" })
    property var share: ({ open: false, screens: [], windows: [] })
    property var load: ({ loading: true, progress: 0, error: "" })
    property bool full: false
    property string hover: ""
    property string toast: ""
    readonly property var doc: web ? { open: win.web.docOpen, name: win.web.docName, path: win.web.docPath } : { open: false, name: "", path: "" }
    property var noteKeys: ({})          // desktop notification id → {acc, key} of the page's notification
    property var noteIds: ({})           // "acc:key" → desktop notification id
    // quitting: the window closes for real. A --grab run (one frame, then the host quits) is one.
    property bool quitting: app.oneShot
    property bool wasMaximized: false

    // ---- palette (WhatsApp's own colours, dark and light) -------------------------------------
    readonly property QtObject pal: QtObject {
        readonly property bool dark: app.dark
        readonly property color bg: dark ? "#111b21" : "#ffffff"
        readonly property color rail: dark ? "#202c33" : "#f0f2f5"
        readonly property color card: dark ? "#202c33" : "#f0f2f5"
        readonly property color hover: dark ? "#2a3942" : "#e9edef"
        readonly property color line: dark ? "#2a3942" : "#d1d7db"
        readonly property color fg: dark ? "#e9edef" : "#111b21"
        readonly property color muted: dark ? "#8696a0" : "#667781"
        readonly property color accent: dark ? "#21c063" : "#008069"
        readonly property color onAccent: dark ? "#0b141a" : "#ffffff"
        readonly property color danger: "#f15c6d"
    }
    function ic(name, variant) { return app.iconBase + "/" + variant + "/" + name + ".svg"; }
    function fileUrl(path) { return "file://" + encodeURI(path); }
    function setting(key, value) { app.set(key, JSON.stringify(value)); }

    // ---- the window ---------------------------------------------------------------------------
    function showWindow() {
        if (!win.visible || win.visibility === Window.Minimized) win.showNormal();
        win.raise();
        win.requestActivate();
    }
    function toggleWindow() {
        if (win.visible && win.active) win.hide();
        else showWindow();
    }
    function quit() { quitting = true; app.quit(); }
    readonly property bool trayOk: app.trayAvailable
    onClosing: (close) => {
        if (s.closeToTray && trayOk && !quitting) { close.accepted = false; win.hide(); }
    }
    Connections {
        target: app
        function onRaiseRequested() { win.showWindow(); }
        function onTrayChanged() { if (app.trayClicks !== win.trayClicksSeen) { win.trayClicksSeen = app.trayClicks; win.toggleWindow(); } }
    }
    property int trayClicksSeen: 0
    onFullChanged: {
        if (full) { wasMaximized = win.visibility === Window.Maximized; win.showFullScreen(); }
        else if (wasMaximized) win.showMaximized();
        else win.showNormal();
    }
    property bool startHiddenDone: false
    Timer {   // start in the tray: once the tray is known to exist (it registers a moment after load)
        interval: 1500; running: app.startHidden; repeat: false
        onTriggered: if (app.trayAvailable) win.hide()
    }
    onUnreadChanged: app.setUnread(unread)

    // ---- shortcuts ----------------------------------------------------------------------------
    Shortcut { sequences: ["Ctrl+Q"]; context: Qt.ApplicationShortcut; onActivated: win.quit() }
    Shortcut { sequences: ["Ctrl+W"]; onActivated: (win.s.closeToTray && win.trayOk) ? win.hide() : win.quit() }
    Shortcut { sequences: ["F5", "Ctrl+R"]; onActivated: win.web.reload() }
    Shortcut { sequences: ["Ctrl+Shift+R"]; onActivated: win.web.hardReload() }
    Shortcut { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: win.zoomBy(0.1) }
    Shortcut { sequences: ["Ctrl+-"]; onActivated: win.zoomBy(-0.1) }
    Shortcut { sequences: ["Ctrl+0"]; onActivated: win.setting("zoom", 1.0) }
    Shortcut { sequences: ["Ctrl+,"]; onActivated: win.togglePanel("settings") }
    Shortcut { sequences: ["Ctrl+J"]; onActivated: win.togglePanel("downloads") }
    Shortcut { sequences: ["F11"]; onActivated: win.full = !win.full }
    Shortcut { sequences: ["Ctrl+Shift+I", "F12"]; onActivated: win.web.devTools() }
    Repeater {   // Ctrl+1 … Ctrl+9: the accounts, in order
        model: 9
        Item {
            required property int index
            Shortcut { sequence: "Ctrl+" + (index + 1); enabled: index < win.accountList.length; onActivated: win.switchAccount(win.accountList[index].id) }
        }
    }
    Shortcut { sequences: ["Escape"]; enabled: win.full || win.panel !== ""; onActivated: win.leave() }
    function leave() {
        if (full) { win.web.exitFullScreen(); full = false; }
        else if (panel !== "") { panel = ""; win.web.focusPage(); }
    }

    function zoomBy(step) {
        var z = Math.round((s.zoom + step) * 100) / 100;
        setting("zoom", Math.max(0.5, Math.min(2.0, z)));
    }
    function togglePanel(name) {
        if (panel === name) { panel = ""; win.web.focusPage(); return; }
        panel = name;
        if (name === "downloads") seen = 0;
    }
    function showPanel(name) {
        showWindow();
        panel = name;
        if (name === "downloads") seen = 0;
    }
    function say(text) {
        toast = text;
        toastTimer.restart();
    }
    Timer { id: toastTimer; interval: 3500; onTriggered: win.toast = "" }

    // ---- remote control (JSON-RPC; the transport and settings.* / app.quit are D's) -----------
    Connections {
        target: app
        function onRpcRequest(conn, method, paramsJson, idJson) { win.rpc(conn, method, JSON.parse(paramsJson), idJson); }
    }
    function rpc(conn, method, params, idJson) {
        function ok(v) { app.rpcReply(conn, idJson, JSON.stringify(v === undefined ? true : v), ""); }
        function fail(msg) { app.rpcReply(conn, idJson, "", msg); }
        var acc = params.account || current;
        var page = pageOf(acc);
        switch (method) {
        case "app.status":
            return ok({ visible: win.visible, active: win.active, current: current, unread: unread,
                        accounts: accountList.map(function (a) { return { id: a.id, name: a.name, unread: unreadBy[a.id] || 0 }; }) });
        case "app.show": showWindow(); return ok();
        case "app.hide": win.hide(); return ok();
        case "app.toggle": toggleWindow(); return ok();
        case "app.reload": if (!page) return fail("no such account"); page.reload(); return ok();
        case "accounts.list": return ok(accountList);
        case "accounts.switch":
            if (!pageOf(params.id)) return fail("no such account: " + params.id);
            switchAccount(params.id); return ok();
        case "unread": return ok(unreadBy);
        case "chat.open":
        case "message.send":
            if (!page) return fail("no such account: " + acc);
            if (!params.phone) return fail("params.phone is required");
            if (method === "message.send" && !params.text) return fail("params.text is required");
            if (acc !== current) switchAccount(acc);
            page.openChat(params.phone, params.text || "", method === "message.send", function (done, err) { if (done) ok(); else fail(err); });
            return;
        case "help":
            return ok(["app.status", "app.show", "app.hide", "app.toggle", "app.reload {account?}", "app.quit",
                       "accounts.list", "accounts.switch {id}", "unread", "chat.open {phone, text?, account?}",
                       "message.send {phone, text, account?}", "settings.get", "settings.set {key, value}"]);
        default:
            return app.rpcReply(conn, idJson, "", "method not found: " + method);
        }
    }

    // ---- notifications ------------------------------------------------------------------------
    function onNotify(acc, key, title, body) {
        if (!s.notifications || typeof solidNotifications === "undefined" || !solidNotifications.available) return;
        if (win.active && win.visible && !full) return;   // the chat is in front of the user already
        var spec = {
            title: accountList.length > 1 ? title + " · " + nameOf(acc) : title,
            body: s.notifyPreview ? body : "Nova mensagem",
            icon: app.appIcon,
            actions: [{ id: "default", label: "Abrir" }]
        };
        if (solidNotifications.supportsReply) spec.reply = "Responder…";
        var id = solidNotifications.send(spec);
        if (id > 0) { noteKeys[id] = { acc: acc, key: key }; noteIds[acc + ":" + key] = id; }
    }
    function onNotifyClosed(acc, key) {
        var id = noteIds[acc + ":" + key];
        if (id) { solidNotifications.close(id); delete noteIds[acc + ":" + key]; delete noteKeys[id]; }
    }
    Connections {
        target: typeof solidNotifications !== "undefined" ? solidNotifications : null
        function onActionInvoked(id, action) {
            var n = win.noteKeys[id];
            win.showWindow();
            if (!n) return;
            win.switchAccount(n.acc);
            var p = win.pageOf(n.acc);
            if (p) p.clickNotification(n.key);
        }
        function onReplied(id, text) {
            var n = win.noteKeys[id];
            var p = n ? win.pageOf(n.acc) : null;
            if (p) { p.replyNotification(n.key, text); win.say("Resposta enviada"); }
        }
        function onClosed(id, reason) {
            var n = win.noteKeys[id];
            if (n) { delete win.noteKeys[id]; delete win.noteIds[n.acc + ":" + n.key]; }
        }
    }

    // ---- downloads ----------------------------------------------------------------------------
    function extOf(name) { var p = name.toLowerCase().split("."); return p.length > 1 ? p[p.length - 1] : ""; }
    function isPdf(d) { return d.mime === "application/pdf" || extOf(d.name) === "pdf"; }
    // Media is saved, documents open (as WhatsApp Desktop does when a document is clicked).
    function isMedia(d) {
        return ["image", "video", "audio"].indexOf((d.mime || "").split("/")[0]) >= 0
            || ["jpg", "jpeg", "png", "gif", "webp", "mp4", "webm", "ogg", "opus", "mp3", "m4a"].indexOf(extOf(d.name)) >= 0;
    }
    function openDownload(d, inApp) {
        if (inApp && isPdf(d)) { win.web.openDocument(fileUrl(d.path), d.name, d.path); panel = ""; }
        else app.openExternal("" + (fileUrl(d.path)));
    }
    function onDownload(acc, json) {
        var e = JSON.parse(json);
        e.id = acc + ":" + e.id;
        var list = downloads.slice();
        var at = -1;
        for (var i = 0; i < list.length; ++i) if (list[i].id === e.id) { at = i; break; }
        var d = { id: e.id, acc: acc, name: e.name, path: e.path, mime: e.mime, received: e.received, total: e.total,
                  state: e.state, error: e.error };
        if (at >= 0) list[at] = d; else list.unshift(d);
        downloads = list.slice(0, 60);
        if (e.type === "start") { app.ensureDir(e.dir); return; }
        if (e.type !== "done") return;
        if (d.state === "failed") { say("Falha ao baixar " + d.name + (d.error ? ": " + d.error : "")); return; }
        if (d.state !== "done") return;
        if (panel !== "downloads") seen++;
        if (isPdf(d) && s.pdfInApp) openDownload(d, true);
        else if (!isMedia(d) && s.openDownloads) openDownload(d, false);
        else say("Salvo: " + d.name);
    }
    function removeDownload(d) {
        if (d.state === "running") { var p = pageOf(d.acc); if (p) p.cancelDownload(parseInt(d.id.split(":")[1])); return; }
        app.removeFile(d.path);
        downloads = downloads.filter(function (x) { return x.id !== d.id; });
        if (doc.path === d.path) win.web.closeDocument();
    }
    function sizeOf(n) {
        if (n <= 0) return "";
        if (n < 1024) return n + " B";
        if (n < 1048576) return Math.round(n / 1024) + " KB";
        return (n / 1048576).toFixed(1) + " MB";
    }
    function openFolder() {
        app.ensureDir(s.downloadDir);
        app.openExternal("" + (fileUrl(s.downloadDir)));
    }

    // ---- permissions, screen sharing ----------------------------------------------------------
    function hostOf(origin) {
        var rest = origin.indexOf("://") >= 0 ? origin.substring(origin.indexOf("://") + 3) : origin;
        return rest.split("/")[0];
    }
    function permText(kind) {
        if (kind === "mic") return "quer usar o microfone";
        if (kind === "camera") return "quer usar a câmera";
        if (kind === "camera+mic") return "quer usar a câmera e o microfone";
        if (kind === "screen") return "quer compartilhar a sua tela";
        return "pede uma permissão";
    }
    function answer(grant) {
        var p = pageOf(perm.acc);
        if (p) p.answerPermission(grant);
        perm = { kind: "", origin: "", acc: "" };
    }
    function pick(kind, index) {
        var p = pageOf(share.acc);
        if (p) p.pickScreen(kind, index);
        share = { open: false, screens: [], windows: [], acc: "" };
    }

    // ---- spell-check languages ----------------------------------------------------------------
    // None chosen yet: the ones that match the system's (pt-BR, en-US), else all of them.
    readonly property var spellLangs: {
        var chosen = s.spellLangs, all = dictionaries;
        if (chosen.length > 0) return chosen.filter(function (l) { return all.indexOf(l) >= 0; });
        var sys = Qt.locale().name.replace("_", "-");
        var near = all.filter(function (l) { return l === sys || l === "en-US" || l.split("-")[0] === sys.split("-")[0]; });
        return near.length > 0 ? near : all;
    }
    function toggleLang(lang) {
        var cur = s.spellLangs.slice();
        var i = cur.indexOf(lang);
        if (i >= 0) cur.splice(i, 1); else cur.push(lang);
        setting("spellLangs", cur);
    }
    // The page's colour scheme is fixed when Chromium starts: a new theme restarts QWhats (the
    // session is on disk — nothing to log in again).
    function setTheme(t) {
        if (t === s.theme) return;
        setting("theme", t);
        app.restart();
    }

    // ==== the screen ===========================================================================
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- the main column -------------------------------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // first run of an AppImage that is not installed: offer to install it
            Bar {
                visible: app.installAsk && !win.full
                Image { source: app.appIcon; sourceSize: Qt.size(28, 28); Layout.preferredWidth: 26; Layout.preferredHeight: 26 }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: "Instalar o QWhats neste computador?"; color: pal.fg; font.pixelSize: 14; font.weight: Font.DemiBold }
                    Label {
                        text: "Move este arquivo para " + app.installTarget + " e põe o QWhats no menu de aplicativos, com ícone. Seus dados e login continuam onde estão."
                        color: pal.muted; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                }
                Btn { text: "Não perguntar mais"; ghost: true; small: true; onClicked: app.declineInstall() }
                Btn { text: "Agora não"; ghost: true; onClicked: app.laterInstall() }
                Btn { text: "Instalar"; onClicked: app.install() }
            }
            Connections {
                target: app
                function onInstallDone(error) { if (error !== "") win.say("Não foi possível instalar: " + error); }
            }
            // permission
            Bar {
                visible: win.perm.kind !== ""
                Image { source: win.ic(win.perm.kind === "screen" ? "monitor" : win.perm.kind === "mic" ? "mic" : "video", "accent"); sourceSize: Qt.size(22, 22); Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
                Label { text: win.hostOf(win.perm.origin) + " " + win.permText(win.perm.kind); color: pal.fg; font.pixelSize: 14; Layout.fillWidth: true; elide: Text.ElideRight }
                Btn { text: "Negar"; ghost: true; onClicked: win.answer(false) }
                Btn { text: "Permitir"; onClicked: win.answer(true) }
            }
            // screen sharing
            Bar {
                visible: win.share.open
                Image { source: win.ic("monitor", "accent"); sourceSize: Qt.size(22, 22); Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
                Label { text: "O que compartilhar na chamada?"; color: pal.fg; font.pixelSize: 14 }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: win.share.screens
                        Btn { required property int index; required property var modelData; small: true; text: modelData || ("Tela " + (index + 1)); onClicked: win.pick("screen", index) }
                    }
                    Repeater {
                        model: win.share.windows
                        Btn { required property int index; required property var modelData; small: true; ghost: true; text: modelData; onClicked: win.pick("window", index) }
                    }
                }
                Btn { text: "Cancelar"; ghost: true; onClicked: win.pick("cancel", 0) }
            }
            // loading
            Rectangle {
                visible: win.load.loading && win.load.progress < 100
                Layout.fillWidth: true
                Layout.preferredHeight: 3
                color: pal.bg
                Rectangle { height: parent.height; width: parent.width * win.load.progress / 100; color: pal.accent }
            }

            // ---- content: WhatsApp + a side panel --------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Repeater {
                        id: pageRep
                        model: accountModel
                        onItemAdded: win.refreshWeb()
                        onItemRemoved: win.refreshWeb()
                        WhatsWeb {
                            required property string accId
                            readonly property string acc: accId
                            anchors.fill: parent
                            visible: acc === win.current
                            enabled: visible
                            storageName: acc === "main" ? "qml-whats" : "qml-whats-" + acc
                            profilePath: acc === "main" ? app.profilePath : app.profileRoot + "/profiles/" + acc
                            cachePath: acc === "main" ? app.cachePath : app.cachePath + "-profiles/" + acc
                            startUrl: app.startUrl
                            downloadDir: win.s.downloadDir
                            zoom: win.s.zoom
                            autoGrantMedia: win.s.autoGrantMedia
                            spellcheck: win.s.spellcheck
                            spellLangs: win.spellLangs
                            autoUpdate: win.s.autoUpdate
                            busy: win.running > 0
                            sounds: win.s.sounds
                            listWidth: win.s.listWidth
                            forceCalling: win.s.forceCalling
                            onUnreadCount: (n) => win.setUnread(acc, n)
                            onNotify: (k, t, b) => win.onNotify(acc, k, t, b)
                            onNotifyClosed: (k) => win.onNotifyClosed(acc, k)
                            onDownloadEvent: (j) => win.onDownload(acc, j)
                            onPermissionAsk: (j) => { var p = JSON.parse(j); p.acc = acc; win.perm = p; win.switchAccount(acc); win.showWindow(); }
                            onScreenPick: (j) => { var r = JSON.parse(j); win.share = { open: true, screens: r.screens, windows: r.windows, acc: acc }; win.switchAccount(acc); win.showWindow(); }
                            onLoadState: (j) => { if (acc === win.current) win.load = JSON.parse(j); }
                            onFullScreen: (on) => win.full = on
                            onLinkHover: (u) => { if (acc === win.current) win.hover = u; }
                            onListResized: (pct) => { if (pct >= 18 && pct <= 45 && pct !== win.s.listWidth) win.setting("listWidth", pct); }
                        }
                    }

                    // ---- the dock ------------------------------------------------------------
                    // QWhats' own buttons, folded into one small button in the empty stretch of
                    // WhatsApp's own rail (above its media and profile buttons): it opens to the right
                    // while the mouse is over it, and folds back a moment after it leaves.
                    Rectangle {
                        id: dock
                        visible: !win.full
                        z: 10
                        readonly property bool open: dockHover.hovered || dockLinger.running
                        x: 12
                        anchors { bottom: parent.bottom; bottomMargin: 132 }
                        height: 40
                        width: open ? dockRow.implicitWidth + 12 : 40
                        radius: 20
                        color: open ? pal.card : (dockHover.hovered ? pal.hover : Qt.rgba(pal.card.r, pal.card.g, pal.card.b, 0.92))
                        border.width: 1
                        border.color: pal.line
                        clip: true
                        Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                        HoverHandler { id: dockHover; onHoveredChanged: if (!hovered) dockLinger.restart() }
                        Timer { id: dockLinger; interval: 450 }

                        // folded: the app's icon (or the current account's initial), with a dot when downloads ask for attention
                        Image {
                            visible: !dock.open
                            anchors.centerIn: parent
                            width: 24; height: 24
                            sourceSize: Qt.size(48, 48)
                            source: app.appIcon
                        }
                        Rectangle {
                            visible: !dock.open && (win.running > 0 || win.seen > 0 || win.doc.open)
                            x: 26; y: 2; width: 10; height: 10; radius: 5
                            color: win.running > 0 ? "#53bdeb" : pal.accent
                        }
                        // open: the buttons
                        RowLayout {
                            id: dockRow
                            visible: dock.open
                            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Repeater {   // the accounts, when there is more than one
                                model: win.accountList.length > 1 ? win.accountList : []
                                AccountButton {
                                    required property var modelData
                                    acc: modelData.id
                                    name: modelData.name
                                    on: modelData.id === win.current
                                    count: win.unreadBy[modelData.id] || 0
                                    onClicked: win.switchAccount(modelData.id)
                                }
                            }
                            Rectangle { visible: win.accountList.length > 1; Layout.preferredWidth: 1; Layout.preferredHeight: 22; color: pal.line }
                            DockButton {
                                icon: "download"; tip: "Downloads (Ctrl+J)"; on: win.panel === "downloads"
                                badge: win.running > 0 ? "" + win.running : (win.seen > 0 ? "" + win.seen : "")
                                onClicked: win.togglePanel("downloads")
                            }
                            DockButton { visible: win.doc.open; icon: "file-text"; tip: "Fechar o documento"; on: true; onClicked: win.web.closeDocument() }
                            DockButton { icon: "settings"; tip: "Configurações (Ctrl+,)"; on: win.panel === "settings"; onClicked: win.togglePanel("settings") }
                            DockButton { icon: "refresh-cw"; tip: "Recarregar (F5)"; onClicked: win.web.reload() }
                        }
                    }

                    // the page could not load
                    Rectangle {
                        anchors.fill: parent
                        visible: win.load.error !== ""
                        color: pal.bg
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 12
                            Image { source: win.ic("circle-alert", "danger"); sourceSize: Qt.size(44, 44); Layout.alignment: Qt.AlignHCenter }
                            Label { text: "Não foi possível abrir o WhatsApp"; color: pal.fg; font.pixelSize: 18; Layout.alignment: Qt.AlignHCenter }
                            Label { text: win.load.error; color: pal.muted; font.pixelSize: 12; Layout.alignment: Qt.AlignHCenter }
                            Btn { text: "Tentar de novo"; onClicked: win.web.reload(); Layout.alignment: Qt.AlignHCenter }
                        }
                    }
                    // the link under the mouse
                    Rectangle {
                        visible: win.hover !== "" && !win.full
                        anchors { left: parent.left; bottom: parent.bottom }
                        width: Math.min(hoverText.implicitWidth + 20, parent.width * 0.7)
                        height: hoverText.implicitHeight + 8
                        color: pal.card
                        Label { id: hoverText; anchors.centerIn: parent; width: parent.width - 20; text: win.hover; color: pal.muted; font.pixelSize: 12; elide: Text.ElideMiddle }
                    }
                    // a short notice
                    Rectangle {
                        visible: win.toast !== ""
                        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
                        width: toastText.implicitWidth + 36
                        height: toastText.implicitHeight + 20
                        radius: 8
                        color: "#e9edef"
                        Label { id: toastText; anchors.centerIn: parent; text: win.toast; color: "#111b21"; font.pixelSize: 13 }
                    }
                }

                // ---- downloads ---------------------------------------------------------------
                SidePanel {
                    visible: win.panel === "downloads"
                    title: "Downloads"
                    extra: IconBtn { icon: "folder-open"; tip: "Abrir a pasta"; onClicked: win.openFolder() }
                    onClose: win.togglePanel("downloads")

                    ColumnLayout {
                        visible: win.downloads.length === 0
                        Layout.fillWidth: true
                        Layout.topMargin: 48
                        spacing: 10
                        Image { source: win.ic("download", "muted"); sourceSize: Qt.size(44, 44); Layout.alignment: Qt.AlignHCenter }
                        Label { text: "Nada baixado ainda."; color: pal.fg; font.pixelSize: 15; Layout.alignment: Qt.AlignHCenter }
                        Label {
                            text: "Documentos abrem sozinhos ao terminar de baixar — PDFs aqui mesmo, ao lado da conversa."
                            color: pal.muted; font.pixelSize: 12; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true; Layout.leftMargin: 32; Layout.rightMargin: 32
                        }
                    }
                    ListView {
                        visible: win.downloads.length > 0
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: win.downloads
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}
                        delegate: Rectangle {
                            required property var modelData
                            readonly property var d: modelData
                            width: ListView.view.width
                            height: 60
                            radius: 8
                            color: rowHover.hovered ? pal.card : "transparent"
                            HoverHandler { id: rowHover }
                            RowLayout {
                                anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                                spacing: 8
                                Image { source: win.ic(win.isPdf(d) ? "file-text" : "download", d.state === "done" ? "fg" : "muted"); sourceSize: Qt.size(22, 22); Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3
                                    Label { text: d.name; color: pal.fg; font.pixelSize: 14; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                    Label {
                                        text: d.state === "running" ? win.sizeOf(d.received) + (d.total > 0 ? " de " + win.sizeOf(d.total) : "")
                                            : d.state === "done" ? win.sizeOf(d.total > 0 ? d.total : d.received)
                                            : d.state === "cancelled" ? "Cancelado" : "Falhou" + (d.error ? ": " + d.error : "")
                                        color: d.state === "failed" ? pal.danger : pal.muted
                                        font.pixelSize: 12
                                    }
                                    Rectangle {
                                        visible: d.state === "running"
                                        Layout.fillWidth: true; Layout.preferredHeight: 3; radius: 2; color: pal.line
                                        Rectangle { height: parent.height; radius: 2; color: pal.accent; width: d.total > 0 ? parent.width * d.received / d.total : 0 }
                                    }
                                }
                                IconBtn { visible: d.state === "done"; small: true; icon: "external-link"; tip: "Abrir com o aplicativo padrão"; onClicked: win.openDownload(d, false) }
                                IconBtn { visible: d.state === "done"; small: true; icon: "folder-open"; tip: "Mostrar na pasta"; onClicked: app.reveal(d.path) }
                                IconBtn { small: true; icon: d.state === "running" ? "x" : "trash-2"; tip: d.state === "running" ? "Cancelar" : "Apagar o arquivo"; onClicked: win.removeDownload(d) }
                            }
                            TapHandler {
                                // the row itself (left of the buttons) opens the file
                                enabled: d.state === "done"
                                onTapped: (pt) => { if (pt.position.x < parent.width - 120) win.openDownload(d, win.s.pdfInApp); }
                            }
                        }
                    }
                }

                // ---- settings ----------------------------------------------------------------
                SidePanel {
                    visible: win.panel === "settings"
                    title: "Configurações"
                    onClose: win.togglePanel("settings")

                    ScrollView {
                        id: settingsScroll
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: availableWidth
                        clip: true
                        ColumnLayout {
                            width: settingsScroll.availableWidth
                            spacing: 0

                            Section { text: "Contas" }
                            Repeater {
                                model: win.accountList
                                Row_ {
                                    id: accRow
                                    required property var modelData
                                    property bool confirm: false
                                    title: modelData.id === win.current ? "Em uso (Ctrl+" + (win.accountList.indexOf(modelData) + 1) + ")" : "Ctrl+" + (win.accountList.indexOf(modelData) + 1)
                                    hint: modelData.id === "main" ? "A conta original — não pode ser removida." : (accRow.confirm ? "Remover apaga o login desta conta neste computador." : "")
                                    TextField {
                                        text: accRow.modelData.name
                                        Layout.preferredWidth: 130
                                        selectByMouse: true
                                        onEditingFinished: win.renameAccount(accRow.modelData.id, text)
                                    }
                                    Btn { visible: accRow.modelData.id !== win.current; small: true; ghost: true; text: "Usar"; onClicked: win.switchAccount(accRow.modelData.id) }
                                    Btn {
                                        visible: accRow.modelData.id !== "main"; small: true; ghost: !accRow.confirm
                                        text: accRow.confirm ? "Confirmar" : "Remover"
                                        onClicked: { if (accRow.confirm) win.removeAccount(accRow.modelData.id); else accRow.confirm = true; }
                                    }
                                }
                            }
                            Row_ {
                                title: "Adicionar conta"; hint: "Abre uma página nova do WhatsApp para entrar com outro número (QR code). Todas ficam abertas e notificam."
                                Btn { text: "Adicionar"; onClicked: win.addAccount() }
                            }

                            Section { text: "Notificações" }
                            SwitchRow {
                                title: "Notificações na área de trabalho"
                                hint: typeof solidNotifications === "undefined" || !solidNotifications.available ? "Nenhum servidor de notificações encontrado."
                                    : solidNotifications.supportsReply ? "Com resposta direto na notificação." : "Clique para abrir a conversa."
                                checked: win.s.notifications; onToggled: (v) => win.setting("notifications", v)
                            }
                            SwitchRow { title: "Mostrar o texto da mensagem"; hint: "Desligado, a notificação diz só quem escreveu."; checked: win.s.notifyPreview; onToggled: (v) => win.setting("notifyPreview", v) }
                            SwitchRow { title: "Sons"; hint: "Desligado, o WhatsApp fica mudo (mensagens e toque de chamada); uma ligação em andamento sempre tem som."; checked: win.s.sounds; onToggled: (v) => win.setting("sounds", v) }

                            Section { text: "Aparência" }
                            Row_ {
                                title: "Tema"
                                hint: "O QWhats reinicia para aplicar. No WhatsApp, deixe Configurações › Personalização › Tema em \"Padrão do sistema\" para ele acompanhar."
                                ComboBox {
                                    id: themeBox
                                    model: [{ v: "system", t: "Sistema" }, { v: "light", t: "Claro" }, { v: "dark", t: "Escuro" }]
                                    textRole: "t"
                                    valueRole: "v"
                                    Component.onCompleted: currentIndex = indexOfValue(win.s.theme)
                                    onActivated: win.setTheme(currentValue)
                                    Layout.preferredWidth: 130
                                }
                            }
                            Row_ {
                                title: "Zoom"; hint: "Ctrl + / Ctrl − / Ctrl 0"
                                IconBtn { small: true; icon: "minus"; tip: "Diminuir"; onClicked: win.zoomBy(-0.1) }
                                Label { text: Math.round(win.s.zoom * 100) + "%"; color: pal.fg; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; Layout.preferredWidth: 44 }
                                IconBtn { small: true; icon: "plus"; tip: "Aumentar"; onClicked: win.zoomBy(0.1) }
                            }

                            Row_ {
                                title: "Largura da lista de conversas"; hint: "Ou arraste a borda direita da lista. O WhatsApp usa 40%; menos deixa mais espaço para a conversa."
                                IconBtn { small: true; icon: "minus"; tip: "Mais estreita"; onClicked: win.setting("listWidth", Math.max(18, win.s.listWidth - 2)) }
                                Label { text: win.s.listWidth + "%"; color: pal.fg; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; Layout.preferredWidth: 44 }
                                IconBtn { small: true; icon: "plus"; tip: "Mais larga"; onClicked: win.setting("listWidth", Math.min(45, win.s.listWidth + 2)) }
                            }

                            Section { text: "Janela" }
                            SwitchRow {
                                title: "Fechar para a bandeja"
                                hint: win.trayOk ? "Continua recebendo mensagens; Ctrl+Q ou o menu da bandeja saem de vez." : "Sem bandeja do sistema nesta sessão: fechar a janela sai do app."
                                checked: win.s.closeToTray; onToggled: (v) => win.setting("closeToTray", v)
                            }
                            SwitchRow { title: "Iniciar escondido na bandeja"; checked: win.s.startHidden; onToggled: (v) => win.setting("startHidden", v) }
                            SwitchRow {
                                title: "Atualizar o WhatsApp quando sair versão nova"
                                hint: "A cada 30 min o QWhats confere se o WhatsApp Web publicou uma versão nova; só então recarrega, depois de 10 min sem uso — nunca durante uma chamada, com texto digitado ou baixando arquivo."
                                checked: win.s.autoUpdate; onToggled: (v) => win.setting("autoUpdate", v)
                            }

                            Section { text: "Chamadas" }
                            SwitchRow {
                                title: "Permitir câmera e microfone ao WhatsApp"
                                hint: "Chamadas de voz e vídeo atendem sem perguntar. Desligado, uma barra pede a sua permissão."
                                checked: win.s.autoGrantMedia; onToggled: (v) => win.setting("autoGrantMedia", v)
                            }

                            SwitchRow {
                                title: "Forçar ligações no WhatsApp Web"
                                hint: "O WhatsApp libera ligações pelo navegador conta a conta; sem isso, os botões de ligar não aparecem. Ligado, o QWhats faz a página agir como se estivesse liberado — é uma modificação do cliente, contra os termos do WhatsApp, e a ligação só completa se o servidor aceitar. A página recarrega ao mudar."
                                checked: win.s.forceCalling; onToggled: (v) => win.setting("forceCalling", v)
                            }

                            Section { text: "Arquivos" }
                            SwitchRow { title: "Abrir PDFs dentro do app"; hint: "Ao lado da conversa, com o leitor do Chromium. Desligado, abrem no leitor do sistema."; checked: win.s.pdfInApp; onToggled: (v) => win.setting("pdfInApp", v) }
                            SwitchRow { title: "Abrir documentos ao terminar de baixar"; hint: "No aplicativo padrão do sistema. Fotos, vídeos e áudios só são salvos."; checked: win.s.openDownloads; onToggled: (v) => win.setting("openDownloads", v) }
                            Row_ {
                                title: "Pasta de downloads"; hint: win.s.downloadDir
                                Btn { text: "Abrir"; ghost: true; onClicked: win.openFolder() }
                            }

                            Section { text: "Corretor ortográfico" }
                            SwitchRow {
                                title: "Verificar a ortografia ao digitar"
                                hint: win.dictionaries.length > 0 ? "Clique com o botão direito numa palavra sublinhada para as sugestões." : "Nenhum dicionário instalado (pacotes hunspell-pt-br, hunspell-en_us)."
                                checked: win.s.spellcheck; onToggled: (v) => win.setting("spellcheck", v)
                            }
                            Flow {
                                visible: win.dictionaries.length > 0
                                Layout.fillWidth: true
                                Layout.topMargin: 10
                                Layout.bottomMargin: 10
                                spacing: 8
                                Repeater {
                                    model: win.dictionaries
                                    Btn { required property var modelData; small: true; text: modelData; ghost: win.spellLangs.indexOf(modelData) < 0; onClicked: win.toggleLang(modelData) }
                                }
                            }

                            Section { text: "Controle remoto" }
                            SwitchRow {
                                title: "Controle remoto (JSON-RPC)"
                                hint: win.s.remoteControl
                                    ? "Socket: " + app.rpcSocket + " — só o seu usuário acessa. Ex.: qwhats --rpc app.status"
                                    : "Permite a programas do seu usuário abrir conversas, enviar mensagens e ler o estado do QWhats por um socket local."
                                checked: win.s.remoteControl; onToggled: (v) => win.setting("remoteControl", v)
                            }

                            Section { text: "Avançado" }
                            Row_ {
                                title: "Recarregar sem cache"; hint: "Ctrl+Shift+R — se o WhatsApp ficar preso carregando."
                                Btn { text: "Recarregar"; ghost: true; onClicked: win.web.hardReload() }
                            }
                            Row_ {
                                title: "Ferramentas do desenvolvedor"; hint: "F12"
                                Btn { text: "Abrir"; ghost: true; onClicked: win.web.devTools() }
                            }
                            Item { Layout.preferredHeight: 24 }
                        }
                    }
                }
            }
        }
    }

    // ==== small components =====================================================================
    component AccountButton: Rectangle {
        id: ab
        property string acc
        property string name
        property bool on: false
        property int count: 0
        signal clicked()
        Layout.preferredWidth: 34
        Layout.preferredHeight: 34
        radius: 17
        color: on ? pal.accent : (abHover.hovered ? pal.hover : pal.line)
        Label { anchors.centerIn: parent; text: (ab.name || "?").substring(0, 1).toUpperCase(); color: ab.on ? pal.onAccent : pal.fg; font.pixelSize: 14; font.weight: Font.DemiBold }
        Rectangle {
            visible: ab.count > 0
            x: 18; y: -2; height: 16; radius: 8
            width: Math.max(16, abCount.implicitWidth + 8)
            color: pal.danger
            Label { id: abCount; anchors.centerIn: parent; text: ab.count > 99 ? "99+" : "" + ab.count; color: "#ffffff"; font.pixelSize: 9; font.bold: true }
        }
        HoverHandler { id: abHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: ab.clicked() }
        ToolTip.visible: abHover.hovered
        ToolTip.text: ab.name + (ab.count > 0 ? " — " + ab.count + " não lida(s)" : "")
        ToolTip.delay: 400
    }
    component DockButton: Rectangle {
        id: rb
        property string icon
        property string tip
        property bool on: false
        property string badge: ""
        property color badgeColor: pal.accent
        signal clicked()
        Layout.preferredWidth: 34
        Layout.preferredHeight: 34
        radius: 17
        color: on || rbHover.hovered ? pal.hover : "transparent"
        Image { anchors.centerIn: parent; width: 20; height: 20; sourceSize: Qt.size(40, 40); source: win.ic(rb.icon, rb.on ? "accent" : "muted") }
        Rectangle {
            visible: rb.badge !== ""
            x: 18; y: -2
            height: 18; radius: 9
            width: Math.max(18, badgeText.implicitWidth + 10)
            color: rb.badgeColor
            Label { id: badgeText; anchors.centerIn: parent; text: rb.badge; color: pal.onAccent; font.pixelSize: 10; font.bold: true }
        }
        HoverHandler { id: rbHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: rb.clicked() }
        ToolTip.visible: rbHover.hovered && tip !== ""
        ToolTip.text: tip
        ToolTip.delay: 600
    }
    component IconBtn: Rectangle {
        id: ib
        property string icon
        property string tip
        property bool small: false
        signal clicked()
        implicitWidth: small ? 30 : 34
        implicitHeight: implicitWidth
        radius: width / 2
        color: ibHover.hovered ? pal.hover : "transparent"
        Image { anchors.centerIn: parent; width: ib.small ? 16 : 20; height: width; sourceSize: Qt.size(40, 40); source: win.ic(ib.icon, "muted") }
        HoverHandler { id: ibHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: ib.clicked() }
        ToolTip.visible: ibHover.hovered && tip !== ""
        ToolTip.text: tip
        ToolTip.delay: 600
    }
    component Btn: Rectangle {
        id: bt
        property string text
        property bool ghost: false
        property bool small: false
        signal clicked()
        implicitWidth: btText.implicitWidth + (small ? 24 : 32)
        implicitHeight: small ? 28 : 32
        radius: height / 2
        color: ghost ? (btHover.hovered ? pal.hover : "transparent") : (btHover.hovered ? Qt.darker(pal.accent, 1.1) : pal.accent)
        border.width: ghost ? 1 : 0
        border.color: pal.line
        Label { id: btText; anchors.centerIn: parent; text: bt.text; color: bt.ghost ? pal.accent : pal.onAccent; font.pixelSize: bt.small ? 12 : 13; font.weight: Font.DemiBold }
        HoverHandler { id: btHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: bt.clicked() }
    }
    component Bar: Rectangle {
        default property alias content: barRow.data
        Layout.fillWidth: true
        Layout.preferredHeight: barRow.implicitHeight + 20
        color: pal.card
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: pal.line }
        RowLayout { id: barRow; anchors { fill: parent; leftMargin: 16; rightMargin: 16 } spacing: 12 }
    }
    component SidePanel: Rectangle {
        id: sp
        property string title
        property alias extra: extraSlot.data
        default property alias content: body.data
        signal close()
        Layout.preferredWidth: 400
        Layout.fillHeight: true
        color: pal.bg
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: pal.line; z: 2 }
        Rectangle {
            id: head
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 60
            color: pal.card
            RowLayout {
                anchors { fill: parent; leftMargin: 20; rightMargin: 10 }
                spacing: 6
                Label { text: sp.title; color: pal.fg; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true }
                Item { id: extraSlot; implicitWidth: childrenRect.width; implicitHeight: 34 }
                IconBtn { icon: "x"; tip: "Fechar (Esc)"; onClicked: sp.close() }
            }
        }
        ColumnLayout {
            id: body
            anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; leftMargin: 20; rightMargin: 12 }
            spacing: 0
        }
    }
    component Section: Label {
        Layout.topMargin: 22
        Layout.bottomMargin: 6
        color: pal.accent
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }
    component Row_: Item {
        id: r
        property string title
        property string hint
        default property alias controls: ctl.data
        Layout.fillWidth: true
        implicitHeight: Math.max(textCol.implicitHeight, ctl.implicitHeight) + 20
        ColumnLayout {
            id: textCol
            anchors { left: parent.left; right: ctl.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 3
            Label { text: r.title; color: pal.fg; font.pixelSize: 14; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Label { visible: r.hint !== ""; text: r.hint; color: pal.muted; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
        }
        RowLayout { id: ctl; anchors { right: parent.right; verticalCenter: parent.verticalCenter } spacing: 4 }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: pal.line }
    }
    component SwitchRow: Row_ {
        id: sr
        property bool checked
        signal toggled(bool value)
        Switch {
            checked: sr.checked
            onToggled: sr.toggled(checked)
            indicator: Rectangle {
                implicitWidth: 38; implicitHeight: 20; radius: 10
                x: parent.leftPadding; y: parent.height / 2 - height / 2
                color: parent.checked ? pal.accent : (pal.dark ? "#3b4a54" : "#c8d3de")
                Rectangle {
                    x: parent.parent.checked ? parent.width - width - 2 : 2
                    y: 2; width: 16; height: 16; radius: 8; color: "#ffffff"
                    Behavior on x { NumberAnimation { duration: 120 } }
                }
            }
        }
    }
}
