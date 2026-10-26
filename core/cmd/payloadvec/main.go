// payloadvec: rebuilds, with whatsmeow, the registration ClientPayload the D protocol wrote (same
// keys, the core's Chrome identity) and says whether the bytes match. Input: the JSON the D test
// writes with WA_PAYLOADOUT.
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/util/keys"
	"google.golang.org/protobuf/proto"
)

func main() {
	var in struct {
		Identity, SkeyPub, SkeySig, Payload string
		RegID, SkeyID                       uint32
	}
	b, _ := os.ReadFile(os.Args[1])
	if err := json.Unmarshal(b, &in); err != nil {
		panic(err)
	}
	store.DeviceProps.Os = proto.String("DQWhats")
	store.DeviceProps.Version = &waCompanionReg.DeviceProps_AppVersion{Primary: proto.Uint32(148), Secondary: proto.Uint32(0), Tertiary: proto.Uint32(0)}
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	store.BaseClientPayload.UserAgent.LocaleLanguageIso6391 = proto.String("pt")
	store.BaseClientPayload.UserAgent.LocaleCountryIso31661Alpha2 = proto.String("BR")
	store.SetWAVersion(store.WAVersionContainer{2, 3000, 1051155679})

	h := func(s string) []byte { x, _ := hex.DecodeString(s); return x }
	var id, sk [32]byte
	copy(id[:], h(in.Identity))
	copy(sk[:], h(in.SkeyPub))
	var sig [64]byte
	copy(sig[:], h(in.SkeySig))
	dev := &store.Device{
		RegistrationID: in.RegID,
		IdentityKey:    &keys.KeyPair{Pub: &id},
		SignedPreKey:   &keys.PreKey{KeyPair: keys.KeyPair{Pub: &sk}, KeyID: in.SkeyID, Signature: &sig},
	}
	want, err := proto.MarshalOptions{Deterministic: true}.Marshal(dev.GetClientPayload())
	if err != nil {
		panic(err)
	}
	if bytes.Equal(want, h(in.Payload)) {
		fmt.Println("match", len(want), "bytes")
		return
	}
	fmt.Println("DIFFER\n want", hex.EncodeToString(want), "\n got ", in.Payload)
	os.Exit(1)
}
