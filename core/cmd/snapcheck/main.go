// snapcheck: an app-state snapshot's MAC as whatsmeow computes it (LTHash of the records' value MACs,
// then HMAC-SHA256(key, hash ‖ version ‖ name)) — to tell our implementation from the server's data.
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"

	"go.mau.fi/whatsmeow/appstate/lthash"
)

func main() {
	f, _ := os.Open(os.Args[1])
	sc := bufio.NewScanner(f)
	sc.Scan()
	head := strings.Fields(sc.Text())
	name := head[0]
	ver, _ := strconv.ParseUint(head[1], 10, 64)
	sc.Scan(); key, _ := hex.DecodeString(sc.Text())
	sc.Scan(); want, _ := hex.DecodeString(sc.Text())
	sc.Scan(); ours, _ := hex.DecodeString(sc.Text())
	var added [][]byte
	for sc.Scan() { b, _ := hex.DecodeString(sc.Text()); added = append(added, b) }
	hash := make([]byte, 128)
	lthash.WAPatchIntegrity.SubtractThenAddInPlace(hash, nil, added)
	v := make([]byte, 8); binary.BigEndian.PutUint64(v, ver)
	m := hmac.New(sha256.New, key); m.Write(hash); m.Write(v); m.Write([]byte(name))
	fmt.Println("records:", len(added))
	fmt.Println("same LTHash as ours:", hex.EncodeToString(hash) == hex.EncodeToString(ours))
	fmt.Println("whatsmeow MAC matches the server's:", hmac.Equal(m.Sum(nil), want))
}
