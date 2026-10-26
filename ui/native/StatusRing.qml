// The ring around a contact's picture in the status list, as WhatsApp draws it: one arc per status,
// clockwise from the top with a small gap between them; the ones already seen in grey, the new
// ones in the accent colour. One status is the whole circle.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property var seen: []                 // one entry per status, oldest first: true when seen
    property string accent: "#21C063"     // the theme's colours: "#rrggbb" or "rgba(r, g, b, a)"
    property string muted: "#8696A0"
    function qc(c) {
        var m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/.exec(c || "")
        return m ? Qt.rgba(m[1] / 255, m[2] / 255, m[3] / 255, m[4] === undefined ? 1 : +m[4]) : c
    }
    property real stroke: 2
    implicitWidth: 48
    implicitHeight: 48
    readonly property int n: Math.max(1, seen ? seen.length : 0)
    readonly property real gap: n > 1 ? Math.min(6, 120 / n) : 0      // degrees between arcs
    readonly property real sweep: 360 / n - gap
    readonly property real r: (Math.min(width, height) - stroke) / 2

    Repeater {
        model: root.n
        delegate: Shape {
            required property int index
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: root.stroke
                strokeColor: root.qc(root.seen && root.seen[index] ? root.muted : root.accent)
                fillColor: "transparent"
                capStyle: ShapePath.FlatCap
                PathAngleArc {
                    centerX: root.width / 2
                    centerY: root.height / 2
                    radiusX: root.r
                    radiusY: root.r
                    startAngle: -90 + root.gap / 2 + index * (root.sweep + root.gap)
                    sweepAngle: root.sweep
                }
            }
        }
    }
}
