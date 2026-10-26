package main

// The WhatsApp Web version we present ourselves as. whatsmeow ships a fixed one that ages; WhatsApp
// answers an old client with 405 ("client too old"). So at start we ask web.whatsapp.com for the
// current one (whatsmeow.GetLatestVersion), keep it in the data directory, and fall back to the last
// one we saw when there is no network.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
)

func useCurrentVersion(dataDir string) {
	file := filepath.Join(dataDir, "wa-version.json")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	v, err := whatsmeow.GetLatestVersion(ctx, &http.Client{Timeout: 10 * time.Second, Transport: chromeTransport{base: http.DefaultTransport}})
	if err == nil && v != nil {
		store.SetWAVersion(*v)
		if b, err := json.Marshal(v); err == nil {
			os.WriteFile(file, b, 0o600)
		}
		fmt.Fprintln(os.Stderr, "qwhats-core: WhatsApp Web version", v.String())
		return
	}
	var saved store.WAVersionContainer
	if b, rerr := os.ReadFile(file); rerr == nil && json.Unmarshal(b, &saved) == nil && !saved.IsZero() {
		if saved.LessThan(store.GetWAVersion()) {
			saved = store.GetWAVersion()
		}
		store.SetWAVersion(saved)
		fmt.Fprintln(os.Stderr, "qwhats-core: WhatsApp Web version (saved)", saved.String(), "—", err)
		return
	}
	fmt.Fprintln(os.Stderr, "qwhats-core: WhatsApp Web version (built in)", store.GetWAVersion().String(), "—", err)
}
