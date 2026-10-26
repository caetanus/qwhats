/// Our own app-state changes (whatsmeow appstate/encode.go + sendAppState): a patch of SET mutations
/// — index JSON, SyncActionValue with the patch's timestamp, encrypted with the newest app-state key —
/// whose LTHash/snapshot/patch MACs continue from our stored state, sent as
/// `<iq xmlns=w:sync:app:state type=set><sync><collection name version return_snapshot=false><patch>`.
/// The builders mirror whatsmeow's BuildMute / BuildPin / BuildArchive / BuildMarkChatAsRead.
module wa.appstate_send;

import std.conv : to;
import std.json : JSONValue;
import wa.binary.node;
import wa.proto : ProtoWriter;
import wa.store.db : Store;
import wa.appstate;
import wa.crypto : aesCbcEncrypt, hmacSha256, randomBytes;
import ss = wa.pb.serversync;
import sav = wa.pb.syncaction;

/// One SET mutation: its index, the action's version, and the SyncActionValue's action field(s)
/// (without the timestamp, which the patch adds).
struct OutMutation {
    string[] index;
    int version_;
    ubyte[] action;
}

/// A patch to send to one collection.
struct PatchInfo {
    string name;
    OutMutation[] mutations;
}

/// json.Marshal of the index: `["a","b"]`, with Go's escaping (", \\, control characters, and
/// <, >, & as \u003c / \u003e / \u0026; '/' and non-ASCII as they are).
string indexJSON(const string[] index) {
    import std.format : format;
    string o = "[";
    foreach (i, s; index) {
        if (i) o ~= ",";
        o ~= '"';
        foreach (char c; s) {
            switch (c) {
                case '"': o ~= `\"`; break;
                case '\\': o ~= `\\`; break;
                case '\n': o ~= `\n`; break;
                case '\r': o ~= `\r`; break;
                case '\t': o ~= `\t`; break;
                case '<', '>', '&': o ~= format(`\u%04x`, cast(int) c); break;
                default:
                    if (c < 0x20) o ~= format(`\u%04x`, cast(int) c);
                    else o ~= c;
            }
        }
        o ~= '"';
    }
    return o ~ "]";
}

/// EncodePatch: the SyncdPatch bytes for `info` on top of `state` (which becomes the new state:
/// version + 1 and the updated LTHash — persisted only when the server's copy comes back).
ubyte[] encodePatch(Store store, const ref PatchInfo info, ref HashState state, long tsMs,
                    const(ubyte)[] iv = null) {
    auto keyId = store.latestAppStateKeyId();
    if (keyId is null) throw new AppStateException("no app-state keys (creating them is not supported)");
    auto keyData = store.appStateKey(keyId);
    auto k = expandAppStateKeys(keyData);

    ProtoWriter[] muts;
    const(ubyte)[][] added, removed, valueMACs;
    const(ubyte)[][] indexMACs;
    foreach (ref m; info.mutations) {
        const idx = indexJSON(m.index);
        auto value = ProtoWriter().varint(sav.SyncActionValue.timestamp, cast(ulong) tsMs).buf ~ m.action;
        auto data = ProtoWriter()
            .bytes(sav.SyncActionData.index, cast(const(ubyte)[]) idx)
            .bytes(sav.SyncActionData.value, value)
            .bytes(sav.SyncActionData.padding, [])
            .varint(sav.SyncActionData.version_, cast(ulong) cast(long) m.version_).buf;
        auto useIv = iv !is null ? iv.dup : randomBytes(16);
        auto enc = useIv ~ aesCbcEncrypt(k.valueEncryption, useIv, data);
        auto vmac = contentMAC(0, enc, keyId, k.valueMAC);   // SET
        auto imac = hmacSha256(k.index, cast(const(ubyte)[]) idx);
        // updateHash: what this index held before (earlier in this patch, else in the store) goes
        const(ubyte)[] prev;
        bool decided;
        foreach_reverse (i, im; indexMACs) if (im == imac[]) { prev = valueMACs[i]; decided = true; break; }
        if (!decided) prev = store.appStateMAC(info.name, imac[]);
        if (prev !is null) removed ~= prev;
        added ~= vmac[].dup;
        valueMACs ~= vmac[].dup;
        indexMACs ~= imac[].dup;
        auto rec = ProtoWriter()
            .bytes(ss.SyncdRecord.index, ProtoWriter().bytes(ss.SyncdIndex.blob, imac[]).buf)
            .bytes(ss.SyncdRecord.value, ProtoWriter().bytes(ss.SyncdValue.blob, enc ~ vmac[]).buf)
            .bytes(ss.SyncdRecord.keyID, ProtoWriter().bytes(ss.KeyId.ID, keyId).buf);
        muts ~= ProtoWriter().varint(ss.SyncdMutation.operation, 0).bytes(ss.SyncdMutation.record, rec.buf);
    }
    ltHashSubtractThenAdd(state.hash, removed, added);
    state.ver += 1;
    auto snap = snapshotMAC(state, info.name, k.snapshotMAC);
    auto pmac = patchMAC(snap[], valueMACs, state.ver, info.name, k.patchMAC);
    auto patch = ProtoWriter();
    foreach (ref m; muts) patch.bytes(ss.SyncdPatch.mutations, m.buf);
    patch.bytes(ss.SyncdPatch.snapshotMAC, snap[])
        .bytes(ss.SyncdPatch.patchMAC, pmac[])
        .bytes(ss.SyncdPatch.keyID, ProtoWriter().bytes(ss.KeyId.ID, keyId).buf);
    return patch.buf;
}

