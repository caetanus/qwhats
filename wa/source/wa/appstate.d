/// App-state sync ("syncd"): the encrypted, versioned key-value collections where WhatsApp keeps a
/// chat's pin/mute/archive/read state, contacts' names, stars, settings… Every linked device fetches
/// them (`<iq xmlns=w:sync:app:state>`), decrypts each mutation with the app-state sync keys the
/// phone shared, and checks integrity end to end: a MAC per value, a MAC per index, an LTHash over
/// all live values (the snapshot MAC) and a MAC per patch. Our implementation of whatsmeow's appstate
/// package (keys.go, hash.go, lthash, decode.go) — the MACs make any mistake fail loudly.
module wa.appstate;

import std.json;
import std.conv : to;
import wa.binary.node;
import wa.crypto : aesCbcDecrypt, hkdf, hmacSha256, hmacSha512;
import wa.proto : ProtoReader, ProtoWriter;
import wa.store.db : Store;
import ss = wa.pb.serversync;
import sa = wa.pb.syncaction;

/// The collections, in the order whatsmeow syncs them.
immutable string[] allPatchNames = ["critical_block", "critical_unblock_low", "regular_high", "regular", "regular_low"];

class AppStateException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// A mutation names a key the phone has not shared with us yet: ask for it (APP_STATE_SYNC_KEY_REQUEST).
class AppStateKeyMissing : AppStateException {
    ubyte[][] keyIds;
    this(ubyte[][] ids) { super("app-state key not found"); keyIds = ids; }
}

// ── keys and integrity ───────────────────────────────────────────────────────────────────────

struct ExpandedKeys {
    ubyte[32] index, valueEncryption, valueMAC, snapshotMAC, patchMAC;
}

/// expandAppStateKeys: HKDF(keyData, ∅, "WhatsApp Mutation Keys", 160) split in five.
ExpandedKeys expandAppStateKeys(const(ubyte)[] keyData) {
    auto x = hkdf(keyData, null, cast(const(ubyte)[]) "WhatsApp Mutation Keys", 160);
    ExpandedKeys k;
    k.index = x[0 .. 32];
    k.valueEncryption = x[32 .. 64];
    k.valueMAC = x[64 .. 96];
    k.snapshotMAC = x[96 .. 128];
    k.patchMAC = x[128 .. 160];
    return k;
}

/// WAPatchIntegrity LTHash: subtract then add HKDF(item, ∅, "WhatsApp Patch Integrity", 128) as
/// little-endian uint16 lanes, wrapping.
void ltHashSubtractThenAdd(ref ubyte[128] base, const(ubyte)[][] subtract, const(ubyte)[][] add) {
    void op(const(ubyte)[] item, bool sub) {
        auto x = hkdf(item, null, cast(const(ubyte)[]) "WhatsApp Patch Integrity", 128);
        for (size_t i = 0; i < 128; i += 2) {
            const a = cast(ushort)(base[i] | (base[i + 1] << 8));
            const b = cast(ushort)(x[i] | (x[i + 1] << 8));
            const r = cast(ushort)(sub ? a - b : a + b);
            base[i] = cast(ubyte) r;
            base[i + 1] = cast(ubyte)(r >> 8);
        }
    }
    foreach (s; subtract) op(s, true);
    foreach (a; add) op(a, false);
}

private ubyte[8] u64be(ulong v) {
    ubyte[8] b;
    foreach (i; 0 .. 8) b[7 - i] = cast(ubyte)(v >> (8 * i));
    return b;
}

struct HashState {
    ulong ver;
    ubyte[128] hash;
}

/// HMAC-SHA256(snapshotMACKey, hash ‖ version(8, BE) ‖ name).
ubyte[32] snapshotMAC(const ref HashState st, string name, const ubyte[32] key) {
    const v = u64be(st.ver);
    return hmacSha256(key[], st.hash[], v[], cast(const(ubyte)[]) name);
}

/// HMAC-SHA256(patchMACKey, snapshotMAC ‖ each mutation's value MAC ‖ version(8, BE) ‖ name).
ubyte[32] patchMAC(const(ubyte)[] snapMAC, const(ubyte)[][] valueMACs, ulong ver, string name, const ubyte[32] key) {
    const(ubyte)[][] parts = [snapMAC];
    parts ~= valueMACs;
    const v = u64be(ver);
    parts ~= v[].dup;
    parts ~= cast(const(ubyte)[]) name;
    return hmacSha256(key[], parts);
}

