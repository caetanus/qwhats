// The UI's `core`: qwhats-core (Go + whatsmeow, docs/native-client.md) as a child process speaking
// JSON-RPC 2.0 lines on its stdio. This side only relays: call() writes a request line; every line
// the core prints (replies and events) comes back to the UI as the `line` signal, in order. The UI
// keeps the state. A reader thread fills a queue; the UI thread's timer drains it (pump), so
// nothing Qt is touched off the UI thread.
module qmlwhats.native.corebridge;

import qtmoc;
import std.process : pipeProcess, ProcessPipes, Redirect, kill, tryWait;
import std.json;
import core.sync.mutex : Mutex;
import core.thread : Thread;

@QObject class CoreBridge {
    /// One line from the core: a reply (has "id") or an event (has "method", no "id").
    Signal!(string) line;
    Signal!() stateChanged;

    /// "starting" | "running" | "stopped" (the core exited; `lastError` says why).
    @Property("stateChanged") string state = "starting";
    @Property("stateChanged") string lastError = "";

    private ProcessPipes proc;
    private Mutex lock;
    private string[] queue;
    private Thread reader;
    private Thread errReader;
    private string errTail;

    void start(string exe, string dataDir, string cacheDir, string[] extra = null) {
        lock = new Mutex;
        try proc = pipeProcess([exe, "--data", dataDir, "--cache", cacheDir] ~ extra, Redirect.stdin | Redirect.stdout | Redirect.stderr);
        catch (Exception e) { state = "stopped"; lastError = e.msg; stateChanged.emit(); return; }
        reader = new Thread(&readLoop);
        reader.isDaemon = true;
        reader.start();
        errReader = new Thread(&errLoop);
        errReader.isDaemon = true;
        errReader.start();
        state = "running";
        stateChanged.emit();
    }

    private void readLoop() {
        try {
            foreach (l; proc.stdout.byLineCopy()) {
                synchronized (lock) queue ~= l;
            }
        } catch (Exception) {}
        synchronized (lock) queue ~= `{"jsonrpc":"2.0","method":"coreExited","params":{}}`;
    }

    private void errLoop() {
        import std.stdio : stderr;
        try foreach (l; proc.stderr.byLineCopy()) {
            stderr.writeln("qwhats-core: ", l);
            synchronized (lock) { errTail = l; }
        } catch (Exception) {}
    }

    /// A local event for the UI, delivered like the core's own (`{"method": …, "params": …}`) on
    /// the next pump — e.g. "App:openUrl" from a whatsapp:// link.
    void inject(string method, JSONValue params) {
        if (lock is null) return;
        JSONValue n = ["jsonrpc": JSONValue("2.0"), "method": JSONValue(method), "params": params];
        synchronized (lock) queue ~= n.toString();
    }

    /// On the UI thread (the app's timer): hand the queued lines to the UI.
    void pump() {
        if (lock is null) return;
        string[] got;
        synchronized (lock) { got = queue; queue = null; }
        foreach (l; got) {
            if (l == `{"jsonrpc":"2.0","method":"coreExited","params":{}}` && state != "stopped") {
                state = "stopped";
                synchronized (lock) lastError = errTail;
                stateChanged.emit();
            }
            line.emit(l);
        }
    }

    /// A request: `paramsJson` an object ("" for none); `id` the UI's own number to match the reply.
    @Slot void call(int id, string method, string paramsJson) {
        if (state != "running") return;
        JSONValue req = ["jsonrpc": JSONValue("2.0"), "id": JSONValue(id), "method": JSONValue(method)];
        try req["params"] = parseJSON(paramsJson.length ? paramsJson : "{}");
        catch (JSONException) req["params"] = parseJSON("{}");
        try {
            proc.stdin.writeln(req.toString());
            proc.stdin.flush();
        } catch (Exception e) {
            state = "stopped";
            lastError = e.msg;
            stateChanged.emit();
        }
    }

    /// The core goes with the app: closing its stdin ends it (it disconnects cleanly).
    void stop() {
        if (proc.pid is null) return;
        try proc.stdin.close();
        catch (Exception) {}
        foreach (_; 0 .. 30) {
            if (tryWait(proc.pid).terminated) return;
            Thread.sleep(dur!"msecs"(100));
        }
        kill(proc.pid);
    }

    import core.time : dur;
}
