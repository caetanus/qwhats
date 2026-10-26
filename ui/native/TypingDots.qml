// Telegram's typing dots: three dots that rise and brighten in turn, before "digitando". Zero wide when
// not active (the chat list's rows are recycled: the dots stay, folded, instead of coming and going).
// A wall-clock Timer, not an animation: an animation stops while the window isn't drawn.
import QtQuick

Item {
    id: root
    property bool active: false
    property color dotColor: "#21C063"
    property int phase: 0
    implicitWidth: active ? 22 : 0
    implicitHeight: 20
    visible: active
    // only tick while the item is actually on screen and the window is shown: a minimised or hidden
    // window (or a recycled row scrolled off) must not wake the timer ~7x/s (adversarial review)
    readonly property bool onScreen: root.visible && Window.window
        && Window.window.visibility !== Window.Hidden && Window.window.visibility !== Window.Minimized
    Timer { interval: 140; repeat: true; running: root.active && root.onScreen; onTriggered: root.phase = (root.phase + 1) % 6 }
    Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Repeater {
            model: 3
            Rectangle {
                // each dot peaks one step after the one before it
                readonly property real k: { var d = (root.phase - index + 6) % 6; return d === 0 ? 1 : d === 1 ? 0.6 : 0.25; }
                width: 4; height: 4; radius: 2
                color: root.dotColor
                opacity: 0.35 + 0.65 * k
                y: 2 - 3 * k
            }
        }
    }
}
