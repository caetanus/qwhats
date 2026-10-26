package main

// The call bridge: WhatsApp Web's own voip engine runs in a helper process (qwhats-call: a Chromium
// page with WhatsApp Web's voip modules and wa_voip_shared.wasm, alive only during a call — see
// docs/calls-plan.md). The engine believes it is our device; this core stays the device on the wire:
//
//   in   a <call> child for us (offer, accept, transport, relaylatency, terminate, …) goes to the
//        engine as WhatsApp Web hands it over (handleIncomingSignalingOffer / …Message) — the offer's
//        <enc> already decrypted to the raw call key, as WAWebVoipValidateAndDecryptEnc does;
//   out  what the engine emits (sendWAWebVoipSignalingXmpp: a binary node for a peer) is wrapped in
//        <call to id>, sent, and its <ack class="call"> handed back (handleIncomingSignalingAck).
//
// The helper connects to a Unix socket and speaks JSON lines:
//
//   core → helper  {"t":"hello","meLid":…,"mePn":…,"pushName":…}
//                  {"t":"in","kind":"offer"|"message","node":b64,"peerJid":…,"platform":…,
//                   "version":…,"ts":…,"offline":false}
//                  {"t":"ack","id":N,"node":b64,"error":"0","type":…}   (the answer to a "send")
//   helper → core  {"t":"send","id":N,"peerJid":…,"payload":b64}
//                  {"t":"log","msg":…}
//
// Binary nodes are WhatsApp's binary XML with the stanza's leading flags byte (0), as WAWap's
// encodeStanza/decodeStanza use them.

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

type callBridge struct {
	a       *Account
	mu      sync.Mutex
	conn    net.Conn
	pending []map[string]any // what came before the helper connected (the offer, while it starts)
}

// callBridgePath: the bridge's socket — beside the core's own runtime files, private to the user.
func callBridgePath() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, fmt.Sprintf("qwhats-call-%d.sock", os.Getpid()))
}

// startCallBridge: listens for the helper (one at a time).
func (a *Account) startCallBridge() {
	path := callBridgePath()
	os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: call bridge:", err)
		return
	}
	os.Chmod(path, 0o600)
	a.bridge = &callBridge{a: a}
	fmt.Fprintln(os.Stderr, "qwhats-core: call bridge on", path)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go a.bridge.serve(c)
		}
	}()
}


// stanzaBytes: a node as WAWap.decodeStanza reads it (flags byte, then the node).
func stanzaBytes(n waBinary.Node) ([]byte, error) {
	b, err := waBinary.Marshal(n)
	if err != nil {
		return nil, err
	}
	return append([]byte{0}, b...), nil
}

// nodeFromStanza: the node in WAWap.encodeStanza's output (an uncompressed stanza).
func nodeFromStanza(b []byte) (*waBinary.Node, error) {
	if len(b) == 0 {
		return nil, errors.New("empty stanza")
	}
	if b[0]&2 != 0 {
		return nil, errors.New("compressed stanza")
	}
	return waBinary.Unmarshal(b[1:])
}

// write: a line to the helper. Called on the account event path, so it never blocks there — the
// socket write gets a deadline and runs outside the mutex, and the pending backlog (before a helper
// connects) is bounded so a call with no helper cannot grow it without limit (adversarial review).
const callPendingMax = 256

func (cb *callBridge) write(m map[string]any) {
	cb.mu.Lock()
	conn := cb.conn
	if conn == nil {
		if len(cb.pending) >= callPendingMax {
			cb.pending = cb.pending[1:] // drop the oldest
		}
		cb.pending = append(cb.pending, m)
		cb.mu.Unlock()
		return
	}
	cb.mu.Unlock()
	j, _ := json.Marshal(m)
	conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write(append(j, '\n')); err != nil {
		cb.mu.Lock()
		if cb.conn == conn {
			cb.conn = nil
		}
		cb.mu.Unlock()
		conn.Close()
	}
}

func (cb *callBridge) serve(c net.Conn) {
	cb.mu.Lock()
	if cb.conn != nil {
		cb.conn.Close()
	}
	cb.conn = c
	queued := cb.pending
	cb.pending = nil
	cb.mu.Unlock()
	a := cb.a
	me := a.client.Store.GetJID()
	lid := a.client.Store.GetLID()
	cb.write(map[string]any{"t": "hello", "mePn": me.String(), "meLid": lid.String(), "pushName": a.client.Store.PushName})
	for _, m := range queued {
		cb.write(m)
	}
	fmt.Fprintln(os.Stderr, "qwhats-core: call bridge: helper connected,", len(queued), "queued")
	r := bufio.NewReaderSize(c, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break
		}
		var m map[string]any
		if json.Unmarshal(line, &m) != nil {
			continue
		}
		switch m["t"] {
		case "send":
			go cb.send(m)
		case "log":
			fmt.Fprintln(os.Stderr, "qwhats-call:", m["msg"])
		}
	}
	cb.mu.Lock()
	if cb.conn == c {
		cb.conn = nil
	}
	cb.mu.Unlock()
	fmt.Fprintln(os.Stderr, "qwhats-core: call bridge: helper gone")
}

