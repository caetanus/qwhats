// The voice note being recorded, as WhatsApp Web shows it in the composer's place: the sound level
// as bars scrolling in from the right (newest last), filling the width it is given.
import QtQuick

Item {
    id: root
    property var levels: []             // 0..1, oldest first
    property color barColor: "#AEBAC1"
    property Item box: null
    function find() {
        var p = parent;
        while (p && !(p.cssClass && ("" + p.cssClass).split(",").indexOf("rec-wave") >= 0)) p = p.parent;
        box = p;
    }
    Component.onCompleted: Qt.callLater(find)
    implicitWidth: box ? box.width : 200
    implicitHeight: 32
    width: implicitWidth
    height: implicitHeight
    readonly property int slots: Math.max(1, Math.floor(width / 5))
    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Repeater {
            model: Math.min(root.slots, root.levels.length)
            Rectangle {
                readonly property real v: root.levels[root.levels.length - Math.min(root.slots, root.levels.length) + index]
                width: 3; radius: 1.5
                height: Math.max(3, Math.round(v * root.height))
                anchors.verticalCenter: parent.verticalCenter
                color: root.barColor
            }
        }
    }
}
