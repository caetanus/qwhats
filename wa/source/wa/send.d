/// Sending a 1:1 message, ported from whatsmeow's sendDM / prepareMessageNode /
/// encryptMessageForDevices:
///   1. usync the devices of [the peer, our own account] (our LID when the chat is LID-addressed);
///   2. leave out this very device;
///   3. our other devices get a deviceSentMessage { destinationJID, message } copy, so the message
///      shows in our own chats (without it they show "waiting for this message");
///   4. devices we have no session with: fetch their pre-key bundles and start one;
///   5. one <enc> per device in <participants>, plus <device-identity> when any is a pre-key message.
module wa.send;

import std.conv : to;
import std.string : indexOf;
import wa.binary.node;
import wa.device : Device;
import wa.envelope : buildMessageStanza, EncTarget, parseJidString, signalAddress;
import wa.messages : encryptEncToStore;
import wa.prekey : fetchPreKeysIQ, parsePreKeyBundle;
import wa.proto : ProtoWriter, ProtoReader;
import wa.signal.session : PreKeyBundle;
import wa.store.db : Store;
import wa.usync : deviceQueryIQ, parseUsyncDevices, parseUsyncLIDs, userInfoIQ;

/// What the sender needs from a live connection.
interface Connection {
    /// Send an IQ and wait for its <iq type=result|error> (throws on timeout).
    Node sendIQ(Node iq);
    void sendNode(Node n);
    /// A fresh id for an IQ / usync sid.
    string nextId();
    /// Start expecting the server's <ack> for an id — call before sending, so a fast ack is kept.
    void expectAck(string id);
    /// Wait for the server's <ack> to a stanza we sent (by its id); throws on timeout.
    Node waitAck(string id, Duration timeout);
}

import core.time : Duration, seconds;

// ── device lists (GetUserDevices' userDevicesCache) ──────────────────────────────────────────

private Jid[][string] deviceCache;   // user@server → its devices

/// Drop a user's cached devices (a `devices` notification, or a phash mismatch on send).
void invalidateDevices(string userJid) { deviceCache.remove(userJid); }

/// participantListHashV2: "2:" + base64(sha256(sorted ADStrings joined)[:6]), no padding.
string participantListHash(const Jid[] devices) {
    import std.algorithm : sort, map;
    import std.array : array, join;
    import std.base64 : Base64Impl;
    import wa.crypto : sha256;
    alias RawB64 = Base64Impl!('+', '/', Base64Impl!('+', '/').NoPadding);
    auto parts = devices.map!(d => d.user ~ ".0:" ~ d.device.to!string ~ "@" ~ d.server).array;
    sort(parts);
    const h = sha256(cast(const(ubyte)[]) parts.join(""));
    return "2:" ~ cast(string) RawB64.encode(h[0 .. 6]);
}

/// whatsmeow's GenerateMessageID: "3EB0" + hex(sha256(unix ‖ user "@c.us" ‖ 16 random)[:9]).
string newMessageId(string ownUser) {
    import wa.crypto : sha256, randomBytes;
    import std.datetime.systime : Clock;
    import std.format : format;
    ubyte[] seed;
    const now = Clock.currTime.toUnixTime;
    foreach_reverse (i; 0 .. 8) seed ~= cast(ubyte)(now >> (8 * i));
    seed ~= cast(ubyte[]) (ownUser ~ "@c.us");
    seed ~= randomBytes(16);
    string id = "3EB0";
    foreach (b; sha256(seed)[0 .. 9]) id ~= format("%02X", b);
    return id;
}

/// "5511…:3@s.whatsapp.net" → ("5511…", 3).
private string userOf(string jid, out ushort device) {
    string j = jid;
    if (const at = j.indexOf('@')) if (at > 0) j = j[0 .. at];
    device = 0;
    if (const colon = j.indexOf(':')) if (colon > 0) {
        try device = j[colon + 1 .. $].to!ushort; catch (Exception) {}
        j = j[0 .. colon];
    }
    return j;
}

