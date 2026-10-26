/// Our own device/Signal store (SQLite, read-write) — what replaces reading whatsmeow's device.db.
/// Keeps the paired device and the Signal protocol state (identities, sessions, pre-keys, sender keys,
/// app-state keys and versions). One account per file, as WhatsApp Web keeps one linked device.
module wa.store.db;

import std.string : toStringz, fromStringz;
import wa.crypto : KeyPair;
import wa.device;

private extern (C) nothrow @nogc {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open_v2(const(char)* filename, sqlite3** db, int flags, const(char)* vfs);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const(char)* sql, void*, void*, char**);
    int sqlite3_prepare_v2(sqlite3*, const(char)* sql, int n, sqlite3_stmt** stmt, const(char)** tail);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_reset(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    int sqlite3_bind_text(sqlite3_stmt*, int, const(char)*, int, void*);
    int sqlite3_bind_blob(sqlite3_stmt*, int, const(void)*, int, void*);
    int sqlite3_bind_int64(sqlite3_stmt*, int, long);
    const(void)* sqlite3_column_blob(sqlite3_stmt*, int col);
    int sqlite3_column_bytes(sqlite3_stmt*, int col);
    const(char)* sqlite3_column_text(sqlite3_stmt*, int col);
    long sqlite3_column_int64(sqlite3_stmt*, int col);
    const(char)* sqlite3_errmsg(sqlite3*);
}

private enum SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101;
private enum SQLITE_OPEN_READWRITE = 2, SQLITE_OPEN_CREATE = 4, SQLITE_OPEN_URI = 0x40;
private enum SQLITE_TRANSIENT = cast(void*)-1;

class StoreException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

private enum schema = `
CREATE TABLE IF NOT EXISTS device (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    jid TEXT NOT NULL, lid TEXT NOT NULL DEFAULT '', registration_id INTEGER NOT NULL,
    noise_key BLOB NOT NULL, identity_key BLOB NOT NULL,
    signed_pre_key BLOB NOT NULL, signed_pre_key_id INTEGER NOT NULL, signed_pre_key_sig BLOB NOT NULL,
    adv_secret BLOB NOT NULL, push_name TEXT NOT NULL DEFAULT '', account BLOB);
CREATE TABLE IF NOT EXISTS identities (address TEXT PRIMARY KEY, key BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (address TEXT PRIMARY KEY, record BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS prekeys (id INTEGER PRIMARY KEY, priv BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS sender_keys (address TEXT PRIMARY KEY, record BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS app_state_keys (key_id BLOB PRIMARY KEY, key_data BLOB NOT NULL, ts INTEGER NOT NULL, fingerprint BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS app_state_versions (name TEXT PRIMARY KEY, version INTEGER NOT NULL, hash BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS history (msg_id TEXT NOT NULL, chunk INTEGER NOT NULL, sync_type INTEGER NOT NULL,
    data BLOB NOT NULL, PRIMARY KEY(msg_id, chunk));
CREATE TABLE IF NOT EXISTS pending_history (msg_id TEXT PRIMARY KEY, notification BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS app_state_macs (name TEXT NOT NULL, version INTEGER NOT NULL, index_mac BLOB NOT NULL,
    value_mac BLOB NOT NULL, PRIMARY KEY(name, index_mac));
CREATE TABLE IF NOT EXISTS privacy_tokens (user TEXT PRIMARY KEY, token BLOB NOT NULL, ts INTEGER NOT NULL,
    sender_ts INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS lid_map (lid TEXT PRIMARY KEY, pn TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS messages (chat TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
    ts INTEGER NOT NULL, from_me INTEGER NOT NULL, proto BLOB NOT NULL, PRIMARY KEY(chat, id));
`;

/// One account's store. Open/create a file, read or write the device and the Signal state.
final class Store {
    private sqlite3* db;