/// HMAC-SHA512(valueMACKey, [op + 1] ‖ keyID ‖ data ‖ (len(keyID)+1)(8, BE))[0 .. 32].
ubyte[32] contentMAC(int operation, const(ubyte)[] data, const(ubyte)[] keyId, const ubyte[32] key) {
    const ubyte[1] op = [cast(ubyte)(operation + 1)];
    const l = u64be(keyId.length + 1);
    ubyte[32] r = hmacSha512(key[], op[], keyId, data, l[])[0 .. 32];
    return r;
}

// ── fetching ─────────────────────────────────────────────────────────────────────────────────

/// fetchAppStatePatches: `<iq xmlns=w:sync:app:state type=set><sync><collection name
/// return_snapshot [version]/></sync></iq>` (version only when not asking for a snapshot).
Node syncIQ(string name, ulong fromVersion, bool snapshot, string iqId) {
    auto c = Node("collection");
    c.attrs ~= Attr("name", Value(name));
    c.attrs ~= Attr("return_snapshot", Value(snapshot ? "true" : "false"));
    if (!snapshot) c.attrs ~= Attr("version", Value(fromVersion.to!string));
    auto sync = Node("sync");
    sync.children ~= c;
    auto iq = node("iq", [["id", iqId], ["xmlns", "w:sync:app:state"], ["type", "set"], ["to", "s.whatsapp.net"]]);
    iq.attr("to").jid = Jid.pair(null, "s.whatsapp.net");
    iq.attr("to").isJid = true;
    iq.children ~= sync;
    return iq;
}

/// One patch, with its mutations resolved (inline or downloaded).
struct Patch {
    ulong ver;
    const(ubyte)[][] mutations;   // SyncdMutation
    const(ubyte)[] snapshotMACv, patchMACv, keyId;
}

struct PatchList {
    string name;
    bool hasMore;
    Patch[] patches;
    const(ubyte)[] snapshot;      // SyncdSnapshot (downloaded), null when none
}

/// ParsePatchList: the <collection> of a sync result. `download(ExternalBlobReference)` fetches
/// and decrypts an external blob (snapshots, and large mutation lists).
PatchList parsePatchList(const ref Node collection, ubyte[] delegate(const(ubyte)[] blobRef) download) {
    PatchList l;
    l.name = collection.get("name");
    l.hasMore = collection.get("has_more_patches") == "true";
    if (const sn = collection.child("snapshot")) if (sn.hasBytes) l.snapshot = download(sn.bytes);
    if (const ps = collection.child("patches"))
        foreach (ref pn; ps.children) {
            if (pn.tag != "patch" || !pn.hasBytes) continue;
            auto p = ProtoReader(pn.bytes);
            Patch patch;
            patch.ver = ProtoReader(p.get(ss.SyncdPatch.version_).bytes).get(ss.SyncdVersion.version_).value;
            foreach (f; p) if (f.number == ss.SyncdPatch.mutations) patch.mutations ~= f.bytes;
            if (p.has(ss.SyncdPatch.externalMutations)) {
                auto ext = download(p.get(ss.SyncdPatch.externalMutations).bytes);
                patch.mutations = null;
                foreach (f; ProtoReader(ext)) if (f.number == ss.SyncdMutations.mutations) patch.mutations ~= f.bytes;
                if (patch.mutations.length == 0) throw new AppStateException("didn't get any mutations from download");
            }
            patch.snapshotMACv = p.get(ss.SyncdPatch.snapshotMAC).bytes;
            patch.patchMACv = p.get(ss.SyncdPatch.patchMAC).bytes;
            patch.keyId = ProtoReader(p.get(ss.SyncdPatch.keyID).bytes).get(ss.KeyId.ID).bytes;
            l.patches ~= patch;
        }
    return l;
}

// ── decoding ─────────────────────────────────────────────────────────────────────────────────

/// A decoded mutation: SET (0) or REMOVE (1) of an action at an index.
struct Mutation {
    int operation;
    string[] index;          // e.g. ["mute", "5511…@s.whatsapp.net"]
    const(ubyte)[] action;   // SyncActionValue
    int ver;
    const(ubyte)[] indexMAC, valueMAC, keyId;
    ulong patchVersion;
}

