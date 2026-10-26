# WhatsApp Web's internal API, mapped from its own JavaScript — and what whatsmeow covers

Reference for **QWhats native** ([native-client.md](native-client.md)). The owner asked for the API to be
mapped from WhatsApp Web's own code, not from third-party descriptions, so that we know what the
real client does and where whatsmeow (our transport) matches, differs or falls short.

- **Source:** WhatsApp Web revision **1051067427** (client version `2.3000.1051067427`), fetched
  2026-10-20 from a logged-out headless Chromium session (no account was used). This revision is
  compared with whatsmeow `v0.0.0-20261017175727-b2b1e71d45e2`.
- **Proprietary code:** WhatsApp's JS is not in this repository. It lives only in
  `~/.cache/qml-whats-build/waweb/`. This document quotes only short excerpts as evidence: stanza
  shapes, attribute names, enum values and module names.
- **Markers:** "(inferred)" marks a conclusion that is not directly visible in code. P1/P2/P3 are
  priorities for a desktop client: P1 = needed for daily-use parity, P2 = nice to have, P3 = niche.

## 0. How the corpus was obtained (reproducible)

| step | what | result |
|---|---|---|
| 1 | Load `https://web.whatsapp.com/` in headless Chromium (`--headless=new`, Chrome 140 Linux UA). Drive it through CDP and record network responses, performance entries and the page HTML. Attach to the dedicated workers and the service worker and read their resource lists. | 736 bundles at first sight: the main page, 3 workers and the SW |
| 2 | Read the Meta bootloader state (`require("Bootloader").__debug.resources`, `rsrcMap`/`compMap` in the HTML). Then repeat until nothing new appears: parse every `__d(...)` and its deps plus `requireDeferred`/`JSResource(ForInteraction)`/`requireLazy` targets, take the names that are referenced but not defined, and ask `/ajax/bootloader-endpoint/?modules=…` (from inside the page) for their `rsrcMap`. Download the `static.whatsapp.net/rsrc.php/…js` URLs with curl. | **8,736 bundle files** (246 MB) |
| 3 | Index every `__d("Name",[deps],…)` → `index.json` (file, deps, lazy refs, size, reachability from WA code). Split into one file per module (`mods/`). | **61,364 unique modules** (101,718 definitions incl. duplicates across packages). 18,205 are WhatsApp's own (`WA*`/`WDS*`); 44,326 are reachable from WhatsApp code; the rest is shared Meta platform code (Ads Manager etc.) |

The WhatsApp modules break down as: `WAWeb*` 11,154 (of which `WAWebBiz*` 1,514,
`WAWebVoip*` 538, `WAWebNewsletter*` 456, `WAWebGroup*` 320, `WAWebMex*` 195,
`WAWebStatus*` 155, `WAWebSchema*` 132, `WAWebSyncd*` 83, `WAWebHistorySync*` 25),
`WASmaxIn*` 982, `WASmaxOut*` 368, other `WASmax*` 153 (139 of them `*RPC`), `WDS*` (the design
system) 1,691, other `WA*` 439, plus 47 protobuf spec modules (`*.pb`).

**Known holes:**
- 28 WhatsApp module names are referenced but cannot be fetched through the bootloader. They are
  server-generated config or worker-resource modules, e.g. `WAWebBackendWorkerV2Resource`,
  `WAWebVoipWebWasmWorkerResource`, `*SitevarConfig`.
- The VoIP media engine is a WASM binary (`wa_voip_shared.wasm`), not JS; it was not analysed.
- About 1,500 non-WhatsApp Meta modules (Ads Manager code that business features reference) were
  deliberately not chased further.

**Regenerating after a WhatsApp Web update:** the scripts are in `~/.cache/qml-whats-build/waweb/tools/`:

| script | role |
|---|---|
| `grab.mjs`, `ev.mjs`, `dw.mjs` | CDP drivers (page and workers) |
| `dl.py` | parallel bundle downloader |
| `mkprobe.py` | bootloader-endpoint probe builder |
| `index.py` | module index |
| `split.py` | per-module files |
| `smax.py` | WASmax request table |
| `pbdump.py`, `pbdiff.py` | protobuf extraction and diff against whatsmeow |

## Contents

