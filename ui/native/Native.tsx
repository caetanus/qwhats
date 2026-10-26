// QWhats native — the screen, drawn to match WhatsApp Web (docs/wa-ui-spec.md has the measurements).
// WhatsApp itself is qwhats-core (Go + whatsmeow), reached through the `core` bridge:
// core.call(id, method, paramsJson) and core.line (every reply and event, as one JSON line). This file
// keeps all the state (Solid signals); docs/native-client.md has the API. `look` hands out WhatsApp's
// own icons, tinted (look.ensure writes <base>/<name>-<colour key>.svg).
import { createSignal, createMemo, createEffect, Show, For, onMount } from "solid-js";
import { Menu, MenuItem, MenuSeparator } from "../../../solid-qml-native/src/solid-qml/runtime";
import { notifications } from "../../../solid-qml-native/src/solid-qml/runtime";
import Wallpaper from "./Wallpaper.qml";
import AudioMessage from "./AudioMessage.qml";
import Chime from "./Chime.qml";
import MediaViewer from "./MediaViewer.qml";
import Picker from "./Picker.qml";
import FitImage from "./FitImage.qml";
import ImageEditor from "./ImageEditor.qml";
import TypingDots from "./TypingDots.qml";
import LocationMap from "./LocationMap.qml";
import Rich from "./Rich.qml";
import Measure from "./Measure.qml";
import Story from "./Story.qml";
import EmojiPanel from "./EmojiPanel.qml";
import Sticker from "./Sticker.qml";
import BlurImage from "./BlurImage.qml";
import Zoom from "./Zoom.qml";
import ScrollWatch from "./ScrollWatch.qml";
import MessageMenu from "./MessageMenu.qml";
import LevelBars from "./LevelBars.qml";
import MsgChevron from "./MsgChevron.qml";
import MsgText from "./MsgText.qml";
import Splitter from "./Splitter.qml";
import StatusRing from "./StatusRing.qml";
import "./native.css";

const ACK = { FAILED: -1, CLOCK: 0, SENT: 1, RECEIVED: 2, READ: 3, PLAYED: 4 };   // WAWebAck.ACK

declare const core: {
  state: string; lastError: string;
  call(id: number, method: string, paramsJson: string): void;
  line: { connect(fn: (l: string) => void): void };
};
declare const app: { iconBase: string; appIcon: string; dark: boolean; settingsJson: string; setUnread(n: number): void; openExternal(url: string): void;
  set(key: string, valueJson: string): void; reveal(path: string): void };
declare const look: { base: string; ok: boolean; cacheDir: string; mapProviders: string; pasted: string; ensure(name: string, color: string): void;
  pasteImage(): void; copyText(text: string): void; copyImage(path: string): void; pastedChanged: { connect(fn: () => void): void } };
declare const Qt: any;

// WhatsApp Web's models, as the core hands them out (docs/native-client.md).
type LastMsg = { id: string; type: string; subtype?: string; body: string; fromMe: boolean; author?: string; senderName?: string; ack: number; t: number };
type Chat = { id: string; kind: string; name: string; t: number; unreadCount: number; markedUnread: boolean; archive: boolean;
  pin: number; muteExpiration: number; isReadOnly: boolean; unknown?: boolean; isAnnounceGrpRestrict?: boolean; parentGroup?: string; parentPic?: string; isAnnounceGroup?: boolean; pinnedMsg?: LastMsg; lastMsg?: LastMsg; profilePicThumb?: string; subscribers?: number };
type Reaction = { aggregateEmoji: string; senders: string[]; hasReactionByMe: boolean };
type Msg = { id: string; remote: string; author?: string; fromMe: boolean; t: number; type: string; subtype?: string; ack: number;
  senderName?: string; body?: string; footer?: string; buttons?: { kind: string; text: string; value?: string }[]; caption?: string; quotedMsg?: { id: string; type?: string; body?: string; author?: string; authorName?: string };
  reactions?: Reaction[]; linkThumb?: string; previewType?: string; thumbWidth?: number; thumbHeight?: number; senderPic?: string; senderPhone?: string; senderRole?: string; newsletterReactions?: { emoji: string; count: number }[]; forwardsCount?: number; isEdited?: boolean; revokeSender?: string; isForwarded?: boolean; star?: boolean;
  isFavoriteSticker?: boolean;
  isStatusMuted?: boolean;
  stickerPack?: string;
  mediaData?: { filename?: string; duration?: number; mediaStage?: string; renderableUrl?: string; waveform?: string; preview?: string;
    width?: number; height?: number; size?: number; pageCount?: number; mimetype?: string; isGif?: boolean; thumbnailHQ?: string }; templateParams?: string[]; templateNames?: string[];
  pollName?: string; pollOptions?: { localId: number; name: string }[]; pollSelectableOptionsCount?: number; loc?: string; lat?: number; lng?: number;
  isLive?: boolean; thumbnail?: string; matchedText?: string; title?: string; description?: string; forwardingScore?: number; vcardList?: { displayName: string; vcard: string }[]; isVideoCall?: boolean; callOutcome?: string };
type Row = { id: string; m: Msg; day: string; first: boolean; last: boolean; stickers?: Msg[]; unread?: string };

// WhatsApp's design tokens the icons are painted with (the CSS has the rest).
// the phone-number link screen's countries (WhatsApp Web lists them all; these are the common ones,
// and any other is typed with its code in the number)
// Meta AI's chat (its number; the core sends to its bot id)
const META_AI = "13135550002@s.whatsapp.net";
const FILTERS = [{ id: "all", label: "Tudo" }, { id: "unread", label: "Não lidas" }, { id: "favorites", label: "Favoritas" }, { id: "groups", label: "Grupos" }];
const COUNTRIES = [
  { name: "Brasil", flag: "🇧🇷", dial: "55" }, { name: "Portugal", flag: "🇵🇹", dial: "351" },
  { name: "Estados Unidos", flag: "🇺🇸", dial: "1" }, { name: "Argentina", flag: "🇦🇷", dial: "54" },
  { name: "Chile", flag: "🇨🇱", dial: "56" }, { name: "Colômbia", flag: "🇨🇴", dial: "57" },
  { name: "México", flag: "🇲🇽", dial: "52" }, { name: "Paraguai", flag: "🇵🇾", dial: "595" },
  { name: "Uruguai", flag: "🇺🇾", dial: "598" }, { name: "Espanha", flag: "🇪🇸", dial: "34" },
  { name: "Reino Unido", flag: "🇬🇧", dial: "44" }, { name: "Alemanha", flag: "🇩🇪", dial: "49" },
  { name: "Itália", flag: "🇮🇹", dial: "39" }, { name: "França", flag: "🇫🇷", dial: "33" },
  { name: "Japão", flag: "🇯🇵", dial: "81" }, { name: "Angola", flag: "🇦🇴", dial: "244" },
  { name: "Moçambique", flag: "🇲🇿", dial: "258" },
];

const DARK = { link: "#21C063", fg: "#FAFAFA", muted: "rgba(255, 255, 255, 0.6)", onAccent: "#0A0A0A", accent: "#21C063", read: "#53BDEB",
  bubbleIn: "#242626", bubbleOut: "#144D37", wall: "#161717", doodle: "#FFFFFF", doodleAlpha: 0.06, brand: "#FFFFFF",
  qBar: "#4DFFFFFF", qBarDone: "#E6FFFFFF", qText: "#99FFFFFF", qPill: "#33FFFFFF", qRead: "#FF53BDEB", qAccent: "#FF21C063" };
const LIGHT = { link: "#1B8755", fg: "#0A0A0A", muted: "rgba(0, 0, 0, 0.6)", onAccent: "#FFFFFF", accent: "#1DAA61", read: "#007BFC",
  bubbleIn: "#FFFFFF", bubbleOut: "#D9FDD3", wall: "#F5F1EB", doodle: "#EAE0D3", doodleAlpha: 0.6, brand: "#1DAA61",
  qBar: "#40000000", qBarDone: "#B3000000", qText: "#99000000", qPill: "#1A000000", qRead: "#FF007BFC", qAccent: "#FF1DAA61" };
// the other themes: a light or dark base (its PHOTO palette, the .light CSS rules) and their colours
const THEMES: { id: string; name: string; dark: boolean; t: any }[] = [
  { id: "paper", name: "Papel", dark: false, t: { ...LIGHT, link: "#2E7D5B", fg: "#2B2A26", muted: "rgba(43, 42, 38, 0.62)", accent: "#2E7D5B", read: "#2F6FB0",
    bubbleIn: "#FFFDF8", bubbleOut: "#E3EFD9", wall: "#EFE9DC", doodle: "#E0D6C2", brand: "#2E7D5B", qRead: "#FF2F6FB0", qAccent: "#FF2E7D5B" } },
  { id: "desert", name: "Deserto", dark: false, t: { ...LIGHT, link: "#A85A2A", fg: "#3B2A1E", muted: "rgba(59, 42, 30, 0.65)", accent: "#C2703D", read: "#2C7DA0",
    bubbleIn: "#FFF8EF", bubbleOut: "#F2D2B6", wall: "#EAD6BC", doodle: "#D9BE9C", brand: "#C2703D", qRead: "#FF2C7DA0", qAccent: "#FFC2703D" } },
  { id: "sol-light", name: "Solarized claro", dark: false, t: { ...LIGHT, link: "#268BD2", fg: "#586E75", muted: "rgba(101, 123, 131, 0.80)", onAccent: "#FDF6E3", accent: "#859900", read: "#268BD2",
    bubbleIn: "#FFFBEF", bubbleOut: "#E6EBC7", wall: "#EEE8D5", doodle: "#DDD6C1", brand: "#859900", qRead: "#FF268BD2", qAccent: "#FF859900" } },
  { id: "sol-dark", name: "Solarized escuro", dark: true, t: { ...DARK, link: "#2AA198", fg: "#EEE8D5", muted: "rgba(147, 161, 161, 0.85)", onAccent: "#002B36", accent: "#2AA198", read: "#268BD2",
    bubbleIn: "#073642", bubbleOut: "#0B4F4F", wall: "#002B36", doodle: "#93A1A1", doodleAlpha: 0.08, brand: "#2AA198", qRead: "#FF268BD2", qAccent: "#FF2AA198" } },
  { id: "nord", name: "Nord", dark: true, t: { ...DARK, link: "#88C0D0", fg: "#ECEFF4", muted: "rgba(216, 222, 233, 0.65)", onAccent: "#2E3440", accent: "#88C0D0", read: "#81A1C1",
    bubbleIn: "#3B4252", bubbleOut: "#3E5A66", wall: "#2E3440", doodle: "#D8DEE9", doodleAlpha: 0.06, brand: "#88C0D0", qRead: "#FF81A1C1", qAccent: "#FF88C0D0" } },
  { id: "ctp-latte", name: "Catppuccin Latte", dark: false, t: { ...LIGHT, link: "#1E66F5", fg: "#4C4F69", muted: "#6C6F85", onAccent: "#FFFFFF", accent: "#8839EF", read: "#1E66F5",
    bubbleIn: "#FFFFFF", bubbleOut: "#E4D5FA", wall: "#E6E9EF", doodle: "#BCC0CC", doodleAlpha: 0.6, brand: "#8839EF", qRead: "#FF1E66F5", qAccent: "#FF8839EF" } },
  { id: "ctp-frappe", name: "Catppuccin Frappé", dark: true, t: { ...DARK, link: "#8CAAEE", fg: "#C6D0F5", muted: "#A5ADCE", onAccent: "#232634", accent: "#CA9EE6", read: "#8CAAEE",
    bubbleIn: "#414559", bubbleOut: "#4F4466", wall: "#232634", doodle: "#C6D0F5", doodleAlpha: 0.05, brand: "#CA9EE6", qRead: "#FF8CAAEE", qAccent: "#FFCA9EE6" } },
  { id: "ctp-macchiato", name: "Catppuccin Macchiato", dark: true, t: { ...DARK, link: "#8AADF4", fg: "#CAD3F5", muted: "#A5ADCB", onAccent: "#181926", accent: "#C6A0F6", read: "#8AADF4",
    bubbleIn: "#363A4F", bubbleOut: "#463C66", wall: "#181926", doodle: "#CAD3F5", doodleAlpha: 0.05, brand: "#C6A0F6", qRead: "#FF8AADF4", qAccent: "#FFC6A0F6" } },
  { id: "ctp-mocha", name: "Catppuccin Mocha", dark: true, t: { ...DARK, link: "#89B4FA", fg: "#CDD6F4", muted: "#A6ADC8", onAccent: "#11111B", accent: "#CBA6F7", read: "#89B4FA",
    bubbleIn: "#313244", bubbleOut: "#43385E", wall: "#11111B", doodle: "#CDD6F4", doodleAlpha: 0.05, brand: "#CBA6F7", qRead: "#FF89B4FA", qAccent: "#FFCBA6F7" } },
  { id: "molokai", name: "Molokai", dark: true, t: { ...DARK, link: "#66D9EF", fg: "#F8F8F2", muted: "rgba(248, 248, 242, 0.6)", onAccent: "#1B1D1E", accent: "#A6E22E", read: "#66D9EF",
    bubbleIn: "#3E3D32", bubbleOut: "#3B4A1E", wall: "#1B1D1E", doodle: "#F8F8F2", doodleAlpha: 0.05, brand: "#A6E22E", qRead: "#FF66D9EF", qAccent: "#FFA6E22E" } },
  { id: "dracula", name: "Drácula", dark: true, t: { ...DARK, link: "#FF79C6", fg: "#F8F8F2", muted: "rgba(248, 248, 242, 0.62)", onAccent: "#21222C", accent: "#BD93F9", read: "#8BE9FD",
    bubbleIn: "#343746", bubbleOut: "#44375E", wall: "#282A36", doodle: "#F8F8F2", doodleAlpha: 0.05, brand: "#BD93F9", qRead: "#FF8BE9FD", qAccent: "#FFBD93F9" } },
];
// Default pictures and group sender names: WhatsApp's profile-photo palette (surface, content).
const PHOTO_DARK = [["#35271E", "#DBA685"], ["#092642", "#53A6FD"], ["#242626", "#BDBDBD"], ["#103529", "#25D366"],
  ["#35221E", "#FC9775"], ["#36192A", "#FF72A1"], ["#242447", "#A791FF"], ["#321622", "#FB5061"], ["#092C3D", "#53BDEB"],
  ["#092D2F", "#42C7B8"], ["#362C1F", "#FFD279"]];
const PHOTO_LIGHT = [["#F4DED1", "#855538"], ["#D2E8FE", "#0063CB"], ["#EEEEEE", "#757778"], ["#D9FDD3", "#1B8755"],
  ["#FEE2D8", "#C4532D"], ["#FFDAE7", "#D42A66"], ["#E8E0FF", "#5E47DE"], ["#FBD8DC", "#B80531"], ["#CAECFA", "#027EB5"],
  ["#CBF2EE", "#028377"], ["#FFF0D4", "#9D6C2C"]];
const WEEKDAYS = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];

// The colour's file-name key, as look.d's keyOf: lower-case letters and digits only.
function colorKey(c: string) {
  const s = c.toLowerCase();
  let k = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    if ((ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")) k += ch;
  }
  return k;
}
function hash(s: string) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 100003;
  return h;
}
// WhatsApp Web's system rows: centred notices, not bubbles.
function isSystem(m: Msg) {
  return m.type === "gp2" || m.type === "e2e_notification" || m.type === "notification_template" || m.type === "call_log" || m.type === "ciphertext";
}
// Day separators, tails and group spacing: a message opens a group when the sender or the day
// changes, and closes one when the next message is someone else's (or another day's).
function rowsOf(list: Msg[], dayLabel: (t: number) => string, unreadFrom: string, unreadN: number, groupStickers: boolean) {
  const out: Row[] = [];
  for (let i = 0; i < list.length; i++) {
    const m = list[i], prev = list[i - 1];
    // stickers sent one after another by the same person sit side by side in one row, wrapping (as
    // WhatsApp shows them): the run ends at another sender, another day, or the unread mark
    let run: Msg[] = [m];
    if (groupStickers && m.type === "sticker") {
      while (i + run.length < list.length) {
        const n = list[i + run.length];
        if (n.type !== "sticker" || n.fromMe !== m.fromMe || (n.author || "") !== (m.author || "") || dayLabel(n.t) !== dayLabel(m.t) || n.id === unreadFrom) break;
        run.push(n);
      }
    }
    const next = list[i + run.length];
    const day = dayLabel(m.t);
    const newDay = !prev || dayLabel(prev.t) !== day;
    const first = newDay || isSystem(prev) || (prev.author || "") !== (m.author || "") || prev.fromMe !== m.fromMe;
    const last = !next || isSystem(next) || (next.author || "") !== (m.author || "") || next.fromMe !== m.fromMe || dayLabel(next.t) !== day;
    const mark = m.id === unreadFrom ? (unreadN === 1 ? "1 mensagem não lida" : unreadN + " mensagens não lidas") : "";
    const row: Row = { id: m.id, m: m, day: newDay ? day : "", first: first || mark !== "", last: last, unread: mark };
    if (run.length > 1) { row.stickers = run; i += run.length - 1; }
    out.push(row);
  }
  return out;
}

