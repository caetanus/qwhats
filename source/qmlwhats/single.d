// One window per user: the first instance listens on an abstract unix socket (no file to clean up
// after a crash: the kernel frees the name with the process); a second launch connects, says
// "raise" and exits, and the first brings its window up. Qt-free; the listener is polled by the
// backend's timer (accept is non-blocking), so nothing here runs off the Qt thread.
module qmlwhats.single;

import std.socket;

final class SingleInstance {
    private Socket listener;

    /// The socket name, per user (two users on one machine each get their own window).
    static string name() {
        import core.sys.posix.unistd : getuid;
        import std.conv : to;
        return "\0qml-whats-" ~ getuid().to!string;
    }

    /// Try to be the first instance. False: another one owns the name (it was told to raise).
    bool claim(string message = "raise") {
        auto addr = new UnixAddress(name());
        auto s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        try {
            s.bind(addr);
            s.listen(4);
            s.blocking = false;
            listener = s;
            return true;
        } catch (SocketOSException) {
            s.close();
        }
        // Taken: hand the message to the owner. If it cannot be reached (a dying owner), run anyway.
        try {
            auto c = new Socket(AddressFamily.UNIX, SocketType.STREAM);
            scope (exit) c.close();
            c.connect(addr);
            c.send(message ~ "\n");
            return false;
        } catch (SocketOSException) {
            return true;
        }
    }

    /// Give the name up (a restart: the new process takes it).
    void close() {
        if (listener !is null) { listener.close(); listener = null; }
    }

    /// Messages that arrived since the last poll (each connection carries one line).
    string[] poll() {
        string[] got;
        if (listener is null) return got;
        for (;;) {
            Socket c;
            try c = listener.accept();
            catch (SocketAcceptException) break;
            scope (exit) c.close();
            c.blocking = true;
            c.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(200));
            char[256] buf;
            const n = c.receive(buf[]);
            if (n > 0) {
                import std.string : strip;
                got ~= buf[0 .. n].idup.strip;
            }
        }
        return got;
    }

    import core.time : dur;
}

unittest {
    auto a = new SingleInstance;
    // A stale owner from another test run would make this flaky; the abstract name is per uid,
    // so this test only runs when no real instance is up.
    if (!a.claim()) return;
    auto b = new SingleInstance;
    assert(!b.claim("raise"));
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(50.msecs);
    assert(a.poll() == ["raise"]);
    assert(a.poll().length == 0);
}
