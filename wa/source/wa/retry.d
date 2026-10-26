/// Answering a retry receipt: a device could not decrypt a message we sent and asks for it again
/// (whatsmeow retry.go handleRetryReceipt). We re-encrypt the stored message for that one device —
/// rebuilding the session from the receipt's <keys>, or from a fetched bundle when we have no
/// session (or the count says the session is stale) — and resend it as a single-device <message>
/// with the same id and timestamp. Our own devices get it wrapped in a deviceSentMessage.
module wa.retry;

import std.conv : to;
import wa.binary.node;
import wa.device : Device;
import wa.envelope : jidAttr, signalAddress;
static import wa.envelope;
static import wa.proto;
import wa.message : encMediaType, messageStanzaType;
import wa.messages : encryptEncToStore;
import wa.prekey : fetchPreKeysIQ, parsePreKeyBundle;
import wa.send : Connection, deviceSentMessage, wireJid;
import wa.signal.session : PreKeyBundle;
import wa.store.db : Store;

/// State whatsmeow keeps on the client across receipts.
struct RetryState {
    int[string] incoming;          // (sender, message id) → retries handled; drop at 10
    long[string] lastRecreate;     // sender → unix time of the last forced session recreation
}

enum int maxIncomingRetries = 10;
enum long recreateSessionTimeout = 3600;   // 1 h

/// Handle one `<receipt type="retry">`. Returns a short status for the log. Throws on failures
/// whatsmeow also reports as errors (the caller acks the receipt afterwards either way).
string handleRetryReceipt(Connection c, Store store, ref const Device dev, const ref Node receipt,
    ref RetryState st, long now) {
    const retry = receipt.child("retry");
    if (retry is null) throw new Exception("retry receipt without <retry>");
    const messageId = retry.get("id");
    const t = retry.get("t");
    int count;
    try count = retry.get("count", "0").to!int; catch (Exception) {}

    auto sender = jidAttr(receipt, "from");            // the device asking
    const isGroup = sender.server == "g.us" || sender.server == "broadcast";
    if (isGroup) return "group retry: not supported yet (no group sending)";

    // our own message, looked up by id (getMessageForRetry): sent by us, in the receipt's chat
    // (the recipient for our own devices' receipts, else the sender) — PN or LID form
    string chat, ignoredSender;
    bool ourOwn;
    auto proto = store.messageById(messageId, chat, ignoredSender, ourOwn);
    if (proto is null || !ourOwn) throw new Exception("couldn't find our message " ~ messageId);
    {
        import wa.lid : lidIdentity;
        auto want = receipt.attr("recipient") !is null ? jidAttr(receipt, "recipient") : sender;
        auto wantPair = Jid.pair(want.user, want.server);
        auto chatJ = wa.envelope.parseJidString(chat);
        const same = Jid.pair(chatJ.user, chatJ.server).toString() == wantPair.toString()
            || lidIdentity(store, Jid.pair(chatJ.user, chatJ.server)).toString() == lidIdentity(store, wantPair).toString();
        if (!same) throw new Exception("message " ~ messageId ~ " is not in the receipt's chat");
    }

    const key = sender.toString() ~ "|" ~ messageId;
    const handled = ++st.incoming[key];
    if (handled >= maxIncomingRetries) return "dropping retry: internal counter " ~ handled.to!string;

    // a device of our own account gets the message as a deviceSentMessage copy
    const ownPN = userOf(dev.jid), ownLID = userOf(dev.lid);
    const fromMe = sender.user == ownPN || (ownLID.length && sender.user == ownLID);
    // handleRetryReceipt wraps our own devices' copy as a bare DeviceSentMessage (no context info)
    const(ubyte)[] plaintext = fromMe
        ? wa.proto.ProtoWriter().bytes(31, wa.proto.ProtoWriter().str(1, chat).bytes(2, proto).buf).buf
        : proto;

    // the session: from the receipt's keys, or fetched when missing/stale (shouldRecreateSession)
    // the LID's sessions for a phone-number device (handleRetryReceipt's encryptionIdentity)
    import wa.lid : lidIdentity;
    const addr = signalAddress(lidIdentity(store, sender));
    PreKeyBundle bundle;
    bool haveBundle;
    if (receipt.child("keys") !is null) {
        bundle = parsePreKeyBundle(receipt);
        haveBundle = true;
    } else {
        bool recreate;
        if (!store.hasSession(addr)) recreate = true;
        else if (count >= 2) {
            const prev = sender.toString() in st.lastRecreate;
            recreate = prev is null || *prev + recreateSessionTimeout < now;
        }
        if (recreate) {
            st.lastRecreate[sender.toString()] = now;
            auto r = c.sendIQ(fetchPreKeysIQ([sender.toString()], c.nextId()));
            const list = r.child("list");
            if (list is null) throw new Exception("prekey fetch for retry returned no <list>");
            foreach (ref u; list.children)
                if (u.tag == "user") { bundle = parsePreKeyBundle(u); haveBundle = true; break; }
            if (!haveBundle) throw new Exception("didn't get a prekey bundle for " ~ sender.toString());
        }
    }

    auto enc = encryptEncToStore(store, dev, addr, plaintext, haveBundle ? &bundle : null);
    // type/mediatype come from what is sent (a DeviceSentMessage reads as text without mediatype)
    if (const mt = encMediaType(plaintext)) if (mt.length) enc.attrs ~= Attr("mediatype", Value(mt));
    enc.attrs ~= Attr("count", Value(count.to!string));

    // <message to=from type id t device_fanout=false [participant] [recipient] [edit]>
    Node msg = Node("message");
    msg.attrs ~= Attr("to", *cast(Value*) receipt.attr("from"));
    msg.attrs ~= Attr("type", Value(messageStanzaType(plaintext)));
    msg.attrs ~= Attr("id", Value(messageId));
    msg.attrs ~= Attr("t", Value(t));
    msg.attrs ~= Attr("device_fanout", Value("false"));
    foreach (k; ["participant", "recipient", "edit"])
        if (auto v = receipt.attr(k)) msg.attrs ~= Attr(k, *cast(Value*) v);
    msg.children ~= enc;
    if (enc.get("type") == "pkmsg") {
        if (dev.account.length == 0) throw new Exception("pkmsg needed but no stored account identity");
        Node di = Node("device-identity");
        di.hasBytes = true;
        di.bytes = dev.account.idup;
        msg.children ~= di;
    }
    c.sendNode(msg);
    return "resent " ~ messageId ~ " (#" ~ count.to!string ~ ", " ~ enc.get("type") ~ ")";
}

