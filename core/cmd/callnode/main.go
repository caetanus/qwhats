// callnode: a <call> child saved by the core's diagnostics (JSON, as whatsmeow marshals a Node) →
// the stanza bytes WAWap.decodeStanza reads (flags byte 0 + binary XML), base64, on stdout.
// For replaying a recorded offer into the voip engine without the network.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
)

func node(m map[string]any) waBinary.Node {
	n := waBinary.Node{Tag: fmt.Sprint(m["Tag"]), Attrs: waBinary.Attrs{}}
	if attrs, ok := m["Attrs"].(map[string]any); ok {
		for k, v := range attrs {
			s := fmt.Sprint(v)
			// JIDs travel as JIDs in binary XML: a string with an @ was one
			if strings.Contains(s, "@") {
				if j, err := types.ParseJID(s); err == nil {
					n.Attrs[k] = j
					continue
				}
			}
			n.Attrs[k] = s
		}
	}
	switch c := m["Content"].(type) {
	case []any:
		kids := []waBinary.Node{}
		for _, k := range c {
			kids = append(kids, node(k.(map[string]any)))
		}
		n.Content = kids
	case string:
		b, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			panic(err)
		}
		n.Content = b
	}
	return n
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		panic(err)
	}
	b, err := waBinary.Marshal(node(m))
	if err != nil {
		panic(err)
	}
	fmt.Print(base64.StdEncoding.EncodeToString(append([]byte{0}, b...)))
}
