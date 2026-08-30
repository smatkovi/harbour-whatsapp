//go:build pulselive

package main

// Runs against a real PulseAudio server (any sink, e.g. module-null-sink):
//   go test -tags pulselive -run TestCallAudioLive -v .
// It opens the bridge, pushes a few frames of peer audio through the sink
// and pulls microphone frames from the source, checking that the pull side
// never blocks and always returns full codec frames.

import (
	"testing"
	"time"

	"github.com/purpshell/meowcaller"
)

func TestCallAudioLive(t *testing.T) {
	a, err := openCallAudio(false)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer a.Close()
	sink := a.Sink()
	src := a.Source()

	// Peer audio: a 440 Hz tone, 10 frames
	tone := make([]float32, meowcaller.FrameSamples)
	for i := range tone {
		tone[i] = 0.3 * float32((i*7%100)-50) / 50
	}
	for i := 0; i < 10; i++ {
		if err := sink.WriteFrame(tone); err != nil {
			t.Fatalf("write frame: %v", err)
		}
		time.Sleep(60 * time.Millisecond)
	}

	// Microphone: pulls must be immediate and full-sized
	for i := 0; i < 20; i++ {
		start := time.Now()
		f, err := src.ReadFrame()
		if err != nil {
			t.Fatalf("read frame: %v", err)
		}
		if len(f) != meowcaller.FrameSamples {
			t.Fatalf("frame has %d samples, want %d", len(f), meowcaller.FrameSamples)
		}
		if d := time.Since(start); d > 20*time.Millisecond {
			t.Fatalf("ReadFrame blocked for %v", d)
		}
		time.Sleep(60 * time.Millisecond)
	}
	a.SetMuted(true)
	if f, _ := src.ReadFrame(); len(f) != meowcaller.FrameSamples {
		t.Fatalf("muted frame wrong size")
	}
	a.SetMuted(false)
	if err := a.SetSpeaker(true); err == nil && a.speakerPort == "" {
		t.Fatalf("speaker switch should fail without ports")
	}
	if a.rec == nil || a.play == nil || a.rec.Error() != nil || a.play.Error() != nil {
		t.Fatalf("stream errors: rec=%v play=%v", a.rec.Error(), a.play.Error())
	}
	t.Logf("sink=%q mic backlog=%d spk backlog=%d", a.sinkName, len(a.micBuf), len(a.spkBuf))
}