// send: a node the engine emitted, to its peer — <call to id>…</call> — and the ack back to it.
func (cb *callBridge) send(m map[string]any) {
	id, _ := m["id"].(float64)
	reply := map[string]any{"t": "ack", "id": id}
	fail := func(err error) {
		fmt.Fprintln(os.Stderr, "qwhats-core: call bridge send:", err)
		reply["error"] = "bridge"
		cb.write(reply)
	}
	raw, err := base64.StdEncoding.DecodeString(fmt.Sprint(m["payload"]))
	if err != nil {
		fail(err)
		return
	}
	child, err := nodeFromStanza(raw)
	if err != nil {
		fail(err)
		return
	}
	peer, err := types.ParseJID(fmt.Sprint(m["peerJid"]))
	if err != nil {
		fail(err)
		return
	}
	// an offer/enc_rekey/transfer carries the raw call key in <enc>: Signal-encrypted per device
	// (WAWebVoipSendSignalingXmpp) — not needed to answer a call; to place one, later
	if hasChild(*child, "enc") {
		fail(fmt.Errorf("%s with <enc>: placing calls is not bridged yet", child.Tag))
		return
	}
	cli := cb.a.client
	reqID := cli.GenerateMessageID()
	stanza := waBinary.Node{Tag: "call", Attrs: waBinary.Attrs{"to": peer, "id": reqID}, Content: []waBinary.Node{*child}}
	in := cli.DangerousInternals()
	wait := in.WaitResponse(reqID)
	if err := in.SendNode(ctx, stanza); err != nil {
		in.CancelResponse(reqID, wait)
		fail(err)
		return
	}
	dumpCallNode("out-"+child.Tag, &stanza)
	select {
	case ack := <-wait:
		b, err := stanzaBytes(*ack)
		if err != nil {
			fail(err)
			return
		}
		dumpCallNode("ack-"+child.Tag, ack)
		reply["node"] = b64(b)
		reply["error"] = attrOr(ack, "error", "0")
		reply["type"] = attrOr(ack, "type", "")
		cb.write(reply)
	case <-time.After(20 * time.Second):
		in.CancelResponse(reqID, wait)
		fail(errors.New("no ack for " + child.Tag))
	}
}

func hasChild(n waBinary.Node, tag string) bool {
	_, ok := n.GetOptionalChildByTag(tag)
	return ok
}

func attrOr(n *waBinary.Node, k, def string) string {
	if v, ok := n.Attrs[k]; ok {
		return fmt.Sprint(v)
	}
	return def
}

// forwardCall: a <call> child for us, to the engine. meta: the <call> stanza's sender and timestamp.
func (a *Account) forwardCall(kind string, node *waBinary.Node, meta types.BasicCallMeta, remote types.CallRemoteMeta) {
	if a.bridge == nil || node == nil {
		return
	}
	n := *node
	if kind == "offer" {
		if key, err := a.decryptCallKey(n, meta); err != nil {
			fmt.Fprintln(os.Stderr, "qwhats-core: call key:", err)
		} else {
			n = withEncContent(n, key)
			fmt.Fprintln(os.Stderr, "qwhats-core: call key decrypted:", len(key), "bytes")
		}
	}
	b, err := stanzaBytes(n)
	if err != nil {
		return
	}
	a.bridge.write(map[string]any{"t": "in", "kind": kind, "node": b64(b), "peerJid": meta.From.String(),
		"platform": remote.RemotePlatform, "version": remote.RemoteVersion, "ts": meta.Timestamp.Unix(), "offline": false})
}

// decryptCallKey (WAWebVoipValidateAndDecryptEnc): the offer's <enc> — Signal from the caller's
// device to ours — holds Message{call:{callKey}}.
func (a *Account) decryptCallKey(n waBinary.Node, meta types.BasicCallMeta) ([]byte, error) {
	enc, ok := n.GetOptionalChildByTag("enc")
	if !ok {
		return nil, errors.New("no <enc>")
	}
	isPreKey := fmt.Sprint(enc.Attrs["type"]) == "pkmsg"
	pt, _, err := a.client.DangerousInternals().DecryptDM(ctx, &enc, meta.From, isPreKey, meta.Timestamp)
	if err != nil {
		return nil, err
	}
	if len(pt) == 0 || int(pt[len(pt)-1]) > len(pt) {
		return nil, errors.New("bad padding")
	}
	pt = pt[:len(pt)-int(pt[len(pt)-1])]
	var msg waE2E.Message
	if err := proto.Unmarshal(pt, &msg); err != nil {
		return nil, err
	}
	key := msg.GetCall().GetCallKey()
	if len(key) == 0 {
		return nil, errors.New("no call key in the message")
	}
	return key, nil
}

// withEncContent: the node with its <enc> child's content replaced.
func withEncContent(n waBinary.Node, content []byte) waBinary.Node {
	kids := n.GetChildren()
	out := make([]waBinary.Node, len(kids))
	for i, k := range kids {
		if k.Tag == "enc" {
			k = waBinary.Node{Tag: k.Tag, Attrs: k.Attrs, Content: content}
		}
		out[i] = k
	}
	n.Content = out
	return n
}

// forwardCallEvent: every call event's node, to the engine (see forwardCall).
func (a *Account) forwardCallEvent(evt any) {
	switch e := evt.(type) {
	case *events.CallOffer:
		a.forwardCall("offer", e.Data, e.BasicCallMeta, e.CallRemoteMeta)
	case *events.CallAccept:
		a.forwardCall("message", e.Data, e.BasicCallMeta, e.CallRemoteMeta)
	case *events.CallPreAccept:
		a.forwardCall("message", e.Data, e.BasicCallMeta, e.CallRemoteMeta)
	case *events.CallTransport:
		a.forwardCall("message", e.Data, e.BasicCallMeta, e.CallRemoteMeta)
	case *events.CallRelayLatency:
		a.forwardCall("message", e.Data, e.BasicCallMeta, types.CallRemoteMeta{})
	case *events.CallTerminate:
		a.forwardCall("message", e.Data, e.BasicCallMeta, types.CallRemoteMeta{})
	case *events.CallReject:
		a.forwardCall("message", e.Data, e.BasicCallMeta, types.CallRemoteMeta{})
	}
}


