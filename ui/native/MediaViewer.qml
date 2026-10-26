// The media viewer WhatsApp Web opens over everything: a dark backdrop, the sender and time at the
// top left, close at the top right, the photo fitted to the window, a video with its controls, or
// a PDF page by page (Qt PDF). QML because it plays video (Qt Multimedia) and renders PDF.
// Esc or the backdrop closes it.
import QtQuick
import QtQuick.Pdf
import QtMultimedia

Item {
    id: root
    property string kind: ""            // image | video | pdf | text (a text status)
    property string textBody: ""
    property color textBg: "#1f5c4b"
    property string counter: ""         // "2/5" while stepping through a status
    property string source: ""          // the decrypted file
    property string title: ""
    property string subtitle: ""
    property string closeIcon: ""
    property string openIcon: ""
    property color backdrop: "#F2161717"
    property color fg: "#fafafa"
    property color muted: "#99ffffff"
    property bool silent: false         // tests
    signal close()
    signal openExternally()
    signal next()

    // the engine gives a foreign item a zero-size holder: take the window's size
    implicitWidth: winSize().width
    implicitHeight: winSize().height
    function winSize() {
        var p = parent;
        while (p && p.parent) p = p.parent;
        return p ? Qt.size(p.width, p.height) : Qt.size(0, 0);
    }
    focus: true
    Keys.onEscapePressed: root.close()
    Component.onCompleted: forceActiveFocus()

    Rectangle {
        anchors.fill: parent
        color: root.backdrop
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    // header: who sent it and when; open-in-app and close
    Item {
        id: head
        anchors.left: parent.left; anchors.right: parent.right
        height: 60
        Column {
            anchors.left: parent.left; anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text { text: root.title; color: root.fg; font.pixelSize: 16; font.family: "Roboto" }
            Text { text: root.subtitle; color: root.muted; font.pixelSize: 13; font.family: "Roboto" }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Repeater {
                model: [{ icon: root.openIcon, act: "open" }, { icon: root.closeIcon, act: "close" }]
                Rectangle {
                    width: 40; height: 40; radius: 20
                    color: hov.containsMouse ? "#1affffff" : "transparent"
                    Image { anchors.centerIn: parent; width: 24; height: 24; source: modelData.icon; sourceSize: Qt.size(24, 24) }
                    MouseArea {
                        id: hov
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: modelData.act === "close" ? root.close() : root.openExternally()
                    }
                }
            }
        }
    }

    Item {
        id: stage
        anchors.top: head.bottom; anchors.bottom: parent.bottom
        anchors.left: parent.left; anchors.right: parent.right
        anchors.margins: 24

        Image {
            visible: root.kind === "image"
            anchors.fill: parent
            source: root.kind === "image" && root.source !== "" ? "file://" + root.source : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            MouseArea { anchors.centerIn: parent; width: parent.paintedWidth; height: parent.paintedHeight }
        }

        Item {
            visible: root.kind === "video"
            anchors.fill: parent
            MediaPlayer {
                id: player
                source: root.kind === "video" && root.source !== "" ? "file://" + root.source : ""
                videoOutput: video
                audioOutput: AudioOutput { muted: root.silent }
                onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia) play()
            }
            VideoOutput { id: video; anchors.fill: parent; anchors.bottomMargin: 48 }
            MouseArea {
                anchors.fill: video
                onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
            }
            // controls: play/pause, position, the bar
            Item {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: 40
                Text {
                    id: ppl
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: player.playbackState === MediaPlayer.PlayingState ? "❚❚" : "▶"
                    color: root.fg; font.pixelSize: 18
                    MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                }
                Rectangle {
                    id: track
                    anchors.left: ppl.right; anchors.leftMargin: 16
                    anchors.right: time.left; anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4; radius: 2; color: "#4dffffff"
                    Rectangle { height: parent.height; radius: 2; color: root.fg; width: player.duration > 0 ? parent.width * player.position / player.duration : 0 }
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -10
                        onPressed: (m) => { if (player.duration > 0) player.position = Math.max(0, Math.min(1, (m.x - 10) / track.width)) * player.duration }
                    }
                }
                Text {
                    id: time
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    color: root.fg; font.pixelSize: 13; font.family: "Roboto"
                    text: clock(player.position) + " / " + clock(player.duration)
                    function clock(ms) { var s = Math.round(ms / 1000); var m = Math.floor(s / 60); s = s % 60; return m + ":" + (s < 10 ? "0" : "") + s; }
                }
            }
        }

        // a text status: the words on WhatsApp's colour, centred
        Rectangle {
            visible: root.kind === "text"
            anchors.centerIn: parent
            width: Math.min(parent.width, 520); height: Math.min(parent.height, 700)
            radius: 12
            color: root.textBg
            Text {
                anchors.fill: parent; anchors.margins: 32
                text: root.textBody
                color: "white"; font.pixelSize: 28; font.family: "Roboto"
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
        }
        // the right half steps to the next status update
        MouseArea {
            visible: root.counter !== ""
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: parent.width / 2
            onClicked: root.next()
        }
        Text {
            visible: root.counter !== ""
            anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.top; anchors.bottomMargin: 4
            text: root.counter; color: root.muted; font.pixelSize: 13; font.family: "Roboto"
        }

        PdfMultiPageView {
            visible: root.kind === "pdf"
            anchors.fill: parent
            document: PdfDocument { source: root.kind === "pdf" && root.source !== "" ? "file://" + root.source : "" }
        }
    }
}
