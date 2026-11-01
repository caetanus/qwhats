// Whether the conversation is scrolled to its end (WhatsApp Web's ⌄⌄ button shows when it isn't).
// The TSX can't read a list's scroll position: this finds the messages list's Flickable (inside
// the ".msgs" box of the conversation pane) and reports when it leaves or reaches the end.
import QtQuick

Item {
    id: root
    signal atEnd(bool yes)
    signal nearTop()                      // within a screen of the top: older messages are wanted
    signal tapped()                       // a click on the conversation (not on a text): the composer takes focus
    implicitWidth: 0
    implicitHeight: 0
    property Item flick: null
    property bool last: true
    function hasClass(it, c) { return it && it.cssClass && ("" + it.cssClass).split(",").indexOf(c) >= 0; }
    function findFlick(it) {
        if (!it) return null;
        if (it.contentY !== undefined && it.contentHeight !== undefined && it.atYEnd !== undefined) return it;
        for (var i = 0; i < it.children.length; i++) { var r = findFlick(it.children[i]); if (r) return r; }
        return null;
    }
    function findList(it) {
        if (!it) return null;
        if (hasClass(it, "msgs")) return it;
        for (var i = 0; i < it.children.length; i++) { var r = findList(it.children[i]); if (r) return r; }
        return null;
    }
    function attach() {
        var p = parent;
        while (p && !hasClass(p, "conv")) p = p.parent;
        var list = findList(p);
        var f = findFlick(list);
        if (!f) { retry.start(); return; }
        flick = f;
        var t = Qt.createQmlObject('import QtQuick; TapHandler { }', f);
        t.tapped.connect(function () { root.tapped(); });
        check();
    }
    function check() {
        if (!flick) return;
        // within 60 px of the bottom counts as the end (the last bubble's margin)
        // a ListView's content may start above 0 (originY): its end is originY + contentHeight
        var yes = flick.contentHeight <= flick.height || flick.contentY + flick.height >= flick.originY + flick.contentHeight - 60;
        if (yes !== last) { last = yes; atEnd(yes); }
        if (flick.contentHeight > flick.height && flick.contentY - flick.originY < flick.height) nearTop();
    }
    Timer { id: retry; interval: 300; onTriggered: root.attach() }
    // the ⌄⌄ button: a quick glide to the end (0.4–1.5 s by distance, easing out), then `glided` so
    // the page snaps to the last message (a virtual list's height settles while it scrolls)
    signal glided()
    // only a glide to the end snaps to the last message: a glide to a message (a search hit) stays there
    property bool glidingToEnd: false
    NumberAnimation {
        id: glide
        property: "contentY"
        easing.type: Easing.OutCubic
        onFinished: { if (root.glidingToEnd) { root.glidingToEnd = false; root.glided(); } }
    }
    // a jump the page already made (a reveal), replayed as a glide from where it was
    function here() { return flick ? flick.contentY : 0; }
    // A glide crosses at most this much: the list is virtual, and every frame of a long glide makes
    // and drops the rows it passes (each one laid out by the CSS engine) — a glide from far up through
    // hundreds of messages held the UI for seconds. Farther than this, the page jumps to this distance
    // from the target first, as WhatsApp Web does, and glides the rest.
    function maxGlide() { return flick ? flick.height * 2 : 0; }
    function glideFrom(from) {
        if (!flick) return;
        // whatever glide was running (a ⌄⌄) ends here: its "snap to the end" no longer applies
        glide.stop();
        root.glidingToEnd = false;
        var to = flick.contentY;
        if (Math.abs(to - from) < 2) return;
        if (Math.abs(to - from) > maxGlide()) from = to + (from < to ? -maxGlide() : maxGlide());
        glide.target = flick;
        glide.from = from;
        glide.to = to;
        glide.duration = Math.max(350, Math.min(1200, Math.abs(to - from) / 5));
        flick.contentY = from;
        root.glidingToEnd = false;
        glide.start();
    }
    function glideToEnd() {
        if (!flick) { glided(); return; }
        glide.stop();
        var end = flick.originY + flick.contentHeight - flick.height;
        var dist = end - flick.contentY;
        if (dist <= 1) { glided(); return; }
        if (dist > maxGlide()) {
            // far: jump near the end (the virtual list re-estimates its height there), glide the rest
            flick.contentY = end - maxGlide();
            end = flick.originY + flick.contentHeight - flick.height;
            dist = end - flick.contentY;
            if (dist <= 1) { glided(); return; }
        }
        glide.target = flick;
        glide.from = flick.contentY;
        glide.to = end;
        glide.duration = Math.max(400, Math.min(1500, dist / 5));
        root.glidingToEnd = true;
        glide.start();
    }
    Component.onCompleted: Qt.callLater(attach)
    Connections {
        target: root.flick
        function onContentYChanged() { root.check(); }
        function onContentHeightChanged() { root.check(); }
        function onHeightChanged() { root.check(); }
        function onOriginYChanged() { root.check(); }
    }
}
