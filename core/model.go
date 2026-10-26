package main

// The models the core hands out: WhatsApp Web's own (WAWebMsgModel, WAWebChatModel,
// WAWebContactModel, WAWebGroupMetadataModel, WAWebPresenceModel), with WhatsApp Web's field names,
// reduced to what a client renders (docs/native-client.md, docs/whatsapp-web-api-map.md §06).

import (
	"strings"

	"go.mau.fi/whatsmeow/types"
)

// Ack: WAWebAck.ACK.
const (
	AckFailed   = -1
	AckClock    = 0
	AckSent     = 1
	AckReceived = 2
	AckRead     = 3
	AckPlayed   = 4
)

type QuotedMsg struct {
	ID         string `json:"id"`
	Type       string `json:"type,omitempty"`
	Body       string `json:"body,omitempty"`
	Author     string `json:"author,omitempty"`
	AuthorName string `json:"authorName,omitempty"` // handed out, not stored ("Você" for mine)
}

type MediaData struct {
	MediaStage    string `json:"mediaStage"` // INIT, FETCHING, RESOLVED, NEED_POKE, ERROR_MISSING
	Mimetype      string `json:"mimetype,omitempty"`
	Size          uint64 `json:"size,omitempty"`
	Filename      string `json:"filename,omitempty"`
	Duration      uint32 `json:"duration,omitempty"`
	Width         uint32 `json:"width,omitempty"`
	Height        uint32 `json:"height,omitempty"`
	Preview       string `json:"preview,omitempty"`  // base64 JPEG thumbnail, as WhatsApp sends it inline
	Waveform      string `json:"waveform,omitempty"` // base64, 64 samples (voice notes)
	IsGif         bool   `json:"isGif,omitempty"`
	IsViewOnce    bool   `json:"isViewOnce,omitempty"`
	PageCount     uint32 `json:"pageCount,omitempty"`
	IsAnimated    bool   `json:"isAnimated,omitempty"`
	RenderableURL string `json:"renderableUrl,omitempty"` // the decrypted file, once downloaded
	ThumbnailHQ   string `json:"thumbnailHQ,omitempty"`   // WhatsApp's high-quality thumbnail, once fetched
}

type Reaction struct {
	AggregateEmoji  string   `json:"aggregateEmoji"`
	Senders         []string `json:"senders"`
	HasReactionByMe bool     `json:"hasReactionByMe"`
}

type Vcard struct {
	DisplayName string `json:"displayName"`
	Vcard       string `json:"vcard"`
}

type PollOption struct {
	LocalID int    `json:"localId"`
	Name    string `json:"name"`
}

