// Package speexdsp wraps the echo canceller and preprocessor of Xiph's
// speexdsp (BSD licence, vendored here - see LICENSE) for the voice call
// path. Built with cgo like SQLCipher, so the static three-arch build is
// unchanged. Float build with the bundled kiss FFT, no dependencies.
package speexdsp

/*
#cgo CFLAGS: -I${SRCDIR}/include -I${SRCDIR} -DFLOATING_POINT -DUSE_KISS_FFT -DEXPORT= -DVAR_ARRAYS -DHAVE_STDINT_H -Wno-unused-function -Wno-unused-variable
#cgo LDFLAGS: -lm
#include <stdlib.h>
#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"
*/
import "C"

import (
	"errors"
	"sync"
	"unsafe"
)

// Canceller removes the far-end signal (what we played) from the near-end
// signal (what the microphone picked up) and denoises the result.
type Canceller struct {
	mu     sync.Mutex
	echo   *C.SpeexEchoState
	pre    *C.SpeexPreprocessState
	frame  int
	rec    []C.spx_int16_t
	play   []C.spx_int16_t
	out    []C.spx_int16_t
	closed bool
}

// New creates a canceller for mono audio at rate Hz. frame is the number of
// samples per Process call (10-20 ms is the sweet spot), tail the filter
// length in samples - the echo path delay it can absorb.
func New(rate, frame, tail int) (*Canceller, error) {
	if frame <= 0 || tail <= frame {
		return nil, errors.New("speexdsp: bad frame/tail")
	}
	c := &Canceller{frame: frame}
	c.echo = C.speex_echo_state_init(C.int(frame), C.int(tail))
	if c.echo == nil {
		return nil, errors.New("speexdsp: echo state init failed")
	}
	r := C.spx_int32_t(rate)
	C.speex_echo_ctl(c.echo, C.SPEEX_ECHO_SET_SAMPLING_RATE, unsafe.Pointer(&r))
	c.pre = C.speex_preprocess_state_init(C.int(frame), C.int(rate))
	if c.pre == nil {
		C.speex_echo_state_destroy(c.echo)
		return nil, errors.New("speexdsp: preprocess init failed")
	}
	C.speex_preprocess_ctl(c.pre, C.SPEEX_PREPROCESS_SET_ECHO_STATE, unsafe.Pointer(c.echo))
	one := C.spx_int32_t(1)
	C.speex_preprocess_ctl(c.pre, C.SPEEX_PREPROCESS_SET_DENOISE, unsafe.Pointer(&one))
	// Residual echo suppression in dB: the defaults leave audible tails on a
	// phone; -40 during single talk, -15 while both sides speak
	supp := C.spx_int32_t(-40)
	C.speex_preprocess_ctl(c.pre, C.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, unsafe.Pointer(&supp))
	suppActive := C.spx_int32_t(-15)
	C.speex_preprocess_ctl(c.pre, C.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, unsafe.Pointer(&suppActive))
	c.rec = make([]C.spx_int16_t, frame)
	c.play = make([]C.spx_int16_t, frame)
	c.out = make([]C.spx_int16_t, frame)
	return c, nil
}

// Frame returns the samples per Process call.
func (c *Canceller) Frame() int { return c.frame }

// Process cancels the echo of play (far end, as played) from rec (near end,
// as captured) in place. Both slices must hold Frame() float32 samples in
// -1..1; rec is overwritten with the cleaned signal.
func (c *Canceller) Process(rec, play []float32) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || len(rec) < c.frame || len(play) < c.frame {
		return
	}
	for i := 0; i < c.frame; i++ {
		c.rec[i] = toI16(rec[i])
		c.play[i] = toI16(play[i])
	}
	C.speex_echo_cancellation(c.echo, &c.rec[0], &c.play[0], &c.out[0])
	C.speex_preprocess_run(c.pre, &c.out[0])
	for i := 0; i < c.frame; i++ {
		rec[i] = float32(c.out[i]) / 32768
	}
}

// Close frees the native state.
func (c *Canceller) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.closed = true
	C.speex_preprocess_state_destroy(c.pre)
	C.speex_echo_state_destroy(c.echo)
}

func toI16(v float32) C.spx_int16_t {
	if v > 1 {
		v = 1
	} else if v < -1 {
		v = -1
	}
	return C.spx_int16_t(v * 32767)
}
