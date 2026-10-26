#!/usr/bin/env node
// WhatsApp Web's own icons, for the native UI (identical look). They are WhatsApp's artwork, so they are
// NOT kept in this repository: this pulls them out of WhatsApp Web's JavaScript bundles (a directory of
// .js files, as downloaded from static.whatsapp.net) and writes one SVG per icon, painted with currentColor.
//
//     tools/wa-icons.mjs BUNDLE_DIR OUT_DIR
//
// Icons are made by createWDSIcon(name, w, h, viewBox, svgProps, body) / createWAWebIcon(…) calls, where
// body is a path string or a list of [tag, attrs]. Each call is cut out of the bundle and evaluated with
// stand-ins for those two functions. NAMES maps our file names to WhatsApp's icon names.
import fs from "fs";
import path from "path";
import vm from "vm";

const NAMES = {
  "chats": "wds-ic-chat", "chats-on": "wds-ic-chat-filled",
  "calls": "ic-call", "calls-on": "ic-call-filled",
  "status": "wds-ic-status", "status-on": "wds-ic-status-filled",
  "channels": "wds-ic-channels", "channels-on": "wds-ic-channels-filled",
  "communities": "wds-ic-communities", "communities-on": "wds-ic-communities-filled",
  "settings": "wds-ic-settings-gear", "settings-on": "wds-ic-settings-gear-fill",
  "menu": "ic-more-vert", "new-chat": "wds-ic-new-chat-filled", "search": "ic-search",
  "archive": "ic-archive", "drop-down": "ic-arrow-drop-down", "chevron-down": "ic-chevron-down",
  "video-call": "ic-videocam", "voice-call": "ic-call", "attach": "ic-attach-file", "plus": "ic-add", "media": "ic-filter", "emoji": "wds-ic-sticker-smiley",
  "mic": "ic-mic", "send": "ic-send-filled", "check": "ic-check", "dblcheck": "wds-ic-read",
  "pending": "ic-schedule", "muted": "ic-notifications-off-filled", "pin": "ic-push-pin", "forward": "ic-double-forward", "play": "ic-play-arrow-filled", "pause": "ic-pause-filled", "mic-filled": "ic-mic-filled", "download": "ic-download", "doc-file": "ic-description-filled", "image": "ic-image-filled", "location-pin": "ic-location-on-filled", "poll": "wds-ic-poll", "headphones": "ic-headphones-filled", "cancel": "ic-cancel-filled", "open": "ic-open-in-new", "photo-library": "ic-photo-library", "camera": "ic-photo-camera-filled", "audio-file": "wds-ic-audio-file-filled", "contacts": "ic-contacts", "lock": "ic-lock",
  "back": "ic-arrow-back", "close": "ic-close", "photo": "ic-photo-camera-filled", "videocam": "ic-videocam-filled",
  "revoked": "ic-block", "person": "ic-person-filled", "group": "ic-group-filled", "tail-in": "tail-in", "tail-out": "tail-out", "wordmark": "wa-wordmark",
  "wa-logo": "wa-logo", "north-east": "ic-north-east", "chevron-right": "ic-chevron-right",
  "sort": "ic-sort", "filter-list": "ic-tune",
  "double-down": "ic-keyboard-double-arrow-down", "meta-ai": "wds-ic-logo-meta-ai", "megaphone": "ic-campaign-megaphone-filled", "reply": "ic-reply", "copy": "ic-content-copy", "edit": "ic-edit", "info": "ic-info",
  "arrow-forward": "ic-arrow-forward", "delete": "ic-delete", "star": "ic-star-rate", "group-add": "ic-group-add", "checkbox": "ic-check-box",
  // the image editor's toolbar (the send preview)
  "crop-rotate": "ic-crop-rotate", "rotate-cw": "ic-rotate-90-degrees-cw", "draw": "ic-draw", "title": "ic-title", "square": "ic-square",
  "pixelate": "media-editor-blur-pixelate", "unmuted": "ic-notifications-filled", "undo": "ic-undo", "redo": "ic-redo",
};