/// The wire JID for a device: device 0 is the plain user JID (as whatsmeow encodes it).
Jid wireJid(const Jid d) {
    return d.device == 0 ? Jid.pair(d.user, d.server) : d;
}

/// Message { deviceSentMessage (31) { destinationJID = 1; message = 2 }; messageContextInfo (35) }
/// — marshalMessage copies the original's messageContextInfo to the outer message.
ubyte[] deviceSentMessage(string destination, const(ubyte)[] messageProto) {
    import wa.proto : ProtoReader;
    auto w = ProtoWriter().bytes(31, ProtoWriter().str(1, destination).bytes(2, messageProto).buf);
    auto r = ProtoReader(messageProto);
    if (r.has(35)) w.bytes(35, r.get(35).bytes);
    return w.buf;
}

/// BuildUnavailableMessageRequest: Message { protocolMessage { type = PEER_DATA_OPERATION_REQUEST
/// (16); peerDataOperationRequestMessage (16) { type = PLACEHOLDER_MESSAGE_RESEND (4);
/// placeholderMessageResendRequest (5) { messageKey { remoteJID, fromMe, id, participant } } } } }.
ubyte[] unavailableMessageRequest(string chatJid, const Jid sender, string id, string ownPN, string ownLID) {
    const fromMe = sender.user.length == 0 || sender.user == ownPN || (ownLID.length && sender.user == ownLID);
    auto key = ProtoWriter().str(1, chatJid).boolean(2, fromMe).str(3, id);
    const chat = parseJidString(chatJid);
    if (!fromMe && chat.server != "s.whatsapp.net" && chat.server != "lid" && chat.server != "msgr")
        key.str(4, Jid.pair(sender.user, sender.server).toString());
    auto req = ProtoWriter().bytes(1, key.buf);
    auto pdo = ProtoWriter().varint(1, 4).bytes(5, req.buf);
    auto pm = ProtoWriter().varint(2, 16).bytes(16, pdo.buf);
    return ProtoWriter().bytes(12, pm.buf).buf;
}

/// BuildHistorySyncRequest: Message { protocolMessage { type = PEER_DATA_OPERATION_REQUEST_MESSAGE (16);
/// peerDataOperationRequestMessage { type = HISTORY_SYNC_ON_DEMAND (3); historySyncOnDemandRequest {
/// chatJID, oldestMsgID, oldestMsgFromMe, onDemandMsgCount, oldestMsgTimestampMS (seconds, despite
/// the name) } } } } — older messages of a chat, asked of our phone.
ubyte[] historySyncRequest(string chatJid, string oldestId, bool oldestFromMe, int count, long oldestTs) {
    auto req = ProtoWriter().str(1, chatJid).str(2, oldestId).boolean(3, oldestFromMe)
        .varint(4, cast(ulong) count).varint(5, cast(ulong) oldestTs);
    auto pdo = ProtoWriter().varint(1, 3).bytes(4, req.buf);
    auto pm = ProtoWriter().varint(2, 16).bytes(16, pdo.buf);
    return ProtoWriter().bytes(12, pm.buf).buf;
}

