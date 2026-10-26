// Recording a voice note, as WhatsApp Web's composer does: the microphone into an Ogg/Opus file
// (what WhatsApp's voice notes are). `recording` starts and stops it; `finished` hands over the
// file and its length when it stops with send=true, and the file is dropped when it is discarded.
import QtQuick
import QtMultimedia

Item {
    id: root
    property bool recording: false
    property bool send: true            // false when stopped: discard
    property string dir: ""
    readonly property int seconds: Math.floor(rec.duration / 1000)
    signal finished(string path, int seconds)
    signal failed(string message)
    implicitWidth: 0
    implicitHeight: 0

    CaptureSession {
        audioInput: AudioInput {}
        recorder: MediaRecorder {
            id: rec
            mediaFormat {
                fileFormat: MediaFormat.Ogg
                audioCodec: MediaFormat.AudioCodec.Opus
            }
            quality: MediaRecorder.NormalQuality
            onErrorOccurred: (e, s) => root.failed(s)
            onRecorderStateChanged: {
                if (recorderState !== MediaRecorder.StoppedState) return;
                var p = actualLocation.toString();
                if (p.indexOf("file://") === 0) p = decodeURIComponent(p.substring(7));
                if (root.send && p !== "") root.finished(p, Math.max(1, Math.round(duration / 1000)));
            }
        }
    }
    onRecordingChanged: {
        if (recording) {
            rec.outputLocation = "file://" + dir + "/voice-" + Date.now() + ".ogg";
            rec.record();
        } else {
            rec.stop();
        }
    }
}
