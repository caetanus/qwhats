# QWhats native — WhatsApp without Chromium (experiment)

Why: the WebEngine client spends ~3 GB in Chromium's renderers for web.whatsapp.com (measured
2026-10-20: 2.0 + 0.9 GB renderers vs 0.34 GB for the QML/D shell). Rewriting the shell would save
nothing; removing the browser is the only way. Target: a few hundred MB.

What is lost: **voice/video calls** — no open implementation of WhatsApp's VoIP exists. An incoming
call becomes a notification ("atenda no celular"). Everything else is built feature by feature.
Risk: WhatsApp may flag unofficial clients. The protocol side is whatsmeow (go.mau.fi/whatsmeow), a
multi-device *companion* (like WhatsApp Web), used by mautrix-whatsapp for years.

## Processes

```
 qwhats (D + solid-qml UI) ──stdio, JSON-RPC 2.0 lines──▶ qwhats-core (Go + whatsmeow + SQLite)
   ▲ unix socket (JSON-RPC, existing remote control)                 │  websocket, Noise, Signal
   │                                                                  ▼
 qwhats --mcp (stdio MCP server, holds nothing)                 WhatsApp servers
```

- **qwhats-core** (Go, `core/`): owns the connection(s) — one whatsmeow client per account — the
  device store (whatsmeow's sqlstore: keys, sessions) and *our* store (`core.db`, SQLite): chats,
  contacts, messages (with FTS5 for search), media references. whatsmeow does not keep message
  history; the history sync the phone sends at pairing and every live event are written here.
  Media is downloaded on demand, decrypted into the cache, and handed out as a path.
- **qwhats** (D, the existing app): spawns the core, speaks JSON-RPC on its stdin/stdout, turns
  results into QML: QAbstractListModel (DSide route C) for the chat list and the open conversation
  — incremental inserts/updates, no list rebuilds — and plain properties for the rest. Keeps what
  it already does: tray, desktop notifications, single instance, settings, remote-control socket.
- **UI** (solid-qml TSX, `ui/native/`): login (QR or phone-number code), chat list, conversation,
  composer, attachments, media viewer, settings.
- **MCP** (`qwhats --mcp`, as `solid-mail --mcp`): an MCP server on stdio whose every tool is one
  request on the running app's remote-control socket.

## The core API — WhatsApp Web's own, over JSON-RPC

The core speaks **WhatsApp Web's internal API**, as mapped from its JavaScript
(docs/whatsapp-web-api-map.md): the same models (`Msg`, `Chat`, `Contact`, `GroupMetadata`,
`Presence`), the same field names, the same ack ladder and message types, and the actions named
after the functions WhatsApp Web's UI calls (its `WAWeb*Bridge` and `WAWeb*ChatAction` /
`WAWeb*MsgAction` modules). Transport: JSON-RPC 2.0, one object per line, on the core's stdio.

Requests may carry `"account"` (default `"main"`). Times are Unix seconds (`t`). Ids are WhatsApp
JIDs (`5511999999999@s.whatsapp.net`, `…@g.us`, `…@lid`, `…@newsletter`, `status@broadcast`).

### Message keys

A message is addressed as WhatsApp Web does (`WAWebMsgKey`): `fromMe_remote_id[_participant]`,
for example `false_5511…@s.whatsapp.net_3EB0C2…` or `false_1203…@g.us_3EB0…_5511…@s.whatsapp.net`.
`msg.id` is that string; every action that takes a message takes it.

### Models (fields as WhatsApp Web names them; only what a client renders)

**Msg** (`WAWebMsgModel`):
`id`, `remote` (the chat), `from`, `to`, `author` (sender in groups), `fromMe`, `t`, `type`,
`subtype`, `ack`, `notifyName` (push name at send time), `senderName` (our display name for the
author), `body`, `caption`, `quotedMsg` (`{id, type, body, author}`), `quotedRemoteJid`,
`mentionedJidList`, `isForwarded`, `forwardingScore`, `star`, `isEdited` + `latestEditSenderTimestamp`,
`revokeSender` (on `type: "revoked"`: `sender_revoke` / `admin_revoke`), `reactions`
(`[{aggregateEmoji, senders[], hasReactionByMe}]`), `mediaData` (`{mediaStage, mimetype, size,
filename, duration, width, height, preview (base64 JPEG), waveform, isGif, isViewOnce, pageCount,
isAnimated, renderableUrl}`), link preview `matchedText`, `title`, `description`, `thumbnail`,
location `lat`, `lng`, `loc`, `isLive`, contacts `vcardList` (`[{displayName, vcard}]`), polls
`pollName`, `pollOptions` (`[{localId, name}]`), `pollSelectableOptionsCount`, disappearing
`ephemeralDuration`, `expiredTimestamp`, calls `callOutcome`, `isVideoCall`, `callDuration`,
`isMdHistoryMsg` (came with history sync).

