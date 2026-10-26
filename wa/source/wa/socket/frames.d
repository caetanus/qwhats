/// WhatsApp's frames over the websocket (WAFrameSocket): each frame is a 3-byte big-endian length
/// and its bytes; the first frame of a connection is preceded by the prologue ("WA", 6, the
/// dictionary version). A websocket message may carry several frames or part of one.
module wa.socket.frames;

import vibe.http.websockets : WebSocket, connectWebSocketEx;
import vibe.inet.url : URL;
import wa.binary.dict : dictVersion;

enum string waURL = "wss://web.whatsapp.com/ws/chat";
enum string waOrigin = "https://web.whatsapp.com";
enum string chromeUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
immutable ubyte[] connHeader = ['W', 'A', 6, dictVersion];
enum size_t frameMax = 1 << 24;

class FrameSocket {
    private WebSocket ws;
    private ubyte[] pending;
    private bool headerSent;

    /// Connects as Chrome on web.whatsapp.com does (its Origin and User-Agent).
    this(string url = waURL) {
        ws = connectWebSocketEx(URL(url), (scope req) {
            req.headers["Origin"] = waOrigin;
            req.headers["User-Agent"] = chromeUA;
        });
    }

    void send(const(ubyte)[] frame) {
        if (frame.length >= frameMax) throw new Exception("frame too large");
        ubyte[] b;
        if (!headerSent) { b ~= connHeader; headerSent = true; }
        b ~= cast(ubyte)(frame.length >> 16);
        b ~= cast(ubyte)(frame.length >> 8);
        b ~= cast(ubyte) frame.length;
        b ~= frame;
        ws.send(b);
    }

    /// The next frame; null when the connection closed.
    ubyte[] receive() {
        while (true) {
            if (pending.length >= 3) {
                const n = (cast(size_t) pending[0] << 16) | (cast(size_t) pending[1] << 8) | pending[2];
                if (pending.length >= 3 + n) {
                    auto f = pending[3 .. 3 + n].dup;
                    pending = pending[3 + n .. $].dup;
                    return f;
                }
            }
            if (!ws.waitForData()) return null;
            pending ~= ws.receiveBinary();
        }
    }

    bool connected() { return ws.connected; }
    /// Always through ws.close(), even when the peer already dropped us: it is what releases the
    /// HTTP client the upgrade came from. Skipped, that client went back to vibe-http's pool still
    /// "responding", and the next connect asserted ("Interleaved HTTP client request/response").
    void close() {
        try ws.close();
        catch (Exception) {}
    }
}
