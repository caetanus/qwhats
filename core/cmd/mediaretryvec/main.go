// mediaretryvec: whatsmeow's media retry crypto (mediaretry.go) with a fixed IV — vectors for
// wa/mediaretry.d: the encrypted ServerErrorReceipt, and a MediaRetryNotification to decrypt.
package main

import (
	"encoding/hex"
	"fmt"

	"go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/util/gcmutil"
	"go.mau.fi/whatsmeow/util/hkdfutil"
	"google.golang.org/protobuf/proto"
)

func fill(n int, start byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = start + byte(i)
	}
	return b
}

func main() {
	mediaKey := fill(32, 0x10)
	id := "3EB0ABCDEF0123456789"
	key := hkdfutil.SHA256(mediaKey, nil, []byte("WhatsApp Media Retry Notification"), 32)
	fmt.Println("key", hex.EncodeToString(key))
	pt, _ := proto.Marshal(&waMmsRetry.ServerErrorReceipt{StanzaID: proto.String(id)})
	iv := fill(12, 0xa0)
	ct, _ := gcmutil.Encrypt(key, iv, pt, []byte(id))
	fmt.Println("receipt", hex.EncodeToString(ct))
	n, _ := proto.Marshal(&waMmsRetry.MediaRetryNotification{StanzaID: proto.String(id),
		DirectPath: proto.String("/v/t62.7118-24/new-path?ccb=11-4"), Result: waMmsRetry.MediaRetryNotification_SUCCESS.Enum()})
	iv2 := fill(12, 0xb0)
	nct, _ := gcmutil.Encrypt(key, iv2, n, []byte(id))
	fmt.Println("notif", hex.EncodeToString(nct))
}
