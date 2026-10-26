// kc-probe: the phone's SMS through KDE Connect, counts only — no numbers, names or texts printed.
import std.stdio;
import core.time : seconds;
import vibe.core.core : runTask, runEventLoop, exitEventLoop, sleep;
import kc.client;
import kc.contacts;

int status = 1;

void probe() {
    auto k = new KdeConnect();
    k.log = (string m) { stderr.writeln("kc: ", m); };
    writefln("device: %s (%s)", k.deviceName, k.reachable ? "reachable" : "not reachable");
    size_t created, updated, mms, groups, fromMe;
    long[long] perThread;
    size_t[int] types;
    k.onMessage = (SmsMessage m, bool c) {
        if (c) created++; else updated++;
        if (m.attachments.length) mms++;
        if (m.isGroup) groups++;
        if (m.fromMe) fromMe++;
        perThread[m.threadID]++;
        types[m.type]++;
    };
    size_t loaded;
    k.onLoaded = (long id, ulong n) { loaded++; };
    runTask(() nothrow { try k.run(); catch (Exception e) { try stderr.writeln("run: ", e.msg); catch (Exception) {} } });

    auto active = k.activeConversations();
    writefln("cached threads: %d", active.length);
    auto contacts = new Contacts;
    contacts.load(k.deviceID);
    writefln("contacts (vCards): %d numbers", contacts.byNumber.length);

    k.requestAllConversationThreads();
    sleep(8.seconds);
    writefln("message types seen (Android TYPE: 1 inbox, 2 sent, …): %s", types);
    writefln("after requestAllConversationThreads: %d created, %d updated, %d threads seen", created, updated, perThread.length);
    active = k.activeConversations();
    size_t[int] lastTypes;
    foreach (m; active) lastTypes[m.type]++;
    writefln("last message of each thread, by Android TYPE: %s", lastTypes);
    size_t named;
    foreach (m; active) foreach (a; m.addresses) if (contacts.name(a) !is null) { named++; break; }
    writefln("cached threads now: %d (%d with a contact name)", active.length, named);
    if (active.length) {
        // the newest thread: its last 10 messages
        auto newest = active[0];
        foreach (m; active) if (m.date > newest.date) newest = m;
        created = updated = mms = groups = fromMe = 0;
        k.requestConversation(newest.threadID, 0, 10);
        sleep(5.seconds);
        writefln("newest thread: %d messages loaded (%d sent by me, %d with attachments, %d group), loaded signals: %d",
            created + updated, fromMe, mms, groups, loaded);
    }
    status = 0;
    k.close();
}

int main() {
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
