// wa-probe: the D protocol against WhatsApp's real server.
//   wa-probe                      a new, unpaired device: handshake, registration, <pair-device>
//   wa-probe --login DEVICE.DB    the Go core's pairing, read-only: keys checked offline …
//   wa-probe --login DEVICE.DB --connect   … then a passive login up to <success>, and out
// The passive login never activates the session, so the server delivers no messages to us (they
// stay for the Go core); only one connection per device may be open: close the app first.
import std.stdio;
import std.json : JSONValue;
import vibe.core.core : runTask, runEventLoop, exitEventLoop;
import wa.binary;
import wa.crypto : xeddsaVerify;
import wa.device;
import wa.pairing;
import wa.socket.frames;
import wa.socket.handshake;
import wa.store.db : Store;
import wa.store.whatsmeow;
import wa.crypto : KeyPair;
import wa.prekey : PreKey, uploadPreKeysIQ;
import wa.envelope : parseMessageStanza, signalAddress, IncomingMessage, jidAttr;
import wa.messages : decryptEncFromStore, decryptGroupEncFromStore, processSenderKeyDistributionToStore;
import wa.receipt : ackStanza, messageReceipt;
import wa.proto : ProtoWriter, ProtoReader;
import wa.send : Connection, invalidateDevices, sendPeerMessage, unavailableMessageRequest;
import wa.retry : handleRetryReceipt, RetryState;
import wa.lid : learnFromMessage, lidEncryptionIdentity = encryptionIdentity, storeLIDPNMapping;
import wa.tctoken : isBot, storePrivacyTokens, tokenStorageKey, tcTokenExpired, issuePrivacyTokenIQ;
import wa.envelope : parseJidString;
import wa.message : messageKinds, senderKeyDistribution, conversationText;
import wa.history;
import wa.media : httpGet, mediaURL, mediaConnIQ, parseMediaConnHosts, historyMmsType;

import core.time : Duration;

int status = 1;
string loginStore;   // --login: read whatsmeow's device.db (the Go core's pairing)
string ourStore;     // --store: our own store — pair into it, or load it and reconnect
bool connect;
bool serve;          // --serve: after login, upload prekeys and handle incoming stanzas (LIVE)

/// Where the current pairing QR is written as a PNG (for a viewer that reloads it).
enum qrPngPath = "~/.cache/qml-whats-build/pair-qr.png";

void writeQRPng(string payload) {
    import std.process : execute;
    import std.path : expandTilde;
    import std.file : rename;
    const dst = qrPngPath.expandTilde, tmp = dst ~ ".tmp.png";
    try {
        if (execute(["qrencode", "-o", tmp, "-s", "10", "-m", "2", payload]).status == 0) rename(tmp, dst);
    } catch (Exception) {}
}

/// Render a QR payload in the terminal with `qrencode` if present, else print the raw string.
/// Also writes it as a PNG (qrPngPath).
void showQR(string payload) {
    writeQRPng(payload);
    import std.process : execute;
    try {
        auto r = execute(["qrencode", "-t", "UTF8", "-m", "1", payload]);
        if (r.status == 0) { write(r.output); return; }
    } catch (Exception) {}
    writeln(payload);
}