/// SendPeerMessage: a protocol message to our own primary phone — <message id type=text
/// category=peer to=ourPN> with <meta appdata=default/>, the <enc> for our phone's device 0 (its
/// LID session), and <device-identity> if it had to be a pre-key message. Waits for the ack.
string sendPeerMessage(Connection c, Store store, ref const Device dev, const(ubyte)[] messageProto) {
    acquireSend();
    scope (exit) sending = false;
    ushort d;
    const ownPN = userOf(dev.jid, d);
    const ownLID = userOf(dev.lid, d);
    const encUser = store.lidForPN(ownPN).length ? store.lidForPN(ownPN) : ownLID;
    const addr = (encUser.length ? encUser : ownPN) ~ ":0";
    auto enc = encryptEncToStore(store, dev, addr, messageProto);
    const id = newMessageId(ownPN);
    auto msg = node("message", [["id", id], ["type", "text"], ["category", "peer"], ["to", ownPN ~ "@s.whatsapp.net"]]);
    msg.attr("to").jid = Jid.pair(ownPN, "s.whatsapp.net");
    msg.attr("to").isJid = true;
    auto meta = Node("meta");
    meta.attrs ~= Attr("appdata", Value("default"));
    msg.children ~= meta;
    msg.children ~= enc;
    if (enc.get("type") == "pkmsg") {
        if (dev.account.length == 0) throw new Exception("pkmsg needed but no stored account identity");
        Node di = Node("device-identity");
        di.hasBytes = true;
        di.bytes = dev.account.idup;
        msg.children ~= di;
    }
    c.expectAck(id);
    c.sendNode(msg);
    auto ack = c.waitAck(id, 75.seconds);
    if (const e = ack.get("error")) if (e.length && e != "0") throw new Exception("server returned error " ~ e);
    return id;
}

struct SendReport {
    string id;
    size_t devices;          // devices we encrypted for
    size_t preKeyMessages;   // of those, how many needed a new session
    string[] skipped;        // "device: reason"
    bool identityIncluded;
    string phash, serverPHash;   // ours and the ack's (different: some devices may have missed it)
    long t;                  // the server's timestamp from the ack (0 when absent)
}

