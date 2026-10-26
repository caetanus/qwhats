/// Reads an existing pairing from whatsmeow's device store (the Go core's accounts/<id>/device.db),
/// so the D protocol logs in as the same linked device instead of pairing a new one. Read-only: the
/// file is opened with mode=ro and nothing is written back.
module wa.store.whatsmeow;

import std.string : toStringz, fromStringz;
import wa.crypto : KeyPair;
import wa.device;

private extern (C) nothrow @nogc {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open_v2(const(char)* filename, sqlite3** db, int flags, const(char)* vfs);
    int sqlite3_close(sqlite3*);
    int sqlite3_prepare_v2(sqlite3*, const(char)* sql, int n, sqlite3_stmt** stmt, const(char)** tail);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    const(void)* sqlite3_column_blob(sqlite3_stmt*, int col);
    int sqlite3_column_bytes(sqlite3_stmt*, int col);
    const(char)* sqlite3_column_text(sqlite3_stmt*, int col);
    long sqlite3_column_int64(sqlite3_stmt*, int col);
    const(char)* sqlite3_errmsg(sqlite3*);
}
private enum SQLITE_OPEN_READONLY = 1, SQLITE_OPEN_URI = 0x40, SQLITE_ROW = 100;

class StoreException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// The device whatsmeow paired (the first, as the core keeps one device per account).
Device loadWhatsmeowDevice(string path) {
    sqlite3* db;
    if (sqlite3_open_v2(("file:" ~ path ~ "?mode=ro").toStringz, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, null) != 0) {
        scope (exit) sqlite3_close(db);
        throw new StoreException("cannot open " ~ path ~ ": " ~ sqlite3_errmsg(db).fromStringz.idup);
    }
    scope (exit) sqlite3_close(db);
    sqlite3_stmt* st;
    enum sql = "SELECT jid, coalesce(lid, ''), registration_id, noise_key, identity_key, signed_pre_key, "
        ~ "signed_pre_key_id, signed_pre_key_sig, adv_key, push_name FROM whatsmeow_device LIMIT 1";
    if (sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &st, null) != 0)
        throw new StoreException("not a whatsmeow store: " ~ sqlite3_errmsg(db).fromStringz.idup);
    scope (exit) sqlite3_finalize(st);
    if (sqlite3_step(st) != SQLITE_ROW) throw new StoreException("no paired device in " ~ path);

    string text(int c) { return sqlite3_column_text(st, c).fromStringz.idup; }
    const(ubyte)[] blob(int c, size_t want) {
        auto p = cast(const(ubyte)*) sqlite3_column_blob(st, c);
        const n = sqlite3_column_bytes(st, c);
        if (n != want) throw new StoreException("unexpected key size in the store");
        return p[0 .. n];
    }
    Device d;
    d.jid = text(0);
    d.lid = text(1);
    d.registrationId = cast(uint) sqlite3_column_int64(st, 2);
    // whatsmeow keeps only the private halves; the public ones follow from them
    d.noiseKey = KeyPair.fromPrivate(blob(3, 32)[0 .. 32]);
    d.identityKey = KeyPair.fromPrivate(blob(4, 32)[0 .. 32]);
    d.signedPreKey.key = KeyPair.fromPrivate(blob(5, 32)[0 .. 32]);
    d.signedPreKey.id = cast(uint) sqlite3_column_int64(st, 6);
    d.signedPreKey.signature = blob(7, 64)[0 .. 64];
    d.advSecret = blob(8, 32)[0 .. 32];
    d.pushName = text(9);
    return d;
}