    this(string path) {
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI;
        if (sqlite3_open_v2(("file:" ~ path).toStringz, &db, flags, null) != SQLITE_OK) {
            auto msg = sqlite3_errmsg(db).fromStringz.idup;
            sqlite3_close(db);
            throw new StoreException("cannot open " ~ path ~ ": " ~ msg);
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;");
        exec(schema);
        // migrations for stores created by earlier builds (the column already exists → ignored)
        try exec("ALTER TABLE device ADD COLUMN account BLOB"); catch (StoreException) {}
        // earlier builds uploaded prekeys 1..N without marking them; they are on the server
        if (meta("prekeys_marked") == 0) {
            exec("UPDATE prekeys SET uploaded = 1");
            setMeta("prekeys_marked", 1);
        }
    }

    ~this() { if (db) sqlite3_close(db); }

    private void exec(string sql) {
        char* err;
        if (sqlite3_exec(db, sql.toStringz, null, null, &err) != SQLITE_OK) {
            auto m = err ? err.fromStringz.idup : "exec failed";
            throw new StoreException(m);
        }
    }

    /// Prepare a statement, hand it to `use` (binds + steps), always finalize.
    private T stmt(T)(string sql, scope T delegate(sqlite3_stmt*) use) {
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &st, null) != SQLITE_OK)
            throw new StoreException("prepare: " ~ sqlite3_errmsg(db).fromStringz.idup);
        scope (exit) sqlite3_finalize(st);
        return use(st);
    }

    private static void bindText(sqlite3_stmt* st, int i, string s) {
        sqlite3_bind_text(st, i, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
    }
    private static void bindBlob(sqlite3_stmt* st, int i, const(ubyte)[] b) {
        sqlite3_bind_blob(st, i, b.ptr, cast(int) b.length, SQLITE_TRANSIENT);
    }
    private static string colText(sqlite3_stmt* st, int c) { return sqlite3_column_text(st, c).fromStringz.idup; }
    private static ubyte[] colBlob(sqlite3_stmt* st, int c) {
        auto p = cast(const(ubyte)*) sqlite3_column_blob(st, c);
        return p[0 .. sqlite3_column_bytes(st, c)].dup;
    }

    // ── the device ──────────────────────────────────────────────────────────────────────────────

    /// Save the paired device (one row; replaces any previous).
    void saveDevice(ref const Device d) {
        stmt!void(`INSERT OR REPLACE INTO device(id, jid, lid, registration_id, noise_key, identity_key,
            signed_pre_key, signed_pre_key_id, signed_pre_key_sig, adv_secret, push_name, account)
            VALUES(1,?,?,?,?,?,?,?,?,?,?,?)`, (st) {
            bindText(st, 1, d.jid);
            bindText(st, 2, d.lid);
            sqlite3_bind_int64(st, 3, d.registrationId);
            bindBlob(st, 4, d.noiseKey.priv[]);
            bindBlob(st, 5, d.identityKey.priv[]);
            bindBlob(st, 6, d.signedPreKey.key.priv[]);
            sqlite3_bind_int64(st, 7, d.signedPreKey.id);
            bindBlob(st, 8, d.signedPreKey.signature[]);
            bindBlob(st, 9, d.advSecret[]);
            bindText(st, 10, d.pushName);
            bindBlob(st, 11, d.account);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("saveDevice: " ~ sqlite3_errmsg(db).fromStringz.idup);
        });
    }

    /// Logged out (whatsmeow Store.Delete): the device and every key, session and app-state row go —
    /// a later pairing starts from nothing.
    void wipe() {
        foreach (t; ["device", "identities", "sessions", "prekeys", "sender_keys", "app_state_keys",
                "app_state_versions", "app_state_macs", "history", "pending_history", "meta", "kv",
                "privacy_tokens", "lid_map", "messages"])
            stmt!void("DELETE FROM " ~ t, (st) {
                if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("wipe: " ~ sqlite3_errmsg(db).fromStringz.idup);
            });
    }

    /// The paired device, or Device.init (not paired) when the store is empty.
    Device loadDevice() {
        return stmt!Device(`SELECT jid, lid, registration_id, noise_key, identity_key, signed_pre_key,
            signed_pre_key_id, signed_pre_key_sig, adv_secret, push_name, account FROM device WHERE id = 1`, (st) {
            Device d;
            if (sqlite3_step(st) != SQLITE_ROW) return d; // empty: unpaired
            d.jid = colText(st, 0);
            d.lid = colText(st, 1);
            d.registrationId = cast(uint) sqlite3_column_int64(st, 2);
            d.noiseKey = KeyPair.fromPrivate(colBlob(st, 3)[0 .. 32]);
            d.identityKey = KeyPair.fromPrivate(colBlob(st, 4)[0 .. 32]);
            d.signedPreKey.key = KeyPair.fromPrivate(colBlob(st, 5)[0 .. 32]);
            d.signedPreKey.id = cast(uint) sqlite3_column_int64(st, 6);
            d.signedPreKey.signature = colBlob(st, 7)[0 .. 64];
            d.advSecret = colBlob(st, 8)[0 .. 32];
            d.pushName = colText(st, 9);
            d.account = colBlob(st, 10);
            return d;
        });
    }

    // ── one-time pre-keys (uploaded to the server, consumed by peers starting a session) ──────────

    /// Store a generated one-time pre-key (its private half); the public half follows from it.
    void putPreKey(uint id, const ref KeyPair kp) {
        stmt!void(`INSERT OR REPLACE INTO prekeys(id, priv, uploaded) VALUES(?,?,0)`, (st) {
            sqlite3_bind_int64(st, 1, id);
            bindBlob(st, 2, kp.priv[]);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putPreKey");
        });
    }

    /// A stored pre-key by id, or false if it was already used/removed.
    bool preKey(uint id, out KeyPair kp) {
        bool found;
        stmt!void(`SELECT priv FROM prekeys WHERE id = ?`, (st) {
            sqlite3_bind_int64(st, 1, id);
            if (sqlite3_step(st) == SQLITE_ROW) { kp = KeyPair.fromPrivate(colBlob(st, 0)[0 .. 32]); found = true; }
        });
        return found;
    }

    /// A pre-key is consumed once a peer uses it to open a session.
    void removePreKey(uint id) {
        stmt!void(`DELETE FROM prekeys WHERE id = ?`, (st) {
            sqlite3_bind_int64(st, 1, id);
            sqlite3_step(st);
        });
    }

    /// How many unused pre-keys are on hand (the server is topped up to ~30 when it runs low).
    int preKeyCount() {
        return stmt!int(`SELECT count(*) FROM prekeys`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }

    // ── small integer settings (counters, flags) ────────────────────────────────────────────────

    long meta(string key, long fallback = 0) {
        return stmt!long(`SELECT value FROM meta WHERE key = ?`, (st) {
            bindText(st, 1, key);
            return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : fallback;
        });
    }
    void setMeta(string key, long value) {
        stmt!void(`INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)`, (st) {
            bindText(st, 1, key);
            sqlite3_bind_int64(st, 2, value);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("setMeta");
        });
    }

    // ── pre-key batches, as whatsmeow's PreKeyStore: ids only ever grow ────────────────────────

    /// The next pre-key id (1-based, monotonic across the store's life; 24-bit on the wire).
    private uint nextPreKeyId() {
        long next = meta("next_prekey_id", 0);
        if (next == 0) {
            next = stmt!long(`SELECT COALESCE(MAX(id), 0) FROM prekeys`, (st) {
                return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : 0;
            }) + 1;
        }
        // ids go on the wire as 3 bytes, and libsignal treats 0xFFFFFF as "no pre-key"
        if (next >= 0xFFFFFF) throw new StoreException("pre-key ids exhausted (24-bit)");
        setMeta("next_prekey_id", next + 1);
        return cast(uint) next;
    }

    /// `count` pre-keys for an upload: those generated but not yet uploaded, topped up with new
    /// ones (GetOrGenPreKeys).
    import wa.prekey : PreKey;
    PreKey[] getOrGenPreKeys(uint count) {
        PreKey[] keys;
        stmt!void(`SELECT id, priv FROM prekeys WHERE uploaded = 0 ORDER BY id LIMIT ?`, (st) {
            sqlite3_bind_int64(st, 1, count);
            while (sqlite3_step(st) == SQLITE_ROW)
                keys ~= PreKey(cast(uint) sqlite3_column_int64(st, 0), KeyPair.fromPrivate(colBlob(st, 1)[0 .. 32]));
        });
        if (keys.length < count) {
            exec("BEGIN");
            scope (failure) exec("ROLLBACK");
            while (keys.length < count) {
                auto k = PreKey(nextPreKeyId(), KeyPair.generate());
                putPreKey(k.id, k.key);
                keys ~= k;
            }
            exec("COMMIT");
        }
        return keys;
    }

    /// After a successful upload: everything up to `lastId` is on the server (MarkPreKeysAsUploaded).
    void markPreKeysUploaded(uint lastId) {
        stmt!void(`UPDATE prekeys SET uploaded = 1 WHERE id <= ?`, (st) {
            sqlite3_bind_int64(st, 1, lastId);
            sqlite3_step(st);
        });
    }

    int uploadedPreKeyCount() {
        return stmt!int(`SELECT count(*) FROM prekeys WHERE uploaded = 1`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }

    /// One fresh pre-key handed out directly (in a retry receipt), counted as uploaded (GenOnePreKey).
    PreKey genOnePreKey() {
        auto k = PreKey(nextPreKeyId(), KeyPair.generate());
        putPreKey(k.id, k.key);
        stmt!void(`UPDATE prekeys SET uploaded = 1 WHERE id = ?`, (st) {   // only this one
            sqlite3_bind_int64(st, 1, k.id);
            sqlite3_step(st);
        });
        return k;
    }

    // ── app-state (syncd): per collection the version + LTHash, and each live record's value MAC ──

    /// The stored version and 128-byte LTHash of a collection (0 / zeros when never synced).
    ulong appStateVersion(string name, ref ubyte[128] hash) {
        ulong v;
        ubyte[128] h;
        stmt!void(`SELECT version, hash FROM app_state_versions WHERE name = ?`, (st) {
            bindText(st, 1, name);
            if (sqlite3_step(st) == SQLITE_ROW) {
                v = cast(ulong) sqlite3_column_int64(st, 0);
                auto b = colBlob(st, 1);
                if (b.length == 128) h = b[0 .. 128];
            }
        });
        hash = h;
        return v;
    }
    void putAppStateVersion(string name, ulong ver, const ubyte[128] hash) {
        stmt!void(`INSERT OR REPLACE INTO app_state_versions(name, version, hash) VALUES(?,?,?)`, (st) {
            bindText(st, 1, name);
            sqlite3_bind_int64(st, 2, cast(long) ver);
            bindBlob(st, 3, hash[]);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putAppStateVersion");
        });
    }
    /// A full resync starts from nothing: drop the collection's version and MACs.
    void deleteAppStateVersion(string name) {
        foreach (table; ["app_state_versions", "app_state_macs"])
            stmt!void("DELETE FROM " ~ table ~ " WHERE name = ?", (st) {
                bindText(st, 1, name);
                if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("deleteAppStateVersion");
            });
    }
    void putAppStateMACs(string name, ulong ver, const(ubyte)[][2][] macs) {
        foreach (m; macs)
            stmt!void(`INSERT OR REPLACE INTO app_state_macs(name, version, index_mac, value_mac) VALUES(?,?,?,?)`, (st) {
                bindText(st, 1, name);
                sqlite3_bind_int64(st, 2, cast(long) ver);
                bindBlob(st, 3, m[0]);
                bindBlob(st, 4, m[1]);
                if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putAppStateMACs");
            });
    }
    void deleteAppStateMACs(string name, const(ubyte)[][] indexMacs) {
        foreach (im; indexMacs)
            stmt!void(`DELETE FROM app_state_macs WHERE name = ? AND index_mac = ?`, (st) {
                bindText(st, 1, name);
                bindBlob(st, 2, im);
                if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("deleteAppStateMACs");
            });
    }

    /// Run `dg` in one transaction (rolled back if it throws).
    void transaction(scope void delegate() dg) {
        exec("BEGIN");
        scope (failure) exec("ROLLBACK");
        dg();
        exec("COMMIT");
    }
    /// The value MAC of the record currently SET at an index (null when none).
    ubyte[] appStateMAC(string name, const(ubyte)[] indexMac) {
        return stmt!(ubyte[])(`SELECT value_mac FROM app_state_macs WHERE name = ? AND index_mac = ?`, (st) {
            bindText(st, 1, name);
            bindBlob(st, 2, indexMac);
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }

    // ── small blobs (NCT salt, …) ──────────────────────────────────────────────────────────

    void putBlob(string key, const(ubyte)[] value) {
        stmt!void(`INSERT OR REPLACE INTO kv(key, value) VALUES(?,?)`, (st) {
            bindText(st, 1, key);
            bindBlob(st, 2, value);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putBlob");
        });
    }
    void deleteBlob(string key) {
        stmt!void(`DELETE FROM kv WHERE key = ?`, (st) {
            bindText(st, 1, key);
            sqlite3_step(st);
        });
    }
    ubyte[] blob(string key) {
        return stmt!(ubyte[])(`SELECT value FROM kv WHERE key = ?`, (st) {
            bindText(st, 1, key);
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }

    // ── privacy tokens (tctoken: given to us by a contact; sender_ts: when we last issued ours) ──

    void putPrivacyToken(string user, const(ubyte)[] token, long ts) {
        stmt!void(`INSERT INTO privacy_tokens(user, token, ts) VALUES(?,?,?)
            ON CONFLICT(user) DO UPDATE SET token = excluded.token, ts = excluded.ts
            WHERE excluded.ts >= privacy_tokens.ts`, (st) {
            bindText(st, 1, user);
            bindBlob(st, 2, token);
            sqlite3_bind_int64(st, 3, ts);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putPrivacyToken");
        });
    }
    /// The stored token for a user (null when none) with its timestamp and our sender timestamp.
    ubyte[] privacyToken(string user, out long ts, out long senderTs) {
        long t, s;
        auto tok = stmt!(ubyte[])(`SELECT token, ts, sender_ts FROM privacy_tokens WHERE user = ?`, (st) {
            bindText(st, 1, user);
            if (sqlite3_step(st) != SQLITE_ROW) return cast(ubyte[]) null;
            t = sqlite3_column_int64(st, 1);
            s = sqlite3_column_int64(st, 2);
            return colBlob(st, 0);
        });
        ts = t;
        senderTs = s;
        return tok;
    }
    void setPrivacySenderTS(string user, long senderTs) {
        stmt!void(`UPDATE privacy_tokens SET sender_ts = ? WHERE user = ?`, (st) {
            sqlite3_bind_int64(st, 1, senderTs);
            bindText(st, 2, user);
            sqlite3_step(st);
        });
        setMeta("tc_sender_ts:" ~ user, senderTs);   // also kept when we hold no token from them
    }
    long privacySenderTS(string user) { return meta("tc_sender_ts:" ~ user); }
    void deleteExpiredPrivacyTokens(long cutoff) {
        stmt!void(`DELETE FROM privacy_tokens WHERE ts < ?`, (st) {
            sqlite3_bind_int64(st, 1, cutoff);
            sqlite3_step(st);
        });
    }

    // ── LID ↔ phone-number users (whatsmeow LIDStore; user parts, no device) ─────────────────

    void putLIDMapping(string lidUser, string pnUser) {
        if (lidUser.length == 0 || pnUser.length == 0) return;
        stmt!void(`DELETE FROM lid_map WHERE pn = ? AND lid <> ?`, (st) {
            bindText(st, 1, pnUser);
            bindText(st, 2, lidUser);
            sqlite3_step(st);
        });
        stmt!void(`INSERT OR REPLACE INTO lid_map(lid, pn) VALUES(?,?)`, (st) {
            bindText(st, 1, lidUser);
            bindText(st, 2, pnUser);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putLIDMapping");
        });
    }
    string lidForPN(string pnUser) {
        return stmt!string(`SELECT lid FROM lid_map WHERE pn = ?`, (st) {
            bindText(st, 1, pnUser);
            return sqlite3_step(st) == SQLITE_ROW ? colText(st, 0) : null;
        });
    }
    string pnForLID(string lidUser) {
        return stmt!string(`SELECT pn FROM lid_map WHERE lid = ?`, (st) {
            bindText(st, 1, lidUser);
            return sqlite3_step(st) == SQLITE_ROW ? colText(st, 0) : null;
        });
    }
    int lidMappingCount() {
        return stmt!int(`SELECT count(*) FROM lid_map`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }

    private bool[string] migratedPN;   // MigratePNToLID runs once per user per process

    /// Move a user's Signal state from its phone-number addresses to its LID ones (sessions,
    /// identities, sender keys), overwriting what the LID side has, as whatsmeow's MigratePNToLID.
    void migratePNToLID(string pnUser, string lidUser) {
        if (pnUser in migratedPN) return;
        migratedPN[pnUser] = true;
        exec("BEGIN");
        scope (failure) exec("ROLLBACK");
        foreach (table; ["sessions", "identities"]) {
            const col = table == "sessions" ? "record" : "key";
            stmt!void("INSERT OR REPLACE INTO " ~ table ~ "(address, " ~ col ~ ") SELECT ? || substr(address, length(?) + 1), "
                ~ col ~ " FROM " ~ table ~ " WHERE address LIKE ? || ':%'", (st) {
                bindText(st, 1, lidUser);
                bindText(st, 2, pnUser);
                bindText(st, 3, pnUser);
                sqlite3_step(st);
            });
            stmt!void("DELETE FROM " ~ table ~ " WHERE address LIKE ? || ':%'", (st) {
                bindText(st, 1, pnUser);
                sqlite3_step(st);
            });
        }
        // sender keys are keyed "group::user:device"
        stmt!void(`INSERT OR REPLACE INTO sender_keys(address, record) SELECT replace(address, '::' || ? || ':', '::' || ? || ':'), record FROM sender_keys WHERE address LIKE '%::' || ? || ':%'`, (st) {
            bindText(st, 1, pnUser);
            bindText(st, 2, lidUser);
            bindText(st, 3, pnUser);
            sqlite3_step(st);
        });
        stmt!void(`DELETE FROM sender_keys WHERE address LIKE '%::' || ? || ':%'`, (st) {
            bindText(st, 1, pnUser);
            sqlite3_step(st);
        });
        exec("COMMIT");
    }

    /// An identity change: forget every session and identity of that user ("user:N" addresses).
    void deleteAllSessionsOf(string user) {
        foreach (table; ["sessions", "identities"])
            stmt!void("DELETE FROM " ~ table ~ " WHERE address LIKE ? || ':%'", (st) {
                bindText(st, 1, user);
                sqlite3_step(st);
            });
    }

    // ── Signal state (identities / sessions / sender keys) — raw records keyed by address ─────────

    void putIdentity(string address, const(ubyte)[] key) { put("identities", "key", address, key); }
    ubyte[] identity(string address) { return get("identities", "key", address); }
    void putSession(string address, const(ubyte)[] record) { put("sessions", "record", address, record); }
    ubyte[] session(string address) { return get("sessions", "record", address); }
    bool hasSession(string address) { return get("sessions", "record", address) !is null; }
    void putSenderKey(string address, const(ubyte)[] record) { put("sender_keys", "record", address, record); }
    ubyte[] senderKey(string address) { return get("sender_keys", "record", address); }

    // ── app-state sync keys (shared by the phone at link time; decrypt contacts/pins/mutes…) ──────

    void putAppStateKey(const(ubyte)[] keyId, const(ubyte)[] keyData, long ts, const(ubyte)[] fingerprint) {
        stmt!void(`INSERT OR REPLACE INTO app_state_keys(key_id, key_data, ts, fingerprint) VALUES(?,?,?,?)`, (st) {
            bindBlob(st, 1, keyId);
            bindBlob(st, 2, keyData);
            sqlite3_bind_int64(st, 3, ts);
            bindBlob(st, 4, fingerprint);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putAppStateKey");
        });
    }
    ubyte[] appStateKey(const(ubyte)[] keyId) {
        return stmt!(ubyte[])(`SELECT key_data FROM app_state_keys WHERE key_id = ?`, (st) {
            bindBlob(st, 1, keyId);
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }
    /// GetLatestAppStateSyncKeyID: the newest key (by its timestamp) — what our own patches use.
    ubyte[] latestAppStateKeyId() {
        return stmt!(ubyte[])(`SELECT key_id FROM app_state_keys ORDER BY ts DESC LIMIT 1`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }
    int appStateKeyCount() {
        return stmt!int(`SELECT count(*) FROM app_state_keys`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }

    // ── history sync (decompressed HistorySync protobufs, and notifications still to download) ──

    void putHistory(string msgId, uint chunk, uint syncType, const(ubyte)[] data) {
        stmt!void(`INSERT OR REPLACE INTO history(msg_id, chunk, sync_type, data) VALUES(?,?,?,?)`, (st) {
            bindText(st, 1, msgId);
            sqlite3_bind_int64(st, 2, chunk);
            sqlite3_bind_int64(st, 3, syncType);
            bindBlob(st, 4, data);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putHistory");
        });
    }
    int historyCount() {
        return stmt!int(`SELECT count(*) FROM history`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }
    /// Every stored HistorySync payload (decompressed), for a backfill pass.
    ubyte[][] historyPayloads() {
        ubyte[][] all;
        stmt!void(`SELECT data FROM history`, (st) {
            while (sqlite3_step(st) == SQLITE_ROW) all ~= colBlob(st, 0);
        });
        return all;
    }

    void putPendingHistory(string msgId, const(ubyte)[] notification) {
        stmt!void(`INSERT OR REPLACE INTO pending_history(msg_id, notification) VALUES(?,?)`, (st) {
            bindText(st, 1, msgId);
            bindBlob(st, 2, notification);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putPendingHistory");
        });
    }
    void removePendingHistory(string msgId) {
        stmt!void(`DELETE FROM pending_history WHERE msg_id = ?`, (st) {
            bindText(st, 1, msgId);
            sqlite3_step(st);
        });
    }
    /// (msg_id, notification) pairs still waiting for a download.
    string[] pendingHistoryIds() {
        string[] ids;
        stmt!void(`SELECT msg_id FROM pending_history`, (st) {
            while (sqlite3_step(st) == SQLITE_ROW) ids ~= colText(st, 0);
        });
        return ids;
    }
    ubyte[] pendingHistory(string msgId) {
        return stmt!(ubyte[])(`SELECT notification FROM pending_history WHERE msg_id = ?`, (st) {
            bindText(st, 1, msgId);
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }

    // ── decrypted messages (the Message protobuf, keyed by chat + message id) ───────────────────

    void putMessage(string chat, string id, string sender, long ts, bool fromMe, const(ubyte)[] proto) {
        stmt!void(`INSERT OR REPLACE INTO messages(chat, id, sender, ts, from_me, proto) VALUES(?,?,?,?,?,?)`, (st) {
            bindText(st, 1, chat);
            bindText(st, 2, id);
            bindText(st, 3, sender);
            sqlite3_bind_int64(st, 4, ts);
            sqlite3_bind_int64(st, 5, fromMe ? 1 : 0);
            bindBlob(st, 6, proto);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("putMessage");
        });
    }
    /// A stored message by id: its Message protobuf, chat and sender address (null if unknown).
    ubyte[] messageById(string id, out string chat, out string sender) {
        bool fm;
        return messageById(id, chat, sender, fm);
    }
    /// The same, telling whether we sent it (several rows may share an id: ours wins).
    ubyte[] messageById(string id, out string chat, out string sender, out bool fromMe) {
        string c, s;
        bool f;
        auto p = stmt!(ubyte[])(`SELECT proto, chat, sender, from_me FROM messages WHERE id = ? ORDER BY from_me DESC LIMIT 1`, (st) {
            bindText(st, 1, id);
            if (sqlite3_step(st) != SQLITE_ROW) return cast(ubyte[]) null;
            c = colText(st, 1);
            s = colText(st, 2);
            f = sqlite3_column_int64(st, 3) != 0;
            return colBlob(st, 0);
        });
        chat = c;
        sender = s;
        fromMe = f;
        return p;
    }
    int messageCount() {
        return stmt!int(`SELECT count(*) FROM messages`, (st) {
            return sqlite3_step(st) == SQLITE_ROW ? cast(int) sqlite3_column_int64(st, 0) : 0;
        });
    }

    private void put(string table, string col, string address, const(ubyte)[] data) {
        stmt!void("INSERT OR REPLACE INTO " ~ table ~ "(address, " ~ col ~ ") VALUES(?,?)", (st) {
            bindText(st, 1, address);
            bindBlob(st, 2, data);
            if (sqlite3_step(st) != SQLITE_DONE) throw new StoreException("put " ~ table);
        });
    }
    private ubyte[] get(string table, string col, string address) {
        return stmt!(ubyte[])("SELECT " ~ col ~ " FROM " ~ table ~ " WHERE address = ?", (st) {
            bindText(st, 1, address);
            return sqlite3_step(st) == SQLITE_ROW ? colBlob(st, 0) : null;
        });
    }
}

unittest {
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-store-test-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) { foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s); }

    auto dev = Device.create();
    dev.jid = "5511999999999:3@s.whatsapp.net";
    dev.lid = "123456:3@lid";
    dev.pushName = "Tester";
    {
        auto st = new Store(path);
        st.saveDevice(dev);
        // a one-time pre-key round-trips
        auto pk = KeyPair.generate();
        st.putPreKey(7, pk);
        assert(st.preKeyCount() == 1);
        KeyPair got;
        assert(st.preKey(7, got) && got.priv == pk.priv);
        // identity/session blobs
        st.putSession("addr.1", cast(ubyte[])[1, 2, 3]);
        assert(st.hasSession("addr.1") && st.session("addr.1") == cast(ubyte[])[1, 2, 3]);
        assert(!st.hasSession("addr.2"));
    }
    {
        auto st = new Store(path);     // reopen: the device persisted
        auto d2 = st.loadDevice();
        assert(d2.paired);
        assert(d2.jid == dev.jid && d2.lid == dev.lid && d2.pushName == "Tester");
        assert(d2.registrationId == dev.registrationId);
        assert(d2.noiseKey.priv == dev.noiseKey.priv && d2.noiseKey.pub == dev.noiseKey.pub);
        assert(d2.identityKey.priv == dev.identityKey.priv);
        assert(d2.signedPreKey.id == dev.signedPreKey.id);
        assert(d2.signedPreKey.signature == dev.signedPreKey.signature);
        assert(d2.advSecret == dev.advSecret);
        assert(st.preKeyCount() == 1); // the pre-key persisted too
    }
}

unittest {
    // pre-key batches: unuploaded keys are reused, new ids only grow, uploads are tracked
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-store-pk-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) { foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s); }
    auto st = new Store(path);
    auto a = st.getOrGenPreKeys(3);
    assert(a.length == 3 && a[0].id == 1 && a[2].id == 3);
    auto again = st.getOrGenPreKeys(3);              // not uploaded yet → the same keys
    assert(again[0].id == 1 && again[0].key.priv == a[0].key.priv);
    st.markPreKeysUploaded(a[$ - 1].id);
    assert(st.uploadedPreKeyCount() == 3);
    auto b = st.getOrGenPreKeys(2);
    assert(b[0].id == 4 && b[1].id == 5);
    st.removePreKey(5);
    auto one = st.genOnePreKey();
    assert(one.id == 6 && st.uploadedPreKeyCount() == 4);  // 1..3 + 6
    st.putSession("123:0", [1]);
    st.putSession("123:7", [2]);
    st.putSession("1234:0", [3]);
    st.deleteAllSessionsOf("123");
    assert(!st.hasSession("123:0") && !st.hasSession("123:7") && st.hasSession("1234:0"));
}

unittest {
    // LID mappings and the PN → LID migration of Signal state
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-store-lid-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) { foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s); }
    auto st = new Store(path);
    st.putLIDMapping("136000", "5511999");
    assert(st.lidForPN("5511999") == "136000" && st.pnForLID("136000") == "5511999");
    st.putLIDMapping("137000", "5511999");             // the number moved to a new LID
    assert(st.lidForPN("5511999") == "137000" && st.pnForLID("136000") is null);

    st.putSession("5511999:0", [1]);
    st.putSession("5511999:3", [2]);
    st.putSession("137000:0", [9]);                    // overwritten by the PN one
    st.putSession("55119990:0", [7]);                  // another user with the same prefix
    st.putSenderKey("g1@g.us::5511999:3", [5]);
    st.migratePNToLID("5511999", "137000");
    assert(st.session("137000:0") == [1] && st.session("137000:3") == [2]);
    assert(!st.hasSession("5511999:0") && st.hasSession("55119990:0"));
    assert(st.senderKey("g1@g.us::137000:3") == [5] && st.senderKey("g1@g.us::5511999:3") is null);
}
