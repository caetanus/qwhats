/// The app lock (WhatsApp Web's "Bloqueio do app"), as the Go core keeps it (core/extras.go): a
/// password stored as scrypt(N=2^15, r=8, p=1, 32 bytes) with a random 16-byte salt, in
/// <data>/applock.json {"salt": hex, "hash": hex} — the same file format, so either core reads it.
///   AppLock.status → {enabled}   AppLock.set {password}   AppLock.check {password} → {ok}
///   AppLock.clear {password}
module applock;

import std.json;

final class AppLock {
    private string file;

    this(string dataDir) {
        import std.path : buildPath;
        file = buildPath(dataDir, "applock.json");
    }

    bool enabled() {
        import std.file : exists;
        return exists(file);
    }

    static ubyte[] hash(string password, const(ubyte)[] salt) {
        import libsodium.crypto_pwhash_scryptsalsa208sha256 : crypto_pwhash_scryptsalsa208sha256_ll;
        auto out_ = new ubyte[32];
        if (crypto_pwhash_scryptsalsa208sha256_ll(cast(const(ubyte)*) password.ptr, password.length, salt.ptr, salt.length,
                1UL << 15, 8, 1, out_.ptr, out_.length) != 0)
            throw new Exception("scrypt failed");
        return out_;
    }

    void set(string password) {
        import std.file : write, rename, mkdirRecurse, exists, remove;
        import std.path : dirName;
        import std.digest : toHexString, LetterCase;
        import std.string : toStringz;
        import std.stdio : File;
        import core.sys.posix.fcntl : open, O_CREAT, O_WRONLY, O_TRUNC, O_EXCL;
        import std.conv : octal;
        import wa.crypto : randomBytes;
        import std.utf : count;
        if (password.count < 4) throw new Exception("a senha precisa ter pelo menos 4 caracteres");
        auto salt = randomBytes(16);
        JSONValue j = ["salt": JSONValue(toHexString!(LetterCase.lower)(salt).idup),
            "hash": JSONValue(toHexString!(LetterCase.lower)(hash(password, salt)).idup)];
        mkdirRecurse(file.dirName);
        // 0600 from the start
        const tmp = file ~ ".tmp";
        if (exists(tmp)) remove(tmp);
        const fd = open(tmp.toStringz, O_CREAT | O_EXCL | O_WRONLY | O_TRUNC, octal!600);
        if (fd < 0) throw new Exception("cannot write the app lock");
        File f;
        f.fdopen(fd, "w");
        f.write(j.toString());
        f.close();
        rename(tmp, file);
    }

    /// true when there is no lock, or the password matches (constant-time)
    bool check(string password) {
        import std.file : exists, readText;
        import std.conv : to;
        import std.digest : secureEqual;
        if (!exists(file)) return true;
        try {
            auto j = parseJSON(readText(file));
            auto salt = hexBytes(j["salt"].str), want = hexBytes(j["hash"].str);
            return secureEqual(hash(password, salt), want);
        } catch (Exception) return false;
    }

    void clear(string password) {
        import std.file : remove, exists;
        if (!check(password)) throw new Exception("senha incorreta");
        if (exists(file)) remove(file);
    }

    private static ubyte[] hexBytes(string h) {
        import std.conv : to;
        ubyte[] o;
        for (size_t i = 0; i + 1 < h.length; i += 2) o ~= h[i .. i + 2].to!ubyte(16);
        return o;
    }
}

unittest {
    // the Go core's lockHash (golang.org/x/crypto/scrypt Key, N=2^15 r=8 p=1, 32 bytes) on the same input
    import std.digest : toHexString, LetterCase;
    ubyte[] salt;
    foreach (i; 0 .. 16) salt ~= cast(ubyte) i;
    assert(toHexString!(LetterCase.lower)(AppLock.hash("senha-teste", salt))
        == "c08a116a61a986ef67d69c56db1d890b40a001eb0ac86d6223a93677fd5281a0");
}
