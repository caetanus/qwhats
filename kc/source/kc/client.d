/// SMS/MMS through KDE Connect's daemon (kdeconnectd), on the session D-Bus. The phone runs the
/// KDE Connect app and is paired with the daemon; per device the daemon exposes
///   org.kde.kdeconnect.device.conversations — the cached threads (activeConversations), requests
///     for a thread's messages (requestConversation → conversationUpdated…, conversationLoaded),
///     sending (replyToConversation / sendWithoutConversation), attachments (requestAttachmentFile
///     → attachmentReceived), and conversationCreated/Updated/Removed as the phone reports;
///   org.kde.kdeconnect.device.contacts — vCards synced to ~/.local/share/kpeoplevcard/.
/// Wire formats after kdeconnect-kde (v26.08): models/conversationmessage.h's QDBusArgument
/// operators, plugins/sms/conversationsdbusinterface.cpp, plugins/sms/smsplugin.cpp.
/// Runs on vibe-core's event loop: the bus fd is watched by a task; calls block for at most their
/// timeout (the daemon answers from its cache — data comes back as signals).
module kc.client;

import std.string : toStringz, fromStringz;
import std.conv : to;
import core.time : seconds, msecs, Duration;
import kc.sdbus;

enum busName = "org.kde.kdeconnect";
enum daemonPath = "/modules/kdeconnect";
enum convIface = "org.kde.kdeconnect.device.conversations";
enum smsIface = "org.kde.kdeconnect.device.sms";
enum deviceIface = "org.kde.kdeconnect.device";

/// ConversationMessage's eventField bits
enum : int { eventTextMessage = 0x1, eventMultiTarget = 0x2 }
/// Android's Telephony.TextBasedSmsColumns.TYPE values the phone reports
enum : int { typeAll = 0, typeInbox = 1, typeSent = 2, typeDraft = 3, typeOutbox = 4, typeFailed = 5, typeQueued = 6 }

/// An MMS part: the thumbnail comes inline (base64); the full file on request (requestAttachment)
struct SmsAttachment {
    long partID;
    string mimeType;
    string base64Thumbnail;
    string uniqueIdentifier;
}

/// ConversationMessage: (isa(s)xiixixa(xsss))
struct SmsMessage {
    int eventField;
    string body;
    string[] addresses;      // the other party (or every participant of a group)
    long date;               // unix ms
    int type;                // typeInbox (received), typeSent, …
    bool read;
    long threadID;
    int uID;
    long subID;              // the SIM
    SmsAttachment[] attachments;

    bool fromMe() const { return type != typeInbox && type != typeAll; }
    bool isGroup() const { return (eventField & eventMultiTarget) != 0; }
}

class KdeConnectException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

private string errText(int r) {
    import core.stdc.string : strerror;
    return strerror(-r).fromStringz.idup;
}

/// Reads a message's arguments in order.
struct Reader {
    sd_bus_message* m;

    int int32() { int v; check(sd_bus_message_read_basic(m, 'i', &v), "i"); return v; }
    long int64() { long v; check(sd_bus_message_read_basic(m, 'x', &v), "x"); return v; }
    bool boolean() { int v; check(sd_bus_message_read_basic(m, 'b', &v), "b"); return v != 0; }
    string str() {
        const(char)* p;
        check(sd_bus_message_read_basic(m, 's', &p), "s");
        return p.fromStringz.idup;
    }
    /// false at the end of the enclosing array
    bool enter(char type, string contents) {
        const r = sd_bus_message_enter_container(m, type, contents.toStringz);
        check(r, "enter " ~ type ~ contents);
        return r > 0;
    }
    void exit() { check(sd_bus_message_exit_container(m), "exit"); }
    private void check(int r, string what) {
        if (r < 0) throw new KdeConnectException("reading D-Bus message (" ~ what ~ "): " ~ errText(r));
    }

    /// One ConversationMessage struct, at the current position
    SmsMessage message() {
        SmsMessage s;
        enter('r', "isa(s)xiixixa(xsss)");
        s.eventField = int32();
        s.body = str();
        enter('a', "(s)");
        while (enter('r', "s")) { s.addresses ~= str(); exit(); }
        exit();
        s.date = int64();
        s.type = int32();
        s.read = int32() != 0;
        s.threadID = int64();
        s.uID = int32();
        s.subID = int64();
        enter('a', "(xsss)");
        while (enter('r', "xsss")) {
            SmsAttachment a;
            a.partID = int64();
            a.mimeType = str();
            a.base64Thumbnail = str();
            a.uniqueIdentifier = str();
            s.attachments ~= a;
            exit();
        }
        exit();
        exit();
        return s;
    }

