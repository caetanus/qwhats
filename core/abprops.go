package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"go.mau.fi/whatsmeow"
	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/types"
)

// callProps: the ABProps (server-side feature flags, WAWebABPropsConfigs) that gate calling on a web
// device, by their config_code.
var callProps = map[string]string{
	"15461": "enable_web_calling",
	"20924": "enable_web_group_calling",
	"25621": "enable_web_voip_p2p",
	"29764": "enable_web_voip_webtransport",
	"35115": "is_guest_calling_eligible",
}

// logCallProps (WASmaxOutAbPropsGetExperimentConfigRequest): asks the server for this account's
// ABProps — <iq xmlns="abt" type="get"><props protocol="1"/></iq> → <props><prop config_code
// config_value/>…</props> — and logs the ones about calls. Read-only: nothing is stored or changed.
func (a *Account) logCallProps() {
	res, err := a.client.DangerousInternals().SendIQ(ctx, whatsmeow.DangerousInfoQuery{
		Namespace: "abt",
		Type:      whatsmeow.DangerousInfoQueryType("get"),
		To:        types.ServerJID,
		Content:   []waBinary.Node{{Tag: "props", Attrs: waBinary.Attrs{"protocol": "1"}}},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: abprops:", err)
		return
	}
	props, ok := res.GetOptionalChildByTag("props")
	if !ok {
		fmt.Fprintln(os.Stderr, "qwhats-core: abprops: no <props>")
		return
	}
	seen := map[string]string{}
	all := 0
	for _, p := range props.GetChildrenByTag("prop") {
		all++
		code := fmt.Sprint(p.Attrs["config_code"])
		if name, ok := callProps[code]; ok {
			seen[name] = fmt.Sprint(p.Attrs["config_value"])
		}
	}
	for _, name := range callProps {
		v, ok := seen[name]
		if !ok {
			v = "(not sent: default)"
		}
		fmt.Fprintf(os.Stderr, "qwhats-core: abprop %s = %s\n", name, v)
	}
	fmt.Fprintf(os.Stderr, "qwhats-core: abprops: %d props received\n", all)
}

// dumpCallNode: the raw <call> stanzas, for docs/calls-plan.md phase 0 — written only when the
// diagnostics directory ~/.cache/qml-whats-build/calls exists (a developer opts in by making it),
// private to the user (0600). They carry call keys (encrypted) and relay tokens: never shared.
func dumpCallNode(kind string, node *waBinary.Node) {
	if node == nil {
		return
	}
	home, _ := os.UserHomeDir()
	dir := home + "/.cache/qml-whats-build/calls"
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return
	}
	// readable (bytes in hex, as whatsmeow prints them) and full (JSON, bytes in base64)
	base := fmt.Sprintf("%s/%s-%s", dir, time.Now().Format("20060102-150405.000"), kind)
	os.WriteFile(base+".xml", []byte(node.String()), 0o600)
	if j, err := json.Marshal(node); err == nil {
		os.WriteFile(base+".json", j, 0o600)
	}
	fmt.Fprintln(os.Stderr, "qwhats-core: call node saved:", kind)
}