/// Send a Message protobuf to a 1:1 chat, the way whatsmeow's sendDM does.
SendReport sendDM(Connection c, Store store, ref const Device dev, Jid chat, const(ubyte)[] messageProto,
    string type_ = null, string id = null) {
    acquireSend();
    scope (exit) sending = false;
    import wa.message : messageStanzaType, encMediaType;
    if (type_.length == 0) type_ = messageStanzaType(messageProto);   // getTypeFromMessage
    const mediaType = encMediaType(messageProto);                     // 1:1 only: <enc mediatype>
    // prepareMessageNode: an edit/pin/revoke carries edit="…"; it, a reaction and a poll vote are
    // hidden by the receiver if they fail to decrypt
    import wa.message : editAttribute;
    const editAttr = editAttribute(messageProto);
    const hideFail = editAttr.length || type_ == "reaction" || ProtoReader(messageProto).has(50 /* pollUpdateMessage */);
    SendReport rep;
    // SendMessage: a phone-number chat is sent to its LID (from the store, else a user-info usync),
    // with the number in peer_recipient_pn
    Jid peerPN;
    if (chat.server == "s.whatsapp.net") {
        string lid = store.lidForPN(chat.user);
        if (lid.length == 0) {
            auto r = c.sendIQ(userInfoIQ([Jid.pair(chat.user, chat.server).toString()], c.nextId(), c.nextId()));
            foreach (pn, l; parseUsyncLIDs(r)) store.putLIDMapping(l, pn);
            lid = store.lidForPN(chat.user);
        }
        if (lid.length == 0) throw new Exception("no LID found for " ~ chat.user ~ " from server");
        store.migratePNToLID(chat.user, lid);
        peerPN = Jid.pair(chat.user, "s.whatsapp.net");
        chat = Jid.pair(lid, "lid");
    } else if (chat.server == "lid") {
        if (const pn = store.pnForLID(chat.user)) if (pn.length) peerPN = Jid.pair(pn, "s.whatsapp.net");
    }
    const lidChat = chat.server == "lid";
    ushort ownDevPN, ownDevLID;
    const ownPN = userOf(dev.jid, ownDevPN);
    const ownLID = userOf(dev.lid, ownDevLID);
    const ownUser = lidChat ? ownLID : ownPN;
    const ownDevice = lidChat ? ownDevLID : ownDevPN;
    auto ownJid = Jid.pair(ownUser, lidChat ? "lid" : "s.whatsapp.net");
    rep.id = id.length ? id : newMessageId(ownPN);

    // 1. devices of the peer and of our own account (cached per user, as GetUserDevices)
    // (our own chat: the peer is us — one list, each device once, as WhatsApp Web sends it)
    const peerKey = Jid.pair(chat.user, chat.server).toString();
    const users = peerKey == ownJid.toString() ? [peerKey] : [peerKey, ownJid.toString()];
    auto allDevices = userDevices(c, users);
    const phash = participantListHash(allDevices);
    Jid[] devices;
    foreach (d; allDevices) {
        if (d.user == ownUser && d.device == ownDevice) continue;   // 2. not ourselves
        devices ~= d;
    }

    // 4. bundles for devices without a session
    string[] missing;
    foreach (d; devices) if (!store.hasSession(signalAddress(d))) missing ~= d.toString();
    PreKeyBundle[string] bundles;
    if (missing.length) {
        // fetchPreKeysNoError: a failed fetch only leaves those devices out
        Node pr;
        try pr = c.sendIQ(fetchPreKeysIQ(missing, c.nextId()));
        catch (Exception e) rep.skipped ~= "prekey fetch: " ~ e.msg;
        if (const list = pr.child("list"))
            foreach (ref u; list.children) {
                if (u.tag != "user") continue;
                auto ujid = u.attr("jid");
                const key = ujid is null ? "" : (ujid.isJid ? ujid.jid.toString() : ujid.str);
                try bundles[key] = parsePreKeyBundle(u);
                catch (Exception e) rep.skipped ~= key ~ ": bundle: " ~ e.msg;
            }
    }

    // 3 + 5. encrypt per device
    const dsm = deviceSentMessage(Jid.pair(chat.user, chat.server).toString(), messageProto);
    EncTarget[] targets;
    foreach (d; devices) {
        const own = d.user == ownUser;
        const addr = signalAddress(d);
        const key = d.toString();
        const PreKeyBundle* b = key in bundles;
        if (!store.hasSession(addr) && b is null) { rep.skipped ~= key ~ ": no session and no bundle"; continue; }
        try {
            auto enc = encryptEncToStore(store, dev, addr, own ? dsm : messageProto, b);
            if (mediaType.length) enc.attrs ~= Attr("mediatype", Value(mediaType));
            if (hideFail) enc.attrs ~= Attr("decrypt-fail", Value("hide"));
            if (enc.get("type") == "pkmsg") rep.preKeyMessages++;
            targets ~= EncTarget(wireJid(d), enc);
        } catch (Exception e) rep.skipped ~= key ~ ": " ~ e.msg;
    }
    rep.devices = targets.length;
    if (targets.length == 0) throw new Exception("no device to send to");

    const(ubyte)[] identity;
    if (rep.preKeyMessages) {
        // whatsmeow always sends <device-identity> (Store.Account) with pre-key messages; without the
        // stored identity we would send a stanza whatsmeow never does — fail closed instead
        if (dev.account.length == 0)
            throw new Exception("pre-key message needed but this device has no stored account identity (re-pair)");
        identity = dev.account;
        rep.identityIncluded = true;
    }
    auto stanza = buildMessageStanza(rep.id, Jid.pair(chat.user, chat.server), type_, targets, identity);
    if (editAttr.length) stanza.attrs ~= Attr("edit", Value(editAttr));
    if (peerPN.user.length) stanza.attrs ~= Attr("peer_recipient_pn", Value(peerPN));

    // privacy token (sendDM): the peer's <tctoken> while fresh, else a <cstoken>
    import wa.tctoken : currentTCToken, csToken, tokenEligible, tokenStorageKey, shouldSendNewTCToken,
        issuePrivacyTokenIQ;
    import std.datetime.systime : Clock;
    const now = Clock.currTime.toUnixTime;
    auto chatJid = Jid.pair(chat.user, chat.server);
    if (auto tc = currentTCToken(store, chatJid, now)) {
        Node t = Node("tctoken");
        t.hasBytes = true;
        t.bytes = tc.idup;
        stanza.children ~= t;
    } else if (auto cs = csToken(store, chatJid)) {
        Node t = Node("cstoken");
        t.hasBytes = true;
        t.bytes = cs.idup;
        stanza.children ~= t;
    }
    c.expectAck(rep.id);
    c.sendNode(stanza);

    // the server's ack (SendMessage waits up to 75 s): an error code fails the send; a different
    // participant hash means our device list was stale
    auto ack = c.waitAck(rep.id, 75.seconds);
    if (const e = ack.get("error")) if (e.length && e != "0") throw new Exception("server returned error " ~ e);
    rep.phash = phash;
    rep.serverPHash = ack.get("phash");
    {
        import std.conv : to;
        try rep.t = ack.get("t", "0").to!long; catch (Exception) {}
    }
    if (rep.serverPHash.length && rep.serverPHash != phash) invalidateDevices(Jid.pair(chat.user, chat.server).toString());

    // then issue our own token to them, once per weekly bucket (issuePrivacyTokenAndSave)
    if (tokenEligible(chatJid)) {
        const key = tokenStorageKey(store, chatJid);
        if (shouldSendNewTCToken(store.privacySenderTS(key), now)) {
            try {
                auto r = c.sendIQ(issuePrivacyTokenIQ(parseJidString(key), now, c.nextId()));
                if (r.get("type") == "result") store.setPrivacySenderTS(key, now);
                else rep.skipped ~= "privacy token issue: " ~ r.get("type");
            } catch (Exception e) rep.skipped ~= "privacy token issue: " ~ e.msg;
        }
    }
    return rep;
}

