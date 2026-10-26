/// A small SQLite wrapper for the app-level stores: open a file, run statements with bound
/// arguments, iterate rows. (wa.store.db keeps its own narrow statements for the Signal state.)
module wa.store.sql;

import std.string : toStringz, fromStringz;

private extern (C) nothrow @nogc {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open_v2(const(char)* filename, sqlite3** db, int flags, const(char)* vfs);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const(char)* sql, void*, void*, char**);
    int sqlite3_prepare_v2(sqlite3*, const(char)* sql, int n, sqlite3_stmt** stmt, const(char)** tail);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    int sqlite3_bind_text(sqlite3_stmt*, int, const(char)*, int, void*);
    int sqlite3_bind_blob(sqlite3_stmt*, int, const(void)*, int, void*);
    int sqlite3_bind_int64(sqlite3_stmt*, int, long);
    int sqlite3_bind_double(sqlite3_stmt*, int, double);
    int sqlite3_bind_null(sqlite3_stmt*, int);
    const(void)* sqlite3_column_blob(sqlite3_stmt*, int col);
    int sqlite3_column_bytes(sqlite3_stmt*, int col);
    const(char)* sqlite3_column_text(sqlite3_stmt*, int col);
    long sqlite3_column_int64(sqlite3_stmt*, int col);
    int sqlite3_column_type(sqlite3_stmt*, int col);
    int sqlite3_changes(sqlite3*);
    const(char)* sqlite3_errmsg(sqlite3*);
    void sqlite3_free(void*);
}

private enum SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101, SQLITE_NULL = 5;
private enum SQLITE_OPEN_READWRITE = 2, SQLITE_OPEN_CREATE = 4, SQLITE_OPEN_URI = 0x40;
private enum SQLITE_TRANSIENT = cast(void*)-1;

class SqlException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// One result row (valid inside the iteration that produced it).
struct Row {
    private sqlite3_stmt* st;
    string text(int col) {
        auto p = sqlite3_column_text(st, col);
        return p is null ? "" : p.fromStringz.idup;
    }
    long int64(int col) { return sqlite3_column_int64(st, col); }
    ubyte[] blob(int col) {
        const n = sqlite3_column_bytes(st, col);
        auto p = cast(const(ubyte)*) sqlite3_column_blob(st, col);
        return p is null || n == 0 ? null : p[0 .. n].dup;
    }
    bool isNull(int col) { return sqlite3_column_type(st, col) == SQLITE_NULL; }
}

/// A prepared, bound query; iterate it once with foreach (it finalizes itself).
struct Rows {
    private sqlite3_stmt* st;
    private sqlite3* db;
    @disable this(this);
    ~this() { if (st) sqlite3_finalize(st); }
    int opApply(scope int delegate(ref Row) dg) {
        scope (exit) { sqlite3_finalize(st); st = null; }
        for (;;) {
            const rc = sqlite3_step(st);
            if (rc == SQLITE_DONE) return 0;
            if (rc != SQLITE_ROW) throw new SqlException("step: " ~ sqlite3_errmsg(db).fromStringz.idup);
            auto r = Row(st);
            if (auto res = dg(r)) return res;
        }
    }
}

final class Db {
    private sqlite3* db;

