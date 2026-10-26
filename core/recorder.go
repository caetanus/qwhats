package main

// Voice notes, recorded here as WhatsApp records them: the microphone (PulseAudio/PipeWire's
// default source) into mono Ogg/Opus, through ffmpeg — which also hands back the sound level ten
// times a second for the waveform the composer shows while recording.

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type recording struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	raw     string // the lossless capture (WAV), processed into the Ogg on stop
	path    string // the final Ogg sent
	denoise string // the denoise filter to apply on stop ("" = none)
	start   time.Time
	done    chan struct{}
}

var (
	recMu  sync.Mutex
	recNow *recording
)

// denoiseModelPath: the RNNoise model to use, or "" to fall back to afftdn. An explicit path from the
// UI wins; otherwise the core looks in <dataDir>/models for bd.rnnn (voice-tuned), then any .rnnn.
func (c *Core) denoiseModelPath(model string) string {
	if model != "" {
		if _, err := os.Stat(model); err == nil {
			return model
		}
		fmt.Fprintln(os.Stderr, "qwhats-core: denoise model not found, using afftdn:", model)
		return ""
	}
	dir := filepath.Join(c.dataDir, "models")
	if p := filepath.Join(dir, "bd.rnnn"); fileExists(p) {
		return p
	}
	if hits, _ := filepath.Glob(filepath.Join(dir, "*.rnnn")); len(hits) > 0 {
		return hits[0]
	}
	return ""
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// denoiseFilter: the noise-reduction stage of the voice chain. "" when off. With an RNNoise model
// (arnndn) — trained on speech, best at hum, fans, keyboard clicks and other voices; else afftdn with
// adaptive tracking, which learns the room's noise floor as the note records and needs nothing to ship.
func denoiseFilter(on bool, model string) string {
	if !on {
		return ""
	}
	if model != "" {
		return "arnndn=m='" + strings.ReplaceAll(model, "'", "") + "':mix=1,"
	}
	return "afftdn=nr=24:nf=-25:tn=1,"
}

func (c *Core) startRecording(denoise bool, modelReq string) (P, error) {
	model := ""
	if denoise {
		model = c.denoiseModelPath(modelReq)
	}
	recMu.Lock()
	defer recMu.Unlock()
	if recNow != nil {
		return nil, errors.New("already recording")
	}
	dir := filepath.Join(c.cacheDir, "outbox")
	os.MkdirAll(dir, 0o700)
	stamp := time.Now().UnixMilli()
	raw := filepath.Join(dir, fmt.Sprintf("voice-%d.raw.wav", stamp))
	path := filepath.Join(dir, fmt.Sprintf("voice-%d.ogg", stamp))
	// The live capture is kept SIMPLE and lossless: the mic, a rumble cut, into a WAV, with the level
	// meter alongside. The evening-out and the noise reduction happen on stop, in a file pass (see
	// stopRecording) — denoisers (arnndn/afftdn) have latency that garbles a real-time capture graph
	// and can truncate the tail; a file pass is reliable and cross-platform (just ffmpeg, no PipeWire).
	stage := "off"
	if denoise {
		stage = "afftdn"
		if model != "" {
			stage = "arnndn " + filepath.Base(model)
		}
	}
	fmt.Fprintf(os.Stderr, "qwhats-core: recording (denoise on stop=%s)\n", stage)
	cmd := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", "default",
		"-filter_complex", "[0:a]aformat=channel_layouts=mono,highpass=f=80,asplit=2[enc][lvl]",
		"-map", "[enc]", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "wav", raw,
		"-map", "[lvl]", "-ar", "8000", "-f", "s16le", "pipe:1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %w", err)
	}
	r := &recording{cmd: cmd, stdin: stdin, raw: raw, path: path, denoise: denoiseFilter(denoise, model), start: time.Now(), done: make(chan struct{})}
	recNow = r
	// the level: the peak of each 100 ms of 8 kHz audio, 0..1
	go func() {
		defer close(r.done)
		br := bufio.NewReaderSize(stdout, 4096)
		buf := make([]byte, 1600)
		for {
			if _, err := io.ReadFull(br, buf); err != nil {
				return
			}
			peak := 0.0
			for i := 0; i+1 < len(buf); i += 2 {
				v := math.Abs(float64(int16(binary.LittleEndian.Uint16(buf[i:]))) / 32768)
				peak = math.Max(peak, v)
			}
			c.emit("Recorder:level", P{"level": math.Min(1, math.Sqrt(peak))})
		}
	}()
	return P{"path": raw}, nil
}