/// The IQ that sends it (`version` = the version the patch builds on).
Node sendPatchIQ(string name, ulong fromVersion, const(ubyte)[] patch, string iqId) {
    auto c = Node("collection");
    c.attrs ~= Attr("name", Value(name));
    c.attrs ~= Attr("version", Value(fromVersion.to!string));
    c.attrs ~= Attr("return_snapshot", Value("false"));
    auto pn = Node("patch");
    pn.bytes = patch.dup;
    pn.hasBytes = true;
    c.children ~= pn;
    auto sync = Node("sync");
    sync.children ~= c;
    auto iq = node("iq", [["id", iqId], ["xmlns", "w:sync:app:state"], ["type", "set"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= sync;
    return iq;
}

// ── builders ─────────────────────────────────────────────────────────────────────────────────

/// A message key for a SyncActionMessageRange (whatsmeow BuildMessageKey): fromMe, and the
/// participant only for someone else's message outside 1:1 chats.
struct MsgKey {
    string remoteJid, id, participant;
    bool fromMe;
}

/// newMessageRange: the last message's time (seconds) and, when known, its key.
ubyte[] messageRange(long lastTs, const MsgKey* last) {
    auto r = ProtoWriter().varint(sav.SyncActionMessageRange.lastMessageTimestamp, cast(ulong) lastTs);
    if (last !is null) {
        auto key = ProtoWriter().str(1, last.remoteJid).boolean(2, last.fromMe).str(3, last.id);
        if (!last.fromMe && last.participant.length) key.str(4, last.participant);
        r.bytes(sav.SyncActionMessageRange.messages, ProtoWriter()
            .bytes(sav.SyncActionMessage.key, key.buf)
            .varint(sav.SyncActionMessage.timestamp, cast(ulong) lastTs).buf);
    }
    return r.buf;
}

/// BuildMuteAbs: muted until muteEndMs (-1 = forever); unmute carries no end.
PatchInfo buildMute(string target, bool mute, long muteEndMs) {
    auto a = ProtoWriter().boolean(sav.MuteAction.muted, mute);
    if (mute) a.varint(sav.MuteAction.muteEndTimestamp, cast(ulong) muteEndMs);
    return PatchInfo("regular_high", [OutMutation(["mute", target], 2,
        ProtoWriter().bytes(sav.SyncActionValue.muteAction, a.buf).buf)]);
}

private OutMutation pinMutation(string target, bool pin) {
    return OutMutation(["pin_v1", target], 5,
        ProtoWriter().bytes(sav.SyncActionValue.pinAction, ProtoWriter().boolean(sav.PinAction.pinned, pin).buf).buf);
}

PatchInfo buildPin(string target, bool pin) { return PatchInfo("regular_low", [pinMutation(target, pin)]); }

/// BuildArchive: archiving also unpins.
PatchInfo buildArchive(string target, bool archive, long lastTs, const MsgKey* last) {
    auto a = ProtoWriter().boolean(sav.ArchiveChatAction.archived, archive)
        .bytes(sav.ArchiveChatAction.messageRange, messageRange(lastTs, last));
    auto muts = [OutMutation(["archive", target], 3,
        ProtoWriter().bytes(sav.SyncActionValue.archiveChatAction, a.buf).buf)];
    if (archive) muts ~= pinMutation(target, false);
    return PatchInfo("regular_low", muts);
}

/// The Go core's sendStatusMute: userStatusMute (version 7) in regular_high.
PatchInfo buildUserStatusMute(string user, bool muted) {
    return PatchInfo("regular_high", [OutMutation(["userStatusMute", user], 7,
        ProtoWriter().bytes(sav.SyncActionValue.userStatusMuteAction,
            ProtoWriter().boolean(sav.UserStatusMuteAction.muted, muted).buf).buf)]);
}

/// WAWebStickersFavoriteSyncAction.generateFavoriteSyncMutation: regular_low, version 7, index
/// [favoriteSticker, filehash], stickerAction {fileEncSha256, mediaKey, mimetype, height, width,
/// directPath, isFavorite, deviceIdHint = our device number}.
PatchInfo buildFavoriteSticker(string filehash, const(ubyte)[] fileEncSHA256, const(ubyte)[] mediaKey, string mimetype,
    uint height, uint width, string directPath, bool favorite, uint deviceIdHint) {
    auto a = ProtoWriter().bytes(sav.StickerAction.fileEncSHA256, fileEncSHA256).bytes(sav.StickerAction.mediaKey, mediaKey)
        .str(sav.StickerAction.mimetype, mimetype).varint(sav.StickerAction.height, height).varint(sav.StickerAction.width, width);
    if (directPath.length) a.str(sav.StickerAction.directPath, directPath);
    a.boolean(sav.StickerAction.isFavorite, favorite).varint(sav.StickerAction.deviceIDHint, deviceIdHint);
    return PatchInfo("regular_low", [OutMutation(["favoriteSticker", filehash], 7,
        ProtoWriter().bytes(sav.SyncActionValue.stickerAction, a.buf).buf)]);
}

/// BuildDeleteChat (whatsmeow appstate/encode.go): regular_high, version 6, index [deleteChat, chat,
/// deleteMedia "0"/"1"], DeleteChatAction {messageRange}
PatchInfo buildDeleteChat(string target, long lastTs, const MsgKey* last, bool deleteMedia) {
    auto a = ProtoWriter().bytes(sav.DeleteChatAction.messageRange, messageRange(lastTs, last));
    return PatchInfo("regular_high", [OutMutation(["deleteChat", target, deleteMedia ? "1" : "0"], 6,
        ProtoWriter().bytes(sav.SyncActionValue.deleteChatAction, a.buf).buf)]);
}

/// BuildStar (whatsmeow appstate/encode.go): regular_high, version 2, index [star, chat, id, fromMe,
/// sender] — the sender "0" when it is the chat itself (the other party of a 1:1)
PatchInfo buildStar(string target, string sender, string id, bool fromMe, bool starred) {
    import wa.envelope : parseJidString;
    const senderIdx = parseJidString(target).user == parseJidString(sender).user ? "0" : sender;
    return PatchInfo("regular_high", [OutMutation(["star", target, id, fromMe ? "1" : "0", senderIdx], 2,
        ProtoWriter().bytes(sav.SyncActionValue.starAction, ProtoWriter().boolean(sav.StarAction.starred, starred).buf).buf)]);
}

/// WAWebDeleteMessageForMeSync (the Go core's sendDeleteMsgs): regular_high, version 3, index
/// [deleteMessageForMe, chat, id, fromMe, participant ("0" unless someone else's group message)]
PatchInfo buildDeleteForMe(string target, string id, bool fromMe, string participant, bool deleteMedia, long messageTs) {
    auto a = ProtoWriter().boolean(sav.DeleteMessageForMeAction.deleteMedia, deleteMedia)
        .int64(sav.DeleteMessageForMeAction.messageTimestamp, messageTs);
    return PatchInfo("regular_high", [OutMutation(["deleteMessageForMe", target, id, fromMe ? "1" : "0",
        participant.length ? participant : "0"], 3, ProtoWriter().bytes(sav.SyncActionValue.deleteMessageForMeAction, a.buf).buf)]);
}

PatchInfo buildMarkChatAsRead(string target, bool read, long lastTs, const MsgKey* last) {
    auto a = ProtoWriter().boolean(sav.MarkChatAsReadAction.read, read)
        .bytes(sav.MarkChatAsReadAction.messageRange, messageRange(lastTs, last));
    return PatchInfo("regular_low", [OutMutation(["markChatAsRead", target], 3,
        ProtoWriter().bytes(sav.SyncActionValue.markChatAsReadAction, a.buf).buf)]);
}

unittest {
    // round trip: what we encode decodes (every MAC verified) with our decoder, from the same state
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    import wa.proto : ProtoReader;
    const path = tempDir ~ "/wa-appstate-send-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto store = new Store(path);
    ubyte[32] keyData = 7;
    store.putAppStateKey(cast(ubyte[]) [0, 0, 0, 1], keyData[], 100, cast(ubyte[]) [1]);

    MsgKey last = MsgKey("123-456@g.us", "ABC", "5511@s.whatsapp.net", false);
    auto info = buildArchive("123-456@g.us", true, 1_700_000_000, &last);
    assert(info.mutations.length == 2 && info.mutations[1].index == ["pin_v1", "123-456@g.us"]);
    HashState st;   // a collection at v0
    auto enc = encodePatch(store, info, st, 1_700_000_000_123);
    assert(st.ver == 1);

    // the same bytes as a server patch list: version 1, built on v0
    PatchList list;
    list.name = "regular_low";
    auto pr = ProtoReader(enc);
    Patch p;
    p.ver = 1;
    foreach (f; pr) {
        if (f.number == ss.SyncdPatch.mutations) p.mutations ~= f.bytes;
        else if (f.number == ss.SyncdPatch.snapshotMAC) p.snapshotMACv = f.bytes;
        else if (f.number == ss.SyncdPatch.patchMAC) p.patchMACv = f.bytes;
        else if (f.number == ss.SyncdPatch.keyID) p.keyId = ProtoReader(f.bytes).get(ss.KeyId.ID).bytes;
    }
    list.patches = [p];
    HashState dst;
    auto muts = Decoder(store).decodePatches(list, dst);
    assert(muts.length == 2 && muts[0].index == ["archive", "123-456@g.us"] && muts[1].index == ["pin_v1", "123-456@g.us"]);
    assert(dst.hash == st.hash && dst.ver == 1);
    auto v = ProtoReader(muts[0].action);
    assert(v.get(sav.SyncActionValue.timestamp).value == 1_700_000_000_123);
    auto ar = ProtoReader(v.get(sav.SyncActionValue.archiveChatAction).bytes);
    assert(ar.get(sav.ArchiveChatAction.archived).value == 1);
    assert(muts[0].ver == 3 && muts[1].ver == 5);
    assert(indexJSON(["mute", "5511@s.whatsapp.net"]) == `["mute","5511@s.whatsapp.net"]`);
    assert(indexJSON([`a/b"<&>`, "\x01é"]) == `["a/b\"\u003c\u0026\u003e","\u0001é"]`);

    // a second patch replacing the pin: the old value MAC leaves the hash (stored by the decode)
    HashState st2 = dst;
    auto pin = buildPin("123-456@g.us", true);
    auto enc2 = encodePatch(store, pin, st2, 1_700_000_001_000);
    Patch p2;
    p2.ver = 2;
    foreach (f; ProtoReader(enc2)) {
        if (f.number == ss.SyncdPatch.mutations) p2.mutations ~= f.bytes;
        else if (f.number == ss.SyncdPatch.snapshotMAC) p2.snapshotMACv = f.bytes;
        else if (f.number == ss.SyncdPatch.patchMAC) p2.patchMACv = f.bytes;
        else if (f.number == ss.SyncdPatch.keyID) p2.keyId = ProtoReader(f.bytes).get(ss.KeyId.ID).bytes;
    }
    list.patches = [p2];
    auto muts2 = Decoder(store).decodePatches(list, dst);
    assert(muts2.length == 1 && dst.hash == st2.hash && dst.ver == 2);
}
