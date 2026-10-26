// WhatsApp Web's media editor, in the send preview: a toolbar over the picture (crop and rotate, draw,
// text, rectangle, pixelate, emoji; undo, redo; download) and the picture with the edits on it.
// Strokes and pixelated boxes are painted into the picture (a list of operations in its pixels, after
// its rotation, drawn on a Canvas); texts, emoji and rectangles are objects over it — picked, dragged,
// sized and turned by their corner handle, dropped on the bin to go, a text edited again with a double
// click. Each change writes the flattened picture (at most 2560 px a side) to a file and reports it with
// edited(path): that file is what gets sent. QML because the CSS engine has no canvas.
import QtQuick
import QtQuick.Controls
import QtCore

Item {
    id: root
    property string source: ""           // file:///… the picture
    property string outDir: ""           // where the flattened copies go
    property color fg: "#FAFAFA"
    property color muted: "#99FFFFFF"
    property color accent: "#21C063"
    // the toolbar's icons (ic(name, colour) from the UI)
    property string iconCrop: ""
    property string iconRotate: ""
    property string iconFlip: ""
    property string iconDraw: ""
    property string iconText: ""
    property string iconRect: ""
    property string iconPixelate: ""
    property string iconEmoji: ""
    property string iconUndo: ""
    property string iconRedo: ""
    property string iconDownload: ""
    property string iconDelete: ""
    signal edited(string path)
    signal notice(string text)

    // the box the stage gives the picture: the ".stage-body" around us (the engine sizes foreign
    // items by their implicit size only)
    property Item host: null
    function hasClass(it, c) { return it && it.cssClass && ("" + it.cssClass).split(",").indexOf(c) >= 0; }
    Component.onCompleted: { var p = parent; while (p && !hasClass(p, "stage-body")) p = p.parent; host = p; root.forceActiveFocus(); }
    implicitWidth: host ? host.width : 640
    implicitHeight: host ? host.height : 480

    // ---- the state ------------------------------------------------------------------------------
    property int natW: 0                  // the picture as loaded
    property int natH: 0
    property int rot: 0                   // 0, 90, 180, 270 (clockwise)
    property bool flip: false             // mirrored left↔right (after the rotation)
    readonly property int rw: rot % 180 === 0 ? natW : natH     // the rotated frame
    readonly property int rh: rot % 180 === 0 ? natH : natW
    property var crop: null               // {x, y, w, h} in the rotated frame; null = all of it
    property var ops: []                  // painted: [{k: path|pixel, …}] in the rotated frame
    // the objects: k text|emoji|rect; x, y their centre (frame px); w, h a rectangle's size; z a text's
    // font size; s scale; r rotation (degrees); c colour; t text; lw a rectangle's line
    ListModel { id: objs }
    property int nextId: 1
    property int selected: -1             // the selected object's oid
    property int editing: -1              // the text being edited again
    property var undoStack: []
    property var redoStack: []
    property string tool: ""              // "" | crop | draw | text | rect | pixel | emoji
    property color pen: "#FFFFFF"
    property int penSize: 8
    property string emoji: "😀"

    readonly property var colors: ["#FFFFFF", "#000000", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#007AFF", "#AF52DE", "#FF2D55"]
    readonly property var emojis: ["😀", "😂", "😍", "😎", "🥳", "😢", "😡", "👍", "👏", "🙏", "❤️", "🔥", "⭐", "🎉", "✅", "❌", "➡️", "⬆️", "💯", "👀"]
    readonly property var roles: ["oid", "k", "x", "y", "w", "h", "z", "s", "r", "c", "t", "lw"]

    function objList() { var out = []; for (var i = 0; i < objs.count; i++) { var o = objs.get(i), c = {}; for (var j = 0; j < roles.length; j++) c[roles[j]] = o[roles[j]]; out.push(c); } return out; }
    function objIndex(oid) { for (var i = 0; i < objs.count; i++) if (objs.get(i).oid === oid) return i; return -1; }
    function obj(oid) { var i = objIndex(oid); return i < 0 ? null : objs.get(i); }
    function addObj(o) {
        var full = { oid: nextId++, k: "", x: 0, y: 0, w: 0, h: 0, z: 0, s: 1, r: 0, c: "#FFFFFF", t: "", lw: 0 };
        for (var key in o) full[key] = o[key];
        objs.append(full);
        return full.oid;
    }
    function setObj(oid, key, v) { var i = objIndex(oid); if (i >= 0) objs.setProperty(i, key, v); }
    function removeObj(oid) { var i = objIndex(oid); if (i >= 0) { push(); objs.remove(i); if (selected === oid) selected = -1; changed(); } }

    function snapshot() { return JSON.stringify({ rot: rot, flip: flip, crop: crop, ops: ops, objs: objList() }); }
    function restore(s) {
        var o = JSON.parse(s);
        rot = o.rot; flip = !!o.flip; crop = o.crop; ops = o.ops;
        objs.clear();
        for (var i = 0; i < o.objs.length; i++) objs.append(o.objs[i]);
        if (objIndex(selected) < 0) selected = -1;
        changed();
    }
    function push() { undoStack = undoStack.concat([snapshot()]); redoStack = []; }
    function dropPush() { undoStack = undoStack.slice(0, -1); }       // an undo step that changed nothing
    function undo() { commitText(); if (!undoStack.length) return; redoStack = redoStack.concat([snapshot()]); var s = undoStack[undoStack.length - 1]; undoStack = undoStack.slice(0, -1); restore(s); }
    function redo() { commitText(); if (!redoStack.length) return; undoStack = undoStack.concat([snapshot()]); var s = redoStack[redoStack.length - 1]; redoStack = redoStack.slice(0, -1); restore(s); }
    function changed() { view.requestPaint(); saveSoon.restart(); }

    // a quarter turn clockwise: the frame turns, the edits, the objects and the crop with it —
    // (x, y) → (rh − y, x)
    function rotate() {
        commitText();
        push();
        var H = rh;
        function pt(p) { return { x: H - p.y, y: p.x }; }
        function box(b) { return { x: H - b.y - b.h, y: b.x, w: b.h, h: b.w }; }
        var out = [];
        for (var i = 0; i < ops.length; i++) {
            var o = JSON.parse(JSON.stringify(ops[i]));
            if (o.k === "path") o.pts = o.pts.map(pt);
            else { var b = box(o); o.x = b.x; o.y = b.y; o.w = b.w; o.h = b.h; }
            out.push(o);
        }
        ops = out;
        for (var j = 0; j < objs.count; j++) {
            var ob = objs.get(j), q = pt(ob);
            objs.setProperty(j, "x", q.x); objs.setProperty(j, "y", q.y); objs.setProperty(j, "r", (ob.r + 90) % 360);
        }
        if (crop) crop = box(crop);
        const before = vs;
        // what is shown is mirror(rotate(picture)): a quarter turn of that is the mirror of a quarter
        // turn the other way
        rot = flip ? (rot + 270) % 360 : (rot + 90) % 360;
        changed();
        // the new frame starts where the old one was (a quarter turn back, at the old size) and turns in
        turnAnim.stop(); animRot = -90; animK = before / vs; turnAnim.start();
    }

    // mirrored left↔right: the picture, the edits, the objects (their place and tilt; a text stays
    // readable) and the crop
    function mirror() {
        commitText();
        push();
        var W = rw;
        var out = [];
        for (var i = 0; i < ops.length; i++) {
            var o = JSON.parse(JSON.stringify(ops[i]));
            if (o.k === "path") o.pts = o.pts.map(function (p) { return { x: W - p.x, y: p.y }; });
            else o.x = W - o.x - o.w;
            out.push(o);
        }
        ops = out;
        for (var j = 0; j < objs.count; j++) {
            var ob = objs.get(j);
            objs.setProperty(j, "x", W - ob.x); objs.setProperty(j, "r", (360 - ob.r) % 360);
        }
        if (crop) crop = { x: W - crop.x - crop.w, y: crop.y, w: crop.w, h: crop.h };
        flip = !flip;
        changed();
        flipAnim.stop(); animFlip = -1; flipAnim.start();
    }

    // the turn and the mirror, animated (WhatsApp's editor): the picture and its objects together
    property real animRot: 0
    property real animK: 1
    property real animFlip: 1
    ParallelAnimation {
        id: turnAnim
        NumberAnimation { target: root; property: "animRot"; to: 0; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "animK"; to: 1; duration: 220; easing.type: Easing.OutCubic }
    }
    NumberAnimation { id: flipAnim; target: root; property: "animFlip"; to: 1; duration: 240; easing.type: Easing.InOutQuad }

    // ---- the view: the cropped frame fitted in the box; in crop mode, the whole frame -----------
    readonly property var shown: (tool === "crop" || !crop) ? { x: 0, y: 0, w: Math.max(1, rw), h: Math.max(1, rh) } : crop
    readonly property real picTop: opts.y + opts.height + 8
    readonly property real vs: Math.max(0.01, Math.min((root.width - 32) / shown.w, (root.height - picTop - 16) / shown.h))
    function toFrame(px, py) { return { x: shown.x + (px - view.x) / vs, y: shown.y + (py - view.y) / vs }; }

    // draws the picture and the painted edits for `frame` (a crop box) at scale s; with objects too
    // when flattening
    function paint(ctx, frame, s, w, h, withObjects) {
        ctx.reset();
        ctx.clearRect(0, 0, w, h);
        if (natW === 0) return;
        function frameSpace() { ctx.save(); ctx.scale(s, s); ctx.translate(-frame.x, -frame.y); }
        frameSpace();
        ctx.save();
        if (flip) { ctx.translate(rw, 0); ctx.scale(-1, 1); }
        if (rot === 90) { ctx.translate(rw, 0); ctx.rotate(Math.PI / 2); }
        else if (rot === 180) { ctx.translate(rw, rh); ctx.rotate(Math.PI); }
        else if (rot === 270) { ctx.translate(0, rh); ctx.rotate(-Math.PI / 2); }
        ctx.drawImage(root.source, 0, 0, natW, natH);
        ctx.restore();
        for (var i = 0; i < ops.length; i++) {
            var o = ops[i];
            if (o.k === "pixel") { ctx.restore(); pixelate(ctx, (o.x - frame.x) * s, (o.y - frame.y) * s, o.w * s, o.h * s, w, h); frameSpace(); continue; }
            if (o.k === "path" && o.pts.length) {
                ctx.strokeStyle = o.c; ctx.lineWidth = o.s; ctx.lineCap = "round"; ctx.lineJoin = "round";
                ctx.beginPath(); ctx.moveTo(o.pts[0].x, o.pts[0].y);
                for (var j = 1; j < o.pts.length; j++) ctx.lineTo(o.pts[j].x, o.pts[j].y);
                if (o.pts.length === 1) ctx.lineTo(o.pts[0].x + 0.1, o.pts[0].y);
                ctx.stroke();
            }
        }
        if (withObjects) {
            for (var k = 0; k < objs.count; k++) {
                var b = objs.get(k);
                ctx.save();
                ctx.translate(b.x, b.y); ctx.rotate(b.r * Math.PI / 180); ctx.scale(b.s, b.s);
                if (b.k === "rect") {
                    ctx.strokeStyle = b.c; ctx.lineWidth = b.lw; ctx.strokeRect(-b.w / 2, -b.h / 2, b.w, b.h);
                } else {
                    ctx.font = (b.k === "emoji" ? "" : "bold ") + Math.round(b.z) + "px " + (b.k === "emoji" ? "Noto Color Emoji" : "Roboto");
                    ctx.textBaseline = "middle"; ctx.textAlign = "center";
                    var lines = b.t.split("\n"), lh = b.z * 1.2;
                    for (var l = 0; l < lines.length; l++) {
                        var ly = (l - (lines.length - 1) / 2) * lh;
                        if (b.k === "text") { ctx.lineWidth = Math.max(2, b.z / 8); ctx.strokeStyle = outlineOf(b.c); ctx.strokeText(lines[l], 0, ly); }
                        ctx.fillStyle = b.c; ctx.fillText(lines[l], 0, ly);
                    }
                }
                ctx.restore();
            }
        }
        ctx.restore();
    }
    function outlineOf(c) { return ("" + c).toUpperCase() === "#000000" ? "#FFFFFF" : "#000000"; }
    // a box of the canvas in blocks of one colour (its average)
    function pixelate(ctx, x, y, w, h, cw, ch) {
        x = Math.max(0, Math.round(x)); y = Math.max(0, Math.round(y));
        w = Math.min(cw - x, Math.round(w)); h = Math.min(ch - y, Math.round(h));
        if (w < 2 || h < 2) return;
        var img = ctx.getImageData(x, y, w, h), d = img.data;
        var b = Math.max(6, Math.round(Math.max(w, h) / 16));
        for (var by = 0; by < h; by += b) for (var bx = 0; bx < w; bx += b) {
            var r = 0, g = 0, bl = 0, n = 0;
            var ey = Math.min(h, by + b), ex = Math.min(w, bx + b);
            for (var yy = by; yy < ey; yy += 2) for (var xx = bx; xx < ex; xx += 2) { var i = (yy * w + xx) * 4; r += d[i]; g += d[i + 1]; bl += d[i + 2]; n++; }
            ctx.fillStyle = Qt.rgba(r / n / 255, g / n / 255, bl / n / 255, 1);
            ctx.fillRect(x + bx, y + by, ex - bx, ey - by);
        }
    }

    // another picture: its own edits
    onSourceChanged: { ops = []; objs.clear(); undoStack = []; redoStack = []; rot = 0; crop = null; tool = ""; selected = -1; editing = -1; field.visible = false; natW = 0; natH = 0; }
    Image { id: probe; visible: false; source: root.source; onStatusChanged: if (status === Image.Ready) { root.natW = implicitWidth; root.natH = implicitHeight; view.loadImage(root.source); out.loadImage(root.source); } }

    // ---- the toolbar ---------------------------------------------------------------------------
    Row {
        id: bar
        anchors.horizontalCenter: parent.horizontalCenter
        y: 4; height: 48; spacing: 4
        component Tool: Rectangle {
            property string icon: ""
            property string name: ""
            property bool on: root.tool === name && name !== ""
            property bool enabledTool: true
            signal hit()
            width: 44; height: 44; radius: 22
            color: on ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25) : (th.hovered ? "#1AFFFFFF" : "transparent")
            opacity: enabledTool ? 1 : 0.35
            Image { anchors.centerIn: parent; width: 24; height: 24; source: parent.icon }
            HoverHandler { id: th }
            MouseArea { anchors.fill: parent; enabled: parent.enabledTool; cursorShape: Qt.PointingHandCursor; onClicked: parent.hit() }
        }
        Tool { icon: root.iconUndo; enabledTool: root.undoStack.length > 0; onHit: root.undo() }
        Tool { icon: root.iconRedo; enabledTool: root.redoStack.length > 0; onHit: root.redo() }
        Item { width: 16; height: 1 }
        Tool { icon: root.iconCrop; name: "crop"; onHit: root.pick("crop") }
        Tool { icon: root.iconRotate; onHit: root.rotate() }
        Tool { icon: root.iconFlip; onHit: root.mirror() }
        Tool { icon: root.iconDraw; name: "draw"; onHit: root.pick("draw") }
        Tool { icon: root.iconText; name: "text"; onHit: root.pick("text") }
        Tool { icon: root.iconRect; name: "rect"; onHit: root.pick("rect") }
        Tool { icon: root.iconPixelate; name: "pixel"; onHit: root.pick("pixel") }
        Tool { icon: root.iconEmoji; name: "emoji"; onHit: root.pick("emoji") }
        Item { width: 16; height: 1 }
        Tool { icon: root.iconDownload; onHit: root.download() }
    }
    function pick(t) { commitText(); tool = tool === t ? "" : t; if (tool === "draw" || tool === "pixel" || tool === "crop") selected = -1; view.requestPaint(); }

    // the options: colours (the selected object's, or the next one's), sizes, the emoji, the crop's buttons
    readonly property bool colouring: tool === "draw" || tool === "text" || tool === "rect" || (selected >= 0 && obj(selected) !== null && obj(selected).k !== "emoji")
    Row {
        id: opts
        anchors.horizontalCenter: parent.horizontalCenter
        y: bar.y + bar.height + 2; height: 32; spacing: 6
        Repeater {
            model: root.colouring ? root.colors : []
            Rectangle {
                readonly property bool cur: root.pen.toString().toUpperCase() === modelData.toUpperCase()
                width: 24; height: 24; radius: 12; y: 4; color: modelData
                border.width: cur ? 3 : 1
                border.color: cur ? root.accent : "#66FFFFFF"
                MouseArea { anchors.fill: parent; onClicked: root.setPen(modelData) }
            }
        }
        Repeater {
            model: (root.tool === "draw" || root.tool === "rect") ? [4, 8, 16] : []
            Rectangle {
                width: 28; height: 28; radius: 14; y: 2
                color: root.penSize === modelData ? "#33FFFFFF" : "transparent"
                Rectangle { anchors.centerIn: parent; width: modelData / 2 + 4; height: width; radius: width / 2; color: root.fg }
                MouseArea { anchors.fill: parent; onClicked: root.penSize = modelData }
            }
        }
        Repeater {
            model: root.tool === "emoji" ? root.emojis : []
            Rectangle {
                width: 30; height: 30; radius: 6; y: 1
                color: root.emoji === modelData ? "#33FFFFFF" : "transparent"
                Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 20; font.family: "Noto Color Emoji" }
                MouseArea { anchors.fill: parent; onClicked: root.emoji = modelData }
            }
        }
        Text {
            visible: root.tool === "crop"; y: 7
            text: "Arraste para recortar"; color: root.muted; font.pixelSize: 14; font.family: "Roboto"
        }
        Rectangle {
            visible: root.tool === "crop" && root.crop !== null
            width: resetT.implicitWidth + 20; height: 28; radius: 14; y: 2; color: "#1AFFFFFF"
            Text { id: resetT; anchors.centerIn: parent; text: "Restaurar"; color: root.fg; font.pixelSize: 13; font.family: "Roboto" }
            MouseArea { anchors.fill: parent; onClicked: { root.push(); root.crop = null; root.changed(); } }
        }
        Rectangle {
            visible: root.tool === "crop"
            width: doneT.implicitWidth + 20; height: 28; radius: 14; y: 2; color: root.accent
            Text { id: doneT; anchors.centerIn: parent; text: "Concluir"; color: "#0A0A0A"; font.pixelSize: 13; font.family: "Roboto"; font.weight: Font.Medium }
            MouseArea { anchors.fill: parent; onClicked: root.pick("crop") }
        }
    }
    // a colour: the next object's, and the selected object's
    function setPen(c) {
        pen = c;
        if (editing >= 0) field.color = c;
        var o = obj(selected);
        if (o && o.k !== "emoji" && ("" + o.c).toUpperCase() !== c.toUpperCase()) { push(); setObj(selected, "c", c); changed(); }
    }

    // ---- the picture ---------------------------------------------------------------------------
    Canvas {
        id: view
        transform: [
            Rotation { origin.x: view.width / 2; origin.y: view.height / 2; angle: root.animRot },
            Scale { origin.x: view.width / 2; origin.y: view.height / 2; xScale: root.animK * root.animFlip; yScale: root.animK }
        ]
        width: Math.max(1, Math.round(root.shown.w * root.vs))
        height: Math.max(1, Math.round(root.shown.h * root.vs))
        x: Math.round((root.width - width) / 2)
        y: Math.round(root.picTop + (root.height - root.picTop - height) / 2)
        onImageLoaded: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            root.paint(ctx, root.shown, root.vs, width, height, false);
            if (root.tool === "crop" && root.crop) {
                // the parts cut away, dimmed
                var c = root.crop, s = root.vs;
                ctx.fillStyle = "rgba(0,0,0,0.55)";
                ctx.fillRect(0, 0, width, c.y * s);
                ctx.fillRect(0, (c.y + c.h) * s, width, height - (c.y + c.h) * s);
                ctx.fillRect(0, c.y * s, c.x * s, c.h * s);
                ctx.fillRect((c.x + c.w) * s, c.y * s, width - (c.x + c.w) * s, c.h * s);
                ctx.strokeStyle = "#FFFFFF"; ctx.lineWidth = 2; ctx.strokeRect(c.x * s, c.y * s, c.w * s, c.h * s);
            }
            if (root.drag) {
                var d = root.drag, k = root.vs;
                ctx.strokeStyle = root.tool === "rect" ? root.pen : "#FFFFFF"; ctx.lineWidth = 2;
                ctx.setLineDash([6, 4]);
                ctx.strokeRect((Math.min(d.x0, d.x1) - root.shown.x) * k, (Math.min(d.y0, d.y1) - root.shown.y) * k, Math.abs(d.x1 - d.x0) * k, Math.abs(d.y1 - d.y0) * k);
            }
        }
    }
    property var drag: null               // a box being dragged (crop, rect, pixel)
    property var stroke: null             // the path being drawn
    // the picture's own clicks: draw, boxes, a new text or emoji; elsewhere, unselect
    MouseArea {
        anchors.fill: view
        cursorShape: root.tool === "text" ? Qt.IBeamCursor : root.tool === "" ? Qt.ArrowCursor : Qt.CrossCursor
        onPressed: (m) => {
            var p = root.toFrame(view.x + m.x, view.y + m.y);
            root.commitText();
            root.selected = -1;
            if (root.tool === "draw") { root.push(); root.stroke = { k: "path", c: "" + root.pen, s: root.penSize / root.vs * 1.5, pts: [p] }; root.ops = root.ops.concat([root.stroke]); view.requestPaint(); }
            else if (root.tool === "crop" || root.tool === "rect" || root.tool === "pixel") root.drag = { x0: p.x, y0: p.y, x1: p.x, y1: p.y };
            else if (root.tool === "emoji") { root.push(); root.selected = root.addObj({ k: "emoji", t: root.emoji, x: p.x, y: p.y, z: 64 / root.vs }); root.changed(); }
            else if (root.tool === "text") root.newText(p);
        }
        onPositionChanged: (m) => {
            var p = root.toFrame(view.x + m.x, view.y + m.y);
            if (root.stroke) { root.stroke.pts.push(p); view.requestPaint(); }
            else if (root.drag) { root.drag = { x0: root.drag.x0, y0: root.drag.y0, x1: p.x, y1: p.y }; view.requestPaint(); }
        }
        onReleased: {
            if (root.stroke) { root.stroke = null; root.changed(); return; }
            var d = root.drag;
            root.drag = null;
            if (!d) return;
            var b = { x: Math.max(0, Math.min(d.x0, d.x1)), y: Math.max(0, Math.min(d.y0, d.y1)) };
            b.w = Math.min(root.rw, Math.max(d.x0, d.x1)) - b.x; b.h = Math.min(root.rh, Math.max(d.y0, d.y1)) - b.y;
            if (b.w < 4 || b.h < 4) { view.requestPaint(); return; }
            root.push();
            if (root.tool === "crop") root.crop = b;
            else if (root.tool === "rect") root.selected = root.addObj({ k: "rect", c: "" + root.pen, lw: root.penSize / root.vs * 1.5, x: b.x + b.w / 2, y: b.y + b.h / 2, w: b.w, h: b.h });
            else root.ops = root.ops.concat([{ k: "pixel", x: b.x, y: b.y, w: b.w, h: b.h }]);
            root.changed();
        }
    }

    // ---- the objects, over the picture (clipped to it) ------------------------------------------
    readonly property bool objectsLive: tool !== "draw" && tool !== "pixel" && tool !== "crop"
    property bool moving: false           // an object being dragged: the bin shows
    property bool overBin: false
    Item {
        id: objLayer
        x: view.x; y: view.y; width: view.width; height: view.height
        transform: [
            Rotation { origin.x: objLayer.width / 2; origin.y: objLayer.height / 2; angle: root.animRot },
            Scale { origin.x: objLayer.width / 2; origin.y: objLayer.height / 2; xScale: root.animK * root.animFlip; yScale: root.animK }
        ]
        clip: true
        Repeater {
            model: objs
            Item {
                id: o
                readonly property bool sel: root.selected === model.oid
                visible: root.editing !== model.oid
                width: model.k === "rect" ? model.w * root.vs : label.implicitWidth + 8
                height: model.k === "rect" ? model.h * root.vs : label.implicitHeight
                x: (model.x - root.shown.x) * root.vs - width / 2
                y: (model.y - root.shown.y) * root.vs - height / 2
                scale: model.s
                rotation: model.r
                Rectangle {
                    visible: model.k === "rect"
                    anchors.fill: parent
                    color: "transparent"; border.color: model.c; border.width: Math.max(1, model.lw * root.vs)
                }
                Text {
                    id: label
                    visible: model.k !== "rect"
                    anchors.centerIn: parent
                    text: model.k === "rect" ? "" : model.t
                    color: model.c
                    horizontalAlignment: Text.AlignHCenter
                    lineHeight: 1.2
                    font.pixelSize: Math.max(4, model.z * root.vs)
                    font.bold: model.k === "text"
                    font.family: model.k === "emoji" ? "Noto Color Emoji" : "Roboto"
                    style: model.k === "text" ? Text.Outline : Text.Normal
                    styleColor: root.outlineOf(model.c)
                }
                // the selection: a dashed frame and the corner handle (size and turn)
                Rectangle {
                    visible: o.sel
                    anchors.fill: parent; anchors.margins: -6 / model.s
                    color: "transparent"; border.color: "#FFFFFF"; border.width: 1.5 / model.s
                    radius: 4 / model.s
                }
                MouseArea {
                    anchors.fill: parent; anchors.margins: -6
                    enabled: root.objectsLive
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property var start: null
                    onPressed: (m) => {
                        root.commitText();
                        root.selected = model.oid;
                        if (model.k !== "emoji") root.pen = model.c;
                        var p = mapToItem(objLayer, m.x, m.y);
                        root.push();
                        start = { px: p.x, py: p.y, x: model.x, y: model.y, moved: false };
                    }
                    onPositionChanged: (m) => {
                        if (!start) return;
                        var p = mapToItem(objLayer, m.x, m.y);
                        if (!start.moved && Math.abs(p.x - start.px) + Math.abs(p.y - start.py) < 3) return;
                        start.moved = true;
                        root.moving = true;
                        root.setObj(model.oid, "x", start.x + (p.x - start.px) / root.vs);
                        root.setObj(model.oid, "y", start.y + (p.y - start.py) / root.vs);
                        var q = mapToItem(root, m.x, m.y);
                        root.overBin = bin.contains(bin.mapFromItem(root, q.x, q.y));
                    }
                    onReleased: {
                        var s = start; start = null;
                        root.moving = false;
                        if (root.overBin) { root.overBin = false; root.dropPush(); root.removeObj(model.oid); return; }
                        if (s && s.moved) root.changed(); else root.dropPush();
                    }
                    onDoubleClicked: if (model.k === "text") root.editText(model.oid)
                }
                // size and turn: drag the corner — the distance to the centre scales, the angle turns
                Rectangle {
                    visible: o.sel && root.objectsLive
                    width: 18 / model.s; height: width; radius: width / 2
                    x: parent.width + 6 / model.s - width / 2; y: parent.height + 6 / model.s - height / 2
                    color: "#FFFFFF"; border.color: root.accent; border.width: 2 / model.s
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -6
                        cursorShape: Qt.SizeFDiagCursor
                        property var start: null
                        function centre() { return o.mapToItem(objLayer, o.width / 2, o.height / 2); }
                        onPressed: (m) => {
                            var c = centre(), p = mapToItem(objLayer, m.x, m.y);
                            root.push();
                            start = { d: Math.max(1, Math.hypot(p.x - c.x, p.y - c.y)), a: Math.atan2(p.y - c.y, p.x - c.x), s: model.s, r: model.r, c: c };
                        }
                        onPositionChanged: (m) => {
                            if (!start) return;
                            var p = mapToItem(objLayer, m.x, m.y), c = start.c;
                            var d = Math.hypot(p.x - c.x, p.y - c.y), a = Math.atan2(p.y - c.y, p.x - c.x);
                            root.setObj(model.oid, "s", Math.max(0.2, Math.min(12, start.s * d / start.d)));
                            root.setObj(model.oid, "r", start.r + (a - start.a) * 180 / Math.PI);
                        }
                        onReleased: { start = null; root.changed(); }
                    }
                }
            }
        }
    }
    // the bin: drop an object on it to take it away
    Rectangle {
        id: bin
        visible: root.moving
        width: 56; height: 56; radius: 28
        anchors.horizontalCenter: parent.horizontalCenter
        y: view.y + view.height - height - 16
        color: root.overBin ? "#E6FF3B30" : "#99000000"
        border.color: "#FFFFFF"; border.width: root.overBin ? 2 : 0
        scale: root.overBin ? 1.15 : 1
        Behavior on scale { NumberAnimation { duration: 120 } }
        Image { anchors.centerIn: parent; width: 26; height: 26; source: root.iconDelete }
    }

    // ---- a text: typed in a field where it goes; Enter (or a click elsewhere) puts it there --------
    property var textAt: null
    function newText(p) {
        editing = -1; textAt = p;
        field.text = ""; field.color = pen; field.font.pixelSize = 36;
        placeField(view.x + (p.x - shown.x) * vs, view.y + (p.y - shown.y) * vs);
    }
    function editText(oid) {
        var o = obj(oid);
        if (!o) return;
        editing = oid; textAt = { x: o.x, y: o.y };
        field.text = o.t; field.color = o.c; field.font.pixelSize = Math.max(12, Math.min(72, o.z * o.s * vs));
        placeField(view.x + (o.x - shown.x) * vs, view.y + (o.y - shown.y) * vs);
    }
    function placeField(cx, cy) { field.x = cx - field.width / 2; field.y = cy - field.height / 2; field.visible = true; field.forceActiveFocus(); field.selectAll(); }
    function commitText() {
        if (!field.visible) return;
        field.visible = false;
        var t = field.text.trim();
        if (editing >= 0) {
            var o = obj(editing), oid = editing;
            editing = -1;
            if (!o) return;
            if (t === "") { removeObj(oid); return; }
            if (t !== o.t || ("" + field.color).toUpperCase() !== ("" + o.c).toUpperCase()) { push(); setObj(oid, "t", t); setObj(oid, "c", "" + field.color); changed(); }
            selected = oid;
            return;
        }
        if (t === "" || !textAt) return;
        push();
        selected = addObj({ k: "text", t: t, c: "" + pen, x: textAt.x, y: textAt.y, z: 36 / vs });
        changed();
    }
    TextField {
        id: field
        visible: false
        width: Math.max(200, Math.min(root.width - 40, contentWidth + 40)); height: font.pixelSize * 1.6
        font.pixelSize: 36; font.bold: true; font.family: "Roboto"
        horizontalAlignment: TextInput.AlignHCenter
        background: Rectangle { color: "#66000000"; radius: 8 }
        onAccepted: root.commitText()
        Keys.onEscapePressed: { visible = false; root.editing = -1; }
    }

    // the keys: Delete takes the selected object away, Ctrl+Z / Ctrl+Shift+Z undo and redo, Esc unselects
    focus: true
    Keys.onPressed: (e) => {
        if (field.visible) return;
        if ((e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) && selected >= 0) { removeObj(selected); e.accepted = true; }
        else if (e.key === Qt.Key_Z && (e.modifiers & Qt.ControlModifier)) { if (e.modifiers & Qt.ShiftModifier) redo(); else undo(); e.accepted = true; }
        else if (e.key === Qt.Key_Escape && selected >= 0) { selected = -1; e.accepted = true; }
    }

    // ---- the flattened picture: drawn at full size (≤ 2560 px) off screen, saved to a file -------
    readonly property var frame: crop ? crop : { x: 0, y: 0, w: Math.max(1, rw), h: Math.max(1, rh) }
    readonly property real outScale: Math.min(1, 2560 / Math.max(frame.w, frame.h))
    property string target: ""
    property int seq: 0
    Item {
        width: 1; height: 1; clip: true; opacity: 0
        Canvas {
            id: out
            width: Math.max(1, Math.round(root.frame.w * root.outScale))
            height: Math.max(1, Math.round(root.frame.h * root.outScale))
            renderStrategy: Canvas.Immediate
            onPaint: {
                root.paint(getContext("2d"), root.frame, root.outScale, width, height, true);
                if (root.target !== "") { var t = root.target; root.target = ""; if (save(t)) root.saved(t); }
            }
        }
    }
    Timer { id: saveSoon; interval: 400; onTriggered: root.flatten("") }
    // writes the edited picture to `path` ("" = a new file in outDir) and reports it
    property string downloadTo: ""
    function flatten(path) {
        if (natW === 0) return;
        seq++;
        target = path !== "" ? path : outDir + "/edited-" + Date.now() + "-" + seq + ".jpg";
        out.requestPaint();
    }
    function saved(p) {
        if (p === downloadTo) { downloadTo = ""; notice("Salvo em " + p); return; }
        edited(p);
    }
    function download() {
        commitText();
        var dir = ("" + StandardPaths.writableLocation(StandardPaths.DownloadLocation)).replace("file://", "");
        downloadTo = dir + "/WhatsApp Image " + Qt.formatDateTime(new Date(), "yyyy-MM-dd 'at' HH.mm.ss") + ".jpg";
        flatten(downloadTo);
    }
}