unittest {
    // participantListHashV2 over ADStrings "user.0:device@server", sorted
    import wa.crypto : sha256;
    import std.base64 : Base64Impl;
    alias RawB64 = Base64Impl!('+', '/', Base64Impl!('+', '/').NoPadding);
    auto devs = [Jid.deviceJid("2", Jid.Domain.lid, 0), Jid.deviceJid("1", Jid.Domain.lid, 3)];
    const want = "2:" ~ cast(string) RawB64.encode(sha256(cast(ubyte[]) "1.0:3@lid2.0:0@lid")[0 .. 6]);
    assert(participantListHash(devs) == want);
    assert(want.length == 2 + 8);
}

unittest {
    // the deviceSent copy keeps messageContextInfo at the top; the PDO request has the key
    import wa.proto : ProtoReader;
    auto m = ProtoWriter().str(1, "oi").bytes(35, [1, 2]).buf;
    auto dsm = ProtoReader(deviceSentMessage("x@lid", m));
    assert(dsm.has(31) && dsm.get(35).bytes == [1, 2]);
    auto req = ProtoReader(unavailableMessageRequest("120@g.us", Jid.pair("5599", "s.whatsapp.net"), "ID1", "5511", "136"));
    auto pm = ProtoReader(req.get(12).bytes);
    assert(pm.get(2).value == 16);
    auto pdo = ProtoReader(pm.get(16).bytes);
    assert(pdo.get(1).value == 4);
    auto key = ProtoReader(ProtoReader(pdo.get(5).bytes).get(1).bytes);
    assert(cast(string) key.get(1).bytes == "120@g.us" && key.get(2).value == 0 && cast(string) key.get(3).bytes == "ID1");
    assert(cast(string) key.get(4).bytes == "5599@s.whatsapp.net");
}

unittest {
    assert(newMessageId("5511").length == 22 && newMessageId("5511")[0 .. 4] == "3EB0");
    ushort d;
    assert(userOf("5511:7@s.whatsapp.net", d) == "5511" && d == 7);
    assert(wireJid(Jid.deviceJid("1", Jid.Domain.lid, 0)).toString() == "1@lid");
    assert(wireJid(Jid.deviceJid("1", Jid.Domain.lid, 5)).toString() == "1:5@lid");
}