    this(string path) {
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI;
        if (sqlite3_open_v2(("file:" ~ path).toStringz, &db, flags, null) != SQLITE_OK) {
            auto msg = sqlite3_errmsg(db).fromStringz.idup;
            sqlite3_close(db);
            throw new SqlException("cannot open " ~ path ~ ": " ~ msg);
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;");
    }
    ~this() { if (db) sqlite3_close(db); }

    /// Run one or more statements without arguments.
    void exec(string sql) {
        char* err;
        if (sqlite3_exec(db, sql.toStringz, null, null, &err) != SQLITE_OK) {
            auto m = err ? err.fromStringz.idup : "exec failed";
            if (err) sqlite3_free(err);
            throw new SqlException(m);
        }
    }

    private sqlite3_stmt* prepare(Args...)(string sql, Args args) {
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(db, sql.toStringz, -1, &st, null) != SQLITE_OK)
            throw new SqlException("prepare: " ~ sqlite3_errmsg(db).fromStringz.idup ~ " — " ~ sql);
        foreach (i, a; args) {
            const idx = cast(int) i + 1;
            alias T = typeof(a);
            static if (is(T == typeof(null))) sqlite3_bind_null(st, idx);
            else static if (is(T : const(char)[])) {
                if (a is null) sqlite3_bind_text(st, idx, "".ptr, 0, SQLITE_TRANSIENT);
                else sqlite3_bind_text(st, idx, a.ptr, cast(int) a.length, SQLITE_TRANSIENT);
            } else static if (is(T : const(ubyte)[])) {
                if (a is null) sqlite3_bind_null(st, idx);
                else sqlite3_bind_blob(st, idx, a.ptr, cast(int) a.length, SQLITE_TRANSIENT);
            } else static if (is(T == bool)) sqlite3_bind_int64(st, idx, a ? 1 : 0);
            else static if (is(T : double) && !is(T : long)) sqlite3_bind_double(st, idx, a);
            else static if (is(T : long) || is(T == ulong)) sqlite3_bind_int64(st, idx, cast(long) a);
            else static assert(0, "cannot bind " ~ T.stringof);
        }
        return st;
    }

    /// Run a statement that returns no rows; the number of changed rows.
    int run(Args...)(string sql, Args args) {
        auto st = prepare(sql, args);
        scope (exit) sqlite3_finalize(st);
        const rc = sqlite3_step(st);
        if (rc != SQLITE_DONE && rc != SQLITE_ROW)
            throw new SqlException("step: " ~ sqlite3_errmsg(db).fromStringz.idup ~ " — " ~ sql);
        return sqlite3_changes(db);
    }

    /// A query to iterate: `foreach (ref r; db.query("SELECT …", x)) r.text(0)`.
    Rows query(Args...)(string sql, Args args) { return Rows(prepare(sql, args), db); }

    /// The first row's first column as text ("" when no row).
    string scalarText(Args...)(string sql, Args args) {
        string v;
        foreach (ref r; query(sql, args)) { v = r.text(0); break; }
        return v;
    }
    long scalarInt(Args...)(string sql, Args args) {
        long v;
        foreach (ref r; query(sql, args)) { v = r.int64(0); break; }
        return v;
    }

    /// Run `dg` inside a transaction (rolled back if it throws).
    void transaction(scope void delegate() dg) {
        exec("BEGIN");
        scope (failure) exec("ROLLBACK");
        dg();
        exec("COMMIT");
    }
}

unittest {
    import std.file : tempDir, remove, exists;
    import std.conv : to;
    import std.process : thisProcessID;
    const path = tempDir ~ "/wa-sql-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto db = new Db(path);
    db.exec("CREATE TABLE t (a TEXT, b INTEGER, c BLOB)");
    db.transaction({
        db.run("INSERT INTO t VALUES(?,?,?)", "x", 7, cast(const(ubyte)[]) [1, 2]);
        db.run("INSERT INTO t VALUES(?,?,?)", "y", true, null);
    });
    string[] got;
    foreach (ref r; db.query("SELECT a, b, c FROM t WHERE b >= ? ORDER BY a", 1))
        got ~= r.text(0) ~ ":" ~ r.int64(1).to!string ~ ":" ~ r.blob(2).length.to!string;
    assert(got == ["x:7:2", "y:1:0"]);
    assert(db.scalarInt("SELECT count(*) FROM t") == 2 && db.scalarText("SELECT a FROM t WHERE b = ?", 7) == "x");
    assert(db.run("UPDATE t SET b = b + 1") == 2);
    // FTS5 and JSON1, which the chat store needs, are available
    db.exec("CREATE VIRTUAL TABLE f USING fts5(body)");
    db.run("INSERT INTO f(body) VALUES(?)", "ola mundo");
    assert(db.scalarInt("SELECT count(*) FROM f WHERE f MATCH ?", "mundo") == 1);
    assert(db.scalarText("SELECT json_extract('{\"k\":\"v\"}', '$.k')") == "v");
}
