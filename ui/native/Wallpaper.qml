// The chat wallpaper: WhatsApp's doodle (look.ensure("doodle", colour) bakes the colour in), tiled
// at the size WhatsApp Web draws it (540x960) over the plain wallpaper colour. QML because the CSS
// engine has no background tiling.
import QtQuick

Item {
    id: root
    objectName: "wallpaper"
    property string source: ""
    property color base: "#161717"
    // WhatsApp masks the doodle with a solid colour and fades the whole layer (not each stroke).
    property real strength: 0.06
    // the conversation pane's width, for the UI's sizes that follow it (voice notes, pictures)
    signal paneWidth(real w)
    onImplicitWidthChanged: if (implicitWidth > 0) paneWidth(implicitWidth)
    // The engine hands a foreign item a zero-size holder and latches sizes: follow the conversation
    // pane itself (the nearest ".conv" ancestor), so the wallpaper always covers it — after a resize,
    // a maximize, the side drawer.
    property Item pane: null
    function findPane() {
        var p = parent;
        while (p && !(p.cssClass && ("" + p.cssClass).split(",").indexOf("conv") >= 0)) p = p.parent;
        pane = p;
    }
    Component.onCompleted: { findPane(); if (implicitWidth > 0) paneWidth(implicitWidth); }
    onParentChanged: Qt.callLater(findPane)
    implicitWidth: pane ? pane.width : 0
    implicitHeight: pane ? pane.height : 0
    width: implicitWidth
    height: implicitHeight

    Rectangle { anchors.fill: parent; color: root.base }
    Image {
        anchors.fill: parent
        source: root.source
        visible: root.source !== ""
        opacity: root.strength
        fillMode: Image.Tile
        horizontalAlignment: Image.AlignLeft
        verticalAlignment: Image.AlignTop
        sourceSize.width: 540
        sourceSize.height: 960
        asynchronous: true
        cache: true
    }
}