export function Native() {
  const [conn, setConn] = createSignal("connecting");   // connecting | qr | ready | loggedOut | conflict | failed
  const [qrImage, setQrImage] = createSignal("");
  // WhatsApp Web's link-device screens: the QR, the phone number, the 8-character code
  const [linkMode, setLinkMode] = createSignal("qr");   // qr | phone | code
  const [country, setCountry] = createSignal(COUNTRIES[0]);
  const [phoneDigits, setPhoneDigits] = createSignal("");
  const [phoneError, setPhoneError] = createSignal("");
  const [askingCode, setAskingCode] = createSignal(false);
  const [pairCode, setPairCode] = createSignal("");
  const [chats, setChats] = createSignal<Chat[]>([]);
  // SMS through KDE Connect (opt-in: Configurações → SMS pelo KDE Connect): threads as Chats, kind "sms"
  const [smsChats, setSmsChats] = createSignal<Chat[]>([]);
  const [smsStatus, setSmsStatus] = createSignal<any>({ enabled: false });
  const [smsQuery, setSmsQuery] = createSignal("");          // the SMS tab's search
  const [smsContacts, setSmsContacts] = createSignal<any[]>([]);  // Sms.contacts: name, number, label
  const [smsPicked, setSmsPicked] = createSignal<string[]>([]);   // a new message's recipients (numbers)
  const [smsNewBody, setSmsNewBody] = createSignal("");
  const [sel, setSel] = createSignal("");
  const [msgs, setMsgs] = createSignal<Msg[]>([]);
  const [draft, setDraft] = createSignal("");
  const [filter, setFilter] = createSignal("");
  const [tab, setTab] = createSignal("all");   // all | unread | favorites | groups
  const [typing, setTyping] = createSignal<Record<string, string[]>>({});   // chat → who is typing (Presence.typingUserIds)
  const [recording, setRecording] = createSignal<Record<string, string[]>>({});
  const [online, setOnline] = createSignal("");
  const [nowPlaying, setNowPlaying] = createSignal("");
  const [viewer, setViewer] = createSignal<any>(null);       // {kind, source, title, subtitle, id}
  const [openWhenReady, setOpenWhenReady] = createSignal("");  // a message clicked while downloading
  // sending media: the attach menu, the file chooser, the preview with its caption, the recorder
  const [attachOpen, setAttachOpen] = createSignal(false);
  // the expressions panel (emoji, stickers) over the composer
  const [exprOpen, setExprOpen] = createSignal(false);
  const [stickerList, setStickerList] = createSignal<any[]>([]);
  // our own sticker packs (local groups for the panel, named by us): [{ id, name, stickers: [{ id, src }] }]
  const [packList, setPackList] = createSignal<any[]>([]);
  const [storeList, setStoreList] = createSignal<any[]>([]);
  const [packAsk, setPackAsk] = createSignal(false);
  const [packChoice, setPackChoice] = createSignal("");      // the pack a sticker goes into ("" = a new one)
  const [packAdded, setPackAdded] = createSignal(false);     // the sticker's own pack is already ours
  const [packStore, setPackStore] = createSignal(false);     // one of WhatsApp's store packs (a whole pack only)
  const [packName, setPackName] = createSignal("");
  let packTarget = "";
  const [pickReq, setPickReq] = createSignal("");
  // the send preview: the files picked or pasted, each with its caption; `stageAt` the one shown
  const [stagedList, setStagedList] = createSignal<any[]>([]);   // [{path, kind: media | document, name, caption}]
  const [stageAt, setStageAt] = createSignal(0);
  function staged() { const l = stagedList(); return l.length ? l[Math.min(stageAt(), l.length - 1)] : null; }
  const [caption, setCaption] = createSignal("");
  const [isRec, setIsRec] = createSignal(false);
  // message and chat menus (right click), reply / edit in the composer, the forward chooser
  const [menuMsg, setMenuMsg] = createSignal<any>(null);
  const [menuChat, setMenuChat] = createSignal<any>(null);
  const [replyTo, setReplyTo] = createSignal<any>(null);
  const [editing, setEditing] = createSignal<any>(null);
  const [forwarding, setForwarding] = createSignal<any>(null);   // the messages being forwarded
  const [fwdQuery, setFwdQuery] = createSignal("");
  const [fwdPicked, setFwdPicked] = createSignal<string[]>([]);
  const [listPx, setListPx] = createSignal(savedListWidth());
  const [convW, setConvW] = createSignal(800);   // the conversation pane's width (from the wallpaper)
  // the info drawer (WhatsApp Web's "Dados do contato" / "Dados do grupo")
  const [infoOpen, setInfoOpen] = createSignal(false);
  const [infoContact, setInfoContact] = createSignal<any>(null);
  const [infoGroup, setInfoGroup] = createSignal<any>(null);
  const [infoPic, setInfoPic] = createSignal("");
  // a person's details over the conversation (a group sender's name): not their chat until asked
  // the search box, answered by the core (Search.run: chats + messages, BM25, the match highlighted);
  // `searchScope` = a chat whose messages only are searched (the conversation's magnifier)
  const [searchScope, setSearchScope] = createSignal("");
  const [searchRes, setSearchRes] = createSignal<any>(null);
  const [flashId, setFlashId] = createSignal("");
  let searchSeq = 0;
  let pendingHit: any = null;
  // "Pesquisar mensagens" in the open chat (the header's magnifier): the core's full-text search
  const [chatSearchOpen, setChatSearchOpen] = createSignal(false);
  const [chatQuery, setChatQuery] = createSignal("");
  const [chatHits, setChatHits] = createSignal<any[]>([]);
  let chatSearchInput: any;
  let chatSearchSeq = 0;
  const [personId, setPersonId] = createSignal("");
  const [personK, setPersonK] = createSignal<any>(null);
  const [personPic, setPersonPic] = createSignal("");
  const [avHover, setAvHover] = createSignal(false);
  // the drawers slide out before they go (the class plays the animation, then they unmount)
  const [personClosing, setPersonClosing] = createSignal(false);
  const [infoClosing, setInfoClosing] = createSignal(false);
  // the navigation rail's tabs: chats | calls | status | channels | communities | media | profile
  const [panel, setPanel] = createSignal("chats");
  const [calls, setCalls] = createSignal<any[]>([]);
  const [statuses, setStatuses] = createSignal<any[]>([]);
  const [channelList, setChannelList] = createSignal<any[]>([]);
  const [communityList, setCommunityList] = createSignal<any[]>([]);
  const [mediaList, setMediaList] = createSignal<any[]>([]);
  // WhatsApp Web's "Mídia" panel: every chat's photos and videos, documents, links
  const [mediaOpen, setMediaOpen] = createSignal(false);
  const [mediaTab, setMediaTab] = createSignal("media");   // media | docs | links
  const [docList, setDocList] = createSignal<any[]>([]);
  const [linkList, setLinkList] = createSignal<any[]>([]);
  const [prevPanel, setPrevPanel] = createSignal("chats");
  const [me, setMe] = createSignal<any>(null);
  const [recSend, setRecSend] = createSignal(true);
  const [recElapsed, setRecElapsed] = createSignal(0);   // one voice note at a time, as WhatsApp
  const [syncing, setSyncing] = createSignal("");
  const [pending] = createSignal<Record<number, (res: any, err: any) => void>>({});
  const [nextId, setNextId] = createSignal(1);
  const [noteChats] = createSignal<Record<number, string>>({});

  let msgList: any;
  let msgMenu_unused: any;
  let reactMenu: any;
  let chatMenu: any;
  let muteMenu: any;
  let captionInput: any;
  let composerInput: any;

  // ---- the core ---------------------------------------------------------------------------------
  function call(method: string, params: any, done: (res: any, err: any) => void) {
    const id = nextId();
    setNextId(id + 1);
    pending()[id] = done;
    core.call(id, method, JSON.stringify(params));
  }
  function ignore(_res: any, _err: any) {}

  function onLine(l: string) {
    const o = JSON.parse(l);
    if (o.id !== undefined && o.id !== null) {
      const done = pending()[o.id];
      delete pending()[o.id];
      if (done) done(o.result, o.error);
      return;
    }
    onEvent(o.method, o.params);
  }

  // whatsapp://send?phone=5511…&text=… — links handed over by the .desktop's
  // x-scheme-handler/whatsapp (a second launch passes it to this window). Before the connection
  // is ready the link waits.
  const [pendingUrl, setPendingUrl] = createSignal("");
  function urlParam(url: string, key: string): string {
    const q = url.indexOf("?");
    if (q < 0) return "";
    const parts = url.substring(q + 1).split("&");
    for (let i = 0; i < parts.length; i++) {
      const eq = parts[i].indexOf("=");
      const k = eq < 0 ? parts[i] : parts[i].substring(0, eq);
      if (k === key) return decodeParam(eq < 0 ? "" : parts[i].substring(eq + 1));
    }
    return "";
  }
  function decodeParam(v: string): string {
    try { return decodeURIComponent(v.split("+").join(" ")); } catch (e) { return v; }
  }
  function digitsOnly(s: string): string {
    let d = "";
    for (let i = 0; i < s.length; i++) { const ch = s.charAt(i); if (ch >= "0" && ch <= "9") d += ch; }
    return d;
  }
  function openWhatsappUrl(url: string) {
    if (url === "") return;
    if (conn() !== "ready") { setPendingUrl(url); return; }
    const phone = digitsOnly(urlParam(url, "phone"));
    const text = urlParam(url, "text");
    if (phone === "") { if (text !== "") setDraft(text); return; }
    const id = phone + "@s.whatsapp.net";
    call("openChat", { id: id }, (_r: any, _e: any) => { openedFromUrl(id, text); });
  }
  function openedFromUrl(id: string, text: string) {
    closeSide();
    open(id);
    if (text !== "") setDraft(text);
  }
  function flushPendingUrl() {
    const u = pendingUrl();
    if (u === "") return;
    setPendingUrl("");
    openWhatsappUrl(u);
  }

  // The core's events are WhatsApp Web's collection events (Msg:add, Chat:change, …).
  function onEvent(method: string, p: any) {
    if (method === "App:openUrl") { openWhatsappUrl(p.url || ""); return; }
    if (method === "App:raise") return;
    if (method === "qr") { setQrImage(p.image ? "file://" + p.image : ""); setConn("qr"); return; }
    if (method === "paired") { setConn("connecting"); return; }
    if (method === "Conn:change") { onState(p.state); return; }
    if (method === "History:progress") { onHistory(p); return; }
    if (method === "Status:change") { loadStatuses(); return; }
    if (method === "Chat:change" || method === "Chat:add") { upsertChat(p); return; }
    if (method === "Chat:remove") { setChats(chats().filter((c) => c.id !== p.id)); return; }
    if (method === "Msg:add") { onMsgAdd(p); return; }
    if (method === "StickerPack:change") { if (exprOpen()) loadPacks(); return; }
    if (method === "Contact:change") { onContactChange(p); return; }
    if (method === "Recorder:level") { onRecLevel(p.level || 0); return; }
    if (method === "Msg:change") { replaceMsg(p); return; }
    if (method === "Msg:remove") { setMsgs(msgs().filter((m) => m.id !== p.id)); return; }
    if (method === "Presence:change") { onPresence(p); return; }
    if (method === "Call:offer") { notifyCall(p); return; }
    if (method === "coreExited") { setConn("failed"); return; }
    if (method === "ready") { if (smsOn()) smsEnable(true); return; }
    if (method === "Sms:status") { setSmsStatus(p); return; }
    if (method === "Sms:thread") { upsertSms(p); return; }
    if (method === "Sms:threadRemoved") { setSmsChats(smsChats().filter((c) => c.id !== p.id)); if (sel() === p.id) setSel(""); return; }
    if (method === "Sms:message") {
      if (p.fromMe) setMsgs(msgs().filter((x: any) => !(x.id.indexOf("sms-pending:") === 0 && x.remote === p.remote && x.body === p.body)));
      onMsgAdd(p);
      return;
    }
  }

  // WhatsApp Web's socket states.
  function onState(state: string) {
    if (state === "CONNECTED") { setSyncing(""); if (conn() !== "ready") { setConn("ready"); loadChats(); loadStatuses(); call("Profile.get", {}, (r: any, _e: any) => { if (r) setMe(r); }); flushPendingUrl(); } return; }
    if (state === "UNPAIRED") { setConn("loggedOut"); setChats([]); return; }
    if (state === "CONFLICT") { setConn("conflict"); return; }
    if (state === "OPENING" || state === "TIMEOUT") { if (conn() === "ready") setSyncing("Conectando…"); return; }
  }

  // History arrives in many chunks: reload once they settle.
  const [historyTick, setHistoryTick] = createSignal(0);
  function onHistory(p: any) {
    // the phone's answer to loadOlder: those messages go on top of the open conversation
    if (p.type === "ON_DEMAND") {
      if (p.chat && olderAsked[p.chat]) { olderAsked[p.chat] = false; if (p.chat === sel()) { if (!p.msgs) olderDone[p.chat] = true; olderBusy = false; loadOlder(); } }
      return;
    }
    setSyncing("Sincronizando mensagens… " + (p.progress || 0) + "%");
    const t = historyTick() + 1;
    setHistoryTick(t);
    setTimeout(() => historyDone(t), 1500);
  }
  function historyDone(t: number) {
    if (t !== historyTick()) return;
    setSyncing("");
    loadChats();
    if (sel() !== "") loadMessages(sel());
  }

  function loadChats() { call("Chat.list", {}, gotChats); }
  // ---- SMS (KDE Connect) ------------------------------------------------------------------------
  function isSms(id: string) { return id.indexOf("sms:") === 0; }
  function anyChat(id: string) { return chats().find((x) => x.id === id) || smsChats().find((x) => x.id === id); }
  function smsOn() { try { return JSON.parse(app.settingsJson).smsKdeConnect === true; } catch (e) { return false; } }
  function setSmsOn(on: boolean) { app.set("smsKdeConnect", on ? "true" : "false"); smsEnable(on); }
  function smsEnable(on: boolean) {
    call("Sms.enable", { on: on }, (r: any, _e: any) => {
      if (r) setSmsStatus(r);
      if (on) loadSms();
      else { setSmsChats([]); if (panel() === "sms") go("chats"); }
    });
  }
  function loadSms() { call("Sms.threads", {}, (r: any, _e: any) => setSmsChats(r || [])); }
  function upsertSms(c: Chat) { setSmsChats([c, ...smsChats().filter((x) => x.id !== c.id)].sort((a, b) => b.t - a.t)); }
  function smsDigits(t: string) { return t.replace(/[^0-9]/g, ""); }
  // the SMS tab's list, by name, number or last message
  function smsVisible() {
    const q = smsQuery().trim().toLowerCase();
    if (q === "") return smsChats();
    const d = smsDigits(q);
    return smsChats().filter((c: any) => c.name.toLowerCase().indexOf(q) >= 0
      || (c.lastMsg && (c.lastMsg.body || "").toLowerCase().indexOf(q) >= 0)
      || (d.length >= 3 && (c.addresses || []).some((a: string) => smsDigits(a).indexOf(d) >= 0)));
  }
  // ---- a new SMS to one or more people (several: a group MMS) -------------------------------
  function openSmsNew() {
    setSmsPicked([]);
    setSmsNewBody("");
    openSide("smsNew");
    call("Sms.contacts", {}, (r: any, _e: any) => setSmsContacts(r || []));
  }
  function smsCandidates() {
    const q = sideQuery().trim().toLowerCase();
    const d = smsDigits(q);
    const list = smsContacts().filter((k: any) => q === "" || k.name.toLowerCase().indexOf(q) >= 0 || (d.length >= 3 && smsDigits(k.number).indexOf(d) >= 0));
    // a number typed that is nobody's yet: offered as it is
    if (d.length >= 8 && !list.some((k: any) => smsDigits(k.number).slice(-8) === d.slice(-8)))
      return [{ name: "Enviar para " + q, number: q.trim(), label: q.trim(), typed: true }, ...list];
    return list;
  }
  function toggleSmsPick(n: string) {
    const cur = smsPicked();
    setSmsPicked(cur.indexOf(n) >= 0 ? cur.filter((x) => x !== n) : [...cur, n]);
  }
  function smsPickedNames() {
    return smsPicked().map((n) => { const k = smsContacts().find((x: any) => x.number === n); return k ? k.name : n; }).join(", ");
  }
  function sendSmsNew() {
    const body = smsNewBody().trim();
    if (body === "" || smsPicked().length === 0) return;
    call("Sms.send", { addresses: smsPicked(), body: body }, (_r: any, err: any) => {
      if (err) { setSideError("Não foi possível enviar: " + (err.message || "")); return; }
      closeSide();
      setTimeout(loadSms, 4000);   // the new thread comes back from the phone
    });
  }
  // a message sent but not yet confirmed by the phone shows with a clock; no confirmation in 90 s: failed
  function markSmsFailed(pid: string) { setMsgs(msgs().map((x: any) => (x.id === pid ? { ...x, ack: ACK.FAILED } : x))); }
  function smsUnread() { let n = 0; for (const c of smsChats()) n += c.unreadCount > 0 ? 1 : 0; return n; }
  function smsNote() {
    const st = smsStatus();
    if (st.error) return "KDE Connect: " + st.error;
    if (!st.reachable) return (st.device ? st.device : "O celular") + " está fora de alcance (KDE Connect)";
    return smsChats().length === 0 ? "Nenhuma conversa ainda. No celular, libere SMS e Contatos no app KDE Connect." : "";
  }
  function gotChats(res: any, _err: any) { if (res) setChats(sortChats(res)); }
  function sortChats(list: Chat[]) { return list.slice().sort(chatOrder); }
  function chatOrder(a: Chat, b: Chat) {
    if ((a.pin > 0) !== (b.pin > 0)) return a.pin > 0 ? -1 : 1;
    if (a.pin > 0 && a.pin !== b.pin) return b.pin - a.pin;
    return b.t - a.t;
  }
  function upsertChat(c: Chat) {
    const rest = chats().filter((x) => x.id !== c.id);
    let i = 0;
    while (i < rest.length && chatOrder(rest[i], c) <= 0) i++;   // the list is kept in chatOrder
    rest.splice(i, 0, c);
    setChats(rest);
  }

  // ---- a conversation ---------------------------------------------------------------------------
  // the open chat's unread mark (WhatsApp Web's "N mensagens não lidas"), and whether the list
  // shows its end (the ⌄⌄ button and its count of messages that came in below)
  const [unreadMark, setUnreadMark] = createSignal<{ chat: string; from: string; n: number }>({ chat: "", from: "", n: 0 });
  const [atBottom, setAtBottom] = createSignal(true);
  // the shown window stops short of the newest messages (a search jump into the past): scrolling down
  // loads the next pages, and live messages wait (appending them would leave a hidden gap)
  const [winBehind, setWinBehind] = createSignal(false);
  let newerBusy = false;
  function loadNewer() {
    const id = sel(), l = msgs();
    if (!winBehind() || newerBusy || id === "" || l.length === 0) return;
    newerBusy = true;
    const gen = winGen;
    call("Msg.list", { chat: id, afterId: l[l.length - 1].id, limit: 50 }, (res: any, _e: any) => {
      newerBusy = false;
      if (id !== sel() || !res || gen !== winGen) return;   // the window was replaced meanwhile
      const have: Record<string, boolean> = {};
      for (const m of msgs()) have[m.id] = true;
      const add = res.filter((m: any) => !have[m.id]);
      if (add.length > 0) { setMsgs([...msgs(), ...add]); autoFetch(add); }
      if (res.length < 50) {
        // the newest are loaded; they are read once the view gets down to them
        setWinBehind(false);
        if (atBottom()) setTimeout(() => {
          if (gen !== winGen || sel() !== id || winBehind()) return;   // another window since: not about it
          if (atBottom()) caughtUp(id); else pendingCaught = id;
        }, 300);
        else pendingCaught = id;
      }
      // a window that still fits the view never scrolls to its end: the next page right away
      else if (atBottom()) setTimeout(loadNewer, 50);
    });
  }
  // the newest messages are shown again: what came in meanwhile is read, the count clears
  function caughtUp(id: string) {
    setNewBelow(0);
    if (isSms(id)) call("Sms.markRead", { thread: id }, ignore); else call("sendSeen", { chat: id }, ignore);
  }
  const [newBelow, setNewBelow] = createSignal(0);
  let pendingCaught = "";   // the chat whose newest were loaded below the view: read when the view gets there
  let winGen = 0;           // the message window's generation: a new window (a chat, a jump) bumps it
  function onAtEnd(yes: boolean) {
    setAtBottom(yes);
    if (yes && winBehind()) loadNewer();
    else if (yes) { setNewBelow(0); if (pendingCaught !== "" && pendingCaught === sel()) { const id = pendingCaught; pendingCaught = ""; caughtUp(id); } }
  }
  let scrollWatchQ: any;
  function toBottom() {
    // behind the newest: the ⌄⌄ goes to the real end — the latest page again
    if (winBehind()) { setWinBehind(false); const id = sel(); loadMessages(id); caughtUp(id); return; }
    setNewBelow(0); if (scrollWatchQ && scrollWatchQ.glideToEnd) scrollWatchQ.glideToEnd(); else snapEnd(); }
  function snapEnd() { scrollEnd(); setTimeout(scrollEnd, 120); }
  const drafts: Record<string, string> = {};   // what was typed in each chat, kept when leaving it
  function open(id: string) {
    endMsgSelect();
    clearNote(id);   // opening the chat dismisses its notification
    const c0 = chats().find((x) => x.id === id);
    setUnreadMark({ chat: id, from: "", n: c0 ? c0.unreadCount : 0 });
    setNewBelow(0);
    setAtBottom(true);
    if (isGroup(id)) call("GroupMetadata.get", { id: id }, ignore);   // its admins-only / left state
    setInfoOpen(false);
    const prev = sel();
    if (prev !== "" && prev !== id) {
      if (editing() === null) drafts[prev] = draft();   // an unfinished edit is dropped, not kept as a draft
      setReplyTo(null);
      setEditing(null);
      setDraft(drafts[id] || "");
    }
    setSel(id);
    olderDone[id] = false;   // reopened: older pages may be asked again
    setMsgs([]);
    openedAt = Date.now();
    setOnline("");
    loadMessages(id);
    if (isSms(id)) call("Sms.markRead", { thread: id }, ignore);
    if (!isSms(id)) {
      call("sendSeen", { chat: id }, ignore);
      if (!isGroup(id)) call("subscribeUserPresence", { id: id }, ignore);
    }
    // typing right away, as WhatsApp Web: the search box (if it had the focus) lets go of it
    if (searchInput && searchInput.focus !== undefined) searchInput.focus = false;
    setTimeout(focusComposer, 30);
  }
  function loadMessages(id: string) {
    setWinBehind(false);
    pendingCaught = "";
    const gen = ++winGen;   // a later navigation (another load, a jump) makes this answer stale
    if (isSms(id)) { call("Sms.messages", { thread: id, count: 50 }, (res: any, err: any) => { if (gen === winGen) gotMessages(id, res, err); }); return; }
    call("Msg.list", { chat: id, limit: 50 }, (res: any, err: any) => { if (gen === winGen) { setWinBehind(false); gotMessages(id, res, err); } });
    // a channel's messages (and their reaction counts) live on its server
    if (isChannel(id)) call("Newsletter.refresh", { id: id }, (res: any, err: any) => { if (gen === winGen && res && res.length) gotMessages(id, res, err); });
  }
  function gotMessages(id: string, res: any, _err: any) {
    if (id !== sel() || !res) return;
    const mk = unreadMark();
    let firstUnread = "";
    if (mk.chat === id && mk.n > 0 && mk.from === "") {
      // the last N messages from others are the unread ones: the first of them gets the mark
      let left = mk.n;
      for (let i = res.length - 1; i >= 0 && left > 0; i--) { if (!res[i].fromMe && !isSystem(res[i])) { firstUnread = res[i].id; left--; } }
      if (firstUnread !== "") setUnreadMark({ chat: id, from: firstUnread, n: mk.n });
    }
    setMsgs(res);
    if (pendingHit !== null && pendingHit.remote === id) { const h = pendingHit; pendingHit = null; setTimeout(() => { if (h.remote === sel()) goToMsg(h); }, 120); }
    else if (firstUnread !== "") revealUnread(firstUnread); else toEnd();
    autoFetch(res);
  }
  // older messages as the conversation nears its top (WhatsApp Web's loadEarlierMsgs): from the store,
  // and past what it has, from the phone (an on-demand history sync, answered as History:progress)
  let olderBusy = false;
  let openedAt = 0;                                  // the list starts at its top: not a wish for older ones
  const olderAsked: Record<string, boolean> = {};
  const olderDone: Record<string, boolean> = {};
  function loadOlder() {
    const id = sel(), l = msgs();
    if (Date.now() - openedAt < 1500) return;
    if (id === "" || olderBusy || l.length === 0 || isChannel(id) || olderAsked[id] || olderDone[id]) return;
    olderBusy = true;
    const gen = winGen;   // the page extends this window only (a jump or a reload replaces it)
    // an SMS thread: the phone's newest N, N growing by a page (KDE Connect counts from the newest)
    if (isSms(id)) {
      call("Sms.messages", { thread: id, count: l.length + 50 }, (res: any, _err: any) => {
        olderBusy = false;
        if (id !== sel() || !res || gen !== winGen) return;
        const have: Record<string, boolean> = {};
        for (const m of msgs()) have[m.id] = true;
        const add = res.filter((m: any) => !have[m.id]);
        if (add.length > 0) setMsgs([...add, ...msgs()]); else olderDone[id] = true;
      });
      return;
    }
    // strictly before the oldest shown, by (time, store order): a second holding more than a page
    // is neither skipped nor repeated (the Go core ignores beforeId and pages by time)
    call("loadEarlierMsgs", { chat: id, before: l[0].t, beforeId: l[0].id, limit: 50 }, (res: any, _err: any) => {
      olderBusy = false;
      if (id !== sel() || !res || gen !== winGen) return;
      const have: Record<string, boolean> = {};
      for (const m of msgs()) have[m.id] = true;
      const add = res.filter((m: any) => !have[m.id]);
      if (add.length > 0) { setMsgs([...add, ...msgs()]); autoFetch(add); }
      if (res.length < 50) {
        // the rest was asked of the phone; if it never answers, asking again is allowed later
        olderAsked[id] = true;
        setTimeout(() => { olderAsked[id] = false; }, 30000);
      }
    });
  }
  // to the end first, then up to the mark: a list reveals an item above the view at its top
  function revealUnread(from: string) {
    const go = () => {
      if (!msgList || !msgList.reveal) return;
      const i = rowIndex(from);
      if (i < 0) return;
      msgList.reveal(rows().length - 1);
      msgList.reveal(i);
    };
    setTimeout(go, 30); setTimeout(go, 300);
  }
  // pictures load after the list is laid out and grow it: follow the end a few times while they do
  function toEnd() { setTimeout(scrollEnd, 30); setTimeout(scrollEnd, 300); setTimeout(scrollEnd, 900); }
  // the VirtualList's ref is its box, which reveals an index (ListView.Contain: the last one at the bottom)
  // the message pinned in the open chat (its bar under the header)
  function pinnedLine() {
    const c = selChat();
    const p = c ? c.pinnedMsg : null;
    if (!p) return "";
    const who = isGroup(c!.id) && !p.fromMe && p.senderName ? p.senderName + ": " : (p.fromMe && isGroup(c!.id) ? "Você: " : "");
    return oneLine(who + typeLabel(p.type, p.body));
  }
  function revealPinned() {
    const c = selChat();
    if (!c || !c.pinnedMsg || !msgList || !msgList.reveal) return;
    const i = rowIndex(c.pinnedMsg!.id);
    if (i >= 0) msgList.reveal(i);
  }
  // the list's model is rows (a sticker run is one row), not messages
  function scrollEnd() { const n = rows().length; if (n > 0 && msgList && msgList.reveal) msgList.reveal(n - 1); }

  // the status updates (the Status tab, and the ring round their authors' pictures in the list)
  let statusSeq = 0;
  function loadStatuses() { call("Status.list", {}, (r: any, _e: any) => { setStatuses(r || []); prefetchStatuses(r || []); }); }
  function statusSoon() { const q = ++statusSeq; setTimeout(() => { if (q === statusSeq) loadStatuses(); }, 800); }
  const storyOf = createMemo(() => {
    const o: any = {};
    // a muted person's updates: no green ring (as WhatsApp shows them, among the seen)
    for (const st of statuses()) if (!st.isMe) o[st.id] = st.viewed || st.muted ? "seen" : "new";
    return o;
  });
  function myPic() { const m = me(); return m && m.profilePicThumb && m.profilePicThumb !== "-" ? m.profilePicThumb : ""; }
  function storyState(id: string) { return storyOf()[id] || ""; }
  function onMsgAdd(m: Msg) {
    if (m.remote === "status@broadcast") statusSoon();
    if (m.remote === sel() && !m.fromMe && !atBottom()) setNewBelow(newBelow() + 1);
    if (m.remote === sel() && winBehind()) {
      // the newest pages are not shown: an own message brings the view to the end (as WhatsApp);
      // another is counted (once: the line above counts it when not at the bottom) and arrives
      // when the user goes down
      if (m.fromMe) toBottom();
      else if (atBottom()) setNewBelow(newBelow() + 1);
      return;
    }
    if (m.remote === sel()) {
      const wasBottom = atBottom();
      let next = [...msgs().filter((x) => x.id !== m.id), m];
      // reading at the end of a chat open for hours: the oldest go (scrolling up loads them again)
      if (wasBottom && next.length > 1500) { next = next.slice(next.length - 1000); olderDone[m.remote] = false; olderAsked[m.remote] = false; }
      setMsgs(next);
      if (wasBottom || m.fromMe) toEnd();
      autoFetch([m]);
      if (!m.fromMe && !isSms(m.remote)) call("sendSeen", { chat: m.remote }, ignore);
      if (!m.fromMe && isSms(m.remote)) call("Sms.markRead", { thread: m.remote }, ignore);
    } else if (!m.fromMe && !isSystem(m)) {
      notify(m);
    }
  }
  function replaceMsg(m: Msg) {
    // a status file the phone uploaded again (it had expired): to the viewer
    if (m.remote === "status@broadcast" && story() && mediaFile(m) !== "") gotStatusFile(m.id, m);
    if (m.remote === sel()) setMsgs(msgs().map((x) => (x.id === m.id ? m : x)));
    if (m.id === openWhenReady() && mediaFile(m) !== "") { setOpenWhenReady(""); openMedia(m); }
  }
  function onPresence(p: any) {
    const t = { ...typing() };
    t[p.id] = p.typingUserIds || [];
    setTyping(t);
    const r = { ...recording() };
    r[p.id] = p.recordingUserIds || [];
    setRecording(r);
    if (p.id === sel() && !isGroup(p.id)) setOnline(p.isOnline ? "online" : "");
  }

  function send() {
    const text = draft().trim();
    if (text === "" || sel() === "") return;
    setDraft("");
    if (isSms(sel())) {
      setReplyTo(null);
      setEditing(null);
      const chat = sel();
      const pid = "sms-pending:" + Date.now();
      setMsgs([...msgs(), { id: pid, remote: chat, fromMe: true, t: Math.floor(Date.now() / 1000), type: "chat", ack: ACK.CLOCK, body: text } as any]);
      toEnd();
      call("Sms.send", { thread: chat, body: text }, (r: any, err: any) => { if (err) { markSmsFailed(pid); sent(r, err); } });
      setTimeout(() => markSmsFailed(pid), 90000);
      return;
    }
    const ed = editing();
    if (ed) { setEditing(null); call("editMessage", { msg: ed.id, text: text }, sent); return; }
    const q = replyTo();
    setReplyTo(null);
    call("sendTextMsgToChat", q ? { chat: sel(), text: text, quotedMsg: q.id } : { chat: sel(), text: text }, sent);
  }
  // ---- a business message's buttons: a reply sends its text, a link opens, a number is called, a code
  // copied; a list shows its rows (each one a reply)
  const [openList, setOpenList] = createSignal("");
  function btnIcon(k: string) { return k === "url" ? "north-east" : k === "call" ? "voice-call" : k === "copy" ? "copy" : k === "list" ? "filter-list" : "reply"; }
  function msgButtons(m: Msg) {
    const out: any[] = [];
    for (const b of m.buttons || []) {
      out.push(b);
      if (b.kind === "list" && openList() === m.id) for (const r of (b.value || "").split("\n")) if (r !== "") out.push({ kind: "reply", text: r, row: true });
    }
    return out;
  }
  function pressButton(m: Msg, b: any) {
    if (b.kind === "url") app.openExternal(b.value || "");
    else if (b.kind === "call") app.openExternal("tel:" + (b.value || ""));
    else if (b.kind === "copy") look.copyText(b.value || "");
    else if (b.kind === "list") setOpenList(openList() === m.id ? "" : m.id);
    else { setOpenList(""); call("sendTextMsgToChat", { chat: m.remote, text: b.text, quotedMsg: m.id }, sent); }
  }
  // ---- the message menu (WhatsApp Web's: reply, react, copy, forward, star, edit, download, delete)
  let mbtn1: any, mref1: any;
  let mbtn2: any, mref2: any;
  let mbtn3: any, mref3: any;
  let mbtn4: any, mref4: any;
  let mbtn5: any, mref5: any;
  let mbtn6: any, mref6: any;
  // a button's menu opens under the button (scene coordinates from the button's own item)
  function openUnder(menu: any, btn: any) {
    if (!menu || !menu.open || !btn) return;
    const p = btn.mapToItem(null, 0, btn.height + 4);
    menu.open(p.x, p.y);
  }
  let menuX = 0, menuY = 0;   // where the last context menu opened (a follow-up menu opens there too)
  function openMsgMenu(m: Msg, x: number, y: number) {
    menuX = x; menuY = y;
    if (isSystem(m)) return;
    setMenuMsg(m);
    if (msgMenuQ && msgMenuQ.openAt) msgMenuQ.openAt(x, y);
  }
  let msgMenuQ: any;
  // Meta AI: its chat, opened from the rail; "Pergunte à Meta AI" brings the message's words along
  function openMetaAI(about: string) {
    setPanel("chats");
    call("openChat", { id: META_AI }, (_r: any, _e: any) => {
      open(META_AI);
      if (about !== "") { setDraft("\"" + oneLine(about) + "\" "); setTimeout(focusComposer, 50); }
    });
  }
  // "Fixar": for how long, as WhatsApp Web asks
  const [pinAsk, setPinAsk] = createSignal(false);
  const [pinFor, setPinFor] = createSignal(7 * 86400);
  let pinTarget: any = null;
  function pinNow() {
    setPinAsk(false);
    if (pinTarget) call("sendPinInChat", { msg: pinTarget.id, pin: true, seconds: pinFor() }, actionDone);
    pinTarget = null;
  }
  // "+" in the reaction bar: any emoji, from the whole list
  const [reactPick, setReactPick] = createSignal(false);
  let reactTarget: any = null;
  function reactWith(e: string) {
    setReactPick(false);
    if (reactTarget) call("sendReactionToMsg", { msg: reactTarget.id, reactionText: e }, actionDone);
    reactTarget = null;
  }
  // WhatsApp Web's message menu, in its order, with its icons
  function msgItems() {
    const m = mm();
    if (!m) return [];
    const c = tk().fg;
    const l: any[] = [{ id: "reply", label: "Responder", icon: ic("reply", c) }];
    l.push({ id: "select", label: "Selecionar", icon: ic("checkbox", c) });
    if (hasText(m)) l.push({ id: "copy", label: "Copiar", icon: ic("copy", c) });
    if (isPictureMsg(m)) l.push({ id: "copy-image", label: "Copiar imagem", icon: ic("copy", c) });
    if (isStickerMsg(m) && !m.stickerPack) l.push({ id: "add-pack", label: "Adicionar pacote…", icon: ic("plus", c) });
    if (isStickerMsg(m) && !!m.stickerPack) l.push({ id: "remove-pack", label: "Remover pacote", icon: ic("delete", c) });
    if (isStickerMsg(m)) l.push({ id: "fav-sticker", label: m.isFavoriteSticker ? "Remover dos favoritos" : "Adicionar aos favoritos", icon: ic("star", c) });
    l.push({ id: "react", label: "Reagir", icon: ic("emoji", c) });
    l.push({ id: "forward", label: "Encaminhar", icon: ic("forward", c) });
    const pinned = !!selChat() && !!selChat()!.pinnedMsg && selChat()!.pinnedMsg!.id === m.id;
    if (m.type !== "revoked") l.push({ id: pinned ? "unpin" : "pin", label: pinned ? "Desafixar" : "Fixar", icon: ic("pin", c) });
    if (hasText(m) && m.remote !== META_AI) l.push({ id: "meta-ai", label: "Pergunte à Meta AI", icon: ic("meta-ai", c) });
    l.push({ id: "star", label: m.star ? "Desfavoritar" : "Favoritar", icon: ic("star", c) });
    if (canEdit(m)) l.push({ id: "edit", label: "Editar", icon: ic("edit", c) });
    if (hasMedia(m)) l.push({ id: "download", label: "Baixar", icon: ic("download", c) });
    l.push({ id: "delete-me", label: "Apagar para mim", icon: ic("delete", c), sep: true });
    if (canRevoke(m)) l.push({ id: "delete-all", label: "Apagar para todos", icon: ic("delete", c) });
    return l;
  }
  function myReaction() {
    const m = mm();
    if (!m || !m.reactions) return "";
    for (const r of m.reactions) if (r.hasReactionByMe) return r.aggregateEmoji;
    return "";
  }
  function msgAction(id: string) {
    if (id === "reply") reply();
    else if (id === "select") { const m = mm(); if (m) startMsgSelect(m.id); }
    else if (id === "copy") copyMsg();
    else if (id === "copy-image") copyImageMsg();
    else if (id === "fav-sticker") favStickerMsg();
    else if (id === "add-pack") openPackAsk();
    else if (id === "remove-pack") removePackOf();
    else if (id === "react" || id === "react-more") { reactTarget = mm(); setReactPick(true); }
    else if (id === "forward") forwardMsg();
    else if (id === "pin") { pinTarget = mm(); setPinFor(7 * 86400); setPinAsk(true); }
    else if (id === "unpin") { const m = mm(); if (m) call("sendPinInChat", { msg: m.id, pin: false }, ignore); }
    else if (id === "meta-ai") { const m = mm(); if (m) openMetaAI(m.body || m.caption || ""); }
    else if (id === "star") starMsg();
    else if (id === "edit") editMsg();
    else if (id === "download") downloadMsg();
    else if (id === "delete-me") deleteForMe();
    else if (id === "delete-all") deleteForAll();
  }
  function mm() { return menuMsg(); }
  function canEdit(m: any) { return !!m && m.fromMe && m.type === "chat" && Date.now() / 1000 - m.t < 15 * 60; }
  function canRevoke(m: any) { return !!m && m.fromMe && m.type !== "revoked" && Date.now() / 1000 - m.t < 2 * 86400; }
  function hasText(m: any) { return !!m && !!(m.body || m.caption); }
  function hasMedia(m: any) { return !!m && !!m.mediaData; }
function isStickerMsg(m: any) { return !!m && m.type === "sticker"; }
function isPictureMsg(m: any) { return !!m && !!m.mediaData && (m.type === "image" || m.type === "sticker"); }
  function focusComposer() { if (composerInput && composerInput.forceActiveFocus) composerInput.forceActiveFocus(); }
  function reply() { const m = mm(); if (m) { setEditing(null); setReplyTo(m); setTimeout(focusComposer, 30); } }
  function react(e: string) { const m = mm(); if (m) call("sendReactionToMsg", { msg: m.id, reactionText: e }, actionDone); }
  function openReact() { if (reactMenu && reactMenu.open) reactMenu.open(menuX, menuY); }
  function copyMsg() { const m = mm(); if (m) look.copyText(m.body || m.caption || ""); }
  // a sticker's "Adicionar aos favoritos" / "Remover dos favoritos" (the core says which applies)
  // "Adicionar pacote…": the sticker's pack (its name pre-filled), kept under the name we give it
  function openPackAsk() { const m = mm(); if (!m) return; packTarget = m.id; call("StickerPack.info", { msg: m.id }, (r: any, _e: any) => { gotPackInfo(r); }); }
  // into one of our packs, or its own pack as a new one (not offered when that pack is ours already)
  function gotPackInfo(r: any) {
    const added = !!(r && r.added);
    if (added && packList().length === 0) return;
    setPackAdded(added);
    setPackStore(false);
    setPackName(r && r.name ? r.name : "");
    setPackChoice(added && packList().length > 0 ? packList()[0].id : "");
    setPackAsk(true);
  }
  function removePackOf() { const m = mm(); if (m && m.stickerPack) call("StickerPack.remove", { id: m.stickerPack }, (_r: any, _e: any) => { loadPacks(); }); }
  function addPackNow() {
    setPackAsk(false);
    if (packChoice() !== "" && packTarget.indexOf("store:") !== 0) call("StickerPack.addTo", { msg: packTarget, pack: packChoice() }, (r: any, _e: any) => { if (r) setPacks(r); });
    else if (packTarget.indexOf("store:") === 0) call("StickerPack.addStore", { id: packTarget.substring(6), name: packName() }, (r: any, _e: any) => { if (r) setPacks(r); });
    else if (packTarget !== "") call("StickerPack.add", { msg: packTarget, name: packName() }, (r: any, _e: any) => { if (r) setPacks(r); });
    packTarget = "";
  }
  // one of WhatsApp's own packs, from the panel's "+": named like any pack of ours (unless we have it)
  function askStorePack(id: string, name: string) { if (packList().some((p: any) => p.id === id)) return; packTarget = "store:" + id; setPackStore(true); setPackName(name); setPackChoice(""); setPackAdded(false); setPackAsk(true); }
  function loadPacks() { call("StickerPack.list", {}, (r: any, _e: any) => { if (r) setPacks(r); }); }
  function setPacks(r: any) { setPackList((r || []).map((p: any) => ({ id: p.id, name: p.name, stickers: (p.stickers || []).map((m: any) => ({ id: m.id, src: mediaFile(m) !== "" ? "file://" + mediaFile(m) : "" })).filter((it: any) => it.src !== "") }))); }
  function favStickerMsg() { const m = mm(); if (m) call("setFavoriteSticker", { msg: m.id, favorite: !m.isFavoriteSticker }, actionDone); }
  // "Copiar imagem": the picture's file (downloaded first when it is not here yet)
  function copyImageMsg() {
    const m = mm();
    if (!m) return;
    const f = mediaFile(m);
    if (f !== "") look.copyImage(f); else call("downloadMedia", { msg: m.id }, (res: any, _e: any) => { copyDownloaded(res); });
  }
  function copyDownloaded(res: any) {
    if (res && res.mediaData && res.mediaData.renderableUrl) look.copyImage(res.mediaData.renderableUrl);
  }
  function starMsg() { const m = mm(); if (m) call("sendStarMsgs", { msgs: [m.id], star: !m.star }, actionDone); }
  function editMsg() { const m = mm(); if (m) { setReplyTo(null); setEditing(m); setDraft(m.body || ""); setTimeout(focusComposer, 30); } }
  function deleteForMe() { const m = mm(); if (m) call("sendDeleteMsgs", { msgs: [m.id] }, actionDone); }
  function deleteForAll() { const m = mm(); if (m) call("sendRevoke", { msgs: [m.id] }, actionDone); }
  function downloadMsg() {
    const m = mm();
    if (!m) return;
    const f = mediaFile(m);
    if (f !== "") app.reveal(f); else call("downloadMedia", { msg: m.id }, (res: any, _e: any) => { if (res && res.mediaData && res.mediaData.renderableUrl) app.reveal(res.mediaData.renderableUrl); });
  }
  function cancelCompose() { setReplyTo(null); if (editing()) { setEditing(null); setDraft(""); } }
  function replyWho(m: any) { return m.fromMe ? "Você" : (m.senderName || (selChat() ? title(selChat()!) : "")); }

  // ---- selecting messages (WhatsApp Web's "Selecionar mensagens": a bar over the header, a checkbox
  // on each bubble, batch forward / star / delete) ----------------------------------------------
  const [msgSelecting, setMsgSelecting] = createSignal(false);
  const [delAsk, setDelAsk] = createSignal(false);
  const [pickedMsgs, setPickedMsgs] = createSignal<string[]>([]);
  function startMsgSelect(id: string) { setPickedMsgs(id ? [id] : []); setMsgSelecting(true); }
  function endMsgSelect() { setMsgSelecting(false); setPickedMsgs([]); setDelAsk(false); }
  function toggleMsgPick(id: string) {
    const p = pickedMsgs();
    setPickedMsgs(p.indexOf(id) >= 0 ? p.filter((x) => x !== id) : [...p, id]);
  }
  function pickedIsSet(id: string) { return pickedMsgs().indexOf(id) >= 0; }
  function selectedMsgs() { const set: any = {}; for (const id of pickedMsgs()) set[id] = true; return msgs().filter((m) => set[m.id]); }
  // all selected sent by me, still revocable → "Apagar para todos" is offered
  function canRevokeAll() { const l = selectedMsgs(); return l.length > 0 && l.every((m) => canRevoke(m)); }
  function selForward() { const l = selectedMsgs(); if (l.length) { setFwdQuery(""); setFwdPicked([]); setForwarding(l); endMsgSelect(); } }
  function selStar() {
    const l = selectedMsgs();
    if (!l.length) return;
    const star = !l.every((m) => m.star); // if any is unstarred, star all; else unstar all
    call("sendStarMsgs", { msgs: l.map((m) => m.id), star: star }, actionDone);
    endMsgSelect();
  }
  function selDeleteForMe() { const l = selectedMsgs(); if (l.length) call("sendDeleteMsgs", { msgs: l.map((m) => m.id) }, actionDone); endMsgSelect(); }
  function selDeleteForAll() { const l = selectedMsgs(); if (l.length) call("sendRevoke", { msgs: l.map((m) => m.id) }, actionDone); endMsgSelect(); }

  // ---- forwarding (WhatsApp Web's "Encaminhar mensagem para": search, pick chats, send) ----------
  function forwardMsg() { const m = mm(); if (m) { setFwdQuery(""); setFwdPicked([]); setForwarding([m]); } }
  const fwdChats = createMemo(() => chats().filter((c) => fwdQuery() === "" || title(c).toLowerCase().indexOf(fwdQuery().toLowerCase()) >= 0).slice(0, 60));
  function fwdToggle(id: string) {
    const p = fwdPicked();
    setFwdPicked(p.indexOf(id) >= 0 ? p.filter((x) => x !== id) : [...p, id]);
  }
  // "Meu status" is a destination for what a status can be: photos, videos and text
  // "Meu status" accepts only photos and videos as a forward target (a text status is created another
  // way), so the option appears only when every selected message is a photo or a video
  function fwdToStatusOk() { const l = forwarding(); return !!l && l.every((m: any) => m.type === "image" || m.type === "video"); }
  function fwdOn(id: string) { return fwdPicked().indexOf(id) >= 0; }
  function fwdSend() {
    const f = forwarding();
    if (!f || fwdPicked().length === 0) return;
    call("forwardMessages", { msgs: f.map((m: Msg) => m.id), chats: fwdPicked() }, sent);
    setForwarding(null);
  }
  function fwdNames() { return fwdPicked().map((id) => { if (id === "status@broadcast") return "Meu status"; const c = chats().find((x) => x.id === id); return c ? title(c) : shortJid(id); }).join(", "); }

  // ---- the chat menu (archive, mute, pin, unread, clear, delete) --------------------------------
  function openChatMenu(c: Chat, x: number, y: number) {
    menuX = x; menuY = y;
    setMenuChat(c);
    if (chatMenu && chatMenu.open) chatMenu.open(x, y);
  }
  function mc() { return menuChat(); }
  function chatAct(method: string, extra: any) { const c = mc(); if (c) call(method, { chat: c.id, ...extra }, actionDone); }
  function openMute() { if (muteMenu && muteMenu.open) muteMenu.open(menuX, menuY); }
  function muteFor(seconds: number) { chatAct("sendConversationMute", { expiration: seconds < 0 ? -1 : Math.floor(Date.now() / 1000) + seconds }); }
  function markUnreadOrRead() {
    const c = mc();
    if (!c) return;
    if (c.unreadCount > 0 || c.markedUnread) chatAct("sendSeen", {}); else chatAct("markUnread", {});
  }
  // the ⋮ menus: the list's (WAWebChatListHeaderMenu) and the open conversation's
  function markAllRead() { for (const c of chats()) if (c.unreadCount > 0 || c.markedUnread) call("sendSeen", { chat: c.id }, ignore); }
  // where we can't write, WhatsApp Web's footer says why instead of the composer
  function readOnlyNote() {
    const c = selChat();
    if (!c) return "";
    if (c.id.indexOf("@broadcast") > 0) return "Use o WhatsApp no seu celular para enviar mensagens para listas de transmissão.";
    if (c.isAnnounceGrpRestrict) return "Apenas admins podem enviar mensagens.";
    if (c.isReadOnly) return isGroup(c.id) ? "Você não pode enviar mensagens para este grupo porque não é mais participante."
      : "Você não pode enviar mensagens para esta conversa.";
    return "";
  }
  // the conversation menu acts on the open chat
  function cv(method: string, extra: any) { const c = selChat(); if (c) call(method, { chat: c.id, ...extra }, ignore); }
  // "rgba(r, g, b, a)" → "#AARRGGBB": a QML color property does not read CSS's rgba()
  function qcolor(c: string) {
    if (c.indexOf("rgba(") !== 0) return c;
    const p = c.slice(5, c.length - 1).split(",");
    const h = (n: number) => { const x = Math.max(0, Math.min(255, Math.round(n))).toString(16); return x.length < 2 ? "0" + x : x; };
    return "#" + h(parseFloat(p[3]) * 255) + h(parseFloat(p[0])) + h(parseFloat(p[1])) + h(parseFloat(p[2]));
  }
  function introW() { return Math.max(160, Math.min(560, convW() - 80)); }
  function deleteChat() { const c = mc(); if (c) { if (c.id === sel()) setSel(""); chatAct("sendDelete", {}); } }

  // ---- links in the text ------------------------------------------------------------------------
  function openLink(url: string) { app.openExternal(url); }
  // the layout twin of a message's text: the words without WhatsApp's markup markers (*_~`), which
  // the rich text does not draw — the engine wraps this, MsgText.qml draws over it
  function ghost(t: string) { return mdGhost(t).split("*").join("").split("_").join("").split("~").join("").split("`").join(""); }
  // markdown rows as the text measures them: a table row's cells spaced as drawn, a third more height
  // per row (its padding and rules), headings without their #
  function isRow(l: string) { return l.length > 1 && l.charAt(0) === "|" && l.charAt(l.length - 1) === "|"; }
  function isRule(l: string) { for (let i = 0; i < l.length; i++) if ("|-: ".indexOf(l.charAt(i)) < 0) return false; return true; }
  function noHashes(l: string) { let i = 0; while (i < l.length && l.charAt(i) === "#") i++; return i > 0 && l.charAt(i) === " " ? l.substring(i + 1) : l; }
  function mdGhost(t: string) {
    const out: string[] = [];
    let k = 0;
    for (const l of t.split("\n")) {
      const tl = l.trim();
      if (isRow(tl)) {
        if (isRule(tl)) { out.push(""); continue; }
        out.push(tl.split("|").join("   "));
        k++;
        if (k % 2 === 0) out.push("");
      } else { k = 0; out.push(noHashes(l)); }
    }
    return out.join("\n");
  }
  // the same for one line (the chat list, notifications): no rules, no #, cells apart
  function mdLine(t: string) {
    const out: string[] = [];
    let inTable = false;
    // a table's rows may come already joined ("| a | b | | 1 | 2 |"): apart again; only its first row shows
    for (const l of t.split("| |").join("|\n|").split("\n")) {
      const tl = l.trim();
      if (isRow(tl)) {
        if (!inTable && !isRule(tl)) out.push(tl.substring(1, tl.length - 1).split("|").map((x) => x.trim()).join(" · "));
        inTable = true;
      } else { inTable = false; out.push(noHashes(tl)); }
    }
    return out.join(" ").split("**").join("");
  }
  function hasPreview(m: Msg) { return !!m.title && m.type === "chat"; }
  function previewThumb(m: Msg) { return m.thumbnail ? "data:image/jpeg;base64," + m.thumbnail : ""; }
  function domain(u: string) {
    let d = u.indexOf("://") >= 0 ? u.substring(u.indexOf("://") + 3) : u;
    if (d.indexOf("/") >= 0) d = d.substring(0, d.indexOf("/"));
    return d.indexOf("www.") === 0 ? d.substring(4) : d;
  }

  // ---- the navigation rail's tabs ----------------------------------------------------------------
  function go(p: string) {
    if (p !== "media") setPrevPanel(p);
    setMediaOpen(false);
    setPanel(p);
    setShowArchived(false);
    setSide("");
    endSelect();
    if (p === "calls") call("Msg.byType", { types: ["call_log"], limit: 200 }, (r: any, _e: any) => setCalls(r || []));
    if (p === "status") call("Status.list", {}, (r: any, _e: any) => setStatuses(r || []));
    if (p === "channels") call("Channel.list", {}, (r: any, _e: any) => setChannelList(r || []));
    if (p === "sms") loadSms();
    if (p === "communities") call("Community.list", {}, (r: any, _e: any) => setCommunityList(r || []));
    if (p === "media") { setPanel(prevPanel()); openMediaPanel(); return; }
    if (p === "profile") call("Profile.get", {}, (r: any, _e: any) => setMe(r));
  }
  function panelTitle() {
    const p = panel();
    return p === "calls" ? "Ligações" : p === "status" ? "Status" : p === "channels" ? "Canais" : p === "sms" ? "SMS" : p === "communities" ? "Comunidades" : p === "media" ? "Mídia" : "Perfil";
  }
  function navColor(p: string) { return panel() === p ? tk().fg : tk().muted; }
  function openFromPanel(chat: string) { setPanel("chats"); open(chat); }
  function callLabel(m: any) {
    const missed = m.callOutcome === "MISSED" || (m.subtype || "").indexOf("miss") === 0;
    return (missed ? "Perdida" : "Atendida") + " · " + when(m.t);
  }
  function callMissed(m: any) { return m.callOutcome === "MISSED" || (m.subtype || "").indexOf("miss") === 0; }
  function statusWhen(t: number) { const n = daysAgo(t); return (n === 0 ? "Hoje" : "Ontem") + " às " + clock(t); }
  // ---- the status viewer (Story.qml): one author's updates, in turn ----------------------------
  const [story, setStory] = createSignal<any>(null);        // the author being watched
  const [storyItems, setStoryItems] = createSignal<any[]>([]);
  function storyItem(m: any) {
    const base = { id: m.id, when: statusWhen(m.t), caption: m.caption || "", viewed: !!m.viewed };
    if (m.type === "chat") {
      const words = (m.body || "").split(" ").length;
      return { ...base, kind: "text", text: m.body || "", bg: m.backgroundColor || "", fg: m.textColor && m.textColor.indexOf("#00") !== 0 ? m.textColor : "", font: m.font || 0, seconds: Math.max(5, Math.min(15, Math.round(words / 3))) };
    }
    const f = mediaFile(m) || statusFile[m.id] || "";
    const kind = m.type === "video" ? "video" : "image";
    // while it downloads: the message's own little preview, under the spinner
    const thumb = m.mediaData && m.mediaData.preview ? "data:image/jpeg;base64," + m.mediaData.preview : "";
    return f === "" ? { ...base, kind: "loading", want: kind, thumb: thumb } : { ...base, kind: kind, source: "file://" + f, seconds: kind === "video" ? 0 : 6 };
  }
  function watchStatus(st: any, fromEnd?: boolean) {
    // WhatsApp Web opens at the first update not seen yet (at the last one, coming back)
    const first = st.items.findIndex((m: any) => !m.viewed);
    storyStart = fromEnd ? st.items.length - 1 : first < 0 ? 0 : first;
    setStoryItems(st.items.map(storyItem));
    setStory(st);
    for (let i = 0; i < st.items.length; i++) fetchStory(i);
  }
  let storyStart = 0;
  // the status updates' pictures and videos fetched ahead (WhatsApp's phones do): the unseen ones,
  // not the muted, three at a time — opened, they show at once
  const statusFile: Record<string, string> = {};
  const statusQueued: Record<string, boolean> = {};
  let statusQ: string[] = [];
  let statusActive = 0;
  // only the first unseen IMAGE of each unseen person is prefetched (what opening Status shows first):
  // videos and the rest download on demand in the viewer. A small budget keeps a big backlog from
  // draining network/CPU/disk in the background (adversarial review P1-2).
  const STATUS_PREFETCH_MAX = 12;
  function prefetchStatuses(list: any[]) {
    let budget = STATUS_PREFETCH_MAX - statusQ.length;
    for (const st of list) {
      if (budget <= 0) break;
      if (st.isMe || st.muted || st.viewed) continue;
      for (const m of st.items) {
        if (m.type !== "image" || m.viewed || mediaFile(m) !== "" || statusQueued[m.id]) continue;
        statusQueued[m.id] = true;
        statusQ.push(m.id);
        budget--;
        break; // one per person is enough to make opening Status feel instant
      }
    }
    pumpStatuses();
  }
  function pumpStatuses() {
    while (statusActive < 3 && statusQ.length > 0) {
      const id = statusQ.shift()!;
      statusActive++;
      call("downloadMedia", { msg: id }, (res: any, _e: any) => {
        statusActive--;
        gotStatusFile(id, res);
        pumpStatuses();
      });
    }
  }
  // a status file is here (downloaded ahead, or re-uploaded by the phone): the viewer shows it
  function gotStatusFile(id: string, res: any) {
    const f = res && res.mediaData && res.mediaData.renderableUrl ? res.mediaData.renderableUrl : "";
    if (f === "") return;
    statusFile[id] = f;
    const l = storyItems();
    const i = l.findIndex((x: any) => x.id === id);
    if (i >= 0 && l[i].kind === "loading") {
      const n = l.slice();
      n[i] = { ...n[i], kind: n[i].want, source: "file://" + f, seconds: n[i].want === "video" ? 0 : 6 };
      setStoryItems(n);
    }
  }
  function fetchStory(i: number) {
    const st = story();
    if (!st || storyItems()[i].kind !== "loading") return;
    const m = st.items[i];
    call("downloadMedia", { msg: m.id }, (res: any, _e: any) => { if (story() === st) gotStatusFile(m.id, res); });
  }
  function storyShown(i: number) {
    const st = story();
    if (!st || st.isMe) return;
    const it = storyItems()[i];
    if (it && !it.viewed) {
      call("sendStatusSeen", { msg: it.id }, ignore);
      const l = storyItems().slice();
      l[i] = { ...l[i], viewed: true };
      setStoryItems(l);
    }
  }
  function storyReply(i: number, text: string) {
    const st = story();
    if (!st) return;
    call("sendTextMsgToChat", { chat: st.id, text: text, quotedMsg: storyItems()[i].id }, ignore);
  }
  // save a status to disk / forward it (to my status or a chat) — beyond WhatsApp Web
  const [storyNotice, setStoryNotice] = createSignal("");
  function storySave(i: number) {
    const it = storyItems()[i];
    if (!it) return;
    let dir = "";
    try { dir = JSON.parse(app.settingsJson).downloadDir || ""; } catch (e) {}
    call("saveMedia", { msg: it.id, path: dir }, (r: any, e: any) => {
      setStoryNotice(e || !r ? "Não foi possível salvar" : "Salvo em " + r.path.split("/").slice(-2).join("/"));
      setTimeout(() => setStoryNotice(""), 2500);
    });
  }
  function storyShare(i: number) {
    const st = story();
    if (!st) return;
    const m = st.items[i];
    storyClose();
    setFwdQuery("");
    setFwdPicked([]);
    setForwarding([m]);
  }
  // the next (or previous) person's updates, in the list's order (Recentes, then Vistas) — as
  // WhatsApp Web goes on from one person to the next; past either end, the viewer closes
  function storyAuthor(dir: number) {
    const cur = story();
    if (!cur) return;
    // a muted person's updates go on among the muted only (WhatsApp does not play them in turn)
    const order = cur.isMe ? myStatus() : cur.muted ? mutedStatus() : [...recentStatus(), ...seenStatus()];
    const i = order.findIndex((x: any) => x.id === cur.id);
    const next = i >= 0 ? order[i + dir] : null;
    if (!next) { if (dir > 0) storyClose(); return; }
    setStory(null);
    setTimeout(() => watchStatus(next, dir < 0), 0);
  }
  function storyClose() { setStory(null); setStoryItems([]); call("Status.list", {}, (r: any, _e: any) => setStatuses(r || [])); }
  const recentStatus = createMemo(() => statuses().filter((s: any) => !s.isMe && !s.muted && !s.viewed));
  const seenStatus = createMemo(() => statuses().filter((s: any) => !s.isMe && !s.muted && s.viewed));
  const mutedStatus = createMemo(() => statuses().filter((s: any) => !s.isMe && s.muted));
  const [mutedOpen, setMutedOpen] = createSignal(false);
  function mutedOpenToggle() { setMutedOpen(!mutedOpen()); }
  // mute (or unmute) the open viewer's person ("Silenciar" in WhatsApp's viewer menu)
  function storyMute() {
    const cur = story();
    if (!cur || cur.isMe) return;
    setStory({ ...cur, muted: !cur.muted });
    setStatusMute(cur, !cur.muted);
  }
  // a person's status updates muted or not (WhatsApp's "Silenciar" in the status menus)
  function setStatusMute(st: any, muted: boolean) {
    setStatuses(statuses().map((x: any) => x.id === st.id ? { ...x, muted: muted } : x));
    call("sendStatusMute", { id: st.id, muted: muted }, (_r: any, err: any) => {
      const note = err ? "Não foi possível " + (muted ? "silenciar" : "reativar o som") : muted ? "Status de " + st.name + " silenciados" : "Som dos status de " + st.name + " reativado";
      if (story()) { setStoryNotice(note); setTimeout(() => setStoryNotice(""), 2500); } else setSyncing(note);
      if (!story()) setTimeout(() => setSyncing(""), 2500);
      if (err) loadStatuses();
    });
  }
  // the status row's context menu (right click)
  let statusMenu: any;
  const [menuStatus, setMenuStatus] = createSignal<any>(null);
  function openStatusMenu(st: any, x: number, y: number) {
    if (st.isMe) return;
    setMenuStatus(st);
    if (statusMenu && statusMenu.open) statusMenu.open(x, y);
  }
  const myStatus = createMemo(() => statuses().filter((s: any) => s.isMe));

  function followers(n: number) { return (n >= 1000 ? (n / 1000).toFixed(1).replace(".", ",") + " mil" : "" + n) + " seguidores"; }
  function openChannel(c: any) { if (c.invite) app.openExternal("https://whatsapp.com/channel/" + c.invite); }
  function mediaThumb(m: any) {
    const d = m.mediaData;
    if (!d) return "";
    if (d.mediaStage === "RESOLVED" && d.renderableUrl && m.type === "image") return "file://" + d.renderableUrl;
    if (d.thumbnailHQ) return "file://" + d.thumbnailHQ;
    return d.preview ? "data:image/jpeg;base64," + d.preview : "";
  }
  // the theme: "" follows the light/dark setting; another name is one of THEMES (whose base sets that setting too)
  function savedTheme() { try { const v = JSON.parse(app.settingsJson).nativeTheme; return typeof v === "string" ? v : ""; } catch (e) { return ""; } }
  const [themeId, setThemeId] = createSignal(savedTheme());
  const [themeOpen, setThemeOpen] = createSignal(false);
  function theme() { const id = themeId(); return THEMES.find((x) => x.id === id) || null; }
  function isDark() { const t = theme(); return t ? t.dark : app.dark; }
  function themeName() { const t = theme(); return t ? t.name : (app.dark ? "Escuro" : "Claro"); }
  function setTheme(id: string) {
    setThemeId(id === "light" || id === "dark" ? "" : id);
    app.set("nativeTheme", JSON.stringify(themeId()));
    const dark = id === "dark" || (!!theme() && theme()!.dark);
    app.set("theme", dark ? "\"dark\"" : "\"light\"");
  }
  function themeIs(id: string) { return themeId() === id || (themeId() === "" && (id === "dark") === app.dark && (id === "dark" || id === "light")); }
  // the chat search: Esc empties it and leaves it; the (x) empties it
  let searchInput: any;
  function clearSearch() { setFilter(""); setSearchRes(null); }
  // (a handler passing its event on to a function gets no event in solid-qml: test the key inline)
  function escSearch() { setFilter(""); setSearchRes(null); setSearchScope(""); if (searchInput && searchInput.focus !== undefined) searchInput.focus = false; }
  function notificationsOn() { try { return JSON.parse(app.settingsJson).notifications !== false; } catch (e) { return true; } }
  function setNotifications(on: boolean) { app.set("notifications", on ? "true" : "false"); }
  // status updates notify too, unless turned off here (muted people's never do)
  function statusNotificationsOn() { try { return JSON.parse(app.settingsJson).statusNotifications !== false; } catch (e) { return true; } }
  function setStatusNotifications(on: boolean) { app.set("statusNotifications", on ? "true" : "false"); }
  // noise reduction for voice notes (the core's ffmpeg denoiser): on by default; a model path, if set,
  // switches it to RNNoise
  function denoiseOn() { try { return JSON.parse(app.settingsJson).voiceDenoise !== false; } catch (e) { return true; } }
  function setDenoise(on: boolean) { app.set("voiceDenoise", on ? "true" : "false"); }
  function denoiseModel() { try { return JSON.parse(app.settingsJson).voiceDenoiseModel || ""; } catch (e) { return ""; } }
  function logout() { call("logout", {}, ignore); }

  // ---- the info drawer: opened from the conversation header ------------------------------------
  function openInfo() {
    const id = sel();
    if (id === "") return;
    setInfoContact(null);
    setInfoGroup(null);
    setInfoPic("");
    setInfoOpen(true);
    if (isGroup(id)) call("GroupMetadata.get", { id: id }, (res: any, _e: any) => { if (res && id === sel()) setInfoGroup(res); });
    else {
      call("Contact.get", { id: id }, (res: any, _e: any) => { if (res && id === sel()) setInfoContact(res); });
      call("getStatus", { id: id }, (res: any, _e: any) => { if (res && id === sel()) setInfoContact(res); });
    }
    call("profilePicFull", { id: id }, (res: any, _e: any) => { if (res && res.path && id === sel()) setInfoPic(res.path); });
  }
  function closeInfo() { if (infoClosing()) return; setInfoClosing(true); setTimeout(() => { setInfoOpen(false); setInfoClosing(false); }, 190); }
  // a group message's sender name: their own chat, with their details open
  function openChatSearch() { setInfoOpen(false); setSearchScope(sel()); setFilter(""); setSearchRes(null); setTimeout(focusSearch, 50); }
  function focusSearch() { if (searchInput && searchInput.forceActiveFocus) searchInput.forceActiveFocus(); }
  function endScope() { setSearchScope(""); setSearchRes(null); if (filter().trim() !== "") searchTyped(filter()); }
  function scopeTitle() { const c = chats().find((x) => x.id === searchScope()); return c ? title(c) : shortJid(searchScope()); }
  // typed: asked of the core after a pause (only the latest answer counts); without Search.run (the Go
  // core) the list keeps filtering itself
  function searchTyped(v: string) { setFilter(v); const n = ++searchSeq; setTimeout(() => runSearch(n), 150); }
  function runSearch(n: number) {
    if (n !== searchSeq) return;
    const q = filter().trim();
    if (q === "") { setSearchRes(null); return; }
    call("Search.run", { query: q, chat: searchScope(), limit: 50 }, (r: any, e: any) => { if (n === searchSeq) setSearchRes(e ? null : r); });
  }
  function searchMode() { return searchScope() !== "" || (filter().trim() !== "" && searchRes() !== null); }
  function resChats() { const r = searchRes(); return r && r.chats ? r.chats : []; }
  function resMsgs() { const r = searchRes(); return r && r.msgs ? r.msgs : []; }
  function esc(t: string) { return t.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;"); }
  function hitLine(m: any) {
    const who = m.fromMe ? "Você: " : (isGroup(m.remote) ? whoName(m) + ": " : "");
    return esc(who) + (m.snippet || esc(oneLine(msgPreview(m))));
  }
  // the hit's picture: the chat's (global search), or who wrote it (searching one chat)
  function hitAvatarId(m: any) { return searchScope() !== "" ? (m.fromMe ? "me" : (m.author || m.remote)) : m.remote; }
  function hitPic(m: any) {
    if (searchScope() === "") return m.chatPic || "";
    if (m.fromMe) return myPic();
    return m.senderPic || (isGroup(m.remote) ? "" : (m.chatPic || ""));
  }
  function hitTitle(m: any) { return searchScope() !== "" ? (m.fromMe ? "Você" : whoName(m)) : (m.chatName || shortJid(m.remote)); }
  // a hit: its chat (opened if it is another), a glide to it, its bubble flashing
  // a contact of the results: their chat (one with no chat yet is opened first, as "nova conversa")
  function openResult(id: string) { if (chats().some((x) => x.id === id)) open(id); else call("openChat", { id: id }, (_r: any, _e: any) => { open(id); }); }
  function openHit(m: any) {
    if (m.remote !== sel()) { pendingHit = m; open(m.remote); return; }
    goToMsg(m);
  }
  function flash(id: string) {
    setFlashId(id); setTimeout(() => setFlashId(""), 400); setTimeout(() => setFlashId(id), 650); setTimeout(() => setFlashId(""), 1300);
  }
  function focusChatSearch() { if (chatSearchInput && chatSearchInput.forceActiveFocus) chatSearchInput.forceActiveFocus(); }
  function closeChatSearch() { setChatSearchOpen(false); }
  // typing searches after a short pause (and only the latest answer is shown)
  function chatQueryTyped(q: string) { setChatQuery(q); const n = ++chatSearchSeq; setTimeout(() => runChatSearch(n), 250); }
  function runChatSearch(n: number) {
    if (n !== chatSearchSeq) return;
    const q = chatQuery().trim();
    if (q === "") { setChatHits([]); return; }
    call("Msg.search", { query: q, chat: sel(), limit: 50 }, (r: any, _e: any) => { if (n === chatSearchSeq) setChatHits((r || []).slice().reverse()); });
  }
  // a result: to that message (the chat loads around it when it is not among the shown ones)
  function goToMsg(m: any) {
    if (m.remote && m.remote !== sel()) return;   // a hit of another chat (the user moved on)
    const gen = ++winGen;   // every jump, even to a loaded message, makes pending navigation stale
    const i = rowIndex(m.id);
    if (i >= 0) { glideToRow(i); flash(m.id); return; }
    const chat = sel();
    // the page that ends at the hit itself (a second with more than a page of messages cannot hide it)
    call("Msg.list", { chat: chat, before: m.t + 1, throughId: m.id, limit: 50 }, (res: any, _e: any) => { if (res && chat === sel() && gen === winGen) { pendingCaught = ""; setMsgs(res); setWinBehind(true); setTimeout(() => revealMsg(m.id), 80); setTimeout(loadNewer, 400); } });
  }
  function revealMsg(id: string) { const i = rowIndex(id); if (i >= 0) { glideToRow(i); flash(id); } }
  function glideToRow(i: number) {
    if (!msgList || !msgList.reveal) return;
    const from = scrollWatchQ && scrollWatchQ.here ? scrollWatchQ.here() : 0;
    msgList.reveal(i);
    if (scrollWatchQ && scrollWatchQ.glideFrom) scrollWatchQ.glideFrom(from);
  }
  function hitWho(m: any) { return m.fromMe ? "Você" : whoName(m); }
  function openSender(id: string) { if (id !== "") openPerson(id); }
  function openPerson(id: string) {
    setPersonId(id); setPersonK(null); setPersonPic("");
    call("Contact.get", { id: id }, (r: any, _e: any) => { if (r && id === personId()) setPersonK(r); });
    call("requestProfilePicFromServer", { id: id }, (r: any, _e: any) => { if (r && id === personId()) setPersonK(r); });
    call("getStatus", { id: id }, (r: any, _e: any) => { if (r && id === personId()) setPersonK(r); });
    call("profilePicFull", { id: id }, (r: any, _e: any) => { if (r && r.path && id === personId()) setPersonPic(r.path); });
  }
  function closePerson() { if (personClosing()) return; setPersonClosing(true); setTimeout(() => { setPersonId(""); setPersonClosing(false); }, 190); }
  // "Conversar": their chat (only offered when it is not the one open)
  function personChat() { const id = personId(); closePerson(); call("openChat", { id: id }, (_r: any, _e: any) => { openPersonChat(id); }); }
  function openPersonChat(id: string) { setPanel("chats"); open(id); }
  function personThumb() { const k = personK(); return k && k.profilePicThumb && k.profilePicThumb !== "-" ? k.profilePicThumb : ""; }
  function personName() { const k = personK(); return k ? (k.name || k.verifiedName || k.pushname || shortJid(personId())) : shortJid(personId()); }
  // a profile picture in full (the larger file when we have it, else the thumbnail we show)
  function viewPic(path: string, who: string) { if (path !== "") setViewer({ kind: "image", source: path, title: who, subtitle: "Foto do perfil", id: "" }); }
  function viewMyPic() {
    const thumb = me() && me().profilePicThumb && me().profilePicThumb !== "-" ? me().profilePicThumb : "";
    call("profilePicFull", { id: me() ? me().id : "" }, (r: any, _e: any) => { viewPic(r && r.path ? r.path : thumb, "Você"); });
  }
  // a contact's picture arrived (the core fetches group senders' in the background): the bubbles
  function onContactChange(k: any) {
    const pic = k && k.profilePicThumb && k.profilePicThumb !== "-" ? k.profilePicThumb : "";
    if (pic === "" || !msgs().some((x) => x.author === k.id && x.senderPic !== pic)) return;
    setMsgs(msgs().map((x) => x.author === k.id ? { ...x, senderPic: pic } : x));
  }
  // The engine keeps a laid-out row's sizes when its pane changes width (the side drawer opening or
  // closing): the wallpaper stays narrow and the bubbles keep their old heights. Rebuild the
  // conversation at the new width, as switching chats does, and go back to its end.
  const [relaying, setRelaying] = createSignal(false);
  // the window changed width: rebuild the conversation once the resize settles (rows keep old sizes)
  let laidW = 0, relaySeq = 0;
  function paneResized(w: number) {
    setConvW(w);
    if (laidW === 0) { laidW = w; return; }
    if (Math.abs(w - laidW) < 24) return;
    const seq = ++relaySeq;
    setTimeout(() => { if (seq === relaySeq) { laidW = convW(); relayout(); } }, 250);
  }
  function relayout() {
    setRelaying(true);
    setTimeout(() => { setRelaying(false); setTimeout(scrollEnd, 50); }, 0);
  }
  function infoPicSrc() {
    if (infoPic() !== "") return "file://" + infoPic();
    const c = selChat();
    return c && c.profilePicThumb ? "file://" + c.profilePicThumb : "";
  }
  function infoPhone() {
    const k = infoContact();
    return k && k.phoneNumber ? formatPhoneUI(k.phoneNumber) : "";
  }
  // "+55 11 98888-7777", as WhatsApp writes numbers (the core does the same for titles)
  function formatPhoneUI(n: string) {
    if (n.indexOf("55") === 0 && (n.length === 12 || n.length === 13)) {
      const local = n.substring(4);
      return "+55 " + n.substring(2, 4) + " " + local.substring(0, local.length - 4) + "-" + local.substring(local.length - 4);
    }
    return "+" + n;
  }
  function memberCount() { const g = infoGroup(); return g ? g.participants.length : 0; }
  function infoMuted() { const c = selChat(); return !!c && muted(c); }
  function toggleInfoMute() {
    const c = selChat();
    if (!c) return;
    call("sendConversationMute", { chat: c.id, expiration: muted(c) ? 0 : -1 }, ignore);
  }
  function ephemeralLabel() {
    const c: any = selChat();
    const d = c ? c.ephemeralDuration || 0 : 0;
    if (!d) return "Desativadas";
    return d >= 7776000 ? "90 dias" : (d >= 604800 ? "7 dias" : "24 horas");
  }
  function deleteFromInfo() { const c = selChat(); if (c) { closeInfo(); setSel(""); call("sendDelete", { chat: c.id }, actionDone); } }
  function openParticipant(id: string) { closeInfo(); open(id); }

  // ---- the chat list's width: the divider drags it; remembered (0 = WhatsApp's 40% / 30%) ---------
  // the interface's zoom (Ctrl+wheel): kept in the settings, applied by Zoom.qml
  function savedZoom() { try { const v = JSON.parse(app.settingsJson).nativeZoom; return typeof v === "number" ? v : 1; } catch (e) { return 1; } }
  const startZoom = savedZoom();
  const [zoom, setZoom] = createSignal(startZoom);
  function zoomK() { return Math.round(zoom() * 10); }
  let zoomSeq = 0;
  function zoomTo(z: number) {
    setZoom(z);
    app.set("nativeZoom", JSON.stringify(z));
    // the rows keep the sizes they were laid out with: rebuild the conversation once the wheel rests
    const q = ++zoomSeq;
    setTimeout(() => { if (q === zoomSeq) relayout(); }, 200);
  }
  function savedListWidth() { try { const v = JSON.parse(app.settingsJson).nativeListWidth; return typeof v === "number" ? v : 0; } catch (e) { return 0; } }
  function dragList(x: number) { setListPx(Math.max(260, Math.min(900, Math.round(x - 64)))); }
  function keepList() { app.set("nativeListWidth", JSON.stringify(listPx())); }
  // the filter chips that fit the list's width; the rest go behind the ∨ chip, as WhatsApp Web does
  function chipCount(id: string) { return id === "unread" ? unreadChats() : id === "groups" ? unreadGroups() : 0; }
  function chipW(f: any) { const n = chipCount(f.id); return 26 + Math.ceil(f.label.length * 7.8) + (n > 0 ? 4 + 7 * ("" + n).length : 0); }
  const [listReal, setListReal] = createSignal(0);   // measured (Measure.qml); the estimate until then
  function listW() { return listReal() > 0 ? listReal() : listPx() > 0 ? listPx() : Math.max(260, Math.round(convW() * 2 / 3)); }
  function chipsShown() {
    let room = listW() - 30 - 34, k = 0;
    for (const f of FILTERS) { const w = chipW(f) + 8; if (w > room) break; room -= w; k++; }
    return k;
  }
  // the search hint cut with "…" to the pill (the field does not clip its placeholder)
  function searchHint() {
    const full = "Pesquisar ou começar uma nova conversa";
    const fit = Math.floor((listW() - 40 - 48 - 16) / 7.1);
    return full.length <= fit ? full : full.slice(0, Math.max(8, fit - 1)).trimEnd() + "…";
  }
  function listStyle() { return listPx() > 0 ? { width: listPx() + "px" } : {}; }

  // ---- sending media (WhatsApp Web: attach menu → preview with caption → send) ----------------
  function toggleAttach() { setExprOpen(false); setAttachOpen(!attachOpen()); }
  function pick(kind: string) { setAttachOpen(false); setPickReq(kind + ":" + Date.now()); }
  function baseName(p: string) { return p.substring(p.lastIndexOf("/") + 1); }
  function isPicture(p: string) {
    const l = p.toLowerCase();
    return l.endsWith(".jpg") || l.endsWith(".jpeg") || l.endsWith(".png") || l.endsWith(".webp") || l.endsWith(".gif");
  }
  // a picked or pasted file: a new preview, or one more in the open one (its "+")
  function onPicked(path: string, kind: string) {
    if (kind === "avatar") { setMyPicture(path); return; }
    keepCaption();
    const l = stagedList().concat([{ path: path, kind: kind, name: baseName(path), caption: "" }]);
    setStagedList(l);
    setStageAt(l.length - 1);
    setCaption("");
    setTimeout(focusCaption, 50);
  }
  // the profile panel: our picture (from a file) and our "Recado", as WhatsApp Web changes them
  const [aboutEditing, setAboutEditing] = createSignal(false);
  const [aboutDraft, setAboutDraft] = createSignal("");
  function pickAvatar() { setPickReq("avatar:" + Date.now()); }
  function setMyPicture(path: string) { call("setProfilePicture", { path: path }, (r: any, _e: any) => { refreshMe(r); }); }
  function refreshMe(_r: any) { call("Profile.get", {}, (p: any, _e: any) => { if (p) setMe(p); }); }
  let aboutInput: any;
  function editAbout() { setAboutDraft(me() && me().status ? me().status : ""); setAboutEditing(true); setTimeout(focusAbout, 30); }
  function focusAbout() { if (aboutInput && aboutInput.forceActiveFocus) aboutInput.forceActiveFocus(); }
  function saveAbout() { setAboutEditing(false); call("setAbout", { text: aboutDraft() }, (r: any, _e: any) => { refreshMe(r); }); }
  function keepCaption() {
    const i = stageAt(), l = stagedList();
    if (i < l.length && l[i].caption !== caption()) setStagedList(l.map((x, k) => k === i ? { ...x, caption: caption() } : x));
  }
  // the editor's flattened copy of the picture shown: what gets sent (the original stays its source)
  function stagedEdited(p: string) {
    const i = stageAt(), l = stagedList();
    if (i < l.length) setStagedList(l.map((x, k) => k === i ? { ...x, out: p } : x));
  }
  // back on a picture: the editor starts over from its edited copy (base), not from the original
  function showStaged(i: number) { keepCaption(); setStagedList(stagedList().map((x, k) => k === i ? { ...x, base: x.out || x.path } : x)); setStageAt(i); setCaption(stagedList()[i].caption); setTimeout(focusCaption, 50); }
  function dropStaged(i: number) {
    keepCaption();
    const l = stagedList().filter((_x, k) => k !== i);
    if (l.length === 0) { cancelStaged(); return; }
    const at = Math.min(stageAt() > i ? stageAt() - 1 : stageAt(), l.length - 1);
    setStagedList(l); setStageAt(at); setCaption(l[at].caption);
  }
  function stageMore() { keepCaption(); setPickReq("media:" + Date.now()); }
  function focusCaption() { if (captionInput && captionInput.forceActiveFocus) captionInput.forceActiveFocus(); }
  function paste() { look.pasteImage(); }
  look.pastedChanged.connect(() => onPasted());
  function onPasted() {
    const f = look.pasted;
    if (f === "" || sel() === "") return;
    const ext = f.toLowerCase().split(".").pop() || "";
    const media = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "mp4", "mov", "webm", "mkv", "3gp"].indexOf(ext) >= 0;
    onPicked(f, media ? "media" : "document");
  }
  function cancelStaged() { setStagedList([]); setStageAt(0); setCaption(""); }
  // every file in turn, each with its caption (as WhatsApp Web sends an album)
  function sendStaged() {
    keepCaption();
    const l = stagedList();
    if (l.length === 0 || sel() === "") return;
    const chat = sel();
    let k = 0;
    const next = () => {
      if (k >= l.length) return;
      const st = l[k++];
      // an SMS thread: the file goes as an MMS through KDE Connect, its caption as the text
      if (isSms(chat)) { call("Sms.send", { thread: chat, body: st.caption.trim(), files: [st.out || st.path] }, (r: any, e: any) => { sent(r, e); next(); }); return; }
      call("sendMediaMsgToChat", { chat: chat, path: st.out || st.path, caption: st.caption.trim(), asDocument: st.kind === "document" }, (r: any, e: any) => { sent(r, e); next(); });
    };
    next();
    cancelStaged();
  }
  // a voice note: the mic starts recording; trash drops it, send sends it as ptt
  let recTimer: any = 0;
  function startRec() {
    setRecLevels([]);
    setRecElapsed(0);
    call("startRecording", { denoise: denoiseOn(), denoiseModel: denoiseModel() }, (_r: any, e: any) => {
      if (e) { setSyncing("Não foi possível gravar: " + (e.message || e)); return; }
      setIsRec(true);
      recTimer = setInterval(() => setRecElapsed(recElapsed() + 1), 1000);
    });
  }
  function stopRec(send: boolean) {
    clearInterval(recTimer);
    setIsRec(false);
    const chat = sel();
    call("stopRecording", { send: send }, (r: any, e: any) => {
      if (e) { setSyncing("Não foi possível gravar: " + (e.message || e)); return; }
      if (send && r && r.path && chat !== "" && !isSms(chat)) call("sendMediaMsgToChat", { chat: chat, path: r.path, asPtt: true, seconds: r.seconds || 1 }, sent);
    });
  }
  // the level, ten times a second, while recording (the composer's waveform)
  const [recLevels, setRecLevels] = createSignal<number[]>([]);
  function onRecLevel(v: number) { if (!isRec()) return; const l = recLevels(); setRecLevels(l.length >= 300 ? [...l.slice(l.length - 299), v] : [...l, v]); }
  function onRecFailed(msg: string) { clearInterval(recTimer); setIsRec(false); setSyncing("Não foi possível gravar: " + msg); }

  function sent(_res: any, err: any) {
    if (err) setSyncing("Não foi possível enviar: " + (err.message || ""));
  }
  // a menu action the user is waiting to see happen: its failure shows (and clears after a while)
  let actionNoteSeq = 0;
  function actionDone(_res: any, err: any) {
    if (!err) return;
    const m = err.message || "";
    setSyncing(m.indexOf("not implemented") >= 0 ? "Esta ação ainda não está disponível no núcleo D" : "Não foi possível concluir: " + m);
    const q = ++actionNoteSeq;
    setTimeout(() => { if (q === actionNoteSeq) setSyncing(""); }, 5000);
  }

  // ---- notifications ----------------------------------------------------------------------------
  // a chat's current notification id, so the next message from it replaces (updates) the same one
  // instead of stacking; cleared when it is acted on or the chat is opened
  const chatNote: Record<string, number> = {};
  const noteCount: Record<string, number> = {};
  function elide(s: string, n: number) { return s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s; }
  function notify(m: Msg) {
    if (!notifications.available) return;
    if (m.isStatusMuted) return;   // their status updates are muted
    if (m.remote === "status@broadcast" && !statusNotificationsOn()) return;
    const chat = m.remote;
    const c = anyChat(chat);
    if (c && (c.muteExpiration === -1 || c.muteExpiration * 1000 > Date.now())) return;
    const t = c && c.name ? c.name : (m.senderName || shortJid(chat));
    noteCount[chat] = (chatNote[chat] ? noteCount[chat] || 1 : 0) + 1;   // messages shown in this one
    const n = noteCount[chat];
    const line = oneLine((isGroup(chat) && m.senderName ? m.senderName + ": " : "") + msgPreview(m));
    const body = elide(n > 1 ? n + " mensagens · " + line : line, 130);  // one elided line
    // a writable chat (not a channel) offers inline reply + mark-as-read, as WhatsApp's notification does
    const canWrite = !isChannel(chat) && chat.indexOf("@broadcast") < 0;
    const spec: any = { title: t, body: body, icon: app.appIcon, replace: chatNote[chat] || 0,
      actions: [{ id: "default", label: "Abrir" }] };
    if (canWrite) {
      spec.actions.push({ id: "mark-read", label: "Marcar como lido" });
      if (notifications.supportsReply) spec.reply = "Responder";
    }
    const id = notifications.send(spec);
    if (id > 0) { noteChats()[id] = chat; chatNote[chat] = id; }
  }
  // the chat's notification is gone (opened, replied, marked read): forget it so the next starts fresh
  function clearNote(chat: string) {
    const id = chatNote[chat];
    if (id) { notifications.close(id); delete noteChats()[id]; }
    delete chatNote[chat];
    delete noteCount[chat];
  }
  function notifyCall(p: any) {
    if (!notifications.available) return;
    const c = chats().find((x) => x.id === p.from);
    notifications.send({ title: c ? c.name : shortJid(p.from), body: p.isVideo ? "Chamada de vídeo — atenda no celular" : "Chamada de voz — atenda no celular",
      icon: app.appIcon, actions: [] });
  }
  function onNoteAction(id: number, action: string) {
    const chat = noteChats()[id];
    if (!chat) return;
    if (action === "mark-read") { call("sendSeen", { chat: chat }, ignore); clearNote(chat); return; }
    open(chat); // "default" / "Abrir"
  }
  notifications.actionInvoked.connect((id: number, a: string) => onNoteAction(id, a));
  // inline reply from the notification: send it to that chat and clear the notification
  notifications.replied.connect((id: number, text: string) => {
    const chat = noteChats()[id];
    if (chat && text.trim() !== "" && isSms(chat)) call("Sms.send", { thread: chat, body: text.trim() }, ignore);
    else if (chat && text.trim() !== "") { call("sendTextMsgToChat", { chat: chat, text: text.trim() }, ignore); call("sendSeen", { chat: chat }, ignore); }
    if (chat) clearNote(chat);
  });

  // ---- look ---------------------------------------------------------------------------------------
  function tk() { const t = theme(); return t ? t.t : (app.dark ? DARK : LIGHT); }
  function ic(name: string, color: string) {
    look.ensure(name, color);
    return look.base + "/" + name + "-" + colorKey(color) + ".svg";
  }
  function photo(j: string) { return (isDark() ? PHOTO_DARK : PHOTO_LIGHT)[hash(j) % PHOTO_DARK.length]; }
  function senderColor(j: string) { return photo(j)[1]; }
  function doodle() { return look.ok ? ic("doodle", tk().doodle) : ""; }

  // ---- formatting (WhatsApp Web's pt-BR strings) ------------------------------------------------
  function isGroup(j: string) { return j.indexOf("@g.us") > 0; }
  function isChannel(j: string) { return j.indexOf("@newsletter") > 0; }
  function shortJid(j: string) { return "+" + j.split("@")[0]; }
  function title(c: Chat) { return c.name !== "" ? c.name : shortJid(c.id); }
  function muted(c: Chat) { return c.muteExpiration === -1 || c.muteExpiration * 1000 > Date.now(); }
  function unreadOf(c: Chat) { return c.unreadCount > 0 ? c.unreadCount : 0; }
  function two(n: number) { return n < 10 ? "0" + n : "" + n; }
  function clock(t: number) { const d = new Date(t * 1000); return two(d.getHours()) + ":" + two(d.getMinutes()); }
  function daysAgo(t: number) {
    const d = new Date(t * 1000);
    const now = new Date();
    const a = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    const b = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    return Math.round((b - a) / 86400000);
  }
  function date(t: number) { const d = new Date(t * 1000); return two(d.getDate()) + "/" + two(d.getMonth() + 1) + "/" + d.getFullYear(); }
  // The chat list: 14:05 · Ontem · sexta-feira · 03/10/2026
  function when(t: number) {
    if (t <= 0) return "";
    const n = daysAgo(t);
    if (n === 0) return clock(t);
    if (n === 1) return "Ontem";
    if (n < 7) return WEEKDAYS[new Date(t * 1000).getDay()];
    return date(t);
  }
  // The conversation's day pills: Hoje · Ontem · sexta-feira · 03/10/2026
  function openMediaPanel() {
    mpTab("media");
    setMpQuery("");
    setMpSearching(false);
    setMediaOpen(true);
    call("Msg.byType", { types: ["image", "video"], limit: 300 }, (r: any, _e: any) => setMediaList(r || []));
    call("Msg.byType", { types: ["document"], limit: 300 }, (r: any, _e: any) => setDocList(r || []));
    call("Msg.links", { limit: 300 }, (r: any, _e: any) => setLinkList(r || []));
  }
  const MONTHS = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];
  function longDate(t: number) { const d = new Date(t * 1000); return d.getDate() + " de " + MONTHS[d.getMonth()] + " de " + d.getFullYear(); }
  // the list by day, newest first: [{ label, sub, items }]
  function byDay(list: any[]) {
    const out: any[] = [];
    for (const m of list) {
      const key = longDate(m.t);
      let g = out.length > 0 ? out[out.length - 1] : null;
      if (!g || g.sub !== key) { g = { label: dayLabel(m.t), sub: key, items: [] }; out.push(g); }
      g.items.push(m);
    }
    return out;
  }
  // search, sort and filter of the panel (per tab: they reset when the tab changes)
  const [mpSearching, setMpSearching] = createSignal(false);
  const [mpQuery, setMpQuery] = createSignal("");
  const [mpSort, setMpSort] = createSignal("new");     // new | old | size | name
  const [mpFilter, setMpFilter] = createSignal("all"); // all | image | video | gif | pdf | sheet | text | slides | other
  function mpTab(t: string) { setMediaTab(t); setMpSort("new"); setMpFilter("all"); }
  function docKind(m: any) {
    const f = ((m.mediaData && m.mediaData.filename) || m.body || "").toLowerCase();
    const mt = (m.mediaData && m.mediaData.mimetype) || "";
    const ext = f.lastIndexOf(".") >= 0 ? f.slice(f.lastIndexOf(".") + 1) : "";
    if (ext === "pdf" || mt.indexOf("pdf") >= 0) return "pdf";
    if (["xls", "xlsx", "ods", "csv"].indexOf(ext) >= 0) return "sheet";
    if (["doc", "docx", "odt", "txt", "rtf", "md"].indexOf(ext) >= 0) return "text";
    if (["ppt", "pptx", "odp", "key"].indexOf(ext) >= 0) return "slides";
    return "other";
  }
  function mpKind(m: any) {
    if (m.type === "document") return docKind(m);
    if (m.type === "video") return m.mediaData && m.mediaData.isGif ? "gif" : "video";
    return m.type;
  }
  function mpText(m: any) {
    return [fromWho(m), m.chatName || "", m.caption || "", m.body || "", (m.mediaData && m.mediaData.filename) || "", firstLink(m)].join(" ").toLowerCase();
  }
  function mpApply(list: any[]) {
    const q = mpQuery().toLowerCase().trim(), f = mpFilter();
    const out = list.filter((m: any) => (f === "all" || mpKind(m) === f) && (q === "" || mpText(m).indexOf(q) >= 0));
    const sz = (m: any) => (m.mediaData && m.mediaData.size) || 0;
    const nm = (m: any) => ((m.mediaData && m.mediaData.filename) || m.body || "").toLowerCase();
    if (mpSort() === "old") out.sort((a: any, b: any) => a.t - b.t);
    else if (mpSort() === "size") out.sort((a: any, b: any) => sz(b) - sz(a));
    else if (mpSort() === "name") out.sort((a: any, b: any) => (nm(a) < nm(b) ? -1 : nm(a) > nm(b) ? 1 : 0));
    else out.sort((a: any, b: any) => b.t - a.t);
    return out;
  }
  // by day for the date orders; one block for size and name
  function grouped(list: any[]) {
    const l = mpApply(list);
    if (mpSort() === "size" || mpSort() === "name") return l.length ? [{ label: mpSort() === "size" ? "Por tamanho" : "Por nome", sub: "", items: l }] : [];
    return byDay(l);
  }
  const mediaDays = createMemo(() => grouped(mediaList()));
  const docDays = createMemo(() => grouped(docList()));
  const linkDays = createMemo(() => grouped(linkList()));
  function mpEmpty() { return (mediaTab() === "media" ? mediaDays() : mediaTab() === "docs" ? docDays() : linkDays()).length === 0; }
  function mpFilterLabel() {
    const f = mpFilter();
    return f === "image" ? "Fotos" : f === "video" ? "Vídeos" : f === "gif" ? "GIFs" : f === "pdf" ? "PDF" : f === "sheet" ? "Planilhas" : f === "text" ? "Textos" : f === "slides" ? "Apresentações" : f === "other" ? "Outros" : "";
  }
  function fromWho(m: any) { return m.fromMe ? "Você" : (m.senderName || m.chatName || shortJid(m.remote)); }
  function kb(n: number) { return n >= 1048576 ? (n / 1048576).toFixed(1).split(".").join(",") + " MB" : Math.max(1, Math.round(n / 1024)) + " kB"; }
  function firstLink(m: any) {
    if (m.matchedText) return m.matchedText;
    for (const w of (m.body || "").split(" ")) if (w.indexOf("http://") === 0 || w.indexOf("https://") === 0) return w;
    return "";
  }
  function dayLabel(t: number) {
    const n = daysAgo(t);
    if (n === 0) return "Hoje";
    if (n === 1) return "Ontem";
    if (n < 7) return WEEKDAYS[new Date(t * 1000).getDay()];
    return date(t);
  }
  // What a message says in one line (chat list, notifications, quotes), by WAWebMsgType.
  function typeLabel(type: string, body: string) {
    if (body) return body;
    if (type === "image") return "Foto";
    if (type === "video") return "Vídeo";
    if (type === "ptv") return "Mensagem de vídeo";
    if (type === "ptt") return "Mensagem de voz";
    if (type === "audio") return "Áudio";
    if (type === "document") return "Documento";
    if (type === "sticker") return "Figurinha";
    if (type === "location") return "Localização";
    if (type === "vcard" || type === "multi_vcard") return "Contato";
    if (type === "poll_creation") return "Enquete";
    if (type === "ciphertext") return "Aguardando mensagem";
    return "";
  }
  function oneLine(t: string) { return mdLine(t); }
  function msgPreview(m: Msg) {
    if (m.type === "revoked") return m.fromMe ? "Você apagou esta mensagem" : "Esta mensagem foi apagada";
    if (isSystem(m)) return systemText(m);
    const body = m.body || m.caption || (m.mediaData && m.mediaData.filename) || m.pollName || (m.loc || "").split("\n")[0];
    return typeLabel(m.type, body || "");
  }
  // The chat list's second line: "Ana: texto", "Você apagou…", the system notice, or typing.
  function lastLine(c: Chat) {
    const ty = typing()[c.id] || [];
    if (ty.length > 0) return isGroup(c.id) ? whoTyping(c.id) : "digitando";
    const rec = recording()[c.id] || [];
    if (rec.length > 0) return "gravando áudio";
    const l = c.lastMsg;
    if (!l) return "";
    if (l.type === "revoked") return l.fromMe ? "Você apagou esta mensagem" : "Esta mensagem foi apagada";
    if (l.type === "gp2" || l.type === "e2e_notification" || l.type === "notification_template" || l.type === "call_log") return systemLine(l);
    const who = isGroup(c.id) && !l.fromMe && l.senderName ? l.senderName + ": " : "";
    return oneLine(who + typeLabel(l.type, l.body));
  }
  // the preview as WhatsApp Web lays it out: "Sender: " · the kind's icon · the text (a photo with
  // no caption reads "Foto")
  const KIND_ICON: any = { image: "image", video: "videocam", ptv: "videocam", ptt: "mic", audio: "headphones", document: "doc-file",
    location: "location-pin", vcard: "person", multi_vcard: "person", poll_creation: "poll", revoked: "revoked" };
  function plainLine(c: Chat) { return isTyping(c) || !c.lastMsg || ["gp2", "e2e_notification", "notification_template", "call_log"].indexOf(c.lastMsg.type) >= 0; }
  function lineWho(c: Chat) {
    if (plainLine(c)) return "";
    const l = c.lastMsg!;
    return isGroup(c.id) && !l.fromMe && l.senderName && l.type !== "revoked" ? oneLine(l.senderName) + ": " : "";
  }
  function lineIcon(c: Chat) { return plainLine(c) ? "" : KIND_ICON[c.lastMsg!.type] || ""; }
  function lineRest(c: Chat) {
    if (plainLine(c)) return lastLine(c);
    const l = c.lastMsg!;
    if (l.type === "revoked") return l.fromMe ? "Você apagou esta mensagem" : "Esta mensagem foi apagada";
    return oneLine(typeLabel(l.type, l.body));
  }
  function systemLine(l: LastMsg) {
    if (l.type === "call_log") return l.subtype === "miss_video" ? "Chamada de vídeo perdida" : "Chamada de voz perdida";
    if (l.type === "e2e_notification") return "O código de segurança mudou";
    return "Mensagem do sistema";
  }
  function isTyping(c: Chat) { return (typing()[c.id] || []).length > 0 || (recording()[c.id] || []).length > 0; }
  function whoTyping(chat: string) {
    const ids = typing()[chat] || [];
    if (ids.length === 0) return "";
    const names = ids.map((j) => nameOf(j));
    return names.length === 1 ? names[0] + " está digitando" : names.join(", ") + " estão digitando";
  }
  function nameOf(j: string) {
    const m = msgs().find((x) => x.author === j && !!x.senderName);
    return m && m.senderName ? m.senderName : shortJid(j);
  }
  function selTyping() { const s = sel(); return s !== "" && !isChannel(s) && ((typing()[s] || []).length > 0 || (recording()[s] || []).length > 0); }
  function convSub() {
    const s = sel();
    if (isChannel(s)) { const c = selChat(); return c && c.subscribers ? followers(c.subscribers) : "Canal"; }
    if ((typing()[s] || []).length > 0) return isGroup(s) ? whoTyping(s) : "digitando";
    if ((recording()[s] || []).length > 0) return "gravando áudio";
    const c = selChat();
    if (c && c.isAnnounceGroup) return "Avisos";
    return online();
  }
  function inCommunity() { const c = selChat(); return !!(c && c.parentGroup); }
  // System notices (gp2 / e2e / call_log / ephemeral), as WhatsApp Web words them in pt-BR.
  function systemText(m: Msg) {
    const n = m.templateNames || [];
    const by = n[0] || "";
    const rest = n.slice(1).join(", ");
    const s = m.subtype || "";
    if (m.type === "ciphertext") return "Aguardando mensagem. Isso pode levar algum tempo.";
    if (m.type === "call_log") return s === "miss_video" ? "Chamada de vídeo perdida às " + clock(m.t) : (s === "miss" ? "Chamada de voz perdida às " + clock(m.t) : "Chamada atendida em outro aparelho");
    if (m.type === "e2e_notification") return s === "identity" ? "O código de segurança de " + by + " mudou. Toque para saber mais." : "As mensagens e ligações são protegidas com a criptografia de ponta a ponta.";
    if (s === "linked_group_join") return by === "Você" ? "Você entrou no grupo através da comunidade" : by + " entrou no grupo através da comunidade";
    if (s === "create") return by + " criou este grupo";
    if (s === "subject") return by + " mudou o nome do grupo para \"" + (n[1] || "") + "\"";
    if (s === "description") return by + " mudou a descrição do grupo";
    if (s === "picture") return by + " mudou a imagem deste grupo";
    if (s === "add") return by === rest ? by + " entrou usando o link de convite deste grupo" : by + " adicionou " + rest;
    if (s === "remove") return by + " removeu " + rest;
    if (s === "leave") return (rest || by) + " saiu";
    if (s === "invite") return by + " entrou usando o link de convite deste grupo";
    if (s === "promote") return by + " tornou " + rest + " admin";
    if (s === "demote") return by + " removeu " + rest + " como admin";
    if (s === "announce") return n[1] === "true" ? by + " mudou as configurações para permitir que somente admins enviem mensagens" : by + " mudou as configurações para permitir que todos os participantes enviem mensagens";
    if (s === "restrict") return n[1] === "true" ? by + " mudou as configurações para permitir que somente admins editem os dados do grupo" : by + " mudou as configurações para permitir que todos os participantes editem os dados do grupo";
    if (s === "ephemeral" || s === "ephemeral_setting") return ephemeralText(by, n[n.length - 1] || "0");
    return "";
  }
  function ephemeralText(by: string, secs: string) {
    const d = parseInt(secs);
    if (!d) return (by ? by + " desativou" : "Desativadas") + " as mensagens temporárias.";
    const label = d >= 7776000 ? "90 dias" : (d >= 604800 ? "7 dias" : "24 horas");
    return (by ? by + " ativou" : "Ativadas") + " as mensagens temporárias. As novas mensagens vão desaparecer desta conversa " + label + " após o envio.";
  }
  // The receipt icon and its colour (WAWebAck): clock, one tick, two ticks, two blue ticks.
  function tickIcon(ack: number) {
    if (ack <= ACK.CLOCK) return "pending";
    if (ack >= ACK.RECEIVED) return "dblcheck";
    return "check";
  }
  // the status ring's arcs: one per status, oldest first, seen ones grey (our own: all seen)
  function ringSeen(st: any) { return (st.items || []).map((it: any) => !!st.isMe || !!it.viewed); }
  function tickColor(ack: number) { return ack >= ACK.READ ? tk().read : tk().muted; }
  function showsTick(l: LastMsg | undefined) { return !!l && l.fromMe && l.type !== "revoked" && l.type !== "gp2" && l.type !== "e2e_notification" && l.type !== "notification_template" && l.type !== "call_log"; }
  // WhatsApp's trick: the text ends in blank room as wide as the time (and ticks, and "Editada"), so
  // the time sits on the last line when it fits there and gets a line of its own when it does not.
  function metaRoom(m: Msg) {
    const n = (m.fromMe ? 14 : 10) + (m.isEdited ? 10 : 0);
    return "\u00a0".repeat(n);
  }
  // a channel message's reactions as WhatsApp shows them: the top emojis and the total
  function channelReacts(m: Msg) {
    const l = m.newsletterReactions || [];
    if (l.length === 0) return "";
    const total = l.reduce((n, r) => n + r.count, 0);
    return l.slice(0, 4).map((r) => r.emoji).join("") + " " + (total >= 1000 ? (total / 1000).toFixed(1).replace(".", ",") + " mil" : "" + total);
  }
  function reactions(m: Msg) {
    if (!m.reactions || m.reactions.length === 0) return "";
    const total = m.reactions.reduce((n, r) => n + r.senders.length, 0);
    return m.reactions.slice(0, 3).map((r) => r.aggregateEmoji).join("") + (total > 1 ? " " + total : "");
  }
  // "~Name" (not in the address book) reads "~ Name" over a bubble, as WhatsApp Web writes it
  function whoName(m: Msg) {
    const n = m.senderName || shortJid(m.author || "");
    return n.indexOf("~") === 0 ? "~ " + n.slice(1) : n;
  }
  function quoteWho(m: Msg) {
    const q = m.quotedMsg;
    if (!q) return "";
    if (q.authorName) return q.authorName;
    return selChat() ? title(selChat()!) : "";
  }
  // ---- media ------------------------------------------------------------------------------------
  // a bubble's lane: 65% of the pane less the row's paddings (54 + 49) and the bubble's (16)
  // a sticker run's width: as many stickers per line as the lane takes (4px apart), no wider than the run
  function stRunW(list: Msg[]) {
    if (list.length === 0) return 0;
    const w = boxW(list[0]);
    const fit = Math.max(1, Math.floor((laneW() + 4) / (w + 4)));
    return Math.min(fit, list.length) * (w + 4) - 4;
  }
  function laneW() { return Math.floor((convW() - 103) * 0.8) - 16; }
  // the bubble's content (its max-width laneW()+8, minus the 16px horizontal padding) is laneW()-8;
  // the audio lane must fit inside it, or the avatar on its right pokes past the card's rounded border
  function audioW() { return Math.max(180, Math.min(336, laneW() - 16)); }
  function isAudio(m: Msg) { return m.type === "ptt" || m.type === "audio"; }
  function mediaFile(m: Msg) { return m.mediaData && m.mediaData.mediaStage === "RESOLVED" && m.mediaData.renderableUrl ? m.mediaData.renderableUrl : ""; }
  function fetching(m: Msg) { return !!m.mediaData && m.mediaData.mediaStage === "FETCHING"; }
  function download(m: Msg) { call("downloadMedia", { msg: m.id }, ignore); }
  function onPlayed(m: Msg) { if (!m.fromMe && m.type === "ptt") call("markPlayed", { msg: m.id }, ignore); }
  // consecutive voice notes play in a row (WhatsApp Web): when one ends, if the next message is a
  // voice note, a short chime plays and that one starts
  // the voice-note playback speed is remembered (WhatsApp keeps it): one speed for all notes, saved
  function savedRate() { try { const v = JSON.parse(app.settingsJson).audioRate; return v === 1.5 || v === 2 ? v : 1; } catch (e) { return 1; } }
  const [audioRate, setAudioRate] = createSignal(savedRate());
  function setRate(r: number) { setAudioRate(r); app.set("audioRate", JSON.stringify(r)); }
  const [autoPlayId, setAutoPlayId] = createSignal("");
  let chimeRef: any, endChimeRef: any;
  let pendingAudio = "";
  let runActive = false;   // a run of voice notes is playing (the end chime plays only after a run)
  function nextAudioId(m: Msg) {
    const rs = rows();
    const i = rs.findIndex((r: any) => r.id === m.id);
    if (i < 0) return "";
    for (let j = i + 1; j < rs.length; j++) {
      const nm = rs[j].m;
      if (isSystem(nm)) continue;      // separators/notices do not interrupt a run
      return isAudio(nm) ? nm.id : ""; // the next real message: a voice note continues the run, else stop
    }
    return "";
  }
  function onAudioFinished(m: Msg) {
    const wasAuto = autoPlayId() === m.id;
    if (wasAuto) setAutoPlayId("");
    const nx = nextAudioId(m);
    if (nx !== "") {               // the next voice note: the advance chime, then play it
      runActive = true;
      pendingAudio = nx;
      if (chimeRef && chimeRef.ring) chimeRef.ring(); else chimeDone();
      return;
    }
    // the run ended: a different chime, only if this was actually a run (auto-advanced here)
    if (wasAuto || runActive) { if (endChimeRef && endChimeRef.ring) endChimeRef.ring(); }
    runActive = false;
  }
  function chimeDone() { if (pendingAudio !== "") { const id = pendingAudio; pendingAudio = ""; setAutoPlayId(id); } }
  // WhatsApp colours the mic badge green until the voice note is played, blue after.
  function micColor(m: Msg) { return m.fromMe ? (m.ack >= ACK.PLAYED ? tk().read : tk().accent) : tk().accent; }
  function audioAvatar(m: Msg) { return m.fromMe ? "me" : (m.author || m.remote); }
  // WhatsApp Web fetches photos and stickers by itself; videos, audio and documents on click.
  const linkAsked: any = {};
  function autoFetch(list: Msg[]) {
    // links: their large preview picture, when the sender's phone uploaded one
    list.filter((m) => m.type === "chat" && !!m.matchedText && !m.linkThumb && !linkAsked[m.id]).forEach((m) => { linkAsked[m.id] = true; call("fetchThumbnail", { msg: m.id }, ignore); });
    list.filter((m) => (m.type === "image" || m.type === "sticker") && !!m.mediaData && m.mediaData.mediaStage === "INIT").forEach((m) => download(m));
    // a sticker that failed once is tried again once a session (the phone may upload it again)
    list.filter((m) => m.type === "sticker" && !!m.mediaData && m.mediaData.mediaStage === "ERROR_MISSING" && !retried[m.id]).forEach((m) => { retried[m.id] = true; download(m); });
    // videos and documents are not downloaded until opened: their good thumbnail is fetched instead
    list.filter((m) => (m.type === "video" || m.type === "document") && !!m.mediaData && !m.mediaData.thumbnailHQ).forEach((m) => call("fetchThumbnail", { msg: m.id }, ignore));
  }
  const retried: any = {};
  // at most the lane less the tail's 8 px (so a run's right edges line up); a captioned picture's
  // bubble is the picture's width
  // a link's large preview: the picture across the bubble, at its own aspect (WhatsApp Web)
  function lpW(m: Msg) { return Math.max(200, Math.min(480, laneW() - 6)); }
  function lpH(m: Msg) {
    const w = m.thumbWidth || 16, h = m.thumbHeight || 9;
    return Math.max(120, Math.min(320, Math.round(lpW(m) * h / w)));
  }
  function fullDomain(u: string) { const x = u.indexOf("://") >= 0 ? u.split("://")[1] : u; return x.split("/")[0]; }
  function bubbleStyle(m: Msg) {
    const s: any = { "max-width": (laneW() + 8) + "px" };
    if (m.linkThumb) s.width = (lpW(m) + 6) + "px";
    if (isVisual(m) && !!m.caption) s.width = (boxW(m) + 6) + "px";
    return s;
  }
  function isVisual(m: Msg) { return m.type === "image" || m.type === "video" || m.type === "sticker"; }
  function isDoc(m: Msg) { return m.type === "document"; }
  // The picture's box in the bubble: WhatsApp's 330 x 338 at most, keeping the aspect.
  function boxW(m: Msg) {
    const d = m.mediaData;
    if (m.type === "sticker") return 190;
    const maxW = m.caption && m.caption.length > 40 ? Math.max(160, laneW() - 6) : Math.max(160, Math.min(330, laneW() - 6));
    if (!d || !d.width || !d.height) return maxW;
    const h = maxW * d.height / d.width;
    return h > 338 ? Math.max(150, Math.round(338 * d.width / d.height)) : maxW;
  }
  function boxH(m: Msg) {
    const d = m.mediaData;
    if (m.type === "sticker") return 190;
    if (!d || !d.width || !d.height) return 240;
    return Math.min(338, Math.round(boxW(m) * d.height / d.width));
  }
  function picSrc(m: Msg) {
    const f = mediaFile(m);
    if (f !== "" && m.type !== "video") return "file://" + f;
    if (m.mediaData && m.mediaData.thumbnailHQ) return "file://" + m.mediaData.thumbnailHQ;
    return m.mediaData && m.mediaData.preview ? "data:image/jpeg;base64," + m.mediaData.preview : "";
  }
  function toggleExpr() {
    if (exprOpen()) { setExprOpen(false); return; }
    setAttachOpen(false);
    setExprOpen(true);
    loadPacks();
    call("StickerStore.list", {}, (r: any, _e: any) => { if (r) setStoreList(r); });
    call("Sticker.list", { limit: 80 }, (r: any, _e: any) => {
      const l = (r || []).map((m: any) => ({ id: m.id, src: mediaFile(m) !== "" ? "file://" + mediaFile(m) : "", m: m }));
      setStickerList(l);
      l.forEach((it: any, i: number) => { if (it.src === "") call("downloadMedia", { msg: it.id }, (res: any, _e2: any) => {
        const f = res && res.mediaData && res.mediaData.renderableUrl ? res.mediaData.renderableUrl : "";
        if (f === "") return;
        const n = stickerList().slice();
        if (n[i] && n[i].id === it.id) { n[i] = { ...n[i], src: "file://" + f }; setStickerList(n); }
      }); });
    });
  }
  function pickEmoji(e: string) { setDraft(draft() + e); }
  function pickSticker(id: string) { const c = sel(); if (c !== "" && !isSms(c)) call("sendSticker", { chat: c, msg: id }, ignore); setExprOpen(false); }
  // only WhatsApp's inline preview (a few dozen pixels) to show: drawn blurred
  function isPreviewOnly(m: Msg) { return picSrc(m).indexOf("data:") === 0; }
  function openMedia(m: Msg) {
    const f = mediaFile(m);
    if (f === "") { setOpenWhenReady(m.id); download(m); return; }
    const pdf = !!m.mediaData && (m.mediaData.mimetype || "").indexOf("pdf") >= 0;
    if (m.type === "document" && !pdf) { app.openExternal("file://" + f); return; }
    const kind = m.type === "document" ? "pdf" : (m.type === "video" ? "video" : "image");
    const who = m.fromMe ? "Você" : (m.senderName || (selChat() ? title(selChat()!) : ""));
    setViewer({ kind: kind, source: f, title: who, subtitle: dayLabel(m.t) + " às " + clock(m.t), id: m.id });
  }
  function closeViewer() { setViewer(null); setStatusRun(null); }
  function viewerExternal() { const v = viewer(); if (v) app.openExternal("file://" + v.source); }
  function secs(n: number) { const m = Math.floor(n / 60); const s = n % 60; return m + ":" + (s < 10 ? "0" : "") + s; }
  function size(n: number) {
    if (n >= 1048576) return (n / 1048576).toFixed(1).replace(".", ",") + " MB";
    return Math.max(1, Math.round(n / 1024)) + " kB";
  }
  function ext(m: Msg) {
    const n = m.mediaData && m.mediaData.filename ? m.mediaData.filename : "";
    const i = n.lastIndexOf(".");
    return i > 0 ? n.substring(i + 1).toUpperCase() : "ARQUIVO";
  }
  function docInfo(m: Msg) {
    const d = m.mediaData;
    if (!d) return "";
    const parts = [];
    if (d.pageCount) parts.push(d.pageCount + (d.pageCount === 1 ? " página" : " páginas"));
    parts.push(ext(m));
    if (d.size) parts.push(size(d.size));
    return parts.join(" • ");
  }
  function docColor(m: Msg) {
    const e = ext(m);
    if (e === "PDF") return "#E54242";
    if (e === "DOC" || e === "DOCX") return "#2B79E8";
    if (e === "XLS" || e === "XLSX" || e === "CSV") return "#1E9E5A";
    if (e === "PPT" || e === "PPTX") return "#E8752B";
    return "#8696A0";
  }
  // ---- location, contacts, polls -------------------------------------------------------------
  function isRich(m: Msg) { return m.type === "location" || m.type === "vcard" || m.type === "multi_vcard" || m.type === "poll_creation"; }
  function openMap(m: Msg) { app.openExternal("https://www.google.com/maps/search/?api=1&query=" + m.lat + "," + m.lng); }
  function locTitle(m: Msg) { return m.loc ? m.loc.split("\n")[0] : (m.isLive ? "Localização em tempo real" : "Localização"); }
  function locSub(m: Msg) { const p = (m.loc || "").split("\n"); return p.length > 1 ? p[1] : ""; }
  function locThumb(m: Msg) { return m.thumbnail ? "data:image/jpeg;base64," + m.thumbnail : ""; }
  function vcardName(m: Msg) {
    const l = m.vcardList || [];
    if (l.length === 0) return "Contato";
    return l.length === 1 ? l[0].displayName : l[0].displayName + " e mais " + (l.length - 1);
  }
  function vcardPhone(m: Msg) {
    const l = m.vcardList || [];
    if (l.length === 0) return "";
    const v = l[0].vcard;
    const i = v.indexOf("waid=");
    return i >= 0 ? v.substring(i + 5, v.indexOf(":", i)) : "";
  }
  function chatWith(m: Msg) { const ph = vcardPhone(m); if (ph !== "") open(ph + "@s.whatsapp.net"); }
  function pollHint(m: Msg) { return (m.pollSelectableOptionsCount || 0) === 1 ? "Selecione uma opção." : "Selecione uma ou mais opções."; }
  function bodyOf(m: Msg) {
    if (m.type === "revoked") return m.fromMe ? "Você apagou esta mensagem" : "Esta mensagem foi apagada";
    return msgPreview(m);
  }

  // ---- the list's side views (new chat, new group, starred) and selection mode -------------------
  const [side, setSide] = createSignal("");          // "" | newChat | newGroup | groupName | starred
  const [sideQuery, setSideQuery] = createSignal("");
  const [contacts, setContacts] = createSignal<any[]>([]);
  const [groupPicked, setGroupPicked] = createSignal<string[]>([]);
  const [groupName, setGroupName] = createSignal("");
  const [sideError, setSideError] = createSignal("");
  const [starred, setStarred] = createSignal<any[]>([]);
  function openSide(v: string) {
    setSideQuery("");
    setSideError("");
    if (v === "newChat" || v === "newGroup") call("Contact.list", {}, (r: any, _e: any) => setContacts(r || []));
    if (v === "newChat") { setGroupPicked([]); setGroupName(""); }
    if (v === "starred") call("Msg.starred", { limit: 200 }, (r: any, _e: any) => setStarred(r || []));
    setPanel("chats");
    setSide(v);
  }
  function closeSide() { setSide(""); }
  // a community: its announcements, my groups, and the ones I can join (WhatsApp Web's view)
  const [commView, setCommView] = createSignal<any>(null);
  const [joining, setJoining] = createSignal("");
  const [commError, setCommError] = createSignal("");
  function openCommunity(id: string) {
    setCommView(null);
    setCommError("");
    setPanel("chats");
    setSide("community");
    call("Community.view", { id: id }, (r: any, e: any) => { if (r) setCommView(r); if (e) setCommError("Não foi possível carregar a comunidade."); });
  }
  function joinSub(g: any) {
    const v = commView();
    if (!v || joining() !== "") return;
    setJoining(g.id);
    setCommError("");
    call("joinCommunityGroup", { id: v.id, chat: g.id }, (r: any, e: any) => {
      setJoining("");
      if (e || !r) { setCommError("Não foi possível entrar no grupo." + (e && e.message ? " " + e.message : "")); return; }
      closeSide();
      open(r.id);
    });
  }
  const sideContacts = createMemo(() => {
    const q = sideQuery().toLowerCase();
    return contacts().filter((k: any) => q === "" || (k.name || "").toLowerCase().indexOf(q) >= 0 || (k.id || "").indexOf(q) >= 0).slice(0, 400);
  });
  function startChat(id: string) { call("openChat", { id: id }, (_r: any, _e: any) => { closeSide(); open(id); }); }
  function toggleGroupPick(id: string) { const p = groupPicked(); setGroupPicked(p.indexOf(id) >= 0 ? p.filter((x) => x !== id) : [...p, id]); }
  function groupPickedNames() { return groupPicked().map((id) => { const k = contacts().find((x: any) => x.id === id); return k ? k.name : shortJid(id); }).join(", "); }
  function makeGroup() {
    if (groupName().trim() === "") return;
    setSideError("");
    call("createGroup", { name: groupName().trim(), participants: groupPicked() }, (r: any, e: any) => {
      if (e || !r) { setSideError("Não foi possível criar o grupo."); return; }
      closeSide();
      open(r.id);
    });
  }
  const [selecting, setSelecting] = createSignal(false);
  const [picked, setPicked] = createSignal<string[]>([]);
  function startSelect() { setSide(""); setPicked([]); setSelecting(true); }
  function endSelect() { setSelecting(false); setPicked([]); }
  function togglePick(id: string) { const p = picked(); setPicked(p.indexOf(id) >= 0 ? p.filter((x) => x !== id) : [...p, id]); }
  function bulk(method: string, extra: any) { for (const id of picked()) call(method, { chat: id, ...extra }, ignore); endSelect(); }
  function bulkDelete() { for (const id of picked()) { if (id === sel()) setSel(""); call("sendDelete", { chat: id }, actionDone); } endSelect(); }

  // ---- the app lock (WhatsApp Web's "Bloqueio do app") -------------------------------------------
  const [lockOn, setLockOn] = createSignal(false);
  const [locked, setLocked] = createSignal(false);
  const [lockDialog, setLockDialog] = createSignal("");   // "" | set | disable
  const [lockPw, setLockPw] = createSignal("");
  const [lockPw2, setLockPw2] = createSignal("");
  const [lockError, setLockError] = createSignal("");
  call("AppLock.status", {}, (r: any, _e: any) => { if (r && r.enabled) { setLockOn(true); setLocked(true); } });
  function lockMenu() { if (lockOn()) { setLockPw(""); setLockError(""); setLocked(true); } else { setLockPw(""); setLockPw2(""); setLockError(""); setLockDialog("set"); } }
  function lockSave() {
    if (lockPw().length < 4) { setLockError("A senha precisa ter pelo menos 4 caracteres."); return; }
    if (lockPw() !== lockPw2()) { setLockError("As senhas não coincidem."); return; }
    call("AppLock.set", { password: lockPw() }, (_r: any, e: any) => { if (e) { setLockError("Não foi possível salvar a senha."); return; } setLockOn(true); setLockDialog(""); setLockPw(""); setLockPw2(""); });
  }
  function lockDisable() {
    call("AppLock.clear", { password: lockPw() }, (_r: any, e: any) => { if (e) { setLockError("Senha incorreta."); return; } setLockOn(false); setLockDialog(""); setLockPw(""); });
  }
  function unlock() {
    call("AppLock.check", { password: lockPw() }, (r: any, _e: any) => { if (r && r.ok) { setLocked(false); setLockPw(""); setLockError(""); } else setLockError("Senha incorreta."); });
  }

  // WhatsApp Web's archived view: the list's place, with its own header (← Arquivadas)
  const [showArchived, setShowArchived] = createSignal(false);
  const visible = createMemo(() => chats().filter(matches));
  function matches(c: Chat) {
    const f = filter().toLowerCase();
    if (!!c.archive !== showArchived()) return false;
    if (showArchived()) return f === "" || title(c).toLowerCase().indexOf(f) >= 0;
    if (tab() === "unread" && unreadOf(c) === 0 && !c.markedUnread) return false;
    if (tab() === "groups" && c.kind !== "group") return false;
    if (tab() === "favorites") return false;
    return f === "" || title(c).toLowerCase().indexOf(f) >= 0 || lastLine(c).toLowerCase().indexOf(f) >= 0;
  }
  const unreadChats = createMemo(() => chats().filter((c) => !c.archive && (c.unreadCount > 0 || c.markedUnread)).length);
  const unreadGroups = createMemo(() => chats().filter((c) => !c.archive && c.kind === "group" && c.unreadCount > 0).length);
  const archived = createMemo(() => chats().filter((c) => c.archive));
  const archivedUnread = createMemo(() => archived().filter((c) => c.unreadCount > 0).length);
  const rows = createMemo(() => rowsOf(msgs(), dayLabel, unreadMark().from, unreadMark().n, !msgSelecting()));
  // the row showing a message (a sticker may be inside a run)
  function rowIndex(id: string) { return rows().findIndex((r: any) => r.id === id || (!!r.stickers && r.stickers.some((x: any) => x.id === id))); }
  // leaving an SMS thread by any path (another chat, "Fechar conversa"…): it goes back under the
  // core's per-thread cap
  let lastSelForSms = "";
  createEffect(() => {
    const s = sel();
    if (isSms(lastSelForSms) && !isSms(s)) call("Sms.leave", {}, ignore);
    lastSelForSms = s;
  });
  const selChat = createMemo(() => chats().find((c) => c.id === sel()) || smsChats().find((c) => c.id === sel()));
  const totalUnread = createMemo(() => chats().reduce((n, c) => n + (muted(c) ? 0 : c.unreadCount), 0));
  createEffect(() => app.setUnread(totalUnread()));

  // ---- start ------------------------------------------------------------------------------------
  core.line.connect((l: string) => onLine(l));
  onMount(() => start());
  function start() { call("connect", {}, connected); }
  function connected(res: any, err: any) {
    if (err) { setConn("failed"); return; }
    if (res) onState(res.state);
  }
  function toPhone() { setPhoneError(""); setLinkMode("phone"); }
  function onlyDigits(t: string) { let o = ""; for (const ch of t.split("")) if (ch >= "0" && ch <= "9") o += ch; return o; }
  function shownPhone() { return "+" + country().dial + " " + phoneDigits().trim(); }
  // WAWebAltDeviceLinkingApi: the phone shows a notification, the user types the code there
  function askCode() {
    if (askingCode()) return;
    const n = onlyDigits(phoneDigits());
    if (n.length < 6) { setPhoneError("Número de telefone inválido."); return; }
    setPhoneError("");
    setAskingCode(true);
    call("pairPhone", { phone: country().dial + n }, (res: any, err: any) => {
      setAskingCode(false);
      if (err || !res || !res.code) { setPhoneError("Não foi possível gerar o código. Confira o número e tente de novo."); return; }
      let c = "";
      for (const ch of ("" + res.code).split("")) if (ch !== "-") c += ch;
      setPairCode(c);
      setLinkMode("code");
    });
  }
  function retry() { setConn("connecting"); start(); }

  return (
    <div class="app" classList={{ light: !isDark(), "th-paper": themeId() === "paper", "th-desert": themeId() === "desert", "th-sol-light": themeId() === "sol-light", "th-sol-dark": themeId() === "sol-dark", "th-nord": themeId() === "nord", "th-dracula": themeId() === "dracula", "th-molokai": themeId() === "molokai", "th-ctp-latte": themeId() === "ctp-latte", "th-ctp-frappe": themeId() === "ctp-frappe", "th-ctp-macchiato": themeId() === "ctp-macchiato", "th-ctp-mocha": themeId() === "ctp-mocha" }}>
      <Show when={conn() !== "ready"}>
        <div class="login">
          <div class="lg-head">
            <img class="lg-logo" src={ic("wa-logo", "#25D366")} />
            <img class="lg-word" src={ic("wordmark", "#25D366")} />
          </div>
          <div class="lg-main">
            <div class="lg-card">
              <Show when={conn() === "qr" && qrImage() !== "" && linkMode() === "qr"}>
                <div class="lg-qrcard">
                  <div class="lg-qrrow">
                    <div class="lg-left">
                      <text class="lg-title">Escaneie para entrar</text>
                      <div class="lg-steps">
                                                <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">1</text></div><div class="lg-conn" /></div><div class="lg-rich"><Rich text={"Use a câmera do seu celular para escanear o QR code."} boxWidth={439} /></div></div>
                        <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">2</text></div><div class="lg-conn" /></div><div class="lg-rich"><Rich text={"Toque no link para abrir o <b>WhatsApp</b> " + "<img src=\"" + ic("wa-badge", "#000000") + "\" width=\"24\" height=\"24\" align=\"middle\">" + "."} boxWidth={439} /></div></div>
                        <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">3</text></div></div><div class="lg-rich"><Rich text={"Escaneie o QR code novamente para acessar sua conta."} boxWidth={439} /></div></div>
                      </div>
                      <button class="lg-link lg-help" onClick={() => openLink("https://faq.whatsapp.com/1317564962315842")}>
                        <div class="lg-ul"><text class="lg-link-t">Precisa de ajuda?</text></div>
                        <img class="lg-link-ic" src={ic("north-east", "#1D1F1F")} />
                      </button>
                    </div>
                    <div class="lg-qr">
                      <img class="lg-qr-img" src={qrImage()} />
                      <div class="lg-qr-logo"><img class="lg-qr-logo-img" src={ic("qr-logo", "#122E31")} /></div>
                    </div>
                  </div>
                  <div class="lg-alt">
                    <button class="lg-link" onClick={() => toPhone()}>
                      <div class="lg-ul"><text class="lg-link-t">Entrar com número de telefone</text></div>
                      <img class="lg-link-ic" src={ic("chevron-right", "#1D1F1F")} />
                    </button>
                  </div>
                </div>
              </Show>
              <Show when={conn() === "qr" && linkMode() === "phone"}>
                <div class="lg-col">
                  <text class="lg-title lg-center">Insira o número de telefone</text>
                  <text class="lg-sub lg-center">Selecione o país e insira seu número de telefone.</text>
                  <div class="lg-form">
                    <div class="mhost" ref={mbtn1}><button class="lg-country" onClick={() => openUnder(mref1, mbtn1)}><text class="lg-country-t">{country().flag + "  " + country().name}</text><img class="lg-chev" src={ic("chevron-down", "#1D1F1F")} /></button></div>
                    <div class="lg-phone">
                      <text class="lg-dial">{"+" + country().dial}</text>
                      <input class="lg-phone-in" value={phoneDigits()} onInput={(e) => setPhoneDigits(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") askCode(); }} />
                    </div>
                    <Show when={phoneError() !== ""}><text class="lg-err">{phoneError()}</text></Show>
                  </div>
                  <button class="lg-next" onClick={() => askCode()}><text class="lg-next-t">{askingCode() ? "Aguarde…" : "Avançar"}</text></button>
                  <button class="lg-link lg-alt-c" onClick={() => setLinkMode("qr")}>
                    <div class="lg-ul"><text class="lg-link-t">Conectar com o QR code</text></div>
                    <img class="lg-link-ic" src={ic("chevron-right", "#1D1F1F")} />
                  </button>
                </div>
              </Show>
              <Show when={conn() === "qr" && linkMode() === "code"}>
                <div class="lg-col">
                  <text class="lg-title lg-center">Insira o código no seu celular</text>
                  <div class="lg-subrow"><Rich text={"Conectando a conta do WhatsApp <b>" + shownPhone() + "</b> (<a href=\"edit\"><u>Editar</u></a>)"} boxWidth={600} centered={true} lineHeightPx={21} textColor="#1D1F1F" onLink={() => setLinkMode("phone")} /></div>
                  <div class="lg-cells">
                    <For each={pairCode().slice(0, 4).split("")}>{(ch) => <div class="lg-cell"><text class="lg-cell-t">{ch}</text></div>}</For>
                    <text class="lg-dash">-</text>
                    <For each={pairCode().slice(4).split("")}>{(ch) => <div class="lg-cell"><text class="lg-cell-t">{ch}</text></div>}</For>
                  </div>
                  <div class="lg-steps lg-steps-c">
                                        <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">1</text></div><div class="lg-conn" /></div><div class="lg-rich"><Rich text={"Abra o <b>WhatsApp</b> " + "<img src=\"" + ic("wa-badge", "#000000") + "\" width=\"24\" height=\"24\" align=\"middle\">" + " no seu celular."} boxWidth={439} /></div></div>
                    <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">2</text></div><div class="lg-conn" /></div><div class="lg-rich"><Rich text={"Toque em <b>Mais opções</b> no Android ou em <b>Configurações</b> no iPhone."} boxWidth={439} /></div></div>
                    <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">3</text></div><div class="lg-conn" /></div><div class="lg-rich"><Rich text={"Toque em <b>Dispositivos conectados</b> e, em seguida, em <b>Conectar dispositivo</b>."} boxWidth={439} /></div></div>
                    <div class="lg-step"><div class="lg-stepcol"><div class="lg-num"><text class="lg-num-t">4</text></div></div><div class="lg-rich"><Rich text={"Toque em <b>Conectar com número de telefone</b> e insira o código exibido no seu celular."} boxWidth={439} /></div></div>
                  </div>
                  <button class="lg-link lg-alt-c" onClick={() => setLinkMode("qr")}>
                    <div class="lg-ul"><text class="lg-link-t">Conectar com o QR code</text></div>
                    <img class="lg-link-ic" src={ic("chevron-right", "#1D1F1F")} />
                  </button>
                </div>
              </Show>
              <Show when={conn() !== "qr" || (qrImage() === "" && linkMode() === "qr")}>
                <div class="lg-col">
                  <Show when={conn() === "connecting" || conn() === "qr"}><text class="lg-title">Carregando…</text></Show>
                  <Show when={conn() === "conflict"}>
                    <text class="lg-title">Aberto em outro lugar</text>
                    <text class="lg-sub">O WhatsApp está aberto em outro computador ou navegador.</text>
                    <button class="lg-next" onClick={() => retry()}><text class="lg-next-t">Usar aqui</text></button>
                  </Show>
                  <Show when={conn() === "loggedOut"}>
                    <text class="lg-title">Desconectado</text>
                    <text class="lg-sub">Este aparelho foi desconectado do WhatsApp.</text>
                    <button class="lg-next" onClick={() => retry()}><text class="lg-next-t">Conectar de novo</text></button>
                  </Show>
                  <Show when={conn() === "failed"}>
                    <text class="lg-title">Algo deu errado</text>
                    <text class="lg-sub">{"O núcleo do WhatsApp parou. " + core.lastError}</text>
                    <button class="lg-next" onClick={() => retry()}><text class="lg-next-t">Tentar de novo</text></button>
                  </Show>
                </div>
              </Show>
            </div>
            <div class="lg-foot">
              <div class="lg-noacc">
                <text class="lg-noacc-t">Não tem uma conta do WhatsApp?</text>
                <button class="lg-link lg-start" onClick={() => openLink("https://www.whatsapp.com/download")}>
                  <div class="lg-ul"><text class="lg-link-t">Começar</text></div>
                  <img class="lg-link-ic" src={ic("north-east", "#1D1F1F")} />
                </button>
              </div>
              <div class="lg-e2e">
                <img class="lg-lock" src={ic("lock", "rgba(0, 0, 0, 0.6)")} />
                <text class="lg-e2e-t">Suas mensagens pessoais são protegidas com a criptografia de ponta a ponta.</text>
              </div>
              <button class="lg-terms" onClick={() => openLink("https://www.whatsapp.com/legal/")}><text class="lg-terms-t">Termos de Serviço e Política de Privacidade</text></button>
            </div>
          </div>
        </div>
        </Show>

      <Show when={conn() === "ready"}>
        <div class="nav">
          <div class="nav-group">
            <button class="nb" classList={{ on: panel() === "chats" }} onClick={() => go("chats")}>
              <img class="nb-ic" src={ic(panel() === "chats" ? "chats-on" : "chats", navColor("chats"))} />
              <Show when={totalUnread() > 0}><div class="nav-badge"><text class="nav-badge-t">{"" + unreadChats()}</text></div></Show>
            </button>
            <button class="nb" classList={{ on: panel() === "calls" }} onClick={() => go("calls")}><img class="nb-ic" src={ic(panel() === "calls" ? "calls-on" : "calls", navColor("calls"))} /></button>
            <button class="nb" classList={{ on: panel() === "status" }} onClick={() => go("status")}><img class="nb-ic" src={ic("status", navColor("status"))} /><Show when={recentStatus().length > 0}><div class="nav-dot" /></Show></button>
            <button class="nb" classList={{ on: panel() === "channels" }} onClick={() => go("channels")}><img class="nb-ic" src={ic("channels", navColor("channels"))} /></button>
            <button class="nb" classList={{ on: panel() === "communities" }} onClick={() => go("communities")}><img class="nb-ic" src={ic("communities", navColor("communities"))} /></button>
            <Show when={smsStatus().enabled}>
              <button class="nb" classList={{ on: panel() === "sms" }} onClick={() => go("sms")}><img class="nb-ic" src={ic("message-circle", navColor("sms"))} /><Show when={smsUnread() > 0}><div class="nav-dot" /></Show></button>
            </Show>
            <div class="nav-sep" />
            <button class="nb" classList={{ on: sel() === META_AI }} onClick={() => openMetaAI("")}><img class="nb-ic" src={ic("meta-ai", "#9B8CFF")} /></button>
          </div>
          <div class="nav-group">
            <button class="nb" classList={{ on: mediaOpen() }} onClick={() => go("media")}><img class="nb-ic" src={ic("media", mediaOpen() ? tk().fg : tk().muted)} /></button>
            <button class="nb" classList={{ on: panel() === "profile" }} onClick={() => go("profile")}><div class="you" style={{ background: photo("me")[0] }}>
                <Show when={!myPic()}><img class="you-ic" src={ic("person", photo("me")[1])} /></Show>
                <Show when={!!myPic()}><img class="you-img" src={"file://" + myPic()} /></Show>
              </div></button>
          </div>
        </div>

        <div class="list" style={listStyle()}>
          <Show when={panel() === "chats"}>
          <div class="pane">
          <Show when={!showArchived() && side() === "" && !selecting()}>
          <div class="list-top">
          <div class="list-head">
            <Measure cls="list" onMeasured={(w: number) => setListReal(Math.round(w))} />
            <img class="wordmark" src={ic("wordmark", tk().brand)} />
            <div class="grow" />
            <div class="head-btns">
              <div class="mhost" ref={mbtn2}><button class="ib" onClick={() => openUnder(mref2, mbtn2)}><img class="ic" src={ic("menu", tk().fg)} /></button></div>
              <button class="fab" onClick={() => openSide("newChat")}><img class="ic" src={ic("new-chat", tk().onAccent)} /></button>
            </div>
          </div>
          <div class="search">
            <div class="search-pill">
              <img class="search-ic" src={ic("search", tk().muted)} />
              <input class="search-in" ref={searchInput} placeholder={searchScope() !== "" ? "Pesquisar nesta conversa" : searchHint()} value={filter()} onInput={(e) => searchTyped(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Escape") escSearch(); }} />
              <Show when={filter() !== ""}>
                <div class="search-x" onClick={() => clearSearch()}><img class="ic20" src={ic("close", tk().muted)} /></div>
              </Show>
            </div>
          </div>
          <div class="filters">
            <div class="chips-in">
            <For each={FILTERS.slice(0, chipsShown())}>{(f) => (
              <button class="chip" classList={{ on: tab() === f.id }} onClick={() => setTab(f.id)}>
                <text class="chip-t">{f.label}</text>
                <Show when={chipCount(f.id) > 0}><text class="chip-n">{"" + chipCount(f.id)}</text></Show>
              </button>
            )}</For>
            </div>
            <div class="mhost" ref={mbtn3}><button class="chip chip-more" onClick={() => openUnder(mref3, mbtn3)}><img class="ic20" src={ic("drop-down", tk().muted)} /></button></div>
          </div>
          <Show when={syncing() !== ""}><text class="chip-n">{syncing()}</text></Show>
          <Show when={archived().length > 0 && tab() === "all"}>
            <div class="archived" onClick={() => setShowArchived(true)}>
              <div class="archived-ic"><img class="ic" src={ic("archive", tk().muted)} /></div>
              <text class="archived-t">Arquivadas</text>
              <Show when={archivedUnread() > 0}><text class="archived-n">{"" + archivedUnread()}</text></Show>
            </div>
          </Show>
          </div>
          </Show>
          <Show when={showArchived() && side() === "" && !selecting()}>
            <div class="arch-head">
              <button class="ib" onClick={() => setShowArchived(false)}><img class="ic" src={ic("back", tk().fg)} /></button>
              <text class="arch-title">Arquivadas</text>
            </div>
          </Show>
          <Show when={selecting()}>
            <div class="arch-head">
              <button class="ib" onClick={() => endSelect()}><img class="ic" src={ic("close", tk().fg)} /></button>
              <text class="arch-title grow">{picked().length === 1 ? "1 selecionada" : picked().length + " selecionadas"}</text>
              <button class="ib" onClick={() => bulk("setArchive", { archive: !showArchived() })}><img class="ic" src={ic("archive", tk().fg)} /></button>
              <button class="ib" onClick={() => bulk("setPin", { pin: true })}><img class="ic" src={ic("pin", tk().fg)} /></button>
              <button class="ib" onClick={() => bulk("sendSeen", {})}><img class="ic" src={ic("dblcheck", tk().fg)} /></button>
              <button class="ib" onClick={() => bulkDelete()}><img class="ic" src={ic("delete", tk().fg)} /></button>
            </div>
          </Show>
          <Show when={side() === "newChat"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => closeSide()}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title">Nova conversa</text>
              </div>
              <div class="search"><div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Pesquisar nome ou número" value={sideQuery()} onInput={(e) => setSideQuery(e.currentTarget.value)} />
              </div></div>
              <div class="side-list">
                <div class="fwd-row" onClick={() => openSide("newGroup")}>
                  <div class="av av40 green"><img class="av-ic" src={ic("group-add", tk().onAccent)} /></div>
                  <text class="fwd-name">Novo grupo</text>
                </div>
                <text class="side-label">Contatos no WhatsApp</text>
                <For each={sideContacts()}>{(k: any) => (
                  <div class="fwd-row" onClick={() => startChat(k.id)}>
                    <div class="av av40" style={{ background: photo(k.id)[0] }}>
                      <Show when={!k.profilePicThumb || k.profilePicThumb === "-"}><img class="av-ic" src={ic("person", photo(k.id)[1])} /></Show>
                      <Show when={!!k.profilePicThumb && k.profilePicThumb !== "-"}><img class="av-img" src={"file://" + (k.profilePicThumb || "")} /></Show>
                    </div>
                    <div class="side-text"><text class="side-name">{k.name}</text><Show when={!!k.status}><text class="side-sub">{k.status || ""}</text></Show></div>
                  </div>
                )}</For>
              </div>
            </div>
          </Show>
          <Show when={side() === "smsNew"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => closeSide()}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title">Nova mensagem SMS</text>
              </div>
              <Show when={smsPicked().length > 0}><text class="side-picked">{smsPickedNames()}</text></Show>
              <div class="search"><div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Nome ou número" value={sideQuery()} onInput={(e) => setSideQuery(e.currentTarget.value)} />
              </div></div>
              <Show when={sideError() !== ""}><text class="lg-err sms-err">{sideError()}</text></Show>
              <div class="side-list">
                <For each={smsCandidates()}>{(k: any) => (
                  <div class="fwd-row" onClick={() => { toggleSmsPick(k.number); if (k.typed) setSideQuery(""); }}>
                    <div class="fwd-check" classList={{ on: smsPicked().indexOf(k.number) >= 0 }}><Show when={smsPicked().indexOf(k.number) >= 0}><img class="ic16" src={ic("check", tk().onAccent)} /></Show></div>
                    <div class="av av40" style={{ background: photo(k.number)[0] }}><img class="av-ic" src={ic("person", photo(k.number)[1])} /></div>
                    <div class="side-text"><text class="side-name">{k.name}</text><Show when={k.name !== k.label}><text class="side-sub">{k.label}</text></Show></div>
                  </div>
                )}</For>
              </div>
              <Show when={smsPicked().length > 0}>
                <div class="side-field"><input class="input" placeholder={smsPicked().length > 1 ? "Mensagem para o grupo (MMS)" : "Mensagem"} value={smsNewBody()} onInput={(e) => setSmsNewBody(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") sendSmsNew(); }} /></div>
                <div class="side-foot"><button class="fab fab56" onClick={() => sendSmsNew()}><img class="ic" src={ic("send", tk().onAccent)} /></button></div>
              </Show>
            </div>
          </Show>
          <Show when={side() === "newGroup"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => openSide("newChat")}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title">Adicionar participantes do grupo</text>
              </div>
              <Show when={groupPicked().length > 0}><text class="side-picked">{groupPickedNames()}</text></Show>
              <div class="search"><div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Pesquisar nome ou número" value={sideQuery()} onInput={(e) => setSideQuery(e.currentTarget.value)} />
              </div></div>
              <div class="side-list">
                <For each={sideContacts()}>{(k: any) => (
                  <div class="fwd-row" onClick={() => toggleGroupPick(k.id)}>
                    <div class="fwd-check" classList={{ on: groupPicked().indexOf(k.id) >= 0 }}><Show when={groupPicked().indexOf(k.id) >= 0}><img class="ic16" src={ic("check", tk().onAccent)} /></Show></div>
                    <div class="av av40" style={{ background: photo(k.id)[0] }}><img class="av-ic" src={ic("person", photo(k.id)[1])} /></div>
                    <text class="fwd-name">{k.name}</text>
                  </div>
                )}</For>
              </div>
              <Show when={groupPicked().length > 0}>
                <div class="side-foot"><button class="fab fab56" onClick={() => openSide("groupName")}><img class="ic" src={ic("arrow-forward", tk().onAccent)} /></button></div>
              </Show>
            </div>
          </Show>
          <Show when={side() === "groupName"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => openSide("newGroup")}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title">Novo grupo</text>
              </div>
              <div class="side-center">
                <div class="av av200" style={{ background: photo("new-group")[0] }}><img class="av-ic-big" src={ic("group", photo("new-group")[1])} /></div>
                <div class="side-field"><input class="input" placeholder="Nome do grupo" value={groupName()} onInput={(e) => setGroupName(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") makeGroup(); }} /></div>
                <Show when={sideError() !== ""}><text class="lg-err">{sideError()}</text></Show>
              </div>
              <Show when={groupName().trim() !== ""}>
                <div class="side-foot"><button class="fab fab56" onClick={() => makeGroup()}><img class="ic" src={ic("check", tk().onAccent)} /></button></div>
              </Show>
            </div>
          </Show>
          <Show when={side() === "community"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => closeSide()}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title grow">{commView() ? commView().name : "Comunidade"}</text>
              </div>
              <div class="side-list">
                <Show when={commView() === null}><text class="empty-note">Carregando…</text></Show>
                <Show when={!!commView() && !!commView().announce}>
                  <div class="fwd-row cm-row" onClick={() => { const a = commView().announce; closeSide(); open(a.id); }}>
                    <div class="av av48 cm-ann"><img class="av-ic" src={ic("megaphone", "#A9A1FF")} /></div>
                    <div class="side-text">
                      <div class="cm-top"><text class="side-name grow">Avisos</text><text class="cell-time">{commView().announce ? when(commView().announce.t) : ""}</text></div>
                      <div class="cm-top"><text class="side-sub grow">{commView().announce ? lineWho(commView().announce) + lineRest(commView().announce) : ""}</text><img class="cell-ic" src={ic("pin", tk().muted)} /></div>
                    </div>
                  </div>
                </Show>
                <Show when={!!commView()}>
                  <text class="cm-label">Grupos de que você participa</text>
                  <div class="fwd-row cm-row" onClick={() => openSide("newGroup")}>
                    <div class="av av48 green"><img class="av-ic" src={ic("group-add", tk().onAccent)} /></div>
                    <text class="side-name">Adicionar grupo</text>
                  </div>
                </Show>
                <For each={commView() ? commView().joined : []}>{(g: any) => (
                  <div class="fwd-row cm-row" onClick={() => { closeSide(); open(g.id); }}>
                    <div class="av av48" style={{ background: photo(g.id)[0] }}>
                      <Show when={!g.profilePicThumb}><img class="av-ic" src={ic("group", photo(g.id)[1])} /></Show>
                      <Show when={!!g.profilePicThumb}><img class="av-img" src={"file://" + (g.profilePicThumb || "")} /></Show>
                    </div>
                    <div class="side-text">
                      <div class="cm-top"><text class="side-name grow">{g.name}</text><text class="cell-time">{when(g.t)}</text></div>
                      <text class="side-sub">{lineWho(g) + lineRest(g)}</text>
                    </div>
                  </div>
                )}</For>
                <Show when={!!commView() && commView().available.length > 0}><text class="cm-label">Grupos em que você pode entrar</text></Show>
                <For each={commView() ? commView().available : []}>{(g: any) => (
                  <div class="fwd-row cm-row" onClick={() => joinSub(g)}>
                    <div class="av av48 cm-avail"><img class="av-ic" src={ic("chats", tk().fg)} /></div>
                    <div class="side-text">
                      <text class="side-name">{g.name}</text>
                      <text class="side-sub">{joining() === g.id ? "Entrando…" : g.size ? g.size + " membros" : ""}</text>
                    </div>
                  </div>
                )}</For>
                <Show when={commError() !== ""}><text class="lg-err cm-err">{commError()}</text></Show>
              </div>
            </div>
          </Show>
          <Show when={side() === "starred"}>
            <div class="side">
              <div class="arch-head">
                <button class="ib" onClick={() => closeSide()}><img class="ic" src={ic("back", tk().fg)} /></button>
                <text class="arch-title">Mensagens favoritas</text>
              </div>
              <div class="side-list">
                <Show when={starred().length === 0}><text class="empty-note">Nenhuma mensagem favorita</text></Show>
                <For each={starred()}>{(m: any) => (
                  <div class="star-row" onClick={() => { closeSide(); open(m.remote); }}>
                    <div class="star-top">
                      <text class="star-who">{(m.fromMe ? "Você" : (m.senderName || m.chatName || shortJid(m.remote))) + (isGroup(m.remote) || m.fromMe ? "  ›  " + (m.chatName || "") : "")}</text>
                      <text class="cell-time">{when(m.t)}</text>
                    </div>
                    <text class="star-body">{oneLine(typeLabel(m.type || "chat", m.body || m.caption || ""))}</text>
                  </div>
                )}</For>
              </div>
            </div>
          </Show>
          <Show when={side() === "" && searchMode()}>
            <div class="plist">
              <Show when={searchScope() !== ""}>
                <div class="sres-scope">
                  <text class="sres-scope-t">{"Mensagens em " + scopeTitle()}</text>
                  <div class="search-x" onClick={() => endScope()}><img class="ic20" src={ic("close", tk().muted)} /></div>
                </div>
              </Show>
              <Show when={resChats().length > 0}><text class="sres-h">Contatos</text></Show>
              <For each={resChats()}>{(c: any) => (
                <div class="sres-row" onClick={() => openResult(c.id)}>
                  <div class="av av40" style={{ background: photo(c.id)[0] }}>
                    <Show when={!c.profilePicThumb}><img class="av-ic" src={ic(c.kind === "group" ? "group" : "person", photo(c.id)[1])} /></Show>
                    <Show when={!!c.profilePicThumb}><img class="av-img" src={"file://" + (c.profilePicThumb || "")} /></Show>
                  </div>
                  <text class="sres-name">{title(c)}</text>
                </div>
              )}</For>
              <Show when={resMsgs().length > 0}><text class="sres-h">Mensagens</text></Show>
              <For each={resMsgs()}>{(m: any) => (
                <div class="sres-row" onClick={() => openHit(m)}>
                  <div class="av av40" style={{ background: photo(hitAvatarId(m))[0] }}>
                    <Show when={hitPic(m) === ""}><img class="av-ic" src={ic(isGroup(hitAvatarId(m)) ? "group" : "person", photo(hitAvatarId(m))[1])} /></Show>
                    <Show when={hitPic(m) !== ""}><img class="av-img" src={"file://" + hitPic(m)} /></Show>
                  </div>
                  <div class="sres-col">
                    <div class="sres-top">
                      <text class="sres-name">{hitTitle(m)}</text>
                      <text class="sres-when">{dayLabel(m.t)}</text>
                    </div>
                    <Rich text={hitLine(m)} fillClass="sres-col" fontSize={14} lineHeightPx={20} textColor={qcolor(tk().muted)} />
                  </div>
                </div>
              )}</For>
              <Show when={filter().trim() !== "" && searchRes() !== null && resChats().length === 0 && resMsgs().length === 0}>
                <text class="hit-none">Nenhum resultado</text>
              </Show>
            </div>
          </Show>
          <Show when={side() === "" && !searchMode()}>
          <VirtualList class="chats" each={visible()} key="id">
            {(c: Chat) => (
              <div class="row">
                <div class="cell" classList={{ on: c.id === sel() }} onClick={() => selecting() ? togglePick(c.id) : open(c.id)} onContextMenu={(e) => openChatMenu(c, e.clientX, e.clientY)}>
                  <Show when={selecting()}><div class="cell-sel"><div class="fwd-check" classList={{ on: picked().indexOf(c.id) >= 0 }}><Show when={picked().indexOf(c.id) >= 0}><img class="ic16" src={ic("check", tk().onAccent)} /></Show></div></div></Show>
                  <div class="cell-av">
                    <div class="av-ring" classList={{ fresh: storyState(c.id) === "new", seen: storyState(c.id) === "seen" }} onClick={() => { const st = statuses().find((x: any) => x.id === c.id); if (st) watchStatus(st); }}>
                    <div class="av" style={{ background: photo(c.id)[0] }}>
                      <Show when={!c.profilePicThumb}><img class="av-ic" src={ic(c.kind === "user" ? "person" : "group", photo(c.id)[1])} /></Show>
                      <Show when={!!c.profilePicThumb}><img class="av-img" src={"file://" + (c.profilePicThumb || "")} /></Show>
                    </div>
                    </div>
                  </div>
                  <div class="cell-text">
                    <div class="cell-top">
                      <Show when={!!c.unknown}><div class="unknown-tag cell-unknown"><text class="unknown-tag-t">desconhecido</text></div></Show>
                      <text class="cell-name">{title(c)}</text>
                      <text class="cell-time" classList={{ hot: (c.unreadCount > 0 || c.markedUnread) && !muted(c) }}>{when(c.t)}</text>
                    </div>
                    <div class="cell-bottom">
                      <Show when={showsTick(c.lastMsg) && !isTyping(c)}><img class="cell-tick" src={ic(tickIcon(c.lastMsg ? c.lastMsg.ack : 0), tickColor(c.lastMsg ? c.lastMsg.ack : 0))} /></Show>
                      <Show when={lineWho(c) !== ""}><text class="cell-who">{lineWho(c)}</text></Show>
                      <Show when={lineIcon(c) !== ""}><img class="cell-type" src={ic(lineIcon(c), tk().muted)} /></Show>
                      <div class="tdots" classList={{ on: isTyping(c) }}><TypingDots active={isTyping(c)} dotColor={tk().accent} /></div>
                      <text class="cell-preview" classList={{ typing: isTyping(c) }}>{lineRest(c)}</text>
                      <Show when={muted(c)}><img class="cell-ic" src={ic("muted", tk().muted)} /></Show>
                      <Show when={c.unreadCount > 0 || c.markedUnread}><div class="unread" classList={{ muted: muted(c) }}><text class="unread-t">{c.unreadCount > 0 ? "" + c.unreadCount : ""}</text></div></Show>
                      <Show when={c.pin > 0 && c.unreadCount === 0 && !c.markedUnread}><img class="cell-ic" src={ic("pin", tk().muted)} /></Show>
                    </div>
                  </div>
                </div>
              </div>
            )}
          </VirtualList>
          </Show>
          </div>
          </Show>
          <Show when={panel() !== "chats"}>
            <div class="list-head"><text class="panel-title">{panelTitle()}</text>
              <Show when={panel() === "sms"}><div class="head-space" /><button class="ib" onClick={() => openSmsNew()}><img class="ic" src={ic("new-chat", tk().fg)} /></button></Show>
            </div>
          </Show>
          <Show when={panel() === "calls"}>
            <div class="plist">
              <Show when={calls().length === 0}><text class="empty-note">Nenhuma ligação recente</text></Show>
              <For each={calls()}>
                {(m: any) => (
                  <div class="prow" onClick={() => openFromPanel(m.remote)}>
                    <div class="av" style={{ background: photo(m.remote)[0] }}><img class="av-ic" src={ic(isGroup(m.remote) ? "group" : "person", photo(m.remote)[1])} /></div>
                    <div class="prow-text">
                      <text class="prow-name" classList={{ missed: callMissed(m) }}>{m.chatName || shortJid(m.remote)}</text>
                      <text class="prow-sub">{callLabel(m)}</text>
                    </div>
                    <img class="ic" src={ic(m.isVideoCall ? "video-call" : "voice-call", tk().muted)} />
                  </div>
                )}
              </For>
            </div>
          </Show>
          <Show when={panel() === "status"}>
            <div class="plist">
              <Show when={statuses().length === 0}><text class="empty-note">Nenhuma atualização de status nas últimas 24 horas</text></Show>
              <For each={myStatus()}>{(st: any) => (
                  <div class="prow" onClick={() => watchStatus(st)} onContextMenu={(e) => openStatusMenu(st, e.clientX, e.clientY)}>
                    <div class="sring"><StatusRing class="sring-arcs" seen={ringSeen(st)} accent={tk().accent} muted={tk().muted} /><div class="av av40" style={{ background: photo(st.id)[0] }}>
                      <Show when={!st.profilePicThumb}><img class="av-ic" src={ic("person", photo(st.id)[1])} /></Show>
                      <Show when={!!st.profilePicThumb}><img class="av-img" src={"file://" + (st.profilePicThumb || "")} /></Show>
                    </div></div>
                    <div class="prow-text">
                      <text class="prow-name">{st.name}</text>
                      <text class="prow-sub">{statusWhen(st.t) + (st.items.length > 1 ? " · " + st.items.length + " atualizações" : "")}</text>
                    </div>
                  </div>
                )}</For>
              <Show when={recentStatus().length > 0}><text class="side-label">Recentes</text></Show>
              <For each={recentStatus()}>{(st: any) => (
                  <div class="prow" onClick={() => watchStatus(st)} onContextMenu={(e) => openStatusMenu(st, e.clientX, e.clientY)}>
                    <div class="sring"><StatusRing class="sring-arcs" seen={ringSeen(st)} accent={tk().accent} muted={tk().muted} /><div class="av av40" style={{ background: photo(st.id)[0] }}>
                      <Show when={!st.profilePicThumb}><img class="av-ic" src={ic("person", photo(st.id)[1])} /></Show>
                      <Show when={!!st.profilePicThumb}><img class="av-img" src={"file://" + (st.profilePicThumb || "")} /></Show>
                    </div></div>
                    <div class="prow-text">
                      <text class="prow-name">{st.name}</text>
                      <text class="prow-sub">{statusWhen(st.t) + (st.items.length > 1 ? " · " + st.items.length + " atualizações" : "")}</text>
                    </div>
                  </div>
                )}</For>
              <Show when={seenStatus().length > 0}><text class="side-label">Vistas</text></Show>
              <For each={seenStatus()}>{(st: any) => (
                  <div class="prow" onClick={() => watchStatus(st)} onContextMenu={(e) => openStatusMenu(st, e.clientX, e.clientY)}>
                    <div class="sring"><StatusRing class="sring-arcs" seen={ringSeen(st)} accent={tk().accent} muted={tk().muted} /><div class="av av40" style={{ background: photo(st.id)[0] }}>
                      <Show when={!st.profilePicThumb}><img class="av-ic" src={ic("person", photo(st.id)[1])} /></Show>
                      <Show when={!!st.profilePicThumb}><img class="av-img" src={"file://" + (st.profilePicThumb || "")} /></Show>
                    </div></div>
                    <div class="prow-text">
                      <text class="prow-name">{st.name}</text>
                      <text class="prow-sub">{statusWhen(st.t) + (st.items.length > 1 ? " · " + st.items.length + " atualizações" : "")}</text>
                    </div>
                  </div>
                )}</For>
              <Show when={mutedStatus().length > 0}>
                <div class="side-label-row" onClick={() => mutedOpenToggle()}>
                  <text class="side-label">Silenciados</text>
                  <img class="ic side-label-ic" src={ic(mutedOpen() ? "chevron-down" : "chevron-right", tk().muted)} />
                </div>
              </Show>
              <For each={mutedOpen() ? mutedStatus() : []}>{(st: any) => (
                  <div class="prow prow-muted" onClick={() => watchStatus(st)} onContextMenu={(e) => openStatusMenu(st, e.clientX, e.clientY)}>
                    <div class="sring"><StatusRing class="sring-arcs" seen={ringSeen(st)} accent={tk().accent} muted={tk().muted} /><div class="av av40" style={{ background: photo(st.id)[0] }}>
                      <Show when={!st.profilePicThumb}><img class="av-ic" src={ic("person", photo(st.id)[1])} /></Show>
                      <Show when={!!st.profilePicThumb}><img class="av-img" src={"file://" + (st.profilePicThumb || "")} /></Show>
                    </div></div>
                    <div class="prow-text">
                      <text class="prow-name">{st.name}</text>
                      <text class="prow-sub">{statusWhen(st.t) + (st.items.length > 1 ? " · " + st.items.length + " atualizações" : "")}</text>
                    </div>
                  </div>
                )}</For>
            </div>
          </Show>
          <Show when={panel() === "channels"}>
            <div class="plist">
              <Show when={channelList().length === 0}><text class="empty-note">Você não segue nenhum canal</text></Show>
              <For each={channelList()}>
                {(ch: any) => (
                  <div class="prow" onClick={() => openChannel(ch)}>
                    <div class="av" style={{ background: photo(ch.id)[0] }}>
                      <Show when={!ch.pic}><img class="av-ic" src={ic("channels", photo(ch.id)[1])} /></Show>
                      <Show when={!!ch.pic}><img class="av-img" src={"file://" + (ch.pic || "")} /></Show>
                    </div>
                    <div class="prow-text">
                      <text class="prow-name">{ch.name}</text>
                      <text class="prow-sub">{followers(ch.subscribers)}</text>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Show>
          <Show when={panel() === "sms"}>
            <div class="plist">
              <div class="search"><div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Pesquisar nome, número ou mensagem" value={smsQuery()} onInput={(e) => setSmsQuery(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Escape") setSmsQuery(""); }} />
              </div></div>
              <Show when={smsNote() !== ""}><text class="empty-note">{smsNote()}</text></Show>
              <For each={smsVisible()}>
                {(c: Chat) => (
                  <div class="prow" classList={{ on: sel() === c.id }} onClick={() => open(c.id)}>
                    <div class="av" style={{ background: photo(c.id)[0] }}>
                      <Show when={!c.profilePicThumb}><img class="av-ic" src={ic("message-circle", photo(c.id)[1])} /></Show>
                      <Show when={!!c.profilePicThumb}><img class="av-img" src={"file://" + (c.profilePicThumb || "")} /></Show>
                    </div>
                    <div class="prow-text">
                      <text class="prow-name">{c.name}</text>
                      <text class="prow-sub">{(c.lastMsg && c.lastMsg.fromMe ? "Você: " : "") + (c.lastMsg ? oneLine(c.lastMsg.body) : "")}</text>
                    </div>
                    <Show when={c.unreadCount > 0}><div class="unread"><text class="unread-t">{"" + c.unreadCount}</text></div></Show>
                  </div>
                )}
              </For>
            </div>
          </Show>
          <Show when={panel() === "communities"}>
            <div class="plist">
              <Show when={communityList().length === 0}><text class="empty-note">Você não participa de nenhuma comunidade</text></Show>
              <For each={communityList()}>
                {(cm: any) => (
                  <div class="community">
                    <div class="prow" onClick={() => openCommunity(cm.id)}>
                      <div class="av sq" style={{ background: photo(cm.id)[0] }}>
                        <Show when={!cm.pic}><img class="av-ic" src={ic("communities", photo(cm.id)[1])} /></Show>
                        <Show when={!!cm.pic}><img class="av-img-sq" src={"file://" + (cm.pic || "")} /></Show>
                      </div>
                      <text class="prow-name">{cm.name}</text>
                    </div>
                    <For each={cm.groups}>
                      {(g: any) => (
                        <div class="prow sub" onClick={() => openFromPanel(g.id)}>
                          <div class="av av40" style={{ background: photo(g.id)[0] }}><img class="av-ic" src={ic("group", photo(g.id)[1])} /></div>
                          <div class="prow-text">
                            <text class="prow-name">{g.name}</text>
                            <text class="prow-sub">{g.lastMsg ? oneLine((g.lastMsg.senderName ? g.lastMsg.senderName + ": " : "") + typeLabel(g.lastMsg.type, g.lastMsg.body)) : ""}</text>
                          </div>
                        </div>
                      )}
                    </For>
                  </div>
                )}
              </For>
            </div>
          </Show>
          <Show when={panel() === "media"}>
            <div class="plist">
              <Show when={mediaList().length === 0}><text class="empty-note">Nenhuma foto ou vídeo</text></Show>
              <div class="grid">
                <For each={mediaList()}>
                  {(m: any) => (
                    <div class="tile" onClick={() => openMedia(m)}>
                      <Show when={mediaThumb(m) !== ""}><img class="tile-img" src={mediaThumb(m)} /></Show>
                      <Show when={m.type === "video"}><div class="tile-badge"><img class="ic20" src={ic("videocam", "#FFFFFF")} /></div></Show>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>
          <Show when={panel() === "profile"}>
            <div class="plist">
              <div class="info-card info-top">
                <div class="info-av" style={{ background: photo("me")[0] }} onClick={() => viewMyPic()} onMouseEnter={() => setAvHover(true)} onMouseLeave={() => setAvHover(false)}>
                  <Show when={!(me() && me().profilePicThumb)}><img class="info-av-ic" src={ic("person", photo("me")[1])} /></Show>
                  <Show when={!!(me() && me().profilePicThumb)}><img class="info-av-img" src={"file://" + (me() ? me().profilePicThumb || "" : "")} /></Show>
                  <Show when={avHover()}><div class="av-cam" onClick={() => pickAvatar()}><img class="ic24" src={ic("camera", "#FFFFFF")} /></div></Show>
                </div>
                <text class="info-name">{me() ? me().pushname : ""}</text>
                <text class="info-sub">{me() ? me().phoneNumber : ""}</text>
              </div>
              <div class="info-card">
                <text class="info-label">Recado</text>
                <Show when={!aboutEditing()}>
                  <div class="info-row" onClick={() => editAbout()}>
                    <text class="info-text">{me() && me().status ? me().status : "Toque para escrever um recado"}</text>
                  </div>
                </Show>
                <Show when={aboutEditing()}>
                  <input class="about-in" ref={aboutInput} value={aboutDraft()} onInput={(e) => setAboutDraft(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") saveAbout(); if (e.key === "Escape") setAboutEditing(false); }} />
                  <text class="about-hint">Enter salva · Esc cancela</text>
                </Show>
              </div>
              <div class="info-card">
                <div class="info-row" onClick={() => setThemeOpen(!themeOpen())}>
                  <img class="ic" src={ic("settings", tk().muted)} />
                  <text class="info-row-t">Tema</text>
                  <text class="theme-cur">{themeName()}</text>
                </div>
                <Show when={themeOpen()}>
                  <div class="theme-list">
                    <For each={[{ id: "light", name: "Claro" }, { id: "dark", name: "Escuro" }, ...THEMES]}>{(o: any) => (
                      <div class="pin-opt" onClick={() => setTheme(o.id)}>
                        <div class="radio" classList={{ on: themeIs(o.id) }}><Show when={themeIs(o.id)}><div class="radio-dot" /></Show></div>
                        <text class="side-name">{o.name}</text>
                      </div>
                    )}</For>
                  </div>
                </Show>
                <div class="info-row" onClick={() => setNotifications(!notificationsOn())}>
                  <img class="ic" src={ic("muted", tk().muted)} />
                  <text class="info-row-t">Notificações</text>
                  <div class="toggle" classList={{ on: notificationsOn() }}><div class="toggle-knob" /></div>
                </div>
                <div class="info-row" onClick={() => setStatusNotifications(!statusNotificationsOn())}>
                  <img class="ic" src={ic("status", tk().muted)} />
                  <text class="info-row-t">Notificações de status</text>
                  <div class="toggle" classList={{ on: statusNotificationsOn() }}><div class="toggle-knob" /></div>
                </div>
                <div class="info-row" onClick={() => setSmsOn(!smsOn())}>
                  <img class="ic" src={ic("message-circle", tk().muted)} />
                  <text class="info-row-t">SMS pelo KDE Connect</text>
                  <div class="toggle" classList={{ on: smsOn() }}><div class="toggle-knob" /></div>
                </div>
                <div class="info-row" onClick={() => setDenoise(!denoiseOn())}>
                  <img class="ic" src={ic("mic", tk().muted)} />
                  <text class="info-row-t">Reduzir ruído na voz</text>
                  <div class="toggle" classList={{ on: denoiseOn() }}><div class="toggle-knob" /></div>
                </div>
              </div>
              <div class="info-card">
                <div class="info-row" onClick={() => logout()}>
                  <img class="ic" src={ic("back", "#FB5061")} />
                  <text class="info-row-t danger-t">Desconectar</text>
                </div>
              </div>
            </div>
          </Show>
        </div>

        <div class="divider"><Splitter onDragged={(x: number) => dragList(x)} onReleased={() => keepList()} /></div>
        <div class="conv" classList={{ cz5: zoomK() === 5, cz6: zoomK() === 6, cz7: zoomK() === 7, cz8: zoomK() === 8, cz9: zoomK() === 9, cz11: zoomK() === 11, cz12: zoomK() === 12, cz13: zoomK() === 13, cz14: zoomK() === 14, cz15: zoomK() === 15, cz16: zoomK() === 16, cz17: zoomK() === 17, cz18: zoomK() === 18, cz19: zoomK() === 19, cz20: zoomK() === 20 }}>
          <Show when={sel() === ""}>
            <div class="intro">
              <text class="intro-t">QWhats</text>
              <div class="intro-rich"><Rich text={"Envie e receba mensagens sem precisar manter seu celular conectado."} fillClass="intro" inset={80} centered={true} fontSize={14} lineHeightPx={20} textColor={qcolor(tk().muted)} /></div>
              <div class="intro-lock"><Rich text={"<img src=\"" + ic("lock", tk().muted) + "\" width=\"20\" height=\"20\" align=\"middle\"> Suas mensagens pessoais são protegidas com a criptografia de ponta a ponta."} fillClass="intro" inset={80} centered={true} fontSize={14} lineHeightPx={20} textColor={qcolor(tk().muted)} /></div>
            </div>
          </Show>
          <Show when={sel() !== "" && !relaying()}>
            <div class="wall"><Wallpaper source={doodle()} base={tk().wall} strength={tk().doodleAlpha} onPaneWidth={(w: number) => paneResized(w)} /></div>
            <Show when={msgSelecting()}>
              <div class="conv-head sel-head">
                <button class="ib" onClick={() => endMsgSelect()}><img class="ic" src={ic("close", tk().fg)} /></button>
                <text class="sel-count">{pickedMsgs().length > 0 ? pickedMsgs().length + " selecionada" + (pickedMsgs().length > 1 ? "s" : "") : "Nenhuma selecionada"}</text>
                <div class="conv-btns">
                  <button class="ib" classList={{ off: pickedMsgs().length === 0 }} onClick={() => selStar()}><img class="ic" src={ic("star", tk().fg)} /></button>
                  <button class="ib" classList={{ off: pickedMsgs().length === 0 }} onClick={() => selForward()}><img class="ic" src={ic("forward", tk().fg)} /></button>
                  <button class="ib" classList={{ off: pickedMsgs().length === 0 }} onClick={() => { if (pickedMsgs().length > 0) setDelAsk(true); }}><img class="ic" src={ic("delete", tk().fg)} /></button>
                </div>
              </div>
            </Show>
            <div class="conv-head">
              <div class="conv-av" onClick={() => openInfo()}>
                <div class="av av40" style={{ background: photo(sel())[0] }}>
                  <Show when={!(selChat() && selChat()!.profilePicThumb)}><img class="av-ic" src={ic(isGroup(sel()) ? "group" : "person", photo(sel())[1])} /></Show>
                  <Show when={!!(selChat() && selChat()!.profilePicThumb)}><img class="av-img" src={"file://" + (selChat() ? selChat()!.profilePicThumb || "" : "")} /></Show>
                </div>
              </div>
              <div class="conv-title" onClick={() => openInfo()}>
                <div class="conv-name-row">
                  <Show when={!!(selChat() && selChat()!.unknown)}><div class="unknown-tag"><text class="unknown-tag-t">desconhecido</text></div></Show>
                  <text class="conv-name">{selChat() ? title(selChat()!) : shortJid(sel())}</text>
                </div>
                <Show when={convSub() !== ""}><div class="conv-sub-row"><TypingDots active={selTyping()} dotColor={tk().muted} /><text class="conv-sub">{convSub()}</text></div></Show>
              </div>
              <div class="conv-btns">
                <Show when={!isChannel(sel()) && !inCommunity() && sel() !== META_AI}>
                  <button class="ib off"><img class="ic" src={ic("video-call", tk().fg)} /></button>
                  <button class="ib off"><img class="ic" src={ic("voice-call", tk().fg)} /></button>
                  <button class="ib" onClick={() => openChatSearch()}><img class="ic" src={ic("search", tk().fg)} /></button>
                </Show>
                <Show when={inCommunity()}>
                  <button class="comm-btn" onClick={() => openCommunity(selChat() ? selChat()!.parentGroup || "" : "")}>
                    <div class="av av28" style={{ background: photo(selChat() ? selChat()!.parentGroup || "" : "")[0] }}>
                      <Show when={!(selChat() && selChat()!.parentPic)}><img class="av-ic16" src={ic("communities", photo(selChat() ? selChat()!.parentGroup || "" : "")[1])} /></Show>
                      <Show when={!!(selChat() && selChat()!.parentPic)}><img class="av-img28" src={"file://" + (selChat() ? selChat()!.parentPic || "" : "")} /></Show>
                    </div>
                    <img class="ic20" src={ic("drop-down", tk().fg)} />
                  </button>
                  <button class="ib" onClick={() => openChatSearch()}><img class="ic" src={ic("search", tk().fg)} /></button>
                </Show>
                <Show when={isChannel(sel())}>
                  <button class="ib" onClick={() => toggleInfoMute()}><img class="ic" src={ic("muted", infoMuted() ? tk().fg : tk().muted)} /></button>
                </Show>
                <div class="mhost" ref={mbtn4}><button class="ib" onClick={() => openUnder(mref4, mbtn4)}><img class="ic" src={ic("menu", tk().fg)} /></button></div>
              </div>
            </div>
            <Show when={!!selChat() && !!selChat()!.pinnedMsg}>
              <div class="pinbar" onClick={() => revealPinned()}>
                <img class="ic20" src={ic("pin", tk().muted)} />
                <text class="pinbar-t">{pinnedLine()}</text>
              </div>
            </Show>
            <ScrollWatch ref={scrollWatchQ} onGlided={() => snapEnd()} onAtEnd={(y: boolean) => onAtEnd(y)} onNearTop={() => loadOlder()} onTapped={() => focusComposer()} />
            <Show when={!atBottom() || winBehind()}>
              <div class="down-wrap">
                <button class="down-fab" onClick={() => toBottom()}><img class="ic" src={ic("double-down", tk().muted)} /></button>
                <Show when={newBelow() > 0}><div class="down-badge"><text class="down-badge-t">{"" + newBelow()}</text></div></Show>
              </div>
            </Show>
            <VirtualList class="msgs" ref={msgList} each={rows()} key="id">
              {(r: Row) => (
                <div class="mline">
                  <Show when={r.day !== ""}>
                    <div class="day"><div class="day-pill"><text class="day-t">{r.day}</text></div></div>
                  </Show>
                  <Show when={!!r.unread}>
                    <div class="unread-sep"><div class="day-pill unread-pill"><text class="day-t unread-t">{r.unread || ""}</text></div></div>
                  </Show>
                  <Show when={isSystem(r.m)}>
                    <div class="sys"><div class="sys-pill"><text class="sys-t">{systemText(r.m)}</text></div></div>
                  </Show>
                  <Show when={!isSystem(r.m)}>
                  <div class="mrow" classList={{ me: r.m.fromMe, last: r.last, picking: msgSelecting() }}>
                    <Show when={msgSelecting()}>
                      <div class="msg-check"><div class="fwd-check" classList={{ on: pickedIsSet(r.m.id) }}><Show when={pickedIsSet(r.m.id)}><img class="ic16" src={ic("check", tk().onAccent)} /></Show></div></div>
                    </Show>
                    <div class="bw">
                      <div class="bline">
                        <Show when={!!r.stickers}>
                          <div class="st-run" classList={{ me: r.m.fromMe }} style={{ width: stRunW(r.stickers || []) + "px" }}>
                            <For each={r.stickers || []}>{(st: Msg) => (
                              <div class="st-item" onContextMenu={(e) => openMsgMenu(st, e.clientX, e.clientY)}>
                                <Show when={flashId() === st.id}><div class="flash-ov" /></Show>
                                <div class="media" style={{ width: boxW(st) + "px", height: boxH(st) + "px" }} onClick={() => openMedia(st)}>
                                  <Sticker source={picSrc(st)} boxSize={boxW(st)} placeholderIcon={ic("emoji", tk().muted)} />
                                  <div class="media-meta sticker" style={{ top: (boxH(st) - 24) + "px", left: (boxW(st) - (st.fromMe ? 70 : 50)) + "px" }}>
                                    <text class="media-meta-t">{clock(st.t)}</text>
                                    <img class="meta-tick" classList={{ "tick-off": !st.fromMe }} src={st.fromMe ? ic(tickIcon(st.ack), st.ack >= ACK.READ ? tk().read : "#FFFFFF") : ""} />
                                  </div>
                                </div>
                              </div>
                            )}</For>
                          </div>
                        </Show>
                        <Show when={!r.stickers}>
                        <div class="bubble" style={bubbleStyle(r.m)} onContextMenu={(e) => openMsgMenu(r.m, e.clientX, e.clientY)} classList={{ me: r.m.fromMe, tin: r.first && !r.m.fromMe, tout: r.first && r.m.fromMe, "b-rich": isRich(r.m), "b-pic": isVisual(r.m) && r.m.type !== "sticker", "b-sticker": r.m.type === "sticker", "b-doc": isDoc(r.m) }}>
                          <Show when={flashId() === r.m.id}><div class="flash-ov" /></Show>
                          <img class="tail tail-l" src={r.first && r.m.type !== "sticker" && !r.m.fromMe ? ic("tail-in", tk().bubbleIn) : ""} />
                          <img class="tail tail-r" src={r.first && r.m.type !== "sticker" && r.m.fromMe ? ic("tail-out", tk().bubbleOut) : ""} />
                          <div class="chev"><MsgChevron icon={ic("chevron-down", tk().muted)} shade={r.m.fromMe ? tk().bubbleOut : tk().bubbleIn} onOpen={(x: number, y: number) => openMsgMenu(r.m, x, y)} /></div>
                          <Show when={r.first && !r.m.fromMe && isGroup(r.m.remote)}>
                            <div class="who-row">
                              <div class="av av32" style={{ background: photo(r.m.author || "")[0] }}>
                                <Show when={!r.m.senderPic}><img class="av-ic16" src={ic("person", photo(r.m.author || "")[1])} /></Show>
                                <Show when={!!r.m.senderPic}><img class="av-img32" src={"file://" + (r.m.senderPic || "")} /></Show>
                              </div>
                              <div class="who-col">
                                <div class="who-line">
                                  <div class="who-click" onClick={() => openSender(r.m.author || "")}><text class="who" style={{ color: senderColor(r.m.author || "") }}>{whoName(r.m)}</text></div>
                                  <Show when={!!r.m.senderPhone}><text class="who-phone">{r.m.senderPhone || ""}</text></Show>
                                </div>
                                <Show when={!!r.m.senderRole}><text class="who-role">{r.m.senderRole || ""}</text></Show>
                              </div>
                            </div>
                          </Show>
                          <Show when={!!r.m.isForwarded && r.m.type !== "revoked"}>
                            <text class="fwd">{(r.m.forwardingScore || 0) >= 5 ? "Encaminhada com frequência" : "Encaminhada"}</text>
                          </Show>
                          <Show when={!!r.m.quotedMsg && r.m.type !== "revoked"}>
                            <div class="quote">
                              <div class="quote-bar" style={{ background: senderColor(r.m.quotedMsg ? r.m.quotedMsg.author || "" : "") }} />
                              <div class="quote-body">
                                <text class="quote-who" style={{ color: senderColor(r.m.quotedMsg ? r.m.quotedMsg.author || "" : "") }}>{quoteWho(r.m)}</text>
                                <text class="quote-t">{r.m.quotedMsg ? oneLine(typeLabel(r.m.quotedMsg.type || "chat", r.m.quotedMsg.body || "")) : ""}</text>
                              </div>
                            </div>
                          </Show>
                          <Show when={hasPreview(r.m) && !!r.m.linkThumb}>
                            <div class="lpb" onClick={() => openLink(r.m.matchedText || "")}>
                              <div class="lpb-pic" style={{ width: lpW(r.m) + "px", height: lpH(r.m) + "px" }}>
                                <img class="lpb-img" src={"file://" + (r.m.linkThumb || "")} />
                                <Show when={r.m.previewType === "VIDEO"}>
                                  <div class="media-play" style={{ left: (lpW(r.m) / 2 - 25) + "px", top: (lpH(r.m) / 2 - 25) + "px" }}><img class="ic" src={ic("play", "#FFFFFF")} /></div>
                                </Show>
                              </div>
                              <div class="lp-text">
                                <text class="lp-title">{r.m.title || ""}</text>
                                <Show when={!!r.m.description}><text class="lp-desc">{r.m.description || ""}</text></Show>
                                <text class="lp-site">{fullDomain(r.m.matchedText || "")}</text>
                              </div>
                            </div>
                          </Show>
                          <Show when={hasPreview(r.m) && !r.m.linkThumb}>
                            <div class="lp" onClick={() => openLink(r.m.matchedText || "")}>
                              <Show when={previewThumb(r.m) !== ""}><img class="lp-img" src={previewThumb(r.m)} /></Show>
                              <div class="lp-text">
                                <text class="lp-title">{r.m.title || ""}</text>
                                <Show when={!!r.m.description}><text class="lp-desc">{r.m.description || ""}</text></Show>
                                <text class="lp-site">{domain(r.m.matchedText || "")}</text>
                              </div>
                            </div>
                          </Show>
                          <Show when={isVisual(r.m)}>
                            <div class="media" style={{ width: boxW(r.m) + "px", height: boxH(r.m) + "px" }} onClick={() => openMedia(r.m)}>
                              <Show when={r.m.type === "sticker"}><Sticker source={picSrc(r.m)} boxSize={boxW(r.m)} placeholderIcon={ic("emoji", tk().muted)} /></Show>
                              <Show when={r.m.type !== "sticker" && isPreviewOnly(r.m)}><BlurImage source={picSrc(r.m)} boxWidth={boxW(r.m)} boxHeight={boxH(r.m)} /></Show>
                              <Show when={r.m.type !== "sticker" && !isPreviewOnly(r.m)}><img class="media-img" src={picSrc(r.m)} /></Show>
                              <Show when={r.m.type === "video"}>
                                <div class="media-play" style={{ left: (boxW(r.m) / 2 - 25) + "px", top: (boxH(r.m) / 2 - 25) + "px" }}>
                                  <img class="ic" src={fetching(r.m) ? ic("download", "#FFFFFF") : ic("play", "#FFFFFF")} />
                                </div>
                                <div class="media-dur" style={{ top: (boxH(r.m) - 24) + "px" }}>
                                  <img class="media-dur-ic" src={ic("videocam", "#FFFFFF")} />
                                  <text class="media-dur-t">{secs(r.m.mediaData ? r.m.mediaData.duration || 0 : 0)}</text>
                                </div>
                              </Show>
                              <Show when={r.m.type === "image" && mediaFile(r.m) === ""}>
                                <div class="media-play" style={{ left: (boxW(r.m) / 2 - 25) + "px", top: (boxH(r.m) / 2 - 25) + "px" }}>
                                  <img class="ic" src={ic("download", "#FFFFFF")} />
                                </div>
                              </Show>
                              <Show when={!r.m.caption}>
                                <div class="media-meta" classList={{ sticker: r.m.type === "sticker" }} style={{ top: (boxH(r.m) - 24) + "px", left: (boxW(r.m) - (r.m.fromMe ? 70 : 50)) + "px" }}>
                                  <text class="media-meta-t">{clock(r.m.t)}</text>
                                  <img class="meta-tick" classList={{ "tick-off": !(r.m.fromMe) }} src={r.m.fromMe ? ic(tickIcon(r.m.ack), r.m.ack >= ACK.READ ? tk().read : "#FFFFFF") : ""} />
                                </div>
                              </Show>
                            </div>
                          </Show>
                          <Show when={isDoc(r.m)}>
                            <div class="doc" style={{ width: Math.min(330, laneW() - 24) + "px" }} onClick={() => openMedia(r.m)}>
                              <div class="doc-badge" style={{ background: docColor(r.m) }}><text class="doc-badge-t">{ext(r.m).substring(0, 4)}</text></div>
                              <text class="doc-name">{r.m.mediaData ? r.m.mediaData.filename || "Documento" : "Documento"}</text>
                              <div class="doc-dl">
                                <Show when={mediaFile(r.m) === ""}><img class="ic" src={ic(fetching(r.m) ? "pending" : "download", tk().muted)} /></Show>
                              </div>
                            </div>
                          </Show>
                          <Show when={isDoc(r.m)}>
                            <div class="doc-foot">
                              <text class="doc-info">{docInfo(r.m)}</text>
                              <Show when={!r.m.caption}><text class="stamp">{clock(r.m.t)}</text></Show>
                              <img class="meta-tick" classList={{ "tick-off": !(!r.m.caption && r.m.fromMe) }} src={!r.m.caption && r.m.fromMe ? ic(tickIcon(r.m.ack), tickColor(r.m.ack)) : ""} />
                            </div>
                          </Show>
                          <Show when={r.m.type === "location"}>
                            <div class="loc" onClick={() => openMap(r.m)}>
                              <div class="loc-map">
                                <Show when={locThumb(r.m) !== ""}><img class="loc-img" src={locThumb(r.m)} /></Show>
                                <Show when={locThumb(r.m) === ""}>
                                  <LocationMap lat={r.m.lat || 0} lng={r.m.lng || 0} pinIcon={ic("location-pin", "#FB5061")} cacheDir={look.cacheDir + "/tiles"} providers={look.mapProviders}
                                    live={!!r.m.isLive} dark={isDark()} onClicked={() => openMap(r.m)} />
                                </Show>
                              </div>
                              <text class="loc-t">{locTitle(r.m)}</text>
                              <Show when={locSub(r.m) !== ""}><text class="loc-s">{locSub(r.m)}</text></Show>
                            </div>
                          </Show>
                          <Show when={r.m.type === "vcard" || r.m.type === "multi_vcard"}>
                            <div class="vc">
                              <div class="vc-av" style={{ background: photo(vcardName(r.m))[0] }}><img class="av-ic" src={ic("person", photo(vcardName(r.m))[1])} /></div>
                              <text class="vc-name">{vcardName(r.m)}</text>
                            </div>
                          </Show>
                          <Show when={r.m.type === "vcard" || r.m.type === "multi_vcard"}>
                            <div class="vc-actions"><button class="vc-btn" onClick={() => chatWith(r.m)}><text class="vc-btn-t">Conversar</text></button></div>
                          </Show>
                          <Show when={r.m.type === "poll_creation"}>
                            <div class="poll">
                              <text class="poll-q">{r.m.pollName || ""}</text>
                              <div class="poll-hint"><img class="poll-hint-ic" src={ic("poll", tk().muted)} /><text class="poll-hint-t">{pollHint(r.m)}</text></div>
                            </div>
                          </Show>
                          <Show when={r.m.type === "poll_creation"}>
                            <For each={r.m.pollOptions || []}>
                              {(o: any) => (
                                <div class="poll-opt">
                                  <div class="poll-dot" />
                                  <text class="poll-name">{o.name}</text>
                                </div>
                              )}
                            </For>
                          </Show>
                          <Show when={isAudio(r.m)}>
                            <div class="audio-box" style={{ width: audioW() + "px" }}><AudioMessage laneWidth={audioW()} source={mediaFile(r.m)} waveform={r.m.mediaData ? r.m.mediaData.waveform || "" : ""} duration={r.m.mediaData ? r.m.mediaData.duration || 0 : 0}
                              fromMe={r.m.fromMe} ptt={r.m.type === "ptt"} fetching={fetching(r.m)} listened={r.m.fromMe ? r.m.ack >= ACK.PLAYED : false}
                              avatarBg={photo(audioAvatar(r.m))[0]} avatarIcon={ic("person", photo(audioAvatar(r.m))[1])} avatarSrc={(r.m as any).senderPic || ""}
                              badgeIcon={ic(r.m.type === "ptt" ? "mic-filled" : "headphones", micColor(r.m))}
                              playIcon={ic("play", tk().fg)} pauseIcon={ic("pause", tk().fg)}
                              barColor={tk().qBar} barDoneColor={tk().qBarDone} dotColor={tk().qRead} badgeColor={tk().qRead} textColor={tk().qText} pillColor={tk().qPill}
                              active={nowPlaying() === r.m.id || nowPlaying() === ""} autoPlay={autoPlayId() === r.m.id} defaultRate={audioRate()} onRateCycled={(rt: number) => setRate(rt)} onDownload={() => download(r.m)} onPlayed={() => onPlayed(r.m)} onStarted={() => setNowPlaying(r.m.id)} onFinished={() => onAudioFinished(r.m)} /></div>
                          </Show>
                          <Show when={!((isVisual(r.m) || isDoc(r.m)) && !r.m.caption)}>
                          <div class="content">
                            <Show when={!isAudio(r.m) && !isRich(r.m)}>
                              <text class="body ghost">{ghost(bodyOf(r.m)) + metaRoom(r.m)}</text>
                              <div class="ovl"><MsgText fontSize={14 * zoom()} lineHeightPx={20 * zoom()} text={bodyOf(r.m)} tail={metaRoom(r.m)} textColor={r.m.type === "revoked" ? tk().qText : tk().fg} linkColor={tk().link}
                                deleted={r.m.type === "revoked"} onOpenLink={(u: string) => openLink(u)} /></div>
                            </Show>
                            <div class="meta" classList={{ "audio-me": isAudio(r.m) }}>
                              <Show when={!!r.m.isEdited && r.m.type !== "revoked"}><text class="stamp">Editada </text></Show>
                              <text class="stamp">{clock(r.m.t)}</text>
                              <img class="meta-tick" classList={{ "tick-off": !(r.m.fromMe && r.m.type !== "revoked") }} src={r.m.fromMe && r.m.type !== "revoked" ? ic(tickIcon(r.m.ack), tickColor(r.m.ack)) : ""} />
                            </div>
                          </div>
                          </Show>
                          <Show when={!!r.m.footer}><text class="msg-footer">{r.m.footer}</text></Show>
                          <Show when={!!r.m.buttons && r.m.buttons!.length > 0}>
                            <div class="msg-btns">
                              <For each={msgButtons(r.m)}>{(b: any) => (
                                <div class="msg-btn" classList={{ "msg-row": !!b.row }} onClick={() => pressButton(r.m, b)}>
                                  <img class="msg-btn-ic" src={ic(btnIcon(b.kind), tk().link)} />
                                  <text class="msg-btn-t">{b.text}</text>
                                </div>
                              )}</For>
                            </div>
                          </Show>
                        </div>
                        </Show>
                        <Show when={!r.m.fromMe && (isVisual(r.m) || isDoc(r.m))}>
                          <button class="fwd-quick" onClick={() => { setMenuMsg(r.m); forwardMsg(); }}><img class="ic20" src={ic("forward", tk().muted)} /></button>
                        </Show>
                      </div>
                      <Show when={reactions(r.m) !== ""}>
                        <div class="reacts"><text class="reacts-t">{reactions(r.m)}</text></div>
                      </Show>
                      <Show when={channelReacts(r.m) !== "" || (r.m.forwardsCount || 0) > 0}>
                        <div class="ch-row">
                          <Show when={channelReacts(r.m) !== ""}><div class="ch-pill"><text class="ch-pill-t">{channelReacts(r.m)}</text></div></Show>
                          <Show when={(r.m.forwardsCount || 0) > 0}><div class="ch-pill"><img class="ic20" src={ic("forward", tk().muted)} /><text class="ch-pill-t">{"" + (r.m.forwardsCount || 0)}</text></div></Show>
                        </div>
                      </Show>
                    </div>
                    <Show when={msgSelecting()}><div class="sel-overlay" onClick={() => toggleMsgPick(r.m.id)} /></Show>
                  </div>
                  </Show>
                </div>
              )}
            </VirtualList>
            <Show when={attachOpen() || exprOpen()}>
              <div class="backdrop" onClick={() => { setAttachOpen(false); setExprOpen(false); }} />
            </Show>
            <Show when={attachOpen()}>
              <div class="attach-menu">
                <button class="attach-item" onClick={() => pick("document")}><div class="attach-ic" style={{ background: "#7F66FF" }}><img class="ic20" src={ic("doc-file", "#FFFFFF")} /></div><text class="attach-t">Documento</text></button>
                <button class="attach-item" onClick={() => pick("media")}><div class="attach-ic" style={{ background: "#007BFC" }}><img class="ic20" src={ic("photo-library", "#FFFFFF")} /></div><text class="attach-t">Fotos e vídeos</text></button>
                <button class="attach-item" onClick={() => pick("document")}><div class="attach-ic" style={{ background: "#FA6533" }}><img class="ic20" src={ic("headphones", "#FFFFFF")} /></div><text class="attach-t">Áudio</text></button>
              </div>
            </Show>
            <Show when={exprOpen()}>
              <div class="expr-layer">
                <EmojiPanel emojiOnly={isSms(sel())} onlyLabel="Emoji" store={storeList()} onStorePick={(id: string, name: string) => askStorePack(id, name)} packs={packList()} stickers={stickerList().filter((it: any) => it.src !== "")} onEmoji={(e: string) => pickEmoji(e)} onSticker={(id: string) => pickSticker(id)} />
              </div>
            </Show>
            <Show when={replyTo() !== null || editing() !== null}>
              <div class="cbar">
                <div class="cbar-quote">
                  <div class="quote-bar" style={{ background: editing() !== null ? tk().accent : senderColor(replyTo() ? replyTo().author || "" : "") }} />
                  <div class="quote-body">
                    <text class="quote-who" style={{ color: editing() !== null ? tk().accent : senderColor(replyTo() ? replyTo().author || "" : "") }}>{editing() !== null ? "Editar mensagem" : (replyTo() ? replyWho(replyTo()) : "")}</text>
                    <text class="quote-t">{editing() !== null ? oneLine(editing().body || "") : (replyTo() ? oneLine(msgPreview(replyTo())) : "")}</text>
                  </div>
                </div>
                <button class="ib" onClick={() => cancelCompose()}><img class="ic" src={ic("close", tk().muted)} /></button>
              </div>
            </Show>
            <Show when={!isChannel(sel()) && readOnlyNote() !== "" && !(inCommunity() && selChat()!.isAnnounceGrpRestrict)}>
              <div class="ro-note"><text class="ro-note-t">{readOnlyNote()}</text></div>
            </Show>
            <Show when={!isChannel(sel()) && inCommunity() && !!selChat()!.isAnnounceGrpRestrict}>
              <div class="ro-note">
                <text class="ro-note-t">Somente </text><text class="ro-note-t ro-accent">admins da comunidade</text><text class="ro-note-t"> podem enviar mensagens</text>
              </div>
            </Show>
            <Show when={!isChannel(sel()) && readOnlyNote() === ""}>
            <div class="footer">
              <div class="composer">
                <Show when={!isRec()}>
                  <button class="ib" classList={{ on: attachOpen() }} onClick={() => toggleAttach()}><img class="ic" src={ic(attachOpen() ? "close" : "attach", tk().fg)} /></button>
                  <button class="ib emoji-btn" classList={{ on: exprOpen() }} onClick={() => toggleExpr()}><img class="ic" src={ic(exprOpen() ? "close" : "emoji", tk().fg)} /></button>
                  <input class="input" ref={composerInput} placeholder="Digite uma mensagem" value={draft()} onInput={(e) => setDraft(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") send(); if (e.key === "v" && e.ctrlKey) paste(); }} />
                </Show>
                <Show when={!isRec() && draft() === "" && !isSms(sel())}>
                  <button class="ib send-btn" onClick={() => startRec()}><img class="ic" src={ic("mic", tk().fg)} /></button>
                </Show>
                <Show when={!isRec() && draft() !== ""}>
                  <button class="ib send-btn primary" onClick={() => send()}><img class="ic" src={ic("send", tk().onAccent)} /></button>
                </Show>
                <Show when={isRec()}>
                  <button class="ib" onClick={() => stopRec(false)}><img class="ic" src={ic("delete", tk().muted)} /></button>
                  <div class="rec">
                    <div class="rec-dot" />
                    <text class="rec-t">{secs(recElapsed())}</text>
                  </div>
                  <div class="rec-wave"><LevelBars levels={recLevels()} barColor={tk().muted} /></div>
                  <button class="ib send-btn primary" onClick={() => stopRec(true)}><img class="ic" src={ic("send", tk().onAccent)} /></button>
                </Show>
              </div>
            </div>
            </Show>
            <Show when={staged() !== null}>
              <div class="stage">
                <div class="stage-head">
                  <button class="ib" onClick={() => cancelStaged()}><img class="ic" src={ic("close", tk().fg)} /></button>
                  <text class="stage-name">{staged() ? staged().name : ""}</text>
                </div>
                <div class="stage-body">
                  <Show when={staged() !== null && staged().kind === "media" && isPicture(staged().path)}>
                    <ImageEditor source={staged() ? "file://" + (staged().base || staged().path) : ""} outDir={look.cacheDir}
                      fg={tk().fg} muted={tk().muted} accent={tk().accent}
                      iconCrop={ic("crop-rotate", tk().fg)} iconRotate={ic("rotate-cw", tk().fg)} iconDraw={ic("draw", tk().fg)} iconText={ic("title", tk().fg)}
                      iconRect={ic("square", tk().fg)} iconPixelate={ic("pixelate", tk().fg)} iconEmoji={ic("emoji", tk().fg)} iconUndo={ic("undo", tk().fg)}
                      iconRedo={ic("redo", tk().fg)} iconDownload={ic("download", tk().fg)} iconDelete={ic("delete", "#FFFFFF")}
                      onEdited={(p: string) => stagedEdited(p)} onNotice={(t: string) => setSyncing(t)} />
                  </Show>
                  <Show when={staged() !== null && !(staged().kind === "media" && isPicture(staged().path))}>
                    <div class="stage-file">
                      <img class="stage-file-ic" src={ic("doc-file", tk().muted)} />
                      <text class="stage-file-t">{staged() ? staged().name : ""}</text>
                    </div>
                  </Show>
                </div>
                <div class="stage-cap">
                  <div class="stage-composer">
                    <input class="input" ref={captionInput} placeholder="Digite uma mensagem" value={caption()} onInput={(e) => setCaption(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") sendStaged(); }} />
                  </div>
                </div>
                <div class="stage-foot">
                  <div class="stage-strip">
                    <For each={stagedList()}>{(st: any, i: () => number) => (
                      <div class="stage-thumb" classList={{ on: i() === stageAt() }} onClick={() => showStaged(i())}>
                        <Show when={st.kind === "media" && isPicture(st.path)}>
                          <img class="stage-thumb-img" src={"file://" + (st.out || st.path)} />
                        </Show>
                        <Show when={!(st.kind === "media" && isPicture(st.path))}>
                          <img class="stage-thumb-ic" src={ic("doc-file", tk().muted)} />
                        </Show>
                        <Show when={i() === stageAt() && stagedList().length > 1}>
                          <div class="stage-thumb-x" onClick={() => dropStaged(i())}><img class="stage-thumb-xi" src={ic("close", "#FFFFFF")} /></div>
                        </Show>
                      </div>
                    )}</For>
                    <div class="stage-more" onClick={() => stageMore()}><img class="ic" src={ic("plus", tk().fg)} /></div>
                  </div>
                  <button class="stage-send" onClick={() => sendStaged()}><img class="ic" src={ic("send", tk().onAccent)} /></button>
                </div>
              </div>
            </Show>
          </Show>
        </div>
        <Show when={infoOpen() && sel() !== ""}>
          <div class="backdrop backdrop-info" onClick={() => closeInfo()} />
        </Show>
        <Show when={chatSearchOpen() && sel() !== ""}>
          <div class="info">
            <div class="info-head">
              <button class="ib" onClick={() => closeChatSearch()}><img class="ic" src={ic("close", tk().fg)} /></button>
              <text class="info-title">Pesquisar mensagens</text>
            </div>
            <div class="search">
              <div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" ref={chatSearchInput} placeholder="Pesquisar…" value={chatQuery()} onInput={(e) => chatQueryTyped(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Escape") closeChatSearch(); }} />
              </div>
            </div>
            <div class="info-scroll">
              <Show when={chatQuery().trim() !== "" && chatHits().length === 0}>
                <text class="hit-none">Nenhuma mensagem encontrada</text>
              </Show>
              <For each={chatHits()}>{(m: any) => (
                <div class="hit" onClick={() => goToMsg(m)}>
                  <text class="hit-when">{dayLabel(m.t) + " · " + clock(m.t)}</text>
                  <text class="hit-text">{hitWho(m) + ": " + oneLine(msgPreview(m))}</text>
                </div>
              )}</For>
            </div>
          </div>
        </Show>
        <Show when={personId() !== ""}>
          <div class="backdrop backdrop-info" onClick={() => closePerson()} />
        </Show>
        <Show when={personId() !== ""}>
          <div class="info" classList={{ "info-out": personClosing() }}>
            <div class="info-head">
              <button class="ib" onClick={() => closePerson()}><img class="ic" src={ic("close", tk().fg)} /></button>
              <text class="info-title">Dados do contato</text>
            </div>
            <div class="info-scroll">
              <div class="info-card info-top">
                <div class="info-av" style={{ background: photo(personId())[0] }} onClick={() => viewPic(personPic() !== "" ? personPic() : personThumb(), personName())}>
                  <Show when={personThumb() === "" && personPic() === ""}><img class="info-av-ic" src={ic("person", photo(personId())[1])} /></Show>
                  <Show when={personThumb() !== "" || personPic() !== ""}><img class="info-av-img" src={"file://" + (personPic() !== "" ? personPic() : personThumb())} /></Show>
                </div>
                <text class="info-name">{personName()}</text>
                <Show when={!!personK() && !!personK().phoneNumber}><text class="info-sub">{formatPhoneUI(personK() ? personK().phoneNumber : "")}</text></Show>
                <Show when={!!personK() && !!personK().pushname && personK().pushname !== personName()}><text class="info-sub">{"~" + (personK() ? personK().pushname : "")}</text></Show>
              </div>
              <Show when={!!personK() && !!personK().status}>
                <div class="info-card">
                  <text class="info-label">Recado</text>
                  <text class="info-text">{personK() ? personK().status : ""}</text>
                </div>
              </Show>
              <Show when={personId() !== sel()}>
                <div class="info-card">
                  <div class="info-row" onClick={() => personChat()}>
                    <img class="ic" src={ic("chats", tk().muted)} />
                    <text class="info-row-t">Conversar</text>
                  </div>
                </div>
              </Show>
            </div>
          </div>
        </Show>
        <Show when={infoOpen() && sel() !== ""}>
          <div class="info" classList={{ "info-out": infoClosing() }}>
            <div class="info-head">
              <button class="ib" onClick={() => closeInfo()}><img class="ic" src={ic("close", tk().fg)} /></button>
              <text class="info-title">{isGroup(sel()) ? "Dados do grupo" : "Dados do contato"}</text>
            </div>
            <div class="info-scroll">
              <div class="info-card info-top">
                <div class="info-av" style={{ background: photo(sel())[0] }} onClick={() => viewPic(infoPic() !== "" ? infoPic() : infoPicSrc().replace("file://", ""), selChat() ? title(selChat()!) : shortJid(sel()))}>
                  <Show when={infoPicSrc() === ""}><img class="info-av-ic" src={ic(isGroup(sel()) ? "group" : "person", photo(sel())[1])} /></Show>
                  <Show when={infoPicSrc() !== ""}><img class="info-av-img" src={infoPicSrc()} /></Show>
                </div>
                <text class="info-name">{selChat() ? title(selChat()!) : shortJid(sel())}</text>
                <Show when={!isGroup(sel()) && infoPhone() !== "" && infoPhone() !== (selChat() ? title(selChat()!) : "")}><text class="info-sub">{infoPhone()}</text></Show>
                <Show when={!isGroup(sel()) && !!infoContact() && !!infoContact().pushname}><text class="info-sub">{"~" + (infoContact() ? infoContact().pushname : "")}</text></Show>
                <Show when={isGroup(sel())}><text class="info-sub">{"Grupo · " + memberCount() + (memberCount() === 1 ? " membro" : " membros")}</text></Show>
              </div>
              <Show when={!isGroup(sel()) && !!infoContact() && !!infoContact().status}>
                <div class="info-card">
                  <text class="info-label">Recado</text>
                  <text class="info-text">{infoContact() ? infoContact().status : ""}</text>
                </div>
              </Show>
              <Show when={isGroup(sel()) && !!infoGroup() && !!infoGroup().desc}>
                <div class="info-card">
                  <text class="info-label">Descrição do grupo</text>
                  <text class="info-text">{infoGroup() ? infoGroup().desc : ""}</text>
                </div>
              </Show>
              <div class="info-card">
                <div class="info-row" onClick={() => toggleInfoMute()}>
                  <img class="ic" src={ic("muted", tk().muted)} />
                  <text class="info-row-t">Silenciar notificações</text>
                  <div class="toggle" classList={{ on: infoMuted() }}><div class="toggle-knob" /></div>
                </div>
                <div class="info-row">
                  <img class="ic" src={ic("pending", tk().muted)} />
                  <div class="info-row-col">
                    <text class="info-col-t">Mensagens temporárias</text>
                    <text class="info-row-s">{ephemeralLabel()}</text>
                  </div>
                </div>
              </div>
              <Show when={isGroup(sel()) && !!infoGroup()}>
                <div class="info-card">
                  <text class="info-label">{memberCount() + (memberCount() === 1 ? " membro" : " membros")}</text>
                  <For each={infoGroup() ? infoGroup().participants : []}>
                    {(p: any) => (
                      <div class="member" onClick={() => p.isMe ? undefined : openParticipant(p.id)}>
                        <div class="av av40" style={{ background: photo(p.id)[0] }}><img class="av-ic" src={ic("person", photo(p.id)[1])} /></div>
                        <text class="member-name">{p.name}</text>
                        <Show when={p.isAdmin}><div class="admin"><text class="admin-t">Admin do grupo</text></div></Show>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
              <div class="info-card">
                <div class="info-row danger" onClick={() => deleteFromInfo()}>
                  <img class="ic" src={ic("revoked", "#FB5061")} />
                  <text class="info-row-t danger-t">Apagar conversa</text>
                </div>
              </div>
            </div>
          </div>
        </Show>
      </Show>
      <Menu ref={mref1}>
        <For each={COUNTRIES}>{(c) => <MenuItem onClick={() => setCountry(c)}>{c.flag + "  " + c.name + "  +" + c.dial}</MenuItem>}</For>
      </Menu>
      <Menu ref={mref2}>
        <MenuItem onClick={() => openSide("newGroup")}>Novo grupo</MenuItem>
        <MenuItem onClick={() => openSide("starred")}>Mensagens favoritas</MenuItem>
        <MenuItem onClick={() => startSelect()}>Selecionar conversas</MenuItem>
        <MenuItem onClick={() => markAllRead()}>Marcar todas como lidas</MenuItem>
        <MenuSeparator />
        <MenuItem onClick={() => lockMenu()}>{lockOn() ? "Bloquear app" : "Bloqueio do app"}</MenuItem>
        <Show when={lockOn()}><MenuItem onClick={() => setLockDialog("disable")}>Desativar bloqueio do app</MenuItem></Show>
        <MenuItem onClick={() => logout()}>Desconectar</MenuItem>
      </Menu>
      <Menu ref={mref3}>
        <For each={FILTERS.slice(chipsShown())}>{(f) => <MenuItem onClick={() => setTab(f.id)}>{f.label + (chipCount(f.id) > 0 ? "  " + chipCount(f.id) : "")}</MenuItem>}</For>
      </Menu>
      <Menu ref={mref4}>
        <MenuItem onClick={() => openInfo()}>{isGroup(sel()) ? "Dados do grupo" : "Dados do contato"}</MenuItem>
        <Show when={!!selChat() && muted(selChat()!)}><MenuItem onClick={() => cv("sendConversationMute", { expiration: 0 })}>Reativar notificações</MenuItem></Show>
        <Show when={!!selChat() && !muted(selChat()!)}><MenuItem onClick={() => cv("sendConversationMute", { expiration: Math.floor(Date.now() / 1000) + 8 * 3600 })}>Silenciar por 8 horas</MenuItem></Show>
        <Show when={!!selChat() && !muted(selChat()!)}><MenuItem onClick={() => cv("sendConversationMute", { expiration: Math.floor(Date.now() / 1000) + 7 * 86400 })}>Silenciar por 1 semana</MenuItem></Show>
        <Show when={!!selChat() && !muted(selChat()!)}><MenuItem onClick={() => cv("sendConversationMute", { expiration: -1 })}>Silenciar sempre</MenuItem></Show>
        <MenuItem onClick={() => cv("setPin", { pin: !(selChat() && selChat()!.pin > 0) })}>{selChat() && selChat()!.pin > 0 ? "Desafixar conversa" : "Fixar conversa"}</MenuItem>
        <MenuItem onClick={() => cv("setArchive", { archive: !(selChat() && selChat()!.archive) })}>{selChat() && selChat()!.archive ? "Desarquivar conversa" : "Arquivar conversa"}</MenuItem>
        <MenuItem onClick={() => setSel("")}>Fechar conversa</MenuItem>
        <MenuSeparator />
        <MenuItem onClick={() => cv("sendClear", { keepStarred: true })}>Limpar conversa</MenuItem>
        <MenuItem onClick={() => { setMenuChat(selChat() || null); deleteChat(); }}>Apagar conversa</MenuItem>
      </Menu>
      <Menu ref={mref5}>
        <MenuItem onClick={() => setMpSort("new")}>{(mpSort() === "new" ? "✓  " : "     ") + "Mais recentes"}</MenuItem>
        <MenuItem onClick={() => setMpSort("old")}>{(mpSort() === "old" ? "✓  " : "     ") + "Mais antigas"}</MenuItem>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpSort("size")}>{(mpSort() === "size" ? "✓  " : "     ") + "Maior tamanho"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpSort("name")}>{(mpSort() === "name" ? "✓  " : "     ") + "Nome (A–Z)"}</MenuItem></Show>
      </Menu>
      <Menu ref={mref6}>
        <MenuItem onClick={() => setMpFilter("all")}>{(mpFilter() === "all" ? "✓  " : "     ") + "Tudo"}</MenuItem>
        <Show when={mediaTab() === "media"}><MenuItem onClick={() => setMpFilter("image")}>{(mpFilter() === "image" ? "✓  " : "     ") + "Fotos"}</MenuItem></Show>
        <Show when={mediaTab() === "media"}><MenuItem onClick={() => setMpFilter("video")}>{(mpFilter() === "video" ? "✓  " : "     ") + "Vídeos"}</MenuItem></Show>
        <Show when={mediaTab() === "media"}><MenuItem onClick={() => setMpFilter("gif")}>{(mpFilter() === "gif" ? "✓  " : "     ") + "GIFs"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpFilter("pdf")}>{(mpFilter() === "pdf" ? "✓  " : "     ") + "PDF"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpFilter("text")}>{(mpFilter() === "text" ? "✓  " : "     ") + "Textos"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpFilter("sheet")}>{(mpFilter() === "sheet" ? "✓  " : "     ") + "Planilhas"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpFilter("slides")}>{(mpFilter() === "slides" ? "✓  " : "     ") + "Apresentações"}</MenuItem></Show>
        <Show when={mediaTab() === "docs"}><MenuItem onClick={() => setMpFilter("other")}>{(mpFilter() === "other" ? "✓  " : "     ") + "Outros"}</MenuItem></Show>
      </Menu>
      <Zoom zoom={zoom()} onZoomTo={(z: number) => zoomTo(z)} onPaste={() => paste()} />
      <MessageMenu ref={msgMenuQ} items={msgItems()} mine={myReaction()} plusIcon={ic("plus", tk().fg)}
        onAction={(id: string) => msgAction(id)} onReact={(e: string) => react(e)} />
      <Menu ref={reactMenu}>
        <MenuItem onClick={() => react("👍")}>👍</MenuItem>
        <MenuItem onClick={() => react("❤️")}>❤️</MenuItem>
        <MenuItem onClick={() => react("😂")}>😂</MenuItem>
        <MenuItem onClick={() => react("😮")}>😮</MenuItem>
        <MenuItem onClick={() => react("😢")}>😢</MenuItem>
        <MenuItem onClick={() => react("🙏")}>🙏</MenuItem>
        <MenuSeparator />
        <MenuItem onClick={() => react("")}>Remover reação</MenuItem>
      </Menu>
      <Menu ref={statusMenu}>
        <MenuItem onClick={() => { const st = menuStatus(); if (st) watchStatus(st); }}>Ver status</MenuItem>
        <MenuItem onClick={() => { const st = menuStatus(); if (st) setStatusMute(st, !st.muted); }}>{menuStatus() && menuStatus().muted ? "Reativar som" : "Silenciar"}</MenuItem>
      </Menu>
      <Menu ref={chatMenu}>
        <MenuItem onClick={() => chatAct("setArchive", { archive: !(mc() && mc().archive) })}>{mc() && mc().archive ? "Desarquivar conversa" : "Arquivar conversa"}</MenuItem>
        <Show when={!!mc() && muted(mc())}><MenuItem onClick={() => chatAct("sendConversationMute", { expiration: 0 })}>Reativar notificações</MenuItem></Show>
        <Show when={!!mc() && !muted(mc())}><MenuItem onClick={() => openMute()}>Silenciar notificações</MenuItem></Show>
        <MenuItem onClick={() => chatAct("setPin", { pin: !(mc() && mc().pin > 0) })}>{mc() && mc().pin > 0 ? "Desafixar conversa" : "Fixar conversa"}</MenuItem>
        <MenuItem onClick={() => markUnreadOrRead()}>{mc() && (mc().unreadCount > 0 || mc().markedUnread) ? "Marcar como lida" : "Marcar como não lida"}</MenuItem>
        <MenuSeparator />
        <MenuItem onClick={() => chatAct("sendClear", { keepStarred: true })}>Limpar conversa</MenuItem>
        <MenuItem onClick={() => deleteChat()}>Apagar conversa</MenuItem>
      </Menu>
      <Show when={story() !== null}>
        <div class="story-layer">
          <Story items={storyItems()} startAt={storyStart} name={story() ? story().name : ""} mine={!!(story() && story().isMe)}
            avatar={story() && story().profilePicThumb ? "file://" + story().profilePicThumb : ""}
            closeIcon={ic("close", "#FFFFFF")} backIcon={ic("back", "#FFFFFF")} sendIcon={ic("send", "#FFFFFF")}
            saveIcon={ic("download", "#FFFFFF")} shareIcon={ic("forward", "#FFFFFF")} notice={storyNotice()}
            authorMuted={!!(story() && story().muted)} menuIcon={ic("menu", "#FFFFFF")} onToggleMute={() => storyMute()}
            onSave={(i: number) => storySave(i)} onShare={(i: number) => storyShare(i)}
            onShown={(i: number) => storyShown(i)} onClosed={() => storyClose()} onFinished={() => storyAuthor(1)} onPrevious={() => storyAuthor(-1)} onReply={(i: number, t: string) => storyReply(i, t)} />
        </div>
      </Show>
      <Show when={mediaOpen()}>
        <div class="mp">
          <div class="mp-head">
            <div class="mp-titles">
              <text class="mp-title">Mídia</text>
              <text class="mp-sub">Mídias de todas as conversas</text>
            </div>
            <div class="mp-tabs">
              <button class="mp-tab" classList={{ on: mediaTab() === "media" }} onClick={() => mpTab("media")}><text class="mp-tab-t">Mídias</text></button>
              <button class="mp-tab" classList={{ on: mediaTab() === "docs" }} onClick={() => mpTab("docs")}><text class="mp-tab-t">Documentos</text></button>
              <button class="mp-tab" classList={{ on: mediaTab() === "links" }} onClick={() => mpTab("links")}><text class="mp-tab-t">Links</text></button>
            </div>
            <div class="grow" />
            <Show when={mpSearching()}>
              <div class="mp-search"><div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Pesquisar" value={mpQuery()} onInput={(e) => setMpQuery(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Escape") { setMpQuery(""); setMpSearching(false); } }} />
              </div></div>
            </Show>
            <button class="ib" classList={{ on: mpSearching() }} onClick={() => { if (mpSearching()) setMpQuery(""); setMpSearching(!mpSearching()); }}><img class="ic" src={ic("search", tk().fg)} /></button>
            <div class="mhost" ref={mbtn5}><button class="ib" onClick={() => openUnder(mref5, mbtn5)}><img class="ic" src={ic("sort", mpSort() !== "new" ? tk().accent : tk().fg)} /></button></div>
            <Show when={mediaTab() !== "links"}>
              <div class="mhost" ref={mbtn6}><button class="ib" onClick={() => openUnder(mref6, mbtn6)}><img class="ic" src={ic("filter-list", mpFilter() !== "all" ? tk().accent : tk().fg)} /></button></div>
            </Show>
            <button class="ib" onClick={() => setMediaOpen(false)}><img class="ic" src={ic("close", tk().fg)} /></button>
          </div>
          <Show when={mpFilter() !== "all" || mpQuery() !== ""}>
            <div class="mp-chips">
              <Show when={mpFilter() !== "all"}><button class="chip on" onClick={() => setMpFilter("all")}><text class="chip-t">{mpFilterLabel()}</text><img class="ic16" src={ic("close", tk().fg)} /></button></Show>
              <Show when={mpQuery() !== ""}><text class="side-sub">{"Resultados para “" + mpQuery() + "”"}</text></Show>
            </div>
          </Show>
          <div class="mp-body">
            <Show when={mediaTab() === "media"}>
              <Show when={mpEmpty()}><text class="empty-note">{mpQuery() !== "" || mpFilter() !== "all" ? "Nada encontrado" : "Nenhuma foto ou vídeo"}</text></Show>
              <For each={mediaDays()}>{(g: any) => (
                <div class="mp-day">
                  <text class="mp-day-t">{g.label}</text>
                  <Show when={g.sub !== "" && g.label !== g.sub}><text class="mp-day-s">{g.sub}</text></Show>
                  <div class="mp-grid">
                    <For each={g.items}>{(m: any) => (
                      <div class="mp-tile" onClick={() => openMedia(m)}>
                        <Show when={mediaThumb(m) !== ""}><img class="mp-img" src={mediaThumb(m)} /></Show>
                        <Show when={m.type === "video"}><div class="mp-badge"><img class="ic20" src={ic("videocam", "#FFFFFF")} /><text class="mp-badge-t">{secs(m.mediaData ? m.mediaData.duration || 0 : 0)}</text></div></Show>
                        <text class="mp-who">{fromWho(m)}</text>
                      </div>
                    )}</For>
                  </div>
                </div>
              )}</For>
            </Show>
            <Show when={mediaTab() === "docs"}>
              <Show when={mpEmpty()}><text class="empty-note">{mpQuery() !== "" || mpFilter() !== "all" ? "Nada encontrado" : "Nenhum documento"}</text></Show>
              <For each={docDays()}>{(g: any) => (
                <div class="mp-day">
                  <text class="mp-day-t">{g.label}</text>
                  <Show when={g.sub !== "" && g.label !== g.sub}><text class="mp-day-s">{g.sub}</text></Show>
                  <For each={g.items}>{(m: any) => (
                    <div class="mp-row" onClick={() => openMedia(m)}>
                      <img class="mp-row-ic" src={ic("doc-file", tk().muted)} />
                      <div class="side-text">
                        <text class="side-name">{m.mediaData && m.mediaData.filename ? m.mediaData.filename : (m.body || "Documento")}</text>
                        <text class="side-sub">{fromWho(m) + (m.mediaData && m.mediaData.size ? "  •  " + kb(m.mediaData.size) : "")}</text>
                      </div>
                      <text class="cell-time">{clock(m.t)}</text>
                    </div>
                  )}</For>
                </div>
              )}</For>
            </Show>
            <Show when={mediaTab() === "links"}>
              <Show when={mpEmpty()}><text class="empty-note">{mpQuery() !== "" ? "Nada encontrado" : "Nenhum link"}</text></Show>
              <For each={linkDays()}>{(g: any) => (
                <div class="mp-day">
                  <text class="mp-day-t">{g.label}</text>
                  <Show when={g.sub !== "" && g.label !== g.sub}><text class="mp-day-s">{g.sub}</text></Show>
                  <For each={g.items}>{(m: any) => (
                    <div class="mp-row" onClick={() => openLink(firstLink(m))}>
                      <img class="mp-row-ic" src={ic("open", tk().muted)} />
                      <div class="side-text">
                        <text class="side-name mp-link">{firstLink(m)}</text>
                        <text class="side-sub">{fromWho(m) + (m.chatName && !m.fromMe ? "" : "")}</text>
                      </div>
                      <text class="cell-time">{clock(m.t)}</text>
                    </div>
                  )}</For>
                </div>
              )}</For>
            </Show>
          </div>
        </div>
      </Show>
      <Show when={reactPick()}>
        <div class="modal" onClick={() => setReactPick(false)}>
          <div class="react-box"><EmojiPanel emojiOnly={true} onEmoji={(e: string) => reactWith(e)} /></div>
        </div>
      </Show>
      <Show when={delAsk()}>
        <div class="modal">
          <div class="lock-box">
            <text class="fwd-title">{pickedMsgs().length > 1 ? "Apagar " + pickedMsgs().length + " mensagens?" : "Apagar mensagem?"}</text>
            <div class="lock-btns del-btns">
              <button class="btn-flat" onClick={() => setDelAsk(false)}><text class="btn-flat-t">Cancelar</text></button>
              <Show when={canRevokeAll()}><button class="btn-flat" onClick={() => selDeleteForAll()}><text class="btn-flat-t">Apagar para todos</text></button></Show>
              <button class="btn" onClick={() => selDeleteForMe()}><text class="btn-t">Apagar para mim</text></button>
            </div>
          </div>
        </div>
      </Show>
      <Show when={packAsk()}>
        <div class="modal">
          <div class="lock-box">
            <text class="fwd-title">Adicionar figurinha</text>
            <Show when={!packStore()}>
              <For each={packList()}>{(pk: any) => (
                <div class="pin-opt" onClick={() => setPackChoice(pk.id)}>
                  <div class="radio" classList={{ on: packChoice() === pk.id }}><Show when={packChoice() === pk.id}><div class="radio-dot" /></Show></div>
                  <text class="side-name">{pk.name}</text>
                </div>
              )}</For>
            </Show>
            <Show when={!packAdded()}>
              <div class="pin-opt" onClick={() => setPackChoice("")}>
                <div class="radio" classList={{ on: packChoice() === "" }}><Show when={packChoice() === ""}><div class="radio-dot" /></Show></div>
                <text class="side-name">Novo pacote</text>
              </div>
              <Show when={packChoice() === ""}>
                <text class="side-sub">O pacote inteiro desta figurinha vira uma aba no painel, com este nome:</text>
                <div class="lock-field"><input class="input" placeholder="Nome do pacote" value={packName()} onInput={(e) => setPackName(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") addPackNow(); }} /></div>
              </Show>
            </Show>
            <div class="lock-btns">
              <button class="btn-flat" onClick={() => setPackAsk(false)}><text class="btn-flat-t">Cancelar</text></button>
              <button class="btn" onClick={() => addPackNow()}><text class="btn-t">Adicionar</text></button>
            </div>
          </div>
        </div>
      </Show>
      <Show when={pinAsk()}>
        <div class="modal">
          <div class="lock-box">
            <text class="fwd-title">Escolha por quanto tempo a mensagem ficará fixada</text>
            <text class="side-sub">Você pode desafixar a qualquer momento.</text>
            <For each={[{ s: 86400, l: "24 horas" }, { s: 7 * 86400, l: "7 dias" }, { s: 30 * 86400, l: "30 dias" }]}>{(o: any) => (
              <div class="pin-opt" onClick={() => setPinFor(o.s)}>
                <div class="radio" classList={{ on: pinFor() === o.s }}><Show when={pinFor() === o.s}><div class="radio-dot" /></Show></div>
                <text class="side-name">{o.l}</text>
              </div>
            )}</For>
            <div class="lock-btns">
              <button class="btn-flat" onClick={() => setPinAsk(false)}><text class="btn-flat-t">Cancelar</text></button>
              <button class="btn" onClick={() => pinNow()}><text class="btn-t">Fixar</text></button>
            </div>
          </div>
        </div>
      </Show>
      <Show when={lockDialog() !== ""}>
        <div class="modal">
          <div class="lock-box">
            <text class="fwd-title">{lockDialog() === "set" ? "Bloqueio do app" : "Desativar bloqueio do app"}</text>
            <text class="side-sub">{lockDialog() === "set" ? "Crie uma senha para abrir o WhatsApp neste computador." : "Digite sua senha para desativar o bloqueio."}</text>
            <div class="lock-field"><input class="input" type="password" placeholder="Senha" value={lockPw()} onInput={(e) => setLockPw(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") { if (lockDialog() === "set") lockSave(); else lockDisable(); } }} /></div>
            <Show when={lockDialog() === "set"}><div class="lock-field"><input class="input" type="password" placeholder="Confirmar senha" value={lockPw2()} onInput={(e) => setLockPw2(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") lockSave(); }} /></div></Show>
            <Show when={lockError() !== ""}><text class="lg-err">{lockError()}</text></Show>
            <div class="lock-btns">
              <button class="btn-flat" onClick={() => { setLockDialog(""); setLockError(""); }}><text class="btn-flat-t">Cancelar</text></button>
              <button class="btn" onClick={() => { if (lockDialog() === "set") lockSave(); else lockDisable(); }}><text class="btn-t">{lockDialog() === "set" ? "OK" : "Desativar"}</text></button>
            </div>
          </div>
        </div>
      </Show>
      <Show when={locked()}>
        <div class="lockscreen">
          <img class="lock-logo" src={ic("wa-logo", "#25D366")} />
          <text class="lock-title">WhatsApp está bloqueado</text>
          <text class="side-sub lock-sub">Digite sua senha para desbloquear</text>
          <div class="lock-field"><input class="input" type="password" placeholder="Senha" value={lockPw()} onInput={(e) => setLockPw(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter") unlock(); }} /></div>
          <Show when={lockError() !== ""}><text class="lg-err">{lockError()}</text></Show>
          <button class="btn" onClick={() => unlock()}><text class="btn-t">Desbloquear</text></button>
        </div>
      </Show>
      <Menu ref={muteMenu}>
        <MenuItem onClick={() => muteFor(8 * 3600)}>8 horas</MenuItem>
        <MenuItem onClick={() => muteFor(7 * 86400)}>1 semana</MenuItem>
        <MenuItem onClick={() => muteFor(-1)}>Sempre</MenuItem>
      </Menu>
      <Show when={forwarding() !== null}>
        <div class="modal">
          <div class="fwd-box">
            <div class="fwd-head">
              <button class="ib" onClick={() => setForwarding(null)}><img class="ic" src={ic("close", tk().fg)} /></button>
              <text class="fwd-title">Encaminhar mensagem para</text>
            </div>
            <div class="search fwd-search">
              <div class="search-pill">
                <img class="search-ic" src={ic("search", tk().muted)} />
                <input class="search-in" placeholder="Pesquisar nome ou número" value={fwdQuery()} onInput={(e) => setFwdQuery(e.currentTarget.value)} />
              </div>
            </div>
            <div class="fwd-list">
              <Show when={fwdToStatusOk()}>
                <div class="fwd-row" onClick={() => fwdToggle("status@broadcast")}>
                  <div class="fwd-check" classList={{ on: fwdOn("status@broadcast") }}><Show when={fwdOn("status@broadcast")}><img class="ic20" src={ic("check", tk().onAccent)} /></Show></div>
                  <div class="ring"><div class="av av40" style={{ background: photo("me")[0] }}>
                    <Show when={!myPic()}><img class="av-ic" src={ic("person", photo("me")[1])} /></Show>
                    <Show when={!!myPic()}><img class="av-img" src={"file://" + myPic()} /></Show>
                  </div></div>
                  <div class="side-text"><text class="side-name">Meu status</text><text class="side-sub">Meus contatos</text></div>
                </div>
              </Show>
              <For each={fwdChats()}>
                {(c: Chat) => (
                  <div class="fwd-row" onClick={() => fwdToggle(c.id)}>
                    <div class="fwd-check" classList={{ on: fwdOn(c.id) }}><Show when={fwdOn(c.id)}><img class="ic20" src={ic("check", tk().onAccent)} /></Show></div>
                    <div class="av av40" style={{ background: photo(c.id)[0] }}>
                      <Show when={!c.profilePicThumb}><img class="av-ic" src={ic(c.kind === "user" ? "person" : "group", photo(c.id)[1])} /></Show>
                      <Show when={!!c.profilePicThumb}><img class="av-img" src={"file://" + (c.profilePicThumb || "")} /></Show>
                    </div>
                    <text class="fwd-name">{title(c)}</text>
                  </div>
                )}
              </For>
            </div>
            <Show when={fwdPicked().length > 0}>
              <div class="fwd-foot">
                <text class="fwd-names">{fwdNames()}</text>
                <button class="stage-send" onClick={() => fwdSend()}><img class="ic" src={ic("send", tk().onAccent)} /></button>
              </div>
            </Show>
          </div>
        </div>
      </Show>
      <Picker request={pickReq()} onPicked={(p: string, k: string) => onPicked(p, k)} />
      <Chime ref={chimeRef} file="chime.ogg" onDone={() => chimeDone()} />
      <Chime ref={endChimeRef} file="chime-end.ogg" />
      <Show when={viewer() !== null}>
        <div class="viewer">
          <MediaViewer kind={viewer() ? viewer().kind : ""} source={viewer() ? viewer().source : ""} title={viewer() ? viewer().title : ""}
            subtitle={viewer() ? viewer().subtitle : ""} closeIcon={ic("close", "#FAFAFA")} openIcon={ic("open", "#FAFAFA")}
            textBody={viewer() ? viewer().text || "" : ""} counter={viewer() ? viewer().counter || "" : ""}
            onClose={() => closeViewer()} onOpenExternally={() => viewerExternal()} />
        </div>
      </Show>
    </div>
  );
}
