// The drag handle between the chat list and the conversation: WhatsApp Web's divider, made
// draggable (the list's width is the user's, remembered). Reports the pointer's x in the window.
import QtQuick

Item {
    id: root
    property color line: "#1affffff"
    signal dragged(real x)
    signal released()
    implicitWidth: 6
    implicitHeight: heightOfPane()
    function heightOfPane() {
        var p = parent;
        while (p && p.height <= 0) p = p.parent;
        return p ? p.height : 0;
    }
    MouseArea {
        anchors.fill: parent
        anchors.leftMargin: -3; anchors.rightMargin: -3
        cursorShape: Qt.SplitHCursor
        hoverEnabled: true
        onPositionChanged: (m) => { if (pressed) root.dragged(mapToItem(null, m.x, m.y).x); }
        onReleased: root.released()
    }
}
