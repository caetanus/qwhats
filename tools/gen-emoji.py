#!/usr/bin/env python3
# Fills the emoji list of ui/native/EmojiPanel.qml (between its BEGIN/END EMOJI DATA markers) from
# iamcal/emoji-data (https://raw.githubusercontent.com/iamcal/emoji-data/master/emoji.json): the
# emoji WhatsApp's picker shows, by its categories, in Unicode's order, without skin-tone variants.
# usage: gen-emoji.py emoji.json ui/native/EmojiPanel.qml
import json, re, sys

CATS = [  # emoji-data category → the picker's (Smileys and People are one tab in WhatsApp)
    (["Smileys & Emotion", "People & Body"], "Smileys e pessoas"),
    (["Animals & Nature"], "Animais e natureza"),
    (["Food & Drink"], "Comidas e bebidas"),
    (["Activities"], "Atividades"),
    (["Travel & Places"], "Viagens e lugares"),
    (["Objects"], "Objetos"),
    (["Symbols"], "Símbolos"),
    (["Flags"], "Bandeiras"),
]

data = json.load(open(sys.argv[1]))
data.sort(key=lambda e: e.get("sort_order", 0))
cats = []
for names, label in CATS:
    lst = []
    for e in data:
        if e.get("category") in names and e.get("has_img_google", True):
            lst.append("".join(chr(int(x, 16)) for x in e["unified"].split("-")))
    cats.append({"name": label, "icon": lst[0], "list": lst})

block = "    // BEGIN EMOJI DATA\n    readonly property var categories: " + json.dumps(cats, ensure_ascii=False) + "\n    // END EMOJI DATA"
qml = open(sys.argv[2]).read()
qml = re.sub(r"    // BEGIN EMOJI DATA\n.*?    // END EMOJI DATA", lambda _: block, qml, flags=re.S)
open(sys.argv[2], "w").write(qml)
print(sum(len(c["list"]) for c in cats), "emoji in", len(cats), "categories")
