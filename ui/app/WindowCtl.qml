// WindowCtl — what the TSX cannot say about its own Window: bring it up (a notification click, the
// tray, a second launch), close to the tray, start hidden, full screen for a video or a call, and
// the app's keyboard shortcuts. A zero-size solid-qml escape hatch; `shortcut(name)` goes back.
import QtQuick
import QtQuick.Window

Item {
    id: root
    property bool closeToTray: true
    property bool startHidden: false
    property int raiseCount: 0
    property int trayClicks: 0   // a click on the tray icon: up, or away if it is in front
    property bool fullScreen: false
    property string title: ""   // "(3) WhatsApp": the window list and the taskbar show the unread count
    signal shortcut(string name)
    signal windowActive(bool active)

    implicitWidth: 0
    implicitHeight: 0

    property bool quitting: false
    property bool wasMaximized: false
    readonly property var win: Window.window

    function show() {
        if (!win) return;
        if (!win.visible || win.visibility === Window.Minimized) win.showNormal();
        win.raise();
        win.requestActivate();
    }
    function hide() { if (win) win.hide(); }
    // The tray icon: up if hidden or behind, away if it is the active window.
    function toggle() {
        if (!win) return;
        if (win.visible && win.active) win.hide();
        else show();
    }
    function quit() { quitting = true; Qt.quit(); }
    // The window goes behind others without being "active" on some compositors: a click on the
    // tray then always brings it up unless it is visible AND focused.

    onRaiseCountChanged: show()
    onTrayClicksChanged: toggle()
    onTitleChanged: if (win && title !== "") win.title = title
    onWinChanged: if (win && title !== "") win.title = title
    onFullScreenChanged: {
        if (!win) return;
        if (fullScreen) { wasMaximized = win.visibility === Window.Maximized; win.showFullScreen(); }
        else if (wasMaximized) win.showMaximized();
        else win.showNormal();
    }

    Connections {
        target: root.win
        function onClosing(close) {
            if (root.closeToTray && !root.quitting) {
                close.accepted = false;
                root.win.hide();
            }
        }
        function onActiveChanged() { root.windowActive(root.win.active); }
    }

    // Hidden at start only once the tray is known to exist (the TSX passes startHidden && tray), which
    // comes a moment after load: a late `true` within the first seconds still counts as the start.
    readonly property double born: Date.now()
    Component.onCompleted: if (startHidden) Qt.callLater(hide)
    onStartHiddenChanged: if (startHidden && Date.now() - born < 3000) hide()

    Shortcut { sequences: ["Ctrl+Q"]; context: Qt.ApplicationShortcut; onActivated: root.quit() }
    Shortcut { sequences: ["Ctrl+W"]; onActivated: root.closeToTray ? root.hide() : root.quit() }
    Shortcut { sequences: ["F5", "Ctrl+R"]; onActivated: root.shortcut("reload") }
    Shortcut { sequences: ["Ctrl+Shift+R"]; onActivated: root.shortcut("hard-reload") }
    Shortcut { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: root.shortcut("zoom-in") }
    Shortcut { sequences: ["Ctrl+-"]; onActivated: root.shortcut("zoom-out") }
    Shortcut { sequences: ["Ctrl+0"]; onActivated: root.shortcut("zoom-reset") }
    Shortcut { sequences: ["Ctrl+,"]; onActivated: root.shortcut("settings") }
    Shortcut { sequences: ["Ctrl+J"]; onActivated: root.shortcut("downloads") }
    Shortcut { sequences: ["F11"]; onActivated: root.shortcut("fullscreen") }
    Shortcut { sequences: ["Ctrl+Shift+I", "F12"]; onActivated: root.shortcut("devtools") }
    Shortcut { sequences: ["Escape"]; enabled: root.fullScreen; onActivated: root.shortcut("escape") }
}