function calls(src) {
  const out = {};
  const re = /create(?:WDS|WAWeb)Icon\(/g;
  for (let m; (m = re.exec(src));) {
    // the argument list: up to the matching ')', skipping strings
    let i = m.index + m[0].length, depth = 1, q = null;
    for (; i < src.length && depth > 0; i++) {
      const c = src[i];
      if (q) { if (c === "\\") i++; else if (c === q) q = null; continue; }
      if (c === '"' || c === "'") q = c; else if (c === "(" || c === "[" || c === "{") depth++; else if (c === ")" || c === "]" || c === "}") depth--;
    }
    const args = src.slice(m.index + m[0].length, i - 1);
    try {
      const a = vm.runInNewContext("[" + args + "]", {}, { timeout: 100 });
      if (typeof a[0] === "string" && !(a[0] in out)) out[a[0]] = a;
    } catch (e) {}
  }
  return out;
}

const attrName = (k) => k === "fillRule" ? "fill-rule" : k === "clipRule" ? "clip-rule" : k === "enableBackground" ? "enable-background" : k;
function toSvg([, , , viewBox, props, body]) {
  const [, , w, h] = viewBox.split(" ");
  const parts = typeof body === "string" ? [["path", { d: body, fill: "currentColor" }]] : body;
  const inner = parts.map(([t, a]) => [t, a && a.fill === "#0000000" ? { ...a, fill: "#000000" } : a]).map(([tag, at]) => "<" + tag + Object.entries(at || {}).filter(([, v]) => typeof v !== "object")
    .map(([k, v]) => ` ${attrName(k)}="${v}"`).join("") + "/>").join("");
  const fill = props && props.fill ? props.fill : "currentColor";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox}" width="${w}" height="${h}" fill="${fill}">${inner}</svg>\n`;
}

// qr-logo, the WhatsApp logo in the middle of the pairing QR code, is a React component
// (WAWebQrCodeWaLogo), not an icon call: written from its three paths below.
const QR_LOGO = (bundle) => {
  const m = /__d\("WAWebQrCodeWaLogo\.react"[\s\S]*?(?=__d\()/.exec(bundle);
  if (!m) return null;
  const paths = [...m[0].matchAll(/jsx\("path",\{fill:"([^"]+)",d:"([^"]+)"\}\)/g)].map((p) => `<path fill="${p[1]}" d="${p[2]}"/>`);
  return paths.length ? `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" fill="currentColor">${paths.join("")}</svg>\n` : null;
};

const [src, dst] = process.argv.slice(2);
if (!src || !dst) { console.error("usage: wa-icons.mjs BUNDLE_DIR OUT_DIR"); process.exit(2); }
const all = {};
for (const f of fs.readdirSync(src).filter((f) => f.endsWith(".js")).sort())
  Object.assign(all, calls(fs.readFileSync(path.join(src, f), "utf8")), all);
fs.mkdirSync(dst, { recursive: true });
const missing = [];
for (const [ours, theirs] of Object.entries(NAMES)) {
  if (!all[theirs]) { missing.push(`${ours} (${theirs})`); continue; }
  fs.writeFileSync(path.join(dst, ours + ".svg"), toSvg(all[theirs]));
}
for (const f of fs.readdirSync(src).filter((f) => f.endsWith(".js"))) {
  const t = fs.readFileSync(path.join(src, f), "utf8");
  if (!t.includes('__d("WAWebQrCodeWaLogo.react"')) continue;
  const svg = QR_LOGO(t);
  if (svg) { fs.writeFileSync(path.join(dst, "qr-logo.svg"), svg); break; }
}
// the landing's inline badge: WhatsApp's logo, white, 16 px in a 24 px green rounded square
if (all["wa-logo"]) {
  const logo = toSvg(all["wa-logo"]).replace(/<svg[^>]*>/, "").replace("</svg>", "").replace(/currentColor/g, "#FFFFFF");
  fs.writeFileSync(path.join(dst, "wa-badge.svg"), `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><rect width="24" height="24" rx="6" fill="#1DAA61"/><g transform="translate(4 4.25) scale(0.516)">${logo}</g></svg>`);
}
console.log(`${Object.keys(NAMES).length - missing.length} icons in ${dst} (${Object.keys(all).length} known)`);
if (missing.length) console.log("not found: " + missing.join(", "));
