// The user's choices, kept as one JSON object in ~/.config/qml-whats/settings.json. Qt-free: the
// defaults, the merge of one changed key and the file round trip are unit-tested on their own.
module qmlwhats.settings;

import std.json;

/// Every key the app knows, with its default. A key missing from the file takes its default; a key
/// the file has and this table does not is dropped on the next save (an option that went away).
JSONValue defaults(string downloadDir) {
    JSONValue d = parseJSON(`{
        "notifications": true,
        "notifyPreview": true,
        "sounds": true,
        "closeToTray": true,
        "startHidden": false,
        "autoGrantMedia": true,
        "forceCalling": false,
        "pdfInApp": true,
        "openDownloads": true,
        "theme": "system",
        "zoom": 1.0,
        "listWidth": 28,
        "autoUpdate": true,
        "spellcheck": true,
        "spellLangs": [],
        "remoteControl": false,
        "installDeclined": false,
        "accounts": [{"id": "main", "name": "Principal"}],
        "currentAccount": "main"
    }`);
    d["downloadDir"] = downloadDir;
    return d;
}

/// `stored` laid over `defs`: only known keys, and only values of the default's JSON type (an int
/// where a float is expected is accepted — JSON has one number type).
JSONValue merged(JSONValue defs, JSONValue stored) {
    JSONValue o = defs;
    if (stored.type != JSONType.object) return o;
    foreach (k, v; stored.object) {
        if (k !in defs.object) continue;
        if (sameKind(defs[k], v)) o[k] = v;
    }
    return o;
}

/// One key changed from the UI (`valueJson` is the value as JSON). Unknown key or wrong type: unchanged.
bool apply(ref JSONValue current, JSONValue defs, string key, string valueJson) {
    if (key !in defs.object) return false;
    JSONValue v;
    try v = parseJSON(valueJson);
    catch (JSONException) return false;
    if (!sameKind(defs[key], v)) return false;
    current[key] = v;
    return true;
}

private bool isNumber(JSONType t) {
    return t == JSONType.integer || t == JSONType.uinteger || t == JSONType.float_;
}

private bool sameKind(JSONValue a, JSONValue b) {
    if (isNumber(a.type)) return isNumber(b.type);
    if (a.type == JSONType.true_ || a.type == JSONType.false_) return b.type == JSONType.true_ || b.type == JSONType.false_;
    return a.type == b.type;
}

JSONValue load(string path, JSONValue defs) {
    import std.file : exists, readText;
    if (!exists(path)) return defs;
    try return merged(defs, parseJSON(readText(path)));
    catch (Exception) return defs;   // a damaged file: the defaults, rewritten on the next change
}

/// Written beside and renamed over: a crash mid-write never leaves half a file.
void save(string path, JSONValue s) {
    import std.file : write, rename, mkdirRecurse;
    import std.path : dirName;
    mkdirRecurse(dirName(path));
    const tmp = path ~ ".tmp";
    write(tmp, s.toPrettyString());
    rename(tmp, path);
}

unittest {
    auto d = defaults("/home/u/Downloads/WhatsApp");
    assert(d["downloadDir"].str == "/home/u/Downloads/WhatsApp");
    assert(d["closeToTray"].boolean);

    // known keys of the right type win; unknown keys and wrong types are dropped
    auto m = merged(d, parseJSON(`{"closeToTray": false, "zoom": 1, "bogus": 3, "notifications": "no"}`));
    assert(!m["closeToTray"].boolean);
    assert(m["zoom"].integer == 1);
    assert("bogus" !in m.object);
    assert(m["notifications"].boolean);

    auto s = d;
    assert(apply(s, d, "zoom", "1.25"));
    assert(s["zoom"].floating == 1.25);
    assert(!apply(s, d, "zoom", `"big"`));
    assert(!apply(s, d, "nope", "true"));
    assert(!apply(s, d, "zoom", "{broken"));
    assert(apply(s, d, "spellLangs", `["pt-BR","en-US"]`));
    assert(s["spellLangs"].array.length == 2);

    import std.file : tempDir, remove, exists;
    import std.path : buildPath;
    const p = buildPath(tempDir, "qml-whats-settings-test.json");
    save(p, s);
    auto back = load(p, d);
    assert(back["zoom"].floating == 1.25);
    remove(p);
    assert(!exists(p ~ ".tmp"));
}
