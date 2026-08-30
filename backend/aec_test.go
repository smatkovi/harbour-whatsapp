package main

import (
	"math"
	"testing"

	"wa-client/speexdsp"
)

// Synthetic echo: the far end is a tone, the mic hears it attenuated and
// delayed by 40 ms plus a little noise; after adaptation the residual must
// be well below the raw echo.
func TestSpeexAEC(t *testing.T) {
	c, err := speexdsp.New(16000, 320, 6400)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	delay := 640
	var far []float32
	for i := 0; i < 16000*4; i++ {
		far = append(far, 0.5*float32(math.Sin(2*math.Pi*440*float64(i)/16000))*float32(0.5+0.5*math.Sin(float64(i)/900)))
	}
	rawE, cleanE := 0.0, 0.0
	for pos := 0; pos+320 <= len(far)-delay; pos += 320 {
		ref := make([]float32, 320)
		copy(ref, far[pos:pos+320])
		mic := make([]float32, 320)
		for i := range mic {
			src := pos + i - delay
			if src >= 0 {
				mic[i] = 0.3 * far[src]
			}
		}
		if pos > 16000*2 { // measure after two seconds of adaptation
			for _, v := range mic {
				rawE += float64(v * v)
			}
		}
		c.Process(mic, ref)
		if pos > 16000*2 {
			for _, v := range mic {
				cleanE += float64(v * v)
			}
		}
	}
	erle := 10 * math.Log10(rawE/(cleanE+1e-12))
	t.Logf("ERLE after adaptation: %.1f dB", erle)
	if erle < 15 {
		t.Fatalf("echo return loss enhancement only %.1f dB", erle)
	}
}
