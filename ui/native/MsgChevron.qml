// O ∨ que o WhatsApp Web mostra no canto superior do balão quando o mouse passa por cima: abre o
// menu da mensagem logo abaixo dele. Em QML porque precisa do hover do balão (o motor de CSS não
// expõe) e da posição do clique para abrir o popup dentro do evento de entrada.
import QtQuick

Item {
    id: root
    property string icon: ""
    property color shade: "#242626"      // a cor do balão, para o degradê atrás do ∨
    signal open(real x, real y)
    implicitWidth: 28
    implicitHeight: 24

    property Item bubble: null
    property var hover: null
    function attach() {
        var p = parent;
        while (p && !(p.cssClass && ("" + p.cssClass).split(",").indexOf("bubble") >= 0)) p = p.parent;
        if (!p || p === bubble) return;
        bubble = p;
        hover = Qt.createQmlObject('import QtQuick; HoverHandler {}', p);
    }
    Component.onCompleted: Qt.callLater(attach)
    visible: !!hover && (hover.hovered || ma.containsMouse)

    // fixed sizes: the engine gives this item's box no height, the drawing must not depend on it
    Rectangle {
        width: 28; height: 24
        radius: 10
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.4; color: root.shade }
        }
    }
    Image { x: 6; y: 2; width: 20; height: 20; source: root.icon }
    MouseArea {
        id: ma
        width: 28; height: 24
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { var p = root.mapToItem(null, 0, 24); root.open(p.x, p.y); }
    }
}