    /// A variant holding a ConversationMessage
    SmsMessage variantMessage() {
        enter('v', "(isa(s)xiixixa(xsss))");
        auto s = message();
        exit();
        return s;
    }
}

/// One paired phone through the daemon.
class KdeConnect {
    string deviceID;
    string deviceName;
    bool reachable;

    /// conversationCreated / conversationUpdated: a message the daemon learned (new, or loaded)
    void delegate(SmsMessage msg, bool created) onMessage;
    /// conversationLoaded: a requestConversation finished, `count` messages in the daemon's cache
    void delegate(long threadID, ulong count) onLoaded;
    void delegate(long threadID) onRemoved;
    /// attachmentReceived: the full file of an MMS part is at `path`
    void delegate(string path, string uniqueIdentifier) onAttachment;
    void delegate(bool reachable) onReachable;
    void delegate(string) log;

    private sd_bus* bus;
    private sd_bus_slot* convSlot, devSlot;
    private bool running;

    private string devPath() const { return daemonPath ~ "/devices/" ~ deviceID; }

    /// Open the session bus and pick the device: `id` if given, else the first paired one
    /// (reachable ones first).
    this(string id = null) {
        if (sd_bus_open_user(&bus) < 0) throw new KdeConnectException("no session D-Bus");
        string[] ids = id.length ? [id] : devices(true, true);
        if (!ids.length) ids = devices(false, true);
        if (!ids.length) throw new KdeConnectException("no paired KDE Connect device (pair the phone with kdeconnect first)");
        deviceID = ids[0];
        deviceName = propertyString(devPath, deviceIface, "name");
        reachable = propertyBool(devPath, deviceIface, "isReachable");
        const conv = "type='signal',sender='" ~ busName ~ "',path='" ~ devPath ~ "',interface='" ~ convIface ~ "'";
        const dev = "type='signal',sender='" ~ busName ~ "',path='" ~ devPath ~ "',interface='" ~ deviceIface ~ "'";
        if (sd_bus_add_match(bus, &convSlot, conv.toStringz, &onSignal, cast(void*) this) < 0
                || sd_bus_add_match(bus, &devSlot, dev.toStringz, &onSignal, cast(void*) this) < 0)
            throw new KdeConnectException("cannot subscribe to KDE Connect's signals");
    }

    ~this() { close(); }

    void close() {
        running = false;
        if (convSlot) { sd_bus_slot_unref(convSlot); convSlot = null; }
        if (devSlot) { sd_bus_slot_unref(devSlot); devSlot = null; }
        if (bus) { sd_bus_flush_close_unref(bus); bus = null; }
    }

    /// Dispatch the bus inside vibe's event loop (a task watching its fd). Returns at close().
    void run() {
        import vibe.core.core : createFileDescriptorEvent, FileDescriptorEvent;
        running = true;
        auto ev = createFileDescriptorEvent(sd_bus_get_fd(bus), FileDescriptorEvent.Trigger.read);
        while (running && bus) {
            pump();
            ev.wait(1.seconds);
        }
    }

    /// Process whatever is queued (signals, async replies)
    void pump() {
        while (bus) {
            const r = sd_bus_process(bus, null);
            if (r < 0) { logf("sd_bus_process: %s", errText(r)); return; }
            if (r == 0) break;
        }
        sd_bus_flush(bus);
    }

    // ---- daemon / device ---------------------------------------------------------------------

    string[] devices(bool onlyReachable, bool onlyPaired) {
        auto m = newCall(daemonPath, "org.kde.kdeconnect.daemon", "devices");
        int a = onlyReachable, b = onlyPaired;
        sd_bus_message_append_basic(m, 'b', &a);
        sd_bus_message_append_basic(m, 'b', &b);
        auto reply = call(m);
        scope (exit) sd_bus_message_unref(reply);
        auto r = Reader(reply);
        string[] ids;
        r.enter('a', "s");
        while (true) {
            const(char)* p;
            const rc = sd_bus_message_read_basic(reply, 's', &p);
            if (rc <= 0) break;
            ids ~= p.fromStringz.idup;
        }
        r.exit();
        return ids;
    }

    private string propertyString(string path, string iface, string name) {
        auto reply = getProperty(path, iface, name);
        scope (exit) sd_bus_message_unref(reply);
        auto r = Reader(reply);
        r.enter('v', "s");
        return r.str();
    }

