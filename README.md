# qml-whats

A WhatsApp client for Linux: **web.whatsapp.com in QtWebEngine**. The application is written in
**D** (DSide) and its UI in **solid-qml** TSX, hosted through [solid-qml-d](../solid-qml-d).

- `ui/app/WhatsApp.tsx` — the screen: the rail, the downloads and settings panels, the PDF viewer,
  the permission and screen-sharing bars, notifications.
- `ui/app/WhatsWeb.qml` — the WebEngine (a solid-qml escape hatch): a persistent profile, the user
  agent, permissions for calls, screen sharing, notifications with inline reply, downloads, popups,
  and the reload after 30 minutes idle.
- `ui/app/WindowCtl.qml`, `ui/app/TrayIcon.qml` — the window (raise, close to the tray, full screen,
  shortcuts) and the tray icon.
- `source/` — `main`, the `app` backend (settings, paths, icons, spell-check dictionaries), and the
  single instance. Never edit `qml/`: `./build ui` generates it.

## Build & run

```sh
reggae -b binary . --reggaefile-import-path $PWD/../dside/reggae --reggaefile-import-path $PWD/../solid-qml-d/reggae
SOLIDQML_PREBUILT=1 ./build ui && SOLIDQML_PREBUILT=1 ./build qml-whats-ldc2
./qml-whats-ldc2            # --hidden (start in the tray), --url URL, --new-instance, --grab out.png
./build unittest
```

### AppImage

`tools/appimage.sh` builds `QWhats-x86_64.AppImage` (~226 MB): the app with its own Qt 6.11.2 and
QtWebEngine, so a machine with another Qt runs it (DSide and libsolidqml use Qt's private API, stable
only within one exact version). On first run it offers to install itself: `~/.local/bin/qwhats`,
the launcher (`qwhats.desktop`) and the icon. Notes in the script: linuxdeploy only *chooses* what to
bundle — every ELF is put back to its pristine original (its patchelf breaks glibc 2.44's loader) and
AppRun provides `LD_LIBRARY_PATH`, which the app keeps away from the programs it starts.

**Portable build (manylinux_2_34, glibc ≥ 2.34):** `tools/manylinux.sh` builds the AppImage in
podman, from `tools/manylinux/Containerfile` (AlmaLinux 9 + clang, LDC 1.43, meson) against Qt's own
6.11.2 (aqtinstall); `tools/manylinux/inside.sh` does the work and is what CI runs too
(`.github/workflows/appimage.yml`: an artifact on every push, a release on a `v*` tag). The DSide
binding and the solid-qml host it needs are kept in `third_party/solid-qml-d` (refresh with
`tools/update-binding.sh` after changing solid-qml-d or Qt), so neither the private solid-qml-d nor
DSide's generator is needed to build.

`tools/install.sh` is the development install (a frozen copy of the build tree, no Qt bundled).

## Data

- session (login), cache: `~/.local/share/qml-whats/profile`, `~/.cache/qml-whats/web`
- settings: `~/.config/qml-whats/settings.json`
- downloads: `~/Downloads/QWhats` (the XDG Downloads folder + `QWhats`)
- spell-check: any hunspell dictionary in `/usr/share/hunspell` is converted to Chromium's format
  on first run (`hunspell-pt-br`, `hunspell-en_us`).

## Accounts

Several WhatsApp accounts at once (Configurações › Contas): each is its own Chromium profile
(`~/.local/share/qml-whats/profiles/<id>`; the first keeps `profile/`), all open so all notify.
Ctrl+1 … Ctrl+9 switch; the dock shows each account's unread count.

## Remote control (JSON-RPC 2.0)

Off by default (Configurações › Controle remoto). A unix socket in `$XDG_RUNTIME_DIR/qwhats.sock`
(0600), one request per line:

```sh
qwhats --rpc help
qwhats --rpc app.status
qwhats --rpc message.send --params '{"phone":"5511999999999","text":"oi","account":"main"}'
```

`app.status|show|hide|toggle|reload|quit`, `accounts.list|switch`, `unread`, `chat.open`,
`message.send`, `settings.get|set`.

## Updates

Every 30 min each page compares its running WhatsApp revision with the one web.whatsapp.com serves;
only when a new one is out is it reloaded — after 10 min without use, never during a call, over a
draft or during a download.

## Shortcuts

Ctrl+Q quit · Ctrl+W hide · F5 reload · Ctrl+Shift+R reload without cache · Ctrl +/−/0 zoom ·
Ctrl+J downloads · Ctrl+, settings · Ctrl+1…9 accounts · F11 full screen · F12 developer tools