void probe() {
    import std.path : expandTilde, absolutePath;
    Device dev;
    Store store;
    bool paired;
    if (ourStore.length) {
        ourStore = ourStore.expandTilde.absolutePath;
        store = new Store(ourStore);
        writeln("store: ", ourStore);
    }
    if (store !is null && store.loadDevice().paired && connect && serve && loginStore.length == 0) {
        dev = store.loadDevice();
        writefln("our store: paired device %s — logging in", dev.jid.length ? "present" : "missing");
        serveForever(dev, store);
        return;
    }
    if (loginStore.length == 0 && (store is null || !store.loadDevice().paired) && store is null) {
        writeln("pairing needs --store PATH (otherwise the new device's keys are lost)");
        return;
    }
    if (loginStore.length) {
        dev = loadWhatsmeowDevice(loginStore);
        const ok = xeddsaVerify(dev.identityKey.pub, serializedKey(dev.signedPreKey.key.pub), dev.signedPreKey.signature);
        writefln("store read: paired device %s, signed pre-key %s (signature by our identity: %s)",
            dev.jid.length ? "present" : "missing", dev.signedPreKey.id, ok ? "valid" : "INVALID");
        if (!ok || !dev.paired) return;
        if (!connect) { status = 0; return; }
    } else if (store !is null && store.loadDevice().paired) {
        dev = store.loadDevice(); // our own pairing: reconnect as that device
        const ok = xeddsaVerify(dev.identityKey.pub, serializedKey(dev.signedPreKey.key.pub), dev.signedPreKey.signature);
        writefln("our store: paired device %s (signed pre-key signature: %s)", dev.jid, ok ? "valid" : "INVALID");
        if (!ok) return;
        if (!connect) { status = 0; return; }
    } else {
        dev = Device.create();
    }
    auto fs = new FrameSocket();
    writeln("websocket open");
    auto sock = handshake(fs, dev, WAVersion());
    writeln("noise handshake done (server certificate chain verified)");
    foreach (_; 0 .. 3) {
        auto plain = sock.receive();
        if (plain is null) { writeln("server closed"); break; }
        auto n = decodeStanza(plain);
        if (dev.paired) {
            // the account's own data stays out of the output: the tag and attribute names only
            string keys;
            foreach (a; n.attrs) keys ~= " " ~ a.key;
            writefln("<- <%s%s> %s", n.tag, keys, n.tag == "failure" ? "reason=" ~ n.get("reason") : "");
            if (n.tag == "success") {
                writeln("login accepted: same linked device, no new pairing");
                status = 0;
                if (serve && store !is null) writeln("   (--serve runs with our own --store only)");
            }
            break;
        }
        string shown = n.toString();
        writeln("<- ", shown.length > 200 ? shown[0 .. 200] ~ "…" : shown);
        if (n.tag == "iq" && n.get("type") == "set" && n.child("pair-device")) {
            // ack the registration, then show the first QR for the phone to scan
            auto ack = node("iq", [["to", "s.whatsapp.net"], ["type", "result"], ["id", n.get("id")]]);
            ack.attrs[0].value = Value(Jid.pair(null, "s.whatsapp.net"));
            sock.send(encodeStanza(ack));
            auto qrs = pairingQRs(dev, *n.child("pair-device"));
            if (qrs.length == 0) { writeln("pair-device had no refs"); break; }
            writeln("scan this QR in WhatsApp → Linked devices → Link a device:");
            showQR(qrs[0]);
            // rotate through the refs as WhatsApp Web does (first 60 s, then 20 s each), keeping
            // the PNG current so a viewer can follow it
            {
                import vibe.core.core : runTask, sleep;
                import core.time : seconds;
                auto refs = qrs.dup;
                runTask(() nothrow {
                    try {
                        foreach (i, q; refs) {
                            sleep(i == 0 ? 60.seconds : 20.seconds);
                            if (paired || i + 1 >= refs.length) break;
                            writeQRPng(refs[i + 1]);
                            writefln("   QR rotated (%d/%d)", i + 2, refs.length);
                        }
                    } catch (Exception) {}
                });
            }
            // keep receiving: the next ref rotations (re-show) and finally <pair-success>
            foreach (_2; 0 .. 40) {
                auto p2 = sock.receive();
                if (p2 is null) { writeln("server closed before pairing"); break; }
                auto m = decodeStanza(p2);
                if (m.tag == "iq" && m.get("type") == "set" && m.child("pair-success")) {
                    auto reply = handlePairSuccess(dev, m);
                    sock.send(encodeStanza(reply));
                    writefln("paired as %s (lid %s) — ADV identity verified and counter-signed",
                        dev.jid, dev.lid.length ? dev.lid : "none");
                    // save BEFORE anything else: without these keys the linked device is orphaned
                    store.saveDevice(dev);
                    import std.file : exists;
                    if (!exists(ourStore) || !store.loadDevice().paired) {
                        writeln("ERROR: device not persisted to ", ourStore, " — remove it from the phone");
                        break;
                    }
                    writefln("saved to our store: %s", ourStore);
                    // the server answers the sign with <stream:error code=515> (restart required);
                    // wait for it, then log in as the new device right away, as whatsmeow does
                    foreach (_3; 0 .. 5) {
                        auto p3 = sock.receive();
                        if (p3 is null) break;
                        auto e = decodeStanza(p3);
                        writefln("<- <%s> %s", e.tag, e.get("code"));
                        if (e.tag == "stream:error") break;
                    }
                    sock.close();
                    paired = true;
                    break;
                }
                writeln("<- waiting for scan: <", m.tag, ">");
            }
            break;
        }
    }
    if (paired) {
        // first login of the freshly linked device: this is what makes the phone stop "connecting"
        writeln("logging in as the new device…");
        serveForever(dev, store);
        return;
    }
    sock.close();
}

/// Log in with our own store and serve (wa.app.Client), the UI's chat store kept next to it.
void serveForever(ref Device dev, Store store) {
    import wa.app.client : Client;
    import wa.app.chatstore : ChatStore;
    import wa.store.sql : Db;
    import std.path : expandTilde;
    size_t uiEvents;
    auto chats = new ChatStore(new Db("~/.cache/qml-whats-build/wa-dcore-chats.db".expandTilde));
    auto c = new Client(store, chats, "main", (string m, JSONValue p) { uiEvents++; });
    c.run();
    status = c.status;
    writefln("client stopped (%d UI events)", uiEvents);
}

int main(string[] args) {
    import std.getopt : getopt;
    getopt(args, "login", &loginStore, "store", &ourStore, "connect", &connect, "serve", &serve);
    // line-buffered even when redirected to a log file, so the log can be followed live
    import core.stdc.stdio : _IOLBF;
    stdout.setvbuf(4096, _IOLBF);
    runTask(() nothrow {
        try probe();
        catch (Exception e) { try stderr.writeln("probe failed: ", e.msg); catch (Exception) {} }
        exitEventLoop();
    });
    runEventLoop();
    return status;
}
