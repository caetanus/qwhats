/// The phone's contacts as KDE Connect's contacts plugin keeps them: one vCard per contact under
/// ~/.local/share/kpeoplevcard/kdeconnect-<device id>/ (plugins/contacts/contactsplugin.cpp writes
/// them as the phone sends them). We need names for numbers, and the photo when there is one.
module kc.contacts;

import std.string : strip, indexOf, startsWith, toUpper;

struct Contact {
    string uid;         // the vCard file: one contact, whatever its name
    string name;
    string[] numbers;
    ubyte[] photo;      // PHOTO;ENCODING=b (JPEG), when the phone sent one
}

/// A number's identity: its digits, all of them ("+55 11 98765-4321" → "5511987654321").
string numberKey(string number) {
    char[] d;
    foreach (c; number) if (c >= '0' && c <= '9') d ~= c;
    return d.idup;
}

/// Two numbers written differently for the same line: one's digits end the other's, at least 8 of
/// them ("11987654321" and "5511987654321"; "(11) 3333-4444" and "(21) 3333-4444" do not match).
bool sameLine(string a, string b) {
    import std.algorithm : endsWith, min;
    if (min(a.length, b.length) < 8) return a == b;
    return a.length >= b.length ? a.endsWith(b) : b.endsWith(a);
}

/// Parse one vCard file (2.1/3.0/4.0 as Android exports them); folded lines are unfolded.
Contact parseVCard(string text) {
    import std.array : split;
    import std.base64 : Base64;
    import std.string : lineSplitter;
    string[] lines;
    foreach (l; text.lineSplitter) {
        if (l.length && (l[0] == ' ' || l[0] == '\t') && lines.length) lines[$ - 1] ~= l[1 .. $];
        else lines ~= l.idup;
    }
    Contact c;
    string photo;
    foreach (l; lines) {
        const colon = l.indexOf(':');
        if (colon <= 0) continue;
        const head = l[0 .. colon].toUpper, value = l[colon + 1 .. $].strip;
        const prop = head.split(";")[0];
        // "item1.TEL" groups
        const name = prop.indexOf('.') >= 0 ? prop[prop.indexOf('.') + 1 .. $] : prop;
        switch (name) {
            case "FN": if (value.length) c.name = unescape(value); break;
            case "N": if (!c.name.length) c.name = unescape(value.split(";")[0 .. $ > 2 ? 2 : $].join_reversed); break;
            case "TEL": if (value.length) c.numbers ~= value.startsWith("tel:") ? value[4 .. $] : value; break;
            case "PHOTO":
                if (value.startsWith("data:")) {
                    const comma = value.indexOf(',');
                    if (comma > 0) photo = value[comma + 1 .. $];
                } else photo = value;
                break;
            default: break;
        }
    }
    if (photo.length) {
        try c.photo = Base64.decode(photo);
        catch (Exception) {}
    }
    return c;
}

private string join_reversed(string[] parts) {
    // N:Family;Given → "Given Family"
    string s;
    foreach_reverse (p; parts) if (p.strip.length) s ~= (s.length ? " " : "") ~ p.strip;
    return s;
}

private string unescape(string v) {
    import std.array : replace;
    return v.replace("\\,", ",").replace("\\;", ";").replace("\\n", " ").replace("\\\\", "\\");
}

/// Every contact of the device, by numberKey (all digits)
final class Contacts {
    Contact[string] byNumber;
    private const(Contact)*[string] resolved;   // lookups already made (null: nobody, or ambiguous)

    void load(string deviceID) {
        import std.file : dirEntries, SpanMode, exists, readText;
        import std.path : expandTilde, buildPath;
        byNumber = null;
        resolved = null;
        const dir = buildPath("~/.local/share/kpeoplevcard".expandTilde, "kdeconnect-" ~ deviceID);
        if (!exists(dir)) return;
        foreach (e; dirEntries(dir, "*.vcf", SpanMode.shallow)) {
            Contact c;
            try c = parseVCard(readText(e.name));
            catch (Exception) continue;
            c.uid = e.name;
            foreach (n; c.numbers) {
                const k = numberKey(n);
                if (k.length) byNumber[k] = c;
            }
        }
    }

    /// The contact's name for a number, or null
    string name(string number) {
        if (auto c = find(number)) return c.name;
        return null;
    }

    /// The contact with this number: the same digits, or else the one contact whose number is the
    /// same line written another way (two candidates: nobody — better a number than a wrong name)
    const(Contact)* find(string number) {
        const k = numberKey(number);
        if (!k.length) return null;
        if (auto c = k in byNumber) return c;
        if (auto r = k in resolved) return *r;
        const(Contact)* hit;
        bool ambiguous;
        foreach (key, ref c; byNumber) {
            if (!sameLine(key, k)) continue;
            if (hit !is null && hit.uid != c.uid) { ambiguous = true; break; }
            hit = &c;
        }
        resolved[k] = ambiguous ? null : hit;
        return ambiguous ? null : hit;
    }
}

unittest {
    auto c = parseVCard("BEGIN:VCARD\r\nVERSION:2.1\r\nN:Silva;Maria;;;\r\nFN:Maria Silva\r\nTEL;CELL:+55 11 98765-4321\r\n"
        ~ "item1.TEL:011 3333-4444\r\nPHOTO;ENCODING=b;TYPE=JPEG:/9j/4A\r\n AQ\r\nEND:VCARD\r\n");
    assert(c.name == "Maria Silva");
    assert(c.numbers == ["+55 11 98765-4321", "011 3333-4444"]);
    assert(c.photo == [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]); // "/9j/4A" ‖ "AQ" unfolded
    assert(numberKey("+55 11 98765-4321") == "5511987654321");
    assert(sameLine(numberKey("+55 11 98765-4321"), numberKey("(11) 98765-4321")));
    assert(!sameLine(numberKey("(11) 3333-4444"), numberKey("(21) 3333-4444")));
    auto cs = new Contacts;
    cs.byNumber["551133334444"] = Contact("a.vcf", "Ana", ["+55 11 3333-4444"]);
    cs.byNumber["552133334444"] = Contact("b.vcf", "Bia", ["+55 21 3333-4444"]);
    assert(cs.name("(11) 3333-4444") == "Ana");        // suffix of one line only
    assert(cs.name("+55 21 3333-4444") == "Bia");      // exact
    assert(cs.name("3333-4444") is null);              // both end like this: ambiguous, no name
    auto twins = new Contacts;                         // same name, different people: still ambiguous
    twins.byNumber["551133334444"] = Contact("j1.vcf", "João", ["+55 11 3333-4444"]);
    twins.byNumber["552133334444"] = Contact("j2.vcf", "João", ["+55 21 3333-4444"]);
    assert(twins.find("3333-4444") is null);
    auto n = parseVCard("BEGIN:VCARD\nVERSION:3.0\nN:Souza;João\nTEL:123\nEND:VCARD\n");
    assert(n.name == "João Souza");
}
