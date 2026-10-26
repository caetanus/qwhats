package main

// We present ourselves as WhatsApp Web in Google Chrome on Linux, not as a client of our own:
// the device props WhatsApp Web sends when a browser links (WAWebClientPayload: os, the browser's
// version, platformType from WAWebCompanionPlatformType — CHROME for Chrome), the name a phone-code
// pairing shows, and Chrome's User-Agent on every HTTP request, the websocket included.

import (
	"net/http"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"google.golang.org/protobuf/proto"
)

const (
	chromeMajor = 148
	chromeUA    = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
	chromeOS    = "Linux QWhats"          // the phone lists us as "Google Chrome (<os>)": the user wants the app named there
	chromeName  = "Chrome (Linux QWhats)" // what a phone-code pairing shows, as WhatsApp Web's "<browser> (<os>)"
)

func init() {
	store.DeviceProps.Os = proto.String(chromeOS)
	store.DeviceProps.Version = &waCompanionReg.DeviceProps_AppVersion{
		Primary: proto.Uint32(chromeMajor), Secondary: proto.Uint32(0), Tertiary: proto.Uint32(0)}
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	// Chrome on Linux reports its UA platform and the user's language; we are in Brazil
	store.BaseClientPayload.UserAgent.LocaleLanguageIso6391 = proto.String("pt")
	store.BaseClientPayload.UserAgent.LocaleCountryIso31661Alpha2 = proto.String("BR")
}

// chromeTransport: Chrome's User-Agent on every request that does not set one.
type chromeTransport struct{ base http.RoundTripper }

func (t chromeTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Header.Get("User-Agent") == "" || r.Header.Get("User-Agent") == "Go-http-client/1.1" {
		r = r.Clone(r.Context())
		r.Header.Set("User-Agent", chromeUA)
	}
	return t.base.RoundTrip(r)
}

var chromeHTTP = &http.Client{Transport: chromeTransport{base: http.DefaultTransport}}

// asChrome: whatsmeow's HTTP clients (websocket, media, pre-login) and its media User-Agent.
func asChrome(c *whatsmeow.Client) {
	c.UserAgent = chromeUA
	// the first full app-state sync carries contacts' names, pins, archives, mutes: WhatsApp Web
	// applies it, so we want its events too (whatsmeow keeps them quiet by default)
	c.EmitAppStateEventsOnFullSync = true
	c.SetWebsocketHTTPClient(&http.Client{Transport: chromeTransport{base: http.DefaultTransport}})
	c.SetMediaHTTPClient(&http.Client{Transport: chromeTransport{base: http.DefaultTransport}})
	c.SetPreLoginHTTPClient(&http.Client{Transport: chromeTransport{base: http.DefaultTransport}})
}
