// Reports the width of the nearest ancestor with a CSS class (the engine gives TSX no sizes): the
// chat list's real width, for what must fit in it (filter chips, the search hint).
import QtQuick

Item {
    id: root
    property string cls: ""
    signal measured(real w)
    property Item box: null
    implicitWidth: 0
    implicitHeight: 0
    function find() {
        var p = parent;
        while (p && !(p.cssClass && ("" + p.cssClass).split(",").indexOf(cls) >= 0)) p = p.parent;
        box = p;
    }
    Component.onCompleted: Qt.callLater(find)
    onParentChanged: Qt.callLater(find)
    readonly property real w: box ? box.width : 0
    onWChanged: if (w > 0) measured(w)
}
