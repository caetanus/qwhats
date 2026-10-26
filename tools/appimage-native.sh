#!/bin/bash
# Build QWhats-x86_64.AppImage of the NATIVE client: qwhats-native-ldc2 (the solid-qml UI, no
# Chromium), its UI (qml-native/), WhatsApp Web's artwork (assets/wa/, tools/wa-icons.mjs), the D core
# beside it (qwhats-dcore, started by the app), libsolidqml and the Qt it was built against.
# DSide and libsolidqml use Qt's private API, stable only within one exact Qt version: the AppImage
# runs its own Qt whatever the machine has.
#
#   DCORE=path/to/qwhats-dcore tools/appimage-native.sh [LIBDIR]
#     LIBDIR: where libsolidqml.so.0 is (default: solid-qml-native/build)
#
# Same method as tools/appimage.sh (linuxdeploy decides what to bundle, every ELF goes back to its
# pristine original, AppRun hands out the bundled libraries through LD_LIBRARY_PATH; a smoke test
# renders one frame before the AppImage is kept). The core runs the system's ffmpeg for voice notes
# and video thumbnails with the original LD_LIBRARY_PATH (QWHATS_ORIG_LD_LIBRARY_PATH).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
lib=${1:-$here/../solid-qml-native/build}
lib=$(cd "$lib" && pwd)
dcore=${DCORE:-${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/qwhats-dcore/qwhats-dcore}
tools=${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/tools
work=${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/appdir-native
out=$here/${OUT_NAME:-QWhats-x86_64.AppImage}
qmake=${QMAKE:-/usr/lib/qt6/bin/qmake}
qt_libs=$("$qmake" -query QT_INSTALL_LIBS); qt_plugins=$("$qmake" -query QT_INSTALL_PLUGINS)
qt_qml=$("$qmake" -query QT_INSTALL_QML)
appimagetool=${APPIMAGETOOL:-appimagetool}

[ -x "$here/qwhats-native-ldc2" ] || { echo "build qwhats-native-ldc2 first" >&2; exit 1; }
[ -e "$here/qml-native/App.generated.qml" ] || { echo "build the UI first (./build ui-native)" >&2; exit 1; }
[ -x "$dcore" ] || { echo "no qwhats-dcore at $dcore (DCORE=…)" >&2; exit 1; }
[ -e "$here/assets/wa/icons/chats.svg" ] || { echo "no assets/wa (tools/wa-icons.mjs)" >&2; exit 1; }
[ -e "$lib/libsolidqml.so.0" ] || { echo "no libsolidqml.so.0 in $lib" >&2; exit 1; }

mkdir -p "$tools"
for t in linuxdeploy linuxdeploy-plugin-qt; do
    f=$tools/$t-x86_64.AppImage
    [ -s "$f" ] || curl -sSL -o "$f" "https://github.com/linuxdeploy/$t/releases/download/continuous/$t-x86_64.AppImage"
    chmod +x "$f"
done

rm -rf "$work"
mkdir -p "$work/usr/bin/assets" "$work/usr/lib" "$work/usr/share/applications" "$work/usr/share/icons/hicolor/scalable/apps" \
         "$work/usr/share/icons/hicolor/256x256/apps" "$work/qmlscan"
cp "$here/qwhats-native-ldc2" "$dcore" "$work/usr/bin/"
cp -r "$here/qml-native" "$work/usr/bin/qml-native"
rm -f "$work"/usr/bin/qml-native/*.map
cp -r "$here/assets/wa" "$work/usr/bin/assets/wa"
[ -d "$here/assets/icons" ] && cp -r "$here/assets/icons" "$work/usr/bin/assets/icons"
cp -a "$lib"/libsolidqml.so.0 "$lib"/libsolidqml.so.0.* "$work/usr/lib/"
rm -rf "$work"/usr/lib/*.p
cp "$here/assets/app.svg" "$work/usr/share/icons/hicolor/scalable/apps/qwhats.svg"
rsvg-convert -w 256 -h 256 "$here/assets/app.svg" -o "$work/usr/share/icons/hicolor/256x256/apps/qwhats.png"
cat > "$work/usr/share/applications/qwhats-native.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=QWhats
GenericName=WhatsApp
Comment=WhatsApp para Linux — cliente nativo
Exec=qwhats-native-ldc2 %U
Icon=qwhats
Terminal=false
Categories=Network;InstantMessaging;Chat;
MimeType=x-scheme-handler/whatsapp;
StartupWMClass=qwhats-native
Keywords=whatsapp;chat;mensagens;
EOF
# QML imports the scanner may not see (loaded by name at run time)
cat > "$work/qmlscan/Extra.qml" <<'EOF'
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Effects
import QtQuick.Shapes
import QtQuick.Pdf
import QtQuick.Window
import QtMultimedia
import QtLocation
import QtPositioning
import QtCore
Item {}
EOF

export QMAKE="$qmake"
export QML_SOURCES_PATHS="$work/usr/bin/qml-native:$work/qmlscan"
export EXTRA_QT_MODULES="svg;waylandclient;dbus;pdf;location;positioning;multimedia"
export EXTRA_PLATFORM_PLUGINS="libqwayland.so;libqoffscreen.so"
export EXTRA_QT_PLUGINS="wayland-graphics-integration-client;imageformats;geoservices;multimedia"
export NO_STRIP=1
export APPIMAGE_EXTRACT_AND_RUN=1
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/tmp"
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
cd "$work/.."
"$tools/linuxdeploy-x86_64.AppImage" --appdir "$work" \
    --executable "$work/usr/bin/qwhats-native-ldc2" \
    --executable "$work/usr/bin/qwhats-dcore" \
    --library "$work/usr/lib/libsolidqml.so.0" \
    --desktop-file "$work/usr/share/applications/qwhats-native.desktop" \
    --icon-file "$work/usr/share/icons/hicolor/256x256/apps/qwhats.png" \
    --plugin qt >"$work/../linuxdeploy-native.log" 2>&1 || { tail -30 "$work/../linuxdeploy-native.log" >&2; exit 1; }
rm -rf "$work/qmlscan"
for d in wayland-graphics-integration-client geoservices; do
    [ -d "$qt_plugins/$d" ] && { rm -rf "$work/usr/plugins/$d"; cp -a "$qt_plugins/$d" "$work/usr/plugins/"; }
done

# every ELF back to its pristine original (see tools/appimage.sh: linuxdeploy's patchelf moves
# .dynamic past GNU_RELRO, which glibc 2.44's loader crashes on)
python3 - "$work" "$here" "$lib" "$qt_libs" "$qt_plugins" "$qt_qml" "$dcore" <<'PY'
import os, shutil, sys
work, here, lib, qt_libs, qt_plugins, qt_qml, dcore = sys.argv[1:8]
sys_libs = [d for d in ("/usr/lib", "/usr/lib64", "/lib64", "/usr/lib/x86_64-linux-gnu") if os.path.isdir(d)]
maps = {"usr/bin/qwhats-native-ldc2": here + "/qwhats-native-ldc2", "usr/bin/qwhats-dcore": dcore}
def is_elf(p):
    try:
        with open(p, "rb") as f: return f.read(4) == b"\x7fELF"
    except OSError: return False
restored = missing = 0
for root, dirs, files in os.walk(work):
    for n in files:
        p = os.path.join(root, n)
        if os.path.islink(p) or not is_elf(p): continue
        rel = os.path.relpath(p, work)
        src = maps.get(rel)
        if src is None:
            if rel.startswith("usr/lib/"):
                cand = [os.path.join(lib, n), os.path.join(qt_libs, n)] + [os.path.join(d, n) for d in sys_libs]
                if not any(os.path.exists(c) for c in cand):
                    cand += [os.path.join(d, n) for top in sys_libs for d, _, fs in os.walk(top) if n in fs][:1]
            elif rel.startswith("usr/plugins/"): cand = [qt_plugins + "/" + rel[len("usr/plugins/"):]]
            elif rel.startswith("usr/qml/"): cand = [qt_qml + "/" + rel[len("usr/qml/"):]]
            else: cand = []
            src = next((c for c in cand if os.path.exists(c)), None)
        if src is None:
            print("appimage: no original for", rel); missing += 1; continue
        os.remove(p); shutil.copy2(os.path.realpath(src), p); restored += 1
print("appimage: restored", restored, "ELF files to their originals,", missing, "without one")
PY
rm -f "$work/AppRun"
cat > "$work/AppRun" <<'RUN'
#!/bin/sh
# QWhats' AppImage entry: the bundled libraries first (the app and its core); the original
# LD_LIBRARY_PATH is kept for the system programs they start (ffmpeg, the browser, …).
HERE="$(dirname "$(readlink -f "$0")")"
export QWHATS_ORIG_LD_LIBRARY_PATH="${LD_LIBRARY_PATH-__unset__}"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/qwhats-native-ldc2" "$@"
RUN
chmod +x "$work/AppRun"

# the core with the bundled libraries, offline in a throwaway store: it must start and answer
coretest=$(mktemp -d)
printf '{"id":1,"method":"ping","params":{}}\n' | LD_LIBRARY_PATH="$work/usr/lib" timeout 20 "$work/usr/bin/qwhats-dcore" \
    --offline --store "$coretest/device.db" --chats "$coretest/wa.db" --data "$coretest/d" --cache "$coretest/c" \
    >"$coretest/out" 2>"$coretest/err" || true
grep -q '"result":"pong"' "$coretest/out" || { echo "the core did not start:" >&2; tail -5 "$coretest/err" >&2; exit 1; }
rm -rf "$coretest"

"$appimagetool" --no-appstream "$work" "$out.new" >"$work/../appimagetool-native.log" 2>&1 || { tail -20 "$work/../appimagetool-native.log" >&2; exit 1; }

# Smoke test: one frame offscreen, in a throwaway profile, from the AppImage itself — without a core
# (a fresh profile would start pairing with WhatsApp's servers; the core was checked above)
shot=$(mktemp -d)
trap 'rm -rf "$shot" "$TMPDIR"' EXIT
XDG_DATA_HOME="$shot/data" XDG_CACHE_HOME="$shot/cache" XDG_CONFIG_HOME="$shot/config" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    timeout 90 "$out.new" --core "$shot/no-core" --grab "$shot/frame.png" --grab-ms 6000 >"$shot/log" 2>&1 || true
[ -s "$shot/frame.png" ] || { echo "smoke test failed:" >&2; tail -15 "$shot/log" >&2; exit 1; }
mv "$out.new" "$out"
echo "built: $out ($(du -h "$out" | cut -f1))"
