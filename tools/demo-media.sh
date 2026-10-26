#!/bin/bash
# The demo account's media (core/demo/, embedded in qwhats-core): made here, nobody's real files —
# a voice note (espeak-ng), a photo, a short video and a 3-page PDF.
set -euo pipefail
out=$(cd "$(dirname "$0")/.." && pwd)/core/demo
tmp=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/demo-media.XXXX")
trap 'rm -rf "${tmp:?}"' EXIT
mkdir -p "$out"
espeak-ng -v pt-br -s 150 -w "$tmp/voice.wav" "Oi! Tô saindo agora do trabalho, chego aí em uns vinte minutos. Quer que eu leve alguma coisa?"
ffmpeg -loglevel error -y -i "$tmp/voice.wav" -ac 1 -ar 48000 -c:a libopus -b:a 24k "$out/voice.ogg"
ffmpeg -loglevel error -y -f lavfi -i "gradients=s=1280x960:c0=0x2e7d32:c1=0xf9a825:x0=0:y0=0:x1=1280:y1=960:d=1" -frames:v 1 \
  -vf "drawtext=text='Praia de domingo':fontsize=72:fontcolor=white:x=(w-tw)/2:y=(h-th)/2" "$out/photo.jpg"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=480x270:d=4:r=20" -f lavfi -i "sine=f=440:d=4" -c:v libx264 -crf 34 -pix_fmt yuv420p \
  -c:a aac -b:a 48k -shortest -movflags +faststart "$out/video.mp4"
for i in 1 2 3; do
  magick -size 1240x1754 xc:white -font DejaVu-Sans -pointsize 64 -fill black -annotate +120+240 "Relatório trimestral" \
    -pointsize 36 -annotate +120+360 "Página $i de 3" "$tmp/p$i.png" 2>/dev/null || \
  magick -size 1240x1754 xc:white -pointsize 64 -fill black -annotate +120+240 "Relatorio trimestral" -pointsize 36 -annotate +120+360 "Pagina $i de 3" "$tmp/p$i.png"
done
magick "$tmp/p1.png" "$tmp/p2.png" "$tmp/p3.png" -quality 60 "$out/relatorio.pdf"
# what WhatsApp sends inline: small JPEG thumbnails, the voice note's 64-sample waveform, durations
magick "$out/photo.jpg" -resize 72x "$out/photo.thumb.jpg"
ffmpeg -loglevel error -y -i "$out/video.mp4" -frames:v 1 -vf scale=72:-1 "$out/video.thumb.jpg"
magick "$tmp/p1.png" -resize 72x "$out/relatorio.thumb.jpg"
ffmpeg -loglevel error -y -i "$out/voice.ogg" -ac 1 -ar 8000 -f s16le "$tmp/voice.raw"
python3 - "$tmp/voice.raw" "$out" <<'PY'
import sys, struct, json, base64, subprocess
raw = open(sys.argv[1], "rb").read()
s = struct.unpack("<%dh" % (len(raw) // 2), raw)
n = 64; step = max(1, len(s) // n)
peaks = [max(abs(x) for x in s[i * step:(i + 1) * step] or [0]) for i in range(n)]
top = max(peaks) or 1
wave = bytes(int(p * 100 / top) for p in peaks)
def dur(f):
    return round(float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]).decode()))
out = sys.argv[2]
json.dump({"voice": {"duration": dur(out + "/voice.ogg"), "waveform": base64.b64encode(wave).decode()},
           "video": {"duration": dur(out + "/video.mp4"), "width": 480, "height": 270},
           "photo": {"width": 1280, "height": 960}, "pdf": {"pages": 3}}, open(out + "/meta.json", "w"))
PY
ls -la "$out"