private struct MutRec {
    int op;
    const(ubyte)[] indexMAC, valueBlob, keyId;
}

private MutRec readRecord(const(ubyte)[] recBytes, int op) {
    auto rec = ProtoReader(recBytes);
    MutRec o;
    o.op = op;
    o.indexMAC = ProtoReader(rec.get(ss.SyncdRecord.index).bytes).get(ss.SyncdIndex.blob).bytes;
    o.valueBlob = ProtoReader(rec.get(ss.SyncdRecord.value).bytes).get(ss.SyncdValue.blob).bytes;
    o.keyId = ProtoReader(rec.get(ss.SyncdRecord.keyID).bytes).get(ss.KeyId.ID).bytes;
    // iv(16) + at least one block + value MAC(32): anything shorter cannot be a record
    if (o.valueBlob.length < 16 + 16 + 32) throw new AppStateException("app-state record value too short");
    return o;
}

private MutRec readMutation(const(ubyte)[] m) {
    auto r = ProtoReader(m);
    return readRecord(r.get(ss.SyncdMutation.record).bytes, cast(int) r.get(ss.SyncdMutation.operation).value);
}

/// GetMissingKeyIDs: every key id the list needs (snapshot, its records, each patch and mutation)
/// that the store does not hold.
ubyte[][] missingKeyIds(Store store, const ref PatchList list) {
    import std.algorithm : canFind;
    ubyte[][] ids;
    void want(const(ubyte)[] id) {
        if (id.length == 0 || ids.canFind(id)) return;
        if (store.appStateKey(id) is null) ids ~= id.dup;
    }
    if (list.snapshot.length) {
        auto s = ProtoReader(list.snapshot);
        want(ProtoReader(s.get(ss.SyncdSnapshot.keyID).bytes).get(ss.KeyId.ID).bytes);
        foreach (f; s) if (f.number == ss.SyncdSnapshot.records)
            want(ProtoReader(ProtoReader(f.bytes).get(ss.SyncdRecord.keyID).bytes).get(ss.KeyId.ID).bytes);
    }
    foreach (ref p; list.patches) {
        want(p.keyId);
        foreach (m; p.mutations)
            want(ProtoReader(ProtoReader(ProtoReader(m).get(ss.SyncdMutation.record).bytes)
                .get(ss.SyncdRecord.keyID).bytes).get(ss.KeyId.ID).bytes);
    }
    return ids;
}

/// The decoder: keys from the store, MACs and versions kept in the store.
struct Decoder {
    Store store;
    private ExpandedKeys[string] cache;

    ExpandedKeys keys(const(ubyte)[] keyId) {
        import std.digest : toHexString;
        const k = toHexString(keyId).idup;
        if (auto p = k in cache) return *p;
        auto data = store.appStateKey(keyId);
        if (data is null) throw new AppStateKeyMissing([keyId.dup]);
        auto e = expandAppStateKeys(data);
        cache[k] = e;
        return e;
    }

    private Mutation decodeMutation(const ref MutRec m, ulong patchVersion) {
        auto k = keys(m.keyId);
        if (m.valueBlob.length < 16 + 32) throw new AppStateException("mutation value too short");
        const content = m.valueBlob[0 .. $ - 32], valueMAC = m.valueBlob[$ - 32 .. $];
        if (contentMAC(m.op, content, m.keyId, k.valueMAC)[] != valueMAC)
            throw new AppStateException("mutation content MAC mismatch");
        auto plain = aesCbcDecrypt(k.valueEncryption[], content[0 .. 16], content[16 .. $]);
        auto d = ProtoReader(plain);
        const indexJson = d.get(sa.SyncActionData.index).bytes;
        if (hmacSha256(k.index[], indexJson)[] != m.indexMAC)
            throw new AppStateException("mutation index MAC mismatch");
        Mutation o;
        o.operation = m.op;
        try foreach (v; parseJSON(cast(string) indexJson).array) o.index ~= v.str;
        catch (Exception) throw new AppStateException("bad mutation index");
        o.action = d.get(sa.SyncActionData.value).bytes.dup;
        o.ver = cast(int) d.get(sa.SyncActionData.version_).value;
        o.indexMAC = m.indexMAC.dup;
        o.valueMAC = valueMAC.dup;
        o.keyId = m.keyId.dup;
        o.patchVersion = patchVersion;
        return o;
    }