/// GetUserDevices: the devices of these users (cached per user; one usync for the missing ones;
/// only non-empty answers are cached).
Jid[] userDevices(Connection c, const string[] users) {
    import wa.usync : parseDeviceList;
    // the cached users' devices first, in order; then the usync answer's, in its order
    Jid[] all;
    string[] toSync;
    foreach (u; users) {
        if (auto d = u in deviceCache) all ~= *d;
        else toSync ~= u;
    }
    if (toSync.length) {
        auto res = c.sendIQ(deviceQueryIQ(toSync, c.nextId(), c.nextId()));
        if (res.get("type") == "error") throw new Exception("device list query failed");
        const us = res.child("usync");
        const list = us !is null ? us.child("list") : null;
        if (list is null) throw new Exception("device list query: no <usync><list> in the answer");
        foreach (ref u; list.children) {
            if (u.tag != "user") continue;
            auto uj = u.attr("jid");
            if (uj is null) continue;
            const key = uj.isJid ? Jid.pair(uj.jid.user, uj.jid.server).toString() : uj.str;
            auto devs = parseDeviceList(u);
            if (devs.length) deviceCache[key] = devs;   // only non-empty lists are trusted later
            all ~= devs;
        }
    }
    return all;
}

/// messageSendLock: one send at a time (sessions and sender keys are read, used and written back).
private bool sending;
private void acquireSend() {
    import vibe.core.core : sleep;
    import core.time : msecs;
    while (sending) sleep(20.msecs);
    sending = true;
}

