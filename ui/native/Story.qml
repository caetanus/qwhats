// WhatsApp Web's status viewer: the whole window, one author's updates in turn. Progress bars on top
// (one per update), the author and the time, the update in the middle (photo, video, or a text on its
// colour), the caption under it, a reply field at the bottom. An update runs for its time (a video
// for its length) and the next follows; a click on the left third goes back, elsewhere forward;
// holding the mouse down pauses. QML because the CSS engine has no timed animation or video.
import QtQuick
import QtQuick.Controls
import QtMultimedia
import QtQuick.Effects
import QtQuick.Shapes

Item {
    id: root
    // [{ kind: image|video|text|loading, source, text, bg, fg, font, caption, when, seconds }]
    property var items: []
    property int startAt: 0             // the first update shown
    property int index: 0
    property string name: ""
    property string avatar: ""          // file:// picture, or "" for the placeholder
    property color avatarBg: "#2E2F2F"
    property string closeIcon: ""
    property string backIcon: ""
    property string sendIcon: ""
    property string saveIcon: ""
    property string shareIcon: ""
    property string notice: ""              // a line shown for a moment ("Salvo em …")
    property bool mine: false
    property bool muted: false
    property bool authorMuted: false        // this person's updates are muted (the menu says so)
    property string menuIcon: ""
    signal shown(int i)                 // an update came on screen (seen receipt, next download)
    signal closed()
    signal finished()                       // past the last update: the next person's, if any
    signal previous()                       // back from the first: the previous person's
    signal reply(int i, string text)
    signal react(int i, string emoji)       // "" never: the same emoji again takes it back (outside)
    signal save(int i)                      // the update to disk
    signal share(int i)                     // the update forwarded (my status, a chat)
    signal toggleMute()                     // mute (or unmute) this person's updates

    // the whole window, whatever box the engine gave us
    implicitWidth: Window.window ? Window.window.width : 800
    implicitHeight: Window.window ? Window.window.height : 600

    readonly property var cur: items.length > index && index >= 0 ? items[index] : null
    property real progress: 0
    property bool held: false
    property bool starting: false        // a video loading, not playing yet
    // the video's own picture is on screen (until then its preview shows, under the spinner)
    readonly property bool videoShown: player.playbackState === MediaPlayer.PlayingState && player.position > 0
    property bool typing: replyField.activeFocus && replyField.text !== ""

    function go(i) {
        if (i < 0) { anim.stop(); player.stop(); previous(); return; }
        if (i >= items.length) { anim.stop(); player.stop(); finished(); return; }
        index = i;
        restart();
    }
    function restart() {
        anim.stop();
        progress = 0;
        if (!cur) return;
        shown(index);
        // a video plays once the player has it ready (loaded, first frame decoded): played at once it
        // began black and stuttering, the bar already running
        if (cur.kind === "video") {
            // the same video again (the list was only refreshed: seen, a reaction): no new status will
            // come for an unchanged source — play what is loaded, or keep waiting for it
            const same = String(player.source) === String(cur.source);
            if (same && (player.mediaStatus === MediaPlayer.LoadedMedia || player.mediaStatus === MediaPlayer.BufferedMedia
                    || player.mediaStatus === MediaPlayer.EndOfMedia)) {
                starting = false; player.stop(); player.position = 0;
                if (!held && !typing) player.play();
            } else if (!same) { player.stop(); starting = true; player.source = cur.source; }
        }
        else { player.stop(); player.source = ""; if (cur.kind !== "loading") anim.start(); }
    }
    // an update that finished downloading starts then (after `cur` follows the new list)
    onItemsChanged: Qt.callLater(function () { if (cur && cur.kind !== "loading" && !anim.running && !starting && player.playbackState === MediaPlayer.StoppedState) restart(); })
    // the viewer takes the keys (not the reply field: focus there pauses, as typing a reply does)
    Component.onCompleted: { index = Math.max(0, Math.min(startAt, items.length - 1)); root.forceActiveFocus(); restart(); }
    onHeldChanged: paused(held || typing)
    onTypingChanged: paused(held || typing)
    function paused(p) {
        if (p) { anim.pause(); if (player.playbackState === MediaPlayer.PlayingState) player.pause(); }
        else { anim.resume(); if (cur && cur.kind === "video" && !starting) player.play(); }
    }

    // the update's clock: wall time, not an animation — an animation only advances while the window
    // is drawn, and a window out of focus (or hidden) stops being drawn
    QtObject {
        id: anim
        property bool running: false
        property bool paused: false
        property real startedAt: 0
        property real before: 0
        readonly property real duration: (root.cur && root.cur.seconds ? root.cur.seconds : 6) * 1000
        function start() { before = 0; startedAt = Date.now(); paused = false; running = true; }
        function stop() { running = false; paused = false; }
        function pause() { if (running && !paused) { before += Date.now() - startedAt; paused = true; } }
        function resume() { if (running && paused) { startedAt = Date.now(); paused = false; } }
    }
    Timer {
        interval: 50; repeat: true
        running: anim.running && !anim.paused
        onTriggered: {
            root.progress = Math.min(1, (anim.before + Date.now() - anim.startedAt) / anim.duration);
            if (root.progress >= 1) { anim.stop(); root.go(root.index + 1); }
        }
    }

    Rectangle { anchors.fill: parent; color: "#111B21" }
    // as WhatsApp: the update itself, filling the window, blurred and dimmed behind it (a video live)
    Item {
        id: backdrop
        anchors.fill: parent
        visible: !!root.cur && root.cur.kind !== "text"
        layer.enabled: visible
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 1.0
            blurMax: 64
            brightness: -0.35
            autoPaddingEnabled: false
        }
        Image {
            anchors.fill: parent
            source: !root.cur ? "" : root.cur.kind === "image" ? root.cur.source
                : (root.cur.kind === "video" || root.cur.kind === "loading") ? (root.cur.poster || root.cur.thumb || "") : ""
            sourceSize.width: 256
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }

    // the update, 9:16 at most, centred
    Item {
        id: stage
        width: Math.min(parent.width - 160, (parent.height - 150) * 9 / 16)
        height: parent.height - 150
        anchors.horizontalCenter: parent.horizontalCenter
        y: 70

        Image {
            anchors.fill: parent
            visible: !!root.cur && root.cur.kind === "image"
            source: visible ? root.cur.source : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        // the video's still under it: shown until (and wherever) the player draws nothing
        Image {
            anchors.fill: parent
            visible: !!root.cur && root.cur.kind === "video" && !!root.cur.poster
            source: visible ? root.cur.poster : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        VideoOutput {
            id: vout
            anchors.fill: parent
            visible: !!root.cur && root.cur.kind === "video"
        }
        Rectangle {
            anchors.fill: parent
            visible: !!root.cur && root.cur.kind === "text"
            color: root.cur && root.cur.bg ? root.cur.bg : "#FF2E7D32"
            Text {
                anchors.fill: parent; anchors.margins: 28
                text: root.cur && root.cur.kind === "text" ? root.cur.text : ""
                color: root.cur && root.cur.fg ? root.cur.fg : "#FFFFFFFF"
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                fontSizeMode: Text.Fit; minimumPixelSize: 16
                font.pixelSize: 34
                font.family: root.cur && root.cur.font === 1 ? "Noto Serif" : root.cur && root.cur.font === 7 ? "Noto Sans Mono" : "Roboto"
                font.bold: !!root.cur && (root.cur.font === 3 || root.cur.font === 6 || root.cur.font === 7)
                font.italic: !!root.cur && root.cur.font === 2
            }
        }
        // still downloading: the message's own preview (tiny, so blurred when stretched) under the spinner
        Image {
            anchors.fill: parent
            visible: !!root.cur && (root.cur.kind === "loading" ? !!(root.cur.poster || root.cur.thumb)
                : root.cur.kind === "video" && !root.videoShown && !root.cur.poster && !!root.cur.thumb)
            source: visible ? (root.cur.poster || root.cur.thumb) : ""
            fillMode: Image.PreserveAspectFit
            smooth: true
            opacity: 0.85
        }
        // the spinner: a white arc turning (the Controls style's own is dark on this dark viewer)
        Item {
            id: spinner
            anchors.centerIn: parent
            width: 44; height: 44
            property bool running: !!root.cur && (root.cur.kind === "loading" || (root.cur.kind === "video" && (root.starting
                || player.mediaStatus === MediaPlayer.BufferingMedia || player.mediaStatus === MediaPlayer.StalledMedia)))
            visible: running
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 4; strokeColor: "#FFFFFF"; fillColor: "transparent"; capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 22; centerY: 22; radiusX: 19; radiusY: 19; startAngle: 0; sweepAngle: 270 }
                }
            }
            RotationAnimator on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: spinner.running }
        }
        // the caption, over the bottom of the picture
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: cap.implicitHeight + 24
            visible: !!root.cur && !!root.cur.caption && root.cur.kind !== "text"
            color: "#80000000"
            Text {
                id: cap
                anchors.fill: parent; anchors.margins: 12
                text: root.cur && root.cur.caption ? root.cur.caption : ""
                color: "#FFFFFF"; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 15; font.family: "Roboto"
            }
        }
        // back on the left third, forward elsewhere; holding pauses
        MouseArea {
            anchors.fill: parent
            pressAndHoldInterval: 250
            onPressAndHold: root.held = true
            onReleased: { if (root.held) { root.held = false; return; } }
            onClicked: (m) => { if (m.x < width / 3) root.go(root.index - 1); else root.go(root.index + 1); }
        }
    }

    MediaPlayer {
        id: player
        videoOutput: vout
        audioOutput: AudioOutput { muted: root.muted }
        onPositionChanged: if (player.duration > 0) root.progress = player.position / player.duration
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) { root.go(root.index + 1); return; }
            if (mediaStatus === MediaPlayer.InvalidMedia) { root.starting = false; root.go(root.index + 1); return; }
            if (root.starting && (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia)) {
                root.starting = false;
                if (!root.held && !root.typing) play();
            }
        }
    }

    // the bars, one per update
    Row {
        x: stage.x; y: 16; width: stage.width; spacing: 4
        Repeater {
            model: root.items.length
            Rectangle {
                width: (stage.width - 4 * (root.items.length - 1)) / Math.max(1, root.items.length)
                height: 3; radius: 2
                color: "#4DFFFFFF"
                Rectangle {
                    height: parent.height; radius: 2; color: "#FFFFFF"
                    width: index < root.index ? parent.width : index === root.index ? parent.width * root.progress : 0
                }
            }
        }
    }
    // who and when
    Row {
        x: stage.x; y: 28; spacing: 12
        Rectangle {
            width: 40; height: 40; radius: 20; color: root.avatarBg; clip: true
            Image { anchors.fill: parent; source: root.avatar; visible: root.avatar !== ""; fillMode: Image.PreserveAspectCrop }
        }
        Column {
            anchors.verticalCenter: parent.verticalCenter
            Text { text: root.name; color: "#FFFFFF"; font.pixelSize: 16; font.family: "Roboto"; font.weight: Font.Medium }
            Text { text: root.cur ? root.cur.when : ""; color: "#B3FFFFFF"; font.pixelSize: 13; font.family: "Roboto" }
        }
    }
    // save and share, beside close (not in WhatsApp Web: the user's wish)
    Row {
        id: saveShare
        x: parent.width - 52 - 96; y: 18; spacing: 16
        visible: !!root.cur && root.cur.kind !== "text" && root.cur.kind !== "loading"
        Image {
            width: 28; height: 28; source: root.saveIcon
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: root.save(root.index) }
        }
        Image {
            width: 28; height: 28; source: root.shareIcon
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: root.share(root.index) }
        }
    }
    // the ⋮ menu, left of save/share and close: this person's updates muted or not ("Silenciar")
    Image {
        id: menuBtn
        visible: !root.mine
        x: parent.width - 52 - (saveShare.visible ? 96 : 0) - 44; y: 18; width: 28; height: 28
        source: root.menuIcon
        MouseArea {
            anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
            onClicked: { root.held = true; storyMenu.popup(menuBtn, -140, menuBtn.height + 6); }
        }
        Menu {
            id: storyMenu
            onClosed: root.held = false
            MenuItem { text: root.authorMuted ? "Reativar som" : "Silenciar"; onTriggered: root.toggleMute() }
        }
    }
    Rectangle {
        visible: root.notice !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 120
        width: noticeText.implicitWidth + 32; height: 36; radius: 18
        color: "#E6242626"
        Text { id: noticeText; anchors.centerIn: parent; text: root.notice; color: "#FFFFFF"; font.pixelSize: 14; font.family: "Roboto" }
    }
    // close (top right) and back/forward arrows beside the update
    Image {
        x: parent.width - 52; y: 20; width: 28; height: 28; source: root.closeIcon
        MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: root.closed() }
    }
    Image {
        x: stage.x - 56; y: stage.y + stage.height / 2 - 16; width: 32; height: 32; source: root.backIcon
        visible: root.index > 0
        MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: root.go(root.index - 1) }
    }
    Image {
        x: stage.x + stage.width + 24; y: stage.y + stage.height / 2 - 16; width: 32; height: 32; source: root.backIcon
        rotation: 180
        MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: root.go(root.index + 1) }
    }

    // the phones' quick reactions, over the reply field while it has the focus
    Row {
        visible: !root.mine && replyField.activeFocus && replyField.text === ""
        anchors.horizontalCenter: stage.horizontalCenter
        y: parent.height - 62 - 56
        spacing: 14
        Repeater {
            model: ["\u{1F602}", "\u{1F62E}", "\u{1F60D}", "\u{1F622}", "\u{1F44F}", "\u{1F525}", "\u{1F389}", "\u{1F4AF}"]
            delegate: Text {
                required property string modelData
                text: modelData
                font.pixelSize: 30
                scale: qa.pressed ? 0.8 : (root.cur && root.cur.reaction === modelData ? 1.2 : 1)
                Behavior on scale { NumberAnimation { duration: 90 } }
                MouseArea {
                    id: qa
                    anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.react(root.index, modelData); replyField.focus = false; }
                }
            }
        }
    }

    // reply (not on my own updates)
    Rectangle {
        visible: !root.mine
        x: stage.x; width: stage.width; height: 44; radius: 22
        y: parent.height - 62
        color: "#2A3942"
        TextField {
            id: replyField
            anchors.left: parent.left; anchors.right: likeBtn.left; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 16; anchors.rightMargin: 8
            placeholderText: "Responder…"
            placeholderTextColor: "#99FFFFFF"
            color: "#FFFFFF"; font.pixelSize: 15; font.family: "Roboto"
            background: null
            onAccepted: send()
            function send() { if (text.trim() !== "") { root.reply(root.index, text); text = ""; focus = false; } }
        }
        // WhatsApp Web's like: the green heart (filled once given; again takes it back)
        Text {
            id: likeBtn
            anchors.right: sendBtn.left; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
            text: root.cur && root.cur.reaction && root.cur.reaction !== "\u{1F49A}" ? root.cur.reaction : "\u{1F49A}"
            opacity: root.cur && root.cur.reaction ? 1 : 0.55
            font.pixelSize: 22
            scale: likeArea.pressed ? 0.85 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }
            MouseArea {
                id: likeArea
                anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor
                onClicked: root.react(root.index, root.cur && root.cur.reaction ? root.cur.reaction : "\u{1F49A}")
            }
        }
        Image {
            id: sendBtn
            anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
            width: 24; height: 24; source: root.sendIcon
            MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: replyField.send() }
        }
    }
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Escape) { root.closed(); e.accepted = true; }
        else if (e.key === Qt.Key_Right) { root.go(root.index + 1); e.accepted = true; }
        else if (e.key === Qt.Key_Left) { root.go(root.index - 1); e.accepted = true; }
    }
    focus: true
}
