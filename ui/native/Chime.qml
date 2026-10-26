// A short chime WhatsApp plays around a run of voice notes: one sound between consecutive notes
// (advance), a different one when the run ends. `file` names which (chime.ogg / chime-end.ogg).
import QtQuick
import QtMultimedia

Item {
    id: root
    property string file: "chime.ogg"
    property bool muted: false
    signal done()
    function ring() { player.stop(); player.play(); }
    MediaPlayer {
        id: player
        source: Qt.resolvedUrl(root.file)
        audioOutput: AudioOutput { muted: root.muted }
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia) root.done()
    }
}