- `type` (`WAWebMsgType`): `chat`, `image`, `video`, `ptv`, `audio`, `ptt`, `document`, `sticker`,
  `location`, `vcard`, `multi_vcard`, `poll_creation`, `revoked`, `ciphertext` (waiting for this
  message), and the system types `gp2`, `e2e_notification`, `notification_template`, `call_log`,
  `unknown`.
- `subtype` (`WAWebCommonMsgSubtypeTypes`) for system rows: gp2 `create`, `subject`,
  `description`, `picture`, `add`, `remove`, `leave`, `invite`, `promote`, `demote`, `restrict`,
  `announce`, `ephemeral`, …; e2e `encrypt`, `identity`; call_log `miss`, `miss_video`; `ephemeral_setting`.
- `ack` (`WAWebAck.ACK`): `-1` FAILED, `0` CLOCK, `1` SENT, `2` RECEIVED, `3` READ, `4` PLAYED.
- `mediaData.mediaStage` (`WAWebMediaTypes`): `INIT`, `FETCHING`, `RESOLVED`, `NEED_POKE`, `ERROR_MISSING`.

**Chat** (`WAWebChatModel`):
`id`, `kind` (`user | group | community | broadcast | newsletter`), `name` (formatted title),
`t`, `unreadCount`, `unreadMentionCount`, `markedUnread`, `archive`, `pin` (pin time, 0 = not pinned),
`muteExpiration` (0 = not muted, -1 = always), `isReadOnly`, `isAnnounceGrpRestrict`,
`ephemeralDuration`, `endOfHistoryTransferType`, `draftMessage`, `lastMsg` (the chat-list preview:
`{id, type, subtype, body, fromMe, author, senderName, ack, t}`).

**Contact** (`WAWebContactModel`): `id`, `name` (address book), `shortName`, `pushname`,
`verifiedName`, `isBusiness`, `isContactBlocked`, `phoneNumber`, `status` (about), `profilePicThumb`
(a local file once fetched), `formattedName` (WhatsApp's precedence: address book → verified
business → `~pushname` → phone).

**GroupMetadata** (`WAWebGroupMetadataModel`): `id`, `subject`, `subjectTime`, `desc`, `owner`,
`creation`, `restrict`, `announce`, `ephemeralDuration`, `size`, `isParentGroup`, `parentGroup`,
`participants` (`[{id, isAdmin, isSuperAdmin}]`). Stored, refreshed by `sendQueryGroup` and by
group notifications.

**Presence** (`WAWebPresenceModel`): `id`, `isOnline`, `t` (last seen), `deny` (hidden),
`typingUserIds`, `recordingUserIds`. Not stored.

### Methods

Collections (what WhatsApp Web reads from its `*Collection`s):

| method | params | result |
|---|---|---|
| `Chat.list` | `{}` | `Chat[]` (pinned first by `pin`, then by `t`) |
| `Chat.get` | `{id}` | `Chat` |
| `Msg.list` | `{chat, before?, limit?}` | `Msg[]`, oldest first (`WAWebChatMsgsCollection` window) |
| `Msg.search` | `{query, chat?, limit?}` | `Msg[]` |
| `Contact.get` | `{id}` | `Contact` |
| `GroupMetadata.get` | `{id}` | `GroupMetadata` (stored; fetched once if unknown) |

Session: `connect {}` → `{state}`; `pairPhone {phone}` → `{code}`; `logout {}`; `getState {}`.

Actions, named after WhatsApp Web's:

