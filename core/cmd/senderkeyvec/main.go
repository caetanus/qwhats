// senderkeyvec: Signal sender-key (group) vectors from libsignal, both ways.
//   senderkeyvec            libsignal creates a sender key, encrypts 4 group messages; prints the
//                           SKDM + messages (shuffled, to exercise skipped keys) for the D core.
//   senderkeyvec -verify    reads {skdm, messages} made by the D core on stdin and decrypts them
//                           with a real libsignal GroupCipher.
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"go.mau.fi/libsignal/groups"
	"go.mau.fi/libsignal/protocol"
	"go.mau.fi/libsignal/serialize"
	"go.mau.fi/libsignal/tests"
)

type msg struct {
	Serialized string `json:"serialized"`
	Plaintext  string `json:"plaintext"`
}
type vectors struct {
	Note     string `json:"note"`
	SKDM     string `json:"skdm"`
	Messages []msg  `json:"messages"`
}

func serializer() *serialize.Serializer {
	s := serialize.NewSerializer()
	s.SenderKeyMessage = &serialize.ProtoBufSenderKeyMessageSerializer{}
	s.SenderKeyDistributionMessage = &serialize.ProtoBufSenderKeyDistributionMessageSerializer{}
	s.SenderKeyRecord = &serialize.JSONSenderKeySessionSerializer{}
	s.SenderKeyState = &serialize.JSONSenderKeyStateSerializer{}
	return s
}

func main() {
	verify := flag.Bool("verify", false, "decrypt D-made group messages from stdin")
	flag.Parse()
	ctx := context.Background()
	s := serializer()
	store := tests.NewInMemorySenderKey()
	builder := groups.NewGroupSessionBuilder(store, s)
	name := protocol.NewSenderKeyName("120363000000000000@g.us", protocol.NewSignalAddress("alice", 0))
	cipher := groups.NewGroupCipher(builder, name, store)

	if *verify {
		var v vectors
		if err := json.NewDecoder(os.Stdin).Decode(&v); err != nil {
			panic(err)
		}
		raw, _ := hex.DecodeString(v.SKDM)
		skdm, err := protocol.NewSenderKeyDistributionMessageFromBytes(raw, s.SenderKeyDistributionMessage)
		if err != nil {
			fmt.Println("parse skdm:", err)
			os.Exit(1)
		}
		if err := builder.Process(ctx, name, skdm); err != nil {
			fmt.Println("process skdm:", err)
			os.Exit(1)
		}
		for i, m := range v.Messages {
			b, _ := hex.DecodeString(m.Serialized)
			skm, err := protocol.NewSenderKeyMessageFromBytes(b, s.SenderKeyMessage)
			if err != nil {
				fmt.Printf("msg %d parse: %v\n", i, err)
				os.Exit(1)
			}
			pt, err := cipher.Decrypt(ctx, skm)
			if err != nil {
				fmt.Printf("msg %d decrypt: %v\n", i, err)
				os.Exit(1)
			}
			ok := string(pt) == m.Plaintext
			fmt.Printf("msg %d: %v (%q)\n", i, map[bool]string{true: "OK", false: "MISMATCH"}[ok], string(pt))
			if !ok {
				os.Exit(1)
			}
		}
		fmt.Println("all D-made group messages decrypted by libsignal")
		return
	}

	skdm, err := builder.Create(ctx, name)
	if err != nil {
		panic(err)
	}
	plain := []string{"grupo zero", "grupo um", "grupo dois", "grupo tres"}
	var made []msg
	for _, p := range plain {
		ct, err := cipher.Encrypt(ctx, []byte(p))
		if err != nil {
			panic(err)
		}
		made = append(made, msg{hex.EncodeToString(ct.(*protocol.SenderKeyMessage).SignedSerialize()), p})
	}
	order := []int{2, 0, 3, 1}
	v := vectors{Note: "libsignal v0.2.2 sender keys; messages delivered out of order", SKDM: hex.EncodeToString(skdm.Serialize())}
	for _, i := range order {
		v.Messages = append(v.Messages, made[i])
	}
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "  ")
	e.Encode(v)
}
