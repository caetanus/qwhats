// signalsend: the reverse cross-check of signalvec. We build Bob (libsignal), hand the D core
// (wa-vectool) Bob's pre-key bundle plus some plaintexts, and let D start a session and encrypt
// them. We then decrypt D's output with a real libsignal SessionCipher. If every plaintext comes
// back, our sender X3DH + ratchet + wire format is exactly what a WhatsApp client accepts.
package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"

	"go.mau.fi/libsignal/keys/identity"
	"go.mau.fi/libsignal/protocol"
	"go.mau.fi/libsignal/serialize"
	"go.mau.fi/libsignal/session"
	"go.mau.fi/libsignal/state/record"
	"go.mau.fi/libsignal/tests"
	"go.mau.fi/libsignal/util/keyhelper"
)

type user struct {
	identityKeyPair *identity.KeyPair
	registrationID  uint32
	preKeys         []*record.PreKey
	signedPreKey    *record.SignedPreKey
	sessionStore    *tests.InMemorySession
	preKeyStore     *tests.InMemoryPreKey
	signedStore     *tests.InMemorySignedPreKey
	identityStore   *tests.InMemoryIdentityKey
	builder         *session.Builder
	address         *protocol.SignalAddress
}

func newUser(name string, deviceID uint32, s *serialize.Serializer) *user {
	ctx := context.Background()
	u := &user{}
	u.identityKeyPair, _ = keyhelper.GenerateIdentityKeyPair()
	u.registrationID = keyhelper.GenerateRegistrationID()
	u.preKeys, _ = keyhelper.GeneratePreKeys(1, 10, s.PreKeyRecord)
	u.signedPreKey, _ = keyhelper.GenerateSignedPreKey(u.identityKeyPair, 0, s.SignedPreKeyRecord)
	u.sessionStore = tests.NewInMemorySession(s)
	u.preKeyStore = tests.NewInMemoryPreKey()
	u.signedStore = tests.NewInMemorySignedPreKey()
	u.identityStore = tests.NewInMemoryIdentityKey(u.identityKeyPair, u.registrationID)
	for i := range u.preKeys {
		u.preKeyStore.StorePreKey(ctx, u.preKeys[i].ID().Value,
			record.NewPreKey(u.preKeys[i].ID().Value, u.preKeys[i].KeyPair(), s.PreKeyRecord))
	}
	u.signedStore.StoreSignedPreKey(ctx, u.signedPreKey.ID(),
		record.NewSignedPreKey(u.signedPreKey.ID(), u.signedPreKey.Timestamp(),
			u.signedPreKey.KeyPair(), u.signedPreKey.Signature(), s.SignedPreKeyRecord))
	u.address = protocol.NewSignalAddress(name, deviceID)
	return u
}

type bundleJSON struct {
	RegistrationID        uint32   `json:"registrationId"`
	IdentityKey           string   `json:"identityKey"`
	SignedPreKeyID        uint32   `json:"signedPreKeyId"`
	SignedPreKey          string   `json:"signedPreKey"`
	SignedPreKeySignature string   `json:"signedPreKeySignature"`
	HasOneTime            bool     `json:"hasOneTime"`
	PreKeyID              uint32   `json:"preKeyId"`
	PreKey                string   `json:"preKey"`
	Plaintexts            []string `json:"plaintexts"`
}

type msgOut struct {
	Type       uint32 `json:"type"`
	Serialized string `json:"serialized"`
}
type vectoolOut struct {
	Messages []msgOut `json:"messages"`
}

func h(b []byte) string { return hex.EncodeToString(b) }

func main() {
	ctx := context.Background()
	s := serialize.NewSerializer()
	s.SignalMessage = &serialize.ProtoBufSignalMessageSerializer{}
	s.PreKeySignalMessage = &serialize.ProtoBufPreKeySignalMessageSerializer{}
	s.SignedPreKeyRecord = &serialize.JSONSignedPreKeyRecordSerializer{}
	s.PreKeyRecord = &serialize.JSONPreKeyRecordSerializer{}
	s.State = &serialize.JSONStateSerializer{}
	s.Session = &serialize.JSONSessionSerializer{}

	bob := newUser("Bob", 2, s)
	alice := protocol.NewSignalAddress("Alice", 1)

	sig := bob.signedPreKey.Signature()
	bobSPub := bob.signedPreKey.KeyPair().PublicKey().PublicKey()
	bobIdPub := bob.identityKeyPair.PublicKey().PublicKey().PublicKey()
	bobPPub := bob.preKeys[0].KeyPair().PublicKey().PublicKey()

	plaintexts := []string{"nossa primeira mensagem", "e a segunda", "terceira do nosso stack"}
	bj := bundleJSON{
		RegistrationID:        bob.registrationID,
		IdentityKey:           h(bobIdPub[:]),
		SignedPreKeyID:        bob.signedPreKey.ID(),
		SignedPreKey:          h(bobSPub[:]),
		SignedPreKeySignature: h(sig[:]),
		HasOneTime:            true,
		PreKeyID:              bob.preKeys[0].ID().Value,
		PreKey:                h(bobPPub[:]),
		Plaintexts:            plaintexts,
	}
	in, _ := json.Marshal(bj)

	vectool := "/home/caetano/.cache/qml-whats-build/wa-vectool/wa-vectool"
	cmd := exec.Command(vectool)
	cmd.Stdin = bytes.NewReader(in)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "running wa-vectool:", err)
		os.Exit(1)
	}
	var vo vectoolOut
	if err := json.Unmarshal(out, &vo); err != nil {
		fmt.Fprintln(os.Stderr, "parsing wa-vectool output:", err, string(out))
		os.Exit(1)
	}

	bobCipher := session.NewCipher(
		session.NewBuilder(bob.sessionStore, bob.preKeyStore, bob.signedStore, bob.identityStore, alice, s),
		alice,
	)

	for i, m := range vo.Messages {
		raw, _ := hex.DecodeString(m.Serialized)
		var plain []byte
		switch m.Type {
		case 3:
			pk, e := protocol.NewPreKeySignalMessageFromBytes(raw, s.PreKeySignalMessage, s.SignalMessage)
			if e != nil {
				fmt.Fprintln(os.Stderr, "parse prekey msg:", e)
				os.Exit(1)
			}
			plain, err = bobCipher.DecryptMessage(ctx, pk)
		case 2:
			sm, e := protocol.NewSignalMessageFromBytes(raw, s.SignalMessage)
			if e != nil {
				fmt.Fprintln(os.Stderr, "parse signal msg:", e)
				os.Exit(1)
			}
			plain, err = bobCipher.Decrypt(ctx, sm)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "decrypt message %d: %v\n", i, err)
			os.Exit(1)
		}
		// libsignal returns the padded WhatsApp plaintext; strip the v2 pad to compare
		unp := plain
		if n := int(plain[len(plain)-1]); n > 0 && n <= len(plain) {
			unp = plain[:len(plain)-n]
		}
		got := string(unp)
		want := plaintexts[i]
		status := "OK"
		if got != want {
			status = "MISMATCH"
		}
		fmt.Printf("msg %d (type %d): %s  decrypted=%q want=%q\n", i, m.Type, status, got, want)
		if got != want {
			os.Exit(1)
		}
	}
	fmt.Println("all messages from the D core decrypted by libsignal — sender path verified")
}