type Msg struct {
	ID         string `json:"id"` // fromMe_remote_id[_participant]
	Account    string `json:"account"`
	Remote     string `json:"remote"`
	MsgID      string `json:"msgId"` // the bare WhatsApp id
	From       string `json:"from"`
	To         string `json:"to"`
	Author     string `json:"author,omitempty"`
	FromMe     bool   `json:"fromMe"`
	T          int64  `json:"t"`
	Type       string `json:"type"`
	Subtype    string `json:"subtype,omitempty"`
	Ack        int    `json:"ack"`
	NotifyName string `json:"notifyName,omitempty"`
	SenderName string `json:"senderName,omitempty"` // filled when handed out, not stored
	ChatName   string `json:"chatName,omitempty"`   // handed out by the panels (calls, media), not stored
	SenderPic  string `json:"senderPic,omitempty"`  // the sender's profile picture (voice notes), handed out
	// group messages, handed out: the number of a sender outside the address book, and the role
	// WhatsApp Web shows under the name ("Admin da comunidade")
	SenderPhone string `json:"senderPhone,omitempty"`
	SenderRole  string `json:"senderRole,omitempty"`

	Body             string     `json:"body,omitempty"`
	Caption          string     `json:"caption,omitempty"`
	QuotedMsg        *QuotedMsg `json:"quotedMsg,omitempty"`
	QuotedRemoteJid  string     `json:"quotedRemoteJid,omitempty"`
	MentionedJidList []string   `json:"mentionedJidList,omitempty"`
	IsForwarded      bool       `json:"isForwarded,omitempty"`
	ForwardingScore  uint32     `json:"forwardingScore,omitempty"`
	Star             bool       `json:"star,omitempty"`
	IsEdited         bool       `json:"isEdited,omitempty"`
	LatestEditT      int64      `json:"latestEditSenderTimestamp,omitempty"`
	RevokeSender     string     `json:"revokeSender,omitempty"`
	Reactions        []Reaction `json:"reactions,omitempty"`
	MediaData        *MediaData `json:"mediaData,omitempty"`
	TemplateParams   []string   `json:"templateParams,omitempty"` // system rows: who / what
	TemplateNames    []string   `json:"templateNames,omitempty"`  // the same, as names (handed out, not stored)

	MatchedText string `json:"matchedText,omitempty"`
	// a text status's look (ExtendedTextMessage.backgroundArgb / textArgb / font), "#AARRGGBB"
	BackgroundColor string `json:"backgroundColor,omitempty"`
	TextColor       string `json:"textColor,omitempty"`
	Font            int    `json:"font,omitempty"`
	Viewed          bool   `json:"viewed,omitempty"` // a status this account has seen
	Title           string `json:"title,omitempty"`
	Description     string `json:"description,omitempty"`
	Thumbnail       string `json:"thumbnail,omitempty"`
	// a link preview's large picture (WhatsApp Web's big preview): there is one to fetch (linkHQ),
	// its size, the preview's kind (VIDEO draws a play button), and the file once fetched
	LinkHQ      bool   `json:"linkHQ,omitempty"`
	ThumbWidth  int    `json:"thumbWidth,omitempty"`
	ThumbHeight int    `json:"thumbHeight,omitempty"`
	PreviewType string `json:"previewType,omitempty"`
	LinkThumb   string `json:"linkThumb,omitempty"`

	// a business's message with buttons (buttons, template, interactive, list messages): the footer
	// line under the text, and the buttons drawn under the bubble
	Footer  string   `json:"footer,omitempty"`
	Buttons []Button `json:"buttons,omitempty"`

	Lat    float64 `json:"lat,omitempty"`
	Lng    float64 `json:"lng,omitempty"`
	Loc    string  `json:"loc,omitempty"`
	IsLive bool    `json:"isLive,omitempty"`

	VcardList []Vcard `json:"vcardList,omitempty"`

	PollName                   string       `json:"pollName,omitempty"`
	PollOptions                []PollOption `json:"pollOptions,omitempty"`
	PollSelectableOptionsCount uint32       `json:"pollSelectableOptionsCount,omitempty"`

	EphemeralDuration uint32 `json:"ephemeralDuration,omitempty"`
	ExpiredTimestamp  int64  `json:"expiredTimestamp,omitempty"`

	CallOutcome  string `json:"callOutcome,omitempty"`
	IsVideoCall  bool   `json:"isVideoCall,omitempty"`
	CallDuration uint32 `json:"callDuration,omitempty"`

	IsMdHistoryMsg bool `json:"isMdHistoryMsg,omitempty"`

	// channel (newsletter) messages: the counts WhatsApp shows under them
	NewsletterReactions []NewsletterReaction `json:"newsletterReactions,omitempty"`
	ForwardsCount       int                  `json:"forwardsCount,omitempty"`
	ViewsCount          int                  `json:"viewsCount,omitempty"`
}

type NewsletterReaction struct {
	Emoji string `json:"emoji"`
	Count int    `json:"count"`
}

// An add-on: a message that changes another one (WhatsApp Web keeps them in their own tables,
// keyed by the parent). Kind: reaction, edit, revoke.
type Addon struct {
	Kind     string
	ParentID string // the bare id of the target, in the same chat
	Sender   string
	FromMe   bool
	Text     string // reaction emoji, or the edited text
	Edited   *Msg   // edit: the new content
	T        int64
}

type LastMsg struct {
	ID         string `json:"id"`
	Type       string `json:"type"`
	Subtype    string `json:"subtype,omitempty"`
	Body       string `json:"body"`
	FromMe     bool   `json:"fromMe"`
	Author     string `json:"author,omitempty"`
	SenderName string `json:"senderName,omitempty"`
	Ack        int    `json:"ack"`
	T          int64  `json:"t"`
}