/// Send a Message protobuf to a group, the way whatsmeow's sendGroup does: the message encrypted
/// once with our sender key (<enc type=skmsg>), and our SenderKeyDistributionMessage encrypted 1:1
/// for every member device (ours too) in <participants>. `members` are the group's participants as
/// the server lists them; `lidAddressing` = the group's addressing_mode is lid (then we are our LID
/// and the stanza says so).
SendReport sendGroup(Connection c, Store store, ref const Device dev, Jid group, const string[] members,
    bool lidAddressing, const(ubyte)[] messageProto, string id = null) {
    acquireSend();
    scope (exit) sending = false;
    import wa.message : messageStanzaType, encMediaType, pad;
    import wa.messages : senderKeyName, encryptEncToStore;
    import wa.signal.group : SenderKeyRecord, serializeSenderKeyDistribution;
    import wa.lid : lidIdentity;
    import wa.proto : ProtoWriter;
    import e2e = wa.pb.e2e;
    import core.time : seconds;
    SendReport rep;
    ushort ownDevPN, ownDevLID;
    const ownPN = userOf(dev.jid, ownDevPN);
    const ownLID = userOf(dev.lid, ownDevLID);
    if (ownLID.length == 0) throw new Exception("no LID for our own device");
    rep.id = id.length ? id : newMessageId(ownPN);
    const groupS = Jid.pair(group.user, group.server).toString();

    // our sender key for this group, under our LID address (sendGroup: NewSenderKeyName(to, ownLID))
    const name = senderKeyName(groupS, ownLID ~ ":" ~ ownDevLID.to!string);
    auto raw = store.senderKey(name);
    auto rec = raw is null ? SenderKeyRecord.init : SenderKeyRecord.deserialize(raw);
    if (rec.empty) rec = SenderKeyRecord.createOwn();
    const axolotl = serializeSenderKeyDistribution(rec.distribution());
    const skdm = ProtoWriter().bytes(e2e.Message.senderKeyDistributionMessage, ProtoWriter()
        .str(e2e.SenderKeyDistributionMessage.groupID, groupS)
        .bytes(e2e.SenderKeyDistributionMessage.axolotlSenderKeyDistributionMessage, axolotl).buf).buf;
    const skmsg = rec.encrypt(pad(messageProto));
    store.putSenderKey(name, rec.serialize());

    // devices of every member (hosted ones excluded), all but this one
    auto all = userDevices(c, members);
    Jid[] devices;
    foreach (d; all) {
        if (d.server == "hosted" || d.server == "hosted.lid") continue;
        devices ~= d;
    }
    const phash = participantListHash(devices);
    Jid[] targets;
    foreach (d; devices) {
        if ((d.user == ownPN && d.device == ownDevPN) || (d.user == ownLID && d.device == ownDevLID)) continue;
        targets ~= d;
    }

    // bundles for the devices without a session (by their encryption identity: PN → LID)
    string[] missing;
    foreach (d; targets) if (!store.hasSession(signalAddress(lidIdentity(store, d)))) missing ~= d.toString();
    PreKeyBundle[string] bundles;
    if (missing.length) {
        Node pr;
        try pr = c.sendIQ(fetchPreKeysIQ(missing, c.nextId()));
        catch (Exception e) rep.skipped ~= "prekey fetch: " ~ e.msg;
        if (const list = pr.child("list"))
            foreach (ref u; list.children) {
                if (u.tag != "user") continue;
                auto ujid = u.attr("jid");
                const key = ujid is null ? "" : (ujid.isJid ? ujid.jid.toString() : ujid.str);
                try bundles[key] = parsePreKeyBundle(u);
                catch (Exception e) rep.skipped ~= key ~ ": bundle: " ~ e.msg;
            }
    }
    import wa.message : editAttribute;
    const editAttr = editAttribute(messageProto);
    const hideFail = editAttr.length || messageStanzaType(messageProto) == "reaction" || ProtoReader(messageProto).has(50 /* pollUpdateMessage */);
    EncTarget[] encs;
    foreach (d; targets) {
        const addr = signalAddress(lidIdentity(store, d));
        const key = d.toString();
        const PreKeyBundle* b = key in bundles;
        if (!store.hasSession(addr) && b is null) { rep.skipped ~= key ~ ": no session and no bundle"; continue; }
        try {
            auto enc = encryptEncToStore(store, dev, addr, skdm, b);
            if (hideFail) enc.attrs ~= Attr("decrypt-fail", Value("hide"));
            if (enc.get("type") == "pkmsg") rep.preKeyMessages++;
            encs ~= EncTarget(wireJid(d), enc);
        } catch (Exception e) rep.skipped ~= key ~ ": " ~ e.msg;
    }
    rep.devices = encs.length;

    const(ubyte)[] identity;
    if (rep.preKeyMessages) {
        if (dev.account.length == 0)
            throw new Exception("pre-key message needed but this device has no stored account identity (re-pair)");
        identity = dev.account;
        rep.identityIncluded = true;
    }
    auto stanza = buildMessageStanza(rep.id, Jid.pair(group.user, group.server), messageStanzaType(messageProto), encs, identity);
    if (editAttr.length) stanza.attrs ~= Attr("edit", Value(editAttr));
    if (lidAddressing) stanza.attrs ~= Attr("addressing_mode", Value("lid"));
    stanza.attrs ~= Attr("phash", Value(phash));
    Node sk = Node("enc");
    sk.attrs ~= Attr("v", Value("2"));
    sk.attrs ~= Attr("type", Value("skmsg"));
    if (const mt = encMediaType(messageProto)) if (mt.length) sk.attrs ~= Attr("mediatype", Value(mt));
    sk.bytes = skmsg.idup;
    sk.hasBytes = true;
    stanza.children ~= sk;

    c.expectAck(rep.id);
    c.sendNode(stanza);
    auto ack = c.waitAck(rep.id, 75.seconds);
    if (const e = ack.get("error")) if (e.length && e != "0") throw new Exception("server returned error " ~ e);
    rep.phash = phash;
    rep.serverPHash = ack.get("phash");
    try rep.t = ack.get("t", "0").to!long; catch (Exception) {}
    return rep;
}