    private void checkSnapshotMAC(string name, const ref HashState st, const(ubyte)[] keyId, const(ubyte)[] expected) {
        auto k = keys(keyId);
        if (snapshotMAC(st, name, k.snapshotMAC)[] != expected)
            throw new AppStateException("LTHash mismatch (snapshot MAC) at v" ~ st.ver.to!string);
    }

    /// DecodePatches: apply a snapshot (if any) then each patch to `state`, verifying every MAC, and
    /// persist versions/hashes/MACs. Returns the mutations in order. `apply`, when given, receives each
    /// snapshot's / patch's mutations BEFORE its version is committed: if applying them fails, the
    /// version does not advance and the next fetch hands them out again.
    Mutation[] decodePatches(const ref PatchList list, ref HashState state,
                             scope void delegate(const(Mutation)[]) apply = null) {
        Mutation[] outv;
        if (list.snapshot.length) {
            auto s = ProtoReader(list.snapshot);
            state.ver = ProtoReader(s.get(ss.SyncdSnapshot.version_).bytes).get(ss.SyncdVersion.version_).value;
            MutRec[] recs;
            foreach (f; s) if (f.number == ss.SyncdSnapshot.records) recs ~= readRecord(f.bytes, 0);   // SET
            const(ubyte)[][] added;
            foreach (ref m; recs) added ~= m.valueBlob[$ - 32 .. $];
            const zeroHash = state.hash;
            ltHashSubtractThenAdd(state.hash, null, added);
            const snapKey = ProtoReader(s.get(ss.SyncdSnapshot.keyID).bytes).get(ss.KeyId.ID).bytes;
            try checkSnapshotMAC(list.name, state, snapKey, s.get(ss.SyncdSnapshot.mac).bytes);
            catch (AppStateException e) {
                import std.stdio : stderr;
                try {
                    bool[string] seen;
                    size_t dups;
                    const(ubyte)[][] lastWins;
                    size_t[string] at;
                    foreach (ref m; recs) {
                        const k = cast(string) m.indexMAC.idup;
                        if (k in seen) { dups++; lastWins[at[k]] = m.valueBlob[$ - 32 .. $]; }
                        else { seen[k] = true; at[k] = lastWins.length; lastWins ~= m.valueBlob[$ - 32 .. $]; }
                    }
                    HashState alt;
                    alt.ver = state.ver;
                    alt.hash = zeroHash;
                    ltHashSubtractThenAdd(alt.hash, null, lastWins);
                    bool altOk;
                    try { checkSnapshotMAC(list.name, alt, snapKey, s.get(ss.SyncdSnapshot.mac).bytes); altOk = true; } catch (Exception) {}
                    size_t badContent;
                    foreach (ref m; recs) try decodeMutation(m, state.ver); catch (Exception) badContent++;
                    stderr.writefln("app-state %s snapshot v%d: %d record(s), %d distinct index(es), %d duplicate(s), %d undecodable; last-wins hash %s",
                        list.name, state.ver, recs.length, seen.length, dups, badContent, altOk ? "MATCHES" : "does not match");
                } catch (Exception) {}
                throw e;
            }
            const(ubyte)[][2][] macs;
            const before = outv.length;
            foreach (ref m; recs) {
                auto mu = decodeMutation(m, state.ver);
                outv ~= mu;
                macs ~= [mu.indexMAC, mu.valueMAC];
            }
            if (apply !is null) apply(outv[before .. $]);
            store.transaction({
                store.putAppStateVersion(list.name, state.ver, state.hash);
                store.putAppStateMACs(list.name, state.ver, macs);
            });
        }
        foreach (ref p; list.patches) {
            MutRec[] ms;
            foreach (raw; p.mutations) ms ~= readMutation(raw);
            HashState ns = state;
            ns.ver = p.ver;
            // updateHash: each SET adds its value MAC; whatever it replaces (or a REMOVE deletes) is
            // subtracted — the previous value from earlier in this patch, else from the store
            const(ubyte)[][] added, removed;
            foreach (i, ref m; ms) {
                if (m.op == 0) added ~= m.valueBlob[$ - 32 .. $];
                const(ubyte)[] prev;
                bool decided;
                for (long j = cast(long) i - 1; j >= 0; j--) {
                    if (ms[j].indexMAC == m.indexMAC) {
                        if (ms[j].op == 0) prev = ms[j].valueBlob[$ - 32 .. $];
                        decided = true;
                        break;
                    }
                }
                if (!decided) prev = store.appStateMAC(list.name, m.indexMAC);
                if (prev !is null) removed ~= prev;
            }
            ltHashSubtractThenAdd(ns.hash, removed, added);
            try checkSnapshotMAC(list.name, ns, p.keyId, p.snapshotMACv);
            catch (AppStateException e) {
                // what the patch did, for the log: each mutation's operation, index and where the value
                // it replaces came from (this patch / the store / nowhere)
                import std.stdio : stderr;
                import std.digest : toHexString;
                try {
                    stderr.writefln("app-state %s v%d: %d mutation(s), from v%d", list.name, p.ver, ms.length, state.ver);
                    foreach (i, ref m; ms) {
                        string src = "none";
                        for (long j = cast(long) i - 1; j >= 0; j--)
                            if (ms[j].indexMAC == m.indexMAC) { src = ms[j].op == 0 ? "patch-set" : "patch-remove"; break; }
                        if (src == "none" && store.appStateMAC(list.name, m.indexMAC) !is null) src = "store";
                        string idx = "?";
                        try { auto mu = decodeMutation(m, p.ver); import std.array : join; idx = mu.index.join(","); } catch (Exception) {}
                        if (idx.length > 60) idx = idx[0 .. 60];
                        stderr.writefln("   #%d %s prev=%s idxmac=%s index=%s", i, m.op == 0 ? "SET" : "REMOVE", src,
                            toHexString(m.indexMAC[0 .. 4]), idx);
                    }
                } catch (Exception) {}
                throw e;
            }
            {
                const(ubyte)[][] vmacs;
                foreach (ref m; ms) vmacs ~= m.valueBlob[$ - 32 .. $];
                auto k = keys(p.keyId);
                if (patchMAC(p.snapshotMACv, vmacs, p.ver, list.name, k.patchMAC)[] != p.patchMACv)
                    throw new AppStateException("patch MAC mismatch at v" ~ p.ver.to!string);
            }
            const(ubyte)[][] removedIdx;
            const(ubyte)[][2][] addedMacs;
            const before = outv.length;
            foreach (ref m; ms) {
                auto mu = decodeMutation(m, ns.ver);
                if (m.op == 1) {
                    removedIdx ~= mu.indexMAC;
                    import std.algorithm : remove;
                    foreach_reverse (i, am; addedMacs) if (am[0] == mu.indexMAC) addedMacs = addedMacs.remove(i);
                } else addedMacs ~= [mu.indexMAC, mu.valueMAC];
                outv ~= mu;
            }
            if (apply !is null) apply(outv[before .. $]);
            store.transaction({
                store.putAppStateVersion(list.name, ns.ver, ns.hash);
                store.deleteAppStateMACs(list.name, removedIdx);
                store.putAppStateMACs(list.name, ns.ver, addedMacs);
            });
            state = ns;
        }
        return outv;
    }
}

