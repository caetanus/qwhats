// qml-whats' screen: WhatsApp itself (WhatsWeb.qml, QtWebEngine) with a slim rail beside it, and
// what the browser tab never had — downloads that open by themselves (PDFs right here, beside the
// chat), the desktop's notifications with inline reply, a tray icon with the unread count, a bar to
// answer a permission and to choose what screen to share in a call, and the settings.
import { createSignal, createMemo, For, Show } from "solid-js";
import { notifications } from "../../../solid-qml-native/src/solid-qml/runtime";
import "./app.css";
import WhatsWeb from "./WhatsWeb.qml";
import WindowCtl from "./WindowCtl.qml";

// The D backend (source/qmlwhats/backend.d).
declare const app: {
  settingsJson: string; iconBase: string; appIcon: string; appIconUnread: string;
  profilePath: string; cachePath: string; dictionariesJson: string; startUrl: string;
  startHidden: boolean; raiseCount: number; dark: boolean; trayAvailable: boolean; trayClicks: number;
  setUnread(n: number): void; restart(): void; quit(): void;
  set(key: string, valueJson: string): void; ensureDir(path: string): void;
  reveal(path: string): void; removeFile(path: string): void;
};
declare const Qt: any;

type Download = {
  id: number; name: string; path: string; mime: string; received: number; total: number;
  state: string; error: string; opened: boolean;
};

