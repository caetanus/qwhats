// The composer's text, as WhatsApp Web's: it grows with what is typed, one line at a time, up to
// `maxLines`; past that it scrolls inside. Enter sends, Shift+Enter breaks the line; Ctrl+V also asks
// for a pasted image (the text itself is pasted as usual). QML because the CSS engine's text fields do
// not grow with their content.
import QtQuick

Item {
    id: root
    property string text: ""              // set from outside (a draft, an emoji, an edit); edits go out by `edited`
    property string placeholder: ""
    property string textColor: "#E9EDEF"  // the theme's colours: "#rrggbb" or "rgba(r, g, b, a)"
    property string hintColor: "#8696A0"
    property real fontSize: 15
    property int maxLines: 3
    property int focusRequest: 0          // bumped from outside: the field takes the focus
    signal edited(string text)
    signal enter()
    signal paste()

    function qc(c) {
        var m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/.exec(c || "")
        return m ? Qt.rgba(m[1] / 255, m[2] / 255, m[3] / 255, m[4] === undefined ? 1 : +m[4]) : c
    }
    FontMetrics { id: metrics; font: edit.font }
    readonly property real lineHeight: Math.ceil(metrics.lineSpacing)
    implicitWidth: 100
    implicitHeight: Math.max(lineHeight, Math.min(edit.contentHeight, lineHeight * maxLines))

    onTextChanged: if (edit.text !== text) { edit.text = text; edit.cursorPosition = edit.length; }
    onFocusRequestChanged: edit.forceActiveFocus()

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: edit.contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        // the caret stays in view while typing past the third line
        function follow(r) {
            if (r.y < contentY) contentY = r.y;
            else if (r.y + r.height > contentY + height) contentY = r.y + r.height - height;
        }
        TextEdit {
            id: edit
            width: flick.width
            wrapMode: TextEdit.Wrap
            color: root.qc(root.textColor)
            selectionColor: "#5b8a72"
            font.pixelSize: root.fontSize
            selectByMouse: true
            persistentSelection: false
            onTextChanged: if (text !== root.text) root.edited(text)
            onCursorRectangleChanged: flick.follow(cursorRectangle)
            Keys.onPressed: (event) => {
                const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                if (enter && !(event.modifiers & Qt.ShiftModifier)) { event.accepted = true; root.enter(); return; }
                if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) root.paste();
            }
        }
    }
    Text {
        anchors.left: parent.left
        anchors.top: parent.top
        visible: edit.text.length === 0
        text: root.placeholder
        color: root.qc(root.hintColor)
        font.pixelSize: root.fontSize
    }
}
