// A sticker in a bubble: animated ones play (WebP animation), still ones show; no background.
// While it isn't there (downloading, or gone and asked of the phone again) a soft frame holds its
// place, as WhatsApp Web's sticker placeholder.
import QtQuick

Item {
    id: root
    property string source: ""
    property int boxSize: 190
    property string placeholderIcon: ""
    implicitWidth: boxSize
    implicitHeight: boxSize
    width: boxSize
    height: boxSize
    readonly property bool inline: source.indexOf("data:") === 0
    AnimatedImage {
        id: anim
        anchors.fill: parent
        source: root.inline ? "" : root.source
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        playing: true
    }
    Image {
        id: still
        anchors.fill: parent
        source: root.inline ? root.source : ""
        fillMode: Image.PreserveAspectFit
    }
    readonly property bool shown: (anim.status === AnimatedImage.Ready && !root.inline) || (still.status === Image.Ready && root.inline)
    Rectangle {
        anchors.fill: parent
        visible: !root.shown
        radius: 16
        color: "#14FFFFFF"
        Image { anchors.centerIn: parent; width: 48; height: 48; source: root.placeholderIcon; opacity: 0.5 }
    }
}
