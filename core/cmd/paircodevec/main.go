// paircodevec: whatsmeow's phone-code pairing crypto (pair-code.go: generateCompanionEphemeralKey and
// handleCodePairNotification) with fixed randomness — vectors for wa/paircode.d.
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"fmt"

	"go.mau.fi/whatsmeow/util/hkdfutil"
	"go.mau.fi/whatsmeow/util/keys"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/pbkdf2"
)

var linkingBase32 = base32.NewEncoding("123456789ABCDEFGHJKLMNPQRSTVWXYZ")

func fill(n int, start byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = start + byte(i)
	}
	return b
}

func wrap(code string, salt, iv, pub []byte) []byte {
	key := pbkdf2.Key([]byte(code), salt, 2<<16, 32, sha256.New)
	blk, _ := aes.NewCipher(key)
	enc := append([]byte{}, pub...)
	cipher.NewCTR(blk, iv).XORKeyStream(enc, enc)
	return append(append(append([]byte{}, salt...), iv...), enc...)
}

func main() {
	var priv [32]byte
	copy(priv[:], fill(32, 1))
	eph := keys.NewKeyPairFromPrivateKey(priv)
	code := linkingBase32.EncodeToString(fill(5, 0xa0))
	salt, iv := fill(32, 0x40), fill(16, 0x70)
	fmt.Println("code", code)
	fmt.Println("ephpub", hex.EncodeToString(eph.Pub[:]))
	fmt.Println("wrapped", hex.EncodeToString(wrap(code, salt, iv, eph.Pub[:])))

	// the phone's side
	var ppriv [32]byte
	copy(ppriv[:], fill(32, 0x21))
	primEph := keys.NewKeyPairFromPrivateKey(ppriv)
	primWrapped := wrap(code, fill(32, 0x90), fill(16, 0xc0), primEph.Pub[:])
	var ipriv, pipriv [32]byte
	copy(ipriv[:], fill(32, 0x31))
	copy(pipriv[:], fill(32, 0x51))
	ident := keys.NewKeyPairFromPrivateKey(ipriv)
	primIdent := keys.NewKeyPairFromPrivateKey(pipriv)
	fmt.Println("primwrapped", hex.EncodeToString(primWrapped))
	fmt.Println("identpriv", hex.EncodeToString(ipriv[:]))
	fmt.Println("primidentpub", hex.EncodeToString(primIdent.Pub[:]))

	advRandom, kbSalt, kbNonce := fill(32, 0x11), fill(32, 0x61), fill(12, 0xe0)
	// handleCodePairNotification
	key := pbkdf2.Key([]byte(code), primWrapped[0:32], 2<<16, 32, sha256.New)
	blk, _ := aes.NewCipher(key)
	primPub := make([]byte, 32)
	cipher.NewCTR(blk, primWrapped[32:48]).XORKeyStream(primPub, primWrapped[48:80])
	shared, _ := curve25519.X25519(eph.Priv[:], primPub)
	kbKey := hkdfutil.SHA256(shared, kbSalt, []byte("link_code_pairing_key_bundle_encryption_key"), 32)
	kblk, _ := aes.NewCipher(kbKey)
	gcm, _ := cipher.NewGCM(kblk)
	plain := append(append(append([]byte{}, ident.Pub[:]...), primIdent.Pub[:]...), advRandom...)
	enc := gcm.Seal(nil, kbNonce, plain, nil)
	fmt.Println("bundle", hex.EncodeToString(append(append(append([]byte{}, kbSalt...), kbNonce...), enc...)))
	idShared, _ := curve25519.X25519(ident.Priv[:], primIdent.Pub[:])
	adv := hkdfutil.SHA256(append(append(append([]byte{}, shared...), idShared...), advRandom...), nil, []byte("adv_secret"), 32)
	fmt.Println("adv", hex.EncodeToString(adv))
}
