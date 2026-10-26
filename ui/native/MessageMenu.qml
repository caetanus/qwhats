// WhatsApp Web's message menu: the reaction bar (👍 ❤️ 😂 😮 😢 🙏 +) over a list of actions with
// their icons (Responder, Copiar, Reagir, Encaminhar, Fixar, Favoritar … Apagar). Its own popup
// window, opened at the click (the library's menu rows take no icons, and the bar needs one button
// per emoji). openAt() must run inside the input handler that asks for it: a Wayland popup needs
// that event's serial.
import QtQuick
import QtQuick.Controls

Item {
    id: root
    // [{ id, label, icon, danger, sep }] — `sep: true` draws a divider before the row
    property var items: []
    property bool reactions: true
    property string mine: ""             // the reaction I gave, highlighted in the bar
    property string plusIcon: ""
    signal action(string id)
    signal react(string emoji)
    implicitWidth: 0
    implicitHeight: 0

    function openAt(x, y) {
        var p = root.parent ? root.parent.mapFromItem(null, x, y) : Qt.point(x, y);
        anchor.x = p.x; anchor.y = p.y;
        pop.open();
    }
    function close() { pop.close(); }

    Item { id: anchor; width: 1; height: 1 }

    Popup {
        id: pop
        parent: anchor
        popupType: Popup.Window
        x: 0; y: 0
        padding: 0
        background: Item {}
        contentItem: Column {
            spacing: 8
            // the reaction bar
            Rectangle {
                visible: root.reactions
                width: bar.implicitWidth + 16; height: 52; radius: 26
                color: "#242626"; border.width: 1; border.color: "#14FFFFFF"
                Row {
                    id: bar
                    anchors.centerIn: parent; spacing: 2
                    Repeater {
                        model: ["👍", "❤️", "😂", "😮", "😢", "🙏"]
                        Rectangle {
                            width: 40; height: 40; radius: 20
                            color: root.mine === modelData ? "#33FFFFFF" : (eh.hovered ? "#1AFFFFFF" : "transparent")
                            Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 26; font.family: "Noto Color Emoji" }
                            HoverHandler { id: eh }
                            MouseArea { anchors.fill: parent; onClicked: { pop.close(); root.react(root.mine === modelData ? "" : modelData); } }
                        }
                    }
                    Rectangle {
                        width: 40; height: 40; radius: 20
                        color: ph.hovered ? "#1AFFFFFF" : "transparent"
                        Image { anchors.centerIn: parent; width: 22; height: 22; source: root.plusIcon }
                        HoverHandler { id: ph }
                        MouseArea { anchors.fill: parent; onClicked: { pop.close(); root.action("react-more"); } }
                    }
                }
            }
            // the actions
            Rectangle {
                width: 240; height: list.implicitHeight + 16; radius: 16
                color: "#242626"; border.width: 1; border.color: "#14FFFFFF"
                Column {
                    id: list
                    x: 0; y: 8; width: parent.width
                    Repeater {
                        model: root.items
                        Column {
                            width: list.width
                            Rectangle { visible: !!modelData.sep; width: parent.width - 32; x: 16; height: 1; color: "#1AFFFFFF" }
                            Item { visible: !!modelData.sep; width: 1; height: 6 }
                            Rectangle {
                                width: parent.width - 16; x: 8; height: 40; radius: 10
                                color: ih.hovered ? "#1AFFFFFF" : "transparent"
                                Image { x: 14; anchors.verticalCenter: parent.verticalCenter; width: 22; height: 22; source: modelData.icon }
                                Text {
                                    x: 52; anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label
                                    color: modelData.danger ? "#FF6B6B" : "#FAFAFA"
                                    font.pixelSize: 15; font.family: "Roboto"
                                }
                                HoverHandler { id: ih }
                                MouseArea { anchors.fill: parent; onClicked: { pop.close(); root.action(modelData.id); } }
                            }
                        }
                    }
                }
            }
        }
    }
}
