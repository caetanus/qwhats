/// LID ↔ phone-number bookkeeping (whatsmeow StoreLIDPNMapping / decryptMessages' encryption
/// identity / migrateSessionStore). WhatsApp is moving every user to a LID; stanzas may name a
/// sender by phone number, by LID, or by one with the other alongside. We learn the pairs as they
/// show up and keep each user's Signal state under the LID, migrating it from the phone-number
/// addresses the first time we see the mapping.
module wa.lid;

import wa.binary.node;
import wa.envelope : IncomingMessage;
import wa.store.db : Store;

/// Remember a pair given in either order (StoreLIDPNMapping ignores anything not LID+PN).
void storeLIDPNMapping(Store store, const Jid first, const Jid second) {
    if (first.server == "lid" && second.server == "s.whatsapp.net")
        store.putLIDMapping(first.user, second.user);
    else if (first.server == "s.whatsapp.net" && second.server == "lid")
        store.putLIDMapping(second.user, first.user);
}

/// handleEncryptedMessage: the sender's alternate identity, or the chat's for our own DMs.
void learnFromMessage(Store store, const ref IncomingMessage m) {
    if (m.source.senderAlt.user.length) storeLIDPNMapping(store, m.source.senderAlt, m.source.sender);
    else if (m.source.recipientAlt.user.length) storeLIDPNMapping(store, m.source.recipientAlt, m.source.chat);
}

/// decryptMessages' senderEncryptionJID: a phone-number sender is decrypted with its LID's
/// sessions (from the stanza, else from the store), migrating the PN-addressed state first.
Jid encryptionIdentity(Store store, const ref IncomingMessage m) {
    import wa.tctoken : isBot;
    const sender = m.source.sender;
    if (sender.server != "s.whatsapp.net" || isBot(sender)) return sender;
    if (m.source.senderAlt.server == "lid") {
        store.migratePNToLID(sender.user, m.source.senderAlt.user);
        return m.source.senderAlt;
    }
    if (const lid = store.lidForPN(sender.user)) {
        if (lid.length) {
            store.migratePNToLID(sender.user, lid);
            return Jid.deviceJid(lid, Jid.Domain.lid, sender.device);
        }
    }
    return sender;
}

/// The same for a JID we address (a retry sender, a send target device): PN → its LID if known.
Jid lidIdentity(Store store, const Jid j) {
    if (j.server != "s.whatsapp.net") return j;
    if (const lid = store.lidForPN(j.user)) {
        if (lid.length) {
            store.migratePNToLID(j.user, lid);
            return j.device ? Jid.deviceJid(lid, Jid.Domain.lid, j.device) : Jid.pair(lid, "lid");
        }
    }
    return j;
}

unittest {
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    import wa.envelope : parseMessageStanza, signalAddress;
    const path = tempDir ~ "/wa-lid-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto store = new Store(path);

    // a group message naming the sender by phone with its LID alongside
    auto msg = node("message", [["id", "X"], ["type", "text"]]);
    msg.attrs ~= Attr("from", Value(Jid.pair("120363", "g.us")));
    msg.attrs ~= Attr("participant", Value(Jid.deviceJid("5511999", Jid.Domain.whatsapp, 2)));
    msg.attrs ~= Attr("participant_lid", Value(Jid.pair("136777", "lid")));
    auto m = parseMessageStanza(msg, "5511000");
    store.putSession("5511999:2", [4]);
    learnFromMessage(store, m);
    assert(store.lidForPN("5511999") == "136777");
    auto id = encryptionIdentity(store, m);
    assert(signalAddress(id) == "136777:2" && store.session("136777:2") == [4]);

    // later, a 1:1 by phone number only: the stored mapping picks the LID
    auto dm = node("message", [["id", "Y"], ["type", "text"]]);
    dm.attrs ~= Attr("from", Value(Jid.deviceJid("5511999", Jid.Domain.whatsapp, 0)));
    auto m2 = parseMessageStanza(dm, "5511000");
    assert(signalAddress(encryptionIdentity(store, m2)) == "136777:0");
    assert(lidIdentity(store, Jid.pair("5511999", "s.whatsapp.net")).toString() == "136777@lid");
}