// stopRecording: the file and its length (send), or nothing (the recording is dropped).
func (c *Core) stopRecording(send bool) (P, error) {
	recMu.Lock()
	r := recNow
	recNow = nil
	recMu.Unlock()
	if r == nil {
		return nil, errors.New("not recording")
	}
	io.WriteString(r.stdin, "q") // ffmpeg's own stop: it finishes the WAV
	r.stdin.Close()
	finished := make(chan error, 1)
	go func() { finished <- r.cmd.Wait() }()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		r.cmd.Process.Kill()
		<-finished
	}
	secs := int(math.Round(time.Since(r.start).Seconds()))
	if !send {
		os.Remove(r.raw)
		return P{}, nil
	}
	if st, err := os.Stat(r.raw); err != nil || st.Size() < 1024 {
		os.Remove(r.raw)
		return nil, errors.New("nothing was recorded (no microphone?)")
	}
	// the file pass: the evening-out and the noise reduction, then Opus — reliable, unlike doing it
	// live. WhatsApp sends voice notes as Opus/Ogg; VOIP mode engages Opus's own speech coder.
	// noise reduction, a gentle compressor to even out syllables, then automatic gain control —
	// loudnorm brings the whole note to a fixed loudness (-16 LUFS) whether it was recorded loud or
	// faint, as the browser's AGC does — and a true-peak safety limiter.
	chain := r.denoise +
		"acompressor=threshold=-22dB:ratio=3:attack=5:release=120:makeup=2," +
		"loudnorm=I=-16:TP=-1.5:LRA=11," +
		"alimiter=limit=0.95:level=0"
	// Opus exactly as WhatsApp Web encodes voice notes: mono, 16 kHz, 16 kbps, VOIP mode (its speech
	// coder). Matching this also helps other clients (iPhone) accept the note.
	out, err := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-i", r.raw,
		"-af", chain, "-ar", "16000", "-ac", "1", "-c:a", "libopus", "-b:a", "16k", "-application", "voip",
		"-f", "ogg", r.path).CombinedOutput()
	os.Remove(r.raw)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qwhats-core: voice encode:", err, string(out))
		return nil, fmt.Errorf("could not process the recording: %w", err)
	}
	if st, err := os.Stat(r.path); err != nil || st.Size() == 0 {
		return nil, errors.New("the processed recording is empty")
	}
	return P{"path": r.path, "seconds": max(1, secs)}, nil
}

// waveformOf: a voice note's 64 levels (0..100), as WhatsApp sends with every voice note.
func waveformOf(path string) []byte {
	out, err := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1").Output()
	if err != nil || len(out) < 128 {
		return nil
	}
	n := len(out) / 2
	wf := make([]byte, 64)
	peak := 0.0
	vals := make([]float64, 64)
	for b := 0; b < 64; b++ {
		from, to := b*n/64, (b+1)*n/64
		sum := 0.0
		for i := from; i < to; i++ {
			v := float64(int16(binary.LittleEndian.Uint16(out[2*i:])))
			sum += v * v
		}
		if to > from {
			vals[b] = math.Sqrt(sum / float64(to-from))
		}
		peak = math.Max(peak, vals[b])
	}
	for b := range vals {
		if peak > 0 {
			wf[b] = byte(math.Round(100 * vals[b] / peak))
		}
	}
	return wf
}
