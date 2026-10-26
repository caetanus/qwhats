/// Voice notes in qwhats-dcore, as the Go core records them (core/recorder.go): the microphone
/// (PulseAudio/PipeWire's default source) through ffmpeg into a lossless WAV, the sound level handed
/// back ten times a second for the composer's waveform; on stop, a file pass — noise reduction,
/// compressor, loudness normalisation (the AGC), limiter — into Opus exactly as WhatsApp Web
/// encodes voice notes: mono, 16 kHz, 16 kbps, VOIP.
///   startRecording {denoise, denoiseModel} → {path}     stopRecording {send} → {path, seconds} | {}
/// Events: Recorder:level {level 0..1}.
/// QWHATS_RECORD_TEST_INPUT=<audio file>: that file (played in real time) instead of the microphone —
/// for tests only (never the real microphone in an automated session).
module recorder;

import std.json;
import std.conv : to;
import core.time : msecs, seconds, MonoTime;
import vibe.core.core : runTask, sleep;

final class Recorder {
    private void delegate(string, JSONValue) emit;
    private string cacheDir;
    private string[] modelDirs;   // where an RNNoise model (*.rnnn) may be

    private struct Rec {
        import std.process : ProcessPipes;
        ProcessPipes pipes;
        string raw, path, denoise;
        MonoTime start;
        bool levelDone;
    }
    private Rec* now;

    this(void delegate(string, JSONValue) emit, string cacheDir, string[] modelDirs) {
        this.emit = emit;
        this.cacheDir = cacheDir;
        this.modelDirs = modelDirs;
    }

    /// denoiseModelPath: an explicit path wins; else bd.rnnn (voice-tuned), then any .rnnn, in the
    /// model folders; "" falls back to afftdn
    private string modelPath(string requested) {
        import std.file : exists, dirEntries, SpanMode, isDir;
        import std.path : buildPath;
        import std.stdio : stderr;
        if (requested.length) {
            if (exists(requested)) return requested;
            try stderr.writeln("qwhats-dcore: denoise model not found, using afftdn: ", requested); catch (Exception) {}
            return "";
        }
        foreach (d; modelDirs) {
            const p = buildPath(d, "bd.rnnn");
            if (exists(p)) return p;
        }
        foreach (d; modelDirs) {
            if (!exists(d) || !isDir(d)) continue;
            foreach (e; dirEntries(d, "*.rnnn", SpanMode.shallow)) return e.name;
        }
        return "";
    }

    private static string denoiseFilter(bool on, string model) {
        import std.array : replace;
        if (!on) return "";
        if (model.length) return "arnndn=m='" ~ model.replace("'", "") ~ "':mix=1,";
        return "afftdn=nr=24:nf=-25:tn=1,";
    }

    JSONValue start(bool denoise, string modelReq) {
        import std.process : pipeProcess, Redirect, environment, Config;
        import wa.app.client : toolEnv;
        import std.file : mkdirRecurse;
        import std.path : buildPath;
        import std.datetime.systime : Clock;
        import std.stdio : stderr;
        if (now !is null) throw new Exception("already recording");
        const model = denoise ? modelPath(modelReq) : "";
        const dir = buildPath(cacheDir, "outbox");
        mkdirRecurse(dir);
        const stamp = (Clock.currTime.toUnixTime!long * 1000 + Clock.currTime.fracSecs.total!"msecs").to!string;
        auto r = new Rec;
        r.raw = buildPath(dir, "voice-" ~ stamp ~ ".raw.wav");
        r.path = buildPath(dir, "voice-" ~ stamp ~ ".ogg");
        r.denoise = denoiseFilter(denoise, model);
        // the live capture is kept SIMPLE and lossless (denoisers in a live graph garble it and cut the
        // tail): the mic, a rumble cut, into a WAV, with the level meter alongside
        const testInput = environment.get("QWHATS_RECORD_TEST_INPUT", "");
        string[] input = testInput.length ? ["-re", "-i", testInput] : ["-f", "pulse", "-i", "default"];
        try stderr.writeln("qwhats-dcore: recording (denoise on stop=", denoise ? (model.length ? "arnndn" : "afftdn") : "off",
            testInput.length ? ", TEST INPUT" : "", ")"); catch (Exception) {}
        r.pipes = pipeProcess(["ffmpeg", "-hide_banner", "-loglevel", "error"] ~ input ~ [
            "-filter_complex", "[0:a]aformat=channel_layouts=mono,highpass=f=80,asplit=2[enc][lvl]",
            "-map", "[enc]", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "wav", "-y", r.raw,
            "-map", "[lvl]", "-ar", "8000", "-f", "s16le", "pipe:1"], Redirect.stdin | Redirect.stdout, toolEnv(), Config.newEnv);
        r.start = MonoTime.currTime;
        now = r;
        runTask((Rec* r) nothrow { try levelLoop(r); catch (Exception) {} r.levelDone = true; }, r);
        return JSONValue(["path": JSONValue(r.raw)]);
    }

