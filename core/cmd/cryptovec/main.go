// cryptovec: XEdDSA vectors from libsignal (what whatsmeow and WhatsApp sign and verify with), for
// the D protocol's tests (wa/tests/xeddsa-vectors.json). With -verify FILE it checks signatures the
// D side made: lines of "pubhex msghex sighex".
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"go.mau.fi/libsignal/ecc"
	"go.mau.fi/whatsmeow/util/keys"
)

func main() {
	verify := flag.String("verify", "", "file of D-made signatures to check")
	flag.Parse()
	if *verify != "" {
		f, err := os.Open(*verify)
		if err != nil {
			panic(err)
		}
		sc := bufio.NewScanner(f)
		n := 0
		for sc.Scan() {
			p := strings.Split(sc.Text(), " ")
			pub, _ := hex.DecodeString(p[0])
			msg, _ := hex.DecodeString(p[1])
			sig, _ := hex.DecodeString(p[2])
			if !ecc.VerifySignature(ecc.NewDjbECPublicKey([32]byte(pub)), msg, [64]byte(sig)) {
				fmt.Println("BAD", sc.Text())
				os.Exit(1)
			}
			n++
		}
		fmt.Println("ok", n)
		return
	}
	type vec struct{ Pub, Msg, Sig string }
	var out []vec
	for i := 0; i < 16; i++ {
		kp := keys.NewKeyPair()
		msg := make([]byte, i*7)
		rand.Read(msg)
		sig := ecc.CalculateSignature(ecc.NewDjbECPrivateKey(*kp.Priv), msg)
		out = append(out, vec{hex.EncodeToString(kp.Pub[:]), hex.EncodeToString(msg), hex.EncodeToString(sig[:])})
	}
	b, _ := json.MarshalIndent(out, "", " ")
	os.Stdout.Write(b)
}