/// requestAppStateKeys: Message { protocolMessage { type = APP_STATE_SYNC_KEY_REQUEST (7);
/// appStateSyncKeyRequest (8) { keyIDs = 1 { keyID = 1 } } } }, sent as a peer message.
ubyte[] appStateKeyRequest(const ubyte[][] keyIds) {
    auto req = ProtoWriter();
    foreach (k; keyIds) req.bytes(1, ProtoWriter().bytes(1, k).buf);
    auto pm = ProtoWriter().varint(2, 7).bytes(8, req.buf);
    return ProtoWriter().bytes(12, pm.buf).buf;
}

unittest {
    // A collection encoded the way the server does (snapshot + one patch), decoded back with every
    // MAC verified: the LTHash, the snapshot and patch MACs, the content and index MACs.
    import std.file : tempDir, remove, exists;
    import std.process : thisProcessID;
    import wa.crypto : aesCbcEncrypt, randomBytes;
    const path = tempDir ~ "/wa-appstate-" ~ thisProcessID.to!string ~ ".db";
    scope (exit) foreach (s; ["", "-wal", "-shm"]) if (exists(path ~ s)) remove(path ~ s);
    auto st = new Store(path);
    auto keyId = cast(ubyte[]) [0, 0, 7];
    auto keyData = randomBytes(32);
    st.putAppStateKey(keyId, keyData, 1, cast(ubyte[]) [1]);
    auto k = expandAppStateKeys(keyData);

    ubyte[] record(int op, string indexJson, ubyte[] action, out ubyte[] valueMAC, out ubyte[] indexMAC) {
        auto data = ProtoWriter().bytes(sa.SyncActionData.index, cast(ubyte[]) indexJson)
            .bytes(sa.SyncActionData.value, action).varint(sa.SyncActionData.version_, 2).buf;
        auto iv = randomBytes(16);
        auto content = iv ~ aesCbcEncrypt(k.valueEncryption[], iv, data);
        valueMAC = contentMAC(op, content, keyId, k.valueMAC).dup;
        indexMAC = hmacSha256(k.index[], cast(ubyte[]) indexJson).dup;
        return ProtoWriter()
            .bytes(ss.SyncdRecord.index, ProtoWriter().bytes(ss.SyncdIndex.blob, indexMAC).buf)
            .bytes(ss.SyncdRecord.value, ProtoWriter().bytes(ss.SyncdValue.blob, content ~ valueMAC).buf)
            .bytes(ss.SyncdRecord.keyID, ProtoWriter().bytes(ss.KeyId.ID, keyId).buf).buf;
    }
    // snapshot v3 with two records
    ubyte[] vm1, im1, vm2, im2;
    auto r1 = record(0, `["mute","a@s.whatsapp.net"]`, [1], vm1, im1);
    auto r2 = record(0, `["pin_v1","b@s.whatsapp.net"]`, [2], vm2, im2);
    HashState expect;
    expect.ver = 3;
    ltHashSubtractThenAdd(expect.hash, null, [vm1, vm2]);
    auto snap = ProtoWriter().bytes(ss.SyncdSnapshot.version_, ProtoWriter().varint(ss.SyncdVersion.version_, 3).buf)
        .bytes(ss.SyncdSnapshot.records, r1).bytes(ss.SyncdSnapshot.records, r2)
        .bytes(ss.SyncdSnapshot.mac, snapshotMAC(expect, "regular", k.snapshotMAC)[])
        .bytes(ss.SyncdSnapshot.keyID, ProtoWriter().bytes(ss.KeyId.ID, keyId).buf).buf;
    // patch v4: SET replaces the mute (same index), REMOVE drops the pin
    ubyte[] vm3, im3, vm4, im4;
    auto r3 = record(0, `["mute","a@s.whatsapp.net"]`, [3], vm3, im3);
    auto r4 = record(1, `["pin_v1","b@s.whatsapp.net"]`, [4], vm4, im4);
    auto mut3 = ProtoWriter().varint(ss.SyncdMutation.operation, 0).bytes(ss.SyncdMutation.record, r3).buf;
    auto mut4 = ProtoWriter().varint(ss.SyncdMutation.operation, 1).bytes(ss.SyncdMutation.record, r4).buf;
    HashState after = expect;
    after.ver = 4;
    ltHashSubtractThenAdd(after.hash, [vm1, vm2], [vm3]);
    auto smac = snapshotMAC(after, "regular", k.snapshotMAC);
    auto pmac = patchMAC(smac[], [vm3, vm4], 4, "regular", k.patchMAC);

    PatchList l;
    l.name = "regular";
    l.snapshot = snap;
    Patch p;
    p.ver = 4;
    p.mutations = [mut3, mut4];
    p.snapshotMACv = smac.dup;
    p.patchMACv = pmac.dup;
    p.keyId = keyId;
    l.patches = [p];

    auto dec = Decoder(st);
    HashState state;
    auto muts = dec.decodePatches(l, state);
    assert(muts.length == 4 && muts[0].index == ["mute", "a@s.whatsapp.net"] && muts[3].operation == 1);
    assert(state.ver == 4 && state.hash == after.hash);
    ubyte[128] h;
    assert(st.appStateVersion("regular", h) == 4 && h == after.hash);
    assert(st.appStateMAC("regular", im1) == vm3 && st.appStateMAC("regular", im2) is null);

    // a tampered patch MAC fails
    l.patches[0].patchMACv = pmac[0 .. 31] ~ cast(ubyte)(pmac[31] ^ 1);
    HashState s2;
    st.deleteAppStateVersion("regular");
    bool threw;
    try dec.decodePatches(l, s2); catch (AppStateException) threw = true;
    assert(threw);
}
