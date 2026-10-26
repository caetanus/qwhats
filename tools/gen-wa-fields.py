#!/usr/bin/env python3
"""Generate D field-number tables from WhatsApp's protobuf schemas.

Reads the .proto files shipped with whatsmeow (in the Go module cache) and writes one D module per
schema under wa/source/wa/pb/, holding only numbers: for every message a struct with an anonymous
enum of its field numbers (Message.imageMessage == 3), nested messages as nested structs, and every
proto enum as a D enum. The D core reads protobufs with wa.proto.ProtoReader; these tables let it
name fields instead of hard-coding numbers.

    tools/gen-wa-fields.py            # finds the whatsmeow module via `go env GOMODCACHE`
"""
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "wa", "source", "wa", "pb")

SCHEMAS = {  # whatsmeow proto dir → our module name
    "waE2E": "e2e",
    "waCommon": "common",
    "waHistorySync": "historysync",
    "waSyncAction": "syncaction",
    "waServerSync": "serversync",
    "waWeb": "web",
    "waAdv": "adv",
    "waLidMigrationSyncPayload": "lidmigration",
    "waAICommon": "aicommon",
    "waAICommonDeprecated": "aicommondeprecated",
}

D_KEYWORDS = set("""abstract alias align asm assert auto body bool break byte case cast catch cdouble
cent cfloat char class const continue creal dchar debug default delegate delete deprecated do double
else enum export extern false final finally float for foreach foreach_reverse function goto idouble if
ifloat immutable import in inout int interface invariant ireal is lazy long macro mixin module new
nothrow null out override package pragma private protected public pure real ref return scope shared
short static struct super switch synchronized template this throw true try typeid typeof ubyte ucent
uint ulong union unittest ushort version void wchar while with""".split())


def ident(name):
    return name + "_" if name in D_KEYWORDS else name


def tokens(text):
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.findall(r'"[^"]*"|[A-Za-z_][A-Za-z0-9_.]*|-?\d+|[{}=;<>\[\],()]', text)


class P:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def skip_stmt(self):
        depth = 0
        while True:
            tok = self.next()
            if tok == "{":
                depth += 1
            elif tok == "}":
                depth -= 1
                if depth == 0:
                    return
            elif tok == ";" and depth == 0:
                return

    def parse_enum(self):
        name = self.next()
        assert self.next() == "{"
        vals = []
        while self.peek() != "}":
            tok = self.next()
            if tok in ("option", "reserved"):
                self.i -= 1
                self.skip_stmt()
                continue
            if tok == ";":
                continue
            assert self.next() == "="
            num = int(self.next())
            if self.peek() == "[":
                while self.next() != "]":
                    pass
            assert self.next() == ";"
            vals.append((tok, num))
        self.next()
        return ("enum", name, vals)

    def parse_message(self):
        name = self.next()
        assert self.next() == "{"
        fields, nested = [], []
        while self.peek() != "}":
            tok = self.peek()
            if tok == "message":
                self.next()
                nested.append(self.parse_message())
            elif tok == "enum":
                self.next()
                nested.append(self.parse_enum())
            elif tok == "oneof":
                self.next()
                self.next()  # oneof name
                assert self.next() == "{"
                while self.peek() != "}":
                    if self.peek() == "option":
                        self.skip_stmt()
                        continue
                    fields.append(self.parse_field(None))
                self.next()
            elif tok in ("option", "reserved", "extensions"):
                self.skip_stmt()
            elif tok == ";":
                self.next()
            else:
                label = None
                if tok in ("optional", "required", "repeated"):
                    label = self.next()
                fields.append(self.parse_field(label))
        self.next()
        return ("message", name, fields, nested)

    def parse_field(self, label):
        ftype = self.next()
        if ftype == "map":
            while self.next() != ">":
                pass
            ftype = "map"
        fname = self.next()
        assert self.next() == "=", (fname, self.t[self.i - 3:self.i + 3])
        num = int(self.next())
        if self.peek() == "[":
            while self.next() != "]":
                pass
        assert self.next() == ";"
        return (fname, num, ftype, label)

    def parse_file(self):
        items = []
        while self.peek() is not None:
            tok = self.next()
            if tok == "message":
                items.append(self.parse_message())
            elif tok == "enum":
                items.append(self.parse_enum())
            elif tok in ("syntax", "package", "option", "import"):
                self.i -= 1
                self.skip_stmt()
        return items


def emit(item, indent, out):
    pad = "    " * indent
    if item[0] == "enum":
        _, name, vals = item
        out.append(f"{pad}enum {ident(name)} : int {{")
        for v, n in vals:
            out.append(f"{pad}    {ident(v)} = {n},")
        out.append(f"{pad}}}")
        return
    _, name, fields, nested = item
    out.append(f"{pad}struct {ident(name)} {{")
    if fields:
        out.append(f"{pad}    enum : uint {{")
        for fname, num, ftype, label in fields:
            out.append(f"{pad}        {ident(fname)} = {num},")
        out.append(f"{pad}    }}")
    for n in nested:
        emit(n, indent + 1, out)
    out.append(f"{pad}}}")


def main():
    cache = subprocess.check_output(["go", "env", "GOMODCACHE"], text=True,
                                    cwd=os.path.join(HERE, "..", "core")).strip()
    mods = sorted(glob.glob(os.path.join(cache, "go.mau.fi", "whatsmeow@*")))
    if not mods:
        sys.exit("whatsmeow not found in the Go module cache")
    wm = mods[-1]
    os.makedirs(OUT, exist_ok=True)
    for src, mod in SCHEMAS.items():
        files = glob.glob(os.path.join(wm, "proto", src, "*.proto"))
        if not files:
            sys.exit(f"no .proto in {src}")
        items = P(tokens(open(files[0]).read())).parse_file()
        out = [
            f"// Generated by tools/gen-wa-fields.py from {os.path.basename(files[0])} (whatsmeow"
            f" {os.path.basename(wm).split('@')[1]}). Do not edit.",
            "// Field numbers and enum values only: read messages with wa.proto.ProtoReader.",
            f"module wa.pb.{mod};",
            "",
        ]
        for it in items:
            emit(it, 0, out)
            out.append("")
        with open(os.path.join(OUT, mod + ".d"), "w") as f:
            f.write("\n".join(out))
        print(f"wa/source/wa/pb/{mod}.d: {len(items)} top-level types")

    # types.BotJIDMap: Meta AI bot ids (…@bot) → their phone-number JIDs (a bot's chat is its number)
    src = open(os.path.join(wm, "types", "botmap.go")).read()
    pairs = re.findall(r'NewJID\("(\d+)", BotServer\):\s*NewJID\("(\d+)", DefaultUserServer\)', src)
    out = [
        f"// Generated by tools/gen-wa-fields.py from whatsmeow types/botmap.go"
        f" ({os.path.basename(wm).split('@')[1]}). Do not edit.",
        "module wa.pb.botmap;",
        "",
        "/// Meta AI bot user (…@bot) → its phone-number user (…@s.whatsapp.net).",
        "immutable string[string] botJIDMap;",
        "",
        "shared static this() {",
        "    botJIDMap = [",
    ]
    out += [f'        "{b}": "{pn}",' for b, pn in pairs]
    out += ["    ];", "}", ""]
    with open(os.path.join(OUT, "botmap.d"), "w") as f:
        f.write("\n".join(out))
    print(f"wa/source/wa/pb/botmap.d: {len(pairs)} bots")


if __name__ == "__main__":
    main()
