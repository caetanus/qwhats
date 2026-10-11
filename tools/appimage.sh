#!/bin/bash
# Build QWhats-x86_64.AppImage: the binary, its UI (qml/), libsolidqml and — the point of it — the
# Qt it was built against, QtWebEngine included (Chromium's process, resources, locales). DSide and
# libsolidqml use Qt's private API, stable only within one exact Qt version: a machine with another
# Qt (6.11.1 vs 6.11.2) runs the AppImage's own.
#
#   tools/appimage.sh [LIBDIR]   LIBDIR: where libsolidqml.so.0 is (default: solid-qml-native/build)
#
# Tools: linuxdeploy + linuxdeploy-plugin-qt (downloaded once into ~/.cache/qml-whats-build/tools),
# appimagetool. The result is smoke-tested (one frame offscreen, in a throwaway profile) before it
# is kept. On first run it offers to install itself (~/.local/bin/qwhats + launcher + icon).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
lib=${1:-$here/../solid-qml-native/build}
lib=$(cd "$lib" && pwd)
tools=${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/tools
work=${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/appdir
out=$here/QWhats-x86_64.AppImage
qmake=${QMAKE:-/usr/lib/qt6/bin/qmake}
# Where this Qt keeps things (Arch: /usr/lib/qt6/…; Qt's own installer: <prefix>/plugins, …/qml, …):
qt_libs=$("$qmake" -query QT_INSTALL_LIBS); qt_plugins=$("$qmake" -query QT_INSTALL_PLUGINS)
qt_qml=$("$qmake" -query QT_INSTALL_QML); qt_libexec=$("$qmake" -query QT_INSTALL_LIBEXECS)
appimagetool=${APPIMAGETOOL:-appimagetool}

[ -x "$here/qml-whats-ldc2" ] || { echo "build qml-whats-ldc2 first" >&2; exit 1; }
[ -e "$here/qml/Main.qml" ] || { echo "build the UI first (./build ui)" >&2; exit 1; }
[ -e "$lib/libsolidqml.so.0" ] || { echo "no libsolidqml.so.0 in $lib" >&2; exit 1; }

mkdir -p "$tools"
for t in linuxdeploy linuxdeploy-plugin-qt; do
    f=$tools/$t-x86_64.AppImage
    [ -s "$f" ] || curl -sSL -o "$f" "https://github.com/linuxdeploy/$t/releases/download/continuous/$t-x86_64.AppImage"
    chmod +x "$f"
done

rm -rf "$work"
mkdir -p "$work/usr/bin/qml" "$work/usr/lib" "$work/usr/share/applications" "$work/usr/share/icons/hicolor/scalable/apps" \
         "$work/usr/share/icons/hicolor/256x256/apps" "$work/qmlscan"
cp "$here/qml-whats-ldc2" "$work/usr/bin/"
cp "$here"/qml/*.qml "$work/usr/bin/qml/"
cp -a "$lib"/libsolidqml.so.0 "$lib"/libsolidqml.so.0.* "$work/usr/lib/"
rm -rf "$work"/usr/lib/*.p   # meson's object directories, not libraries
cp "$here/assets/app.svg" "$work/usr/share/icons/hicolor/scalable/apps/qwhats.svg"
rsvg-convert -w 256 -h 256 "$here/assets/app.svg" -o "$work/usr/share/icons/hicolor/256x256/apps/qwhats.png"
cat > "$work/usr/share/applications/qwhats.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=QWhats
GenericName=WhatsApp
Comment=WhatsApp para Linux — chamadas, PDFs, notificações, várias contas
Exec=qml-whats-ldc2 %U
Icon=qwhats
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=qwhats
Keywords=whatsapp;chat;mensagens;
EOF
# QML imports the scanner cannot see in our files: QtWebEngine's default dialogs and menus load
# these at run time.
cat > "$work/qmlscan/Extra.qml" <<'EOF'
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window
import QtWebEngine
import QtWebEngine.ControlsDelegates
import Qt.labs.platform
Item {}
EOF

export QMAKE="$qmake"
export QML_SOURCES_PATHS="$work/usr/bin/qml:$work/qmlscan"
export EXTRA_QT_MODULES="webenginecore;webenginequick;svg;waylandclient;dbus"
export EXTRA_PLATFORM_PLUGINS="libqwayland.so;libqoffscreen.so"
# Wayland's OpenGL (wayland-egl): without it Qt Quick has no GL context on Wayland and aborts
# ("Failed to load client buffer integration: wayland-egl") — the offscreen smoke test cannot see it.
export EXTRA_QT_PLUGINS="wayland-graphics-integration-client"   # offscreen: the smoke test (and --grab)
# (no LD_LIBRARY_PATH into the AppDir: qmake would load the AppDir's QtCore and report the AppDir as
# the Qt prefix — "QT_INSTALL_LIBS: …/appdir/usr/lib" — and find no plugins there)
export NO_STRIP=1           # Qt's private-API symbols must stay as they are
# AppImages (linuxdeploy's own, and ours in the smoke test) extract themselves into $TMPDIR; /tmp is
# RAM (tmpfs) and an extraction of ours is 600 MB: they go to disk instead, removed at the end.
export APPIMAGE_EXTRACT_AND_RUN=1
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/qml-whats-build/tmp"
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
cd "$work/.."
"$tools/linuxdeploy-x86_64.AppImage" --appdir "$work" \
    --executable "$work/usr/bin/qml-whats-ldc2" \
    --library "$work/usr/lib/libsolidqml.so.0" \
    --desktop-file "$work/usr/share/applications/qwhats.desktop" \
    --icon-file "$work/usr/share/icons/hicolor/256x256/apps/qwhats.png" \
    --plugin qt >"$work/../linuxdeploy.log" 2>&1 || { tail -30 "$work/../linuxdeploy.log" >&2; exit 1; }
rm -rf "$work/qmlscan"
# Wayland's OpenGL (wayland-egl): without it Qt Quick has no GL context on Wayland and aborts
# ("Failed to load client buffer integration: wayland-egl") — the offscreen smoke test cannot see it,
# and linuxdeploy-plugin-qt does not deploy it. Its libraries are already in (Qt6WaylandClient) or the
# system's (EGL, libwayland-egl).
cp -a "$qt_plugins/wayland-graphics-integration-client" "$work/usr/plugins/"

# linuxdeploy's patchelf rewrote every ELF's RUNPATH — and in doing so moved .dynamic into a new LOAD
# segment past GNU_RELRO, which glibc 2.44's loader crashes on (seen: dlopen of the QtWebEngine
# plugin, relocating libdatrie.so.1). Its choice of WHAT to bundle is kept; every ELF goes back to
# its pristine original, and AppRun (below) gives the bundled libraries through LD_LIBRARY_PATH.
python3 - "$work" "$here" "$lib" "$qt_libs" "$qt_plugins" "$qt_qml" "$qt_libexec" <<'PY'
import os, shutil, sys
work, here, lib, qt_libs, qt_plugins, qt_qml, qt_libexec = sys.argv[1:8]
sys_libs = [d for d in ("/usr/lib", "/usr/lib64", "/lib64", "/usr/lib/x86_64-linux-gnu") if os.path.isdir(d)]
maps = {"usr/bin/qml-whats-ldc2": here + "/qml-whats-ldc2", "usr/libexec/QtWebEngineProcess": qt_libexec + "/QtWebEngineProcess"}
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
# QWhats' AppImage entry: the bundled libraries first; the original LD_LIBRARY_PATH is kept for the
# programs QWhats starts (source/qmlwhats/env.d childEnv), which must not load the bundled Qt.
HERE="$(dirname "$(readlink -f "$0")")"
export QWHATS_ORIG_LD_LIBRARY_PATH="${LD_LIBRARY_PATH-__unset__}"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/qml-whats-ldc2" "$@"
RUN
chmod +x "$work/AppRun"

# The app finds its UI next to its binary (qml/), as in the build tree.
"$appimagetool" --no-appstream "$work" "$out.new" >"$work/../appimagetool.log" 2>&1 || { tail -20 "$work/../appimagetool.log" >&2; exit 1; }

# Smoke test: one frame offscreen, in a throwaway profile, from the AppImage itself.
shot=$(mktemp -d)
trap 'rm -rf "$shot" "$TMPDIR"' EXIT
# (as root — a container build — Chromium refuses its sandbox; no GPU there either: software rendering)
[ "$(id -u)" = 0 ] && export QTWEBENGINE_DISABLE_SANDBOX=1
XDG_DATA_HOME="$shot/data" XDG_CACHE_HOME="$shot/cache" XDG_CONFIG_HOME="$shot/config" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    timeout 90 "$out.new" --new-instance --url about:blank --grab "$shot/frame.png" --grab-ms 3000 >"$shot/log" 2>&1 || true
[ -s "$shot/frame.png" ] || { echo "smoke test failed:" >&2; tail -15 "$shot/log" >&2; exit 1; }
mv "$out.new" "$out"
echo "built: $out ($(du -h "$out" | cut -f1))"