unittest {
    // sendGroup end to end: Alice sends to a LID-addressed group with Bob; Bob decrypts the sender
    // key distribution from his <to>, then the skmsg with it.
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    import core.time : Duration;
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.messages : decryptEncFromStore, processSenderKeyDistributionToStore, decryptGroupEncFromStore;
    import wa.message : senderKeyDistribution;
    import wa.signal.session : PreKeyBundle;
    const ap = tempDir ~ "/wa-sg-a-" ~ thisProcessID.to!string ~ ".db";
    const bp = tempDir ~ "/wa-sg-b-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (p; [ap, bp]) foreach (s; ["", "-wal", "-shm"]) if (exists(p ~ s)) remove(p ~ s);
    auto alice = Device.create();
    alice.jid = "5511100:5@s.whatsapp.net";
    alice.lid = "900:5@lid";
    alice.account = [1, 2, 3];
    auto bob = Device.create();
    bob.jid = "5511200:0@s.whatsapp.net";
    auto aStore = new Store(ap);
    auto bStore = new Store(bp);

    // Alice already has a session with Bob's device (from his bundle)
    auto one = bStore.genOnePreKey();
    PreKeyBundle b;
    b.registrationId = bob.registrationId;
    b.identityKey = bob.identityKey.pub;
    b.signedPreKeyId = bob.signedPreKey.id;
    b.signedPreKey = bob.signedPreKey.key.pub;
    b.signedPreKeySignature = bob.signedPreKey.signature;
    b.hasOneTime = true;
    b.preKeyId = one.id;
    b.preKey = one.key.pub;
    auto first = encryptEncToStore(aStore, alice, "800:0", ProtoWriter().str(1, "oi").buf, &b);
    assert(decryptEncFromStore(bStore, bob, "900:5", first) == ProtoWriter().str(1, "oi").buf);

    final class FakeConn : Connection {
        Node[] sent;
        Node sendIQ(Node iq) { throw new Exception("unexpected IQ " ~ iq.get("xmlns")); }
        void sendNode(Node n) { sent ~= n; }
        void expectAck(string id) {}
        string nextId() { return "1.2-3"; }
        Node waitAck(string id, Duration timeout) { return Node("ack"); }
    }
    deviceCache["900@lid"] = [Jid.deviceJid("900", Jid.Domain.lid, 5)];   // only us: skipped
    deviceCache["800@lid"] = [Jid.deviceJid("800", Jid.Domain.lid, 0)];
    scope (exit) { deviceCache.remove("900@lid"); deviceCache.remove("800@lid"); }
    auto conn = new FakeConn;
    auto proto = ProtoWriter().str(1, "olá, grupo").buf;
    auto group = parseJidString("120363000000000001@g.us");
    auto rep = sendGroup(conn, aStore, alice, group, ["900@lid", "800@lid"], true, proto);
    assert(conn.sent.length == 1 && rep.devices == 1);
    auto st = decodeStanza(encodeStanza(conn.sent[0]));
    assert(st.get("to") == "120363000000000001@g.us" && st.get("addressing_mode") == "lid" && st.get("type") == "text");
    assert(st.get("phash").length && st.child("device-identity").bytes == [1, 2, 3]);
    const parts = st.child("participants");
    assert(parts !is null && parts.children.length == 1 && parts.children[0].get("jid") == "800@lid");
    const sk = st.children[$ - 1];
    assert(sk.tag == "enc" && sk.get("type") == "skmsg" && sk.get("v") == "2");

    // Bob: the SKDM, then the group message
    auto skdm = decryptEncFromStore(bStore, bob, "900:5", *parts.children[0].child("enc"));
    string gid;
    const(ubyte)[] axolotl;
    assert(senderKeyDistribution(skdm, gid, axolotl) && gid == "120363000000000001@g.us");
    processSenderKeyDistributionToStore(bStore, gid, "900:5", axolotl);
    assert(decryptGroupEncFromStore(bStore, gid, "900:5", sk) == proto);

    // a second message reuses the same sender key (next iteration), still decryptable
    auto proto2 = ProtoWriter().str(1, "de novo").buf;
    sendGroup(conn, aStore, alice, group, ["900@lid", "800@lid"], true, proto2);
    auto st2 = decodeStanza(encodeStanza(conn.sent[1]));
    assert(decryptGroupEncFromStore(bStore, gid, "900:5", st2.children[$ - 1]) == proto2);
}