    private bool propertyBool(string path, string iface, string name) {
        auto reply = getProperty(path, iface, name);
        scope (exit) sd_bus_message_unref(reply);
        auto r = Reader(reply);
        r.enter('v', "b");
        return r.boolean();
    }

    private sd_bus_message* getProperty(string path, string iface, string name) {
        auto m = newCall(path, "org.freedesktop.DBus.Properties", "Get");
        appendStr(m, iface);
        appendStr(m, name);
        return call(m);
    }

    // ---- conversations -----------------------------------------------------------------------

    /// The latest message of every thread the daemon has cached
    SmsMessage[] activeConversations() {
        auto reply = callAsync(newCall(devPath, convIface, "activeConversations"));
        scope (exit) sd_bus_message_unref(reply);
        auto r = Reader(reply);
        SmsMessage[] out_;
        r.enter('a', "v");
        while (true) {
            char t;
            const(char)* c;
            if (sd_bus_message_peek_type(reply, &t, &c) <= 0) break;
            out_ ~= r.variantMessage();
        }
        r.exit();
        return out_;
    }

    /// Ask the phone for the first message of every thread (they arrive as conversationCreated/Updated)
    void requestAllConversationThreads() { callVoid(newCall(devPath, convIface, "requestAllConversationThreads")); }

    /// Ask for messages [start, end) of a thread, newest first (conversationUpdated…, then conversationLoaded)
    void requestConversation(long threadID, int start, int end) {
        auto m = newCall(devPath, convIface, "requestConversation");
        sd_bus_message_append_basic(m, 'x', &threadID);
        sd_bus_message_append_basic(m, 'i', &start);
        sd_bus_message_append_basic(m, 'i', &end);
        callVoid(m);
    }

    /// Reply in a thread (a group thread answers the group); attachments are local file paths (MMS)
    void reply(long threadID, string body, string[] attachmentPaths = null) {
        auto m = newCall(devPath, convIface, "replyToConversation");
        sd_bus_message_append_basic(m, 'x', &threadID);
        appendStr(m, body);
        appendAttachments(m, attachmentPaths);
        callVoid(m);
    }

    /// Send to addresses with no thread yet (several addresses: a group MMS)
    void send(string[] addresses, string body, string[] attachmentPaths = null) {
        auto m = newCall(devPath, convIface, "sendWithoutConversation");
        // av of ConversationAddress (the struct (s)), as the SMS app sends them
        sd_bus_message_open_container(m, 'a', "v");
        foreach (a; addresses) {
            sd_bus_message_open_container(m, 'v', "(s)");
            sd_bus_message_open_container(m, 'r', "s");
            appendStr(m, a);
            sd_bus_message_close_container(m);
            sd_bus_message_close_container(m);
        }
        sd_bus_message_close_container(m);
        appendStr(m, body);
        appendAttachments(m, attachmentPaths);
        callVoid(m);
    }

    /// The full file of an MMS part: arrives as onAttachment(path, uniqueIdentifier)
    void requestAttachment(long partID, string uniqueIdentifier) {
        auto m = newCall(devPath, convIface, "requestAttachmentFile");
        sd_bus_message_append_basic(m, 'x', &partID);
        appendStr(m, uniqueIdentifier);
        callVoid(m);
    }

    /// Ask the phone to (re)send its contacts as vCards (kc.contacts reads them)
    void syncContacts() {
        callVoid(newCall(devPath ~ "/contacts", "org.kde.kdeconnect.device.contacts", "synchronizeRemoteWithLocal"));
    }

    // ---- plumbing ----------------------------------------------------------------------------

    private void appendAttachments(sd_bus_message* m, string[] paths) {
        import std.path : absolutePath;
        import std.uri : encode;
        // av of file:// URLs (smsplugin's createAttachmentFromUrl reads them)
        sd_bus_message_open_container(m, 'a', "v");
        foreach (p; paths) {
            sd_bus_message_open_container(m, 'v', "s");
            appendStr(m, "file://" ~ encode(p.absolutePath));
            sd_bus_message_close_container(m);
        }
        sd_bus_message_close_container(m);
    }

    private static void appendStr(sd_bus_message* m, string s) {
        sd_bus_message_append_basic(m, 's', s.toStringz);
    }