private string userOf(string jid) {
    import std.string : indexOf;
    string j = jid;
    if (const at = j.indexOf('@')) if (at > 0) j = j[0 .. at];
    if (const colon = j.indexOf(':')) if (colon > 0) j = j[0 .. colon];
    return j;
}

version (unittest) {
    import wa.binary.codec : encodeStanza, decodeStanza;
    import wa.crypto : KeyPair;
    import wa.envelope : parseMessageStanza;
    import wa.messages : decryptEncFromStore;
    import wa.prekey : preKeyNode;
    import wa.proto : ProtoWriter;
    import wa.receipt : retryReceipt, RetryKeys;
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    import core.time : Duration;

    /// A Connection that records what is sent (no IQs expected in this test).
    final class FakeConn : Connection {
        Node[] sent;
        Node sendIQ(Node iq) { throw new Exception("unexpected IQ"); }
        void sendNode(Node n) { sent ~= n; }
        void expectAck(string id) {}
        string nextId() { return "1.2-3"; }
        Node waitAck(string id, Duration timeout) { return Node("ack"); }
    }
}

unittest {
    // Bob could not decrypt our message and sends a retry receipt with <keys>; we rebuild the
    // session from them and resend the stored message, which Bob then decrypts.
    const ap = tempDir ~ "/wa-retry-a-" ~ thisProcessID.to!string ~ ".db";
    const bp = tempDir ~ "/wa-retry-b-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (p; [ap, bp]) foreach (s; ["", "-wal", "-shm"]) if (exists(p ~ s)) remove(p ~ s);
    auto alice = Device.create();
    alice.jid = "5511100:5@s.whatsapp.net";
    alice.account = [1, 2, 3];
    auto bob = Device.create();
    bob.jid = "5511200:0@s.whatsapp.net";
    auto aStore = new Store(ap);
    auto bStore = new Store(bp);

    // the message Alice "sent" earlier (stored), to Bob's chat
    ubyte[] proto = ProtoWriter().str(1, "chegou?").buf;
    aStore.putMessage("5511200@s.whatsapp.net", "3EB0AAA", "5511100:0", 1_700_000_000, true, proto);

    // Bob's retry receipt #2 with keys (fresh one-time pre-key in his store)
    auto bobOne = bStore.genOnePreKey();
    auto incoming = node("message", [["id", "3EB0AAA"], ["t", "1700000000"], ["type", "text"]]);
    incoming.attrs ~= Attr("from", Value(Jid.pair("5511100", "s.whatsapp.net")));
    RetryKeys k;
    k.identityPub = bob.identityKey.pub;
    k.oneTimeId = bobOne.id;
    k.oneTimePub = bobOne.key.pub;
    k.signedId = bob.signedPreKey.id;
    k.signedPub = bob.signedPreKey.key.pub;
    k.signedSig = bob.signedPreKey.signature;
    k.account = [9];
    auto rr = retryReceipt(incoming, 2, bob.registrationId, false, &k);
    // as Alice receives it: from = Bob's device
    rr.attrs = rr.attrs.dup;
    foreach (ref a; rr.attrs) if (a.key == "to") { a.key = "from"; a.value = Value(Jid.pair("5511200", "s.whatsapp.net")); }
    auto wire = encodeStanza(rr);
    auto onWire = decodeStanza(wire);

    auto conn = new FakeConn;
    RetryState st;
    auto status = handleRetryReceipt(conn, aStore, alice, onWire, st, 1_700_000_100);
    assert(conn.sent.length == 1, status);
    auto resent = conn.sent[0];
    assert(resent.get("id") == "3EB0AAA" && resent.get("t") == "1700000000");
    assert(resent.get("device_fanout") == "false" && resent.get("type") == "text");
    const enc = resent.child("enc");
    assert(enc !is null && enc.get("count") == "2" && enc.get("type") == "pkmsg");
    assert(resent.child("device-identity").bytes == [1, 2, 3]);

    // Bob decrypts the resent message (his one-time pre-key is consumed)
    auto back = decodeStanza(encodeStanza(resent));
    auto got = decryptEncFromStore(bStore, bob, "5511100:0", *back.child("enc"));
    assert(got == proto);

    // the 10th retry for the same message is dropped
    foreach (_; 0 .. 8) { try handleRetryReceipt(conn, aStore, alice, onWire, st, 1_700_000_200); catch (Exception) {} }
    assert(handleRetryReceipt(conn, aStore, alice, onWire, st, 1_700_000_300).length > 0);
    assert(st.incoming["5511200@s.whatsapp.net|3EB0AAA"] >= 10);
}