type Chat struct {
	ID                       string   `json:"id"`
	Account                  string   `json:"account"`
	Kind                     string   `json:"kind"`
	Name                     string   `json:"name"`
	T                        int64    `json:"t"`
	UnreadCount              int      `json:"unreadCount"`
	UnreadMentionCount       int      `json:"unreadMentionCount"`
	MarkedUnread             bool     `json:"markedUnread"`
	Archive                  bool     `json:"archive"`
	Pin                      int64    `json:"pin"`
	MuteExpiration           int64    `json:"muteExpiration"`
	IsReadOnly               bool     `json:"isReadOnly"`
	IsAnnounceGrpRestrict    bool     `json:"isAnnounceGrpRestrict"`
	EphemeralDuration        uint32   `json:"ephemeralDuration"`
	EndOfHistoryTransferType int      `json:"endOfHistoryTransferType"`
	DraftMessage             string   `json:"draftMessage,omitempty"`
	Unknown                  bool     `json:"unknown,omitempty"`         // a 1:1 contact not in the address book
	ProfilePicThumb          string   `json:"profilePicThumb,omitempty"` // a local file once fetched
	Subscribers              int      `json:"subscribers,omitempty"`     // channels: followers
	ParentGroup              string   `json:"parentGroup,omitempty"`     // a community's group: the community
	ParentPic                string   `json:"parentPic,omitempty"`       // … and its picture
	IsAnnounceGroup          bool     `json:"isAnnounceGroup,omitempty"` // the community's "Avisos" group
	PinnedMsg                *LastMsg `json:"pinnedMsg,omitempty"`       // the message pinned in the chat
	LastMsg                  *LastMsg `json:"lastMsg,omitempty"`
}

type Contact struct {
	ID               string `json:"id"`
	Account          string `json:"account"`
	Name             string `json:"name,omitempty"`
	ShortName        string `json:"shortName,omitempty"`
	Pushname         string `json:"pushname,omitempty"`
	VerifiedName     string `json:"verifiedName,omitempty"`
	IsBusiness       bool   `json:"isBusiness,omitempty"`
	IsContactBlocked bool   `json:"isContactBlocked,omitempty"`
	PhoneNumber      string `json:"phoneNumber,omitempty"`
	Status           string `json:"status,omitempty"`
	ProfilePicThumb  string `json:"profilePicThumb,omitempty"`
	FormattedName    string `json:"formattedName"`
}

type Participant struct {
	ID           string `json:"id"`
	Name         string `json:"name,omitempty"` // handed out, not stored
	IsMe         bool   `json:"isMe,omitempty"`
	IsAdmin      bool   `json:"isAdmin"`
	IsSuperAdmin bool   `json:"isSuperAdmin"`
}

type GroupMetadata struct {
	ID                string        `json:"id"`
	Account           string        `json:"account"`
	Subject           string        `json:"subject"`
	SubjectTime       int64         `json:"subjectTime,omitempty"`
	Desc              string        `json:"desc,omitempty"`
	Owner             string        `json:"owner,omitempty"`
	Creation          int64         `json:"creation,omitempty"`
	Restrict          bool          `json:"restrict"`
	Announce          bool          `json:"announce"`
	EphemeralDuration uint32        `json:"ephemeralDuration"`
	Size              int           `json:"size"`
	IsParentGroup     bool          `json:"isParentGroup"`
	ParentGroup       string        `json:"parentGroup,omitempty"`
	Participants      []Participant `json:"participants"`
}

type Presence struct {
	ID               string   `json:"id"`
	Account          string   `json:"account"`
	IsOnline         bool     `json:"isOnline"`
	T                int64    `json:"t,omitempty"`
	Deny             bool     `json:"deny,omitempty"`
	TypingUserIds    []string `json:"typingUserIds"`
	RecordingUserIds []string `json:"recordingUserIds"`
}

// msgKey: WAWebMsgKey serialised — fromMe_remote_id, plus _participant for others' group messages.
func msgKey(fromMe bool, remote, id, participant string) string {
	k := "false_"
	if fromMe {
		k = "true_"
	}
	k += remote + "_" + id
	if participant != "" && !fromMe && strings.HasSuffix(remote, "@"+types.GroupServer) {
		k += "_" + participant
	}
	return k
}

// parseKey: the parts of a message key (remote, bare id).
func parseKey(k string) (fromMe bool, remote, id, participant string, ok bool) {
	parts := strings.Split(k, "_")
	if len(parts) < 3 {
		return false, "", "", "", false
	}
	fromMe = parts[0] == "true"
	remote, id = parts[1], parts[2]
	if len(parts) > 3 {
		participant = parts[3]
	}
	return fromMe, remote, id, participant, true
}

// chatKind: Chat.kind from the Wid's server (WhatsApp Web derives it the same way).
func chatKind(jid string, isParent bool) string {
	switch {
	case strings.HasSuffix(jid, "@"+types.GroupServer):
		if isParent {
			return "community"
		}
		return "group"
	case strings.HasSuffix(jid, "@"+types.BroadcastServer):
		return "broadcast"
	case strings.HasSuffix(jid, "@"+types.NewsletterServer):
		return "newsletter"
	}
	return "user"
}

// Button: one of a message's buttons. Kind: reply (sends its text back), url, call, copy, list
// (Value: the list's rows, one per line).
type Button struct {
	Kind  string `json:"kind"`
	Text  string `json:"text"`
	Value string `json:"value,omitempty"`
}
