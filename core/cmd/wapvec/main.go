// wapvec: test vectors for our D WAP codec (wa/), made by whatsmeow's encoder — the reference
// while we replace it. Prints JSON: [{name, hex}].
//
//	cd core && go run ./cmd/wapvec > ../wa/tests/wap-vectors.json
package main

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
)

func main() {
	user := types.NewJID("5511999999999", types.DefaultUserServer)
	dev := types.JID{User: "5511999999999", Device: 7, Server: types.DefaultUserServer}
	lid := types.JID{User: "100200300400500", Device: 2, Server: types.HiddenUserServer}
	group := types.NewJID("120363000000000001", types.GroupServer)
	big := []byte(strings.Repeat("x", 300))
	vectors := []struct {
		name string
		node waBinary.Node
	}{
		{"empty", waBinary.Node{Tag: "iq"}},
		{"token attrs", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"type": "get"}}},
		{"server jid", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"to": types.ServerJID}}},
		{"user jid", waBinary.Node{Tag: "message", Attrs: waBinary.Attrs{"to": user}}},
		{"device jid", waBinary.Node{Tag: "message", Attrs: waBinary.Attrs{"to": dev}}},
		{"lid jid", waBinary.Node{Tag: "message", Attrs: waBinary.Attrs{"participant": lid}}},
		{"group jid", waBinary.Node{Tag: "message", Attrs: waBinary.Attrs{"to": group}}},
		{"nibble", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"id": "1234-56.7"}}},
		{"nibble odd", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"id": "123"}}},
		{"hex", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"id": "3EB0C2A1F9"}}},
		{"plain string", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"xmlns": "some:new:namespace!"}}},
		{"unicode", waBinary.Node{Tag: "body", Content: []byte("olá, ação ☀️")}},
		{"dict token", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"xmlns": "w:profile:picture"}}},
		{"binary 300", waBinary.Node{Tag: "enc", Content: big}},
		{"empty string attr", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"id": ""}}},
		{"children", waBinary.Node{Tag: "iq", Attrs: waBinary.Attrs{"type": "set"}, Content: []waBinary.Node{
			{Tag: "pair-device", Content: []waBinary.Node{{Tag: "ref", Content: []byte("abc")}}},
			{Tag: "ping"},
		}}},
	}
	type out struct {
		Name string `json:"name"`
		Hex  string `json:"hex"`
	}
	res := []out{}
	for _, v := range vectors {
		b, err := waBinary.Marshal(v.node)
		if err != nil {
			panic(v.name + ": " + err.Error())
		}
		res = append(res, out{v.name, hex.EncodeToString(b)})
	}
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", " ")
	e.Encode(res)
}