| method | params | WhatsApp Web | whatsmeow / ours |
|---|---|---|---|
| `sendTextMsgToChat` | `{chat, text, quotedMsg?, mentionedJidList?}` | `WAWebSendTextMsgChatAction` | `SendMessage` (ExtendedText + ContextInfo) |
| `sendReactionToMsg` | `{msg, reactionText}` ("" removes) | `WAWebSendReactionMsgAction` | `BuildReaction` |
| `sendRevoke` | `{chat, msgs[]}` (delete for everyone) | `WAWebRevokeMsgAction.sendRevoke` | `BuildRevoke` |
| `sendDeleteMsgs` | `{chat, msgs[], deleteMedia?}` (delete for me) | `WAWebChatSendDeleteMsgsBridge` | app-state `deleteMessageForMe` v3 (ours) |
| `editMessage` | `{msg, text}` | `WAWebSendMsgChatAction` (edit) | `BuildEdit` |
| `sendStarMsgs` | `{chat, msgs[], star}` | `WAWebChatSendStarMsgsBridge` | `BuildStar` |
| `setArchive` | `{chat, archive}` | `WAWebSetArchiveChatAction` | `BuildArchive` |
| `setPin` | `{chat, pin}` | `WAWebChatPinBridge.setPin` | `BuildPin` |
| `sendConversationMute` | `{chat, expiration}` (0 unmute, -1 always) | `WAWebChatMuteBridge` | `BuildMuteAbs` |
| `sendClear` | `{chat, keepStarred?}` | `WAWebChatClearBridge` | app-state `clearChat` v6 (ours) |
| `sendDelete` | `{chat}` | `WAWebDeleteChatAction` | `BuildDeleteChat` |
| `sendSeen` | `{chat}` | `WAWebUpdateUnreadChatAction.sendSeen` | `MarkRead` + `BuildMarkChatAsRead` |
| `markUnread` | `{chat}` | `WAWebUpdateUnreadChatAction.markUnread` | `BuildMarkChatAsRead(false)` |
| `markComposing` / `markRecording` / `markPaused` | `{chat}` | `WAWebPresenceChatAction` | `SendChatPresence` |
| `sendPresenceAvailable` / `sendPresenceUnavailable` | `{}` | `WAWebPresenceChatAction` | `SendPresence` |
| `subscribeUserPresence` | `{id}` | `WAWebContactPresenceBridge` | `SubscribePresence` |
| `changeEphemeralDuration` | `{chat, duration}` (seconds) | `WAWebChangeEphemeralDurationChatAction` | `SetDisappearingTimer` |
| `markPlayed` | `{msg}` | `WAWebMarkPlayedMsgAction` | `MarkRead(…, ReceiptTypePlayed)` |
| `loadEarlierMsgs` | `{chat}` | `WAWebChatMsgsCollection.loadEarlierMsgs` | store, then `BuildHistorySyncRequest` to the phone |
| `downloadMedia` | `{msg}` | `WAWebDownloadManager` | `Download` → `mediaData.renderableUrl`; expired → `SendMediaRetryReceipt` |
| `sendQueryGroup` | `{id}` | `WAWebGroupQueryBridge` | `GetGroupInfo` → stored |
| `requestProfilePicFromServer` | `{id}` | `WAWebContactProfilePicThumbBridge` | `GetProfilePictureInfo` + fetch → `profilePicThumb` |
| `getStatus` | `{id}` | `WAWebContactStatusBridge` | `GetUserInfo` → `status` |
| `updateDraftMessageChat` | `{chat, draft}` | `WAWebUpdateDraftMessageChatAction` | stored only |
| `rejectCall` | `{id, from}` | call UI | offer `<receipt>` + `RejectCall` |

### Events (what WhatsApp Web's collections emit: `add`, `change`, `remove`)

| method | params |
|---|---|
| `Msg:add` | `Msg` (new, live or sent) |
| `Msg:change` | `Msg` (ack, reactions, edit, revoke, star, media stage, …: the whole updated row) |
| `Msg:remove` | `{id}` (deleted for me, cleared) |
| `Chat:add` / `Chat:change` | `Chat` |
| `Chat:remove` | `{id}` |
| `Contact:change` | `Contact` |
| `GroupMetadata:change` | `GroupMetadata` |
| `Presence:change` | `Presence` |
| `Call:offer` / `Call:terminate` | `{id, from, isVideo, isGroup}` |
| `Conn:change` | `{state}`: `OPENING`, `PAIRING`, `CONNECTED`, `TIMEOUT`, `CONFLICT` (opened elsewhere), `UNPAIRED` (logged out) — WhatsApp Web's socket states |
| `qr` | `{code, image, timeout}` |
| `History:progress` | `{type, progress, chats, msgs}` |

Every event is stored before it is sent: re-reading the collections always gives the same state.

### What the core does that whatsmeow leaves to the app

- **Add-ons on their parent** (WhatsApp Web's add-on tables): reactions aggregate on the parent
  (one per sender, replaced on change, "" removes), edits rewrite the body and set `isEdited`,
  revokes turn the parent into `type: "revoked"`, receipts raise `ack`. An add-on that arrives
  before its parent (history sync, out of order) is parked as an **orphan** and applied when the
  parent is stored.
- **System rows**: group changes, disappearing-mode changes, identity changes and missed calls
  become `gp2` / `notification_template` / `e2e_notification` / `call_log` messages, as in WhatsApp
  Web.
- **Undecryptable messages** become `ciphertext` ("Aguardando mensagem…"); the real message replaces
  them when it arrives.
- **Current WhatsApp Web version** at start (`core/version.go`).
- **Delete for me** and **clear chat** app-state patches, built as WhatsApp Web builds them
  (`WAWebDeleteMessageForMeSync`, `WAWebClearChatSync`).

## MCP tools (on the app's remote-control socket)

`list_accounts`, `list_chats`, `search_messages`, `get_messages` (a chat's history, paged),
`send_message` (text, optionally a file), `mark_read`, `download_media` (→ local path),
`get_contact`. Sending is the user's action through the user's account, as in solid-mail.

## Phases (each one usable and measured)

1. core + login (QR) + history stored + chat list + reading text + sending text + notifications;
   memory measured against the WebEngine client.
2. media: thumbnails, download, PDFs/documents open, voice notes play (Qt Multimedia), sending
   files, reactions, quotes, receipts, typing.
3. groups, contacts, profile pictures, search, several accounts.
4. MCP (+ the existing JSON-RPC remote control on the new backend).