    /// the level: the peak of each 100 ms of 8 kHz audio, 0..1 (its square root, as the Go core) —
    /// read off the non-blocking pipe, polled every 50 ms, without holding the event loop
    private void levelLoop(Rec* r) {
        import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
        import core.sys.posix.unistd : read;
        import core.stdc.errno : errno, EAGAIN, EINTR;
        import std.math : abs, sqrt, fmin;
        const fd = r.pipes.stdout.fileno;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        ubyte[1600] block;   // 800 samples = 100 ms at 8 kHz
        size_t have;
        ubyte[4096] buf;
        for (;;) {
            const n = read(fd, buf.ptr, buf.length);
            if (n == 0) return;   // ffmpeg finished
            if (n < 0) {
                // polled: a FileDescriptorEvent on this pipe returned at once without yielding, and the
                // loop spun, starving every other task (startRecording answered 5 s late)
                if (errno == EAGAIN || errno == EINTR) { sleep(50.msecs); continue; }
                return;
            }
            foreach (b; buf[0 .. n]) {
                block[have++] = b;
                if (have < block.length) continue;
                have = 0;
                double peak = 0;
                for (size_t i = 0; i + 1 < block.length; i += 2) {
                    const v = abs(cast(double) cast(short)(block[i] | (block[i + 1] << 8)) / 32_768);
                    if (v > peak) peak = v;
                }
                emit("Recorder:level", JSONValue(["level": JSONValue(fmin(1, sqrt(peak)))]));
            }
        }
    }

    /// the app is going away: a recording in progress ends here (the microphone is not left open)
    void shutdown() nothrow {
        import std.process : kill;
        import std.file : remove;
        auto r = now;
        now = null;
        if (r is null) return;
        try kill(r.pipes.pid); catch (Exception) {}
        try remove(r.raw); catch (Exception) {}
    }

    JSONValue stop(bool send) {
        import std.process : tryWait, kill;
        import std.file : exists, getSize, remove;
        import std.math : round;
        import std.stdio : stderr;
        auto r = now;
        now = null;
        if (r is null) throw new Exception("not recording");
        // ffmpeg's own stop: it finishes the WAV
        try { r.pipes.stdin.write("q"); r.pipes.stdin.close(); } catch (Exception) {}
        const deadline = MonoTime.currTime + 5.seconds;
        for (;;) {
            auto w = tryWait(r.pipes.pid);
            if (w.terminated) break;
            if (MonoTime.currTime > deadline) { kill(r.pipes.pid); sleep(100.msecs); tryWait(r.pipes.pid); break; }
            sleep(50.msecs);
        }
        const secs = cast(long) round((MonoTime.currTime - r.start).total!"msecs" / 1000.0);
        if (!send) {
            try remove(r.raw); catch (Exception) {}
            return JSONValue.emptyObject;
        }
        if (!exists(r.raw) || getSize(r.raw) < 1024) {
            try remove(r.raw); catch (Exception) {}
            throw new Exception("nothing was recorded (no microphone?)");
        }
        // the file pass: noise reduction, a gentle compressor to even out syllables, loudnorm as the
        // AGC (a fixed -16 LUFS whether recorded loud or faint), a true-peak limiter; then Opus as
        // WhatsApp Web encodes voice notes (which is also what the iPhone accepts) — on a worker thread
        const chain = r.denoise
            ~ "acompressor=threshold=-22dB:ratio=3:attack=5:release=120:makeup=2,"
            ~ "loudnorm=I=-16:TP=-1.5:LRA=11,"
            ~ "alimiter=limit=0.95:level=0";
        import wa.app.client : execOff;
        auto o = execOff(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", r.raw, "-af", chain,
            "-ar", "16000", "-ac", "1", "-c:a", "libopus", "-b:a", "16k", "-application", "voip", "-f", "ogg", "-y", r.path]);
        try remove(r.raw); catch (Exception) {}
        if (o.status != 0) {
            try stderr.writeln("qwhats-dcore: voice encode: ", o.output); catch (Exception) {}
            throw new Exception("could not process the recording");
        }
        if (!exists(r.path) || getSize(r.path) == 0) throw new Exception("the processed recording is empty");
        return JSONValue(["path": JSONValue(r.path), "seconds": JSONValue(secs < 1 ? 1 : secs)]);
    }
}
