// The map of a location message, when the message brings no map picture of its own (WhatsApp's
// phones usually send one; the core hands it over as `thumbnail` and the bubble shows that
// instead). Esri's Light Gray / Dark Gray canvases following the theme (look.mapProviders has the
// provider files: OSM's own tiles look dated), through Qt Location, centred on the place with
// WhatsApp's red pin; not interactive — a click opens the place in the browser, as WhatsApp Web does.
import QtQuick
import QtLocation
import QtPositioning

Item {
    id: root
    property real lat: 0
    property real lng: 0
    property string pinIcon: ""
    property string cacheDir: ""
    property string providers: ""       // file:// folder with "street" (light) and "night-transit" (dark)
    property int boxWidth: 270
    property int boxHeight: 150
    property bool live: false
    property bool dark: true
    signal clicked()
    implicitWidth: boxWidth
    implicitHeight: boxHeight
    clip: true

    Plugin {
        id: osm
        name: "osm"
        PluginParameter { name: "osm.useragent"; value: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36" }
        PluginParameter { name: "osm.mapping.providersrepository.address"; value: root.providers + "/" }
        PluginParameter { name: "osm.mapping.cache.directory"; value: root.cacheDir + (root.dark ? "/dark" : "/light") }
    }
    Map {
        id: map
        anchors.fill: parent
        plugin: osm
        // the osm plugin's map types are its provider files: Street (light) and Night Transit (dark)
        activeMapType: pick(supportedMapTypes, root.dark ? MapType.TransitMap : MapType.StreetMap)
        function pick(types, style) {
            for (var i = 0; i < types.length; i++) if (types[i].style === style && (style !== MapType.TransitMap || types[i].night)) return types[i];
            return types[0];
        }
        center: QtPositioning.coordinate(root.lat, root.lng)
        zoomLevel: 16
        copyrightsVisible: false
        MapQuickItem {
            coordinate: QtPositioning.coordinate(root.lat, root.lng)
            anchorPoint.x: 20
            anchorPoint.y: 38
            sourceItem: Image { width: 40; height: 40; source: root.pinIcon; sourceSize: Qt.size(40, 40) }
        }
    }
    // the providers' terms ask for the credit on the map
    Text {
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 3
        text: "© Esri, OpenStreetMap"
        font.pixelSize: 8; color: root.dark ? "#aaa" : "#555"
        Rectangle { anchors.fill: parent; anchors.margins: -2; color: root.dark ? "#99000000" : "#b3ffffff"; z: -1 }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.clicked() }
}
