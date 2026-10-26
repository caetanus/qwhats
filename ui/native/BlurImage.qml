// A media thumbnail that is only the tiny inline preview (a few dozen pixels): blurred, as
// WhatsApp Web draws it until the real picture arrives, instead of blown-up blocks.
import QtQuick
import QtQuick.Effects

Item {
    id: root
    property string source: ""
    property int boxWidth: 270
    property int boxHeight: 270
    implicitWidth: boxWidth
    implicitHeight: boxHeight
    width: boxWidth
    height: boxHeight
    clip: true
    Image {
        id: img
        anchors.fill: parent
        source: root.source
        fillMode: Image.PreserveAspectCrop
        smooth: true
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: img
        blurEnabled: true
        blur: 1.0
        blurMax: 48
        autoPaddingEnabled: false
    }
}
