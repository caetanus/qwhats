// A picture fitted into a box keeping its aspect (the send preview). QML because the CSS engine's
// <img> stretches to its box.
import QtQuick

Item {
    id: root
    property string source: ""
    property int boxWidth: 600
    property int boxHeight: 400
    implicitWidth: boxWidth
    implicitHeight: boxHeight
    Image {
        anchors.fill: parent
        source: root.source
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: root.boxWidth * 2
    }
}
