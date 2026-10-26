// A line of WhatsApp Web's landing text with inline bold, links and icons (StyledText): the
// engine's <text> has no inline styling. Sized by its own width (`boxWidth`) and the wrapped
// text's height, as a foreign item must be.
import QtQuick

Item {
    id: root
    property string text: ""
    property int boxWidth: 439
    property real fontSize: 18
    property real lineHeightPx: 24
    property color textColor: "#111B21"
    property bool centered: false
    // fill an ancestor's width instead of boxWidth: the nearest item with this CSS class, less `inset`
    property string fillClass: ""
    property int inset: 0
    property Item fill: null
    function findFill() {
        if (fillClass === "") return;
        var p = parent;
        while (p && !(p.cssClass && ("" + p.cssClass).split(",").indexOf(fillClass) >= 0)) p = p.parent;
        fill = p;
    }
    Component.onCompleted: Qt.callLater(findFill)
    onParentChanged: Qt.callLater(findFill)
    readonly property int w: fill ? Math.max(120, fill.width - inset) : boxWidth
    signal link(string href)
    implicitWidth: w
    implicitHeight: t.contentHeight

    Text {
        id: t
        width: root.w
        text: root.text
        textFormat: Text.StyledText
        wrapMode: Text.WordWrap
        horizontalAlignment: root.centered ? Text.AlignHCenter : Text.AlignLeft
        color: root.textColor
        linkColor: root.textColor
        font.family: "Roboto"
        font.pixelSize: root.fontSize
        font.letterSpacing: -0.18
        lineHeightMode: Text.FixedHeight
        lineHeight: root.lineHeightPx
        onLinkActivated: (href) => root.link(href)
        HoverHandler { cursorShape: t.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
    }
}
