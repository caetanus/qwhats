#!/bin/sh
# Install QWhats for daily use: a frozen copy of a build that works — the binary, its UI (qml/) and
# the libsolidqml it ran with — under ~/.local/share/qml-whats/app, started by ~/.local/bin/qwhats,
# with a launcher (qwhats.desktop) and its icon. The installed app never depends on the development
# trees: a solid-qml-native build caught mid-change does not keep it from starting. (The pattern is
# solid-mail's tools/install.sh.)
#
#   tools/install.sh [LIBDIR]   LIBDIR: where libsolidqml.so.0 is (default: solid-qml-native/build)
#
# The copy is smoke-tested first (one frame offscreen, in a throwaway profile), then swapped in
# whole; the previous one stays as app.old. The session (the WhatsApp login) is not touched.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
lib=${1:-$here/../solid-qml-native/build}
lib=$(cd "$lib" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
dest=$data/qml-whats/app
bin=$HOME/.local/bin/qwhats

[ -e "$lib/libsolidqml.so.0" ] || { echo "no libsolidqml.so.0 in $lib" >&2; exit 1; }
[ -x "$here/qml-whats-ldc2" ] || { echo "build qml-whats-ldc2 first" >&2; exit 1; }
[ -e "$here/qml/Main.qml" ] || { echo "build the UI first (./build ui)" >&2; exit 1; }

shot=$(mktemp -d)
trap 'rm -rf "$shot"' EXIT
XDG_DATA_HOME="$shot/data" XDG_CACHE_HOME="$shot/cache" XDG_CONFIG_HOME="$shot/config" \
LD_LIBRARY_PATH="$lib" QT_QPA_PLATFORM=offscreen timeout 60 "$here/qml-whats-ldc2" --new-instance \
    --url about:blank --grab "$shot/frame.png" --grab-ms 2500 >"$shot/log" 2>&1 || true
[ -s "$shot/frame.png" ] || { echo "smoke test failed:" >&2; tail -5 "$shot/log" >&2; exit 1; }

new=$dest.new
rm -rf "$new"
mkdir -p "$new/lib"
cp -f "$here/qml-whats-ldc2" "$new/"
cp -rf "$here/qml" "$new/"
cp -af "$lib"/libsolidqml.so* "$new/lib/"
rm -rf "$new/lib/"*.p   # meson's object directories, not libraries

rm -rf "$dest.old"
[ -d "$dest" ] && mv "$dest" "$dest.old"
mv "$new" "$dest"

mkdir -p "$(dirname "$bin")"
rm -f "$bin"
cat >"$bin" <<EOS
#!/bin/sh
# QWhats, as installed by tools/install.sh: its own libsolidqml copy before the build tree's.
exec env LD_LIBRARY_PATH="$dest/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "$dest/qml-whats-ldc2" "\$@"
EOS
chmod +x "$bin"

icons=$data/icons/hicolor/scalable/apps
mkdir -p "$icons" "$data/applications"
cp -f "$here/assets/app.svg" "$icons/qwhats.svg"
cat >"$data/applications/qwhats.desktop" <<EOS
[Desktop Entry]
Type=Application
Name=QWhats
GenericName=WhatsApp
Comment=WhatsApp para Linux — chamadas, PDFs, notificações
Exec=$bin %U
Icon=qwhats
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=qwhats
Keywords=whatsapp;chat;mensagens;
EOS
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" 2>/dev/null || true
echo "installed: $bin -> $dest (libsolidqml from $lib)"