export function WhatsApp() {
  const settings = createMemo(() => JSON.parse(app.settingsJson));
  const dictionaries = createMemo(() => JSON.parse(app.dictionariesJson));

  const [unread, setUnread] = createSignal(0);
  const [panel, setPanel] = createSignal("");   // "" | "downloads" | "settings"
  // The document open beside the chat (WhatsWeb's pane): {open, name, path}.
  const [doc, setDoc] = createSignal({ open: false, name: "", path: "" });
  const [downloads, setDownloads] = createSignal<Download[]>([]);
  const [seen, setSeen] = createSignal(0);       // downloads finished since the panel was last open
  const [perm, setPerm] = createSignal({ kind: "", origin: "" });
  const [share, setShare] = createSignal({ open: false, screens: [] as string[], windows: [] as string[] });
  const [load, setLoad] = createSignal({ loading: true, progress: 0, error: "" });
  const [full, setFull] = createSignal(false);
  const [focused, setFocused] = createSignal(true);
  const [hover, setHover] = createSignal("");
  const [toast, setToast] = createSignal("");
  // desktop notification id → the page's notification key (and back)
  const [noteKeys] = createSignal<Record<number, number>>({});
  const [noteIds] = createSignal<Record<number, number>>({});

  let web: any;
  let win: any;

  const ic = (name: string, variant: string) => app.iconBase + "/" + variant + "/" + name + ".svg";
  const fileUrl = (path: string) => "file://" + encodeURI(path);
  const running = createMemo(() => downloads().filter((d) => d.state === "running").length);
  const title = createMemo(() => (unread() > 0 ? "(" + unread() + ") WhatsApp" : "WhatsApp"));

  function clearToast(text: string) {
    if (toast() === text) setToast("");
  }
  function say(text: string) {
    setToast(text);
    setTimeout(() => clearToast(text), 3500);
  }

  function togglePanel(name: string) {
    if (panel() === name) { setPanel(""); web.focusPage(); return; }
    setPanel(name);
    if (name === "downloads") setSeen(0);
  }

  function setting(key: string, value: any) { app.set(key, JSON.stringify(value)); }
  function onUnread(n: number) {
    setUnread(n);
    app.setUnread(n);
  }
  // The page's colour scheme is fixed when Chromium starts: a new theme restarts QWhats (the
  // session is on disk — nothing to log in again).
  function setTheme(t: string) {
    if (t === settings().theme) return;
    setting("theme", t);
    app.restart();
  }
  function showPanel(name: string) {
    win.show();
    setPanel(name);
    if (name === "downloads") setSeen(0);
  }
  function showChats() {
    setPanel("");
    web.focusPage();
  }
  function openFolder() {
    app.ensureDir(settings().downloadDir);
    Qt.openUrlExternally(fileUrl(settings().downloadDir));
  }
  function onPermissionAsk(json: string) {
    setPerm(JSON.parse(json));
    win.show();
  }

  // ---- notifications ----------------------------------------------------------------------
  function onNotify(key: number, nTitle: string, body: string) {
    const s = settings();
    if (!s.notifications || !notifications.available) return;
    if (focused() && !full()) return;   // the chat is in front of the user already
    const spec: any = {
      title: nTitle,
      body: s.notifyPreview ? body : "Nova mensagem",
      icon: app.appIcon,
      actions: [{ id: "default", label: "Abrir" }],
    };
    if (notifications.supportsReply) spec.reply = "Responder…";
    const id = notifications.send(spec);
    if (id > 0) { noteKeys()[id] = key; noteIds()[key] = id; }
  }
  function onNotifyClosed(key: number) {
    const id = noteIds()[key];
    if (id) { notifications.close(id); delete noteIds()[key]; delete noteKeys()[id]; }
  }
  function onNoteAction(id: number) {
    const key = noteKeys()[id];
    win.show();
    if (key) web.clickNotification(key);
  }
  function onNoteReply(id: number, text: string) {
    const key = noteKeys()[id];
    if (key) { web.replyNotification(key, text); say("Resposta enviada"); }
  }
  function onNoteClosed(id: number) {
    const key = noteKeys()[id];
    if (key) { delete noteKeys()[id]; delete noteIds()[key]; }
  }
  notifications.actionInvoked.connect((id: number, _action: string) => onNoteAction(id));
  notifications.replied.connect((id: number, text: string) => onNoteReply(id, text));
  notifications.closed.connect((id: number, _reason: number) => onNoteClosed(id));

  // ---- downloads --------------------------------------------------------------------------
  const extOf = (name: string) => name.toLowerCase().split(".").pop() || "";
  const isPdf = (d: Download) => d.mime === "application/pdf" || extOf(d.name) === "pdf";
  // Media is saved, documents open (as WhatsApp Desktop does when a document is clicked).
  const isMedia = (d: Download) => ["image", "video", "audio"].indexOf(d.mime.split("/")[0]) >= 0
    || ["jpg", "jpeg", "png", "gif", "webp", "mp4", "webm", "ogg", "opus", "mp3", "m4a"].indexOf(extOf(d.name)) >= 0;

  function openDownload(d: Download, inApp: boolean) {
    if (inApp && isPdf(d)) { web.openDocument(fileUrl(d.path), d.name, d.path); setPanel(""); }
    else Qt.openUrlExternally(fileUrl(d.path));
  }

  function onDownload(json: string) {
    const e = JSON.parse(json);
    const prev = downloads().find((d) => d.id === e.id);
    const d: Download = {
      id: e.id, name: e.name, path: e.path, mime: e.mime, received: e.received, total: e.total,
      state: e.state, error: e.error, opened: prev ? prev.opened : false,
    };
    if (prev) setDownloads(downloads().map((x) => (x.id === d.id ? d : x)));
    else setDownloads([d, ...downloads()].slice(0, 60));
    if (e.type === "start") {
      app.ensureDir(e.dir);
      return;
    }
    if (e.type !== "done") return;
    if (d.state === "failed") { say("Falha ao baixar " + d.name + (d.error ? ": " + d.error : "")); return; }
    if (d.state !== "done") return;
    if (panel() !== "downloads") setSeen(seen() + 1);
    const s = settings();
    if (isPdf(d) && s.pdfInApp) openDownload(d, true);
    else if (!isMedia(d) && s.openDownloads) openDownload(d, false);
    else say("Salvo: " + d.name);
  }

  function removeDownload(d: Download) {
    if (d.state === "running") { web.cancelDownload(d.id); return; }
    app.removeFile(d.path);
    setDownloads(downloads().filter((x) => x.id !== d.id));
    if (doc().path === d.path) web.closeDocument();
  }

  function sizeOf(n: number) {
    if (n <= 0) return "";
    if (n < 1024) return n + " B";
    if (n < 1048576) return Math.round(n / 1024) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  // ---- permissions and screen sharing -----------------------------------------------------
  function hostOf(origin: string) {
    const rest = origin.indexOf("://") >= 0 ? origin.substring(origin.indexOf("://") + 3) : origin;
    return rest.split("/")[0];
  }
  function permText(kind: string) {
    if (kind === "mic") return "quer usar o microfone";
    if (kind === "camera") return "quer usar a câmera";
    if (kind === "camera+mic") return "quer usar a câmera e o microfone";
    if (kind === "screen") return "quer compartilhar a sua tela";
    return "pede uma permissão";
  }
  function answer(grant: boolean) {
    web.answerPermission(grant);
    setPerm({ kind: "", origin: "" });
  }
  function onScreenPick(json: string) {
    const r = JSON.parse(json);
    setShare({ open: true, screens: r.screens, windows: r.windows });
    win.show();
  }
  function pick(kind: string, index: number) {
    web.pickScreen(kind, index);
    setShare({ open: false, screens: [], windows: [] });
  }

  // ---- shortcuts and zoom -----------------------------------------------------------------
  function zoomBy(step: number) {
    const z = Math.round((settings().zoom + step) * 100) / 100;
    setting("zoom", Math.max(0.5, Math.min(2.0, z)));
  }
  function onShortcut(name: string) {
    if (name === "reload") web.reload();
    else if (name === "hard-reload") web.hardReload();
    else if (name === "zoom-in") zoomBy(0.1);
    else if (name === "zoom-out") zoomBy(-0.1);
    else if (name === "zoom-reset") setting("zoom", 1.0);
    else if (name === "settings") togglePanel("settings");
    else if (name === "downloads") togglePanel("downloads");
    else if (name === "fullscreen") setFull(!full());
    else if (name === "devtools") web.devTools();
    else if (name === "escape") { web.exitFullScreen(); setFull(false); }
  }

  function toggleLang(lang: string) {
    const cur: string[] = settings().spellLangs;
    const next = cur.indexOf(lang) >= 0 ? cur.filter((l) => l !== lang) : [...cur, lang];
    setting("spellLangs", next);
  }
  // No language chosen yet: the ones that match the system's (pt-BR, en-US), else all of them.
  function pickLangs(chosen: string[], all: string[]) {
    if (chosen.length > 0) return chosen.filter((l) => all.indexOf(l) >= 0);
    const sys = Qt.locale().name.replace("_", "-");
    const near = all.filter((l) => l === sys || l === "en-US" || l.split("-")[0] === sys.split("-")[0]);
    return near.length > 0 ? near : all;
  }
  const spellLangs = createMemo(() => pickLangs(settings().spellLangs, dictionaries()));

  return (
    <div class="app" classList={{ light: !app.dark, full: full() }}>
      <WindowCtl ref={win} closeToTray={settings().closeToTray && app.trayAvailable} startHidden={app.startHidden && app.trayAvailable}
                 trayClicks={app.trayClicks}
                 raiseCount={app.raiseCount} fullScreen={full()} title={title()}
                 onShortcut={(n) => onShortcut(n)} onWindowActive={(a) => setFocused(a)} />

      <Show when={!full()}>
        <div class="rail">
          <div class="rail-group">
          <div tabIndex={0} role="button" aria-label="Conversas" class="rbtn" classList={{ on: panel() === "" }}
               onClick={() => showChats()}>
            <img class="ic" src={ic("message-circle", panel() === "" ? "accent" : "muted")} />
            <Show when={unread() > 0}><div class="dot"><text class="dot-t">{unread() > 99 ? "99+" : "" + unread()}</text></div></Show>
          </div>
          <div tabIndex={0} role="button" aria-label="Downloads" class="rbtn" classList={{ on: panel() === "downloads" }}
               onClick={() => togglePanel("downloads")}>
            <img class="ic" src={ic("download", panel() === "downloads" ? "accent" : "muted")} />
            <Show when={running() > 0 || seen() > 0}>
              <div class="dot" classList={{ busy: running() > 0 }}><text class="dot-t">{"" + (running() > 0 ? running() : seen())}</text></div>
            </Show>
          </div>
          <Show when={doc().open}>
            <div tabIndex={0} role="button" aria-label="Fechar o documento" class="rbtn on" onClick={() => web.closeDocument()}>
              <img class="ic" src={ic("file-text", "accent")} />
            </div>
          </Show>
          </div>
          <div class="rail-group">
          <div tabIndex={0} role="button" aria-label="Recarregar" class="rbtn" onClick={() => web.reload()}>
            <img class="ic" src={ic("refresh-cw", "muted")} />
          </div>
          <div tabIndex={0} role="button" aria-label="Configurações" class="rbtn" classList={{ on: panel() === "settings" }}
               onClick={() => togglePanel("settings")}>
            <img class="ic" src={ic("settings", panel() === "settings" ? "accent" : "muted")} />
          </div>
          </div>
        </div>
      </Show>

      <div class="main">
        <Show when={perm().kind !== ""}>
          <div class="bar">
            <img class="ic" src={ic(perm().kind === "screen" ? "monitor" : perm().kind === "mic" ? "mic" : "video", "accent")} />
            <text class="bar-t">{hostOf(perm().origin) + " " + permText(perm().kind)}</text>
            <button class="btn ghost" onClick={() => answer(false)}>Negar</button>
            <button class="btn" onClick={() => answer(true)}>Permitir</button>
          </div>
        </Show>
        <Show when={share().open}>
          <div class="bar share">
            <img class="ic" src={ic("monitor", "accent")} />
            <text class="bar-t">O que compartilhar na chamada?</text>
            <div class="share-list">
              <For each={share().screens}>
                {(name, i) => <button class="btn chip" onClick={() => pick("screen", i())}>{name || "Tela " + (i() + 1)}</button>}
              </For>
              <For each={share().windows}>
                {(name, i) => <button class="btn chip ghost" onClick={() => pick("window", i())}>{name}</button>}
              </For>
            </div>
            <button class="btn ghost" onClick={() => pick("cancel", 0)}>Cancelar</button>
          </div>
        </Show>
        <Show when={load().loading && load().progress < 100}>
          <progress class="loadbar" value={load().progress} max={100} />
        </Show>

        <div class="content">
          <WhatsWeb ref={web} class="web" profilePath={app.profilePath} cachePath={app.cachePath}
                    startUrl={app.startUrl} downloadDir={settings().downloadDir} zoom={settings().zoom}
                    autoGrantMedia={settings().autoGrantMedia} spellcheck={settings().spellcheck}
                    spellLangs={spellLangs()}
                    idleReloadMinutes={settings().idleReload} busy={running() > 0}
                    sounds={settings().sounds}
                    onUnreadCount={(n) => onUnread(n)}
                    onNotify={(k, t, b) => onNotify(k, t, b)}
                    onNotifyClosed={(k) => onNotifyClosed(k)}
                    onDownloadEvent={(j) => onDownload(j)}
                    onPermissionAsk={(j) => onPermissionAsk(j)}
                    onScreenPick={(j) => onScreenPick(j)}
                    onLoadState={(j) => setLoad(JSON.parse(j))}
                    onFullScreen={(on) => setFull(on)}
                    onLinkHover={(u) => setHover(u)}
                    onDocumentChanged={(j) => setDoc(JSON.parse(j))} />


          <Show when={panel() === "downloads"}>
            <div class="panel">
              <div class="phead">
                <text class="ptitle">Downloads</text>
                <div tabIndex={0} role="button" aria-label="Abrir a pasta" class="tbtn" onClick={() => openFolder()}>
                  <img class="ic" src={ic("folder-open", "muted")} />
                </div>
                <div tabIndex={0} role="button" aria-label="Fechar" class="tbtn" onClick={() => togglePanel("downloads")}>
                  <img class="ic" src={ic("x", "muted")} />
                </div>
              </div>
              <Show when={downloads().length === 0}>
                <div class="empty">
                  <img class="ic xl" src={ic("download", "muted")} />
                  <text class="empty-t">Nada baixado ainda.</text>
                  <text class="hint">Documentos abrem sozinhos ao terminar de baixar — PDFs aqui mesmo, ao lado da conversa.</text>
                </div>
              </Show>
              <div class="dlist">
                <For each={downloads()}>
                  {(d) => (
                    <div class="dl" classList={{ failed: d.state === "failed" || d.state === "cancelled" }}>
                      <div tabIndex={0} role="button" class="dl-main" onClick={() => d.state === "done" && openDownload(d, settings().pdfInApp)}>
                        <img class="ic" src={ic(isPdf(d) ? "file-text" : "download", d.state === "done" ? "fg" : "muted")} />
                        <div class="dl-text">
                          <text class="dl-name">{d.name}</text>
                          <text class="dl-sub">{d.state === "running" ? sizeOf(d.received) + (d.total > 0 ? " de " + sizeOf(d.total) : "")
                            : d.state === "done" ? sizeOf(d.total > 0 ? d.total : d.received)
                            : d.state === "cancelled" ? "Cancelado" : "Falhou" + (d.error ? ": " + d.error : "")}</text>
                          <Show when={d.state === "running"}>
                            <progress class="dl-bar" value={d.total > 0 ? d.received / d.total : 0} max={1} />
                          </Show>
                        </div>
                      </div>
                      <Show when={d.state === "done"}>
                        <div tabIndex={0} role="button" aria-label="Abrir com outro aplicativo" class="tbtn" onClick={() => openDownload(d, false)}>
                          <img class="ic sm" src={ic("external-link", "muted")} />
                        </div>
                        <div tabIndex={0} role="button" aria-label="Mostrar na pasta" class="tbtn" onClick={() => app.reveal(d.path)}>
                          <img class="ic sm" src={ic("folder-open", "muted")} />
                        </div>
                      </Show>
                      <div tabIndex={0} role="button" aria-label={d.state === "running" ? "Cancelar" : "Apagar o arquivo"} class="tbtn"
                           onClick={() => removeDownload(d)}>
                        <img class="ic sm" src={ic(d.state === "running" ? "x" : "trash-2", "muted")} />
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          <Show when={panel() === "settings"}>
            <div class="panel">
              <div class="phead">
                <text class="ptitle">Configurações</text>
                <div tabIndex={0} role="button" aria-label="Fechar" class="tbtn" onClick={() => togglePanel("settings")}>
                  <img class="ic" src={ic("x", "muted")} />
                </div>
              </div>
              <div class="plist">
                <text class="sect">Notificações</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Notificações na área de trabalho</text>
                    <text class="hint">{notifications.available ? (notifications.supportsReply ? "Com resposta direto na notificação." : "Clique para abrir a conversa.") : "Nenhum servidor de notificações encontrado."}</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().notifications} onChange={(e) => setting("notifications", e.target.checked)} />
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Mostrar o texto da mensagem</text>
                    <text class="hint">Desligado, a notificação diz só quem escreveu.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().notifyPreview} onChange={(e) => setting("notifyPreview", e.target.checked)} />
                </div>

                <div class="row">
                  <div class="row-text"><text class="row-t">Sons</text>
                    <text class="hint">Desligado, o WhatsApp fica mudo (mensagens e toque de chamada); uma ligação em andamento sempre tem som.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().sounds} onChange={(e) => setting("sounds", e.target.checked)} />
                </div>

                <text class="sect">Aparência</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Tema</text>
                    <text class="hint">O QWhats reinicia para aplicar. No WhatsApp, deixe Configurações › Personalização › Tema em "Padrão do sistema" para ele acompanhar.</text></div>
                  <select class="sel" value={settings().theme} onChange={(e) => setTheme(e.target.value)}>
                    <option value="system">Sistema</option>
                    <option value="light">Claro</option>
                    <option value="dark">Escuro</option>
                  </select>
                </div>

                <text class="sect">Janela</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Fechar para a bandeja</text>
                    <text class="hint">{app.trayAvailable ? "Continua recebendo mensagens; Ctrl+Q sai de vez." : "Sem bandeja do sistema nesta sessão: fechar a janela sai do app."}</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().closeToTray} onChange={(e) => setting("closeToTray", e.target.checked)} />
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Iniciar escondido na bandeja</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().startHidden} onChange={(e) => setting("startHidden", e.target.checked)} />
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Zoom</text><text class="hint">Ctrl + / Ctrl − / Ctrl 0</text></div>
                  <div class="zoom">
                    <div tabIndex={0} role="button" aria-label="Diminuir" class="tbtn" onClick={() => zoomBy(-0.1)}><img class="ic sm" src={ic("minus", "fg")} /></div>
                    <text class="zoom-t">{Math.round(settings().zoom * 100) + "%"}</text>
                    <div tabIndex={0} role="button" aria-label="Aumentar" class="tbtn" onClick={() => zoomBy(0.1)}><img class="ic sm" src={ic("plus", "fg")} /></div>
                  </div>
                </div>

                <div class="row">
                  <div class="row-text"><text class="row-t">Atualizar sozinho depois de 30 min parado</text>
                    <text class="hint">Recarrega o WhatsApp quando ninguém mexe nele há meia hora — nunca durante uma chamada, com texto digitado ou baixando arquivo.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().idleReload > 0} onChange={(e) => setting("idleReload", e.target.checked ? 30 : 0)} />
                </div>

                <text class="sect">Chamadas</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Permitir câmera e microfone ao WhatsApp</text>
                    <text class="hint">Chamadas de voz e vídeo atendem sem perguntar. Desligado, uma barra pede a sua permissão.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().autoGrantMedia} onChange={(e) => setting("autoGrantMedia", e.target.checked)} />
                </div>

                <text class="sect">Arquivos</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Abrir PDFs dentro do app</text>
                    <text class="hint">Ao lado da conversa, com o leitor do Chromium. Desligado, abrem no leitor do sistema.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().pdfInApp} onChange={(e) => setting("pdfInApp", e.target.checked)} />
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Abrir documentos ao terminar de baixar</text>
                    <text class="hint">No aplicativo padrão do sistema. Fotos, vídeos e áudios só são salvos.</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().openDownloads} onChange={(e) => setting("openDownloads", e.target.checked)} />
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Pasta de downloads</text><text class="hint">{settings().downloadDir}</text></div>
                  <button class="btn ghost" onClick={() => openFolder()}>Abrir</button>
                </div>

                <text class="sect">Corretor ortográfico</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Verificar a ortografia ao digitar</text>
                    <text class="hint">{dictionaries().length > 0 ? "Clique com o botão direito numa palavra sublinhada para as sugestões." : "Nenhum dicionário instalado (pacotes hunspell-pt-br, hunspell-en_us)."}</text></div>
                  <input type="checkbox" role="switch" class="sw" checked={settings().spellcheck} onChange={(e) => setting("spellcheck", e.target.checked)} />
                </div>
                <Show when={dictionaries().length > 0}>
                  <div class="langs">
                    <For each={dictionaries()}>
                      {(lang) => (
                        <button class="btn chip" classList={{ ghost: spellLangs().indexOf(lang) < 0 }} onClick={() => toggleLang(lang)}>{lang}</button>
                      )}
                    </For>
                  </div>
                </Show>

                <text class="sect">Avançado</text>
                <div class="row">
                  <div class="row-text"><text class="row-t">Recarregar sem cache</text><text class="hint">Ctrl+Shift+R — se o WhatsApp ficar preso carregando.</text></div>
                  <button class="btn ghost" onClick={() => web.hardReload()}>Recarregar</button>
                </div>
                <div class="row">
                  <div class="row-text"><text class="row-t">Ferramentas do desenvolvedor</text><text class="hint">F12</text></div>
                  <button class="btn ghost" onClick={() => web.devTools()}>Abrir</button>
                </div>
              </div>
            </div>
          </Show>

          <Show when={load().error !== ""}>
            <div class="offline">
              <img class="ic xl" src={ic("circle-alert", "danger")} />
              <text class="off-t">Não foi possível abrir o WhatsApp</text>
              <text class="hint">{load().error}</text>
              <button class="btn" onClick={() => web.reload()}>Tentar de novo</button>
            </div>
          </Show>
        </div>

        <Show when={hover() !== "" && !full()}>
          <div class="hover"><text class="hover-t">{hover()}</text></div>
        </Show>
        <Show when={toast() !== ""}>
          <div class="toast-row"><div class="toast"><text class="toast-t">{toast()}</text></div></div>
        </Show>
      </div>
    </div>
  );
}