1. [Summary: coverage table and prioritized gaps](#summary)
2. [Connection and protocol plumbing](#01--connection-and-protocol-plumbing): websocket, Noise, WAP, pairing, IQ framework, the full WASmax / MEX / usync tables
3. [Protobuf schemas](#02--protobuf-schemas-in-whatsapp-web-rev-1051067427-vs-whatsmeow): every `.pb` module, all `waE2E.Message` kinds, and the diff against whatsmeow
4. [Messaging](#03--messaging-send-receive-media-receipts-presence): send pipeline, message kinds, media upload/download, receipts, presence
5. [History sync and app-state sync](#04--history-sync-and-app-state-sync-syncd): including the full syncd action table
6. [Groups, communities, channels, status, calls](#05--groups-communities-channels-status-calls)
7. [Internal data model](#06--whatsapp-webs-internal-data-model-and-what-our-core-should-expose): the fields our core should expose

<a id="summary"></a>
## Summary

### Verdict

whatsmeow is a sound transport. On the wire it matches WhatsApp Web exactly:
- the binary-XML token dictionary (v3) is byte-identical;
- the Noise intro (`WA 6 3`) and the root certificate are the same;
- the ClientPayload schema has no missing fields;
- the protobuf schemas agree field-for-field, with whatsmeow about one release behind (a handful of
  minor fields);
- the message stanza shape, phash, tc/cs tokens, edit codes and the receipt types all match.

What separates "whatsmeow works" from "behaves like WhatsApp Web" falls into three groups:
1. **Client-side logic that whatsmeow leaves to the application**: history-sync bookkeeping, dirty
   bits, unwrapping of new message wrappers, system rows, link previews.
2. **Builders and stanza attributes that whatsmeow lacks or has out of date**: delete-for-me /
   clear-chat patches, poll and event `meta` attributes, status receipts, call offer receipts,
   media paths for ptt/sticker/gif, current MEX doc ids.
3. **Calls**: the VoIP media engine is a closed WASM blob, and it is gated even on WhatsApp Web
   (browser calling needs the server flag `enable_web_calling`; the Windows app is always on).
   Calls remain "answer on the phone" plus Reject, as planned.

### Coverage by domain

| domain | WhatsApp Web (main modules) | whatsmeow | coverage |
|---|---|---|---|
| Websocket + Noise + WAP | `WAWebOpenSocket`, `WANoiseHandshake`, `WANoiseSocket`, `WAWap`, `WAWapDict` | `socket/`, `handshake.go`, `binary/` | **Full on the wire.** No `:5222` fallback race, no IK fast-resume, no edge-routing replay (none of these are needed) |
| Client version | `2.3000.1051067427` | hard-coded `2.3000.1050728964` (`store/clientpayload.go:79`) | **Stale.** Must be refreshed at runtime (`SetWAVersion`) to avoid 405 |
| Pairing (QR, phone code, passkey) | `md` RPCs: GetRef, CompanionHello/Finish, SetPasskeyPrologue… | `pair.go`, `pair-code.go`, `pair-passkey.go` | **Full**, except the `refresh_code` notification |
| Connection stanzas | `<success>`, `<failure>`, `<stream:error>`, `<ib>` dirty/offline/offline_batch | `connectionevents.go` | **Partial.** The dirty-bit handler is commented out (`connectionevents.go:95`); no `offline_batch` pull; 516 is not treated as logout; no answer to server ping |
| IQ framework / WASmax | 139 RPCs + 82 `WASmaxOut*Request` over 30+ xmlns; 982 incoming parsers | `request.go`, hand-written per feature | Most namespaces used daily are present: `w:g2`, `encrypt`, `md`, `usync`, `w:m`, `w:profile:picture`, `privacy`, `blocklist`, `w:sync:app:state`, `newsletter`, `w:p`, `urn:xmpp:whatsapp:push`, `passive`, `abt` |
| MEX (GraphQL over IQ, `w:mex`) | 78 persisted queries, 46 notification types | `newsletter.go` and a few others; 5 notification types | **Partial and stale.** The doc ids differ from Web's current ones; the platform check is broken; LID-change, username and group-property notifications are dropped |
| usync | contact, devices, lid, status, picture, business, disappearing_mode, text_status, username, feature… | `user.go` | **Mostly.** Lacks `text_status`, `feature` and the per-protocol backoff |
| Protobufs | 47 `.pb` modules, 942 message types, 249 enums | `proto/*` | **Equal for daily use.** 12 extra FutureProof wrappers that Web unwraps are not unwrapped by `UnwrapRaw` |
| Send / receive / E2E | `WAWebSendMsgJob`, `WAWebEncryptMsgProtobuf`, `WAWebSendGroupSkmsgJob` | `send.go`, `message.go`, `retry.go` | **Full core.** Sender keys go to every device on every message (Web sends only to devices that lack them); no automatic resend on phash mismatch; no PQ (Kyber) sessions, which are off by default on Web |
| Message kinds / attributes | `type=event`, `meta polltype`, `view_once`, `message_association_type` | `getTypeFromMessage` | **Gaps.** Events are sent as `text`; newer polls lack `polltype`; no view-once or HD-association meta; `BuildPollCreation` is V1 only |
| Media | `WAWebQueryMediaConnsJob` (`w:m`), `/mms/{image,video,audio,ptt,sticker,gif,document,thumbnail-*,md-msg-hist,md-app-state,group-history}` | `upload.go`, `download.go`, `mediaconn.go`, `mediaretry.go` | **Core OK.** Wrong path for ptt/sticker/gif; first host only; no resumable/chunked upload; no streaming sidecar; no waveform; no HQ-thumbnail HKDF info |
| Link previews | asks the phone (`GENERATE_LINK_PREVIEW` peer-data op, wait 7 s) and falls back to a minimal preview | enums only | **Missing** (P1) |
| Receipts / presence / chatstate | read, read-self, played, inactive, sender, hist_sync, server-error, retry; `class=status`; 256-id chunks; group presence count | `receipt.go`, `presence.go` | **Mostly.** No `class=status`, no chunking, `readreceipts` from the ack is ignored, no group presence |
| History sync | `WAWebHistorySync*`, `WAWebHandleHistorySync*`; boundary, dedup, end-of-transfer type, on-demand flow | `message.go` (event + download), `BuildHistorySyncRequest` | **Transport only.** All bookkeeping is left to the app; on-demand timestamp units differ (Web ms, whatsmeow s, to verify) |
| App state (syncd) | 71 action handlers (~49 sendable), key create/rotate/share, snapshot recovery, batched IQ | `appstate/`, `appstate.go`, 10 builders | **Decode: full. Encode: partial.** No `deleteMessageForMe`/`clearChat`/`lock`/`contact` builders; no key creation or sharing; only SET operations |
| Groups / communities | 29 `w:g2` RPCs, more moving to MEX; ~50 notification types | `group.go` | **Basics OK.** ~30 notification types arrive only as raw `UnknownChanges`; no community deactivate, join sub-group, leave community or cancel request; join approval state misread |
| Channels (newsletters) | `newsletter` IQs + MEX operations; live-update notifications | `newsletter.go` | **Partial.** Stale ids, outdated mute model, update notifications ignored |
| Status | `status@broadcast` sender keys to the audience; privacy through app-state `StatusPrivacyAction`; `class=status` view receipts; key rotation when the audience shrinks | `broadcast.go` | **Partial.** No status receipts class, no key rotation (privacy), incoming `<status>` stanzas dropped |
| Calls | signaling + media inside `wa_voip_shared.wasm`; gated by `enable_web_calling`; offer → `<receipt><offer/>` | `call.go` (events, `RejectCall`) | **Reject works.** No offer receipt; answering or placing calls is out of reach |
| Data model / persistence | `WAWebMsgModel` (411 + 42 fields), `WAWebChatModel` (75 + 59), `WAWebContactModel` (33 + 21); 132 IndexedDB tables | — (whatsmeow keeps no history) | Our core must build it. See §06 for the field list |

### Prioritized gaps for a desktop client

Ordered by impact on daily use. "custom stanza" means a node we build and send through
whatsmeow's `DangerousInternals().SendNode`/`SendIQ`, or a small patch to whatsmeow.

**P1: needed for parity in daily use**

| # | gap | kind of fix | § |
|---|---|---|---|
| 1 | Refresh the WA version at startup (`SetWAVersion` from Web's `client_revision`); whatsmeow's hard-coded build is older than Web's | client logic | 01 |
| 2 | History bookkeeping: initial-sync boundary, dedup by `originalMessageId`, per-chat end-of-history type, progress, the "load older" on-demand flow (check ms vs s) | client logic + peer-data op | 04 |
| 3 | App-state builders for **delete-for-me** (`deleteMessageForMe`, regular_high v3) and **clear chat** (`clearChat` v6); index 1:1 chats by **LID** after the migration | client-built `PatchInfo` | 04 |
| 4 | Dirty bits: refetch and `<clean>` ack (whatsmeow's handler is commented out) | client logic on the raw `<ib>` | 01 |
| 5 | Message normalization: unwrap Web's 12 extra FutureProof wrappers; build system rows from group notifications, identity changes, calls and ephemeral changes; placeholder for undecryptable messages; edits, revokes and reactions applied to their parent; orphan handling | client logic | 02, 06 |
| 6 | Link previews: `GENERATE_LINK_PREVIEW` to the phone with a 7 s wait, falling back to a local OpenGraph fetch plus a `/mms/thumbnail-link` upload | peer-data op + client logic | 03 |
| 7 | Voice notes: waveform (64 samples), `ptt=true`, opus/ogg; edit/revoke UX within the 15/20-minute windows | protobuf fields + client logic | 03 |
| 8 | Calls: notify with Reject; send `<receipt><offer call-id call-creator/></receipt>` as Web does; dismiss on accepted/rejected elsewhere | custom stanza + existing events | 05 |
| 9 | Group notifications whatsmeow leaves raw (membership requests, member add mode, linked-group promote/demote, change number, `groups_dirty`); fix the join-approval state | client logic (parse raw nodes) | 05 |
| 10 | Stream error 516 = logged out (show re-link); any conflict other than "replaced" = device removed | client logic | 01 |
| 11 | MEX notifications for LID changes (and username / group-property / text status) | client logic (parse the MEX JSON) | 01 |
| 12 | Status: `class="status"` view receipts, status privacy through app state, sender-key rotation when the audience shrinks, incoming `<status>` stanzas | custom stanza + app-state | 05 |
| 13 | Offline backlog: check with a live account whether whatsmeow (`pull=true`, never sends `<offline_batch>`) stalls on a large backlog | verify, then custom `ib` stanza | 01 |

**P2: nice to have / robustness**

- **Media:**
  - correct `/mms/ptt|sticker|gif` paths and HQ thumbnail download;
  - streaming sidecar for videos;
  - resumable and chunked upload with host fallback for large files.
- **Message attributes:**
  - `type=event` and `meta polltype` for events and polls V3/V6;
  - view-once send;
  - albums and HD association.
- **Receipts:** read receipts chunked at 256 ids; honour `readreceipts` from the ack.
- **Groups:** send sender keys only to devices that lack them, and rotate on member removal;
  auto-resend on phash mismatch.
- **App state:**
  - key creation, rotation and sharing (whatsmeow cannot create keys);
  - snapshot recovery, then a full resync, before giving up;
  - typed handling of `lock`, `favorites`, `lid_contact`, `status_privacy` and similar actions;
  - builders for lock, favorites, contact (with REMOVE) and userStatusMute.
- **History:** call `SendHistorySyncServerErrorReceipt` automatically when a download fails.
- **Communities:** deactivate, join a sub-group, leave the community, unlink with orphan removal,
  list sub-groups, withdraw my own join request.
- **Channels:** our own MEX wrapper with current doc ids; mute through `update_user_setting`;
  directory and search; admin operations.
- **Calls:** call-history tab from app-state `CallLog`; create call links.
- **Group history bundles:** receive them (`messageHistoryBundle`, media type `group-history`).
- **Connection:** answer server `urn:xmpp:ping`; handle the pairing-code `refresh_code`; usync
  `text_status`/`feature`.

**P3: niche or future**
- group presence count;
- PQ (Kyber) sessions, which become P1 if Meta enables `pq_1on1_message_enabled`;
- secret-encrypted edits;
- batching all dirty collections into one sync IQ, and MMS upload of large patches;
- channel statuses, Q&A and insights;
- `StubType` 290/291;
- business-only syncd actions;
- answering or placing calls (needs the full proprietary VoIP engine; out of scope).

### What changes in `native-client.md`

- `session.connect`: set the WA version from Web's current revision before connecting.
- `chats.list` row: add `kind`, `mutedUntil`, `pinnedAt`, `markedUnread`, `ephemeral`,
  `readOnly`/`announce`, and a structured `lastMessage`.
- Normalized message: add `pushName`, the full ack ladder (`error`/`pending`), `mentions`,
  `forwarded`, `edited`, `revokedBy`, `viewOnce`, `expiresAt`, `starred`, `linkPreview`,
  `waveform`, `subtype` for `system` rows, and `undecryptable`.
- New methods: `message.deleteForMe` and `chat.clear` (app-state patches whatsmeow lacks),
  `message.edit`, `call.reject`.
- Events: `dirty` handling is internal to the core; there is a `history` progress event with
  per-chat end-of-history.

See §06.3 for the full field lists.

---


## 01 — Connection and protocol plumbing

WhatsApp Web revision 1051067427 (client version string `2.3000.1051067427`), checked against
whatsmeow `v0.0.0-20261017175727-b2b1e71d45e2` (paths below are relative to that module root).
"(inferred)" marks conclusions that are not directly visible in code.

---

### 1. What WhatsApp Web does

#### 1.1 WebSocket transport (`WAWebOpenSocket`, `WAWebWatchedSocket`, `WAFrameSocket`)

- **Endpoints**: two URLs are **raced at the same time** (`openWebSocketsConcurrently`). The first
  one to open wins and the other is closed with `1000 "loser socket"`:
  ```
  g=["wss://web.whatsapp.com/ws/chat","wss://web.whatsapp.com:5222/ws/chat"]
  ```
  If an edge-routing blob is stored, each URL gets `?ED=<base64url(edgeRouting)>`.
- **Socket open retry** (`WAPromiseRetryLoop "socketOpener"`): Fibonacci backoff, first/second 1 s,
  max 10 s, jitter 0.1. It resets when the browser `online` event fires.
- **Comms loop reconnect** (`WAWebCommsConfigBase`): Fibonacci 1 s/1 s, max `9e5` ms (15 min),
  jitter 0.1, `maxRetries: MAX_SAFE_INTEGER`. `WAComms` has its own default of Fibonacci 10 s/10 s
  with `resetDelay: 3e4`.
- **Close codes**: 1000/1001 are normal and 1006 is counted. 1002/1003/1007–1011/1015 are logged as
  errors (`WAWebOpenSocket`).
- **Framing** (`WAFrameSocket`): each frame is a 3-byte big-endian length followed by the payload,
  and must be smaller than `1<<24`. The *first* frame carries the intro header in front of it.
- **Intro header** (`WAWebOpenChatSocket`, `WAWebCommonSocketPlatformDetails.WA_WEB_PROTO_HEADER`):
  `new Uint8Array([87,65,6,DICT_VERSION])` = `"WA" 0x06 0x03`.
- **Edge-routing pre-intro**: when `getRoutingInfo().edgeRouting` exists, the client sends
  `"ED" 0x00 0x01` + a 3-byte length + the routing bytes *before* the `WA` header:
  ```
  l.write("ED",0,1),l.writeUint8(i.byteLength>>16),l.writeUint16(i.byteLength&65535),l.writeBuffer(i)
  ```
  The routing bytes come from `<ib><edge_routing><routing_info>…</routing_info><dns_domain>fb|sl</dns_domain></edge_routing></ib>`
  (`WAWebHandleInfoBulletin`, `WAWebHandleRoutingInfo`, domains `{fb, sl}`) and are stored in
  `WAWebUserPrefsMultiDevice.setRoutingInfo`.
- **"Direct connection" is not a transport feature.** `WAWebDirectConnectionCaBundle` (200 KB of
  PEM roots), `WAWebDirectConnectionCypher` and `WAWebBusinessDirectConnection*` belong to a Business
  feature: AES-GCM / X.509 sharing of phone number and postcode with a business, gated by abprops
  `web_abprop_direct_connection_md` and `direct_connection_business_numbers`. The chat socket does not use them.

#### 1.2 Noise handshake (`WAOpenChatSocket`, `WAWebOpenChatSocket`, `WANoiseHandshake`, `WANoiseSocket`)

There are three patterns. Each name is padded to 32 bytes and used directly as the hash; otherwise
it is SHA-256'd (`start()`):

| Pattern | When |
|---|---|
| `Noise_XX_25519_AESGCM_SHA256\0\0\0\0` | Full handshake (first login, or no cached server cert) |
| `Noise_IK_25519_AESGCM_SHA256\0\0\0\0` | **Resume** handshake, when the server static key is known from the stored cert chain (`getNoiseInfo().certificateChainBuffer` → `makeServerInfoIfKnown` → `leaf.key`) and the screen lock is off |
| `Noise_XXfallback_25519_AESGCM_SHA256` | Server answers an IK hello with a `static` field: client switches to XXfallback using the same ephemeral |

- The prologue is the intro header (`authenticate(WA header)`). `mixIntoKey` resets the counter;
  keys come from HKDF(salt=ck, ikm, "", 64) split 32/32. The AES-GCM IV is 8 zero bytes plus a 4-byte
  big-endian counter. After `finish()`, separate write/read counters are kept.
- **Resume (IK) client hello** = `{ephemeral, static: enc(clientStatic), payload: enc(ClientPayload)}`
  in one message, so it saves a round trip. If the IK path throws `OperationError`, the client falls
  back to a full handshake. Cert-chain lookup failures are retried at most `$=1` time before the
  client falls back to XX.
- **Server cert** (`WAVerifyChainCertificateWA6`): CertChain {intermediate, leaf}. The intermediate is
  signed by root `142375574d0a587166aae71ebe516437c4a28b73e3695c6ce1f7f9545da8ee6b`
  ("WhatsAppLongTerm1", serial 0). The leaf is signed by the intermediate, and `leaf.key` must equal the
  decrypted server static key.
- HandshakeMessage protobuf comes from `WAWebProtobufsWa6.pb` (`clientHello=2`, `serverHello=3`,
  `clientFinish=4`).
- **Incoming stanza frame**: the first byte is a flags byte. Bit `2` means the rest is zlib-compressed
  (`WAWap.decodeStanza`: `a=r&_` with `_=2`).

#### 1.3 ClientPayload / UserAgent / WebInfo (`WAWebClientPayload`, `WAWebWorkerClientPayload`, `WAWebBuildConstants`, `WAWebDeviceInfoBridgeApi`)

- Version: `VERSION_PRIMARY="2"`, `SECONDARY="3000"`, `TERTIARY=SiteData.client_revision`. Non-prod
  builds report `3.0.0` (gk 26258/26259). `VERSION_BASE` is `2.3000.<rev>`. Windows hybrid builds add
  `quaternary=WINDOWS_BUILD`, and its 6 digits are split into mcc/mnc.
- **Common fields** (login and registration):
  `passive`, `pull`, `connectType=WIFI_UNKNOWN`, `connectReason=USER_ACTIVATED` (the worker/service-worker
  path uses `PUSH`), `userAgent`, `webInfo{webSubPlatform}`.
- **UserAgent**: `platform=WEB`, `appVersion`, `releaseChannel` (RELEASE/BETA/ALPHA/DEBUG from
  `WAWebBuildType`), and `mcc="000"`, `mnc="000"`, `osVersion="0.1"`, `manufacturer=""`,
  `device="Desktop"`, `osBuildNumber="0.1"`, `localeLanguageIso6391=<UI lang>`,
  `localeCountryIso31661Alpha2=<UI region>`. These are the hard-coded values from `WAWebDeviceInfoBridgeApi`.
- **WebInfo.webSubPlatform**: `WEB_BROWSER` (WEB/PWA), `DARWIN`, `APP_STORE` (MACSTORE),
  `WIN_HYBRID`. No other WebInfo fields are set.
- **Login payload adds**: `username=parseInt(pn user)`, `device`, `lc=<login counter>`,
  `connectAttemptCount`, `lidDbMigrated=<real migration state>`, `pushName` (when set).
- **Registration payload adds** `devicePairingData{buildHash=md5(VERSION_BASE), deviceProps,
  eRegid(4B), eKeytype=[5], eIdent, eSkeyId(3B), eSkeyVal, eSkeySig}`.
- **DeviceProps** (`WAWebProtobufsCompanionReg.pb`):
  - `os=<browser OS>`, `version=<browser version>`, `platformType` from browser name (CHROME,
    FIREFOX, …, DESKTOP for electron, UWP on Windows), `requireFullSync`.
  - `historySyncConfig`:
    - `inlineInitialPayloadInE2EeMsg`, `supportBotUserAgentChatHistory`, `supportCagReactionsAndPolls`,
      `supportRecentSyncChunkMessageCountTuning`, `supportHostedGroupMsg`, `supportBizHostedMsg`,
      `supportFbidBotChatHistory`, `supportMessageAssociation`, `supportCallLogHistory`: all true.
    - `supportGroupHistory` (gk 15338), `thumbnailSyncDaysLimit` (knob 4736),
      `supportManusHistory` / `supportHatchHistory` (knobs), `supportedBotChannelFbids:[]`.
    - `storageQuotaMb` comes from `navigator.storage` (or `fullSyncDaysLimit:365` in debug).
    - Windows sets `onDemandReady` and `completeOnDemandReady`.
- **Default connect options**: `{passive:false, pull:true}`. `passive` is then overwritten by
  `shouldConnectAsPassiveMode()` (see 1.7).

#### 1.4 Binary XML (WAP) encoding (`WAWap`, `WAWapDict`, `WAWapJid`, `WAJids`)

- Dictionary: `DICT_VERSION=3`, `SINGLE_BYTE_TOKEN` (235 entries, written as index+1), and 4 double-byte
  dictionaries of 256 entries (tags 236–239).
- Tags: `0` LIST_EMPTY, `245` INTEROP_JID (user, u16 device, u16 integrator), `246` FB_JID
  (user, u16 device, "msgr"), `247` AD_JID / JID_U (u8 domainType, u8 device, user), `248` LIST_8,
  `249` LIST_16, `250` JID_PAIR, `251` HEX_8, `252` BINARY_8, `253` BINARY_20, `254` BINARY_32, `255` NIBBLE_8.
- JID_U `domainType`: `WHATSAPP=0`, `LID=1`, `HOSTED=128`, `HOSTED_LID=129`. The decoder also accepts
  any even value with bit 7 set as HOSTED. Hosted JIDs must use device 99 (`"wid unexpected deviceId"`).
- Domains in `WAJids`: `s.whatsapp.net`, `g.us`, `broadcast` (`status@broadcast`), `lid`,
  `newsletter`, `msgr`, `interop` (written as `<integrator>-<user>:<device>@interop`), `hosted`, `hosted.lid`,
  `bot`, `call` (call-link JIDs, `WAWap.CALL`), and also `@me` and `@system` (author pseudo-JIDs).
- **Stanza IDs** (`WAWap.generateId`): `"<u16>.<u16>-<counter>"`. The random prefix is generated once
  per session.

#### 1.5 Keepalive / ping (`WAComms`, `WAWebCommsSendPing`, `WASmaxOutPingsClientRequest`)

- Ping: `<iq id=… type="get" xmlns="w:p" to="s.whatsapp.net"/>`. The response `<iq type="result" t=…>`
  is used for **clock skew** = `round((sendTime+rtt/2)/1000 - t)`.
- Health-check timer: `healthCheckInterval: 15` s, randomized to `15–30 s` (`e*1e3*(1+Math.random())`).
  It only runs when **idle**, meaning no active ping, pending acks, IQs or smax stanzas.
- Dead-socket timer: after any `callStanza` (a request that expects a reply), the socket is
  soft-closed if nothing arrives within `deadSocketTime: 2e4` (20 s).
- Server-initiated `<iq xmlns="urn:xmpp:ping">` is answered with `<iq type="result" to=from>`
  (`WAWebHandleStanzaCommon`).
- The offline resume step uses `blockSendPing` with timeout `web_offline_resume_wait_for_ping_timeout_seconds`.

#### 1.6 Connection stanzas: `<success>`, `<failure>`, `<stream:error>`, `<ib>`

- **`<success>`** (`WAWebHandleSuccess`) has attrs `t` (clock skew), `lid` (own LID), `display_name`,
  `companion_enc_static` (server salt for the local DB encryption key), `abprops` (refresh id) and
  `group_abprops`. On success the client:
  1. runs passive tasks;
  2. refreshes mms4 media hosts (1 s budget);
  3. triggers an AB-props sync if the refresh id changed.
- **`<failure reason=…>`** (`WAWebHandleFailure`, `WAWebFailureErrorCodes`):

  | Reason | Meaning | Client action |
  |---|---|---|
  | 400 | GENERIC | log |
  | 401 | NOT_AUTHORIZED | logout |
  | 402 | TEMP_BANNED | ban banner; attrs `code`, `expire`, `message`, `url` |
  | 403 | LOCKED | logout with `logout_message_header/subtext/locale` |
  | 405 | CLIENT_TOO_OLD | force update |
  | 406 | BANNED | logout |
  | 409 | BAD_USER_AGENT | force update |
  | 500 | INTERNAL_SERVER_ERROR | log |
  | 501 | EXPERIMENTAL | log |
  | 503 | SERVICE_UNAVAILABLE | event |

  The parser also reads the `location` attr.
- **`<stream:error>`** (`WAWebHandleStreamError`):

  | Stream error | Client action |
  |---|---|
  | `code=515` | stop comms, `startLogin()`, restart backend (post-pairing restart) |
  | `code=516` | **forced logout** (`startLogout`) |
  | other 5xx | `onStreamErrorReceived` (reconnect) |
  | `<conflict type="replaced">` | stop comms, no reconnect (another tab or session took over) |
  | `<conflict type="device_removed">` (or any other conflict type) | clear credentials and log out |
  | `<ack id>` | close socket |
  | `<xml-not-well-formed>` | close socket |
- **`<ib>` info bulletins** (`WAWebHandleInfoBulletin`, `WAWebHandleInfoBulletinTypes`). None of them
  are acked:
  - `dirty` (`type`, `timestamp`; `account_sync` has children naming protocols) — §1.8
  - `edge_routing` (`routing_info`, optional `dns_domain`) — §1.1
  - `offline count=N` — the offline queue is drained
  - `offline_preview count message receipt notification call` — offline resume starts
  - `priority_offline_complete`
  - `tos` (`<notice id>`) — `TosManager.maybeUpdateServer`
  - `thread_metadata` — `WAWebParseThreadMetadata`
  - `client_expiration` (smax `ClientExpirationClientExpiration`) — sets the client expiry date
  - `recovery_nonce code use_case` — `WAWebHandleRecoveryNonceIB`
- **Outgoing `<ib>`**:
  - `<ib><offline_batch count=N/></ib>` (`WASmaxOfflineBatchRPC`). Because the client connects with
    `pull=true`, it **asks for the next batch of offline stanzas** when pending ≤ 200 (`C=200`;
    adaptive sizes `{0:200,1:100,2:50,3:10}`, debounce 100 ms) (`WAWebOfflineHandler`).
  - `<ib><unified_session id=…/></ib>` (`WASmaxUnifiedSessionShareRPC`, telemetry).

#### 1.7 Passive / active mode (`WAWebPassiveModeManager`, `WAWebRegisterPassiveTasks*`, `WASmaxPassiveMode*`)

- The client connects with `passive=true` only if passive tasks are registered:
  - `KeyUpload`, `PQKeyUpload`, `PQKeyRollback`, `SyncABProps`;
  - `SendDanglingReceipts`, `SendOnlineDanglingReceipts`.
- After `<success>`, the client runs those tasks (60 s timeout `k=6e4`), then sends
  `<iq xmlns="passive" type="set"><active/></iq>`. `<passive/>` is the counterpart (`PassiveIQ`).
- **Post-quantum prekeys**: `PQKeyUpload` / `PQKeyRollback` and the `WASmaxInPreKeysPQ*` parsers
  (`PQKeyMixin`, `PQPreKeyContentsMixin`, `PQPreKeyListCountLowMixin`, notification child `pq_count`)
  show that Web now uploads PQ prekeys during passive mode. Details belong to the crypto section.

#### 1.8 Dirty bits (`WAWebHandleDirtyBits`, `WAWebDirtyBitsConsts`, `WAWebClearDirtyBitsJob`)

- Supported types: `groups`, `account_sync`, `syncd_app_state`, `newsletter_metadata`, `orgs`.
- `account_sync` protocols: `devices`, `picture`, `privacy`, `blocklist`, `notice` (plus optoutlist).
- Each type triggers a refetch. For example `syncd_app_state` marks all app-state collections for
  sync, and `devices` refetches own devices. Then the client acks:
  ```
  <iq to=s.whatsapp.net type=set xmlns="urn:xmpp:whatsapp:dirty"><clean type=… timestamp=…/>…</iq>
  ```

#### 1.9 Push config (`WASmaxPushConfigSetRPC`, `WAWebSetPushConfigJob`, `WAWebSetWindowsPushConfig`, `WAWebGetPushServerSettingsJob`)

`<iq xmlns="urn:xmpp:whatsapp:push" type=set>` with one of these children:
- `<config platform="web" endpoint auth p256dh lg lc/>` (WebPush);
- `platform="wns" id pkey settings version` (Windows);
- `platform="fb" appid deviceid fbid`;
- `platform="ent" id`;
- a generic mobile config (`preview default groups call voip_payload_type nse_* …`, with `<item jid mute notify call>`);
- or `<clear platform/>`.

#### 1.10 AB props (`abt`)

- `<iq xmlns="abt" type=get><props protocol="1" hash=… refresh_id=…/></iq>`.
- Group variant: `<props group=<gjid> hash=…/>`.
- Triggered by `<success abprops=…>` and the `SyncABProps` passive task.

#### 1.11 Pairing / login (`md` namespace)

**QR flow** (`WAWebHandlePairDevice`, `WAWebLinkDeviceQrcode.react`):
- The server sends `<iq xmlns="md"><pair-device><ref>…</ref>…</pair-device></iq>`
  (`WASmaxInMdSetToCompanionRequest`).
- QR text = `ref,b64(noiseStaticPub),b64(identityPub),b64(advSecret),<platformId>`. Behind a knob it
  is prefixed with `https://wa.me/settings/linked_devices#`; otherwise `,https://faq.whatsapp.com/r/ld`
  is appended (knob 770).
- `<pair-success>` (`WASmaxInMdSetRegRequest`) carries:
  - `device jid lid`, `biz name`, `platform name`, `device-identity`, `client-props`;
  - newer elements `encryption-metadata` (AES metadata: `algorithm`, `nonce`, `encrypted_key`,
    `encrypted_data`, `auth_tag`, `version`), `companion_recovery_server_token`, and
    `jurisdiction` / `cc` / `iso` / `beta`.
- Reply: `<pair-device-sign><device-identity key-index=…/>[<key_attestation key_id>][<gpia>][<client-app-id>]</pair-device-sign>`
  (`WASmaxOutMdRegularCompanionSetRegResponseBundleMixin`). There is a separate hosted-companion variant.
- `GetRef`: `<iq xmlns=md type=get><ref/></iq>` fetches a fresh companion ref on demand. It is used
  by the passkey ("Shortcake") flow.

**Phone-number pairing code** (`WAWebAltDeviceLinking*`, smax `MdCompanionHello` / `CompanionFinish`):
- `<link_code_companion_reg stage="companion_hello" should_show_push_notification>` with children:
  - `link_code_pairing_wrapped_companion_ephemeral_pub`
  - `companion_server_auth_key_pub`
  - `companion_platform_id`
  - `companion_platform_display`
  - `link_code_pairing_nonce`
  - the primary's `jid` **or** a contact point (`contact_point_type`, `contact_point_value`)
- The server notifies `primary_hello`:
  - `link_code_pairing_ref`
  - `link_code_pairing_wrapped_primary_ephemeral_pub`
  - `primary_identity_pub`
- The client finishes with `stage="companion_finish"` (`link_code_pairing_wrapped_key_bundle`,
  `companion_identity_public`, `link_code_pairing_ref`).
- **`refresh_code`** notification (`MdRefreshCodeNotifyCompanion`, attr `force_manual_refresh`) asks for
  a new code.
- `stage="get_country_code"` (`MdGetCountryCode`) prefills the phone UI.

**Passkey / "Shortcake" linking** (`WAWebShortcakeLinking*`):
- The server notifies `passkey_prologue_request` (with `passkey_request_options`, optional `dbsc_registration`).
- The client sends `<passkey_prologue><credential_id/><webauthn_assertion/><prologue_payload/>[<pairing_handoff_proof/>]</passkey_prologue>`.
- The server notifies `crsc_continuation` with `primary_ephemeral_identity`.
- The client sends `<companion_nonce>` and then `<encrypted_pairing_request>`.
- `GetPasskeyRequestOptions` = `<passkey_request_options/>`.
- Protobufs: `ProloguePayload`, `CompanionCommitment`, `CompanionEphemeralIdentity`,
  `PrimaryEphemeralIdentity`, `PairingRequest`, `EncryptedPairingRequest`.

**Other**:
- `companion_reg_refresh` notification (`WAWebHandleCompanionReqRefreshNotification`).
- Unpair: `WAWebUnpairDeviceJob` (hand-built `xmlns="md"`).
- `WAWebProtobufsCompanionReg.pb` also defines `ClientPairingProps{isChatDbLidMigrated,
  isSyncdPureLidSession, isSyncdSnapshotRecoveryEnabled, isHsThumbnailSyncEnabled,
  subscriptionSyncPayload, isBotJidDbMigrated}`.

#### 1.12 LID / PN mapping

- **Sources of mappings**:
  - `<success lid>`;
  - `<pair-success><device lid>`;
  - usync `lid` protocol and `contact addressing_mode="lid"`;
  - message and receipt attrs parsed in `WAWebHandleMsgParser`: `sender_lid`, `sender_pn`,
    `participant_pn`, `participant_lid`, `recipient_pn`, `recipient_lid`, `peer_recipient_pn`,
    `peer_recipient_lid`, `recipient_latest_lid`, `target_chat_jid_lid`;
  - group attrs `creator_pn`, `s_o_pn`, `requestor_pn`;
  - `contacts` notification `old_lid` / `new_lid` (`WAWebHandleContactNotification`);
  - MEX `LidChangeNotification` (`WAWebMexLidChangeNotificationHandler`, query `WAWebMexLidChangeNotificationQuery`).
- Storage: `WAWebDBCreateLidPnMappings`, `WAWebLidPnCache`,
  `WAWebCreateOrReplaceDisplayNamesAndLidPnMappingsJob`.
- There is a large migration subsystem (`WAWebLid1x1Migration*`, `WAWebLidMigration*`), and the
  ClientPayload carries `lidDbMigrated`.

#### 1.13 Request framework

- **`wap(tag, attrs, ...children)`** (`WAWap.wap`): hand-built nodes. Attr helpers: `CUSTOM_STRING`,
  `INT`, `LONG_INT`, `JID`, `USER_JID`, `DEVICE_JID`, `GROUP_JID`, `DOMAIN_JID`, `STANZA_ID`,
  `SMAX_ID`, `DROP_ATTR` (omit attr), `MAYBE_CUSTOM_STRING`, `BIG_ENDIAN_CONTENT`.
- **Sending**:
  - `WADeprecatedSendIq.deprecatedSendIq(iq, WADeprecatedWapParser)` → `WAComms._sendIq(iq, attachToSocket)`.
    An IQ that is not attached to a socket is **re-sent after reconnect**; `attachToSocket=true`
    fails on disconnect.
  - Parsed by `WAParseIqResponse`.
  - `deprecatedSendStanzaAndReturnAck` matches an `<ack>` by template.
- **WASmax**: generated code from a stanza schema ("smax").
  - `WASmaxOut<Family><Action>Request` builds the stanza with `WASmaxJsx.smax()` and `*Mixin` merges.
  - `WASmax<Family><Action>RPC.send<Action>RPC(args)` sends it via `WAComms.sendSmaxStanza` and tries
    every response parser.
  - `WASmaxIn<Family><Action>Response<Variant>` parses each response. On failure it throws
    `SmaxParsingFailure` ("Tried <response name=…>, but failed with …").
  - Server-initiated RPCs (`receive<X>RPC`) parse `<X>Request` and build the ack/response
    (`WASmaxOut…ResponseAck`).
  - Infrastructure: `WASmaxJsx`, `WASmaxMixins`, `WASmaxAttrs` (`OPTIONAL`, `OPTIONAL_LITERAL`,
    `OPTIONAL_CHILD`), `WASmaxChildren`, `WASmaxParseUtils`, `WASmaxParseJid`, `WASmaxParseReference`
    (checks response id = request id), `WASmaxParsingFailure`, `WASmaxMockRunner*` (tests),
    `WASmaxWasmMemoryManagement` (a WASM-backed variant exists).
- **MEX** (`WAWebMexClient` → `WAWebMexNativeClient` → `WAWebMexRelayEnvironment.sendMexIq`):
  ```
  <iq id to=s.whatsapp.net type="get" xmlns="w:mex"><query query_id="<doc id>">{"variables":{…}}</query></iq>
  ```
  - The reply is `<result>` with JSON content `{data, errors}`.
  - `errors[].extensions` = `{error_code, is_retryable, backoff_sec}` (`MexFatalExtensionError`).
  - The persisted query ids come from Relay `*.graphql` modules (`params.id`). The operation is chosen
    by `query_id` only; no query text is sent.
- **Incoming MEX notifications**: `<notification type="mex"><update op_name="…">JSON</update></notification>`
  (`WAWebHandleMexNotification`). Unknown `op_name` values are nacked.

#### 1.14 usync (`WAWebUsync*`)

```
<iq to=s.whatsapp.net xmlns="usync" type="get">
  <usync sid=<id> index="0" last="true" mode="query|full|delta…" context="interactive|background|message|voip|…">
    <query>…protocol query elements…</query>
    <list><user jid=… [pn_jid=…]>…per-user protocol elements…</user>…</list>
  </usync></iq>
```

| Protocol | Query element | Per-user element | Parsed result |
|---|---|---|---|
| `contact` | `<contact [addressing_mode="lid"]/>` | `<contact>+phone</contact>` / `<contact username pin lid/>` / `<contact type/>` | `type` (in/out), `username`, content |
| `devices` | `<devices version="2"/>` | `<devices device_hash ts expected_ts/>` | `device-list` (`is_hosted`, `key-index`), `key-index-list` (`ts`, `expected_ts`, signed bytes) |
| `lid` | `<lid/>` | `<lid jid/>` | `val` |
| `status` | `<status/>` | — | text, `t`, also `tctoken` |
| `text_status` | `<text_status/>` | — | `content`, `emoji`, `ephemeral_duration_sec`, `last_update_time` |
| `picture` | `<picture/>` | — | id |
| `business` | `<business><verified_name/></business>` | — | verified name |
| `disappearing_mode` | `<disappearing_mode/>` | — | `duration`, `t` |
| `feature` | `<feature>…</feature>` | — | flags (`encrypt*`, `document`, `voip`, `multi_agent`) |
| `bot` | `<bot><profile v="1"/></bot>` | `<bot><profile persona_id/></bot>` | bot profile (name, description, commands, prompts, …) |
| `username` | `<username/>` | `<username username/>` | username |

- Per-protocol `<error code text backoff>` results set a **per-protocol backoff**
  (`WAWebUsyncBackoff`). The backoff applies only to non-interactive contexts, except device queries
  in `message` and `voip` contexts.
- `<… refresh=N>` gives the refresh hints.
- A MEX alternative exists: `WAWebMexUsyncQuery` → `xwa2_fetch_wa_users` (about status, country code,
  orgs, username).


#### 1.15 WASmax outgoing requests / RPCs (139 RPC modules, 368 `WASmaxOut*` builders)

Grouped by xmlns. RPCs without xmlns are either non-IQ stanzas or server-initiated "receive" RPCs, where the server sends and the client parses and acks. Source: `smax_rpcs.json` / `smax_requests.json`.

| xmlns | stanza | # | RPCs | whatsmeow |
|---|---|---|---|---|
| `abt` | iq | 2 | AbPropsGetExperimentConfig, AbPropsGetGroupExperimentConfig | no |
| `blocklist` | iq | 2 | BlocklistsGetBlockList, BlocklistsUpdateBlockList | yes (user.go GetBlocklist / UpdateBlocklist) |
| `bot` | iq | 1 | BotBotList | yes (GetBotListV2) |
| `encrypt` | iq | 5 | PreKeysAdd, PreKeysDelete, PreKeysFetchKeyBundles, PreKeysFetchMissingPreKeys, PreKeysSet | yes (prekeys.go) |
| `fb:thrift_iq` | iq | 6 | BizAccessTokenRequestSilentNonce, BizCtwaAdAccountGetAccessTokenAndSessionCookies, BizCtwaAdAccountSendAccountRecoveryNonce, BizCtwaNativeAdUploadAdMedia, BizLinkingGetAccountNonce, BizLinkingGetLinkedAccounts | no for these ops (business.go uses `fb:thrift_iq` only for GetOrderDetails) |
| `md` | iq | 8 | MdCompanionFinish, MdCompanionHello, MdGetCountryCode, MdGetPasskeyRequestOptions, MdGetRef, MdSetCompanionNonce, MdSetEncryptedPairingRequest, MdSetPasskeyPrologue | yes (pair*.go) |
| `newsletter` | iq | 8 | NewslettersGetNewsletterMessageUpdates, NewslettersGetNewsletterMessages, NewslettersGetNewsletterResponses, NewslettersGetNewsletterStatusUpdates, NewslettersGetNewsletterStatuses, NewslettersMyAddOns, NewslettersStatusMyAddOns, NewslettersSubscribeToLiveUpdates | partial (newsletter.go: messages/updates/live updates) |
| `optoutlist` | iq | 2 | BlocklistsGetOptOutList, BlocklistsUpdateOptOutList | no |
| `passive` | iq | 2 | PassiveModeActiveIQ, PassiveModePassiveIQ | yes (SetPassive) |
| `privacy` | iq | 1 | PrivacyGetContactBlacklist | partial (privacysettings.go privacy settings; tctoken.go) |
| `privatestats` | iq | 1 | PrivatestatsSignCredential | no |
| `spam` | iq | 5 | SpamGroupReport, SpamIndividualReport, SpamNewsletterReport, SpamStatusReport, SpamStatusReportV2 | no |
| `tos` | iq | 4 | UserNoticeGetDisclosureStageByIds, UserNoticeGetDisclosures, UserNoticeSet, UserNoticeSetResult | partial (newsletter.go AcceptTOSNotice) |
| `urn:xmpp:whatsapp:account` | iq | 1 | AccountSetPaymentsTOSv3 | no |
| `urn:xmpp:whatsapp:push` | iq | 1 | PushConfigSet | yes (push.go) |
| `w:biz` | iq | 4 | BizMarketingMessageGetBusinessEligibility, BizSettingsGetPrivacySetting, BizSettingsSetPrivacySetting, SmbMeteredMessagingAccountGetSMBMeteredMessagingCheckout | no for these ops (user.go has the `business_profile` query) |
| `w:biz:msg_feedback` | iq | 1 | BizMsgUserFeedbackUpdatePreference | no |
| `w:comms` | iq | 1 | InAppCommsEvent | no |
| `w:comms:chat` | iq | 2 | PsaChatBlockGet, PsaChatBlockSet | no |
| `w:g2` | iq | 29 | GroupsAcceptGroupAdd, GroupsAcknowledgeGroup, GroupsAddParticipants, GroupsBatchGetGroupInfo, GroupsCancelGroupMembershipRequests, GroupsCreate, GroupsCreateSubGroupSuggestion, GroupsDeleteParentGroup, GroupsGetGroupInfo, GroupsGetGroupProfilePictures, GroupsGetInviteGroupInfo, GroupsGetLinkedGroup, GroupsGetLinkedGroupsParticipants, GroupsGetMembershipApprovalRequests, GroupsGetParticipatingGroups, GroupsGetReportedMessages, GroupsJoinLinkedGroup, GroupsLinkSubGroups, GroupsMembershipRequestsAction, GroupsPromoteDemoteAdmin, GroupsPromoteDemote, GroupsRemoveParticipants, GroupsReportMessages, GroupsRevokeRequestCode, GroupsSetDescription, GroupsSetProperty, GroupsSetSubject, GroupsSubGroupSuggestionsAction, GroupsUnlinkGroups | yes (group.go, most actions) |
| `w:pay` | iq | 3 | BrPaymentCreateCustomPaymentMethod, BrPaymentGetPixBankList, BrPaymentRemoveCustomPaymentMethod | no |
| `w:profile:picture` | iq | 1 | ProfilePictureGet | yes (GetProfilePictureInfo/SetGroupPhoto) |
| `w:stats` | iq | 1 | StatsSendBuffer | no |
| `waffle` | iq | 9 | WaffleEncryptedPayloadRequest, WaffleForceDeleteState, WaffleForceSuspendState, WaffleGenerateAccessTokens, WaffleGenerateWAEntACUser, WaffleGetCertificate, WaffleRefreshAccessTokens, WaffleStateExists, WaffleWFPing | no |
| `—` | ? | 26 | BizCtwaActionBannerSuggestion, BizCtwaAdAccountNonceNotification, BizSettingsSyncPrivacySetting, BizThreadDataNotifyBulk, BizThreadDataNotify, ChatstateServerNotification, ClientExpirationClientExpiration, CoexistenceOffboardingNotification, CoexistenceOnboardingStatusNotification, CoexistenceSyncNotification, GroupsGroupsDirtyNotification, MdPasskeyPrologueRequestNotification, MdPrimaryHelloNotifyCompanion, MdRefreshCodeNotifyCompanion, MdSetPrimaryEphemeralIdentityNotification, MessageDeliverNewsletter, NewslettersLiveUpdatesNotification, NotificationFallbackGenericNotification, PresenceServerUpdate, PsaResetSmbLastQpPrefetchTimestamp, QpSurfacesQPNotification, SmbMeteredMessagesCampaignBbProCampaignStatusNotification, SmbMeteredMessagesCampaignCampaignStateChangedNotification, StatusDeliverIncomingNewsletterStatus, StatusPublishPostBroadcastStatus, StatusPublishPostNewsletterStatus | see notes |
| `—` | call | 3 | VoipLinkCreate, VoipLinkQuery, VoipWaitingRoomToggleCallLink | no |
| `—` | chatstate | 1 | ChatstateClientNotification | yes |
| `—` | ib | 2 | OfflineBatch, UnifiedSessionShare | unified_session only |
| `—` | iq | 2 | MdSetReg, MdSetToCompanion | yes (pair-device/pair-success) |
| `—` | message | 1 | MessagePublishNewsletter | n/a |
| `—` | presence | 2 | PresenceAvailability, PresenceSubscribe | yes |
| `—` | receipt | 2 | MessageFallbackDeliver, ReceiptPublishView | yes |

Notes on the server-initiated ("?") RPCs. The client parses a `<X>Request` and replies with an ack or IQ result:
- `NotificationFallbackGenericNotification`
- `GroupsGroupsDirtyNotification`
- `ChatstateServerNotification`, `PresenceServerUpdate`
- `MdPrimaryHelloNotifyCompanion`, `MdRefreshCodeNotifyCompanion`, `MdPasskeyPrologueRequestNotification`,
  `MdSetPrimaryEphemeralIdentityNotification`
- `NewslettersLiveUpdatesNotification`, `MessageDeliverNewsletter`, `StatusDeliverIncomingNewsletterStatus`,
  `StatusPublishPostBroadcastStatus`, `StatusPublishPostNewsletterStatus`
- `ClientExpirationClientExpiration` (inside `<ib>`)
- `CoexistenceOnboardingStatus/Offboarding/SyncNotification`
- `BizThreadDataNotify(Bulk)`, `BizSettingsSyncPrivacySetting`, `BizCtwaAdAccountNonceNotification`,
  `BizCtwaActionBannerSuggestion`
- `QpSurfacesQPNotification`, `PsaResetSmbLastQpPrefetchTimestamp`
- `SmbMeteredMessagesCampaign*`
- `MessageFallbackDeliver` (receipt)
- `VoipLink*` (call-link `call` stanzas)

#### 1.16 WASmaxIn* incoming parser families (982 modules)

Grouped by family prefix. "Response" modules parse IQ replies to the outgoing RPCs above. "Request"
modules parse server-pushed stanzas. "Mixin" modules are shared attribute and child fragments.

| Family | # | What it parses |
|---|---|---|
| Groups | 300 | Replies for the 29 `w:g2` RPCs, with many error mixins (`GroupsIQError*`, `Participant*` conflict / not-authorized / limit, `SubGroup*` for communities, `Membership*`, `ParticipantPNMixin`, `GroupCreatorPhoneNumberMixin`, `SubjectOwnerPhoneNumberMixin`, `Username*`), plus `GroupsDirtyNotification` |
| Newsletters | 142 | Newsletter (channel) `newsletter` RPC replies: messages, message updates, statuses, responses, add-ons. Also `LiveUpdatesNotification`, question/response content, admin, paid-partnership, rate-limit and suspended/unauthorized errors |
| Status | 72 | `StatusDeliver*`: incoming E2EE status stanzas (enc type/version, sender-key bucket, fan-out count, mentions, edit/revoke/admin-revoke, reporting tokens, offline) and incoming newsletter statuses. `StatusPublish*`: acks and nacks for status publishing |
| Message | 72 | `MessageDeliver*`: newsletter message delivery (text/media/poll/quiz/reaction/question/edit/revoke/admin-profile, WAMO, paid partnership, AI-content meta, offline). `MessagePublish*`: ack / negative-ack / nack-retry / franking tag / paid-conversation acks for sent messages |
| Biz | 65 | `BizCtwa*` (ad account, native ad media), `BizSettings*` (privacy), `BizMarketing*`, `BizLinking*`, `BizThreadData*` |
| Pre (PreKeys) | 63 | `encrypt` RPC replies (add/delete/set/fetch bundles/fetch missing). Includes **PQ prekeys** (`PQKeyMixin`, `PQPreKeyContents`, `PQPreKeyListCountLow`), `BotIdentityKeyAuthMixin`, `NonE2EEAttestation`, `ForceOverrideE2EEState`, `Vname*` failures |
| Waffle | 50 | Account-linking / Accounts-Center (`waffle`) replies: certificate, access tokens, `WFPing`, encrypted payload, state |
| Blocklists | 46 | `blocklist` / `optoutlist` replies, with `addressing_mode` / mismatch variants (CAPI, migrated, force-migrated), username and guest entries |
| Md | 34 | Pairing (§1.11): `SetRegRequest` (pair-success), `SetToCompanionRequest` (pair-device), CompanionHello/Finish replies, PrimaryHello / RefreshCode / PasskeyPrologue / PrimaryEphemeralIdentity notifications, `DbscRegistrationMixin`, `AESEncryptionMetadataMixin`, country code |
| Br | 33 | Brazil payments (Pix bank list, custom payment methods) |
| Ab | 18 | `abt` experiment and group-experiment config replies (`ExperimentConfigMixin`, `SamplingConfigMixin`, retry/no-retry errors) |
| Smb | 17 | SMB metered messaging checkout, broadcast campaign status |
| Spam | 9 | `spam` report replies (`ReportIdMixin`, report-token validation error) |
| Privatestats | 9 | `privatestats` sign-credential (anonymous credential for private stats) |
| Chatstate | 9 | Server `<chatstate>`: composing/paused, from user or group, state source |
| Psa | 8 | `w:comms:chat` PSA chat block get/set |
| Presence | 8 | Server `<presence>`: available/unavailable, group, last-seen variants |
| Coexistence | 7 | SMB app ↔ Cloud API coexistence on/offboarding and sync notifications |
| User | 7 | `tos` user-notice errors and stage |
| Account | 4 | `urn:xmpp:whatsapp:account` (payments TOS v3) |
| Receipt | 4 | Receipt publish (view) success, deprecated edit |
| Pings | 2 | `w:p` server response (`t`) |
| Voip / Profile / App | 1 each | enums, `AppCommsEventRPC` (`w:comms`) |

#### 1.17 Hand-built IQs (outside WASmax): `xmlns` literals in WA* modules

| xmlns | Modules (hand-built `wap("iq",…)`) | whatsmeow |
|---|---|---|
| `usync` | `WAWebUsync` | yes (`user.go: usync`) |
| `w:mex` | `WAWebMexRelayEnvironment` | yes (`newsletter.go: sendMexIQ`) |
| `encrypt` | `WAWebUploadPreKeysJob`, `WAWebUploadPrekeysForRegTask`, `WAWebDigestKeyJob`, `WAWebRotateKeyJob`, `WAWebGetIdentityKeysJob` | yes (`prekeys.go`); digest/rotate partially |
| `privacy` | `WAWebQueryPrivacySettingsJob`, `WAWebSetPrivacyJob`, `WAWebSetReadReceiptJob`, `WAWebSetPrivacyTokensJob`, `WAWebQueryPrivacyDisallowedListPnJob` | yes (`privacysettings.go`, `tctoken.go`) |
| `disappearing_mode` | `WAWebQueryDisappearingModeJob`, `WAWebSetDisappearingModeJob` | set only (`SetDefaultDisappearingTimer`) |
| `status` | `WAWebSetAboutJob` | about text via MEX `UpdateTextStatus` (`SetStatusMessage`); `GetStatusPrivacy` |
| `w:g2` | `WAWebGroupExitJob`, `WAWebGroupInviteJob`, `WAWebQueryGroupInviteProfilePicApi` | yes |
| `w:profile:picture` | `WAWebSendProfilePictureJob`, `WAWebQueryGroupInviteProfilePicApi` | yes |
| `w:m` | `WAWebQueryMediaConnsJob` | yes (`mediaconn.go`) |
| `w:sync:app:state` | `WAWebSyncdRequestBuilderBuild` | yes (`appstate.go`) |
| `urn:xmpp:whatsapp:dirty` | `WAWebClearDirtyBitsJob` | function exists (`appstate.go: MarkNotDirty`) but is **never called** from `handleIB` |
| `urn:xmpp:whatsapp:push` | `WAWebGetPushServerSettingsJob`, `WAWebSetWindowsPushConfig` | yes (`push.go`) |
| `urn:xmpp:whatsapp:account` | `WAWebGdprHookUtils` | no |
| `w:biz` | `WAWebBusinessProfileJob`, `WAWebQueryBusinessProfileJob`, `WAWebHandleBusinessNameChange` | business_profile query only |
| `w:biz:catalog` | `WAWebQueryProductListCatalogJob`, `WAWebQueryGetSignedUserInfoJob` | no |
| `fb:thrift_iq` | `WAWebQueryBusinessCategoriesJob`, `WAWebQueryCtwaContextJob` | no (only orders) |
| `md` | `WAWebUnpairDeviceJob` (`<remove-companion-device jid reason>`) | yes (`client.go: Logout`, same `md` IQ) |
| `tos` | `WAWebTosJob` | partial |
| `urn:xmpp:ping` | incoming only (`WAWebHandleStanzaCommon`) | **not answered** |

Other namespaces seen only as literals:
- `fb:update` and `w:growth` are notification types.
- `w:gp2` is the group notification type.
- `w:biz:directory`, `fb:multiway` and `w:auth:backup:token` appear only in the token dictionary.

`w:qr` (whatsmeow's contact/business QR links) is **not** in the fetched bundle, so it may live in
an unfetched lazy chunk.

#### 1.18 MEX operations (78 persisted queries used through `WAWebMexClient`)

The doc id goes in `<query query_id=…>`. The root field is the top-level GraphQL field in the JSON reply.

| Operation (module minus `WAWebMex`) | kind | root field | doc id |
|---|---|---|---|
| FetchOHAIKeyConfigJobQuery | query | `xwa2_ohai_configurations` | 29366514836329275 |
| AcceptNewsletterAdminInviteJobMutation | mutation | `xwa2_newsletter_admin_invite_accept` | 9580828702035549 |
| CachedTokenJobMutation | mutation | `xwa2_ent_trade_canonical_nonce_for_access_tokens` | 27013462064904056 |
| ChangeNewsletterOwnerJobMutation | mutation | `xwa2_newsletter_change_owner` | 9546742745432473 |
| CreateEnforcementAppealJobMutation | mutation | `xwa2_create_enforcement_appeal` | 9848815108513025 |
| CreateInviteCodeJobMutation | mutation | `xwa2_growth_create_invite_code` | 28250338504572715 |
| CreateNewsletterAdminInviteJobMutation | mutation | `xwa2_newsletter_admin_invite_create` | 9387141988078609 |
| CreateNewsletterJobMutation | mutation | `xwa2_newsletter_create` | 25149874324715067 |
| CreateReportAppealJobMutation | mutation | `xwa2_create_channel_report_appeal_v2` | 27103316329328467 |
| DeleteNewsletterJobMutation | mutation | `xwa2_newsletter_delete_v2` | 30062808666639665 |
| DemoteNewsletterAdminJobMutation | mutation | `xwa2_newsletter_admin_demote` | 9880997548630971 |
| FetchAboutStatusJobQuery | query | `xwa2_users_updates_since` | 24535500086059408 |
| FetchAllNewslettersMetadataJobQuery | query | `xwa2_newsletter_subscribed` | 25399611239711790 |
| FetchAllSubgroupsJobQuery | query | `xwa2_group_query_by_id` | 9935467776504344 |
| FetchBotCertificateRevocationListQuery | query | `xwa2_fetch_feature_pki_crl` | 35807917542188393 |
| FetchGroupInfoIncludBotsJobAcp2Query | query | `xwa2_group_query_by_id` | 28036426022701940 |
| FetchGroupInfoIncludBotsJobQuery | query | `xwa2_group_query_by_id` | 27795062750123057 |
| FetchGroupInfoJobAcp2Query | query | `xwa2_group_query_by_id` | 38735621546085739 |
| FetchGroupInfoJobQuery | query | `xwa2_group_query_by_id` | 27508847222068472 |
| FetchGroupInviteCodeJobQuery | query | `xwa2_group_query_by_id` | 29247029834912157 |
| FetchGroupIsInternalJobQuery | query | `xwa2_group_query_by_id` | 34119218944390847 |
| FetchIntegritySignalsQuery | query | `xwa2_fetch_wa_users` | 26438847999065394 |
| FetchNewChatMessageCappingInfoJobQuery | query | `xwa2_message_capping_info` | 27910975521856601 |
| FetchNewsletterAdminCapabilitiesJobQuery | query | `xwa2_newsletter_admin` | 9801384413216421 |
| FetchNewsletterAdminInfoJobQuery | query | `xwa2_newsletter_admin` | 26278439461859188 |
| FetchNewsletterDehydratedJobQuery | query | `xwa2_newsletter` | 26944199458535748 |
| FetchNewsletterDirectoryCategoriesPreviewJobQuery | query | `xwa2_newsletters_directory_category_preview` | 35266481849605779 |
| FetchNewsletterDirectoryListJobQuery | query | `xwa2_newsletters_directory_list` | 26125047313831973 |
| FetchNewsletterDirectorySearchResultsJobQuery | query | `xwa2_newsletters_directory_search` | 26301059626252132 |
| FetchNewsletterEnforcementsJobQuery | query | `xwa2_channel_enforcements` | 27835373536068060 |
| FetchNewsletterFollowersJobQuery | query | `xwa2_newsletter_followers` | 27472091235714801 |
| FetchNewsletterInsightsJobQuery | query | `xwa2_newsletter_admin_insights` | 9853618868050977 |
| FetchNewsletterIsDomainPreviewableJobQuery | query | `xwa2_newsletter_message_integrity` | 9849510985088294 |
| FetchNewsletterJobQuery | query | `xwa2_newsletter` | 27456920720571478 |
| FetchNewsletterMessageReactionSenderListJobQuery | query | `xwa2_newsletters_reaction_sender_list` | 29575462448733991 |
| FetchNewsletterPendingInvitesJobQuery | query | `xwa2_newsletter_admin` | 28049623068067370 |
| FetchNewsletterPollVotersJobQuery | query | `xwa2_newsletters_poll_voter_list` | 9407762219322536 |
| FetchNewsletterReportsJobQuery | query | `xwa2_channels_reports` | 35936238352686172 |
| FetchPlaintextLinkPreviewJobQuery | query | `xwa2_newsletter_link_preview` | 9101130456653613 |
| FetchReachoutTimelockJobQuery | query | `xwa2_fetch_account_reachout_timelock` | 23983697327930364 |
| FetchRecommendedNewslettersJobQuery | query | `xwa2_newsletters_recommended` | 25806748772361516 |
| FetchSimilarNewslettersJobQuery | query | `xwa2_newsletters_similar` | 26217043484590756 |
| FetchSubgroupSuggestionsJobQuery | query | `xwa2_group_query_by_id` | 23972005349071865 |
| FetchTextStatusListJobQuery | query | `xwa2_text_status_list` | 24072923595647473 |
| GetDsbInfoJobMutation | mutation | `xwa2_get_dsb_info` | 9982897848413251 |
| GetPrivacyListsQuery | query | `xwa2_fetch_wa_users` | 26806428515612550 |
| GetPrivacySettingsQuery | query | `xwa2_fetch_wa_users` | 25637004609323493 |
| GetUsernameJobQuery | query | `xwa2_username_get` | 25347099718279209 |
| GetWoasAgeSignalQuery | query | `xwa2_fetch_wa_users` | 38845990424986108 |
| GroupStoreAndSendInviteSmsJobMutation | mutation | `xwa2_group_store_and_send_invites_sms` | 29313771494886407 |
| GroupStoreInviteSmsJobMutation | mutation | `xwa2_group_store_invites_sms` | 26810859745268181 |
| IntegrityChallengeResponseMutation | mutation | `xwa2_submit_integrity_challenge_response` | 26230331493320650 |
| JoinNewsletterJobMutation | mutation | `xwa2_newsletter_join_v2` | 24404358912487870 |
| LeaveNewsletterJobMutation | mutation | `xwa2_newsletter_leave_v2` | 9767147403369991 |
| LogNewsletterExposuresJobMutation | mutation | `xwa2_newsletter_log_exposures` | 25260800823586918 |
| LogServerSentInviteIntentJobMutation | mutation | `xwa2_growth_log_server_sent_invite_intent` | 28486062674347663 |
| NewsletterAddPaidPartnershipLabelJobMutation | mutation | `xwa2_newsletter_label_paid_partnership` | 26102375079404865 |
| NewsletterBlockUserJobMutation | mutation | `xwa2_newsletter_block_user` | 24021389470875463 |
| NewsletterLabelAiContentJobMutation | mutation | `xwa2_newsletter_label_ai_content` | 27909718265289596 |
| NewsletterPinMessagesJobMutation | mutation | `xwa2_newsletter_pin_messages` | 27165709459706559 |
| NewsletterQuestionResponseStateUpdateJobMutation | mutation | `xwa2_newsletter_question_response_state_update` | 24636260219323456 |
| NewsletterUnpinMessagesJobMutation | mutation | `xwa2_newsletter_unpin_messages` | 28007176042216937 |
| PaymentsPasskeyHasCredentialJobQuery | query | `xwa2_payments_passkey_has_credential` | 36878915648418618 |
| QuerySubgroupParticipantCountJobQuery | query | `xwa2_group_query_by_id` | 24079399904996141 |
| RequestClientLogsForBugJobMutation | mutation | `xwa2_request_client_logs_for_bug` | 27135500612803533 |
| RequestOTEJobMutation | mutation | `xwa2_ncm_request_ote` | 35108428002105570 |
| RevokeNewsletterAdminInviteJobMutation | mutation | `xwa2_newsletter_admin_invite_revoke` | 9656078347839416 |
| SetUsernameJobMutation | mutation | `xwa2_username_set` | 25757341163897635 |
| SetUsernameKeyJobMutation | mutation | `xwa2_username_pin_set` | 9749436995157074 |
| TransferCommunityOwnershipJobMutation | mutation | `xwa2_group_update_users_role` | 29643783178598899 |
| UpdateGroupPropertyJobMutation | mutation | `xwa2_group_update_property` | 9418211574894172 |
| UpdateNewsletterAdminProfileJobMutation | mutation | `xwa2_newsletter_admin_profile_update` | 27871895895845117 |
| UpdateNewsletterAdminProfileSettingJobMutation | mutation | `xwa2_newsletter_update` | 28226671310350649 |
| UpdateNewsletterJobMutation | mutation | `xwa2_newsletter_update` | 24250201037901610 |
| UpdateNewsletterUserSettingJobMutation | mutation | `xwa2_newsletter_update_user_setting` | 31938993655691868 |
| UpdateTextStatusJobMutation | mutation | `xwa2_update_text_status` | 9152604461510864 |
| UsernameAvailabilityQuery | query | `xwa2_username_check` | 26122779627399568 |
| UsyncQuery | query | `xwa2_fetch_wa_users` | 28496738596651319 |

MEX notification `op_name`s handled by Web (`WAWebHandleMexNotification`), 46 in total:
- **Newsletter (17)**: `NotificationNewsletterJoin`, `…Leave`, `…UserSettingChange`, `…StateChange`,
  `…AdminProfileUpdate`, `…AdminMetadataUpdate`, `…OwnerUpdate`, `…Update`, `…AdminPromote`,
  `…AdminDemote`, `…AdminInviteRevoke`, `…WamoSubStatusChange`, `…BlockUser`,
  `…PaidPartnershipUpdate`, `…AIContentUpdate`, `…Milestone`, `NewsletterResponseStateUpdate`.
- **Group (7)**: `NotificationGroupPropertyUpdate`, `…HiddenPropertyUpdate`, `…SafetyCheckPropertyUpdate`,
  `…MemberLinkPropertyUpdate`, `…MemberShareGroupHistoryModePropertyUpdate`,
  `…LimitSharingPropertyUpdate`, `NotificationGroupAppealStatusUpdate`.
- **Community and org (2)**: `NotificationCommunityOwnerUpdate`, `NotificationOrgMemberUpdate`.
- **Identity (5)**: `LidChangeNotification`, `UsernameSetNotification`, `UsernameUpdateNotification`,
  `UsernameDeleteNotification`, `AccountSyncUsernameNotification`.
- **Text status (2)**: `TextStatusUpdateNotification`, `TextStatusUpdateNotificationSideSub`.
- **Events (6)**: `NotificationEventInvite`, `…InviteRemove`, `…Update`, `…Delete`, `…Rsvp`, `…Reminder`.
- **Scheduled messages (2)**: `NotificationScheduledMessagePost`, `NotificationScheduledMessageReveal`.
- **Integrity and limits (4)**: `NotificationIntegrityChallengeRequest`, `NotificationUserBrigadingUpdate`,
  `NotificationUserReachoutTimelockUpdate`, `MessageCappingInfoNotification`.
- **Generic (1)**: `MexNotificationEvent`.

`NotificationLinkedProfilesUpdates(SideSub)` and `NotificationAgeCollection` are deliberately
unsupported.

#### 1.19 Top-level stanza dispatch (`WAWebCommsHandleStanza`, `…LoggedInStanza`, `…WorkerCompatibleStanza`)

- **Top-level tags**: `iq` (ping, md pair-device / pair-success), `message`, `receipt`, `notification`,
  `call`, `presence`, `chatstate`, `ack`, `ib`, `success`, `failure`, `stream:error`, `xmlstreamend`.
- **Notification `type`s**:
  - Core: `server_sync`, `picture`, `contacts` (except `invite`), `devices`, `disappearing_mode`,
    `mediaretry`, `encrypt` (`count`, `pq_count`, `digest`), `server`, `status`, `account_sync`,
    `privacy_token`, `newsletter`, `mex`, `w:gp2`, `identity`.
  - Business, payments and promos: `business`, `digital_commerce_subscription`, `pay`, `psa`
    (`surfaces`, `reset_smb_last_qp_prefetch_timestamp`, WA chat), `biz_thread_data(_bulk)`.
  - Pairing and devices: `link_code_companion_reg`, `companion_reg_refresh`, `passkey_prologue_request`,
    `crsc_continuation`, `registration` (device switching), `hosted`.
  - Other: `w:growth`, `waffle` (account linking), `fb:update` (bot profile).
- Any stanza with an `offline` attr feeds the offline-resume counters.

---

### 2. whatsmeow coverage

#### 2.1 What matches

- **Socket and framing**:
  - `socket/constants.go`: URL `wss://web.whatsapp.com/ws/chat`, `Origin: https://web.whatsapp.com`,
    `WAConnHeader = {'W','A',6,token.DictVersion}`, 3-byte frame length, max `1<<24`.
  - `binary/unpack.go` handles the zlib flag bit 2.
- **Noise XX** (`handshake.go: doHandshake`, `socket/noisehandshake.go`, `noisesocket.go`): same
  pattern string, prologue = header, HKDF and AES-GCM counter IV. Cert verification uses the same root
  key (`WACertPubKey` = `142375…ee6b`, serial 0) and checks issuer serials and the leaf key.
- **Token dictionary**: `binary/token/token.go` `DictVersion = 3`. `SingleByteTokens[1:]` and the 4
  double-byte dictionaries are **identical** to `WAWapDict` (verified programmatically). whatsmeow
  index 0 is `""`.
- **JID encodings**: AD_JID / JID_U with domain 0/1/128/129, FB_JID (`msgr`), INTEROP_JID (with
  `Integrator`), JID_PAIR, `hosted`, `hosted.lid` and `bot` servers are all present
  (`types/jid.go`, `binary/encoder.go`, `binary/decoder.go`).
- **Wa6 protobuf**: field-by-field diff of `WAWebProtobufsWa6.pb` (ClientPayload, UserAgent, WebInfo,
  DNSSource, InteropData, DevicePairingRegistrationData, HandshakeMessage) against
  `proto/waWa6/WAWebProtobufsWa6.proto` shows **no missing fields or numbers**. The only differences
  are Go-side name casing (`sessionID`/`sessionId`, `eSkeyID`, `phoneID`).
- **ClientPayload values** (`store/clientpayload.go: BaseClientPayload`): `Platform=WEB`,
  `ReleaseChannel=RELEASE`, `mcc/mnc "000"`, `osVersion "0.1"`, `manufacturer ""`, `device "Desktop"`,
  `osBuildNumber "0.1"`, `en/US`, `WebSubPlatform=WEB_BROWSER`, `WIFI_UNKNOWN`, `USER_ACTIVATED`. These
  match Web's `WAWebDeviceInfoBridgeApi` defaults exactly. The registration payload (`getRegistrationPayload`)
  matches too: BuildHash = md5 of the version string, eSkeyId 3 bytes, eKeytype 5.
- **Login payload** (`getLoginPayload`): `Passive=true`, `Pull=true`, `LidDbMigrated=true`, `Lc=1`.
  whatsmeow then sends `<iq xmlns=passive><active/>` (`connectionevents.go: SetPassive(false)`) after
  checking the prekey count. This is functionally the same as Web's passive-task model.
- **Pairing**:
  - QR (`pair.go: handlePairDevice`, `makeQRData`): same `wa.me/settings/linked_devices#ref,noise,identity,adv,platform`
    format; Web shows the prefix only behind a knob.
  - `pair-success` → `pair-device-sign` with `device-identity key-index`.
  - Phone code (`pair-code.go: PairPhone`, `handleCodePairNotification`): same companion_hello and
    companion_finish children.
  - Passkey (`pair-passkey.go`): `passkey_prologue`, `crsc_continuation`, `companion_nonce`,
    `encrypted_pairing_request`, `GetRef`, `passkey_request_options`.
  - `companion_reg_refresh` notification.
- **Keepalive** (`keepalive.go`): `w:p` ping.
- **Request ids**: `uniqueID + counter`, same shape as Web's `<rand>.<rand>-<n>`.
- **IQ helper**: `request.go: sendIQ`, default timeout 75 s, `retryFrame` on reconnect.
- **Stream errors** (`connectionevents.go: handleStreamError`): 515 reconnect, `401` +
  `conflict device_removed` logout, `conflict replaced` → `StreamReplaced`, 503, CAT refresh codes.
- **Failure** (`handleConnectFailure`): 401/403/406 (logged out), 402 temp-ban (`code`, `expire`),
  405 outdated, 5xx reconnect, `logout_message_header` / `logout_message_subtext` logged.
- **`<ib>`** (`handleIB`): `offline_preview` (incl. `appdata`), `offline` → `OfflineSyncCompleted`,
  `downgrade_webclient`.
- **usync** (`user.go: usync`): `contact addressing_mode=lid`, `business/verified_name`,
  `disappearing_mode`, `username`, `status`, `picture`, `devices version=2`, `lid`, `bot profile`.
  The contexts used are `interactive`, `background` and `message`.
- **MEX** (`newsletter.go: sendMexIQ`): same `<query query_id>{"variables":…}` shape. It is used for
  newsletters and `mutationUpdateTextStatus` (`user.go: SetStatusMessage`, doc id `9152604461510864`,
  which **matches Web's current id**).
- **Push** (`push.go`): `urn:xmpp:whatsapp:push` with `gcm`, `apple` and `web` platforms.
- **App state**: dirty `MarkNotDirty` helper exists in `appstate.go`.

#### 2.2 What differs or is missing

| Area | Web | whatsmeow | Note |
|---|---|---|---|
| Version | `2.3000.1051067427` (this bundle) | `store.waVersion = 2.3000.1050728964` (hard-coded; `SetWAVersion` exists) | A few days stale. Web's version comes from `SiteData.client_revision` on the live page. A 405 `CLIENT_TOO_OLD` failure is the symptom |
| Socket endpoints | Races `:443` and `:5222` and adds `?ED=` | Single URL, no `ED` | `socket/framesocket.go` |
| Edge routing | `<ib><edge_routing>` stored and replayed as `ED` pre-intro + `?ED=` | Ignored (not in `handleIB`) | Likely affects which edge or region you land on (inferred) |
| Resume handshake | Noise **IK** with cached server static (one round trip fewer) + **XXfallback** | XX only | Not required: the server still accepts XX |
| Keepalive | Ping every 15–30 s, **only when idle**; 20 s dead-socket timer after any request; ping `t` → clock skew | Ping every 20–30 s always, 10 s deadline, forced reconnect after 3 min failing | Equivalent enough; whatsmeow takes clock skew from `<success t>` only |
| Server ping | Replies to `<iq xmlns="urn:xmpp:ping">` | `pair.go: handleIQ` drops it (only pair-device / pair-success) | (inferred) rarely sent, but an unanswered ping may get the session dropped |
| `pull` / offline batches | `pull=true` + `<ib><offline_batch count=200…/>` as the queue drains | Sends `Pull=true` but **never sends `offline_batch`** | Needs verification: if the server waits for batch requests, large offline backlogs could stall after the first batch (inferred) |
| `<ib>` children | `dirty`, `edge_routing`, `offline`, `offline_preview`, `priority_offline_complete`, `tos`, `thread_metadata`, `client_expiration`, `recovery_nonce` | `offline`, `offline_preview`, `downgrade_webclient`; `dirty` is a commented-out no-op | Missing: dirty handling, `client_expiration`, `tos`, `thread_metadata`, `priority_offline_complete` |
| Dirty bits | Refetch per type (groups, account_sync{devices, picture, privacy, blocklist, notice}, syncd_app_state, newsletter_metadata, orgs), then `<clean>` | Ignored, so never cleaned | Server keeps re-flagging (inferred). State can go stale after long offline periods |
| Stream error 516 | Forced logout | Falls to `default` → `events.StreamError` | Treat as logout |
| `conflict` types | `replaced`; *any other* type = device removed (logout) | Only `device_removed` with code 401 is logout | Edge case |
| `<success>` attrs | `t`, `lid`, `display_name`, `companion_enc_static`, `abprops`, `group_abprops` | `t`, `lid` | `companion_enc_static` is Web-DB-specific; abprops are not used |
| ClientPayload extras | `pushName`, `connectAttemptCount`, real `lc`, real `lidDbMigrated` | None of these; `lc=1`, `lidDbMigrated=true` | Low risk |
| DeviceProps proto | HistorySyncConfig fields 25–27 `supportNewsletter`, `supportUniversalReachChat`, `supportOmittedConversationIndex`; PlatformType 25–30 (`WAIL`, `WASS`, `BUSINESS_BACK_OFFICE`, `WAIL_WAI`, `WAIL_ALEXA`, `AUTOMOTIVE`); `ClientPairingProps.isBotJidDbMigrated=6` | Missing in `proto/waCompanionReg/WACompanionReg.proto` (stops at 24 / SMARTGLASSES=24 / field 5) | Regenerate protos. Web does not set the new history-sync flags in this build, so they do not matter for the payload today |
| DeviceProps values | `os=<browser>`, `platformType=CHROME/…/DESKTOP` | `os="whatsmeow"`, `platformType=UNKNOWN`, `storageQuotaMb 10240`, `thumbnailSyncDaysLimit 60` | Set via `store.SetOSInfo` / `DeviceProps` before pairing (shows as the device name on the phone) |
| Pairing extras | `refresh_code` notification (`force_manual_refresh`), `get_country_code`, `contact_point_*` pairing, `key_attestation` / `gpia` / `client-app-id` in `pair-device-sign`, `encryption-metadata` + `companion_recovery_server_token` in `pair-success` | None of these | Only `refresh_code` matters for the phone-code UX |
| usync | Adds `text_status` and `feature` protocols, `pn_jid` on `<user>`, per-protocol `error backoff` + `refresh` | No `text_status` / `feature`, no backoff tracking | MEX `xwa2_fetch_wa_users` also exists |
| MEX coverage | 78 operations (see 1.18); 46 notification `op_name`s | About 12 newsletter doc ids + UpdateTextStatus; 5 notification roots (`xwa2_notify_newsletter_on_join/leave/mute_change/milestone`, `xwa2_notify_account_reachout_timelock`) | **Newsletter doc ids differ from Web's current ones**. Examples: fetch newsletter `6563316087068696` vs Web `27456920720571478`; create `6234210096708695` vs `25149874324715067`; join/leave map to Web's `xwa2_newsletter_join_v2` / `leave_v2` ids `24404358912487870` / `9767147403369991`. Old persisted ids still work today (inferred, since whatsmeow users use them) but may be retired |
| MEX notifications | `LidChangeNotification`, username set/update/delete, group property updates, text status updates, events, scheduled messages … | Not dispatched (silently dropped after JSON decode) | LID change matters most |
| `convertQueryID` | — | Compares `payload.GetUserAgent().Platform == waWa6.ClientPayload_UserAgent_MACOS.Enum()`: **pointer equality, always false** | So the "desktop" ids are only chosen when `WebInfo==nil`. Small bug |
| Namespaces | `abt`, `privatestats`, `w:stats`, `spam`, `optoutlist`, `waffle`, `w:comms`, `w:comms:chat`, `w:pay`, `urn:xmpp:whatsapp:account`, `w:biz:catalog`, `w:biz:msg_feedback`, Biz `fb:thrift_iq` ops | Absent | Mostly telemetry, business or payments |
| Notification types | Also `business`, `contacts` (`old_lid` / `new_lid`), `disappearing_mode`, `hosted`, `psa`, `registration`, `pay`, `waffle`, `w:growth`, `fb:update`, `digital_commerce_subscription`, `biz_thread_data`, `server` | `notification.go: handleNotification` covers encrypt, server_sync, account_sync, devices, fbid:devices, w:gp2, picture, mediaretry, privacy_token, link_code_companion_reg, newsletter, mex, status, passkey_prologue_request, crsc_continuation, companion_reg_refresh | `contacts` / LID change and `disappearing_mode` are the relevant gaps |
| LID attrs | Also `recipient_latest_lid`, `target_chat_jid_lid` | Not parsed | See the messaging section |
| PQ prekeys | Passive tasks `PQKeyUpload`, `PQKeyRollback`; `pq_count` notification | Not present | Belongs to the crypto section; watch it |
| `call` JID domain | `WAJids` `@call` / `WAWap.CALL` (call links) | No `call` server constant | Niche |

---

### 3. Gaps that matter for a desktop client (QWhats native)

| # | Gap | Priority | What closing it needs |
|---|---|---|---|
| 1 | **Version currency.** Fetch `client_revision` (or the version JSON) from `web.whatsapp.com` at startup and call `store.SetWAVersion`, so a 405 never happens | P1 | Client logic (HTTP fetch + `SetWAVersion`) |
| 2 | **Dirty bits.** Handle `<ib><dirty>`: groups → refetch participating groups; `account_sync` → devices / picture / privacy / blocklist; `syncd_app_state` → full app-state sync; `newsletter_metadata` → refetch subscribed. Then call the existing `MarkNotDirty` | P1 | Client logic (whatsmeow's `IB` hook or a fork patch; `MarkNotDirty` exists) |
| 3 | **Offline pull batching.** Confirm whether the server needs `<ib><offline_batch count/>` when `pull=true`. If yes, send it (Web: 200, adaptive down to 10) or connect with `pull=false` | P1 (verify first) | Custom stanza (`ib` / `offline_batch`) or a payload tweak |
| 4 | **LID change and contact LID notifications.** MEX `LidChangeNotification` and `contacts` `old_lid` / `new_lid` → update the LID↔PN store; username notifications | P1 | Client logic: parse MEX JSON from the raw node (whatsmeow drops it) or patch `handleMexNotification` |
| 5 | **Stream error 516 and unknown `conflict` types** → treat as logged out and show a re-link UI | P1 | Client logic on `events.StreamError` |
| 6 | **Answer server `urn:xmpp:ping`** with `<iq type=result id to>` | P2 | Custom stanza (tiny patch to `handleIQ`) |
| 7 | **Phone-code `refresh_code` notification** → regenerate and redisplay the code | P2 | Client logic + `PairPhone` re-call |
| 8 | **Edge routing** (`ED` pre-intro + `?ED=`) and the `:5222` fallback URL for networks that block or interfere with :443 | P2 | Socket-level patch (frame header prefix, URL list) |
| 9 | **MEX doc-id refresh** for newsletters (and new ops a desktop UI needs: directory, followers, reactions sender list, poll voters, pin/unpin, text-status list, username get/set, group property update) | P2 | Doc ids from this bundle (§1.18); JSON variables |
| 10 | **usync `text_status` and per-protocol backoff** (respect `<error backoff>` for background usync) | P2 | Custom usync protocol node + client logic |
| 11 | **DeviceProps.** Set `os` / `platformType` to something sensible (for example `os="QWhats"`, `platformType=DESKTOP`) so the phone shows a proper device name. Regenerate `waCompanionReg` protos for the new fields | P2 | Protobuf fields + config |
| 12 | **AB props (`abt`)**: needed only if we gate features on server experiments | P3 | Custom IQ (smax shape in §1.10) |
| 13 | IK resume handshake (faster reconnect), `<success>` `display_name`, ClientPayload `pushName` / `connectAttemptCount` / `lc` | P3 | Socket patch / payload fields |
| 14 | `client_expiration`, `tos`, `thread_metadata`, `recovery_nonce` ib children | P3 | Client logic |
| 15 | Telemetry and business namespaces (`privatestats`, `w:stats`, `spam` reporting, `waffle`, `w:pay`, `fb:thrift_iq` CTWA, coexistence) | P3 | Not needed. `spam` report (P2 for a "Report" button) is a smax IQ |
| 16 | PQ prekey upload (`PQKeyUpload`, `pq_count`) | P2 (watch) | Crypto / protobuf work; see crypto section |

---

## 02 — Protobuf schemas in WhatsApp Web (rev 1051067427) vs whatsmeow

Tools: `tools/pbdump.py` (extracts every spec from the `*.pb` modules into `proto_dump.json`),
`tools/pbdiff.py` (diffs that dump against whatsmeow's `.proto` files compiled with `protoc`
into `tools/out/whatsmeow.desc`; result in `tools/out/pbdiff.json`).
Totals: **47 `.pb` modules, 942 message types, 249 enums**, 0 unresolved type references.

### 1. What WhatsApp Web does

#### 1.1 Spec encoding (how the minified modules represent .proto)

Every schema lives in a module named `<Something>.pb` that depends on `WAProtoConst` (+ `$InternalEnum`
and other `.pb` modules it imports). There are no generated classes. Each message type is an empty object
with two properties, and the generic codec (`encodeProtobuf`, `decodeProtobuf`, `WAProtoCompile.compileSpec`)
interprets them at runtime:

```
Ue.name="Message",
Ue.internalSpec={conversation:[1,(e=o("WAProtoConst")).TYPES.STRING],
                 imageMessage:[3,e.TYPES.MESSAGE,ao], ...,
                 __oneofs__:{header:["text","documentMessage",...]}}
Vt.internalDefaults={version:1}
```

* `name` is the full type name; `$` separates nesting levels (`Message$ProtocolMessage$Type`).
* `internalSpec` maps each **field name** to `[fieldNumber, FLAGS|TYPE, ref?]`.
  * `WAProtoConst.TYPES`: INT32 1, INT64 2, UINT32 3, UINT64 4, SINT32 5, SINT64 6, BOOL 7, ENUM 8, FIXED64 9,
    SFIXED64 10, DOUBLE 11, STRING 12, BYTES 13, MESSAGE 14, FIXED32 15, SFIXED32 16, FLOAT 17, MAP 18 (`TYPE_MASK=31`).
  * `WAProtoConst.FLAGS`: REPEATED 64, PACKED 128, REQUIRED 256, OR-ed into the type (`e.FLAGS.REPEATED|e.TYPES.MESSAGE`).
  * `ref` is the local variable of the message or enum, or a cross-module reference such as
    `o("WAWebProtobufsProtocol.pb").MessageKeySpec`. Often the module is aliased first with
    `(s=o("X.pb"))` and then used as `s.MessageKeySpec`.
  * A map field is `[num, TYPES.MAP, [keyType, valueType, valueRef?]]`. Only one occurs, in `SyncActionValue$MusicUserIdAction.music_user_id_map`.
  * `__oneofs__:{group:[fieldNames]}` declares oneofs. A `__reserved__` key (`tags`/`fields`) is supported by
    `WAProtoConst.KEYS` but is not used in any current module.
* `internalDefaults={field:value}` holds proto2 defaults.
* Enums are either `n("$InternalEnum")({A:0,B:1})` (WAWeb* modules) or plain object literals `{A:0,...}`
  (WAArmadillo*/WAConsumerApplication). Minified numbers such as `1e3` occur. Negative values exist, e.g.
  `PAYMENT_UNKNOWN:-1`.
* Exports are `l.<Name>Spec = var` for messages (`l.Message$ImageMessageSpec=ao`) and `l.<Name> = var` for enums
  (`l.Message$ProtocolMessage$Type=...`). Armadillo/ConsumerApplication enums are exported as SCREAMING_CASE
  (`ARMADILLO_CONTENT_PAYMENTS_TRANSACTION_MESSAGE_PAYMENT_STATUS`).
* The only non-`.pb` module that reads `internalSpec` is `WAProtoCompile`.

**Unknown fields.** `decodeProtobuf` counts every unknown tag in `$$unknownFieldCount`. When a flag is set it also keeps
the raw values in `$$unsafeUnknownFields`. `WAWebVerifyProtobufMsgObjectKeys` maps a non-zero
`$$unknownFieldCount` on the `Message` to `MSG_TYPE.UNKNOWN`. Such messages are stored with the original plaintext
(`MsgOpaqueData.futureproofBuffer` #14, `WebMessageInfo.futureproofData` #43). After an app update,
`WAWebFutureproofReparseMsgsAction` re-runs `processDecryptedMessageProto` on that buffer. This is how Web turns
"unsupported message" bubbles into real messages later.

#### 1.2 The `.pb` modules

The schema-bearing modules are listed below. "Top-level" means types without `$`; everything else is nested.

| Module | top-level msgs | all msgs | enums | top-level message types |
|---|---|---|---|---|
| `EBMinosWasm.pb` | 87 | 97 | 0 | DecryptMekForDistributionFromTransportSenderInput, DecryptMekForDistributionFromTransportSenderResult, DecryptMekForDistributionFromTransportSenderSuccess, DecryptMekForDistributionInput, DecryptMekForDistributionResult, DecryptMekForDistributionSuccess, DecryptSelfMmkDistributionInput, … (+80) |
| `VestaWasm.pb` | 14 | 14 | 0 | BeginLoginRequest, BeginLoginResponse, BeginRegisterRequest, BeginRegisterResponse, CliCommand, CliResponse, FinishLoginRequest, … (+7) |
| `WAArmadilloApplication.pb` | 1 | 33 | 8 | Armadillo |
| `WAArmadilloBackupCommon.pb` | 3 | 3 | 0 | FrankingMetadata, Metadata, Subprotocol |
| `WAArmadilloBackupMessage.pb` | 1 | 1 | 0 | BackupMessage |
| `WAArmadilloLocallyTransformedMessage.pb` | 1 | 2 | 0 | LocallyTransformedMessage |
| `WAArmadilloMiTransportAdminMessage.pb` | 1 | 44 | 6 | MiTransportAdminMessage |
| `WAArmadilloTransportEvent.pb` | 1 | 5 | 3 | TransportEvent |
| `WAArmadilloXMA.pb` | 1 | 2 | 5 | ExtendedContentMessage |
| `WACert.pb` | 2 | 5 | 0 | CertChain, NoiseCertificate |
| `WACommon.pb` | 5 | 5 | 3 | Command, Mention, MessageKey, MessageText, SubProtocol |
| `WAConsumerApplication.pb` | 1 | 33 | 3 | ConsumerApplication |
| `WAFingerprint.pb` | 2 | 2 | 1 | CombinedFingerprint, FingerprintData |
| `WAMediaEntryData.pb` | 1 | 3 | 0 | MediaEntry |
| `WAMediaTransport.pb` | 7 | 25 | 4 | AudioTransport, ContactTransport, DocumentTransport, ImageTransport, StickerTransport, VideoTransport, WAMediaTransport |
| `WAMsgApplication.pb` | 1 | 10 | 2 | MessageApplication |
| `WASignalLocalStorageProtocol.pb` | 7 | 15 | 0 | IdentityKeyPairStructure, PreKeyRecordStructure, RecordStructure, SenderKeyRecordStructure, SenderKeyStateStructure, SessionStructure, SignedPreKeyRecordStructure |
| `WASignalWhisperTextProtocol.pb` | 6 | 6 | 0 | DeviceConsistencyCodeMessage, KeyExchangeMessage, PreKeySignalMessage, SenderKeyDistributionMessage, SenderKeyMessage, SignalMessage |
| `WAWebLabyrinthWaWasm.pb` | 40 | 40 | 0 | AddDeviceKeysOutput, AddDeviceSyncEpochInput, BackwardEdge, ComputeClientSealTokenInput, ComputeClientSealTokenOutput, CreateBackupInput, CreateBackupOutput, … (+33) |
| `WAWebProtobufSyncAction.pb` | 5 | 105 | 30 | CallLogRecord, PatchDebugData, RecentEmojiWeight, SyncActionData, SyncActionValue |
| `WAWebProtobufsAICommon.pb` | 56 | 83 | 34 | AIHomeState, AIMediaCollectionMessage, AIMediaCollectionMetadata, AIMetadataOperation, AIProvenance, AIRegenerateMetadata, AIRichResponseUnifiedResponse, … (+49) |
| `WAWebProtobufsAICommonDeprecated.pb` | 10 | 16 | 6 | AIRichResponseCodeMetadata, AIRichResponseContentItemsMetadata, AIRichResponseDynamicMetadata, AIRichResponseGridImageMetadata, AIRichResponseImageURL, AIRichResponseInlineImageMetadata, AIRichResponseLatexMetadata, … (+3) |
| `WAWebProtobufsAdv.pb` | 5 | 5 | 1 | ADVDeviceIdentity, ADVKeyIndexList, ADVSignedDeviceIdentity, ADVSignedDeviceIdentityHMAC, ADVSignedKeyIndexList |
| `WAWebProtobufsAea.pb` | 1 | 1 | 1 | NonE2EEAttestation |
| `WAWebProtobufsChatLockSettings.pb` | 1 | 1 | 0 | ChatLockSettings |
| `WAWebProtobufsCompanionReg.pb` | 8 | 10 | 1 | ClientPairingProps, CompanionCommitment, CompanionEphemeralIdentity, DeviceProps, EncryptedPairingRequest, PairingRequest, PrimaryEphemeralIdentity, ProloguePayload |
| `WAWebProtobufsDeviceCapabilities.pb` | 1 | 11 | 4 | DeviceCapabilities |
| `WAWebProtobufsE2E.pb` | 31 | 236 | 84 | AIQueryFanout, AIRichResponseMessage, ActionLink, ContextInfo, DeviceListMetadata, DisappearingMode, EmbeddedContent, … (+24) |
| `WAWebProtobufsEphemeral.pb` | 1 | 1 | 0 | EphemeralSetting |
| `WAWebProtobufsFingerprintV3.pb` | 2 | 2 | 1 | CombinedFingerprint, FingerprintData |
| `WAWebProtobufsGroupHistory.pb` | 5 | 5 | 0 | GroupHistory, GroupHistoryWithMessageBytes, UnCountedAssociatedMessageList, UnCountedAssociatedMessageListWithMessageBytes, WebMessageInfoWithMessageBytes |
| `WAWebProtobufsHistorySync.pb` | 18 | 18 | 8 | Account, AutoDownloadSettings, AvatarUserSettings, Conversation, GlobalSettings, GroupParticipant, HistorySync, … (+11) |
| `WAWebProtobufsMdStorageAccountLinkingOpaqueData.pb` | 1 | 1 | 0 | AccountLinkingOpaqueData |
| `WAWebProtobufsMdStorageChatRowOpaqueData.pb` | 1 | 4 | 1 | ChatRowOpaqueData |
| `WAWebProtobufsMdStorageMsgRowOpaqueData.pb` | 3 | 8 | 2 | MsgOpaqueData, MsgRowOpaqueData, PollEncValue |
| `WAWebProtobufsMmsRetry.pb` | 2 | 2 | 1 | MediaRetryNotification, ServerErrorReceipt |
| `WAWebProtobufsProtocol.pb` | 3 | 3 | 1 | ACP2Setting, LimitSharing, MessageKey |
| `WAWebProtobufsQuickPromotionSurfaces.pb` | 1 | 4 | 3 | QP |
| `WAWebProtobufsReporting.pb` | 3 | 3 | 0 | Config, Field, Reportable |
| `WAWebProtobufsRoutingInfo.pb` | 1 | 1 | 0 | RoutingInfo |
| `WAWebProtobufsServerSync.pb` | 12 | 14 | 1 | CoexStateSync, ExitCode, ExternalBlobReference, KeyId, SyncdIndex, SyncdMutation, SyncdMutations, … (+5) |
| `WAWebProtobufsStatusAttributions.pb` | 1 | 8 | 5 | StatusAttribution |
| `WAWebProtobufsSyncdSnapshotRecovery.pb` | 3 | 3 | 0 | SyncdPlainTextRecord, SyncdSnapshotRecovery, SyncdVersion |
| `WAWebProtobufsUserPassword.pb` | 1 | 3 | 2 | UserPassword |
| `WAWebProtobufsVnameCert.pb` | 5 | 6 | 5 | BizAccountLinkInfo, BizAccountPayload, BizIdentityInfo, LocalizedName, VerifiedNameCertificate |
| `WAWebProtobufsWa6.pb` | 2 | 12 | 13 | ClientPayload, HandshakeMessage |
| `WAWebProtobufsWeb.pb` | 30 | 31 | 10 | Citation, CommentMetadata, EventAdditionalMetadata, EventInviteAdditionalMetadata, EventResponse, GroupHistoryBundleInfo, GroupHistoryIndividualMessageInfo, … (+23) |

Grouping:
* **Wire, used for E2E messages:** `WAWebProtobufsE2E.pb`, which holds `Message`, `ContextInfo`, `MessageContextInfo` and 236 types in all.
  It imports `Protocol` (`MessageKey`, `LimitSharing`, `ACP2Setting`), `AICommon`, `AICommonDeprecated`, `Adv`, `Aea`, `CompanionReg`,
  `MmsRetry`, `ServerSync` and `StatusAttributions`.
* **Wire, used for the session, pairing and sync:** `Wa6` (`ClientPayload`, `HandshakeMessage` for the Noise login),
  `CompanionReg` (`DeviceProps`, pairing), `Adv` (device identity), `Cert`/`VnameCert`, `ServerSync` + `SyncAction` +
  `SyncdSnapshotRecovery` (app-state), `HistorySync`, `GroupHistory`, `Web` (`WebMessageInfo`, with StubType at 267 values).
* **Messenger/"Armadillo" (MSGR-interop) payloads:** `WAMsgApplication`, `WAConsumerApplication`, `WAArmadillo*`,
  `WAMediaTransport`, `WACommon`, `WAMediaEntryData`.
* **Local-only:** `WAWebProtobufsMdStorage*OpaqueData` (IndexedDB row blobs), `WASignalLocalStorageProtocol`
  (Signal session/prekey records), `WASignalWhisperTextProtocol` (Signal wire envelopes).
* **WASM bridges:** `WAWebLabyrinthWaWasm`, `EBMinosWasm` and `VestaWasm`. These are input/output structs for the
  encrypted-backup (Labyrinth/Minos) and passkey-login (Vesta, `Begin/FinishLogin/Register`) WASM modules. The
  passkey reading is (inferred) from the type names.

#### 1.3 `Message` (waE2E): every kind of message

`Message` has **117 fields** (numbers 1–138), all plain optional and with no oneof. Every field below also exists in
whatsmeow's `waE2E.Message` with the same number and type: the diff found **0 differences on `Message` itself**.

How to read the extra columns:
* **MSG_TYPE** is how `WAWebVerifyProtobufMsgObjectKeys.getProtobufMessageTypesToKeys` classifies the key.
  * `*UnknownMessageKey` means a wrapper, or a type that is classified later in the pipeline.
  * `*Buttons` and `*Template` are "undeclared types" that Web rejects in `getProtobufMessageTypesSet`.
  * `—` means ignored (metadata).
* **unwrap** shows whether the key is a `FutureProofMessage` wrapper that Web unwraps in
  `WAWebFutureproofProtoUtils.maybeGetFutureproofMessage` (W), and whether whatsmeow's
  `events.Message.UnwrapRaw` (types/events/events.go) unwraps it (M).

| # | field | type | Web MSG_TYPE / key class | unwrap: Web / whatsmeow |
|---|---|---|---|---|
| 1 | `conversation` | STRING | CHAT |  |
| 2 | `senderKeyDistributionMessage` | Message.SenderKeyDistributionMessage | *SenderKeyDistribution |  |
| 3 | `imageMessage` | Message.ImageMessage | IMAGE |  |
| 4 | `contactMessage` | Message.ContactMessage | VCARD |  |
| 5 | `locationMessage` | Message.LocationMessage | LOCATION |  |
| 6 | `extendedTextMessage` | Message.ExtendedTextMessage | CHAT |  |
| 7 | `documentMessage` | Message.DocumentMessage | DOCUMENT |  |
| 8 | `audioMessage` | Message.AudioMessage | AUDIO |  |
| 9 | `videoMessage` | Message.VideoMessage | VIDEO |  |
| 10 | `call` | Message.Call | *UnknownMessageKey |  |
| 11 | `chat` | Message.Chat | *UnknownMessageKey |  |
| 12 | `protocolMessage` | Message.ProtocolMessage | PROTOCOL |  |
| 13 | `contactsArrayMessage` | Message.ContactsArrayMessage | MULTI_VCARD |  |
| 14 | `highlyStructuredMessage` | Message.HighlyStructuredMessage | PROTOCOL |  |
| 15 | `fastRatchetKeySenderKeyDistributionMessage` | Message.SenderKeyDistributionMessage | *SenderKeyDistribution |  |
| 16 | `sendPaymentMessage` | Message.SendPaymentMessage | PAYMENT |  |
| 18 | `liveLocationMessage` | Message.LiveLocationMessage | LOCATION |  |
| 22 | `requestPaymentMessage` | Message.RequestPaymentMessage | PAYMENT |  |
| 23 | `declinePaymentRequestMessage` | Message.DeclinePaymentRequestMessage | UNKNOWN |  |
| 24 | `cancelPaymentRequestMessage` | Message.CancelPaymentRequestMessage | UNKNOWN |  |
| 25 | `templateMessage` | Message.TemplateMessage | *Template |  |
| 26 | `stickerMessage` | Message.StickerMessage | STICKER |  |
| 28 | `groupInviteMessage` | Message.GroupInviteMessage | GROUPS_V4_INVITE |  |
| 29 | `templateButtonReplyMessage` | Message.TemplateButtonReplyMessage | TEMPLATE_BUTTON_REPLY |  |
| 30 | `productMessage` | Message.ProductMessage | PRODUCT |  |
| 31 | `deviceSentMessage` | Message.DeviceSentMessage | *UnknownMessageKey | - / M |
| 35 | `messageContextInfo` | MessageContextInfo | — |  |
| 36 | `listMessage` | Message.ListMessage | LIST |  |
| 37 | `viewOnceMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 38 | `orderMessage` | Message.OrderMessage | ORDER |  |
| 39 | `listResponseMessage` | Message.ListResponseMessage | LIST_RESPONSE |  |
| 40 | `ephemeralMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 41 | `invoiceMessage` | Message.InvoiceMessage | *UnknownMessageKey |  |
| 42 | `buttonsMessage` | Message.ButtonsMessage | *Buttons |  |
| 43 | `buttonsResponseMessage` | Message.ButtonsResponseMessage | BUTTONS_RESPONSE |  |
| 44 | `paymentInviteMessage` | Message.PaymentInviteMessage | PAYMENT |  |
| 45 | `interactiveMessage` | Message.InteractiveMessage | INTERACTIVE |  |
| 46 | `reactionMessage` | Message.ReactionMessage | REACTION |  |
| 47 | `stickerSyncRmrMessage` | Message.StickerSyncRMRMessage | *UnknownMessageKey |  |
| 48 | `interactiveResponseMessage` | Message.InteractiveResponseMessage | INTERACTIVE_RESPONSE |  |
| 49 | `pollCreationMessage` | Message.PollCreationMessage | POLL_CREATION |  |
| 50 | `pollUpdateMessage` | Message.PollUpdateMessage | POLL_UPDATE |  |
| 51 | `keepInChatMessage` | Message.KeepInChatMessage | KEEP_IN_CHAT |  |
| 53 | `documentWithCaptionMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 54 | `requestPhoneNumberMessage` | Message.RequestPhoneNumberMessage | REQUEST_PHONE_NUMBER |  |
| 55 | `viewOnceMessageV2` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 56 | `encReactionMessage` | Message.EncReactionMessage | REACTION_ENC |  |
| 58 | `editedMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 59 | `viewOnceMessageV2Extension` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 60 | `pollCreationMessageV2` | Message.PollCreationMessage | POLL_CREATION |  |
| 61 | `scheduledCallCreationMessage` | Message.ScheduledCallCreationMessage | *UnknownMessageKey |  |
| 62 | `groupMentionedMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 63 | `pinInChatMessage` | Message.PinInChatMessage | PIN_MESSAGE |  |
| 64 | `pollCreationMessageV3` | Message.PollCreationMessage | POLL_CREATION |  |
| 65 | `scheduledCallEditMessage` | Message.ScheduledCallEditMessage | *UnknownMessageKey |  |
| 66 | `ptvMessage` | Message.VideoMessage | PTV |  |
| 67 | `botInvokeMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / M |
| 69 | `callLogMesssage` | Message.CallLogMessage | CALL_LOG |  |
| 70 | `messageHistoryBundle` | Message.MessageHistoryBundle | MESSAGE_HISTORY_BUNDLE |  |
| 71 | `encCommentMessage` | Message.EncCommentMessage | COMMENT |  |
| 72 | `bcallMessage` | Message.BCallMessage | *UnknownMessageKey |  |
| 74 | `lottieStickerMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / M |
| 75 | `eventMessage` | Message.EventMessage | EVENT_CREATION |  |
| 76 | `encEventResponseMessage` | Message.EncEventResponseMessage | EVENT_RESPONSE |  |
| 77 | `commentMessage` | Message.CommentMessage | *UnknownMessageKey |  |
| 78 | `newsletterAdminInviteMessage` | Message.NewsletterAdminInviteMessage | NEWSLETTER_ADMIN_INVITE |  |
| 80 | `placeholderMessage` | Message.PlaceholderMessage | *UnknownMessageKey |  |
| 82 | `secretEncryptedMessage` | Message.SecretEncryptedMessage | *UnknownMessageKey |  |
| 83 | `albumMessage` | Message.AlbumMessage | ALBUM |  |
| 85 | `eventCoverImage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 86 | `stickerPackMessage` | Message.StickerPackMessage | STICKER_PACK |  |
| 87 | `statusMentionMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 88 | `pollResultSnapshotMessage` | Message.PollResultSnapshotMessage | POLL_RESULT_SNAPSHOT |  |
| 90 | `pollCreationOptionImageMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 91 | `associatedChildMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 92 | `groupStatusMentionMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 93 | `pollCreationMessageV4` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 95 | `statusAddYours` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 96 | `groupStatusMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 97 | `richResponseMessage` | AIRichResponseMessage | RICH_RESPONSE |  |
| 98 | `statusNotificationMessage` | Message.StatusNotificationMessage | STATUS_NOTIFICATION |  |
| 99 | `limitSharingMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 100 | `botTaskMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 101 | `questionMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 102 | `messageHistoryNotice` | Message.MessageHistoryNotice | MESSAGE_HISTORY_NOTICE |  |
| 103 | `groupStatusMessageV2` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 104 | `botForwardedMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 105 | `statusQuestionAnswerMessage` | Message.StatusQuestionAnswerMessage | *UnknownMessageKey |  |
| 106 | `questionReplyMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 107 | `questionResponseMessage` | Message.QuestionResponseMessage | *UnknownMessageKey |  |
| 109 | `statusQuotedMessage` | Message.StatusQuotedMessage | *UnknownMessageKey |  |
| 110 | `statusStickerInteractionMessage` | Message.StatusStickerInteractionMessage | *UnknownMessageKey |  |
| 111 | `pollCreationMessageV5` | Message.PollCreationMessage | POLL_CREATION |  |
| 113 | `newsletterFollowerInviteMessageV2` | Message.NewsletterFollowerInviteMessage | NEWSLETTER_FOLLOWER_INVITE |  |
| 115 | `pollResultSnapshotMessageV3` | Message.PollResultSnapshotMessage | POLL_RESULT_SNAPSHOT |  |
| 116 | `newsletterAdminProfileMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 118 | `spoilerMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 119 | `pollCreationMessageV6` | Message.PollCreationMessage | POLL_CREATION |  |
| 120 | `conditionalRevealMessage` | Message.ConditionalRevealMessage | *UnknownMessageKey |  |
| 121 | `pollAddOptionMessage` | Message.PollAddOptionMessage | POLL_ADD_OPTION_DECRYPTED |  |
| 122 | `eventInviteMessage` | Message.EventInviteMessage | SHARABLE_EVENT_INVITE |  |
| 123 | `groupRootKeyShare` | GroupRootKeyShare | *UnknownMessageKey |  |
| 124 | `paymentReminderMessage` | Message.PaymentReminderMessage | *UnknownMessageKey |  |
| 125 | `splitPaymentMessage` | Message.SplitPaymentMessage | *UnknownMessageKey |  |
| 126 | `newsletterAdminProfileStatusMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 127 | `rootSecretDistributeMessage` | Message.RootSecretDistributeMessage | *RootSecretDistribute |  |
| 128 | `splitPaymentUpdateMessage` | Message.SplitPaymentUpdateMessage | *UnknownMessageKey |  |
| 129 | `musicMessage` | Message.MusicMessage | MUSIC |  |
| 130 | `statusLinkPreviewMetadata` | Message.StatusLinkPreviewMetadata | — |  |
| 131 | `botPlatformRegistrationSuccessMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 132 | `newsletterScheduledMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 133 | `acp2SettingMessage` | Message.FutureProofMessage | *UnknownMessageKey | - / - |
| 134 | `audioStickerMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 135 | `instantImageMessage` | Message.ImageMessage | *UnknownMessageKey |  |
| 136 | `requestLocationMessage` | Message.RequestLocationMessage | *UnknownMessageKey |  |
| 137 | `botGroupParticipantMessage` | Message.FutureProofMessage | *UnknownMessageKey | W / - |
| 138 | `requestLocationUpdateMessage` | Message.RequestLocationUpdateMessage | *UnknownMessageKey |  |

Field 69 is really spelled `callLogMesssage`, in both Web and whatsmeow.
Web also unwraps `deviceSentMessage` and `botInvokeMessage`, but in other modules (inferred from the
MSG_TYPE table, where they are `*UnknownMessageKey` wrappers).

### 2. whatsmeow coverage (diff by field number)

whatsmeow `v0.0.0-20261017175727-b2b1e71d45e2` generates its protos from the same WA Web schema dumps: its packages are
named after the Web modules (`WAWebProtobufsE2E`, `WAWebProtobufSyncAction`, …) and it flattens nested types
(`Message$ImageMessage` → `waE2E.ImageMessage`). Matching by name suffix inside the corresponding package (and enums by
value set where Web uses SCREAMING names) gives:

| Module | Web types | matched in whatsmeow | fields only in Web | fields only in whatsmeow |
|---|---|---|---|---|
| E2E | 236 | 235 | 4 | 0 |
| SyncAction | 105 | 105 | 1 | 0 |
| HistorySync | 18 | 18 | 0 | 0 |
| Web (WebMessageInfo…) | 31 | 31 | 0 | 0 |
| CompanionReg | 10 | 10 | 4 | 0 |
| ServerSync, Wa6, Adv, AICommon, Armadillo*, ConsumerApplication, MsgApplication, MediaTransport, … | all | all | 0 | 0 |
| WebLabyrinthWaWasm | 40 | 38 | 1 | 0 |
| MdStorage* (local DB), WASignal* (local/libsignal), EBMinosWasm, VestaWasm, ArmadilloLocallyTransformedMessage | 145 | 0 | n/a | n/a |

No field anywhere has a different type or label for the same number.

#### 2.1 In WhatsApp Web but not in whatsmeow

Field numbers are given; see `tools/out/pbdiff.json` for the full lists.

| Where | Web-only | Used by Web code? |
|---|---|---|
| `ContextInfo` | 84 `sourceExperienceId` uint32 | only the schema |
| `ContextInfo.StatusAudienceMetadata` | 4 `networkId` string; enum AudienceType += `CUSTOM_LIST=2`, `NETWORK=3` | schema |
| `MessageContextInfo` | 22 `lightE2Ee` bool | only the schema |
| `PeerDataOperationRequestMessage` | 13 `recentConversationsOnDemandRequest` (new type `RecentConversationsOnDemandRequest`, 2 fields); `PeerDataOperationRequestType` += `RECENT_CONVERSATIONS_ON_DEMAND_REQUEST=15` | Web logs "recent conversations on demand request is not supported in web" (`WAWebSendNonMessageDataRequest`) |
| `Message.HistorySyncType` / `HistorySync.HistorySyncType` | += `RECENT_CONVERSATIONS_ON_DEMAND=9` | goes with the item above |
| `SyncActionValue.MusicUserIdAction` | 2 `music_user_id_map` map<string,string> | schema |
| `ClientPairingProps` | 6 `isBotJidDbMigrated` bool | schema only (no builder sets it) |
| `DeviceProps.HistorySyncConfig` | 25 `supportNewsletter`, 26 `supportUniversalReachChat`, 27 `supportOmittedConversationIndex` (bool) | Web itself does not set them |
| `DeviceProps.PlatformType` | += `WAIL=25`, `WASS=26`, `BUSINESS_BACK_OFFICE=27`, `WAIL_WAI=28`, `WAIL_ALEXA=29`, `AUTOMOTIVE=30` (31 vs 25) | n/a for us |
| `ADVEncryptionType` | += `NON_E2EE=2` (also used by `DeviceListMetadata.sender/receiverAccountType`) | Adv/hosted devices |
| `StatusAttribution.Type` | += `PAID_PARTNERSHIP=11`, `USERNAME_STATUS=12`; `ExternalShare.Source` += `SHAZAM=12`, `PICSART=13` | status |
| `WebMessageInfo.StubType` | += `POLL_OPTIONS_REMOVED=290`, `POLL_ADDED_OPTION_REMOVED=291` (Web 267 values vs whatsmeow 265) | poll system messages |
| `LabyrinthWaCommand` | 13 `prepareAddPeerDeviceInput` (+2 types) | backup WASM |

Cosmetic differences, with the same numbers on both sides:
* `KeepType.UNKNOWN` is `UNKNOWN_KEEP_TYPE` in whatsmeow, and `PollContentType.UNKNOWN` is `UNKNOWN_POLL_CONTENT_TYPE`.
* Web's `PAYMENT_UNKNOWN=-1` and XMA `UNSUPPORTED=-1` are `0` in whatsmeow. These are the enum sentinels of Armadillo
  payloads; the wire value -1 would be an unknown enum value for Go.

Enums that are identical: `ProtocolMessage.Type` (35 values, max 41), `SyncActionValue` (91 fields, numbers 1–100),
`HistorySyncNotification`, all `SyncdPatch`/`SyncdMutation` types, `ClientPayload`/`HandshakeMessage` (Wa6) and the whole
`Message` field set.

**In short, whatsmeow's protos match WA Web revision 1051067427 almost exactly; it is about one schema drop behind.**

#### 2.2 In whatsmeow but not in this WhatsApp Web bundle

182 types, none of them WhatsApp-Web/E2E-relevant:
* `WABotMetadata` (46): an older split of what Web now keeps in `WAWebProtobufsAICommon`. Web's 83 AICommon types all
  match `waAICommon`.
* Messenger/Instagram E2EE, used by mautrix-meta and not by WhatsApp:
  * `WAMsgTransport` (11) and `WAMultiDevice` (11): Web has no `.pb` for these. It encodes the outer transport differently (inferred).
  * `Instamadillo*` (≈60).
  * `WACommonParameterised` and `WAConsumerApplicationParameterised` (38).
  * `WAArmadilloICDC` (2).
* `WAWinUIApi` (9, Windows native app), `WAWebProtobufsE2EGuest` (4, "guest" Message subset) and
  `WAWebProtobufLidMigrationSyncPayload` (2). Web never decodes `encodedMappingPayload`: only `WAWebProtobufsE2E.pb`
  mentions it. These are therefore native/primary-device-only (inferred).

### 3. What this means for a client built on whatsmeow

1. **Unknown fields are preserved.**
   * whatsmeow uses `google.golang.org/protobuf` v1.36.12 with standard generated code. Every message carries
     `unknownFields protoimpl.UnknownFields`, so unknown tags survive `proto.Unmarshal` and are re-emitted by `proto.Marshal`.
   * Forwarding or re-encrypting such a message (retry receipts, `deviceSentMessage`) is lossless.
   * You can detect "newer than my schema" the way Web does: `len(msg.ProtoReflect().GetUnknown()) > 0` on the
     `Message` means a message kind we don't know, which is Web's `MSG_TYPE.UNKNOWN`.
2. **Closed enums are a trap (proto2).**
   * An unknown enum value, such as `HistorySyncType=9` or `ADVEncryptionType=2`, goes to the unknown fields. The getter
     then returns the *default*, e.g. `GetSyncType()` → `INITIAL_BOOTSTRAP` (0).
   * Today none of these occur unless we request them: Web itself does not use RECENT_CONVERSATIONS_ON_DEMAND, and
     `NON_E2EE` only applies to hosted/business devices.
   * Treat "field present in unknownFields" carefully in history-sync and device-list code. (P3; client logic.)
3. **No message kind would show as "unsupported" because of the schema.**
   * All 117 `Message` fields are known to whatsmeow.
   * The gap is in **semantics**: whatsmeow only unwraps 9 wrappers in `UnwrapRaw`. Web additionally unwraps
     `groupMentionedMessage`, `spoilerMessage`, `questionMessage`, `questionReplyMessage`, `pollCreationMessageV4`,
     `pollCreationOptionImageMessage`, `associatedChildMessage`, `botForwardedMessage`, `botGroupParticipantMessage`,
     `newsletterAdminProfileMessage`, `newsletterScheduledMessage` and `audioStickerMessage`. Several more wrappers are
     handled ad hoc elsewhere: `statusMentionMessage`, `groupStatusMessage(V2)`, `groupStatusMentionMessage`,
     `limitSharingMessage`, `eventCoverImage`, `statusAddYours` and `acp2SettingMessage`.
   * A naive renderer that switches on the top-level field will therefore show these as unsupported.
     **P1, client-side logic only**: write a `unwrapFutureProof(msg)` that mirrors `maybeGetFutureproofMessage`,
     applied after whatsmeow's `UnwrapRaw`.
4. **Kinds Web itself classifies as UNKNOWN or hides.**
   * `declinePaymentRequestMessage` and `cancelPaymentRequestMessage` map to UNKNOWN.
   * `buttonsMessage` and `templateMessage` are rejected as "Undeclared message types".
   * Payments (`sendPayment`, `requestPayment`, `paymentInvite`, `splitPayment*`, `paymentReminder`), `invoiceMessage`,
     `bcallMessage`, `secretEncryptedMessage`, `stickerSyncRmrMessage` and `call`/`chat` are not rendered as normal
     bubbles. A desktop client can show a generic "open on phone" bubble for them, as Web does (P2).
5. **Kinds a desktop client must render for parity (P1).** These come from the MSG_TYPE table; all are present in
   whatsmeow's protos and only need client logic:
   * `conversation`/`extendedTextMessage`, and image/video/`ptvMessage`/audio/document/sticker
   * `albumMessage` (83), `stickerPackMessage` (86)
   * location/live location
   * contact/`contactsArrayMessage`
   * `reactionMessage`/`encReactionMessage` (encrypted, needs `messageSecret`)
   * `pollCreationMessage` V1–V6, `pollUpdateMessage` and `pollAddOptionMessage` (121); polls V4 are wrapped
   * `pinInChatMessage`, `keepInChatMessage`, `editedMessage` and `protocolMessage` (REVOKE/MESSAGE_EDIT/EPHEMERAL_SETTING)
   * `eventMessage`/`encEventResponseMessage`/`eventInviteMessage` (122)
   * `groupInviteMessage`, `newsletterAdminInviteMessage`/`newsletterFollowerInviteMessageV2`
   * `callLogMesssage`, `requestPhoneNumberMessage`, `richResponseMessage` (AI)
   * `messageHistoryBundle`/`messageHistoryNotice` (group history, 70/102)
   * `placeholderMessage` (80; ask the phone for a resend via PeerDataOperation `PLACEHOLDER_MESSAGE_RESEND`, which
     whatsmeow implements)
6. **Protobuf fields worth adding locally** if we fork or vendor the protos (all P3): the 4 E2E fields, the 3
   `HistorySyncConfig` booleans and the new enum values above. Each is one line in the `.proto`. A cheaper alternative
   is to read them from unknown fields with `protowire` when needed.
7. **Re-checking after a WA Web update** is mechanical:
   `python3 tools/pbdump.py && python3 tools/pbdiff.py`, after rebuilding `tools/out/whatsmeow.desc` with the `protoc`
   command in the `pbdiff.py` docstring.

#### Gaps summary

| Gap | Priority | Fix type |
|---|---|---|
| Unwrap the 12 extra FutureProof wrappers Web unwraps (spoiler, question, groupMentioned, pollV4, audioSticker, …) | P1 | client logic |
| Render the ~30 user-visible kinds in §3.5; generic bubble for payment/invoice/bcall kinds | P1/P2 | client logic |
| Detect unknown `Message` fields → "update/unsupported" bubble + keep raw plaintext for re-parse (Web's futureproof buffer) | P2 | client logic (unknown fields already preserved) |
| `StubType` 290/291 (poll option removed) system messages | P3 | enum value (or treat the raw int) |
| `recentConversationsOnDemandRequest`, `HistorySyncType=9` | P3 | protobuf field; Web doesn't use it either |
| `ContextInfo.sourceExperienceId`, `MessageContextInfo.lightE2Ee`, status audience `networkId` | P3 | protobuf field |
| Closed-enum unknown values silently becoming defaults | P3 | client logic (check unknown fields) |

---

## 03 — Messaging: send, receive, media, receipts, presence

Source: WhatsApp Web rev 1051067427 (`mods/`), cross-checked against whatsmeow
`v0.0.0-20261017175727-b2b1e71d45e2`. Module names are cited as evidence. Short excerpts are
minified JS. "(inferred)" marks a conclusion that is not directly visible in the code.

---

### 1. What WhatsApp Web does

#### 1.1 Outgoing pipeline (overview)

`WAWebSendMsgJob` builds the protobuf (`createOutgoingMessageProtobuf`), waits for offline delivery
to end (`waitForOfflineDeliveryEnd`) and queues the send per chat (`WAWebSendMsgQueueMap`). After that:

- 1:1, peer and "group-direct" sends go through `WAWebSendMsgCreateFanoutStanza.createFanoutMsgStanza`.
  It encrypts once per device with `WAWebEncryptMsgProtobuf.encryptMsgProtobuf`. A copy for one of
  your own devices is wrapped in `deviceSentMessage` (`WAWebDeviceSentMessageProtoUtils.wrapDeviceSentMessage`).
- Groups and broadcast lists go through `WAWebSendGroupSkmsgJob` (sender keys, see 1.3).
- A retry, which resends to a single device, goes through `WAWebSendMsgCreateDeviceStanza`.
- Padding: `WAWebSendMsgCommonApi.encodeAndPad` uses `writeRandomPadMax16`, which matches whatsmeow's `padMessage`.

The server's ack is parsed by `WAWebSendMsgCommonApi.sendMsgAckSyncParser`. It reads these attributes:
`t, sync, phash, refresh_lid, addressing_mode, count, error`.
The ack error codes are in `WAWebHandleMsgError.MessageSentAckErrorCode`:
`MessageNotAllowed:420, StaleGroupAddressingMode:421, NewChatMessagesCapped:475`.

#### 1.2 Message stanza shape

1:1 message, from `WAWebSendMsgCreateFanoutStanza`:

```
<message id to type=text|media|poll|reaction|event|medianotify|pay
         [edit=1|2|3|7|8] [addressing_mode=lid|pn] [device_fanout=false]
         [peer_recipient_lid] [peer_recipient_pn] [peer_recipient_username] [recipient_pn]>
  <enc v=2 type=msg|pkmsg [session_type=pq] [state=false] [mediatype] [decrypt-fail=hide] [native_flow_name]>…</enc>
     (or <participants><to jid=device><enc …/></to>…</participants>, optional <content_binding> per <to>)
  [<bot type=feedback persona_type agent_engagement_type …>]  [<device-identity>ADV</device-identity>]
  [<biz …><interactive v type><native_flow name/></interactive></biz>]
  [<meta …>]  [<reporting><reporting_token v=2>16B</reporting_token></reporting>]
  [<tctoken>…</tctoken> | <cstoken>HMAC</cstoken>]  [ctwa attribution node]
</message>
```

Group message, from `WAWebSendGroupSkmsgJob`:
`<message id to=group phash=2:… type edit addressing_mode=lid|pn>` with these children:
`<participants>` (pkmsg/msg carrying the SKDM, only for devices that lack the key),
`<enc v=2 type=skmsg mediatype>`, `device-identity`, `biz`, `sender_content_binding`, `meta`, `bot`
and `reporting`. The `content_binding` and `sender_content_binding` children carry opaque bytes
supplied by the caller. Their purpose is unknown.

`type` attribute (`WAWebE2EProtoUtils.typeAttributeFromProtobuf`, enum `WAWebHandleMsgCommon.STANZA_MSG_TYPES`
= `text, media, medianotify, pay, poll, reaction, event`). It first unwraps ephemeral,
groupMentioned, botInvoke, botForwarded and deviceSent wrappers, then:
- `reaction`: reactionMessage or encReactionMessage.
- `event`: eventMessage, encEventResponseMessage, or secretEncrypted `EVENT_EDIT`.
- `text`: secretEncrypted `MESSAGE_EDIT`.
- `poll`: pollCreationMessage V1/V2/V3/V5/V6, pollUpdateMessage, secretEncrypted `POLL_EDIT` or `POLL_ADD_OPTION`.
- `media`: extendedText with a non-empty `matchedText` (a link preview).
- `text`: conversation, extendedText, protocol, keepInChat, pinInChat, editedMessage, encComment,
  albumMessage, richResponse, newsletter invites, messageHistoryNotice and similar.
- pollResultSnapshot: `poll` or `text`, depending on a gate.
- everything else: `media`.

`edit` attribute (`WAWebAck.EDIT_ATTR`): `MESSAGE_EDIT:1, PIN_IN_CHAT:2, NEWSLETTER_MSG_EDIT:3,
SENDER_REVOKE:7, ADMIN_REVOKE:8`. These are mapped in `WAWebSendMsgCommonApi.getEditAttrValue` as follows:
- REVOKE → 7 or 8.
- MESSAGE_EDIT, and the secret-encrypted MESSAGE_EDIT, EVENT_EDIT and POLL_EDIT → 1.
- **`MESSAGE_UNSCHEDULE` → 7.**
- A reaction with empty text → 7.
- keepInChat `UNDO_KEEP_FOR_ALL` from me → 7.
- pinInChat → 2.

`<meta>` node (`WAWebSendMsgMetaNode.genMetaNode`) attributes:
- `polltype`: `creation|quiz_creation|vote|result_snapshot|edit` (`POLL_TYPES`).
- `event_type`: `creation|response|edit`.
- `appdata`: `default|member_tag|group_history`.
- `view_once="true"`.
- `message_association_type="hd_image_dual_upload"`.
- `is_group_status`, `session_scope="status"`.
- `thread_msg_id`, `thread_msg_sender_jid` (comments).
- `conversation_thread_id`, `tag_reason`.
- `origin`, `destination_id`, `sender_intent="hosted"`.
- `type=<scheduled>` with `st=<ts>` (scheduled messages).

`decrypt-fail="hide"` is set from `WAWebE2EProtoUtils.decryptFailAttributeFromProtobuf`.
It is used for edits, reactions and poll votes.

#### 1.3 Device fanout, sender keys, phash

- Devices come from usync and the device-list cache. `WAWebManageE2ESessionsJob.ensureE2ESessions`
  fetches missing prekeys. Devices whose identity changed after the message was created are dropped
  (`WAWebSendMsgCommonApi.filterDeviceWithChangedIdentity`).
- Groups: the job receives `rotateKey`, `skDistribList` (devices that still need the SKDM) and
  `skList` (devices that already have it).
  - The SKDM goes only to `skDistribList`.
  - After a successful ack it calls `WAWebApiParticipantStore.markHasSenderKey(group, devices)`.
  - With `rotateKey` it first calls `Session.deleteGroupSenderKeyInfo`.
- phash (`WAWebPhashUtils.phashV2`) is computed as `"2:"+b64(sha256(sorted(jids).join(""))[0:6])` over the
  recipient devices plus your own device. Meta bot JIDs are added in bot groups.
  - On a **phash mismatch in the ack, WA Web resends the group message**
    (`WAWebResendGroupMsg.resendPersistedGroupMsgWrapper`).
  - Ack errors 420 and 421 are handled separately: re-query the group, or set the message to failed.
- Post-quantum: `WAWebPQGatingUtils` gates a PQXDH/Kyber path on the AB props `pq_keys_upload` and
  `pq_1on1_message_enabled`. Both default to false locally; the server decides.
  - The `enc` node then gets `session_type="pq"`.
  - Retry receipts can carry a Kyber last-resort key (`pqkey`, parsed in `WAWebRetryRequestParser`).

#### 1.4 Privacy, reporting and NCT tokens

- `tctoken`: sent in 1:1 messages when the chat holds a receiver token that has not expired
  (`WAWebTrustedContactsUtils.isTokenExpired`). AB props: `tctoken_duration`=604800 s and
  `tctoken_num_buckets`=4 (sender side likewise). The token is also attached to the presence
  subscription (`WAWebSendPresenceSubscriptionJob`, `tCTokenMixinArgs`).
- `cstoken`: `HMAC-SHA256(WAWebNctSalt, recipientLID.toString())`, gated by `wa_nct_token_send_enabled`.
  A small LRU cache keeps up to 5 entries.
- Reporting token (`WAWebReportingTokenUtils`):
  - Derived with HKDF from messageSecret, with info = `stanzaId‖sender‖remote‖"Report Token"`, 32 bytes.
  - Not sent for comment, event edit/response, encrypted message edit, poll add option, poll edit,
    poll vote and reactions.
  - `rt_sender_reporting_token_version`=2.
  - On receipt, a missing or invalid token gets a nack: `NackReason.MissingReportingToken:421` or
    `InvalidReportingToken:420` (`WAWebCreateNackFromStanza`).

#### 1.5 Message kinds and their builders

**Edit**
- `WAWebGenerateProtocolMessageEditProto` builds `protocolMessage{key,type:MESSAGE_EDIT,timestampMs,editedMessage}`.
- An alternative secret-encrypted edit exists (`WAWebGenerateSecretMessageEditProto`:
  `secretEncryptedMessage{secretEncType:MESSAGE_EDIT}` + messageSecret). It is gated by
  `message_edit_to_message_secret_sender_enabled`, which defaults to false.
- Edit window: `message_edit_window_duration_seconds`=1200; the UI entry point closes at 900 s.
- After the window, `WAWebSendMessageEditAction` marks the send as `EditWindowExpired`.
- "Message yourself" chats are exempt when `message_yourself_edit_window_is_forever_enabled` is set.

**Revoke**
- `WAWebGenerateProtocolRevokeMessageProto` builds `protocolMessage{key,type:REVOKE}`. It adds
  `messageContextInfo.botMetadata.invokerJid` when revoking a bot message.
- The admin revoke uses edit=8.

**Reaction**: `WAWebSendReactionMsgAction`. Removing a reaction means sending text "" with edit=7.

**Poll creation** (`WAWebPollsGeneratePollCreationMessageProto`)
- Version chosen by poll kind:
  - CAG (community announcement group) poll → `pollCreationMessageV2`.
  - Poll with an end time, or with hidden voter names → `pollCreationMessageV6`.
  - Single-select or image poll → `pollCreationMessageV3`.
  - Anything else → `pollCreationMessage`.
- Quiz polls set `pollType` and `correctAnswer`.
- Image polls carry an `optionHash` per option.
- Limits: options ≤ 12, name ≤ 255, option ≤ 100.

**Poll vote** (`WAWebPollVoteEncryptMsgData`): AES-GCM with a 12-byte IV, using the messageSecret
of the poll creation. Votes are refused after `pollEndTime`. Vote metadata (a trusted-contact
validation object) can be attached.

**Poll edit, add option, result snapshot**: `WAWebPollsSendPollEditMsgAction`, the
`POLL_ADD_OPTION` path and `WAWebPollsSendPollResultSnapshotMsgAction`. All are AB-gated and mostly
off by default.

**Events**: `WAWebSendEventCreationMsgAction`, `WAWebSendEventResponseMsgAction` (encrypted with
message secret "Event Response") and `WAWebSendEventEditMsgAction` (secretEncrypted `EVENT_EDIT`).
All use stanza `type=event` with `meta event_type`.

**Keep-in-chat**: `WAWebGenerateKeepInChatMessageProto` builds `keepInChatMessage{key,keepType,timestampMs}`.
`keep_in_chat_undo_duration_limit` is 30 days.

**Pin-in-chat**: `PinInChatMessage` with edit=2 (`WAWebPinInChat*`). `pinned_messages_m2_pin_max` is a gate.

**Link previews** (`WAWebLinkPreviewChatAction`)
- Web does **not** fetch URLs itself for 1:1 and group chats. It sends a peer request to the
  primary phone, `PeerDataOperationRequestType.GENERATE_LINK_PREVIEW {urls, includeHqThumbnail}`,
  and waits `link_preview_wait_time`=7 s for `linkPreviewResponse` (with an optional `hqThumbnail`
  uploaded by the phone).
- On timeout it falls back to `genMinimalLinkPreview`: title=domain, description=url, no thumbnail.
- For newsletters it uses a MEX fetch (`WAWebMexFetchPlaintextLinkPreviewJob`).
- The user setting `disableLinkPreviews` is honoured.

**Albums** (`WAWebAlbumsGenerateAlbumMessageProto`): an `albumMessage` parent, and children linked
by `messageContextInfo.messageAssociation`. HD dual upload uses the association type
`HD_IMAGE_DUAL_UPLOAD` and is reflected in meta.

**View-once**: the message carries `meta view_once=true`. Companions receive
`<unavailable type="view_once"/>` instead of content (see 1.9).

**Location and contacts**: `WAWebSendLocationChatAction` handles static locations. No module sends
live location (inferred: web shows it but does not originate it).

**Message secrets**: HKDF use-case strings, mirrored by whatsmeow `msgsecret.go`:
"Poll Vote", "Enc Reaction", "Enc Comment", "Report Token", "Event Response", "Event Edit",
"Message Edit", "Poll Edit", "Poll Add Option", "Bot Message".

#### 1.6 Media upload and download

**Media connection** (`WAWebQueryMediaConnsJob`, `WAMediaConnParser`)
- Request: `<iq xmlns="w:m" type=set to=s.whatsapp.net><media_conn/></iq>`.
- Response: `media_conn{auth, auth_ttl, ttl, max_buckets, max_manual_retry, max_auto_download_retry}`
  with `host{hostname, class, type=primary|fallback, ip4, ip6, fallback_hostname, fallback_class,
  fallback_ip4/ip6, <upload>types…</upload>, <download>types…</download>, <download_buckets>}`.
  Each host advertises which media types it accepts.
- A 507 reply means throttling (`E507` with backoff).

**Upload URL** (`WAWebMmsClientFormatUploadUrl` + `WAWebMmsClientFormatHashUrl`):
`https://{host}{path}/{b64url(encFilehash)}?auth=&token=&media_id=[&resume=1|&stream=1&bytestart&byteend|&final_hash][&server_thumb_gen=1][&server_transcode=1]`.

Upload paths per media type:

| type | path | HKDF info (`WAWebCryptoMediaTypeInfo`) |
|---|---|---|
| image, product | /mms/image | WhatsApp Image Keys |
| sticker | **/mms/sticker** | WhatsApp Image Keys |
| video, ptv | /mms/video (ptv: no explicit path entry; inferred to use video) | WhatsApp Video Keys |
| gif | **/mms/gif** | WhatsApp Video Keys |
| audio | /mms/audio | WhatsApp Audio Keys |
| ptt | **/mms/ptt** | WhatsApp Audio Keys |
| document | /mms/document | WhatsApp Document Keys |
| md-msg-hist / md-app-state | /mms/md-msg-hist, /mms/md-app-state | WhatsApp History Keys / App State Keys |
| thumbnail-image / -video / -document / -link | /mms/thumbnail-image, -video, -document, -link | WhatsApp Image / Video / Document / Link **Thumbnail** Keys |
| sticker-pack, thumbnail-sticker-pack | /mms/sticker-pack, /mms/thumbnail-sticker-pack | Sticker Pack Keys / Sticker Pack Thumbnail Keys |
| music-artwork | /mms/music-artwork | WhatsApp Music Artwork Keys |
| group-history | /mms/group-history | (not in key table; inferred: History) |
| payment-bg-image | (n/a) | WhatsApp Payment Background Keys |
| ppic, biz-cover-photo | /pps/photo, /pps/biz-cover-photo | unencrypted |
| newsletter-* | /newsletter/newsletter-{image,video,audio,ptt,ptv,gif,document,sticker,sticker-pack,thumbnail-link} | unencrypted |
| ads/waffle/maiba | /mms/ads-image, /mms/waffle-video, /wa-ai/maiba-file, … | niche |

**Upload algorithm** (`WAWebMmsClientUploadMethod`)
- Exponential backoff over a host chosen by `WAWebMmsClientSelectHost` (primary or fallback,
  rotated on failure).
- Error handling: 401 refreshes auth; 413 too large; 415 hash mismatch; 507 throttle.
- **Resumable upload**: for documents above `WAWebMediaHostsMaybeSwitchHost.THRESHOLD`,
  `WAWebMmsClientMmsCheckIfUploadExists` POSTs `?resume=1` first. The reply `resume:"complete"`
  carries a direct_path; a numeric reply is the byte offset. The rest is then sent with
  `bytestart/byteend`. While the upload runs, it polls for a better host (`pollMediaHosts`).
- **Chunked streaming upload** (`WAWebMmsClientUploadStreamer`): documents > 50 MiB are sent as
  `?stream=1&bytestart&byteend` chunks, then finalized with `?stream=1&final_hash=`.
- Upload response fields: `direct_path, url, handle, thumbnail_info{thumbnail_direct_path,
  thumbnail_sha256}, metadata_url, dash_manifest_url` (`WAWebMmsClientMmsUpload`).

**Sidecars and thumbnails**
- Streaming sidecar (`WAMediaCryptoSidecar`), video only: for each 64 KiB chunk (+16 bytes overlap),
  the first 10 bytes of the HMAC-SHA256 under the media MAC key.
- First-frame sidecar: `WAWebCryptoCalculateFirstFrameSidecar`.
- HQ thumbnails are uploaded separately (`WAWebMediaUploadMmsThumbnail`) with the same media key
  and the *Thumbnail* HKDF info.
- Voice-note waveform: `WAWebWaveformUtils`, `WAPttComposerWaveformRecorder`.

**Download**
- Range and partial downloads: `WAWebGetMediaDownloadByterange`, `WAWebCryptoDecryptPartialMedia`.
- Video streaming: `WAWebMediaVideoStreaming`.
- Host polling and switching applies to large documents.

**Media retry** (RMR, `WAWebSendServerErrorReceiptJob`, `WAWebCryptoMediaRetry`)
- `<receipt type=server-error to=<own LID user> id>` containing
  `<encrypt><enc_p/><enc_iv/></encrypt><rmr jid from_me participant/>`.
- Payload: `ServerErrorReceipt{stanzaId}` encrypted with AES-GCM; the key is derived with HKDF info
  "WhatsApp Media Retry Notification".
- The answer arrives as a `mediaretry` notification (`WAWebHandleMediaRetryNotification`).

#### 1.7 Receipts and acks

Receipt types (`WAWebSendReceiptJobCommon.RECEIPT_TYPE`): `inactive, sender, delivery (no type attribute),
read, read-self, played, played-self, hist_sync, server-error, peer_msg`. In addition: `retry`, `view`
(status), `enc_rekey_retry` (calls) and `class="status"`.

**Delivery receipts** (`WAWebSendDeliveryReceiptJob`)
- Sent after decryption: `<receipt id to [participant] [recipient] [type=sender|peer_msg|inactive] [class=status]>`.
- Optional child `<meta mode=N>` (`genReceiptMetaModeNode`, a receipt-mode bitmask; enum values
  ORPHAN, NO_CHECKMARK_UX, HID_FAILED_DECRYPT; exact bit semantics inferred).
- `type=inactive` is used when the message was handled while the app was inactive.

**Read and played receipts** (`sendAggregateReceipts`)
- At most **256 ids per stanza** (first id in `id`, the rest in `<list><item id/>`).
- Attributes: `t`, `participant`, `recipient`, `peer_participant_pn` (LID status reads),
  `sts`, `class=status`. Optional child `<bot client_thread_id>`.
- The **ack to a read receipt carries `readreceipts=all|none`**, which updates the local privacy setting.

**Retry receipts** (`WAWebSendRetryReceiptJob`)
```
<receipt id to participant recipient type=retry [category=peer]>
  <retry v=1 count id t [error=N]/> <registration>regId(4B)</registration>
  [<keys><type/><identity/><key/><skey/>[<pqkey…>]<device-identity/></keys>]  [<meta mode/>]
```
- `keys` are included when `retryCount >= 2` or for stateless sessions.
- Error enum: `UnknownError 0, SignalErrorNoSession 1, InvalidKey 2, InvalidKeyId 3, InvalidMessage 4,
  InvalidSignature 5, FutureMessage 6, BadMac 7, InvalidSession 8, InvalidMsgKey 9,
  BadBroadcastEphemeralSetting 10, UnknownCompanionNoPrekey 11, AdvFailure 12, StatusRevokeDelay 13`.
- Incoming retries: `WAWebHandleMessageRetryRequest` acks with `class=receipt type=retry`, then
  `WAWebHandleRetryRequest` processes the key bundle, rebuilds the session and resends with
  `WAWebSendRetryMsgJob` (`device_fanout=false`, `enc count`).

**Nack reasons** (`WAWebCreateNackFromStanza.NackReason`): `UnsupportedMessage 415,
InvalidReportingToken 420, MissingReportingToken 421, ParsingError 487, … 491 InvalidProtobuf,
493, 495 MissingMessageSecret, 496, 499, 500, 550, 551, 552`.

**History-sync server-error receipt** (`WAWebSendHistSyncServerErrorReceiptJob`):
`type=server-error category=peer` with the encrypted payload.

#### 1.8 Presence and chatstate

**Own availability**: `<presence type=available|unavailable name=pushname>` (`WASmaxOutPresenceAvailabilityRequest`).

**Subscribe**
- `<presence type=subscribe to=<LID user> [name] [context=group]><tctoken>…</tctoken></presence>`.
- 1:1 subscriptions use the account **LID** (`WAWebSendPresenceSubscriptionJob`).
- Group subscription: `sendGroupPresenceSubscription(groupJid)`. The server answers with
  `<presence from=group count=N>` (online count) or `type=unavailable`
  (`WASmaxInPresenceGroupAvailableMixin`, `WAWebHandlePresence`). This drives the "N online" UI.
- The `last` attribute may be `deny|none|error` or a unix time.

**Chatstate** (`WASendChatStateProtocol`): `<chatstate to><composing [media=audio]/></chatstate>` or `<paused/>`.
When typing to a bot in a group, the client sends `<composing><bot jid/></composing>` (`WAWebChatStateBridge`).
Incoming chatstates are not acked ("NO_ACK", `WAWebHandleChatState`).

#### 1.9 Incoming messages

**Parser** (`WAWebHandleMsgParser`) reads these attributes and child tags:
`from, participant, participant_lid|pn|username, sender_lid|pn, recipient(_lid|_pn|_username),
peer_recipient_*, addressing_mode, edit, count, sts, offline, category=peer, type, notify, verified_name,
<enc v type mediatype decrypt-fail session_type state count>, <meta polltype event_type
thread_msg_id appdata is_group_status …>, <reporting><reporting_token v/><reporting_tag/>`,
`<bot>`, `<biz>`, `<hsm>` and `<unavailable type=view_once|sender_drop hosted=true>`.

**Decryption**: `WAWebMsgProcessingDecryptEnc` and `WAWebMsgProcessingDecryptionHandler` handle
pkmsg, msg and skmsg, plus the PQ scope.
- On failure the client writes a CIPHERTEXT placeholder (`WAWebMessageProcessPlaceholder`) and sends
  a retry receipt with an error code.
- Placeholder recovery: when placeholders are **seen** (shown in the chat),
  `WAWebNonMessageDataRequestPlaceholderMessageResendUtils.handlePlaceholderMsgsSeen` sends
  `PLACEHOLDER_MESSAGE_RESEND` peer requests to the phone.
  - Batches of 32 message keys.
  - Only messages younger than `placeholder_message_resend_maximum_days_limit`.
  - Bot, hosted, view-once and ACP "unavailable_fanout" placeholders are skipped.

---

### 2. whatsmeow coverage

#### What it implements, and it matches WA Web

- **Stanza assembly** (`send.go: prepareMessageNode, getMessageContent, sendDM, sendGroup`):
  - `participants/to/enc`, `device-identity`, `meta polltype=creation|vote`, `bot`, `biz` buttons.
  - `addressing_mode`, `peer_recipient_pn`, `decrypt-fail=hide` for edits, reactions and votes.
  - `phash` V2 (`participantListHashV2`, identical to `phashV2`).
- **Tokens**: `tctoken` and `cstoken` (`tctoken.go`, `cstoken.go`). Bucket constants match
  (604800 s × 4). Token issuance uses `<iq xmlns=privacy><tokens><token type=trusted_contact>`.
- **Reporting token** (`reportingtoken.go`) with v=2. It is opt-in (`Client.SendReportingTokens`).
  When enabled, a messageSecret is added automatically (`send.go` ~L240).
- **Edit attribute values** (`types/message.go` EditAttribute 1/2/3/7/8) and `getEditAttribute`,
  covering protocol REVOKE/EDIT, empty reaction, keep UNDO and pin.
- **Builders**: `BuildRevoke` (sender or admin), `BuildReaction`, `BuildEdit` (wrapped in
  `editedMessage` FutureProof; `EditWindow=20m`), `BuildPollCreation`/`BuildPollVote`/`EncryptPollVote`,
  `EncryptReaction`, `EncryptComment`, `DecryptSecretEncryptedMessage`, `BuildUnavailableMessageRequest`,
  `BuildHistorySyncRequest`.
- **Message secrets**: all use-case strings are present (`msgsecret.go`).
- **Media**: encryption and HKDF (`download.go: getMediaKeys`), media_conn (`mediaconn.go`, `w:m`),
  plain POST upload (`upload.go: rawUpload`), `UploadNewsletter`, `DeleteMedia`, download with retries,
  `DownloadToFile`, and media retry (`mediaretry.go`, same RMR shape).
- **Receipts**:
  - Delivery: sender / peer_msg / inactive (`receipt.go: sendMessageReceipt`).
  - `MarkRead` covers read, read-self (when read receipts are off) and played, with the `<list><item>` form.
  - Retry receipts with `<keys>` on retry > 1 (`retry.go: sendRetryReceipt`).
  - Handling of incoming retries with resend (`handleRetryReceipt`, with `count` and `device_fanout=false`).
  - `hist_sync` and `server-error` receipts.
  - Nack codes 487–552.
- **Presence**: `SendPresence`, `SubscribePresence` (with tctoken), `SendChatPresence` (composing,
  media=audio, paused), and incoming presence/chatstate events.
- **Incoming**: `<unavailable type=view_once>` → `events.UndecryptableMessage{UnavailableType}`.
  The placeholder resend is requested from the phone 5 s after the first retry receipt
  (`retry.go: delayedRequestMessageFromPhone`, `RequestFromPhoneDelay`).

#### Where it lacks or differs

1. **Group sender-key distribution.** whatsmeow `sendGroup` encrypts the SKDM to **every**
   participant device on **every** send (`prepareMessageNode(…, skdPlaintext, …)`). WA Web tracks
   `skList`/`skDistribList`, sends the SKDM only to devices that lack it, `markHasSenderKey` after
   the ack, and rotates the key when participants change. whatsmeow's way is correct but costly
   in large groups.
2. **phash mismatch.** whatsmeow only logs it and drops the cached group/device list (`send.go` ~L469).
   WA Web resends automatically. whatsmeow also ignores the ack's `refresh_lid`, `addressing_mode`,
   `count` and `sync`, and the errors 420, 421 and 475.
3. **`type` and meta for newer kinds** (`getTypeFromMessage`, `getMediaTypeFromMessage`):
   - `EventMessage` and `EncEventResponseMessage` get `type=text` (WA Web: `event` + `meta event_type`).
   - Poll V2/V3/V5/V6 creation, POLL_EDIT and POLL_ADD_OPTION get `text` and no `meta polltype`.
   - `quiz_creation` and `result_snapshot` are missing.
   - No `meta view_once=true`.
   - No `meta message_association_type`, `appdata`, `thread_msg_id` and similar (except via the
     `req.Meta` passthrough for thread ids).
   - `getEditAttribute` ignores `secretEncryptedMessage` edits (MESSAGE/EVENT/POLL_EDIT) and `MESSAGE_UNSCHEDULE`.
4. **Poll versions.** `BuildPollCreation` always emits V1. WA Web emits V3 for single-select and
   V6 for end-time or hidden-voters polls. There is no quiz or image-poll builder.
5. **Media upload paths.** Stickers go to `/mms/image`, ptt to `/mms/audio`, and gif to `/mms/video`
   (`mediaTypeToMMSType` is keyed by HKDF type). WA Web uses `/mms/sticker`, `/mms/ptt` and `/mms/gif`.
   Today's behaviour works in practice (inferred: the server accepts it), but server-side
   transcoding and stats may differ.
   - Thumbnail HKDF infos (Image/Video/Document/Sticker-pack Thumbnail, Music Artwork, Payment BG)
     are not defined.
   - `DownloadThumbnail` only supports `ExtendedTextMessage` (link thumbnails). It cannot fetch the
     HQ `thumbnailDirectPath` of images, videos or documents.
6. **Upload robustness.** whatsmeow always uses `Hosts[0]` (or the last host for Messenger). It does
   not parse the per-host `upload`/`download` type lists, the fallback hosts, `max_manual_retry`
   or the 507 backoff. It has no resumable upload (`?resume=1`), no chunked streaming upload
   (`stream=1`, `final_hash`), and no `server_thumb_gen` / `media_id`. `UploadResponse` drops
   `thumbnail_info`, `metadata_url` and `dash_manifest_url`.
7. **No media helpers.** There is no streaming sidecar, first-frame sidecar, waveform or
   thumbnail generation. These are caller-side protobuf fields.
8. **No link-preview flow.** whatsmeow has the protobuf enums (`GENERATE_LINK_PREVIEW`,
   `LinkPreviewResponse` in `binary/proto/legacy.go`), but no builder and no handler for the
   response (`message.go` handles only `PLACEHOLDER_MESSAGE_RESEND` and syncd recovery responses).
9. **Receipt details.**
   - `MarkRead` neither chunks at 256 ids nor sets `class=status` for status reads.
   - The `readreceipts` value in the read-receipt ack is not parsed.
   - No `<meta mode>` on delivery or retry receipts; no `peer_participant_pn` or `sts`.
   - The retry receipt has no `error` attribute, and sends `<keys>` only from the second retry
     (WA Web: retry ≥ 2, or stateless).
   - Nack codes 415, 420 and 421 are missing.
10. **Presence.** No group presence subscription and no parsing of `count` from group presences.
    `SubscribePresence` uses whatever JID it is given; WA Web always subscribes to the LID.
11. **Media retry `to`.** whatsmeow uses the own PN JID (`mediaretry.go`); WA Web uses the own LID
    user. A small difference that may matter after the LID migration (inferred).
12. **Post-quantum (PQXDH / Kyber).** Absent: no `session_type=pq`, no `pqkey` in retry receipts,
    no Kyber prekey upload. It is gated off by default in WA Web today.
13. **Placeholder recovery policy.** whatsmeow asks the phone 5 s after a decryption failure.
    WA Web asks lazily when the user views the placeholder, in batches of 32, with an age limit.
    Both are valid; WA Web's sends less traffic.
14. **`content_binding` / `sender_content_binding`** stanza children and the `<biz host_storage
    actual_actors privacy_mode_ts>` attributes for hosted (coex) chats are not emitted. They are
    business- or hosted-specific.

---

### 3. Gaps that matter for a desktop client

| # | Gap | Priority | How to close it |
|---|---|---|---|
| G1 | **Link previews**: send `GENERATE_LINK_PREVIEW` to the phone, wait about 7 s, take `linkPreviewResponse` (+ HQ thumbnail via `thumbnail-link`), and fall back to a minimal preview or a local fetch. A desktop app can also fetch OpenGraph locally and upload a `/mms/thumbnail-link` thumbnail with "WhatsApp Link Thumbnail Keys" (whatsmeow `MediaLinkThumbnail` exists). | P1 | Protobuf (peer data op) + client logic; a whatsmeow hook to surface `PeerDataOperationRequestResponseMessage` |
| G2 | **Correct `type`/meta for events and newer polls** (event creation/response/edit, poll V3/V6, quiz). Without it, recipients may drop or mis-render these messages (inferred). | P2 (P1 if events or polls are sent) | Custom stanza attributes: patch `getTypeFromMessage` or pass `extraParams.metaNode`/`additionalNodes`; whatsmeow already exposes `SendRequestExtra.Meta` |
| G3 | **HQ thumbnail download** for images, videos and documents (`thumbnailDirectPath`) with the *Thumbnail* HKDF infos | P2 | Client logic: add MediaType constants + `/mms/thumbnail-*`; uses the existing `DownloadMediaWithPath` |
| G4 | **Voice notes**: waveform (64 samples), `ptt=true`, opus/ogg; optionally upload to `/mms/ptt` | P1 (waveform/ptt fields), P3 (path) | Client logic + protobuf fields |
| G5 | **Video streaming sidecar and first-frame sidecar** so phones can stream and seek your videos | P2 | Client logic (HMAC per 64 KiB chunk, 10 B each) |
| G6 | **Large file upload**: resumable (`resume=1`) and chunked (`stream=1`, >50 MiB documents), host fallback and 507 backoff | P2 (desktop users send large files) | Custom HTTP logic outside whatsmeow (re-implement `rawUpload`) |
| G7 | **Read receipts**: chunk at 256, `class=status` for status views, sync `readreceipts` from the ack | P2 | Custom stanza (`cli.DangerousInternals().SendNode`) or upstream patch |
| G8 | **Group SKDM distribution only to new devices** + key rotation on member removal | P2 (big groups, bandwidth and CPU) | Client logic inside whatsmeow (needs a store for "has sender key") |
| G9 | **Auto-resend on phash mismatch** (re-fetch devices, re-send to the missing ones) | P2 | Client logic |
| G10 | **Group presence count** ("N online" in group header) | P3 | Custom stanza: `<presence type=subscribe to=group>` + parse `count` in a raw-node handler |
| G11 | **View-once send** (`meta view_once=true`) and correct UX for `<unavailable type=view_once>` (show "open on phone") | P2 | Custom meta attribute; UI logic |
| G12 | **Edit, revoke and pin UX**: 15-min UI entry point, 20-min hard window, pin edit=2 with duration (`messageAddOnDurationInSecs`), keep-in-chat 30-day undo | P1 (edit/revoke), P2 (pin/keep) | Protobuf + client logic; whatsmeow lacks builders for pin/keep but the edit attribute already works |
| G13 | **Albums** (`albumMessage` + `messageAssociation`) and HD dual upload (`meta message_association_type`) | P2 | Protobuf + meta attribute |
| G14 | Retry receipt `error` code, `<meta mode>` on receipts, nacks 415/420/421 | P3 | Custom stanza |
| G15 | Media retry `to` = own LID; presence subscription to the LID | P3 (watch after the LID migration) | Small whatsmeow patch |
| G16 | PQXDH sessions (`session_type=pq`, Kyber prekeys, `pqkey` in retries) | P3 now; may become P1 if Meta turns `pq_1on1_message_enabled` on | New crypto (libsignal-PQ) in whatsmeow; watch upstream |
| G17 | Secret-encrypted message edits (MESSAGE_EDIT via messageSecret) — receiving already works (`DecryptSecretEncryptedMessage`); sending is gated off in WA Web | P3 | Protobuf + `edit=1` attribute |

Recommendation: whatsmeow is a sound transport for the core send/receive/receipt/media path.
G1, G4 and G12 should go into the native client first. G2 and G3 are small patches to
whatsmeow's attribute and type tables. G6, G8 and G9 are robustness and efficiency work for a
later stage.

---

## 04 — History sync and app-state sync (syncd)

Source: WhatsApp Web rev 1051067427 module dump (`mods/`), cross-checked against whatsmeow
`v0.0.0-20261017175727-b2b1e71d45e2`. Module names are cited without the `.js` suffix.

---

### Part A — History sync

#### A.1 How the companion receives history (Web)

**Transport.** History arrives as a `protocolMessage` of type `HISTORY_SYNC_NOTIFICATION` that the
*primary* sends to the companion as a peer message. `WAWebParseProtocolHistorySyncNotificationMessageProto`
maps it to msg subtype `history_sync_notification` and sets the MMS type `md-msg-hist`.
`WAWebHandleHistorySyncNotification.handleHistorySyncNotification`:

1. Rejects the payload unless the sender is our own primary (`isMePrimary`), with errors `invalid_sender` / `non_primary_sender`.
2. If `syncType == MESSAGE_ACCESS_STATUS` (8), it calls `WAWebHandleHistorySyncMessageAccessStatusChange`. That handler only acts on Windows Hybrid (`completeAccessGranted` sets `setHistorySyncCompleteOnDemandAccessGranted`).
3. Drops `FULL` chunks when AB prop `web_abprop_drop_full_history_sync` is set.
4. Builds a `history-sync-notification` DB row (`WAWebSchemaHistorySyncNotification`) with these columns: `msgKey, syncType, chunkOrder, progress, downloadOptions, isReupload, reuploadPending, historySyncPayloadSize, oldestMsgInChunkTimestampSec, initialHistBootstrapInlinePayload, peerDataRequestSessionId, peerDataRequestChatId, encHandle, processed`. If `originalMessageId` is set, the chunk is a **re-upload** of an earlier notification, and the key uses the original id.
5. Dispatches by `syncType`:
   - `INITIAL_BOOTSTRAP`, `INITIAL_STATUS_V3` or `NON_BLOCKING_DATA`: handled immediately by `WAWebHandleHistorySyncChunk.handleHistorySyncChunk`. These are the critical path. The inline payload `initialHistBootstrapInlinePayload` is used if present; otherwise the chunk is downloaded, and an initial-sync download failure is retried.
   - `PUSH_NAME`: queued, then handled immediately.
   - `ON_DEMAND`: accepted only if `peerDataRequestSessionId` matches an in-flight request in `WAWebNonMessageDataRequestHistorySyncOnDemandUtils.inFlightHistorySyncOnDemandRequests`. Otherwise it is dropped (`on_demand_request_expired`). The chunk must contain exactly one conversation (`"on-demand dropped, conv len != 1"`).
   - `RECENT` / `FULL`: queued. If `chunkOrder <= 11`, the chunk is pre-downloaded right away (`S=11`). From `chunkOrder` and `progress` the handler estimates the total chunk count (`ceil(chunkOrder/(progress/100))`). `progress==100` fixes the final count. `historySyncEarliestDate` is updated from `oldestMsgInChunkTimestampSec`.
6. **Download failure** (anything other than a network error) triggers `WAWebSendHistSyncServerErrorReceiptJob`. That job sends `<receipt type="server-error" category="peer" to=own-user id=msgId><encrypt><enc_p/><enc_iv/></encrypt></receipt>`, which asks the phone to re-upload. The resulting re-upload arrives with `originalMessageId`.
7. After processing, the blob is deleted from MMS (`WAWebMmsClientMmsDeleteMdHistorySyncBlob`, HTTP `DELETE`).

**Decoding** (`WAWebHistorySyncBackendWorkerV2.processHistorySync`, which runs in a worker): `WAGzip.inflate` (zlib), then `decodeProtobuf(HistorySyncSpec)`. The steps are:

1. Learn LID↔PN pairs from `phoneNumberToLidMappings` (`createLidPnMappings`, source `"history-sync-worker"`).
2. Drop conversations whose `id` is not a valid wid.
3. Run `WAWebPreprocessHistorySyncProto`.
4. Run `WAWebHandleHistorySyncMsg.handleProgressiveHistorySyncMsgs`, which stores data via `WAWebDBProcessRecentAndFullHistorySyncMessage`.
5. Apply orphan syncd mutations to the new messages (`WAWebSyncdOrphanWorkerCompatible.checkOrphanMutations`).
6. Process add-ons such as reactions and polls.
7. Bulk-update `endOfHistoryTransferType` per chat.
8. Report progress.

Each chunk records a per-chunk status machine (`setRecentSyncSingleChunkStatus`): RECEIVED, DOWNLOADING, DOWNLOADED, DECODED, MESSAGE_PREPROCESSED, APPLIED.

**The initial-sync boundary.** The INITIAL_BOOTSTRAP chunk sets a per-chat `msgOrderId` boundary (`WAWebUserPrefsHistorySync.setHistoryInitialSyncBoundary`). In later RECENT/FULL chunks `WAWebPreprocessHistorySyncProto` applies these rules:
- It drops chats that are not in the boundary map ("dropped N chats, null boundary").
- It drops messages with `msgOrderId >= boundary`, because bootstrap already delivered them.
- It drops newsletter chats.
- It drops chats whose `endOfHistoryTransferType` is already `COMPLETE_AND_NO_MORE_MESSAGE_REMAIN_ON_PRIMARY`.
- It drops `REQUEST_WELCOME_MESSAGE` and `BOT_MEMU_ONBOARDING_MESSAGE` protocol messages.

Processing is throttled dynamically (`WAWebHistorySyncDynamicThrottlingManager`, batch size plus delay).

#### A.2 Proto types (Web `WAWebProtobufsHistorySync.pb`, `WAWebProtobufsE2E.pb`)

- `HistorySync.syncType` (1): `INITIAL_BOOTSTRAP 0, INITIAL_STATUS_V3 1, FULL 2, RECENT 3, PUSH_NAME 4, NON_BLOCKING_DATA 5, ON_DEMAND 6, RECENT_CONVERSATIONS_ON_DEMAND 9`. The E2E `Message.HistorySyncType` enum also has `NO_HISTORY 7` and `MESSAGE_ACCESS_STATUS 8`.
- `HistorySync` fields: `conversations 2, statusV3Messages 3, chunkOrder 5, progress 6, pushnames 7, globalSettings 8, threadIdUserSecret 9, threadDsTimeframeOffset 10, recentStickers 11, pastParticipants 12, callLogRecords 13, aiWaitListState 14, phoneNumberToLidMappings 15, companionMetaNonce 16, shareableChatIdentifierEncryptionKey 17, accounts 18, nctSalt 19, inlineContacts 20, inlineContactsProvided 21, favoriteStickers 22, omittedConversations 23, omittedConversationsProvided 24`.
- `HistorySyncNotification` (E2E): `fileSha256 1, fileLength 2, mediaKey 3, fileEncSha256 4, directPath 5, syncType 6, chunkOrder 7, originalMessageId 8, progress 9, oldestMsgInChunkTimestampSec 10, initialHistBootstrapInlinePayload 11, peerDataRequestSessionId 12, fullHistorySyncOnDemandRequestMetadata 13, encHandle 14, messageAccessStatus 15`.
- `Conversation.endOfHistoryTransferType`: `COMPLETE_BUT_MORE_MESSAGES_REMAIN_ON_PRIMARY 0, COMPLETE_AND_NO_MORE_MESSAGE_REMAIN_ON_PRIMARY 1, COMPLETE_ON_DEMAND_SYNC_BUT_MORE_MSG_REMAIN_ON_PRIMARY 2, COMPLETE_ON_DEMAND_SYNC_WITH_MORE_MSG_ON_PRIMARY_BUT_NO_ACCESS 3`. This drives the "load older messages" banner.
- `HistorySyncMsg = { message: WebMessageInfo (1), msgOrderId (2) }`.

**Which `Conversation` fields Web reads.** Evidence: field references in `WAWebHistoryMsgHandlerAction`, `WAWebHistorySyncNotificationUtils`, `WAWebDBProcessInitialHistorySyncMessage` and `WAWebHandleHistorySyncChunk`.

- **Fields Web reads:** `id, messages, lastMsgTimestamp, conversationTimestamp, unreadCount, unreadMentionCount, archived, name, displayName, pHash, notSpam, ephemeralExpiration, ephemeralSettingTimestamp, disappearingMode, endOfHistoryTransferType, tcToken, tcTokenTimestamp, tcTokenSenderTimestamp, contactPrimaryIdentityKey, pnJid, lidJid, accountLid, username, lidOriginType, shareOwnPn, locked, systemMessageToInsert, isDefaultSubgroup, maibaAiThreadEnabled, isSenderNewAccount, isSenderSuspicious, authAgent*`.
- **Group fields Web reads:** `readOnly, participant (rank/memberLabel), suspended, terminated, createdAt, createdBy, description, support, isParentGroup, parentGroupId, appealStatus, appealUpdateTime`. These go through `saveGroupMetadataForLeftGroup` and `processPastParticipants`.
- **Fields not read in these modules:** `pinned, muteEndTime, markedAsUnread, wallpaper, mediaVisibility, newJid/oldJid, limitSharing*, acp2*`. Pin, mute and mark-unread come from syncd instead.
- **`HistorySync`-level fields Web reads:** `statusV3Messages, pushnames, recentStickers, pastParticipants, threadIdUserSecret, threadDsTimeframeOffset, phoneNumberToLidMappings, callLogRecords, nctSalt, companionMetaNonce, accounts`. `globalSettings`, `inlineContacts`, `favoriteStickers` and `omittedConversations` were not referenced in the modules inspected (inferred: unused or handled elsewhere).

#### A.3 Gating and limits (pairing)

`WAWebClientPayload` builds `DeviceProps.historySyncConfig` as follows:
- Capability flags set to true: `inlineInitialPayloadInE2EeMsg`, `supportBotUserAgentChatHistory`, `supportCagReactionsAndPolls`, `supportRecentSyncChunkMessageCountTuning`, `supportHostedGroupMsg`, `supportBizHostedMsg`, `supportFbidBotChatHistory`, `supportMessageAssociation`, `supportCallLogHistory`.
- Flags behind gates: `supportGroupHistory` (gk), `thumbnailSyncDaysLimit`, `supportManusHistory` and `supportHatchHistory` (knobs).
- `requireFullSync=false`.
- **No `fullSyncDaysLimit`.** It is only set to 365 behind the debug flag `debug_1_year_history_sync`, which also sets `requireFullSync=true`.
- `storageQuotaMb` comes from `navigator.storage.estimate()`.
- Windows sets `onDemandReady` and `completeOnDemandReady`.

So the primary decides how many days of history it sends, based on the quota. The phone-side setting "Chat history → Full chat history" grants access. Web shows a banner explaining how to enable it (`WAWebConversationLoadMoreMessagesHistorySync`, strings "Histórico de conversas completo").

The full HistorySyncConfig proto has 27 fields, including `initialSyncMaxMessagesPerChat 20`, `supportInlineContacts 24`, `supportNewsletter 25`, `supportUniversalReachChat 26` and `supportOmittedConversationIndex 27`.

#### A.4 Progress tracking

`WAWebHistorySyncProgress` and `WAWebHistorySyncProgressModel` compute progress from the received `progress` values and from `chunkCountForEndOfRecentHistorySync` / `estimatedChunkCount`. `historySyncRemainingPausedSeconds` drives the "paused" state, shown by `WAWebHistorySyncPausedPopup.react` (inferred: the phone stopped uploading). The completion log lines are "Initial bootstrap history sync complete", "Recent history sync complete", "Full history sync complete" and "On demand … complete for chat".

#### A.5 On-demand history and peer-data requests

All of these are `protocolMessage PEER_DATA_OPERATION_REQUEST_MESSAGE` messages sent to our own primary (`WAWebSendNonMessageDataRequest`).

**`HISTORY_SYNC_ON_DEMAND` (3).** The user starts it by clicking the "load older messages" banner. The banner only appears when the chat's `endOfHistoryTransferType` is 0, or 3 with a gate. The request body is:

`{chatJid (historyChatId if set), oldestMsgId, oldestMsgFromMe, onDemandMsgCount: ABProp history_sync_on_demand_message_count, oldestMsgTimestampMs: t*1000, supportInlineResponse: true}`

Notes on this request:
- **`oldestMsgTimestampMs` is in milliseconds.**
- The request id becomes `peerDataRequestSessionId`, which is matched against the returning `ON_DEMAND` notification.
- The request times out after `history_sync_on_demand_timeout_ms`.
- After `history_sync_on_demand_failure_limit` failures within `history_sync_on_demand_cooldown_sec`, requests are disabled for the cooldown period.
- Only one request per chat may be in flight.
- Gate: `history_sync_on_demand_companion`.

**`PLACEHOLDER_MESSAGE_RESEND` (4).** `WAWebNonMessageDataRequestPlaceholderMessageResendUtils.handlePlaceholderMsgsSeen` collects CIPHERTEXT (undecryptable) messages. It excludes history messages and the `*_unavailable_fanout` subtypes, and only takes messages newer than `placeholder_message_resend_maximum_days_limit`. It sends them in batches of 32 keys. The response is handled by `WAWebNonMessageDataRequestHandlerPlaceholderResend`: `webMessageInfoBytes` is decoded and processed as the real message.

**`COMPANION_SYNCD_SNAPSHOT_FATAL_RECOVERY` (8).** See B.6.

**Request types Web refuses to send** (each logs "not supported in web"): `FULL_HISTORY_SYNC_ON_DEMAND` (6), `COMPANION_META_NONCE_FETCH` (7), `HISTORY_SYNC_CHUNK_RETRY` (10) and `RECENT_CONVERSATIONS_ON_DEMAND_REQUEST` (15).

---

### Part B — App-state sync (syncd)

#### B.1 Collections and constants (`WAWebSyncdConst`)

- **Collections:** `regular`, `regular_low`, `regular_high`, `critical_block`, `critical_unblock_low`. The critical ones are `critical_block` and `critical_unblock_low` (`WAWebSyncdCollectionUtils.isCriticalCollection`). During bootstrap, `server_sync` notifications for non-critical collections are filtered out (`WAWebHandleServerSyncNotification`).
- **States:** `CollectionState` is Success, SuccessHasMore, Conflict, ConflictHasMore, ErrorRetry, ErrorFatal or Blocked. `CollectionSyncState` is UpToDate, Dirty, FailingFiniteRetry, Fatal or Blocked. `SyncActionState` is Success, Malformed, Orphan, Unsupported, Skipped or Failed.
- **Retry backoff:** 1 s, doubling, capped at 1 h. A finite failure expires after 2 days.
- **Index format** (`WAWebSyncdActionUtils.buildIndex`): `JSON.stringify([action, ...args])`.
  - Message key segments are `[remoteJid, id, fromMe?"1":"0", participant||"0"]`.
  - After LID migration, the chat index for 1:1 chats is the chat's **`accountLid`** (`WAWebSyncdGetChat.getChatJidMutationIndexForChat`). If no chat is found, this throws `syncd-missing-chat-outgoing-mutation`.

#### B.2 The IQ (`WAWebSyncdRequestBuilderBuild`, `WAWebSyncdResponseParser`)

```
<iq id=… to=s.whatsapp.net type=set xmlns="w:sync:app:state">
  <sync>
    <collection name="regular_high" version="N" return_snapshot="true|false"> [<patch>SyncdPatch bytes</patch>] </collection>
    … (one <collection> per dirty collection, batched in ONE iq)
  </sync></iq>
```

**Request rules.**
- `return_snapshot` is `"true"` when the local version is null or 0.
- Pending local mutations travel in the same IQ as the fetch.
- Mutations for a collection whose initial full sync is incomplete are deferred.

**Outgoing patch contents.**
- The patch carries `keyId`, `mutations`, `snapshotMac`, `patchMac` and `deviceIndex` (our device id).
- It also carries `clientDebugData = PatchDebugData{isSenderPrimary:false, senderPlatform:WEB}`.
- If there are more than `syncd_inline_mutations_max_count` mutations (clamped to 100–2000), or the encoded patch exceeds `syncd_patch_protobuf_max_size` KB (clamped to 10–100), the mutations are uploaded to MMS as `md-app-state`. The patch then carries `externalMutations` instead (`WAWebSyncdMMSUpload`).

**Response parsing.**
- Per `<collection>`: `version` attribute, `<patches><patch>…`, `<snapshot>` (an ExternalBlobReference, downloaded from MMS), and `has_more_patches`.
- Errors: `type="error"` with `<error code>`. Code 409 means Conflict or ConflictHasMore. Codes 400 and 404 mean **ErrorFatal**. Any other code means ErrorRetry.
- `WAWebSyncdServerSync` loops until no collection needs a refetch. A safety cap ends the loop with `"reached max iterations"`.

**Triggers.**
- The `server_sync` notification lists `<collection name version>`. Web compares versions (`localV < serverV`) before syncing, then acks with `<ack class="notification" type="server_sync">`.
- A periodic `syncdSyncAllCollections` job syncs all collections.
- Pending mutations, app resume, and a key share also trigger a sync.

#### B.3 Crypto, LTHash and MAC verification

These match whatsmeow byte-for-byte:
- HKDF(keyData, info `"WhatsApp Mutation Keys"`, 160 bytes) gives `indexKey | valueEncKey | valueMacKey | snapshotMacKey | patchMacKey`, each 32 bytes (`WAWebSyncdCryptoHelper`, `WAWebSyncdCryptoConst`).
- `indexMac = HMAC-SHA256(indexKey, indexJSON)`.
- Values are encrypted with AES-CBC.
- `valueMac = HMAC-SHA512(valueMacKey, op(0x01 SET / 0x02 REMOVE)||keyId || iv||ct || 8-byte len(AD))[:32]` (`WAWebSyncdMutationsCryptoUtils`).
- `WACryptoLtHash` uses salt `"WhatsApp Patch Integrity"` and 128 bytes, with pointwise uint16 add/sub (`WAWebSyncdAntiTamperingLtHash`).
- `snapshotMac = HMAC(snapshotMacKey, ltHash||u64be(version)||name)`. `patchMac` is computed the same way over the snapshotMac and the valueMacs (`WAWebSyncdAntiTampering.computeLtHashAndValidateSnapshot`, `computeLtHashAndValidatePatch`, `computeOutgoingSnapshotAndPatchMacs`).

Web also periodically **re-checks LTHash consistency** against the stored mutations (`checkLtHash`; capped at 900 mutations for employees and 400 by default) and reports inconsistencies.

#### B.4 Keys: share, request, rotation

**Key format.**
- A key id is 6 bytes: a 2-byte creator device id followed by a 4-byte epoch (`WAWebSyncdRotateKey`).
- The active key is the newest epoch. Ties are broken by the lowest device id (`WAWebSyncdKeyManagement.getNewestKeyPair`).

**Web creates and rotates keys itself.** `getActiveKey` rotates when any of these hold:
- the key is older than `syncd_key_max_use_days` (clamped to 1–90);
- a device has been removed (the stored key `fingerprint {rawId,currentIndex,deviceIndexes}` no longer matches the ADV device list);
- no key exists.

The new key is 32 random bytes. It is broadcast to all own peer devices as `APP_STATE_SYNC_KEY_SHARE` (`WAWebKeyManagementSendKeyShareApi`, type `key_rotation`). Behind `wa_web_enable_syncd_key_persistence_only_after_server_ack`, the key is stored only after the server ack.

**Answering key requests.** `WAWebKeyManagementHandleKeyRequestApi` checks that the requester is one of our own devices. It then returns the keys it holds, and lists the ids it lacks as "orphan" entries with no keyData.

**Missing keys.**
- Patches or snapshots that need missing keys trigger `APP_STATE_SYNC_KEY_REQUEST` (`WAWebSyncdHandleMissingKeys`).
- The collection is blocked until the key arrives.
- After `syncd_wait_for_key_timeout_days` the client hits a fatal error, "missing key on all clients" (`WAWebSyncdStoreMissingKeys`).

**Sentinel on logout.** When the user logs out, `WAWebSocketModel` calls `WAWebSentinel`. It queues a `sentinel` mutation (`keyExpiration{expiredKeyEpoch}`, index `["sentinel", <collection>]`) for **every** collection and syncs it, waiting at most `syncd_sentinel_timeout_seconds` (0–20 s).

#### B.5 Orphans and conflicts

- A mutation whose target chat or message is not present locally is stored as an **orphan**. It is applied later, when the model appears (`WAWebSyncdOrphan`, `checkOrphanMutations/Chats/Messages/Agents/…`). For example, history sync calls `checkOrphanMutations` after storing messages.
- A 409 response leads to `WAWebSyncdResolveConflict`. Its outcomes are `ApplyRemoteAndDropLocal`, `SkipRemote` or `SkipRemoteAndDropLocal`.

#### B.6 Fatal handling and recovery

`WAWebSyncdFatal.handleFatalError` runs these steps:
1. Sleep 5 s.
2. Send `APP_STATE_FATAL_EXCEPTION_NOTIFICATION {collectionNames, timestamp}` to the primary.
3. Sleep 5 s.
4. **Log out** (`socketLogout(LogoutReason.SyncdFailure)`).

Before that, `WAWebSyncdSnapshotRecoveryGatingUtils.shouldPreformSnapshotRecovery` may choose **snapshot recovery**. Recovery requires all of the following:
- the error is a `SyncdFatalError`;
- the IDB pref `WAPrimaryDeviceSupportsSyncdRecovery` is true;
- the collection is not `critical_block`;
- the mutation count is at most `snapshot_recovery_max_mutations_count_allowed`.

`WAWebRequestSyncdSnapshotRecovery` then sends `PEER_DATA_OPERATION_REQUEST COMPANION_SYNCD_SNAPSHOT_FATAL_RECOVERY {collectionName, timestamp}` with a 60 s timeout. The response `SyncdSnapshotRecovery{version, collectionName, mutationRecords[SyncdPlainTextRecord{value: SyncActionData, keyId, mac}], collectionLthash}` is converted into decrypted mutations. Web recomputes `indexMac` locally from the record's key.

#### B.7 Full action table

The table covers every handler in `WAWebCollectionHandlerActions.ActionHandlers` (71 handlers). It is registered at `<success>` by `WAWebHandleSuccess`.

- **Collection, version and field** are taken from each handler's `collectionName`, `getVersion()` and the `SyncActionValue` field it reads.
- **"Web sends? = yes"** means the handler, or a named helper, calls `WAWebSyncdActionUtils.buildPendingMutation`.
- **whatsmeow event**: "generic AppState only" means whatsmeow emits only `events.AppState{Index, SyncActionValue}`, and only when it is not a full sync or `EmitAppStateEventsOnFullSync` is set.

| syncd action (index[0]) | collection | ver | SyncActionValue field | Web sends? | whatsmeow Index const (its section) | whatsmeow event | whatsmeow builder | Web handler |
|---|---|---|---|---|---|---|---|---|
| `star` | regular_high | 2 | starAction | yes | IndexStar (regular_high) | Star | BuildStar | StarMessageSync |
| `contact_manager_metadata` | regular_low | 1 | contactManagerMetadataAction | yes | IndexContactManagerMetadata (regular_low) | generic AppState only | - | ContactManagerMetadataSync |
| `contact` | critical_unblock_low | 2 | contactAction | yes | IndexContact (critical_unblock_low) | Contact (+contact store) | - | ContactSync |
| `mute` | regular_high | 2 | muteAction | yes | IndexMute (regular_high) | Mute | BuildMute, BuildMuteAbs | MuteChatSync |
| `label_edit` | regular | 3 | labelEditAction | yes | IndexLabelEdit (regular) | LabelEdit | BuildLabelEdit | LabelSync |
| `label_reordering` | regular | 3 | labelReorderingAction | yes (WAWebListsActions) | IndexLabelReordering (regular) | generic AppState only | - | LabelReorderingSync |
| `deviceAgent` | regular | 7 | agentAction | no | IndexDeviceAgent (regular) | generic AppState only | - | AgentSync |
| `label_jid` | regular | 3 | labelAssociationAction | yes | IndexLabelAssociationChat (regular) | LabelAssociationChat | BuildLabelChat | LabelJidSync |
| `label_sublist` | regular | 1 | labelSublistAction | yes | IndexLabelSublist (regular) | generic AppState only | - | LabelSublistSync |
| `quick_reply` | regular | 2 | quickReplyAction | yes | IndexQuickReply (regular) | generic AppState only | - | QuickRepliesSync |
| `setting_locale` | critical_block | 3 | localeSetting | no | IndexSettingLocale (critical_block) | generic AppState only | - | LocaleSettingSync |
| `setting_pushName` | critical_block | 1 | pushNameSetting | yes | IndexSettingPushName (critical_block) | PushNameSetting (+Store.PushName) | BuildSettingPushName | PushNameSync |
| `archive` | regular_low | 3 | archiveChatAction | yes | IndexArchive (regular_low) | Archive | BuildArchive | ArchiveChatSync |
| `markChatAsRead` | regular_low | 3 | markChatAsReadAction | yes | IndexMarkChatAsRead (regular_low) | MarkChatAsRead | BuildMarkChatAsRead | MarkChatAsReadSync |
| `clearChat` | regular_high | 6 | clearChatAction | yes | IndexClearChat (regular_high) | ClearChat | - | ClearChatSync |
| `deleteMessageForMe` | regular_high | 3 | deleteMessageForMeAction | yes | IndexDeleteMessageForMe (regular_high) | DeleteForMe | - | DeleteMessageForMeSync |
| `sentinel` | regular_low | 3 | keyExpiration | yes | IndexSentinel (regular_low) | generic AppState only | - | SentinelMutationSync |
| `setting_unarchiveChats` | regular_low | 4 | unarchiveChatsSetting | no | IndexSettingUnarchiveChats (regular_low) | UnarchiveChatsSetting | - | ArchiveSettingSync |
| `pin_v1` | regular_low | 5 | pinAction | yes | IndexPin (regular_low) | Pin | BuildArchive, BuildPin | PinChatSync |
| `deleteChat` | regular_high | 6 | deleteChatAction | yes | IndexDeleteChat (regular_high) | DeleteChat | BuildDeleteChat | DeleteChatSync |
| `android_unsupported_actions` | regular_low | 4 | androidUnsupportedActions | no | IndexAndroidUnsupportedActions (regular_low) | generic AppState only | - | AndroidUnsupportedActionsSync |
| `primary_feature` | regular | 7 | primaryFeature | no | IndexPrimaryFeature (regular) | generic AppState only | - | PrimaryFeatureSync |
| `nux` | regular_low | 7 | nuxAction | yes | IndexNux (regular_low) | generic AppState only | - | NuxSync |
| `bb_pro_pending_customer_base_action` | regular_low | 7 | bbProPendingCustomerBaseAction | yes | IndexBBProPendingCustomerBaseAction (regular_low) | generic AppState only | - | BizBroadcastProPendingActionSync |
| `time_format` | regular_low | 7 | timeFormatAction | no | IndexTimeFormat (regular_low) | generic AppState only | - | TimeFormatSync |
| `userStatusMute` | regular_high | 7 | userStatusMuteAction | yes | IndexUserStatusMute (regular_high) | UserStatusMute | - | UserStatusMuteSync |
| `primary_version` | regular_low | 7 | primaryVersionAction | no | IndexPrimaryVersion (regular_low) | generic AppState only | - | PrimaryVersionSync |
| `removeRecentSticker` | regular_low | 7 | removeRecentStickerAction | yes | IndexRemoveRecentSticker (regular_low) | generic AppState only | - | StickersRemoveRecentSyncAction |
| `agentChatAssignment` | regular | 7 | chatAssignment | yes | IndexAgentChatAssignment (regular) | generic AppState only | - | ChatAssignmentSync |
| `agentChatAssignmentOpenedStatus` | regular | 7 | chatAssignmentOpenedStatus | yes | IndexAgentChatAssignmentOpenedStatus (regular) | generic AppState only | - | ChatAssignmentOpenedStatusSync |
| `favoriteSticker` | regular_low | 7 | stickerAction | yes | IndexFavoriteSticker (regular_low) | generic AppState only | - | StickersFavoriteSyncAction |
| `shareOwnPn` | regular | 8 | (none; index only) | no | IndexShareOwnPN (regular) | generic AppState only | - | ShareOwnPnSync |
| `pnForLidChat` | regular | 8 | pnForLidChatAction | no | IndexPNForLIDChat (regular) | generic AppState only | - | PnForLidChatSync |
| `external_web_beta` | regular | 3 | externalWebBetaAction | yes (WAWebExternalBetaOptInAction) | IndexExternalWebBeta (regular) | generic AppState only | - | ExternalWebBetaSync |
| `marketingMessage` | regular | 7 | marketingMessageAction | no | IndexMarketingMessage (regular) | generic AppState only | - | PremiumMessageSync |
| `marketingMessageBroadcast` | regular | 7 | (none; index only) | no | IndexMarketingMessageBroadcast (regular) | generic AppState only | - | PremiumMessageBroadcastSync |
| `status_privacy` | regular_high | 7 | statusPrivacy | yes | IndexStatusPrivacy (regular_high) | generic AppState only | - | StatusPrivacySettingSync |
| `bot_welcome_request` | regular_low | 2 | botWelcomeRequestAction | yes | IndexBotWelcomeRequest (regular_low) | generic AppState only | - | BotWelcomeRequestSync |
| `payment_info` | regular_low | 7 | paymentInfoAction | no | IndexPaymentInfo (regular_low) | generic AppState only | - | PaymentInfoSync |
| `custom_payment_methods` | regular_low | 7 | customPaymentMethodsAction | yes | IndexCustomPaymentMethods (regular_low) | generic AppState only | - | CustomPaymentMethodsSync |
| `lock` | regular_low | 7 | lockChatAction | yes | IndexLock (regular_low) | generic AppState only | - | LockChatSync |
| `setting_chatLock` | regular_low | 7 | chatLockSettings | no | IndexSettingChatLock (regular_low) | generic AppState only | - | ChatLockSettingsSync |
| `setting_disableLinkPreviews` | regular | 8 | privacySettingDisableLinkPreviewsAction | yes | IndexSettingDisableLinkPreviews (regular) | generic AppState only | - | DisableLinkPreviewsSync |
| `note_edit` | regular_low | 7 | noteEditAction | yes | IndexNoteEdit (regular_low) | generic AppState only | - | NoteSync |
| `favorites` | regular_high | 1 | favoritesAction | yes | IndexFavorites (regular_high) | generic AppState only | - | FavoritesSync |
| `merchant_payment_partner` | regular_low | 7 | merchantPaymentPartnerAction | no (handler returns Unsupported) | IndexMerchantPaymentPartner (regular_low) | generic AppState only | - | MerchantPaymentPartnerSync |
| `device_capabilities` | regular_low | 7 | deviceCapabilities | yes (DeviceCapabilitiesSyncBase.getMutation) | IndexDeviceCapabilities (regular_low) | generic AppState only | - | DeviceCapabilitiesSync |
| `device_capabilities_v2` | regular_low | 7 | deviceCapabilitiesV2 | yes (DeviceCapabilitiesSyncBase.getMutation; gated `device_capabilities_v2_sync_enabled`) | IndexDeviceCapabilitiesV2 (regular_low) | generic AppState only | - | DeviceCapabilitiesV2Sync |
| `setting_relayAllCalls` | regular | 1 | privacySettingRelayAllCalls | yes | IndexSettingRelayAllCalls (regular) | generic AppState only | - | VoipRelayAllCallsSettingSync |
| `call_log` | regular | 1 | callLogAction | yes | IndexCallLog (regular) | generic AppState only | - | CallLogSync |
| `waffle_account_link_state` | regular_high | 1 | waffleAccountLinkStateAction | no | IndexWaffleAccountLinkState (regular_high) | generic AppState only | - | WaffleAccountLinkStateSync |
| `business_broadcast_list` | regular | 1 | businessBroadcastListAction | yes | IndexBusinessBroadcastList (regular) | generic AppState only | - | BroadcastListSync |
| `business_broadcast_campaign` | regular | 1 | businessBroadcastCampaignAction | yes | **missing** | - | - | BroadcastCampaignSync |
| `business_broadcast_insights_sync` | regular | 1 | businessBroadcastInsightsAction | no | **missing** | - | - | BusinessBroadcastInsightsSync |
| `payment_tos` | regular_low | 7 | paymentTosAction | yes | IndexPaymentTOS (regular_low) | generic AppState only | - | PaymentTosSync |
| `detected_outcomes_status_action` | regular | 1 | detectedOutcomesStatusAction | no | IndexDetectedOutcomesStatusAction (regular) | generic AppState only | - | DetectedOutcomesStatusSync |
| `avatar_updated_action` | regular | 7 | avatarUpdatedAction | no (handler returns Unsupported) | IndexAvatarUpdatedAction (regular) | generic AppState only | - | StickersAvatarUpdatedSyncAction |
| `lid_contact` | critical_unblock_low | 1 | lidContactAction | yes | IndexLIDContact (critical_unblock_low) | generic AppState only | - | LidContactSync |
| `interactive_message_action` | regular_low | 1 | interactiveMessageAction | yes | IndexInteractiveMessageAction (regular_low) | generic AppState only | - | InteractiveMessageSync |
| `ctwaPerCustomerDataSharing` | regular_high | 1 | ctwaPerCustomerDataSharingAction | yes | IndexCTWAPerCustomerDataSharing (regular_high) | generic AppState only | - | CtwaPerCustomerDataSharingSync |
| `customer_data` | regular_low | 1 | customerDataAction | yes | IndexCustomerData (regular_low) | generic AppState only | - | CustomerDataSync |
| `ai_thread_rename` | regular_low | 7 | aiThreadRenameAction | yes | IndexAIThreadRename (regular_low) | generic AppState only | - | AiThreadRenameSync |
| `ai_thread_delete` | regular_high | 7 | (none; index only) | yes | IndexAIThreadDelete (regular_high) | generic AppState only | - | AiThreadDeleteSync |
| `thread_pin` | regular_low | 7 | threadPinAction | yes | IndexThreadPin (regular_low) | generic AppState only | - | AiThreadPinSync |
| `settings_sync` | regular_low | 1 | settingsSyncAction | yes | IndexSettingsSync (regular_low) | generic AppState only | - | SettingsSync |
| `nct_salt_sync` | regular_high | 1 | nctSaltSyncAction | no | IndexNCTSaltSync (regular_high) | none (stores NCT salt; handles REMOVE) | - | NctSaltSync |
| `subscriptions_sync_v2` | regular | 1 | subscriptionsSyncV2Action | no | IndexSubscriptionsSync (regular) | generic AppState only | - | SubscriptionsSyncV2Sync |
| `out_contact` | regular_low | 1 | outContactAction | no | IndexOutContact (regular_low) | generic AppState only | - | OutContactSync |
| `biz_ai_settings_nudge` | regular_high | 1 | bizAiSettingsNudgeAction | yes (WAWebBizAISettingsNudgeAction) | IndexBizAISettingsNudgeAction (regular_high) | generic AppState only | - | BizAiSettingsNudgeSync |
| `wasa_root_secret` | regular_high | 1 | wasaRootSecretAction | no | IndexWasaRootSecretAction (regular_high) | none (stores msg secrets) | - | WASARootSecretSync |
| `group_history_toggle` | regular_low | 1 | groupHistoryToggleAction | yes | IndexGroupHistoryToggle (regular_low) | generic AppState only | - | GroupHistoryToggleSync |

**Gaps between the two lists.**
- **Enum entries with no Web handler:** `pin` (deprecated), `subscription`, `broadcast`, `broadcast_jid`.
- **Constants only in whatsmeow** (Web ignores these indexes): `label_message`, `recent_emoji_weights_action`, `setting_securityNotification`, `generated_wui`, `delete_individual_call_log`, `ugc_bot`, `lock_message`, `usernameChatStartMode`, `notificationActivitySetting`, `setting_channels_personalised_recommendation_optout`, `music_user_id`, `galaxy_flow_action`, `newsletter_saved_interests`, `maiba_ai_features_control`, `status_post_opt_in_notification_preferences_action`, `private_processing_setting`, `setting_autoOrganizeBusinessChat`, `coexV2Version`, `business_folder_activation`, `community_nesting_state`, `shared_device_allowlist/secret`, `ctwa_message_received`.
- **`label_message` is notable.** whatsmeow has `BuildLabelMessage`, but Web has neither a handler nor a sender for it.
- **Constants only on Web:** `business_broadcast_campaign` and `business_broadcast_insights_sync`. Both are business-only.
- **REMOVE operations are sent** by `contact`, `lid_contact`, `label_sublist`, `business_broadcast_list/campaign` and `customer_data`. Pin also issues REMOVEs in its unpin-all path. whatsmeow's `EncodePatch` hard-codes `SET`.

---

### Part C — whatsmeow coverage

#### History sync

| Topic | What whatsmeow does |
|---|---|
| Notification handling | `message.go:handleProtocolMessage` queues `HistorySyncNotification`s (only `IsFromMe`). It sends a `hist_sync` receipt and runs `handleHistorySyncNotificationLoop`. |
| Download and decode | `DownloadHistorySync` uses the inline payload if present, otherwise downloads; then zlib, then `proto.Unmarshal`. |
| Stored automatically | NCT salt, PN↔LID mappings, push names (`PUSH_NAME`), message secrets and privacy tokens from conversations, `globalSettings`, `companionMetaNonce`. |
| Everything else | Left to the app via `events.HistorySync{Data}`. |
| MMS blob | Deleted afterwards (`DeleteMedia(MediaHistory)`). |
| Not implemented | Initial-sync boundary, re-upload dedup (`originalMessageId`), progress, chunk ordering, on-demand session matching. |
| `SendHistorySyncServerErrorReceipt` | Exists, but is **not called automatically** on download failure. Web calls it automatically. |
| `BuildHistorySyncRequest` | Exists. It **sends seconds in `OldestMsgTimestampMS`**, with a code comment saying "actually supposed to contain seconds". **Web sends `t*1000` (ms)**, so whatsmeow and Web disagree here. Re-verify against a live primary. It also omits `supportInlineResponse` and `accountLid`. |
| `BuildUnavailableMessageRequest` | Exists and is called automatically from `retry.go:455` (one key per request; Web batches up to 32). Responses become `events.Message` with `UnavailableRequestID`. |
| DeviceProps (`store/clientpayload.go`) | Similar flags to Web. `StorageQuotaMb=10240`, `ThumbnailSyncDaysLimit=60`, `RequireFullSync=false`. |
| Proto | Lacks `RECENT_CONVERSATIONS_ON_DEMAND` (HistorySyncType 9) and `recentConversationsOnDemandRequest` (field 13). Both are new and Web does not send them. |

#### App state

| Topic | What whatsmeow does |
|---|---|
| Fetch | `appstate.go:FetchAppState` sends **one collection per IQ**, loops on `has_more_patches`, and verifies snapshot, patch and LTHash MACs (`appstate/decode.go`, `hash.go`, `lthash`). Crypto is identical to Web. |
| Send | `SendAppState` sends one patch per IQ, retries once on 409 after applying the conflicting patches, then refetches. |
| Send limitations | `SET` only. No `deviceIndex`, no `clientDebugData`, no external-mutation upload. Uses the latest existing key; **it never creates or rotates keys** ("creating app state keys is not yet supported"). |
| Keys | `handleAppStateSyncKeyShare` stores shared keys and refetches. `requestMissingAppStateKeys` sends `APP_STATE_SYNC_KEY_REQUEST`, deduplicated for 24 h. **No handler for incoming key requests** from other devices, and no fingerprint/device-removal check. |
| Recovery | `BuildAppStateRecoveryRequest` and `handleAppStateRecovery`/`ProcessRecovery` are implemented. `BuildFatalAppStateExceptionNotification` exists. **Neither is triggered automatically**: on a MAC/LTHash mismatch whatsmeow emits `events.AppStateSyncError` and stops. |
| `server_sync` | `notification.go:handleAppStateNotification` fetches each listed collection. It does not compare versions and does not filter critical collections. |
| Typed events | `Contact, PushNameSetting, Mute, Pin, Archive, Star, DeleteForMe, MarkChatAsRead, ClearChat, DeleteChat, UnarchiveChatsSetting, UserStatusMute, LabelEdit, LabelAssociationChat, LabelAssociationMessage`, plus `AppState`, `AppStateSyncComplete` and `AppStateSyncError`. |
| Builders | `BuildMute/MuteAbs, BuildPin, BuildArchive` (adds unpin), `BuildMarkChatAsRead, BuildLabelChat, BuildLabelMessage, BuildLabelEdit, BuildSettingPushName, BuildStar, BuildDeleteChat`. Versions match Web (2, 5, 3, 3, 3, 3, 1, 2, 6). |
| Builder caveat | Builders take the target JID as given. After LID migration, Web indexes 1:1 chats by **LID**, so the caller must pass the LID. |

---

### Part D — Gaps that matter for a desktop client

| # | Gap | Priority | What closing it needs |
|---|---|---|---|
| 1 | No builder for `deleteMessageForMe` (regular_high, v3, index `[deleteMessageForMe, chat, id, fromMe, participant]`, `deleteMessageForMeAction{deleteMedia, messageTimestamp}`) or `clearChat` (v6). "Delete for me" and "Clear chat" are daily actions. | P1 | Client-side `PatchInfo` built in our code. Proto already present. |
| 2 | Outgoing chat index must use the **LID** (`accountLid`) after migration, as Web does. Using a PN index can create mutations that other devices treat as orphans. | P1 | Client logic: resolve PN→LID via `Store.LIDs` before `Build*`. |
| 3 | History bookkeeping: initial-sync boundary (drop RECENT messages with `msgOrderId >= boundary`), dedup re-uploads via `originalMessageId`, per-chat `endOfHistoryTransferType`, a progress UI, and a "load older" button only when the type is 0 (or 3). | P1 | Client logic over `events.HistorySync` and the notification fields. |
| 4 | On-demand history: implement the banner flow with in-flight/timeout/cooldown, and match `peerDataRequestSessionId`. Check the units of `oldestMsgTimestampMs`: Web sends ms, whatsmeow sends s. | P1 | Custom `PeerDataOperationRequestMessage` (protobuf field already present) sent via `SendPeerMessage`. Fork or wrap `BuildHistorySyncRequest`. |
| 5 | Call `SendHistorySyncServerErrorReceipt` automatically on non-network download failures, as Web does. | P2 | Client logic, with `ManualHistorySyncDownload=true` and our own loop. |
| 6 | Fatal syncd errors: whatsmeow only emits `AppStateSyncError`. Web tries snapshot recovery (non-critical collections), otherwise notifies the primary and **logs out**. A desktop client should at least try `BuildAppStateRecoveryRequest` and then do a full resync (`FetchAppState(fullSync=true)`) before giving up. | P2 | Client logic; existing builders. |
| 7 | Key rotation and sharing (expiry ≤ `syncd_key_max_use_days`, device removal) and answering peer key requests. Without them, sending stops if the primary never shares a key, and other companions cannot get keys from us. Web does all of this. | P2 | Fork/patch whatsmeow (`sendAppState` key creation, a `APP_STATE_SYNC_KEY_REQUEST` handler). Protobufs exist. |
| 8 | Batch all dirty collections into one `w:sync:app:state` IQ, and compare `server_sync` versions before fetching. This is an efficiency issue at startup and after reconnects. | P3 | Custom IQ, or accept the whatsmeow behaviour. |
| 9 | Builders for other Web-sendable actions useful on desktop: `lock` (lockChatAction), `userStatusMute`, `favorites`, `contact`/`lid_contact` (add/edit contacts, REMOVE op), `label_reordering`, `setting_disableLinkPreviews`, `status_privacy`, `favoriteSticker`/`removeRecentSticker`, `note_edit`, `quick_reply` (business). | P2 for lock, favorites, contact and userStatusMute; P3 for the rest | Client-side `PatchInfo`. REMOVE needs an `EncodePatch` change, because whatsmeow hard-codes SET. |
| 10 | Typed handling for received actions that only arrive as generic `events.AppState`: `lock`, `setting_chatLock`, `favorites`, `lid_contact`, `setting_locale`, `time_format`, `status_privacy`, `setting_disableLinkPreviews`, `call_log`, `favoriteSticker`. Full-sync snapshots emit no events unless `EmitAppStateEventsOnFullSync=true`, so set it, or read state from the store. | P2 | Client logic (switch on `Index[0]`). |
| 11 | Sentinel `keyExpiration` patch on user-initiated logout. | P3 | Client-side PatchInfo per collection (`sentinel`, v3). |
| 12 | Outgoing patches over the inline limits (100–2000 mutations or 10–100 KB) must go to MMS `md-app-state` as `externalMutations`. This only matters for bulk operations such as "archive all". | P3 | whatsmeow patch (upload plus `ExternalBlobReference`). |

---

## 05 — Groups, communities, channels, status, calls

WA Web rev 1051067427; whatsmeow v0.0.0-20261017175727-b2b1e71d45e2. Module names refer to `mods/<Name>.js`. "(inferred)" marks things not directly seen.

### 1. Groups and communities

#### 1.1 What WhatsApp Web does

**Transport.** Almost every group operation is a WASmax request in the `Groups` family
(`xmlns="w:g2"`, 29 actions, `WASmaxOutGroups*Request` / `WASmaxInGroups*Response*`). Requests
use one of three base mixins: `BaseSetGroupMixin` (`<iq type="set" to="<group>@g.us">`),
`BaseGetGroupMixin` (`type="get" to=<group>`), `BaseGetServerMixin` (`to="g.us"`). A few legacy
paths still use hand-built `WAWap.wap("iq",…)` (`WAWebGroupExitJob`, `WAWebGroupInviteJob`).
A growing set of reads/writes moved to **MEX** (GraphQL over `w:mex`, see §2.2 for transport):

| MEX operation (module) | doc id | use |
|---|---|---|
| `WAWebMexFetchGroupInfoJobQuery` (+`…Acp2`, `…IncludBots…`) | 27508847222068472 | full group metadata incl. `properties.member_link_mode`, `member_share_group_history_mode`, `membership_approval_mode_enabled`, `support`, `allow_admin_reports`; vars `id, include_username, participants_phash, query_context` |
| `WAWebMexUpdateGroupPropertyJobMutation` | 9418211574894172 | `{group_id, update:{member_add_mode:"ALL_MEMBER_ADD"/"ADMIN_ADD"} \| {member_link_mode:"ALL_MEMBER_LINK"/"ADMIN_LINK"} \| {member_share_group_history_mode:"ALL_MEMBER_SHARE"/"ADMIN_SHARE"}}` → `xwa2_group_update_property.state` (`WAWebSetPropertyGroupAction`) |
| `WAWebMexFetchAllSubgroupsJobQuery` | 9935467776504344 | community sub-groups: `xwa2_group_query_by_id.default_sub_group` (announcement group) + `sub_groups.edges[].node` with `properties.general_chat/hidden_group/membership_approval_mode_enabled`, `membership_approval_requests.total_count` |
| `WAWebMexFetchGroupInviteCodeJobQuery` | 29247029834912157 | `query_context:"INVITE_CODE"` → `invite_code` |
| `WAWebMexTransferCommunityOwnershipJobMutation` | 29643783178598899 | `xwa2_group_update_users_role` |
| `WAWebMexFetchSubgroupSuggestionsJobQuery` | 23972005349071865 | pending sub-group suggestions |
| `WAWebMexQuerySubgroupParticipantCountJobQuery` | 24079399904996141 | |
| `WAWebGroupSuspensionAppealMutation` | 25946115325088226 | appeal a suspended group |
| `WAWebMexGroupStoreAndSendInviteSmsJobMutation` / `WAWebEmailInviteSendGroupMutation` | 29313771494886407 / 28484430131216234 | invite by SMS / e-mail |

(Doc ids are build-specific; they rotate with WA Web releases.)

**w:g2 request shapes** (from the smax builders; `<iq>` envelope omitted):

| Action | child stanza |
|---|---|
| Create | `<create subject=…>` + `<participant jid phone_number? username?>[<privacy>token]`, `<description id><body>`, `<locked/>`, `<announcement/>`, `<ephemeral expiration trigger?/>`, `<membership_approval_mode><group_join state/></…>`, `<member_add_mode>`, `<member_link_mode>`, `<member_share_group_history_mode>`, `<parent default_membership_approval_mode/>` (community), `<linked_parent jid/>` (create inside community), `<hidden_group/>`, `<allow_non_admin_sub_group_creation/>`, `<create_general_chat/>`, `<breakout/>`, `<created_as_lid/>`, `<addressing_mode_override mode/>`, `<capi/>`, `<no_frequently_forwarded/>` |
| SetProperty | exactly one of `locked/unlocked`, `announcement/not_announcement`, `no_frequently_forwarded/frequently_forwarded_ok`, `ephemeral{expiration,trigger?}/not_ephemeral`, `membership_approval_mode`, `allow_admin_reports/not_allow_admin_reports`, `allow_non_admin_sub_group_creation/not_…`, `group_history/no_group_history` |
| SetSubject / SetDescription | `<subject>` (via `SetSubjectChangeSubjectMixin`) / `<description id? prev? delete="true"?><body>…</body>?</description>` |
| Add/Remove/PromoteDemote | `<add|remove|promote|demote><participant jid …/></…>` ; PromoteDemoteAdmin: `<admin><promote|demote><participant/></…></admin>` (multi-admin/superadmin) |
| GetGroupInfo | `<query phash?><add_request expiration …/>?</query>` |
| BatchGetGroupInfo | `to=g.us` `<query context?><group jid/>…</query>` |
| GetParticipatingGroups | `<participating><participants/><description/></participating>` |
| GetInviteGroupInfo / join | `<invite code/>` (get = preview, set = join; response `<group>` or `<membership_approval_request>`) ; reset link: `set to=<group> <invite/>` (`WAWebGroupInviteJob`) |
| AcceptGroupAdd | `<accept code expiration admin/>` (v4 invite from a `GroupInviteMessage`) |
| Leave | `to=g.us <leave><group id/>…</leave>`; leave whole community: `<leave><linked_groups parent_group_jid/></leave>` (`WAWebGroupExitJob.leaveCommunity`) |
| Membership approval | `GetMembershipApprovalRequests`: `<membership_approval_requests/>`; `MembershipRequestsAction`: `<membership_requests_action><approve|reject><participant jid/>…`; `CancelGroupMembershipRequests` (requester withdraws): `<cancel_membership_requests><participant jid/>` |
| Community | `LinkSubGroups`: `to=<parent> <links><link link_type="sub_group"><group jid><hidden_group/>?</group>…`; `UnlinkGroups`: `<unlink unlink_type="sub_group"><group jid remove_orphaned_members="true"?/>`; `DeleteParentGroup`: `<delete_parent/>` (deactivate community); `JoinLinkedGroup`: `<join_linked_group type? jid/>` (member joins a sub-group of a community he is in); `GetLinkedGroup`, `GetLinkedGroupsParticipants`: `<linked_groups_participants/>`; `CreateSubGroupSuggestion`: `<sub_group_suggestion>` (non-admin proposes a group); `SubGroupSuggestionsAction`: `<sub_group_suggestions_action><approve|reject|cancel><sub_group_suggestion …/>` |
| Admin reports | `ReportMessages`: `<reports><report message_id/>…`; `GetReportedMessages`: `<reports/>` |
| Misc | `RevokeRequestCode`: `<revoke><participant jid/>` (revoke an add-request code); `AcknowledgeGroup`: `<ack/>`; `GetGroupProfilePictures` |

Enums (`WASmaxInGroupsEnums`): add reasons `accept|auto_add|default_sub_group_admin_add|general_chat_auto_add|invite|invite_auto_add|linked_group_join|sub_group_suggestion_approved`;
participant types `admin|superadmin`; delete reasons `deactivate_general_chat|delete_capi|delete_parent|integrity_delete_parent`;
unlink reasons `deactivate_group|delete_parent|integrity_delete_parent|unlink_group`; request methods `invite_link|linked_group_join|non_admin_add`; addressing `lid|pn`.

**Incoming `<notification type="w:gp2">`** (`WAWebHandleGroupNotification` → `WAWebHandleParsedGroupNotification` / `WAWebHandleGroupNotificationV2`). Child tags recognised (`WAWebHandleGroupNotificationConst.GROUP_NOTIFICATION_TAG`):
`add remove promote demote delete modify create subject description locked unlocked announcement not_announcement no_frequently_forwarded frequently_forwarded_ok invite ephemeral not_ephemeral revoke suspended unsuspended growth_locked growth_unlocked link unlink linked_group_promote linked_group_demote membership_approval_mode membership_approval_request created_membership_requests revoked_membership_requests allow_non_admin_sub_group_creation not_allow_non_admin_sub_group_creation allow_admin_reports not_allow_admin_reports reports created_sub_group_suggestion revoked_sub_group_suggestions change_number member_add_mode auto_add_disabled is_capi_hosted_group group_safety_check limit_sharing_enabled missing_participant_identification`,
plus `member_link_mode`, `member_share_group_history_mode`. Special case: `<notification type="w:gp2" from="g.us"><groups_dirty><group jid/>…</groups_dirty>` (`WASmaxInGroupsGroupsDirtyNotificationRequest`) → `WAWebHandleGroupsDirtyNotification` re-queries those groups. `membership_approval_request` carries `request_method` and optional `parent_group_jid`; add/remove carry `reason` from the enums above.

**Group history sharing** ("send recent messages to new members"). Gated by ab-props in `WAWebGroupHistoryGating` (`group_history_send`, `group_history_send_after_join`, `group_history_send_default_on`, `rt_ghs_sender_enabled`, `rt_ghs_receiver_enabled`, `group_history_messages_time_limit_secs`, …). Per-group mode is `member_share_group_history_mode` (MEX) plus `<group_history/>|<no_group_history/>` SetProperty. Sender (`WAWebGenerateGroupHistoryBundleMsgData`): serialises a `GroupHistory` protobuf (`WAWebProtobufsGroupHistory.pb`: `messages[]` WebMessageInfo, `uncountedAssociatedMessageLists[]`, `commentMessages[]`, `outOfWindowPinnedMessages[]`, `themeMessage`), compresses it, encrypts+uploads as media type `group-history` (HKDF info string `"Group History"`, `WAWebCryptoMediaTypeInfo`), and sends an E2E `messageHistoryBundle` (Message field 70: mimetype `application/protobuf`, mediaKey, directPath, hashes, `messageHistoryMetadata`) to the group. Receiver: `WAWebGroupHistoryBundleProcessor` downloads, decompresses (`WAWebDecompressAndDecodeBundle`), validates reporting tokens, and inserts messages before the anchor.

#### 1.2 whatsmeow coverage (group.go)

Implemented: `CreateGroup` (participants+privacy token, member_add_mode, parent/linked_parent, locked, announce, ephemeral, membership_approval_mode — `// TODO member_share_group_history_mode`), `LinkGroup`, `UnlinkGroup` (no `remove_orphaned_members`), `LeaveGroup` (single group only), `UpdateGroupParticipants` (add/remove/promote/demote), `GetGroupRequestParticipants`, `UpdateGroupRequestParticipants`, `SetGroupPhoto`, `SetGroupName`, `SetGroupTopic`, `SetGroupLocked`, `SetGroupAnnounce`, `SetGroupJoinApprovalMode`, `SetGroupMemberAddMode` (sends `<member_add_mode>` over w:g2; WA Web now uses MEX for this — the w:g2 path is presumably still accepted, unverified), `GetGroupInviteLink(reset)`, `GetGroupInfoFromInvite`/`JoinGroupWithInvite` (= AcceptGroupAdd), `GetGroupInfoFromLink`/`JoinGroupWithLink` (handles `membership_approval_request` reply), `GetJoinedGroups`, `GetSubGroups` (`<sub_groups/>` w:g2 query; WA Web uses MEX), `GetLinkedGroupsParticipants`, `GetGroupInfo`.
Notifications (`parseGroupChange`): add remove promote demote locked unlocked delete subject description announcement not_announcement invite ephemeral not_ephemeral link unlink membership_approval_mode suspended unsuspended, `create`; **everything else lands in `events.GroupInfo.UnknownChanges` as raw nodes** (so a client can parse them itself). Bug-ish: `membership_approval_mode` is always reported as enabled (state attr not read). Group history: proto exists (`proto/waGroupHistory`, `waE2E.MessageHistoryBundle`) but no send/receive logic and no `group-history` media type in `download.go`.

Missing in whatsmeow: DeleteParentGroup, JoinLinkedGroup, leave-community, CancelGroupMembershipRequests, sub-group suggestions, PromoteDemoteAdmin (superadmin/transfer), ReportMessages/GetReportedMessages, SetProperty variants (no_frequently_forwarded, allow_admin_reports, allow_non_admin_sub_group_creation, group_history), member_link_mode / member_share_group_history_mode, BatchGetGroupInfo, GetGroupProfilePictures, RevokeRequestCode, AcknowledgeGroup, all group MEX operations, typed parsing of ~25 notification tags (membership_approval_request, created/revoked_membership_requests, linked_group_promote/demote, growth_locked, revoke, member_add_mode, change_number, reports, sub-group suggestions, groups_dirty…).

### 2. Newsletters (channels)

#### 2.1 Two transports
1. **`xmlns="newsletter"` IQs** (WASmax `Newsletters` family) for message history and live counters.
2. **MEX**: GraphQL persisted queries over `xmlns="w:mex"` for everything else (metadata, follow, admin, directory).

#### 2.2 MEX transport (`WAWebMexClient` → `WAWebMexNativeClient` → `WAWebMexRelayEnvironment`)

**Request.** It is always `type="get"`, mutations included:
```
<iq id to="s.whatsapp.net" type="get" xmlns="w:mex"><query query_id="<doc id>">{"variables":{…}}</query></iq>
```

**Response.** The bytes of `<result>` hold UTF-8 JSON `{data, errors}`.
- `errors[].extensions.{error_code,is_summary,backoff_sec,is_retryable}` becomes `MexServerStatusCodeError`.
- Newsletter jobs retry via `WAWebNewsletterRpcUtils.runWithBackoff`.

**Doc ids.** Each one is the `params.id` of a `*.graphql.js` module. They are build-specific and rotate.

**Incoming notifications** (`WAWebHandleMexNotification`):
- Shape: `<notification type="mex"><update op_name="…">JSON</update></notification>`, dispatched by `op_name`.
- The client acks with `<ack class="notification" type="mex">`.
- An unknown op is nacked, except for a small ignore set.

#### 2.3 Newsletter MEX operations (current WA Web ids)

| Purpose | Job module | query_id | root field / variables |
|---|---|---|---|
| Create | WAWebMexCreateNewsletterJob | 25149874324715067 | `xwa2_newsletter_create {input:{name,description,picture}}` |
| Follow | WAWebMexJoinNewsletterJob | 24404358912487870 | `xwa2_newsletter_join_v2 {newsletter_id}` |
| Unfollow | WAWebMexLeaveNewsletterJob | 9767147403369991 | `xwa2_newsletter_leave_v2` |
| Mute/unmute | WAWebMexUpdateNewsletterUserSetting | 31938993655691868 | `xwa2_newsletter_update_user_setting {input:{newsletter_id,type:"MUTE_ADMIN_ACTIVITY"\|"MUTE_FOLLOWER_ACTIVITY",value:"ON"\|"OFF"}}` |
| Metadata | WAWebMexFetchNewsletterJob | 27456920720571478 | `xwa2_newsletter {input:{key,type,view_role},fetch_viewer_metadata,fetch_full_image,fetch_creation_time,fetch_status_metadata,fetch_pinned_messages…}` |
| Metadata (light) | WAWebMexFetchNewsletterDehydratedJob | 26944199458535748 | |
| All subscribed | WAWebMexFetchAllNewslettersMetadataJob | 25399611239711790 | `xwa2_newsletter_subscribed` |
| Update name/desc/pic/reactions | WAWebMexUpdateNewsletterJob | 24250201037901610 | `xwa2_newsletter_update {newsletter_id,updates:{…,settings:{reaction_codes:{value}}}}` |
| Delete | WAWebMexDeleteNewsletterJob | 30062808666639665 | `xwa2_newsletter_delete_v2` |
| Directory list | …FetchNewsletterDirectoryListJob | 26125047313831973 | `xwa2_newsletters_directory_list {input:{view,filters:{country_codes,categories},limit,start_cursor}}` |
| Directory search | …DirectorySearchResultsJob | 26301059626252132 | `xwa2_newsletters_directory_search` |
| Directory categories | …DirectoryCategoriesPreviewJob | 35266481849605779 | |
| Recommended | …FetchRecommendedNewslettersJob | 25806748772361516 | |
| Similar | …FetchSimilarNewslettersJob | 26217043484590756 | |
| Followers (admin) | …FetchNewsletterFollowersJob | 27472091235714801 | |
| Reaction senders | …MessageReactionSenderListJob | 29575462448733991 | `{input:{id,server_id}}` |
| Poll voters | …FetchNewsletterPollVotersJob | 9407762219322536 | |
| Admin invite create | …CreateNewsletterAdminInviteJob | 9387141988078609 | `{newsletter_id,user_id:<LID>}` |
| Admin invite accept | …AcceptNewsletterAdminInviteJob | 9580828702035549 | |
| Admin invite revoke | …RevokeNewsletterAdminInviteJob | 9656078347839416 | |
| Demote admin | …DemoteNewsletterAdminJob | 9880997548630971 | |
| Transfer owner | …ChangeNewsletterOwnerJob | 9546742745432473 | |
| Pin messages | …NewsletterPinMessagesJob | 27165709459706559 | |
| Unpin messages | …Unpin | 28007176042216937 | |
| Insights | | 9853618868050977 | |
| Admin info / capabilities / pending invites | | 26278439461859188 / 9801384413216421 / 28049623068067370 | |

Further operations exist for Q&A, block user, paid-partnership and AI labels, enforcement, appeals, link preview, and exposure logging.

**MEX notification ops** handled by Web:
- NewsletterJoin/Leave
- `xwa2_notify_newsletter_on_user_setting_change` (mute sync)
- `…_on_metadata_update`, StateChange
- AdminPromote/Demote, OwnerUpdate, AdminInviteRevoke, AdminProfile/MetadataUpdate
- Milestone, PaidPartnership/AIContent updates
- TextStatusUpdate

#### 2.4 `newsletter` xmlns IQs
- `GetNewsletterMessages`: `<messages count before|after>`, with a key that is `type="jid" jid` or `type="invite" key`, optional `view_role`.
- `GetNewsletterMessageUpdates`: `<message_updates count since after|before>`.
- `GetNewsletterStatuses` / `…StatusUpdates`: `<statuses>` / `<status_updates>`. These are channel statuses.
- `GetNewsletterResponses`: `<question_responses server_id count>`. This is channel Q&A.
- `MyAddOns`: `<my_addons limit jid?>`, with `type="status"` for statuses. It restores my own reactions and votes.
- `SubscribeToLiveUpdates`: `<live_updates/>` returns `<live_updates duration>`. Live updates then arrive as `<notification type="newsletter"><live_updates><messages><message server_id><views_count count/><reactions><reaction code count/>…`.

#### 2.5 Publishing (`WASmaxOutMessagePublishNewsletter*`, `WAWebNewsletterSendMessageQueryJob`)
Nothing is encrypted. The stanza is `<message to=<nl jid> id [server_id]>`. Its `<plaintext>` holds the serialized `Message` protobuf.

| Content | Shape |
|---|---|
| Text | `type="text"` |
| Media | `type="media" media_id`, `<plaintext mediatype>` |
| Admin edit | `edit="3"` |
| Admin delete | `edit="8"` with an empty plaintext |
| Reaction | `type="reaction" server_id <reaction code/>` |
| Reaction revoke | `edit="7"` |
| Poll vote | `type="poll"`, `<meta polltype="vote"><votes><vote>hash</vote>` |

The ack returns the `server_id`.

View receipts (`WASmaxOutReceiptPublishViewRequest`): `<receipt to=<nl> id type="view" [class="status"]><list><item server_id/>…(≤255)</list></receipt>`. `class="status"` marks channel statuses.

#### 2.6 whatsmeow (newsletter.go, send.go)

**Present**
- `CreateNewsletter`, `GetNewsletterInfo[WithInvite]`, `GetSubscribedNewsletters`, `Follow/UnfollowNewsletter`, `NewsletterToggleMute`
- `GetNewsletterMessages` (before only), `GetNewsletterMessageUpdates`, `NewsletterSubscribeLiveUpdates`, `NewsletterMarkViewed`, `NewsletterSendReaction`
- `sendNewsletter` (plaintext, mediatype, media_id, edit 3/8 all match), `UploadNewsletter`
- `sendMexIQ` builds the same stanza as Web.

**Problems**
- None of whatsmeow's hard-coded query ids appear in the current bundle. It uses older Web ids, for example `queryFetchNewsletter` 6563316087068696 and `mutationFollow` 9926858900719341. These presumably still resolve on the server (inferred).
- `convertQueryID` compares `*Platform` pointers: `GetUserAgent().Platform == waWa6.ClientPayload_UserAgent_MACOS.Enum()`. That comparison is always false, so only `WebInfo == nil` selects the "Desktop" ids.
- Two Desktop ids look wrong:
  - `mutationFollowNewsletterDesktop` is `8621797084555037`, the same value as `querySubscribedNewslettersDesktop`.
  - `mutationUpdateNewsletterDesktop` (7839742399440946) maps to `NotificationNewsletterUpdate` in whatsmeow's own `argo/name-to-queryids.json`.
- Mute uses separate mute/unmute mutations. Web uses `update_user_setting`.
- MEX notifications: whatsmeow handles only `on_join/leave/on_mute_change/milestone` (plus `account_reachout_timelock`). It ignores `on_user_setting_change`, `on_metadata_update`, `on_state_change` and the admin ops.

**Missing**
- Directory, search, recommended, similar (the recommended constant exists but nothing uses it).
- Delete, update metadata, admin invite/accept/revoke/demote, owner transfer, followers, pin.
- Reaction-sender list, poll voters, MyAddOns, channel statuses, poll vote publish, `class="status"` view receipt.

### 3. Status (status@broadcast)

**Audience** (`WAWebUserPrefsStatus.getStatusList`)
- Contacts: address-book contacts, as LIDs.
- AllowList: the stored list.
- DenyList: contacts minus the list, matched on both PN and LID.
- Fanout goes to these plus my own devices.

**Sender key** (`getStatusSkDistribList`)
- A persisted map records which devices already hold the status sender key. SKDM goes only to devices missing from it.
- If the audience shrinks (a full send reaches fewer devices than the map holds), the key is rotated (`rotateKey:true`).

**Stanza** (`WAWebEncryptAndSendStatusMsg`)
```
<message to="status@broadcast" id t phash><participants><to jid><enc pkmsg|msg/></to>…</participants><enc v=2 type="skmsg" mediatype/>[<device-identity>]<meta status_setting="contacts|allowlist|denylist" session_scope="status"/></message>
```
- Gated variants rename the tag to `<status>`: `status_e2ee_send_over_status_stanza`, and `web_status_send_via_smax` via `WASmaxStatusPublishPostBroadcastStatusRPC`, which adds `device_fanout`, `bucketing`, `<mentioned_users>`, `<tctoken>`.
- `web_status_recv_via_smax` routes incoming `<status>` stanzas, including **group status** (from a group JID), through `WAWebCommsClassifyStatusStanza`.

**Revoke.** Web sends a REVOKE `ProtocolMessage`.
- If earlier receivers are no longer in the audience, it goes pairwise to them (`encryptAndSendStatusDirectMsg`).
- Otherwise it goes via the sender key.

**Reactions.** These are addon messages sent pairwise to the author's devices plus my own (`WAWebSendStatusReactionAction`).

**Mentions.** Web parses and renders `StatusMentionMessage` / group mention. No Web send path was found (inferred).

**Privacy.** There is **no IQ** in Web.
- It goes through app-state `StatusPrivacyAction` (`WAWebStatusPrivacySettingSync`), collection `regular_high`.
- Modes: CONTACTS, ALLOW_LIST, DENY_LIST. CLOSE_FRIENDS and CUSTOM_LIST are ignored by Web.
- The only `xmlns="status"` IQ in Web is `WAWebSetAboutJob` (the "about" text).

**Viewing** (`WAWebSendReadReceiptJob.markStatusRead`)
```
<receipt to="status@broadcast" id type="read"|"read-self" class="status" participant=<author device> [peer_participant_pn] [t]>
```
It is `read-self` when my read receipts are off, the status is my own, or it is a PSA.

**Expiry.** Client-side, 24 h (`WAWebStatusCollection`).

**whatsmeow** (broadcast.go, send.go, receipt.go)

Audience
- It fetches privacy with the legacy `<iq xmlns="status" type="get"><privacy/>`. Web no longer uses this IQ; it presumably still works server-side (inferred).
- Contacts are store contacts that have a FullName.

Sending
- It resends SKDM to every device on every post.
- It never rotates the key when the audience shrinks (inferred).
- It adds no `<meta status_setting>`.
- It has no pairwise revoke.
- A phash mismatch is a TODO.

Receiving and other
- An incoming `<status>` tag goes to `handleUnencryptedMessage`, which acks and **drops** anything not from a newsletter. That would lose E2EE `<status>`-form and group statuses if the server uses them.
- `MarkRead` never adds `class="status"`.
- `IndexStatusPrivacy` is defined but neither emitted as an event nor writable.
- There is no status-reaction helper and no mentions or group status.

### 4. Calls / VoIP

#### 4.1 Architecture
JS is only a transport and crypto shell. The signaling state machine and the media both live in the Emscripten pthread WASM `wa_voip_shared.wasm` (C++/folly). It is loaded by `WAWebVoipWebWasmLoader`; the content-addressed form is `/wasm/whatsapp/versioned/<sha256>/wa_voip_shared.wasm`, and the variant comes from `web_voip_load_wasm_variant` = `"prod-nonlab"`.

Stack selection is `WAWebVoipStackInterface` → `…Impl`:
- `WAWebVoipStackInterfaceWeb` for the browser, usually proxied into a worker by `WAWebVoipStackInterfaceWorkerProxy`.
- `WAWebVoipStackInterfaceWindows` (native stack) for the Windows hybrid app.

**No JS module builds `<offer>`, `<accept>`, `<reject>`, `<terminate>`, `<transport>`, `<relaylatency>` or `<preaccept>`.** The flow is:
1. The WASM emits binary stanzas through `onSignalingXmpp({callId, peerJid, xmlPayload})`.
2. `WAWebVoipSendSignalingXmpp` decodes them.
3. For `offer`, `enc_rekey` and `transfer` it Signal-encrypts the `<enc>` call key (`E2E.Message{call:{callKey}}`) per device, adding `<device-identity>` for pkmsg.
4. It wraps the result in `<call to=<device jid | call jid> id>` and waits for `<ack class="call">`, which goes back to the WASM through `handleIncomingSignalingAck`.

Media runs over three possible transports:
- an RTCPeerConnection DataChannel to the WA relay, with a synthesized SDP (`WAWebVoipSctpConnectionManager`)
- WebTransport (gated)
- a P2P DataChannel (gated)

Audio uses AudioWorklets. Video uses WebCodecs.

#### 4.2 Incoming signaling (`WAWebHandleVoipCall`)
**Routing.** `WAWebCommsHandleLoggedInStanza` sends `case "call"` to `handleCall`.

**Parsing.**
- `<call>` attributes: `from`, `sender_lid`, `id`, `platform`, `version`, `offline`, `t`, `e`.
- Child attributes: `call-id`, `call-creator`, `group-jid`, `caller_pn`, `username`, `caller_country_code`, `notify`.
- Child elements and flags:
  - `<video/>` marks a video call
  - `<silence reason>`
  - `<group_info>` with `jid`, `user_pn`, `username`, `push_name`
  - on terminate, `reason`
  - `<terminate_hint>`

**Type enum** (`WAWebVoipSignalingEnums.TYPE`): OFFER, OFFER_RECEIPT, ACCEPT, REJECT, TERMINATE, TRANSPORT, OFFER_ACK/NACK, RELAY_LATENCY, RELAY_ELECTION, INTERRUPTION, MUTE, PREACCEPT, ACCEPT_RECEIPT, VIDEO_STATE, NOTIFY, GROUP_INFO, ENC_REKEY, PEER_STATE, FLOW_CONTROL, WEB_CLIENT, ACCEPT_ACK, GROUP_UPDATE, OFFER_NOTICE.

**Terminate reasons** include `accepted_elsewhere`, `rejected_elsewhere`, `group_call_ended` and `timeout`.

**Acknowledgement.** WA Web does not ack `offer`, `accept`, `reject` or `enc_rekey`. It sends a receipt instead, built by function `me()`:
```
<receipt to=FROM id=STANZA_ID><offer call-id call-creator/></receipt>
```
(The same shape is used with `accept`, `reject` or `enc_rekey` as the child.)
- This receipt goes out **even when calling is disabled**.
- Every other tag gets `<ack to id class="call" type=<child tag>>`.
- Incoming call `<receipt>`s (first child offer, accept or reject) go to the WASM and are acked with `class="receipt"`.

**Decrypt failure.** WA Web calls WASM `rejectCallWithoutCallContext(…, "enc"|"enc_rekey_retry", count+1, registrationId)`. This is a reject that asks the caller to re-send.

#### 4.3 Gating
`WAWebVoipGatingUtils`:
```
isCallingEnabled = isWindows ? true : isGuest ? true : getABPropConfigValue("enable_web_calling")
```

**Browser prerequisites** (`getUnsupportedBrowserReason`): `SharedArrayBuffer` (crossOriginIsolated), `Atomics`, `RTCPeerConnection`, and not a broken-WASM Safari.

**When calling is disabled**, `WAWebVoipActionWebHandleIncomingSignalingMessage` takes over:
- the call is only displayed, with no answer possible
- on terminate, a **local** call-log bubble is written (Missed / AcceptedElsewhere / Rejected)

**AB-prop defaults** (`WAWebABPropsConfigs`; the server overrides them):
- `enable_web_calling` false
- `enable_web_group_calling` false
- `web_calling_enable_on_windows` false
- `enable_web_voip_p2p` false
- `enable_web_voip_webtransport` false
- `enable_web_voip_proxy_and_sctp_workers` true
- `is_guest_calling_eligible` false
- `enable_waiting_room_ui` false
- `group_call_max_participants` 32
- `enable_hybrid_call_links_creation` / `_join` true

**Per-chat call button** (`WAWebShouldShowCallButtons.canCallContact`) is hidden for:
- self, blocked contacts, bots, newsletters, broadcasts
- announcement-only groups where I am not an admin
- groups where I am not a member

#### 4.4 Call links and the call log
- **Link create** (`WASmaxVoipLinkCreateRPC`):
  - request: `<call id to="call"><link_create media="audio|video" waiting_room_enabled?><event start_time/>?</link_create></call>`
  - reply: `<ack class="call" type="link_create"><link_create token …/>`
  - URL: `https://call.whatsapp.com/{voice|video}/<token>`
- **Link query:** `<call to="call"><link_query token media action?/>`.
- **Waiting room:** `<waiting_room_toggle enabled link-token media/>`. Join, preview, admit and deny all run inside the WASM.
- **Call-log bubbles** are local only (`addVoipCallLogMsgToChat`); nothing is sent.
- **App-state `CallLog`** (`WAWebCallLogSync`) is read-only on web, applying records newer than the pairing. Outgoing mutations exist only on Windows (`win_call_log_send_outgoing_syncd_mutations`).

#### 4.5 Rejecting a call
On the web stack, the UI reject (`useWAWebVoipCallHandlers.handleClickReject`) only calls WASM `rejectCall()`.
- The `<reject>` is built inside the WASM, then sent as `<call to=<caller device jid> id>…</call>` and acked with `class="call"`.
- JS adds **no** terminate, chat message or app-state mutation, only the local call-log bubble.
- The `<receipt><offer/></receipt>` was already sent when the offer arrived.
- JS warns when `call-creator`'s domain (LID vs PN) differs from the recipient's (`reject stanza domain mismatch`).
- The exact attributes of a plain user reject cannot be seen (inferred: `<reject call-id call-creator count="0"/>`, the shape whatsmeow uses).

**Answer: rejecting needs only the `<call><reject/></call>` stanza.** For parity, the client should also send the `<receipt><offer/></receipt>` on arrival, which whatsmeow does not do.

#### 4.6 whatsmeow (call.go, types/events/call.go)

**Events.** `handleCallEvent` emits:
- CallOffer, CallOfferNotice, CallRelayLatency, CallAccept, CallPreAccept, CallTransport, CallTerminate (with `reason`), CallReject
- UnknownCallEvent for everything else: mute, video, enc_rekey, interruption, flowcontrol, transfer

**`RejectCall`.** It sends `<call id from to=<caller non-AD user jid>><reject call-id call-creator count="0"/></call>`.

**Differences from Web**
- Every `<call>` gets a plain `<ack class="call">` **without** `type=<child>`.
- Offer, accept, reject and enc_rekey get that ack instead of a `<receipt><offer/></receipt>`. Inferred effect: the caller may not see "ringing" for this device.
- `RejectCall` targets the user JID, not the device JID, and adds `from`.

**Missing**
- `<enc>` call-key decryption, video/group_info parsing, call `<receipt>` handling.
- Call links.
- Call-log app-state events: the `call_log` index exists but no event is emitted.
- Anything for placing or answering calls.

#### 4.7 What a third-party client needs
- **Notify and reject: feasible today.** Use the CallOffer/OfferNotice events plus `RejectCall`, and write a local call-log entry.
- **Answer or place calls: needs WA's proprietary VoIP engine** (WASM or native), relay transport, the media pipeline, call-key E2E and ADV identity. It is not practical for a native client. The only realistic route is embedding web.whatsapp.com calling in QtWebEngine, which needs crossOriginIsolated/SharedArrayBuffer and `enable_web_calling` set server-side for the account (inferred).

### 5. Gaps for QWhats

| Pri | Gap | Closing needs |
|---|---|---|
| P1 | Incoming-call notification, Reject button, local missed/rejected bubble; dismiss on `accepted_elsewhere`/`rejected_elsewhere` terminate | client logic on existing whatsmeow events |
| P1 | Send `<receipt><offer call-id call-creator/></receipt>` (and for accept/reject/enc_rekey) and `type=<tag>` on call acks, as Web does | custom stanza (raw send or whatsmeow patch) |
| P1 | Group notifications whatsmeow leaves in `UnknownChanges`: membership_approval_request, created/revoked_membership_requests, revoke, member_add_mode, linked_group_promote/demote, change_number, growth_locked, groups_dirty (re-query); fix `membership_approval_mode` state | client logic (parse raw nodes) |
| P1 | Status privacy read/write through app-state `StatusPrivacyAction` (also keep the legacy IQ) | protobuf already present + app-state mutation |
| P1 | Status: `class="status"` on view receipts; audience = address-book LIDs; rotate the sender key when the audience shrinks (privacy) | custom stanza + client logic |
| P1 | Incoming `<status>` stanzas (E2EE/group status) are dropped by whatsmeow (`handleUnencryptedMessage`) | client logic / whatsmeow patch (verify the server sends that form) |
| P1 | Newsletter mute via `update_user_setting` MEX, and handling of `on_user_setting_change`/`on_metadata_update`/`on_state_change` MEX notifications | custom MEX + client logic |
| P1 | Own MEX wrapper with current doc ids (whatsmeow's ids are stale, two "Desktop" ids are wrong, the platform check is broken) | custom MEX |
| P2 | Community management: deactivate (`<delete_parent/>`), join sub-group (`<join_linked_group>`), leave community (`<leave><linked_groups parent_group_jid/>`), unlink with `remove_orphaned_members`, list sub-groups/announcement group (MEX FetchAllSubgroups), sub-group suggestions | custom w:g2 IQs / MEX |
| P2 | Group settings: member_link_mode / member_share_group_history_mode (MEX UpdateGroupProperty), allow_admin_reports, no_frequently_forwarded, allow_non_admin_sub_group_creation | custom MEX / w:g2 SetProperty |
| P2 | Withdraw my join request (`<cancel_membership_requests>`), admin reports (`<reports>`), PromoteDemoteAdmin/transfer community ownership (MEX) | custom IQ / MEX |
| P2 | Channel directory, search, recommended, similar | custom MEX |
| P2 | Channel admin: update, delete, admin invite/accept/revoke/demote, owner transfer, followers, pin | custom MEX |
| P2 | Newsletter MyAddOns (restore my reactions and votes), poll vote publish, reaction senders, poll voters | custom IQ / stanza / MEX |
| P2 | Status reactions (pairwise addon), status revoke parity (pairwise to past receivers) | client logic |
| P2 | Call history tab from app-state `CallLog` records | client logic (protobuf exists; whatsmeow emits no event) |
| P2 | Create a call link (`link_create`) and share it | custom stanza |
| P2 | Receive group history bundles (`messageHistoryBundle`, media type `group-history`, HKDF info "Group History", decompress `GroupHistory` proto) | client logic + media type (proto present in whatsmeow) |
| P3 | Send group history bundles; reporting-token validation | client logic + upload |
| P3 | Channel statuses, Q&A, insights, labels, enforcement; status mentions send; group status send; smax `<status>` publish | custom IQ / MEX / stanza |
| P3 | Answer or place calls, waiting room, link_query | full VoIP engine; out of scope natively |

---

## 06 — WhatsApp Web's internal data model (and what our core should expose)

Source: WhatsApp Web revision 1051067427 module dump (`mods/`). Model fields were extracted
mechanically from `X.prop(default)` / `X.session(default)` / `X.collection(C)` declarations in the
model constructors (`WAWebBaseModel` / `WAWebModelUtils`); IndexedDB tables from the
`WAWebSchema*` modules (`getStorage().add("table").version(v,[addColumn(..), addIndex(..)…])`).
`prop` = persisted/serialisable field, `session` = in-memory only (UI/runtime state).
Defaults shown as `=x` (`!1` = false, `!0` = true). Everything here is "seen" unless marked (inferred).

### 1. What WhatsApp Web does

#### 1.1 Model layer (Backbone-like)

- `WAWebBaseModel` is an observable model (`get/set`, `change:<field>` events, `stale` flag that
  triggers a lazy re-`find` when a UI observer attaches). `defineModel(cls)` registers it; each
  model has a `Proxy` name (`"msg"`, `"chat"`, `"contact"`, …) and an `idClass` (`WAWebWid` for
  chat/contact, `WAWebMsgKey` for messages).
- Collections (`WAWebBaseCollection`/`WAWebCollection`) hold models by id. Main ones:
  `WAWebChatCollection`, `WAWebMsgCollection` (global message cache, `hydrateOrGetMessages`),
  `WAWebChatMsgsCollection` (per-chat window), `WAWebContactCollection`,
  `WAWebGroupMetadataCollection`, `WAWebPresenceCollection`, `WAWebMuteCollection`,
  `WAWebLabelCollection`/`WAWebLabelItemCollection`, `WAWebProfilePicThumbCollection`,
  `WAWebReactionsCollection`, `WAWebPinInChatCollection`, `WAWebPollsPollVoteCollection`,
  `WAWebMsgInfoCollection` (per-recipient receipts), `WAWebStatusCollection` (stories),
  `WAWebCallCollection`, `WAWebNewsletterMetadataCollection`, `WAWebBlocklistCollection`,
  `WAWebQuickReplyCollection`, `WAWebStarredMsgCollection`, per-chat media/doc/link
  collections (`WAWebChatMediaMsgsCollection`, `WAWebChatDocMsgsCollection`,
  `WAWebChatLinkMsgsCollection`) used by the "Media, links and docs" drawer.
- Sub-objects are linked as session fields: `chat.contact`, `chat.groupMetadata`, `chat.presence`,
  `chat.mute`, `chat.newsletterMetadata`; `msg.senderObj`, `msg.mediaData`.

#### 1.2 Message key and ids

`WAWebMsgKey`: `{fromMe, remote: Wid, id, participant?}`, serialised as
`fromMe_remote_id[_participant]` (`[this.fromMe,this.remote,this.id].join("_")` + participant).
This string is the primary key of the `message` table and of every add-on table
(`reactions.parentMsgKey`, `message-info.msgKey`, …). Newsletter messages additionally carry
`serverId`. Chat/contact ids are `Wid`s; servers seen in `WAWebWid`: `c.us`, `s.whatsapp.net`,
`g.us`, `broadcast`, `newsletter`, `lid`, `hosted`, `hosted.lid`, `bot`, `call`.

#### 1.3 Msg model (`WAWebMsgModel`, Proxy `msg`) — 411 props, 42 session

Grouped (all `prop` unless noted):

- **Identity/envelope**: `id` (MsgKey), `rowId`, `serverId`, `parentServerId`, `from`, `to`,
  `author` (group sender), `notifyName` (push name at send time), `t` (seconds),
  `senderTimestampMs`, `clientReceivedTsMillis`, `serverStoreTimeMicros`, `type`, `subtype`,
  `typeFlag`, `invis`, `isNewMsg`, `recvFresh`, `broadcast`, `multicast`, `recipients`,
  `isMdHistoryMsg=!1` (came from history sync), `local=!1` (session), `senderWithDevice` (session).
- **Delivery**: `ack` (see 1.9), `isSendFailure`, `errorCode`, `read`.
- **Text**: `body`, `caption`, `isCaptionByUser`, `matchedText`, `title`, `description`
  (link preview), `thumbnail`, `thumbnailHQ`, `richPreviewType`, `doNotPlayInline`,
  `mentionedJidList`, `groupMentions`, `nonJidMentions`, `urlText`, `urlNumber`, `textColor`,
  `backgroundColor`, `font` (text status), `isSpoiler=!1`.
- **Context**: `quotedMsg`, `quotedStanzaID`, `quotedRemoteJid`, `quotedParticipant`,
  `quotedType`, `quotedGroupSubject`, `quotedParentGroupJid`, `contextInfo`, `isForwarded=!1`,
  `forwardingScore`, `forwardsCount=0`, `forwardedNewsletterMessageInfo`.
- **Star/keep/pin**: `star=!1`, `keepType`, `keptMessageKey`, `keptCount`, `kicKey`,
  `kicState`, `pinParentKey`, `pinMessageType`, `pinExpiryDuration`, `labels`.
- **Edit/revoke**: `latestEditMsgKey=null`, `latestEditSenderTimestampMs=null`, `editMsgType`,
  `protocolMessageKey`, `revokeSender`, `revokeTimestamp`, session `isOverwrittenByRevoke`,
  `revokeDuration`.
- **Reactions**: `hasReaction=!1`, `reactionParentKey`, `reactionText`, `reactionTimestamp`
  (on the reaction msg itself), `targetMessageKey`, `encIv`, `encPayload` (encrypted reaction).
- **Media** (persisted description; the live state is in `mediaData`): `directPath`,
  `deprecatedMms3Url`, `mediaKey`, `mediaKeyTimestamp`, `mimetype`, `filehash`, `encFilehash`,
  `size`, `filename`, `pageCount`, `duration`, `width`, `height`, `isGif`, `gifAttribution`,
  `isViewOnce`, `streamingSidecar`, `scanLengths`, `scansSidecar`, `firstFrameLength`,
  `firstFrameSidecar`, `waveform`, `staticUrl`, `metadataUrl`, `dashManifestUrl`,
  `thumbnailDirectPath`, `thumbnailSha256`, `thumbnailEncSha256`, `thumbnailWidth`,
  `thumbnailHeight`, `accessibilityLabel`, `mediaHandle`, `interactiveAnnotations`;
  stickers: `isAnimated`, `isAiSticker`, `isLottie`, `isAvatar`, `stickerPackId/Name/Publisher`,
  `stickers`, `emojis`, `stickerPremiumStatus`; `lastPlaybackProgress=0` (voice notes resume).
- **Location**: `lat`, `lng`, `loc`, `isLive`, `accuracy`, `speed`, `degrees`, `comment`,
  `sequence`, `shareDuration`, `final{Lat,Lng,Accuracy,Thumbnail,Speed,Degrees,TimeOffset}`.
- **Contacts**: `vcardList`, `vcardFormattedName`, `isVcardOverMmsDocument`.
- **Polls**: `pollName`, `pollOptions`, `pollSelectableOptionsCount`, `pollType`,
  `pollContentType`, `correctOptionIndex`, `pollEndTime`, `pollHideVoterNames`,
  `pollAllowAddOption`, `pollInvalidated=!1`, `pollUpdateParentKey`, `encPollVote`,
  `selectedOptionLocalIds`, `pollVotesSnapshot`, `messageSecret` (needed to decrypt votes).
- **Events (calendar)**: `eventName`, `eventDescription`, `eventStartTime`, `eventEndTime`,
  `eventLocation`, `eventJoinLink`, `isEventCanceled`, `eventIsScheduledCall`, …
- **Disappearing**: `ephemeralDuration`, `ephemeralSettingTimestamp`, `ephemeralOutOfSync`,
  `ephemeralSharedSecret`, `ephemeralSettingUser`, `disappearingModeInitiator/Trigger/InitiatedByMe`,
  `afterReadDuration`, `expiredTimestamp`, `viewMode`.
- **Calls (call_log msgs)**: `callOutcome`, `finalCallOutcome`, `isVideoCall=!1`,
  `callDuration`, `callParticipants`, `callCreator`, `callSilenceReason`, `isCallLink`,
  `callLinkToken`, `bytesSent/Received`.
- **Group invite msgs**: `inviteCode`, `inviteCodeExp`, `inviteGrp`, `inviteGrpName`,
  `inviteGrpJpegThum`, `inviteGrpType`.
- **Business/interactive/payments/bots**: `hydratedButtons`, `buttons`(session), `list`,
  `listResponse`, `nativeFlow*`, `interactive*`, `hsmTag`, `templateId`, `product*`, `order*`,
  `payment*`, `verifiedBizName`, `bizPrivacyStatus`, ~40 `bot*` fields, `richResponse`, …
  (low value for us).
- **Threads/comments/status**: `threadIds`, `replyCount`, `parentMsgKey`, `associationType`,
  `statusMentioned`, `isGroupStatus`, `isNewsletterStatus`, `viewCount`, `viewed=!1`.
- **Session-only**: `mediaData`, `senderObj`, `quotedMsgKey`, `isQuotedMsgAvailable=!0`,
  `startOfDay`, `search`, `pendingDeleteForMe`, `isRetry`, `isOffline`, `plainProtobufBytes`, …

`WAWebMediaData` (the per-message media state object, `msg.mediaData`): `type`, `mediaStage`
(`INIT, EXISTS, PREPARING, UPLOADING, FINALIZING, SENDING, REUPLOADING, FETCHING, DECRYPTING,
RESOLVED, NEED_POKE, NEED_UPLOAD, ERROR_FILE_NOT_READABLE, ERROR_MISSING, ERROR_TOO_LARGE,
ERROR_UNSUPPORTED, ERROR_FORBIDDEN, PROGRESSIVE_READY, REMOTE_UPLOADING, REMOTE_NEED_UPLOAD` —
`WAWebMediaTypes`), `size`, `loadedSize`, `mimetype`, `filename`, `renderableUrl`, `mediaBlob`,
`fullWidth/fullHeight`, `aspectRatio`, `preview` (thumb), `duration`, `waveform`, `pageCount`,
`documentPreview`, `isPasswordProtected`, `parsedVcards`, `suspiciousContent`, `isViewOnce=!1`,
`isGif`, sticker flags. `NEED_POKE`/`REUPLOADING` = the media-retry (re-upload request) path.

#### 1.4 Chat model (`WAWebChatModel`, Proxy `chat`) — 75 props, 59 session

- props: `id`, `accountLid`, `t` (last activity), `unreadCount=0`, `unreadDividerOffset=0`,
  `unreadMentionsOfMe`, `unreadMentionCount`, `hasUnreadMention=!1`, `archive`, `pin` (a
  timestamp-like ordering value; falsy = unpinned) (inferred from usage), `muteExpiration=0`,
  `mentionAllMuteExpiration`, `callMuteExpiration`, `isAutoMuted=!1`, `isReadOnly`, `isLocked`
  (locked chats), `isAnnounceGrpRestrict`, `name`, `notSpam`, `modifyTag`,
  `changeNumberOldJid/NewJid`, `lastReceivedKey`, `ephemeralDuration`,
  `ephemeralSettingTimestamp`, `afterReadDuration`, `disappearingMode{Initiator,Trigger,InitiatedByMe}`,
  `endOfHistoryTransferType`, `chatlistPreview`, `previewT`, `lastReactionPreview`,
  `unreadEditTimestampMs`, `draftMessage`, `hasOpened`, `lastChatEntryTimestamp`,
  `chatViewMode=VISIBLE` (`VISIBLE|ONLY_MARKETING_FROM_SELF`), `tcToken`, `tcTokenTimestamp`,
  `tcTokenSenderTimestamp`, `historyChatId`, `lidOriginType`, wallpaper/theme fields
  (`wallpaper`, `chatThemeId`, `colorSchemeId`, …), `toneId`, `limitSharing`, `acp2Setting`,
  `isSenderNewAccount`, `isSenderSuspicious`, biz/AI fields.
- session: `markedUnread`, `active`, `typing`, `recording`, `presence`, `mute`, `contact`,
  `groupMetadata`, `newsletterMetadata`, `broadcastMetadata`, `formattedTitle`, `canSend`,
  `trusted`, `isFavorite=!1`, `composeQuotedMsg`, `draftMessageSortTs`, `mediaCount`,
  `linkCount`, `docCount`, `endOfHistoryTransfer=!1`, `isParentGroup`, `groupType`,
  `pendingSeenCount`, `squelch`, …
- Chat "kind" is not a field; it is derived from the Wid server (user/lid, group, broadcast,
  newsletter, bot) plus `groupMetadata.isParentGroup` / `parentGroup` (community/subgroup).

#### 1.5 Contact model (`WAWebContactModel`, Proxy `contact`) — 33 props, 21 session

props: `id`, `name` (address-book name), `shortName`, `pushname`, `type="in"`,
`isDeactivated=!1`, `verifiedName`, `verifiedLevel`, `isBusiness`, `isEnterprise`, `isSmb`,
`privacyMode`, `statusMute`, `parentStatusMute`, `sectionHeader`, `labels`,
`isContactSyncCompleted`, `disappearingModeDuration`, `disappearingModeSettingTimestamp`,
`isEphemeralityDisabled`, `textStatusString`, `textStatusEmoji`,
`textStatusEphemeralDuration`, `textStatusLastUpdateTime`, `textStatusExpiryTs`,
`requestedPnTimestamp`, `username`, `usernameKey`, `usernameCountryCode`,
`isUsernameContact=!1`, `externalUserState`, `syncToAddressbook=!1`.
session: `isContactBlocked=!1`, `status` (about text), `profilePicThumb`, `businessProfile`,
`commonGroups`, `phoneNumber`, `displayNameLID`, `shareOwnPn`, `isFavorite`, `locale`, …

Display-name precedence (inferred from fields): `name` (address book) → `verifiedName`
(business) → `pushname` (shown as "~pushname" with the number) → formatted phone.

#### 1.6 Group metadata (`WAWebGroupMetadataModel`) and participants

props: `id`, `creation`, `owner`, `subject`, `subjectTime`, `desc`, `descId`, `descTime`,
`descOwner`, `restrict` (only admins edit info), `announce` (only admins send),
`noFrequentlyForwarded`, `ephemeralDuration`, `afterReadDuration`, `membershipApprovalMode`,
`memberAddMode`, `memberLinkMode`, `reportToAdminMode`, `size`, `numSubgroups`, `support`,
`suspended=!1`, `terminated=!1`, `isLidAddressingMode`, `isParentGroup`, `isParentGroupClosed`,
`parentGroup`, `defaultSubgroup`, `generalSubgroup`, `hiddenSubgroup`, `groupAdder`,
`lastActivityTimestamp`, `memberShareGroupHistoryMode`, …
collections: `participants` (`WAWebGroupParticipantModel`: `id`, `isAdmin`, `isSuperAdmin`,
`joinTime`, `leaveTs`, `leaveReason`, session `contact`), `pendingParticipants`,
`pastParticipants`, `membershipApprovalRequests` (`id, t, addedBy, requestMethod,
parentGroupId`), `subgroupSuggestions`. session: `inviteCode`, `displayedDesc`, `joinedSubgroups`,
`unjoinedSubgroups`.

#### 1.7 Presence / chat state (`WAWebPresenceModel`)

props: `id`, `type`, `t`, `deny`; session: `isOnline=!1`, `hasData`, `isSubscribed`,
`chatActive`, `chatstate`, `typingUserIds=[]`, `recordingUserIds=[]`, `groupOnlineCount=0`,
`updateTime`; collection `chatstates` (per-participant; getters `type`, `deny`, `t` in
`WAWebChatstateGetters`). Chat-state values (`WAChatState`): `typing`, `recording_audio`, `idle`.
`deny` = the contact's privacy hides last-seen. Nothing of presence is persisted (no table).

#### 1.8 Other models

- `WAWebMuteModel`: `id`, `expiration=0`, `callExpiration=0`, `mentionAllMuteExpiration=0`, `isAutoMuted`.
- `WAWebLabelModel`: `id`, `name`, `colorIndex`, `color`, `count`, `chatCount`, `orderIndex`,
  `predefinedId`, `isActive`, `type` (`WAWebSchemaLabel` enum: NONE 0, UNREAD 1, GROUPS 2,
  FAVORITES 3, PREDEFINED 4, CUSTOM 5, COMMUNITY 6, …, MENTIONS_AND_REPLIES 17 — i.e. the chat-list
  filter chips are labels), `isImmutable`.
- Reactions (`WAWebReactionsModels`): `reactions` {`id`, `msgKey`, `parentMsgKey`,
  `reactionText`, `timestamp`, `senderUserJid`, `read`, `orphan`}; aggregated per message as
  `aggReactions` {`aggregateEmoji`, `hasReactionByMe`, `senders`} and `reactionByMe`.
- `WAWebPinInChatModel`: `msgKey`, `parentMsgKey`, `senderTimestampMs`, `t`, `sender`,
  `chatId`, `pinType`, `pinExpiryDuration`, `read`.
- `WAWebPollsPollVoteModel`: `msgKey`, `parentMsgKey`, `selectedOptionLocalIds`,
  `senderTimestampMs`, `t`, `sender`, `read`.
- `WAWebMsgInfoModel` (message info drawer): per-recipient `delivery`/`read`/`played`
  collections, `deliveryRemaining`, `readRemaining`, `playedRemaining`, `usePlayReceipt`.
- `WAWebProfilePicThumbModel`: `id`, `tag`, `eurl`, `previewEurl`, `fullDirectPath`,
  `previewDirectPath`, `filehash`, session `timestamp`, `stale`.
- `WAWebStatusModel` (stories per contact): `id`, `t`, `unreadCount`, `totalCount`, `pic`,
  `statusMsgs`, session `readKeys`, `expireTs`.
- `WAWebCallModel` (plain class, live call only): `id`, `peerJid`, `offerTime`, `isVideo`,
  `isGroup`, `groupJid`, `outgoing`, `isSilenced`, `silenceReason`, `isCallLink`,
  `callLinkToken`, `callLogResult`, `callFailedReason`, … The call *history* is ordinary
  `call_log` messages (indexed `isCallLogMsg`, `callOutcome` in the message table).
- `WAWebNewsletterMetadataModel`: `name`, `description`, `handle`, `inviteCode`, `size`,
  `verified`, `membershipType`, `privacy`, `website`, `reactionCodesSetting`, `pinnedMessages`,
  `suspended`, `terminated`, `adminCount`, `capabilities`, `statusMute`, …
- `WAWebBusinessProfileModel`: `description`, `categories`, `email`, `website`, `address`,
  `latitude/longitude`, `businessHours`, `catalogStatus`, …
- `WAWebChatPreferenceModel` (global UI prefs): `enterIsSend`, `spellcheck`,
  `autoplayAnimatedImages`, `hdMediaEnabled`, `chatlistDensity`, `wallpaper`, `chatThemeId`, …
- `WAWebQuickReplyModel`: `shortcut`, `message`, `count`, `keywords`. `WAWebNoteModel`:
  `type`, `chatJid`, `content`, `createdAt`, `modifiedAt`.

#### 1.9 Enumerations the UI depends on

- **ACK** (`WAWebAck.ACK`): `INACTIVE -6, CONTENT_UNUPLOADABLE -5, CONTENT_TOO_BIG -4,
  CONTENT_GONE -3, EXPIRED -2, FAILED -1, CLOCK 0, SENT 1, RECEIVED 2, READ 3, PLAYED 4, PEER 5`.
  `ACK_STRING` (receipt `type` attr): `sender, delivery, read, played, inactive, read-self,
  played-self`. `EDIT_ATTR` (stanza `edit` attr): `NONE -1, MESSAGE_EDIT 1, PIN_IN_CHAT 2,
  NEWSLETTER_MSG_EDIT 3, SENDER_REVOKE 7, ADMIN_REVOKE 8`. (Protobuf
  `WebMessageInfo.Status`: `ERROR, PENDING, SERVER_ACK, DELIVERY_ACK, READ, PLAYED`.)
- **Message types** (`WAWebMsgType.MSG_TYPE`, 70 values): user-visible: `chat, image, video,
  ptv, audio, ptt, document, sticker, sticker-pack, location, vcard, multi_vcard, album, poll_creation,
  poll_update, poll_result_snapshot, event_creation, event_response, reaction, reaction_enc,
  revoked, ciphertext, groups_v4_invite, keep_in_chat, pin_message, pinned_message,
  message_edit_encrypted, comment, music, oversized, quarantined, unknown, status, product,
  order, payment, list, list_response, buttons_response, template_button_reply, interactive,
  interactive_response, native_flow, hsm, rich_response, newsletter_admin_invite,
  newsletter_follower_invite, request_phone_number, sharable_event_invite, group-history,
  history_bundle, message_history_notice, loading_media, biz_content_placeholder, …`.
  `SYSTEM_MESSAGE_TYPES`: `broadcast_notification, call_log, debug, e2e_notification, gp2,
  newsletter_notification, notification, notification_template, protocol, pinned_message,
  poll_add_option_decrypted`. `MESSAGE_TYPE_FLAGS` (`typeFlag`, indexed): `MEDIA_MSG 1,
  DOC_MSG 2, HAS_LINK 4`. A finer `MsgKind` enum (e.g. `locationLive`, `protocolRevoke`,
  `reactionDecrypted`, `pollVoteEncrypted`) exists for rendering dispatch.
- **Subtypes** (`WAWebCommonMsgSubtypeTypes.MsgSubtype`, 276 values). Those a desktop client
  must render: gp2: `create, subject, description, picture, add, remove, leave, invite,
  promote, demote, restrict, announce, ephemeral, revoke_invite, v4_add_invite_join,
  membership_approval_mode, membership_approval_request, member_add_mode, delete, suspend,
  linked_group_join, parent_group_link/unlink, sub_group_link/unlink, change_number`; e2e:
  `encrypt, encrypt_now, identity, device, e2e_identity_unavailable`; call_log: `miss,
  miss_video, miss_group, miss_group_video, silence`; protocol: `admin_revoke, sender_revoke,
  ephemeral_setting, message_edit, history_sync_notification`; ciphertext: `fanout,
  view_once_unavailable_fanout, bot_unavailable_fanout`; disappearing: `disappearing_mode,
  disappearing_mode_update`; `block_contact`, `biz_name_change`, verified-business transitions,
  `keep_in_chat`, `poll_vote`, `reaction`.
- **Media stages** (1.3); **chat view mode**; **label types** (1.8); **presence** `WithholdDisplayStage`.

#### 1.10 Persistence: IndexedDB tables (`WAWebSchema*`, 132 modules)

Key point: the message row stores declared columns **plus** an encrypted protobuf blob
`msgRowOpaqueData` (`WAWebDBMessageSerialization`, keys in `WAWebDBMsgOpaqueDataKeys`):
`body, caption, loc, lat, lng, isLive, matchedText, title, description, pollName,
pollSelectableOptionsCount, pollEndTime, pollUpdateParentKey, encPollVote, senderTimestampMs,
targetMessageKey, encIv, encPayload, event*, messageSecret, clientUrl, mediaPngThumbnail, …`
— i.e. all user text is encrypted at rest; the plain columns are metadata. `chat.chatRowOpaqueData`
and `tcToken` are likewise encrypted columns.

Tables relevant to the UI model (pk; indexed columns):

| table | pk | notable columns / indexes |
|---|---|---|
| `message` | `id` (MsgKey string) | ~300 cols (all of 1.3 minus text). unique `internalId`, `rowId`; idx `isStarred`, `expiredTimestamp`, `messageRangeIndex`, `latestEditMsgKey`, `isCallLogMsg`, `callOutcome`, `protocolMessageKey`; composite `[internalId,isMediaMsg]`, `[internalId,isDocMsg]`, `[internalId,hasLink]`, `[internalId,isStarred]`, `[internalId,isEventMsg]`, `[internalId,isCallLogMsg]`, `[typeFlag,t,internalId]`, `[from,pendingReadReceipt]`; array idx `vcardWAids` |
| `chat` | `id` | 70+ cols (1.4); idx `ephemeralDuration`, `tcTokenTimestamp`; unique `accountLid`, `historyChatId` |
| `contact` (`WAWebSchemaContact_DO_NOT_USE_DIRECTLY`) | `id` | `name, shortName, pushname, type, verifiedName, isBusiness, isEnterprise, verifiedLevel, statusMute, username*, phoneNumber, displayNameLID, textStatus*, disappearingModeDuration, isAddressBookContact, syncToAddressbook`; idx `isAddressBookContact`, `phoneNumber`, `contactHash`, `textStatusExpiryTs` |
| `group-metadata` | `id` | all of 1.6 scalars (`subject, desc, owner, creation, restrict, announce, ephemeralDuration, size, parentGroup, isParentGroup, …`); idx `parentGroup`, `ephemeralDuration` |
| `participant` | `groupId` | `participants, admins, superAdmins, pastParticipants, senderKey, rotateKey, version` (Signal fan-out + roster) |
| `group-member-changes` | autoinc | `groupJid, participantJid, changeTimestamp, changeAction` |
| `pending-membership-approval-request` | `[groupId,id]` | `t, addedBy, requestMethod` |
| `reactions` | `[parentMsgKey,senderUserJid]` | `msgKey, reactionText, timestamp, orphan, read, ack, t`; idx `parentMsgKey`, `orphan`, `msgKey` |
| `addons-unified` | `msgKey` | `targetMsgKey, rowType, ack, t, read, addonProps` (generic add-ons: poll votes, edits, pins…) |
| `message-info` | `[msgKey,receiverUserJid]` | `delivery, read, played, deviceDelivered` (per-recipient receipts) |
| `message-association` / `message-history` | `[msgKey,associationType]` / `msgKey` | `parentMsgKey` (albums, edit history) |
| `message-orphans`, `orphan-receipt`, `orphan-revoke` | — | add-ons/receipts that arrived before their parent |
| `label`, `label-association` | `id`; `[labelId,associationId,type]` | `name, colorIndex, predefinedId, orderIndex, isActive, type` |
| `profile-pic-thumb` | `id` | `tag, eurl, previewEurl, previewDirectPath, fullDirectPath, filehash, timestamp` |
| `status` (status DB) | autoinc | `status_uuid`(unique), `sender_user_jid, type, timestamp, state, is_archived, media_row_id` |
| `newsletter-metadata` | `id` | as 1.8 |
| `blocklist`, `favorite`(`orderIndex`), `quick-reply`, `note`, `user-prefs`(k/v), `verified-business-name`, `lid-pn-mapping`, `lid-display-name-mapping`, `device-list`, `history-sync-notification`, `sync-actions`/`sync-keys` (app state), `active-message-ranges` | | |

Not persisted (session only): presence/chat states, live calls, media blobs (separate LRU
`WAWebSchemaLruMedia*` caches), drafts' attachments, `MsgInfo` remaining-counters. Full-text
search has its own tables (`WAWebSchemaFtsV1/V2/V3Index`, `fts-indexing-queue`).

### 2. whatsmeow coverage (for building the same model)

| WA Web field group | whatsmeow source |
|---|---|
| msg envelope: id, chat, from/author, fromMe, t, notifyName, broadcast/multicast, edit attr | `types.MessageInfo` (`ID, ServerID, Chat, Sender, IsFromMe, IsGroup, SenderAlt, PushName, Timestamp, Type, MediaType, Category, Multicast, Edit, VerifiedName, BroadcastListOwner`) in `events.Message.Info` |
| view-once/ephemeral/edit/doc-with-caption wrappers | `events.Message.IsViewOnce*, IsEphemeral, IsEdit, IsDocumentWithCaption, IsLottieSticker` (already unwrapped) |
| quote, mentions, forwarded, ephemeral expiry | `waE2E.ContextInfo` on each content message: `StanzaID, Participant, RemoteJID, QuotedMessage, MentionedJID, GroupMentions, IsForwarded, ForwardingScore, Expiration, EphemeralSettingTimestamp` |
| media metadata | `waE2E.{Image,Video,Audio,Document,Sticker}Message`: `Mimetype, FileLength, FileSHA256, FileEncSHA256, MediaKey, DirectPath, Seconds, PTT, Waveform, Width, Height, JPEGThumbnail, FileName, PageCount, GifPlayback, ViewOnce, IsAnimated` ; download `Client.Download*`; re-upload `SendMediaRetryReceipt` + `events.MediaRetry` (= WA's `NEED_POKE`) |
| ack | `events.Receipt` (`Type`: `""`=delivered, `read`, `read-self`, `played`, `played-self`, `sender`, `retry`, `server-error`, `inactive`) + server ack = `SendMessage` return (`SendResponse.Timestamp/ServerID`) |
| reactions | `waE2E.ReactionMessage` (`Key, Text, SenderTimestampMS`); encrypted ones `Client.DecryptReaction` |
| edit / revoke | `ProtocolMessage{Type: MESSAGE_EDIT, EditedMessage}`, `REVOKE`; admin revoke = `MessageInfo.Edit == "8"` |
| polls | `PollCreationMessage(V3/V5)`, `PollUpdateMessage` + `Client.DecryptPollVote` (needs `MsgSecretStore`, stored automatically) |
| pin in chat / keep | `waE2E.PinInChatMessage`, `KeepInChatMessage` (raw protobuf only) |
| history (all of the above for old msgs + status, starred, stub types, reactions, userReceipt) | `events.HistorySync` → `waWeb.WebMessageInfo` (`status, starred, messageStubType, messageStubParameters, reactions, pollUpdates, userReceipt, ephemeralDuration, pinInChat, keepInChat, revokeMessageTimestamp, …`) via `Client.ParseWebMessage` |
| chat props | history `waHistorySync.Conversation`: `unreadCount, unreadMentionCount, markedAsUnread, archived, pinned, muteEndTime, ephemeralExpiration, ephemeralSettingTimestamp, readOnly, name, displayName, lastMsgTimestamp, conversationTimestamp, notSpam, endOfHistoryTransferType, pnJID/lidJID, username, locked, limitSharing, suspended, terminated, description, isParentGroup, parentGroupID, createdAt/createdBy`; live: app-state events `Pin, Archive, Mute, MarkChatAsRead, ClearChat, DeleteChat, Star, DeleteForMe, LabelEdit, LabelAssociationChat/Message`; `store.ChatSettingsStore` keeps `MutedUntil, Pinned, Archived` only |
| contact | `store.ContactStore` → `types.ContactInfo{FirstName, FullName, PushName, BusinessName, RedactedPhone}`; events `Contact`, `PushName`, `BusinessName`; `GetUserInfo` (`Status`, `PictureID`, `Devices`, `VerifiedName`, `LID`); `GetBusinessProfile`; `GetBlocklist` + `events.Blocklist`; `events.UserAbout`, `events.Picture`; `store.LIDStore` (lid↔pn) |
| group metadata | `GetGroupInfo` → `types.GroupInfo` (`Name/NameSetAt/NameSetBy`, `Topic/TopicID/TopicSetAt/TopicSetBy`, `IsLocked`(=restrict), `IsAnnounce`, `GroupEphemeral`, `IsIncognito`, `GroupParent`/`GroupLinkedParent` (communities), `MembershipApprovalMode`, `MemberAddMode`, `AddressingMode`, `GroupCreated`, `OwnerJID`, `Participants[]{JID, LID, PhoneNumber, IsAdmin, IsSuperAdmin, DisplayName}`, `Suspended`); live changes `events.GroupInfo` (`Name, Topic, Locked, Announce, Ephemeral, Join, Leave, Promote, Demote, Link, Unlink, Delete, NewInviteLink, Sender, Timestamp`), `events.JoinedGroup` |
| presence / chat state | `events.Presence{From, Unavailable, LastSeen}` (after `SubscribePresence`), `events.ChatPresence{State: composing|paused, Media: ""|audio}` |
| calls | `events.CallOffer, CallAccept, CallTerminate(Reason), CallOfferNotice(Media, Type=group)`, `CallReject` — no call_log message is created live; old ones arrive in history as `call_log`-equivalent stub types / `CallLogMessage` (inferred) |
| newsletter | `GetNewsletterInfo`, `GetSubscribedNewsletters`, `events.NewsletterJoin/Leave/MuteChange/LiveUpdate`, `events.Message.NewsletterMeta` |
| undecryptable (`ciphertext` type) | `events.UndecryptableMessage{IsUnavailable, UnavailableType (view_once / bot / hosted), DecryptFailMode}` |
| stub types (`gp2`, `e2e_notification`, `call_log` system rows) | only in history (`WebMessageInfo.messageStubType` + `messageStubParameters`); live they must be synthesised from `events.GroupInfo`, `events.IdentityChange`, `CallOffer/Terminate`, `ProtocolMessage{EPHEMERAL_SETTING}` |

whatsmeow keeps no message, chat or group store of its own (beyond contacts, chat settings,
LID map and message secrets) — everything in sections 1.3–1.6 has to live in our `core.db`.

### 3. Gaps: what our core should add

Current core (`core/normalize.go`, `core/store.go`): `Message{id, chat, sender, fromMe, time,
kind, text, caption, quote{id,sender,text}, media{mime,size,name,seconds,width,height,thumb,path},
status, target, emoji, lat, lng}`; table `chats(account, jid, name, time, preview, unread, pinned,
archived, muted, …)`, `contacts(account, jid, name)`, `messages(…, json, raw)` + FTS5. All of this
is client-side logic (store + normalisation); none needs a custom stanza unless noted.

#### 3.1 Message (P1 = daily-use parity)

| add | why (WA Web field) | whatsmeow source | P |
|---|---|---|---|
| `senderName` (push name at receipt) | `notifyName`; group bubbles show it for non-contacts | `MessageInfo.PushName` | P1 |
| `status` as full ACK ladder incl. `error`/`pending`/`server` and per-message upgrade | `ack` (-1..4); clock vs single tick | `SendMessage` result (server ack), `events.Receipt` types, history `WebMessageInfo.status` | P1 |
| `edited` (bool + `editedAt`), apply edit to the target row instead of a separate `edit` kind | `latestEditMsgKey`, `latestEditSenderTimestampMs` | `ProtocolMessage MESSAGE_EDIT` / `events.Message.IsEdit` | P1 |
| `revoked` applied to the target (`kind=revoked`, `revokedBy` admin/sender) | `type=revoked`, `revokeSender`, subtype `admin_revoke`/`sender_revoke` | `ProtocolMessage REVOKE`; `MessageInfo.Edit` 7/8 | P1 |
| `reactions` aggregated on the parent (`[{emoji, senders[], byMe}]`) | `aggReactions{aggregateEmoji, hasReactionByMe, senders}`; table `reactions` pk `[parentMsgKey,senderUserJid]` (one per sender, replace on change, empty text = remove) | `ReactionMessage`; history `WebMessageInfo.reactions` | P1 |
| `mentions[]` (jids) + render `@name` | `mentionedJidList`, `groupMentions` | `ContextInfo.MentionedJID` | P1 |
| `forwarded` (+ `frequentlyForwarded` when score ≥ 5) | `isForwarded`, `forwardingScore` | `ContextInfo.IsForwarded/ForwardingScore` | P1 |
| `quote.kind`/`quote.thumb`, `quote.chat` (reply from other chat) | `quotedType`, `quotedRemoteJid` | `ContextInfo.QuotedMessage/RemoteJID` | P1 |
| `system` rows with `subtype` + params (group add/remove/subject/…, e2e/identity change, disappearing toggled, missed call) | `type` gp2/e2e_notification/call_log/notification_template + `subtype` (1.9) | history `messageStubType/Parameters`; live synthesise from `events.GroupInfo`, `IdentityChange`, `CallOffer`+`CallTerminate`, `ProtocolMessage EPHEMERAL_SETTING` | P1 |
| `ciphertext` placeholder ("waiting for this message") | `type=ciphertext`, subtypes `fanout`, `view_once_unavailable_fanout` | `events.UndecryptableMessage` (+ later `Message` with same ID replaces it) | P1 |
| media: `sha256`, `encSha256`, `mediaKey`, `directPath` kept server-side (not sent to UI) + `media.state` (`remote|downloading|ready|expired|error`) | `mediaData.mediaStage`; `NEED_POKE` | needed by `Download`; `SendMediaRetryReceipt` + `events.MediaRetry` for expired media | P1 |
| `media.waveform` (voice notes), `media.gif`, `media.viewOnce`, `media.pages`, `media.animated` (stickers) | `waveform`, `isGif`, `isViewOnce`, `pageCount`, `isAnimated` | `AudioMessage.Waveform`, `VideoMessage.GifPlayback`, `events.Message.IsViewOnce`, `DocumentMessage.PageCount`, `StickerMessage.IsAnimated` | P1 (waveform, gif, viewOnce) / P2 |
| link preview: `preview{url,title,description,thumb}` | `matchedText`, `title`, `description`, `thumbnail`, `richPreviewType` | `ExtendedTextMessage.MatchedText/Title/Description/JPEGThumbnail` | P1 |
| `starred` | `star` (indexed) | history `WebMessageInfo.starred`; app-state `events.Star` | P1 |
| `expiresAt` / `ephemeral` seconds | `ephemeralDuration`, `expiredTimestamp` (indexed for the reaper) | `ContextInfo.Expiration` + `events.Message.IsEphemeral` | P1 (otherwise disappearing chats keep everything) |
| poll: structured `poll{name, options[{name, votes, voters[]}], selectable, myVotes}` instead of text | `pollName`, `pollOptions`, `pollSelectableOptionsCount`, `PollVote` table | `PollCreationMessage*`, `PollUpdateMessage` + `DecryptPollVote` (MsgSecretStore) | P2 |
| contact cards: `vcards[{name, vcard}]`, multi_vcard | `vcardList`, `vcardFormattedName` | `ContactMessage.Vcard`, `ContactsArrayMessage` | P2 |
| live location (`live`, `accuracy`, `seq`) | `isLive`, `accuracy`, `sequence` | `LiveLocationMessage` | P2 |
| `pinned` in chat (+ expiry) | `PinInChatModel` | `waE2E.PinInChatMessage` | P2 |
| album grouping (`parentMsgKey`, association) | `message-association`, `type=album` | `AlbumMessage` + `MessageContextInfo.MessageAssociation` (raw proto) | P2 |
| event (calendar) messages, `keep_in_chat`, newsletter `serverId`/views | event*, `kicState`, `viewCount` | raw proto | P3 |
| buttons/list/template/payments/bots | ~100 fields | raw proto | P3 (render body/caption fallback only) |

Also: store a per-recipient receipt table (`msgKey, user, delivered, read, played`) like
`message-info` for the "Message info" dialog in groups — P2, from `events.Receipt` (MessageSource.Sender).

#### 3.2 Chat (`chats.list` row)

| add | WA Web field | whatsmeow source | P |
|---|---|---|---|
| `kind` (`user|group|community|broadcast|newsletter|status`) | derived from Wid server + `isParentGroup` | `JID.Server` (`s.whatsapp.net`/`lid`, `g.us`, `broadcast`, `newsletter`) + `GroupInfo.IsParent` | P1 |
| `mutedUntil` (timestamp, `-1`/far future = forever) instead of bool | `muteExpiration` | `events.Mute{Action.MuteEndTimestamp}`, history `muteEndTime`, `ChatSettingsStore.MutedUntil` | P1 |
| `pinnedAt` (ordering) instead of bool | `pin` | `events.Pin` timestamp, history `pinned` | P1 |
| `markedUnread` (separate from `unread` count) | session `markedUnread` | `events.MarkChatAsRead{Action.Read=false}`, history `markedAsUnread` | P1 |
| `unreadMentions` | `unreadMentionCount` | history `unreadMentionCount`; live: count msgs whose mentions include me | P2 |
| `ephemeralSeconds` (+ settingAt) | `ephemeralDuration`, `ephemeralSettingTimestamp` | history `ephemeralExpiration`; `GroupInfo.GroupEphemeral`; `ProtocolMessage EPHEMERAL_SETTING` | P1 |
| `readOnly` (left group / can't send) and `announce` (only admins send) | `isReadOnly`, `isAnnounceGrpRestrict`, session `canSend` | history `readOnly`; `GroupInfo.IsAnnounce` + my participant `IsAdmin`; `events.GroupInfo.Leave` containing me | P1 |
| `lastMessage{id, sender, kind, preview, status, fromMe, time}` instead of a plain `preview` string (tick icon, "You:"/sender name prefix) | `chatlistPreview`, `previewT`, `lastReceivedKey` | derived from our messages table | P1 |
| `draft` | `draftMessage` | local only | P2 |
| `lastReaction` preview | `lastReactionPreview` | from reactions | P3 |
| `labels[]` / favourites | label/label-association, `favorite` table | `events.LabelEdit`, `LabelAssociationChat` (app-state) | P2 |
| `locked` | `isLocked` | history `locked` | P3 |
| `notSpam`/unknown-sender banner | `notSpam` | history `notSpam` | P2 |
| `endOfHistory` (show "older messages on your phone") | `endOfHistoryTransferType` | history `endOfHistoryTransferType` | P2 |
| `cleared`/deleted chats | `ClearChat`/`DeleteChat` | app-state events | P1 (else deleted chats reappear) |
| `lid`/`pn` alias pair | `accountLid`, `historyChatId`, `lid-pn-mapping` | `MessageInfo.SenderAlt/RecipientAlt`, history `pnJID/lidJID`, `store.LIDStore` | P1 (one chat per person, not two) |

#### 3.3 Contact (`contacts.get`)

Add: `pushName`, `fullName`/`firstName` (address book), `businessName`/`verifiedName` + `isBusiness`,
`about` (status text), `pictureId`, `phone` (for `@lid` contacts: `LIDStore` pn, or
`RedactedPhone`), `blocked`. Expose a computed `displayName` with WA's precedence
(address book → verified business → `~pushName` → phone) so UI code never repeats it.
Sources: `ContactStore.GetContact`, `events.PushName/Contact/BusinessName`, `GetUserInfo`
(`Status`, `PictureID`, `VerifiedName`), `events.UserAbout`, `events.Picture`,
`GetBlocklist`/`events.Blocklist`. P1: displayName, pushName, phone, pictureId, blocked; P2: about,
business fields, username.

#### 3.4 Group metadata (`groups.info`, should also be stored, not only fetched)

Persist a `groups` table like `group-metadata` + `participant`: `subject, subjectTime,
subjectBy, desc, descId, descTime, descBy, owner, creation, restrict (IsLocked), announce,
ephemeral, membershipApproval, memberAddMode, size, isParent, parent (community), suspended`
and `participants(group, jid, lid, pn, admin, superAdmin)`. Source: `GetGroupInfo` at first open
/ after `JoinedGroup`, patched by `events.GroupInfo` (which also feeds the gp2 system rows).
P1 (subject, desc, participants+admins, announce/restrict, ephemeral); P2 communities, approval
requests (`GetGroupRequestParticipants`).

#### 3.5 Presence / typing

Current events `presence{jid, online, lastSeen}` and `typing{chat, jid, on, media}` match WA
Web's model; add `lastSeenHidden` (WA's `deny`; whatsmeow reports `LastSeen` zero) and, for
groups, keep a per-chat set of typing/recording jids (WA's `typingUserIds`/`recordingUserIds`) so
the UI shows "Ana, Bruno are typing…". Not persisted (WA doesn't persist it either). P1.

#### 3.6 Calls

WA Web shows call history as `call_log` messages (`callOutcome`, `isVideoCall`, `callDuration`,
missed subtypes `miss`, `miss_video`, `miss_group`…). Core should insert a system row on
`CallOffer` → `CallTerminate` (missed if never accepted on any device; `CallAccept` from own
device ⇒ answered elsewhere) — P1 for missed-call visibility; client-side only.

#### 3.7 Storage-shape lessons from WA Web

- Key everything by the message key string `fromMe_chat_id[_participant]`, not bare `id`
  (ids are only unique per chat+sender); add-ons (reactions, votes, edits, receipts, pins) live in
  their own tables keyed by `parentMsgKey`, and orphans (add-on before parent) are parked and
  applied later (`message-orphans`, `orphan-receipt`, `orphan-revoke`). Our core needs the same
  orphan handling for reactions/edits/receipts arriving during history sync — P1.
- Index flags for the "media / docs / links" drawer: `typeFlag` (MEDIA 1, DOC 2, LINK 4) with
  composite `[chat-order,flag]` indexes; `isStarred`; `expiredTimestamp` for the disappearing
  reaper. Cheap to mirror as SQLite columns + indexes — P2.

---
