// A message's text as WhatsApp Web shows it: selectable with the mouse (Ctrl+C copies), links that
// open in the browser, WhatsApp's own formatting (*bold*, _italic_, ~strike~, ```mono```, `code`,
// "> " quotes). QML because the CSS engine's text is neither selectable nor rich. It does not size
// itself: the bubble lays out an invisible engine <text class="ghost"> with the same words (which
// the engine measures and wraps), and this takes that text's size, drawn over it. `tail` is the blank room kept for the
// time on the last line.
import QtQuick

Item {
    id: root
    property string text: ""
    property string tail: ""
    property color textColor: "#fafafa"
    property color linkColor: "#53bdeb"
    property real fontSize: 14
    property real lineHeightPx: 20          // WhatsApp's 20 px lines, times the conversation's zoom
    property bool deleted: false
    signal openLink(string url)

    // the invisible layout text it covers: the `.ghost` in the same bubble content
    property Item box: null
    Component.onCompleted: Qt.callLater(refind)
    onParentChanged: Qt.callLater(refind)
    // the list recycles rows and the ghost can be rebuilt under us (a destroyed item reads null):
    // look again whenever it goes, or whenever this row is shown again
    onBoxChanged: if (!box) Qt.callLater(refind)
    onVisibleChanged: if (visible) Qt.callLater(refind)
    onTextChanged: Qt.callLater(refind)
    // a call queued just before the list rebuilt the row reaches a destroyed item: nothing to do
    function refind() { if (typeof root.findBox !== "function") return; var b = findBox(); if (b !== box) box = b; }
    function hasClass(it, c) { return it && it.cssClass && ("" + it.cssClass).split(",").indexOf(c) >= 0; }
    function findIn(it, c) {
        if (!it) return null;
        if (hasClass(it, c)) return it;
        for (var i = 0; i < it.children.length; i++) { var r = findIn(it.children[i], c); if (r) return r; }
        return null;
    }
    function findBox() {
        var p = parent;
        while (p && !hasClass(p, "content")) p = p.parent;
        return p ? findIn(p, "ghost") : null;
    }
    implicitWidth: box ? box.width : 0
    implicitHeight: box ? box.height : 0

    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
    // WhatsApp's markup: a marker hugging the words on both sides (*bold*), not across lines
    function markup(s) {
        var code = [];
        s = s.replace(/```([\s\S]+?)```/g, function (m, c) { code.push("<tt>" + c.replace(/\n/g, "<br>") + "</tt>"); return "\u0000" + (code.length - 1) + "\u0000"; });
        s = s.replace(/`([^`\n]+)`/g, function (m, c) { code.push("<tt>" + c + "</tt>"); return "\u0000" + (code.length - 1) + "\u0000"; });
        // links first (their text must not be read as markup), kept aside the same way
        s = s.replace(/\b((?:https?:\/\/|www\.)[^\s<]+[^\s<.,;:!?)\]'"])/gi, function (m, u) {
            var href = u.indexOf("www.") === 0 ? "http://" + u : u;
            code.push("<a href=\"" + href.replace(/&amp;/g, "&").replace(/"/g, "%22") + "\" style=\"color:" + root.linkColor + "; text-decoration:underline\">" + u + "</a>");
            return "\u0000" + (code.length - 1) + "\u0000";
        });
        // markdown as Meta AI writes it: **bold** (before WhatsApp's *bold*), # headings, - bullets
        s = s.replace(/^#{1,6} +(.*)$/gm, "<b>$1</b>");
        s = s.replace(/^([ \t]*)[-*] +/gm, "$1• ");
        s = s.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>");
        s = s.replace(/(^|[\s(])\*(\S(?:[^*\n]*\S)?)\*(?=$|[\s).,!?:;])/g, "$1<b>$2</b>");
        s = s.replace(/(^|[\s(])_(\S(?:[^_\n]*\S)?)_(?=$|[\s).,!?:;])/g, "$1<i>$2</i>");
        s = s.replace(/(^|[\s(])~(\S(?:[^~\n]*\S)?)~(?=$|[\s).,!?:;])/g, "$1<s>$2</s>");
        s = s.replace(/^&gt; (.*)$/gm, "<span style=\"color:" + Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.6) + "\">┃ $1</span>");
        s = s.replace(/\u0000(\d+)\u0000/g, function (m, i) { return code[parseInt(i)]; });
        // `| a | b |` lines: a table (a `| --- |` line under the first makes it the heading)
        s = s.replace(/(^|\n)((?:[ \t]*\|[^\n]*\|[ \t]*(?:\n|$))+)/g, function (m, pre, blk) { return pre + table(blk); });
        return s.replace(/\n/g, "<br>");
    }
    function table(blk) {
        var lines = blk.replace(/\n$/, "").split("\n"), rows = [], head = false;
        var line = Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.25);
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim();
            if (/^\|[\s:|-]+\|$/.test(l)) { if (i === 1) head = true; continue; }
            rows.push(l.slice(1, -1).split("|"));
        }
        var h = "<table border=\"1\" cellspacing=\"0\" cellpadding=\"6\" style=\"border-collapse:collapse; border-color:" + line + "; margin-top:4px; margin-bottom:4px\">";
        for (var r = 0; r < rows.length; r++) {
            h += "<tr>";
            for (var c = 0; c < rows[r].length; c++) {
                var t = rows[r][c].trim();
                h += (head && r === 0) ? "<th align=\"left\">" + t + "</th>" : "<td>" + t + "</td>";
            }
            h += "</tr>";
        }
        return h + "</table>";
    }
    // WhatsApp's 20 px lines for 14 px text
    readonly property string html: "<div style=\"line-height:" + Math.round(root.lineHeightPx) + "px\">" + (deleted ? "<i>" + esc(text) + "</i>" : markup(esc(text))) + tail + "</div>"

    TextEdit {
        id: edit
        // not before the layout has measured the ghost: at width 0 the text wraps letter by letter
        visible: root.box !== null && root.box.width > 1
        // the ghost's width straight from the ghost: the engine sizes this item once and, in a
        // recycled row, never again — the text must not follow that stale size
        width: root.box ? root.box.width : root.width
        readOnly: true
        selectByMouse: true
        persistentSelection: false
        textFormat: TextEdit.RichText
        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
        text: root.html
        color: root.textColor
        selectionColor: "#5553bdeb"
        selectedTextColor: root.textColor
        font.pixelSize: root.fontSize
        font.family: "Roboto"
        font.letterSpacing: 0.16
        onLinkActivated: (link) => root.openLink(link)
        HoverHandler { cursorShape: edit.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
    }
}
