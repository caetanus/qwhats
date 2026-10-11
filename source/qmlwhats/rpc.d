// Remote control: JSON-RPC 2.0 over a unix socket, one request per line, one response per line.
// The socket lives in $XDG_RUNTIME_DIR (a per-user 0700 directory) and is made 0600: only this user
// can drive the app. Qt-free and non-blocking — the backend polls it from its timer, hands each
// request to the UI (which knows the pages) and writes the answer back on the same connection when
// the UI gives it, however late (a message sent through a page answers after the chat opened).
module qmlwhats.rpc;

import std.socket;
import std.json;

final class RpcServer {
    private Socket listener;
    private Socket[int] conns;
    private char[][int] pending;   // bytes received but not yet a full line, per connection
    private int nextId = 1;
    string path;

    /// Listen on `path` (a stale socket file from a crashed run is replaced). False when it cannot.
    bool open(string p) {
        import std.file : exists, remove;
        import core.sys.posix.sys.stat : chmod;
        import std.string : toStringz;
        path = p;
        try {
            if (exists(p)) remove(p);
            auto s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
            s.bind(new UnixAddress(p));
            chmod(p.toStringz, octal600);
            s.listen(8);
            s.blocking = false;
            listener = s;
            return true;
        } catch (Exception) {
            return false;
        }
    }
    private enum octal600 = 0x180;   // 0600

    bool isOpen() const { return listener !is null; }

    void close() {
        import std.file : exists, remove;
        foreach (c; conns) c.close();
        conns = null;
        pending = null;
        if (listener !is null) { listener.close(); listener = null; }
        try if (path.length && exists(path)) remove(path);
        catch (Exception) {}
    }

    /// A complete request line, and the connection to answer on.
    static struct Request { int conn; string line; }

    /// Accept new clients, read what they sent; the complete lines come back.
    Request[] poll() {
        Request[] got;
        if (listener is null) return got;
        for (;;) {
            Socket c;
            try c = listener.accept();
            catch (SocketAcceptException) break;
            c.blocking = false;
            conns[nextId] = c;
            pending[nextId] = null;
            ++nextId;
        }
        int[] dead;
        foreach (id, c; conns) {
            char[4096] buf;
            for (;;) {
                const n = c.receive(buf[]);
                if (n == 0) { dead ~= id; break; }               // the client went away
                if (n == Socket.ERROR) {
                    if (!wouldHaveBlocked()) dead ~= id;
                    break;
                }
                pending[id] ~= buf[0 .. n];
                if (pending[id].length > 1 << 20) { dead ~= id; break; }   // a megabyte without a newline: not a client
            }
            // split complete lines
            for (;;) {
                import std.string : indexOf, strip;
                const i = (cast(string) pending[id]).indexOf('\n');
                if (i < 0) break;
                auto line = (cast(string) pending[id][0 .. i]).strip.idup;
                pending[id] = pending[id][i + 1 .. $].dup;
                if (line.length) got ~= Request(id, line);
            }
        }
        foreach (id; dead) drop(id);
        return got;
    }

    /// Write one response line to a connection (if it is still there).
    void reply(int conn, string json) {
        auto c = conn in conns;
        if (c is null) return;
        (*c).blocking = true;   // small answers: write them whole
        scope (exit) if (conn in conns) (*c).blocking = false;
        const data = json ~ "\n";
        size_t sent;
        while (sent < data.length) {
            const n = (*c).send(data[sent .. $]);
            if (n <= 0) { drop(conn); return; }
            sent += n;
        }
    }

    private void drop(int id) {
        if (auto c = id in conns) (*c).close();
        conns.remove(id);
        pending.remove(id);
    }
}

/// A JSON-RPC 2.0 error response.
string rpcError(JSONValue id, int code, string message) {
    JSONValue r = ["jsonrpc": JSONValue("2.0")];
    r["id"] = id;
    r["error"] = JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
    return r.toString();
}

/// Parse a request line: (id, method, params) or an error response to send back as is.
bool parseRequest(string line, out JSONValue id, out string method, out JSONValue params, out string errorResponse) {
    JSONValue v;
    id = JSONValue(null);
    try v = parseJSON(line);
    catch (JSONException) { errorResponse = rpcError(id, -32700, "parse error"); return false; }
    if (v.type != JSONType.object) { errorResponse = rpcError(id, -32600, "invalid request"); return false; }
    if (auto p = "id" in v.object) id = *p;
    auto m = "method" in v.object;
    if (m is null || m.type != JSONType.string) { errorResponse = rpcError(id, -32600, "invalid request: no method"); return false; }
    method = m.str;
    if (auto p = "params" in v.object) params = *p;
    else params = parseJSON("{}");
    return true;
}

unittest {
    JSONValue id, params;
    string method, err;
    assert(parseRequest(`{"jsonrpc":"2.0","id":7,"method":"app.status"}`, id, method, params, err));
    assert(id.integer == 7 && method == "app.status" && params.type == JSONType.object);
    assert(!parseRequest(`{broken`, id, method, params, err));
    assert(parseJSON(err)["error"]["code"].integer == -32700);
    assert(!parseRequest(`{"id":1}`, id, method, params, err));
    assert(parseJSON(err)["error"]["code"].integer == -32600);

    // a round trip over a real socket
    import std.file : tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;
    auto srv = new RpcServer;
    const p = buildPath(tempDir, "qwhats-rpc-test-" ~ thisProcessID.to!string ~ ".sock");
    assert(srv.open(p));
    scope (exit) srv.close();
    auto c = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    c.connect(new UnixAddress(p));
    c.send(`{"jsonrpc":"2.0","id":1,"method":"a"}` ~ "\n" ~ `{"jsonrpc":"2.0","id":2,"me`);
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(30.msecs);
    auto got = srv.poll();
    assert(got.length == 1 && got[0].line == `{"jsonrpc":"2.0","id":1,"method":"a"}`);
    c.send(`thod":"b"}` ~ "\n");
    Thread.sleep(30.msecs);
    got = srv.poll();
    assert(got.length == 1 && got[0].line == `{"jsonrpc":"2.0","id":2,"method":"b"}`);
    srv.reply(got[0].conn, `{"ok":1}`);
    char[64] buf;
    const n = c.receive(buf[]);
    assert(buf[0 .. n] == `{"ok":1}` ~ "\n");
    c.close();
}