    private sd_bus_message* newCall(string path, string iface, string member) {
        if (!bus) throw new KdeConnectException("closed");
        sd_bus_message* m;
        const r = sd_bus_message_new_method_call(bus, &m, busName, path.toStringz, iface.toStringz, member.toStringz);
        if (r < 0) throw new KdeConnectException(member ~ ": " ~ errText(r));
        return m;
    }

    /// Call (5 s at most) and return the reply, which the caller unrefs
    private sd_bus_message* call(sd_bus_message* m) {
        scope (exit) sd_bus_message_unref(m);
        sd_bus_error err;
        sd_bus_message* reply;
        const r = sd_bus_call(bus, m, 5_000_000, &err, &reply);
        scope (exit) sd_bus_error_free(&err);
        if (r < 0) {
            const member = sd_bus_message_get_member(m).fromStringz.idup;
            throw new KdeConnectException(member ~ ": " ~ (err.message ? err.message.fromStringz.idup : errText(r)));
        }
        return reply;
    }

    private void callVoid(sd_bus_message* m) { sd_bus_message_unref(callAsync(m)); }

    /// An in-flight call: the reply comes back through run()'s sd_bus_process (same thread)
    private static final class Pending {
        import vibe.core.sync : LocalManualEvent;
        sd_bus_message* reply;
        bool done;
        LocalManualEvent ev;
    }
    private bool[Pending] inFlight;   // keeps them reachable while sd-bus holds the pointer

    private extern (C) static int onReply(sd_bus_message* m, void* ud, sd_bus_error*) nothrow {
        auto p = cast(Pending) ud;
        p.reply = sd_bus_message_ref(m);
        p.done = true;
        try p.ev.emit(); catch (Exception) {}
        return 0;
    }

    /// Call without blocking the event loop: the request goes out, this task waits (6 s at most)
    /// while run() keeps dispatching — a stalled kdeconnectd no longer freezes the whole core.
    /// Before run() is dispatching (the constructor), a plain blocking call.
    private sd_bus_message* callAsync(sd_bus_message* m) {
        import vibe.core.sync : createManualEvent;
        if (!running) return call(m);
        auto p = new Pending;
        p.ev = createManualEvent();
        inFlight[p] = true;
        scope (exit) inFlight.remove(p);
        sd_bus_slot* slot;
        const r = sd_bus_call_async(bus, &slot, m, &onReply, cast(void*) p, 5_000_000);
        const member = sd_bus_message_get_member(m).fromStringz.idup;
        sd_bus_message_unref(m);
        if (r < 0) throw new KdeConnectException(member ~ ": " ~ errText(r));
        scope (exit) sd_bus_slot_unref(slot);
        sd_bus_flush(bus);
        const count = p.ev.emitCount;
        if (!p.done) p.ev.wait(6.seconds, count);
        if (!p.done) throw new KdeConnectException(member ~ ": no answer from kdeconnectd");
        if (sd_bus_message_is_method_error(p.reply, null) > 0) {
            auto e = sd_bus_message_get_error(p.reply);
            const msg = e && e.message ? e.message.fromStringz.idup : "error";
            sd_bus_message_unref(p.reply);
            throw new KdeConnectException(member ~ ": " ~ msg);
        }
        return p.reply;
    }

    private extern (C) static int onSignal(sd_bus_message* m, void* self, sd_bus_error*) nothrow {
        try (cast(KdeConnect) self).dispatch(m);
        catch (Exception e) { try (cast(KdeConnect) self).logf("signal: %s", e.msg); catch (Exception) {} }
        return 0;
    }

    private void dispatch(sd_bus_message* m) {
        const member = sd_bus_message_get_member(m).fromStringz;
        auto r = Reader(m);
        switch (member) {
            case "conversationCreated", "conversationUpdated":
                auto msg = r.variantMessage();
                if (onMessage !is null) onMessage(msg, member == "conversationCreated");
                break;
            case "conversationLoaded":
                const id = r.int64();
                ulong n;
                sd_bus_message_read_basic(m, 't', &n);
                if (onLoaded !is null) onLoaded(id, n);
                break;
            case "conversationRemoved":
                if (onRemoved !is null) onRemoved(r.int64());
                break;
            case "attachmentReceived":
                const path = r.str(), uid = r.str();
                if (onAttachment !is null) onAttachment(path, uid);
                break;
            case "reachableChanged":
                reachable = r.boolean();
                if (onReachable !is null) onReachable(reachable);
                break;
            default: break;
        }
    }

    void logf(A...)(string fmt, A args) nothrow {
        import std.format : format;
        try if (log !is null) log(format(fmt, args));
        catch (Exception) {}
    }
}
