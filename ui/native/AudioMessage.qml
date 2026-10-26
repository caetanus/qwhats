// A voice note (ptt) or audio message, laid out as WhatsApp Web draws it: play/pause, the waveform
// with its dot, and on the right the sender's picture with the mic badge at its lower left, the waveform that fills as it plays (click or drag to seek) with
// its dot, the duration below; while playing, the picture becomes the 1× / 1.5× / 2× speed pill.
// QML because it plays (Qt Multimedia) and draws per-sample bars. The file comes from the core's
// downloadMedia: until `source` is set, play asks for it (`download`) and starts once it arrives.
import QtQuick
import QtMultimedia
import QtQuick.Effects

Item {
    id: root
    property string source: ""          // file path once downloaded
    property string waveform: ""        // base64, 64 samples 0..100 (WhatsApp's own)
    property int duration: 0            // seconds, from the message
    property bool fromMe: false
    property bool ptt: true             // voice note (picture + mic) or plain audio (headphones)
    property bool fetching: false
    property bool listened: false       // the receiver played it (ack PLAYED / markPlayed)
    property string avatarBg: "#242626"
    property string avatarIcon: ""
    property string avatarSrc: ""       // the sender's picture, when there is one
    property string badgeIcon: ""       // mic (voice note) or headphones (audio)
    property string playIcon: ""
    property string pauseIcon: ""
    property color barColor: "#80ffffff"
    property color barDoneColor: "#fafafa"
    property color dotColor: "#53BDEB"
    property color badgeColor: "#21C063"
    property color textColor: "#99ffffff"
    property color pillColor: "#33000000"
    property bool muted: false          // tests
    property bool active: true          // false: another voice note started — this one pauses
    property bool autoPlay: false       // set true to start this note (auto-advance of a sequence)
    signal download()
    signal played()                     // the first time it plays (markPlayed)
    signal started()                    // every time it starts (one voice note at a time)
    signal finished()                   // the note reached its end (auto-advance to the next)
    onAutoPlayChanged: if (autoPlay && !playing) toggle()

    implicitWidth: laneWidth
    implicitHeight: 58

    property bool wantPlay: false
    property real defaultRate: 1.0      // the remembered playback speed (one for all notes), from settings
    readonly property real rate: defaultRate
    signal rateCycled(real r)          // the user cycled the speed pill: save it
    onActiveChanged: if (!active && playing) player.pause()
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    // the note finished: the player resets position to 0, so the dot returns to the start (as WhatsApp)
    readonly property real progress: player.duration > 0 ? player.position / player.duration : 0
    property var samples: decode(waveform)

    function decode(b64) {
        var out = [];
        if (!b64) {
            for (var k = 0; k < 64; k++) out.push(8);
            return out;
        }
        // base64 → bytes (Qt.atob is deprecated for binary data)
        var abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var bits = 0, n = 0;
        for (var i = 0; i < b64.length; i++) {
            var v = abc.indexOf(b64.charAt(i));
            if (v < 0) continue;
            bits = (bits << 6) | v;
            n += 6;
            if (n >= 8) { n -= 8; out.push((bits >> n) & 0xff); }
        }
        return out;
    }
    function toggle() {
        if (playing) { player.pause(); return; }
        if (source === "") { wantPlay = true; root.download(); return; }
        player.play();
    }
    function clock(ms) {
        var s = Math.round(ms / 1000);
        var m = Math.floor(s / 60);
        s = s % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    MediaPlayer {
        id: player
        source: root.source === "" ? "" : "file://" + root.source
        playbackRate: root.rate
        audioOutput: AudioOutput { muted: root.muted }
        property bool reported: false
        // play() before the file is loaded is lost: a play asked while downloading waits for it
        onMediaStatusChanged: {
            if (root.wantPlay && (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia)) { root.wantPlay = false; play(); }
            if (mediaStatus === MediaPlayer.EndOfMedia) root.finished(); // advance to the next note
        }
        onPlaybackStateChanged: {
            if (playbackState === MediaPlayer.PlayingState) root.started();
            if (playbackState === MediaPlayer.PlayingState && !reported) { reported = true; root.played(); }
        }
    }

    // laid out on its own width: the engine may resize the item, the player keeps WhatsApp's size
    property int laneWidth: 300            // the UI's: WhatsApp's 336 at most, narrower in a narrow pane
    Row {
        id: row
        spacing: 0
        // WhatsApp Web: play, the waveform, and the picture on the right, sent or received
        width: root.laneWidth
        height: 55

        // play / pause (a spinner ring while the file is fetched)
        Item {
            width: 34; height: 55
            Image {
                anchors.centerIn: parent
                visible: !root.fetching
                width: 34; height: 34
                source: root.playing ? root.pauseIcon : root.playIcon
                sourceSize: Qt.size(34, 34)
            }
            Rectangle {
                anchors.centerIn: parent
                visible: root.fetching
                width: 26; height: 26; radius: 13
                color: "transparent"
                border.width: 2.5
                border.color: root.barDoneColor
                opacity: 0.6
                RotationAnimation on rotation { running: root.fetching; loops: Animation.Infinite; from: 0; to: 360; duration: 900 }
                Rectangle { width: 8; height: 8; radius: 4; color: root.pillColor; x: -1; y: -1 }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggle() }
        }
        Item { width: 8; height: 1 }
        // the waveform: 64 bars, filled up to the playing position; click or drag to seek
        Item {
            id: wave
            width: row.width - 55 - 6 - 34 - 8
            height: 55
            Row {
                id: bars
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -4
                spacing: (wave.width - 64 * 2) / 63
                Repeater {
                    model: root.samples
                    Rectangle {
                        width: 2
                        radius: 1
                        anchors.verticalCenter: parent.verticalCenter
                        height: Math.max(3, Math.round(modelData / 100 * 22))
                        color: index / 64 < root.progress ? root.barDoneColor : root.barColor
                    }
                }
            }
            Rectangle {
                width: 12; height: 12; radius: 6
                color: root.listened || root.fromMe ? root.dotColor : root.badgeColor
                anchors.verticalCenter: bars.verticalCenter
                x: Math.max(0, Math.min(wave.width - width, root.progress * wave.width - width / 2))
            }
            Text {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: -2
                text: root.playing || player.position > 0 ? root.clock(player.position) : root.clock(root.duration * 1000)
                color: root.textColor
                font.pixelSize: 11; font.family: "Roboto"
            }
            MouseArea {
                anchors.fill: parent
                anchors.bottomMargin: 14
                cursorShape: Qt.PointingHandCursor
                function seek(x) {
                    if (root.source === "") { root.toggle(); return; }
                    var f = Math.max(0, Math.min(1, x / wave.width));
                    if (player.duration > 0) player.position = f * player.duration;
                    if (!root.playing) player.play();
                }
                onPressed: (m) => seek(m.x)
                onPositionChanged: (m) => { if (pressed && player.duration > 0) player.position = Math.max(0, Math.min(1, m.x / wave.width)) * player.duration; }
            }
        }
        Item { width: 6; height: 1 }
        // the sender's picture with the mic badge; the speed pill while playing
        Item {
            width: 55; height: 55
            Rectangle {
                visible: !root.playing
                anchors.fill: parent
                radius: width / 2
                color: root.avatarBg
                Image { visible: root.avatarSrc === ""; anchors.centerIn: parent; width: 26; height: 26; source: root.avatarIcon; sourceSize: Qt.size(26, 26) }
                // the picture, cut round
                Image {
                    id: face
                    visible: false
                    anchors.fill: parent
                    source: root.avatarSrc === "" ? "" : "file://" + root.avatarSrc
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(110, 110)
                }
                MultiEffect {
                    visible: root.avatarSrc !== ""
                    anchors.fill: parent
                    source: face
                    maskEnabled: true
                    maskSource: ShaderEffectSource { sourceItem: roundMask; hideSource: true }
                }
                Rectangle { id: roundMask; anchors.fill: parent; radius: width / 2; visible: false; layer.enabled: true }
            }
            Image {
                visible: !root.playing && root.badgeIcon !== ""
                x: -2
                y: parent.height - 19
                width: 19; height: 19
                source: root.badgeIcon
                sourceSize: Qt.size(19, 19)
            }
            Rectangle {
                visible: root.playing
                anchors.centerIn: parent
                width: 42; height: 26; radius: 13
                color: root.pillColor
                Text {
                    anchors.centerIn: parent
                    text: (root.rate === 1 ? "1" : (root.rate === 1.5 ? "1,5" : "2")) + "×"
                    color: root.barDoneColor
                    font.pixelSize: 13; font.weight: Font.Medium; font.family: "Roboto"
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.rateCycled(root.rate === 1 ? 1.5 : (root.rate === 1.5 ? 2 : 1))
                }
            }
        }
    }
}
