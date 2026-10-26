// The attach menu's file choosers (Documento; Fotos e vídeos), as the system's file dialog. The UI
// asks by setting `request` ("document:N" / "media:N" — the number makes each ask a change).
import QtQuick
import QtQuick.Dialogs
import QtCore

Item {
    id: root
    property string request: ""
    signal picked(string path, string kind)
    implicitWidth: 0
    implicitHeight: 0
    property string kind: ""

    onRequestChanged: {
        if (request === "") return;
        kind = request.split(":")[0];
        dialog.nameFilters = kind === "media"
            ? ["Fotos e vídeos (*.jpg *.jpeg *.png *.webp *.gif *.mp4 *.mov *.mkv *.webm *.3gp)"]
            : kind === "avatar" ? ["Imagens (*.jpg *.jpeg *.png *.webp)"]
            : ["Todos os arquivos (*)"];
        dialog.open();
    }
    FileDialog {
        id: dialog
        title: root.kind === "media" ? "Fotos e vídeos" : root.kind === "avatar" ? "Foto do perfil" : "Documento"
        currentFolder: StandardPaths.writableLocation(root.kind === "document" ? StandardPaths.DocumentsLocation : StandardPaths.PicturesLocation)
        onAccepted: {
            var p = selectedFile.toString();
            if (p.indexOf("file://") === 0) p = decodeURIComponent(p.substring(7));
            root.picked(p, root.kind);
        }
    }
}
