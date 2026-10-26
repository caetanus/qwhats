// signalvec: authoritative Signal-protocol vectors from libsignal (exactly what WhatsApp and
// whatsmeow use), for the D core's receive path. We play Alice, encrypt a few messages to Bob
// through a real SessionCipher, and dump Bob's private key material plus the wire bytes. The D
// side loads Bob's keys, runs the receiver X3DH + ratchet, and must recover the plaintexts.
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"os"

	"go.mau.fi/libsignal/keys/identity"
	"go.mau.fi/libsignal/keys/prekey"
	"go.mau.fi/libsignal/protocol"
	"go.mau.fi/libsignal/serialize"
	"go.mau.fi/libsignal/session"
	"go.mau.fi/libsignal/state/record"
	"go.mau.fi/libsignal/tests"
	"go.mau.fi/libsignal/util/keyhelper"
)

func h(b []byte) string { return hex.EncodeToString(b) }

type user struct {
	deviceID        uint32
	address         *protocol.SignalAddress
	identityKeyPair *identity.KeyPair
	registrationID  uint32
	preKeys         []*record.PreKey
	signedPreKey    *record.SignedPreKey
	sessionStore    *tests.InMemorySession
	preKeyStore     *tests.InMemoryPreKey
	signedStore     *tests.InMemorySignedPreKey
	identityStore   *tests.InMemoryIdentityKey
	builder         *session.Builder
}

func newUser(name string, deviceID uint32, s *serialize.Serializer) *user {
	ctx := context.Background()
	u := &user{deviceID: deviceID}
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

func (u *user) buildSession(remote *protocol.SignalAddress, s *serialize.Serializer) {
	u.builder = session.NewBuilder(u.sessionStore, u.preKeyStore, u.signedStore, u.identityStore, remote, s)
}

type msgVec struct {
	Type       uint32 `json:"type"`
	Serialized string `json:"serialized"`
	Plaintext  string `json:"plaintext"`
}

type vectors struct {
	Note              string   `json:"note"`
	BobRegistrationID uint32   `json:"bobRegistrationId"`
	BobIdentityPriv   string   `json:"bobIdentityPriv"`
	BobIdentityPub    string   `json:"bobIdentityPub"`
	BobSignedPreKeyID uint32   `json:"bobSignedPreKeyId"`
	BobSignedPriv     string   `json:"bobSignedPreKeyPriv"`
	BobSignedPub      string   `json:"bobSignedPreKeyPub"`
	BobPreKeyID       uint32   `json:"bobPreKeyId"`
	BobPreKeyPriv     string   `json:"bobPreKeyPriv"`
	BobPreKeyPub      string   `json:"bobPreKeyPub"`
	AliceIdentityPub  string   `json:"aliceIdentityPub"`
	Messages          []msgVec `json:"messages"`
}

func main() {
	ctx := context.Background()
	s := serialize.NewSerializer()
	s.SignalMessage = &serialize.ProtoBufSignalMessageSerializer{}
	s.PreKeySignalMessage = &serialize.ProtoBufPreKeySignalMessageSerializer{}
	s.SignedPreKeyRecord = &serialize.JSONSignedPreKeyRecordSerializer{}
	s.PreKeyRecord = &serialize.JSONPreKeyRecordSerializer{}
	s.State = &serialize.JSONStateSerializer{}
	s.Session = &serialize.JSONSessionSerializer{}

	alice := newUser("Alice", 1, s)
	bob := newUser("Bob", 2, s)
	alice.buildSession(bob.address, s)

	bundle := prekey.NewBundle(
		bob.registrationID, bob.deviceID,
		bob.preKeys[0].ID(), bob.signedPreKey.ID(),
		bob.preKeys[0].KeyPair().PublicKey(),
		bob.signedPreKey.KeyPair().PublicKey(),
		bob.signedPreKey.Signature(),
		bob.identityKeyPair.PublicKey(),
	)
	if err := alice.builder.ProcessBundle(ctx, bundle); err != nil {
		panic(err)
	}
	cipher := session.NewCipher(alice.builder, bob.address)

	plaintexts := []string{"ola, esse e o primeiro teste", "segunda mensagem", "terceira"}
	var msgs []msgVec
	for _, p := range plaintexts {
		cm, err := cipher.Encrypt(ctx, []byte(p))
		if err != nil {
			panic(err)
		}
		msgs = append(msgs, msgVec{Type: cm.Type(), Serialized: h(cm.Serialize()), Plaintext: p})
	}

	bobIdPriv := bob.identityKeyPair.PrivateKey().Serialize()
	bobIdPub := bob.identityKeyPair.PublicKey().PublicKey().PublicKey()
	bobSPriv := bob.signedPreKey.KeyPair().PrivateKey().Serialize()
	bobSPub := bob.signedPreKey.KeyPair().PublicKey().PublicKey()
	bobPPriv := bob.preKeys[0].KeyPair().PrivateKey().Serialize()
	bobPPub := bob.preKeys[0].KeyPair().PublicKey().PublicKey()
	aliceIdPub := alice.identityKeyPair.PublicKey().PublicKey().PublicKey()

	v := vectors{
		Note:              "libsignal v0.2.2 — Alice->Bob, 3 PreKeySignalMessages; D plays Bob and decrypts",
		BobRegistrationID: bob.registrationID,
		BobIdentityPriv:   h(bobIdPriv[:]),
		BobIdentityPub:    h(bobIdPub[:]),
		BobSignedPreKeyID: bob.signedPreKey.ID(),
		BobSignedPriv:     h(bobSPriv[:]),
		BobSignedPub:      h(bobSPub[:]),
		BobPreKeyID:       bob.preKeys[0].ID().Value,
		BobPreKeyPriv:     h(bobPPriv[:]),
		BobPreKeyPub:      h(bobPPub[:]),
		AliceIdentityPub:  h(aliceIdPub[:]),
		Messages:          msgs,
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
}
