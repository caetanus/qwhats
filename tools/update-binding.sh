#!/bin/bash
# Refresh third_party/solid-qml-d from ../solid-qml-d: the solid-qml host (source/solidqml/host.d) and
# the DSide binding its reggae build generated (generated/qt-6.11/solidqml — xiboca's output for this
# Qt). Kept in this repository so the AppImage builds (tools/manylinux.sh, CI) need neither the private
# solid-qml-d checkout nor DSide's generator and libclang. Machine paths become placeholders, filled
# in at build time: @SOLIDQML@ (the solid-qml checkout), @QTINC@ (Qt's include directory).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sqd=${SOLIDQMLD:-$here/../solid-qml-d}
sq=$(cd "${SOLIDQML:-$here/../solid-qml-native}" && pwd)
qtinc=$(pkg-config --variable=includedir Qt6Core)
dst=$here/third_party/solid-qml-d
rm -rf "$dst"
mkdir -p "$dst/source/solidqml" "$dst/generated/qt-6.11"
cp "$sqd/source/solidqml/host.d" "$dst/source/solidqml/"
cp "$sqd/LICENSE"* "$dst/" 2>/dev/null || true
cp -r "$sqd/generated/qt-6.11/solidqml" "$dst/generated/qt-6.11/"
rm -f "$dst/generated/qt-6.11/solidqml/"*.tsv "$dst/generated/qt-6.11/solidqml/coverage"*   # the generator's reports
sed -i -e "s#$sq/#@SOLIDQML@/#g" -e "s#$qtinc/#@QTINC@/#g" "$dst/generated/qt-6.11/solidqml/"*.cpp
grep -rl "$HOME" "$dst" && { echo "a machine path is left in the binding" >&2; exit 1; }
echo "solid-qml-d $(git -C "$sqd" log --oneline -1 | cut -c1-60) (binding for Qt $(pkg-config --modversion Qt6Core))" > "$dst/SOURCE"
echo "updated $dst: $(cat "$dst/SOURCE")"
