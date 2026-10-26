package main

import (
	"os"
	"testing"
)

// WAVE_FILE=<a voice note>: its waveform has 64 levels, the loudest at 100.
func TestWaveformOf(t *testing.T) {
	f := os.Getenv("WAVE_FILE")
	if f == "" {
		t.Skip("WAVE_FILE not set")
	}
	wf := waveformOf(f)
	if len(wf) != 64 {
		t.Fatalf("got %d levels", len(wf))
	}
	top := byte(0)
	for _, v := range wf {
		top = max(top, v)
	}
	if top != 100 {
		t.Fatalf("loudest %d", top)
	}
	t.Log(wf)
}
