// Ctrl+wheel (and Ctrl+= / Ctrl+- / Ctrl+0): the conversation's zoom — its words, not the chat list
// (the UI scales the messages' sizes by it).
import QtQuick

Item {
    id: root
    property real zoom: 1.0                 // what the user wants
    signal zoomTo(real z)
    signal paste()                          // Ctrl+V with no text field focused: an image or a file
    implicitWidth: 0
    implicitHeight: 0

    function set(z) {
        z = Math.round(Math.max(0.5, Math.min(2.0, z)) * 10) / 10;
        if (z !== zoom) zoomTo(z);
    }
    // the wheel catcher on top of the window (attached once it exists)
    Component.onCompleted: Qt.callLater(function () { if (Window.window) catcher.parent = Window.window.contentItem; })
    MouseArea {
        id: catcher
        anchors.fill: parent
        z: 100000
        acceptedButtons: Qt.NoButton
        hoverEnabled: false
        onWheel: (e) => {
            if (!(e.modifiers & Qt.ControlModifier)) { e.accepted = false; return; }
            if (e.angleDelta.y !== 0) root.set(root.zoom + (e.angleDelta.y > 0 ? 0.1 : -0.1));
            e.accepted = true;
        }
    }
    Shortcut { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: root.set(root.zoom + 0.1) }
    Shortcut { sequence: "Ctrl+-"; onActivated: root.set(root.zoom - 0.1) }
    Shortcut { sequence: "Ctrl+0"; onActivated: root.set(1.0) }
    // a text field keeps its own Ctrl+V (the composer's pastes images too)
    Shortcut {
        sequence: "Ctrl+V"
        enabled: { var w = root.Window.window; var f = w ? w.activeFocusItem : null; return !(f && f.cursorPosition !== undefined); }
        onActivated: root.paste()
    }
}
