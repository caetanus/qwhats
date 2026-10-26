// actionvec: the message menu's Message protobufs as whatsmeow builds them (BuildMessageKey,
// BuildReaction, BuildRevoke, BuildEdit, the core's pin), with fixed times — vectors for wa/actions.d.
package main

import (
	"encoding/hex"
	"fmt"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

func main() {
	own := types.NewADJID("5511999990000", 0, 3)
	lid := types.NewADJID("111222333444555", 1, 3)
	cli := whatsmeow.NewClient(&store.Device{ID: &own, LID: lid}, waLog.Noop)
	const ms = int64(1700000000123)
	dm := types.NewJID("5511900000001", types.DefaultUserServer)
	grp := types.NewJID("120363000000000001", types.GroupServer)
	cases := []struct {
		name         string
		chat, sender types.JID
	}{
		{"own-dm", dm, own.ToNonAD()},
		{"their-dm", dm, dm},
		{"their-group", grp, types.NewADJID("5511900000002", 0, 5)},
		{"lid-group", grp, types.NewJID("987654321098765", types.HiddenUserServer)},
		{"own-lid-group", grp, lid.ToNonAD()},
	}
	out := func(name string, m proto.Message) {
		b, err := proto.Marshal(m)
		if err != nil {
			panic(err)
		}
		fmt.Println(name, hex.EncodeToString(b))
	}
	for _, c := range cases {
		key := cli.BuildMessageKey(c.chat, c.sender, "3EB0ABCDEF")
		out(c.name+"/key", key)
		r := cli.BuildReaction(c.chat, c.sender, "3EB0ABCDEF", "👍")
		r.ReactionMessage.SenderTimestampMS = proto.Int64(ms)
		out(c.name+"/react", r)
		u := cli.BuildReaction(c.chat, c.sender, "3EB0ABCDEF", "")
		u.ReactionMessage.SenderTimestampMS = proto.Int64(ms)
		out(c.name+"/unreact", u)
		out(c.name+"/revoke", cli.BuildRevoke(c.chat, c.sender, "3EB0ABCDEF"))
		for _, pin := range []bool{true, false} {
			typ := waE2E.PinInChatMessage_PIN_FOR_ALL
			n := "/pin"
			if !pin {
				typ, n = waE2E.PinInChatMessage_UNPIN_FOR_ALL, "/unpin"
			}
			out(c.name+n, &waE2E.Message{
				PinInChatMessage:   &waE2E.PinInChatMessage{Key: key, Type: typ.Enum(), SenderTimestampMS: proto.Int64(ms)},
				MessageContextInfo: &waE2E.MessageContextInfo{MessageAddOnDurationInSecs: proto.Uint32(86400)},
			})
		}
	}
	e := cli.BuildEdit(dm, "3EB0ABCDEF", &waE2E.Message{Conversation: proto.String("texto novo ✏️")})
	e.EditedMessage.Message.ProtocolMessage.TimestampMS = proto.Int64(ms)
	out("edit", e)
}
