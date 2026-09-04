package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"math"

	"github.com/godbus/dbus/v5"
	"github.com/jfreymuth/pulse"
	"github.com/jfreymuth/pulse/proto"
	"github.com/purpshell/meowcaller"

	"wa-client/speexdsp"
)

// pulseSocketPath is where the session PulseAudio listens. Sailjail only
// maps ${RUNUSER}/pulse into the jail with the Audio (or Microphone)
// permission, and only for processes started after the grant - so this
// path missing is the signature of "granted on paper, not in this process".
func pulseSocketPath() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = fmt.Sprintf("/run/user/%d", os.Getuid())
	}
	return filepath.Join(dir, "pulse", "native")
}

// audioAccessEffective reports whether THIS process can reach PulseAudio.
// The socket file alone is not the answer: Sailfish starts PulseAudio on
// demand and publishes its address over D-Bus, so ${RUNUSER}/pulse can be
// empty on a perfectly working device (only dbus-socket in it). The D-Bus
// lookup therefore counts as reachable too.
func audioAccessEffective() bool {
	if _, err := os.Stat(pulseSocketPath()); err == nil {
		return true
	}
	return pulseServerFromDBus() != ""
}

// pulseServerFromDBus asks the session bus where PulseAudio listens. This
// is what libpulse does before falling back to the well-known path, and
// it is why gstreamer works on devices where our socket check failed.
func pulseServerFromDBus() string {
	conn, err := dbus.SessionBus()
	if err != nil {
		return ""
	}
	obj := conn.Object("org.PulseAudio1", dbus.ObjectPath("/org/pulseaudio/server_lookup1"))
	v, err := obj.GetProperty("org.PulseAudio.ServerLookup1.Address")
	if err != nil {
		return ""
	}
	addr, _ := v.Value().(string)
	return addr
}

// pulseServerString returns the address to connect to, preferring an
// explicit PULSE_SERVER, then the D-Bus lookup, then the default path.
func pulseServerString() string {
	if s := os.Getenv("PULSE_SERVER"); s != "" {
		return s
	}
	if s := pulseServerFromDBus(); s != "" {
		return s
	}
	return ""
}

// ---- Route Manager (org.nemomobile.Route.Manager): the Sailfish policy
// layer that the phone app and our voice-message player already use.
// Prefer("earpiece", type, 1) routes output to the ear speaker, 0 releases
// it; the type bits are vendor-specific and come from Routes(). Going
// through the policy instead of poking the sink port directly means
// ohmd does not fight us - the port switch below stays as a fallback for
// devices without an earpiece route ----
func routeManager() (dbus.BusObject, error) {
	conn, err := dbus.SystemBus()
	if err != nil {
		return nil, err
	}
	return conn.Object("org.nemomobile.Route.Manager", "/org/nemomobile/Route/Manager"), nil
}

func earpieceRouteType() uint32 {
	obj, err := routeManager()
	if err != nil {
		return 0
	}
	var routes []struct {
		Name string
		Type uint32
	}
	if err := obj.Call("org.nemomobile.Route.Manager.Routes", 0).Store(&routes); err != nil {
		fmt.Printf("📞 route manager Routes: %v\n", err)
		return 0
	}
	for _, r := range routes {
		if r.Name == "earpiece" && r.Type&1 != 0 {
			return r.Type
		}
	}
	return 0
}

func preferEarpiece(routeType uint32, on bool) error {
	obj, err := routeManager()
	if err != nil {
		return err
	}
	enable := uint32(0)
	if on {
		enable = 1
	}
	call := obj.Call("org.nemomobile.Route.Manager.Prefer", 0, "earpiece", routeType, enable)
	if call.Err != nil {
		fmt.Printf("📞 route manager Prefer(earpiece,%d,%d): %v\n", routeType, enable, call.Err)
	}
	return call.Err
}

// callAudio bridges one WhatsApp voice call to PulseAudio. The microphone
// becomes the call's AudioSource, the peer's decoded audio feeds a playback
// stream. jfreymuth/pulse speaks the native protocol on the session socket
// in pure Go, so the static three-architecture build stays intact - no
// libpulse, no CGO.
//
// Routing follows RooTelegram's recipe for Sailfish OS: pick the sink that
// offers both a speaker and an earpiece/handset/receiver port (that skips
// sink.null and A2DP), play into that sink and switch its active port for
// earpiece vs speakerphone. The previously active port is restored when the
// call ends, otherwise music would keep coming out of the earpiece.
//
// The codec side is fixed at 16 kHz mono float32 in 60 ms frames. meowcaller
// PULLS a frame every 60 ms and expects an immediate answer, so ReadFrame
// never blocks: it hands out silence when the microphone has not delivered
// a full frame yet. Both buffers are bounded - on overflow the oldest
// samples are dropped, which keeps latency from creeping up during a long
// call at the price of an occasional inaudible skip.
type callAudio struct {
	pc   *pulse.Client
	rec  *pulse.RecordStream
	play *pulse.PlaybackStream

	mu     sync.Mutex
	micBuf []float32
	spkBuf []float32
	muted  bool
	closed bool

	// diagnostics: sample counts and smoothed levels (0..1) of both
	// directions, reported in /call/state and logged during the call
	micSamples uint64
	spkSamples uint64
	micLevel   float32
	spkLevel   float32

	// Echo cancellation (speexdsp): everything handed to PulseAudio for
	// playback is queued as far-end reference and consumed in lockstep
	// with the captured audio, 20 ms at a time. The filter tail (400 ms)
	// absorbs the playback+acoustic+capture delay in between. RooTelegram
	// gets this from WebRTC's APM for free; we do it here.
	aec      *speexdsp.Canceller
	rawMic   []float32 // captured, not yet cancelled
	refQ     []float32 // played, waiting to serve as reference
	aecChunk []float32
	refChunk []float32
	// Round trip between handing a sample to PulseAudio and hearing it
	// back through the microphone: playback buffer plus acoustic path plus
	// capture buffer. Measured from the server and held back from the
	// reference queue as silence, so the filter sees echo and reference
	// aligned - guessing this wrong is what makes a canceller useless.
	refDelay    int
	refPrimed   bool
	measuredLat time.Duration
	bypassed    int // frames that went out uncancelled (reference ran dry)
	refTrimmed  int // reference samples dropped to hold the alignment

	// Ringback: 425 Hz, 1 s on / 4 s off (the European tone RooTelegram
	// ships as a WAV), synthesised into the playback path while an
	// outgoing call rings; silenced as soon as far-end audio arrives
	// Zeitausgleich der Echounterdrueckung: PulseAudio sagt uns, wie lange
	// ein gerade abgegebener Block noch bis zum Lautsprecher braucht und
	// wie alt ein gerade gelesener Mikrofonblock schon ist. Die Summe ist
	// der Versatz, um den die Referenz VOR dem Echo im Mikrofon liegt -
	// genau so viele Samples muessen aus der Referenzschlange verworfen
	// werden, damit Referenz und Echo zusammenpassen.
	alignSkip int  // noch zu ueberspringende Referenz-Samples
	aligned   bool // Ausrichtung bereits vorgenommen

	ringback   bool
	ringPhase  float64
	ringPos    int
	farEndSeen bool

	sinkName     string
	speakerPort  string
	earpiecePort string
	restorePort  string
	speakerOn    bool
	routeType    uint32 // earpiece route type from the Route Manager, 0 = none
	routeOn      bool
	managed      bool // system call UI routes audio; we only carry the streams

	// flat volumes: raising a silent stream also raises the sink, and that
	// value would outlive the call - remember the sink volume and put it back
	savedVolume   proto.ChannelVolumes
	volumeTouched bool
}

const (
	micBufMax = meowcaller.FrameSamples * 5 // 300 ms of microphone backlog
	spkBufMax = meowcaller.FrameSamples * 6 // 360 ms of peer audio backlog
	aecFrame  = 320                         // 20 ms at 16 kHz
	aecTail   = 12800                       // 800 ms echo path (152 ms round trip plus room reverb on a phone)
	refQMax   = 2 * meowcaller.SampleRate   // room for the priming delay plus burst jitter
)

// openCallAudio connects to PulseAudio and starts both streams. An error
// here almost always means the sandbox lacks the Audio/Microphone permission
// (the session socket is then simply not there) - the caller turns that into
// a hint for the settings page instead of failing the call.
func openCallAudio(managed bool) (*callAudio, error) {
	// Just try to connect. PulseAudio is started on demand here, so a
	// missing socket is not a verdict - retry for a few seconds and let
	// the connection attempt itself wake it up. Only a lasting failure
	// means the sandbox really cannot reach it.
	opts := []pulse.ClientOption{
		pulse.ClientApplicationName("harbour-whatsapp"),
		pulse.ClientApplicationIconName("harbour-whatsapp"),
		pulse.ClientTimeout(5 * time.Second),
	}
	if srv := pulseServerString(); srv != "" {
		fmt.Printf("📞 pulseaudio address from lookup: %s\n", srv)
		opts = append(opts, pulse.ClientServerString(srv))
	}
	var pc *pulse.Client
	var err error
	for attempt := 1; attempt <= 6; attempt++ {
		pc, err = pulse.NewClient(opts...)
		if err == nil {
			break
		}
		if attempt == 1 {
			fmt.Printf("📞 pulseaudio not up yet (%v) - retrying\n", err)
		}
		time.Sleep(500 * time.Millisecond)
		if srv := pulseServerString(); srv != "" {
			opts = append(opts, pulse.ClientServerString(srv))
		}
	}
	if err != nil {
		return nil, fmt.Errorf("pulseaudio unreachable after 3s: %w", err)
	}
	a := &callAudio{pc: pc, managed: managed}
	if aec, aerr := speexdsp.New(meowcaller.SampleRate, aecFrame, aecTail); aerr == nil {
		a.aec = aec
		a.aecChunk = make([]float32, aecFrame)
		a.refChunk = make([]float32, aecFrame)
	} else {
		fmt.Printf("📞 echo canceller unavailable: %v\n", aerr)
	}
	a.discoverSink()

	// No media.role on either stream: the Sailfish policy layer maps the
	// "phone" role to the cellular voice path, whose capture side is
	// silent without a real modem call - first field test heard the peer
	// but the peer heard nothing. The voice-message recorder (gst pulsesrc)
	// runs without a role and works, so the call streams do the same.
	// Pick the microphone explicitly. The default source on these devices
	// can be a monitor of an output (sink.primary_output.monitor and
	// friends are all sources too), and recording from one of those gives
	// exactly what the field log showed: a microphone level of 0.000 for
	// the whole call.
	recOpts := []pulse.RecordOption{
		pulse.RecordSampleRate(meowcaller.SampleRate),
		pulse.RecordChannels(proto.ChannelMap{proto.ChannelMono}),
		pulse.RecordLatency(0.04),
		pulse.RecordMediaName("WhatsApp call"),
	}
	if src := a.pickMicrophone(); src != nil {
		fmt.Printf("📞 recording from %q (%s)\n", src.Name(), src.ID())
		recOpts = append(recOpts, pulse.RecordSource(src))
	}
	a.rec, err = pc.NewRecord(pulse.Float32Writer(a.onMic), recOpts...)
	if err != nil {
		pc.Close()
		return nil, fmt.Errorf("microphone: %w", err)
	}

	playOpts := []pulse.PlaybackOption{
		pulse.PlaybackSampleRate(meowcaller.SampleRate),
		pulse.PlaybackChannels(proto.ChannelMap{proto.ChannelMono}),
		pulse.PlaybackLatency(0.08),
		pulse.PlaybackMediaName("WhatsApp call"),
	}
	if a.sinkName != "" {
		if sink, serr := pc.SinkByID(a.sinkName); serr == nil {
			playOpts = append(playOpts, pulse.PlaybackSink(sink))
		}
	}
	a.play, err = pc.NewPlayback(pulse.Float32Reader(a.onPlay), playOpts...)
	if err != nil {
		a.rec.Close()
		pc.Close()
		return nil, fmt.Errorf("playback: %w", err)
	}
	a.rec.Start()
	a.play.Start()
	a.ensureAudible()
	go a.alignEchoReference()
	// Earpiece first, like a phone call - the speakerphone is a toggle.
	// Route Manager when the device has an earpiece route, sink port
	// otherwise (RooTelegram's way)
	if managed {
		// voicecall-manager's playback manager owns the route while the
		// system call UI runs the call - two hands on the switch would
		// only fight each other
		fmt.Println("📞 audio routing left to voicecall-manager (plugin present)")
	} else {
		a.routeType = earpieceRouteType()
		if a.routeType != 0 {
			if preferEarpiece(a.routeType, true) == nil {
				a.routeOn = true
			}
		} else if a.earpiecePort != "" {
			a.setPort(a.earpiecePort)
		}
	}
	fmt.Printf("📞 audio up: sink=%q earpiece=%q speaker=%q restore=%q routeType=%d managed=%v\n",
		a.sinkName, a.earpiecePort, a.speakerPort, a.restorePort, a.routeType, managed)
	go a.logLevels()
	go a.trackLatency()
	go a.keepUnmuted()
	return a, nil
}

// keepUnmuted re-asserts both streams as unmuted every half second. The
// Sailfish policy layer mutes ordinary streams while the system is in call
// mode (RooTelegram fought the same thing: its WebRTC stream "came up
// muted"); a cheap periodic unmute keeps our call audio flowing without
// depending on which stream class the policy assigned.
func (a *callAudio) keepUnmuted() {
	// Only during the first seconds, and then never again. Running this
	// on a ticker for the whole call was a mistake: every mute request
	// makes PulseAudio re-evaluate the stream, the timing between
	// playback and capture jumps, and the echo canceller loses its
	// alignment - audible as echo that comes and goes about twice a
	// second. The policy layer only mutes a stream when it appears, so
	// three passes at the start are enough.
	for i := 0; i < 3; i++ {
		time.Sleep(500 * time.Millisecond)
		a.mu.Lock()
		closed := a.closed
		a.mu.Unlock()
		if closed {
			return
		}
		if a.play != nil {
			_ = a.pc.RawRequest(&proto.SetSinkInputMute{SinkInputIndex: a.play.StreamInputIndex(), Mute: false}, nil)
		}
		if a.rec != nil {
			_ = a.pc.RawRequest(&proto.SetSourceOutputMute{SourceOutputIndex: a.rec.StreamIndex(), Mute: false}, nil)
		}
	}
}

// streamLatencies asks PulseAudio how far playback and capture actually
// run behind, in samples.
func (a *callAudio) streamLatencies() (playSamples, recSamples int, err error) {
	var pl proto.GetPlaybackLatencyReply
	if err = a.pc.RawRequest(&proto.GetPlaybackLatency{
		StreamIndex: a.play.StreamIndex(), Time: proto.Time{},
	}, &pl); err != nil {
		return 0, 0, err
	}
	var rl proto.GetRecordLatencyReply
	if err = a.pc.RawRequest(&proto.GetRecordLatency{
		StreamIndex: a.rec.StreamIndex(), Time: proto.Time{},
	}, &rl); err != nil {
		return 0, 0, err
	}
	playSamples = int(uint64(pl.Latency) * meowcaller.SampleRate / 1e6)
	recSamples = int(uint64(rl.Latency) * meowcaller.SampleRate / 1e6)
	return playSamples, recSamples, nil
}

// alignEchoReference measures the round trip once the streams are running
// and drops that many samples from the reference queue, so the block the
// canceller sees is the one the microphone actually picked up. Without it
// the filter has to find the delay by itself within its 400 ms tail - and
// on a phone the playback buffer alone can eat most of that.
func (a *callAudio) alignEchoReference() {
	if a.aec == nil {
		return
	}
	// Give both streams a moment to report meaningful numbers
	time.Sleep(700 * time.Millisecond)
	playSamples, recSamples, err := a.streamLatencies()
	if err != nil {
		fmt.Printf("📞 latency query failed (%v) - echo canceller works without alignment\n", err)
		return
	}
	skip := playSamples + recSamples
	if skip < 0 {
		skip = 0
	}
	if max := 2 * meowcaller.SampleRate; skip > max {
		skip = max
	}
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	a.alignSkip = skip
	a.aligned = true
	a.refQ = a.refQ[:0]
	a.rawMic = a.rawMic[:0]
	a.mu.Unlock()
	fmt.Printf("📞 echo reference aligned: playback %d ms + capture %d ms = %d samples skipped\n",
		playSamples*1000/meowcaller.SampleRate, recSamples*1000/meowcaller.SampleRate, skip)
}

// logLevels prints a heartbeat every five seconds - the fastest way to see
// on a device whether the microphone delivers anything at all.
func (a *callAudio) logLevels() {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for range t.C {
		a.mu.Lock()
		closed := a.closed
		mic, spk, ml, sl := a.micSamples, a.spkSamples, a.micLevel, a.spkLevel
		a.mu.Unlock()
		if closed {
			return
		}
		a.mu.Lock()
		lat, refq, byp := a.measuredLat, len(a.refQ), a.bypassed
		trimmed, want := a.refTrimmed, a.refDelay
		a.mu.Unlock()
		fmt.Printf("📞 audio: mic %d samples level %.3f | peer %d samples level %.3f | muted=%v rec=%v play=%v | aec delay %s ref %d bypassed %d\n",
			mic, ml, spk, sl, a.muted, a.rec.Running(), a.play.Running(), lat.Round(time.Millisecond), refq, byp)
		fmt.Printf("📞 aec: reference %d/%d samples, trimmed %d\n", refq, want, trimmed)
	}
}

// trackLatency asks PulseAudio how far playback and capture actually run
// behind and turns that into the reference delay of the echo canceller.
func (a *callAudio) trackLatency() {
	for {
		a.mu.Lock()
		closed := a.closed
		a.mu.Unlock()
		if closed || a.aec == nil {
			return
		}
		var pl proto.GetPlaybackLatencyReply
		var rl proto.GetRecordLatencyReply
		total := time.Duration(0)
		if err := a.pc.RawRequest(&proto.GetPlaybackLatency{StreamIndex: a.play.StreamIndex()}, &pl); err == nil {
			total += time.Duration(pl.Latency) * time.Microsecond
		}
		if err := a.pc.RawRequest(&proto.GetRecordLatency{StreamIndex: a.rec.StreamIndex()}, &rl); err == nil {
			total += time.Duration(rl.Latency) * time.Microsecond
		}
		if total > 0 {
			// Cap at the filter tail - a delay the filter cannot span
			// cannot be compensated anyway
			if maxLat := time.Duration(aecTail) * time.Second / meowcaller.SampleRate; total > maxLat {
				total = maxLat
			}
			samples := int(total.Seconds() * meowcaller.SampleRate)
			a.mu.Lock()
			first := !a.refPrimed
			if first {
				// Prime the queue with exactly that much silence so the
				// first real reference block lines up with the echo it
				// caused, instead of arriving early
				a.refQ = append(make([]float32, samples), a.refQ...)
				a.refPrimed = true
			}
			a.refDelay = samples
			a.measuredLat = total
			a.mu.Unlock()
			if first {
				fmt.Printf("📞 echo canceller: round trip %s (%d samples) - reference delayed by that much\n",
					total.Round(time.Millisecond), samples)
			}
		}
		time.Sleep(2 * time.Second)
	}
}

// Levels returns the smoothed microphone and peer levels (0..1).
func (a *callAudio) Levels() (mic, spk float32) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.micLevel, a.spkLevel
}

func peakOf(buf []float32) float32 {
	var peak float32
	for _, v := range buf {
		if v < 0 {
			v = -v
		}
		if v > peak {
			peak = v
		}
	}
	return peak
}

// pickMicrophone returns a real input, never a monitor: the well-known
// droid name first, then any source whose name is not a monitor, and the
// default only as a last resort.
func (a *callAudio) pickMicrophone() *pulse.Source {
	if src, err := a.pc.SourceByID("source.primary_input"); err == nil && src != nil {
		return src
	}
	if srcs, err := a.pc.ListSources(); err == nil {
		for _, src := range srcs {
			if src == nil {
				continue
			}
			name := strings.ToLower(src.Name() + " " + src.ID())
			if !strings.Contains(name, "monitor") && !strings.Contains(name, "null") {
				return src
			}
		}
	}
	src, err := a.pc.DefaultSource()
	if err != nil {
		return nil
	}
	if src != nil && strings.Contains(strings.ToLower(src.Name()+" "+src.ID()), "monitor") {
		fmt.Printf("📞 default source %q is a monitor - recording would be silent\n", src.Name())
	}
	return src
}

// discoverSink looks for the output that carries both a speaker and an
// earpiece-style port and remembers the port that is active right now.
func (a *callAudio) discoverSink() {
	var reply proto.GetSinkInfoListReply
	if err := a.pc.RawRequest(&proto.GetSinkInfoList{}, &reply); err != nil {
		fmt.Printf("📞 sink enumeration failed: %v\n", err)
		return
	}
	for _, s := range reply {
		if s == nil {
			continue
		}
		var speaker, earpiece string
		for _, p := range s.Ports {
			name := strings.ToLower(p.Name)
			desc := strings.ToLower(p.Description)
			if speaker == "" && (strings.Contains(name, "speaker") || strings.Contains(desc, "speaker")) {
				speaker = p.Name
			}
			if earpiece == "" && (strings.Contains(name, "earpiece") || strings.Contains(name, "handset") ||
				strings.Contains(name, "receiver") || strings.Contains(desc, "earpiece") ||
				strings.Contains(desc, "handset") || strings.Contains(desc, "receiver")) {
				earpiece = p.Name
			}
		}
		if speaker != "" && earpiece != "" {
			a.sinkName = s.SinkName
			a.speakerPort = speaker
			a.earpiecePort = earpiece
			a.restorePort = s.ActivePortName
			return
		}
	}
	// Droid naming (Xperia and friends) as a fallback when the ports carry
	// no telling names - RooTelegram ships the same three strings
	for _, s := range reply {
		if s != nil && s.SinkName == "sink.primary_output" {
			a.sinkName = s.SinkName
			a.speakerPort = "output-speaker"
			a.earpiecePort = "output-earpiece"
			a.restorePort = s.ActivePortName
			return
		}
	}
	fmt.Println("📞 no sink with speaker+earpiece ports - playing to the default sink, no route switching")
}

func (a *callAudio) setPort(port string) error {
	if a.sinkName == "" || port == "" {
		return errors.New("no switchable output")
	}
	err := a.pc.RawRequest(&proto.SetSinkPort{SinkIndex: proto.Undefined, SinkName: a.sinkName, Port: port}, nil)
	if err != nil {
		fmt.Printf("📞 set port %s on %s failed: %v\n", port, a.sinkName, err)
	}
	return err
}

// SetSpeaker toggles between earpiece and speakerphone.
func (a *callAudio) SetSpeaker(on bool) error {
	if a.managed {
		// the plugin mirrors the flag into voicecall-manager's audio mode
		a.mu.Lock()
		a.speakerOn = on
		a.mu.Unlock()
		return nil
	}
	if a.routeType != 0 {
		if err := preferEarpiece(a.routeType, !on); err != nil {
			return err
		}
		a.routeOn = !on
	} else {
		port := a.earpiecePort
		if on {
			port = a.speakerPort
		}
		if err := a.setPort(port); err != nil {
			return err
		}
	}
	a.mu.Lock()
	a.speakerOn = on
	a.mu.Unlock()
	return nil
}

func (a *callAudio) SetMuted(m bool) {
	a.mu.Lock()
	a.muted = m
	if m {
		a.micBuf = a.micBuf[:0]
	}
	a.mu.Unlock()
}

// ensureAudible lifts a stream that PulseAudio created effectively muted
// (seen on SFOS 5.x: new streams may start at 0 %). Done once, remembering
// the sink volume, because flat volumes couple the two.
func (a *callAudio) ensureAudible() {
	vol, err := a.play.Volume()
	if err != nil || len(vol) == 0 {
		return
	}
	var sum uint64
	for _, v := range vol {
		sum += uint64(v)
	}
	avg := sum / uint64(len(vol))
	if avg >= 0x10000/20 { // above 5 %: leave the user's level alone
		return
	}
	if a.sinkName != "" {
		var info proto.GetSinkInfoReply
		if err := a.pc.RawRequest(&proto.GetSinkInfo{SinkIndex: proto.Undefined, SinkName: a.sinkName}, &info); err == nil {
			a.savedVolume = append(proto.ChannelVolumes(nil), info.ChannelVolumes...)
			a.volumeTouched = true
		}
	}
	target := make(proto.ChannelVolumes, len(vol))
	for i := range target {
		target[i] = proto.Volume(0x10000) * 9 / 10
	}
	if err := a.play.SetVolume(target); err != nil {
		fmt.Printf("📞 stream volume set failed: %v\n", err)
	} else {
		fmt.Printf("📞 stream came up at %d%%, raised to 90%%\n", avg*100/0x10000)
	}
}

// onMic receives captured samples from PulseAudio.
func (a *callAudio) onMic(in []float32) (int, error) {
	peak := peakOf(in)
	a.mu.Lock()
	a.micSamples += uint64(len(in))
	a.micLevel = 0.8*a.micLevel + 0.2*peak
	if a.closed || a.muted {
		a.rawMic = a.rawMic[:0]
		a.refQ = a.refQ[:0]
		a.mu.Unlock()
		return len(in), nil
	}
	if a.aec == nil {
		a.pushMicLocked(in)
		a.mu.Unlock()
		return len(in), nil
	}
	a.rawMic = append(a.rawMic, in...)
	for len(a.rawMic) >= aecFrame {
		// Ohne echte Referenz lernt der Filter nichts: mit Nullen
		// aufgefuellte Bloecke bringen ihm bei, dass zum Echo im Mikrofon
		// gar kein Wiedergabesignal gehoert - danach ist er blind. Lieber
		// warten, bis die Wiedergabeseite genug geliefert hat; erst wenn
		// sich mehr als eine Viertelsekunde Mikrofon staut, wird
		// ungefiltert durchgereicht, damit die Gegenseite nie stockt.
		if !a.aligned {
			// Noch nicht ausgerichtet: unveraendert weiterreichen statt
			// den Filter auf einen falschen Versatz einzuschwoeren
			copy(a.aecChunk, a.rawMic[:aecFrame])
			a.rawMic = a.rawMic[aecFrame:]
			a.pushMicLocked(a.aecChunk)
			continue
		}
		if len(a.refQ) < aecFrame || !a.refPrimed {
			if len(a.rawMic) < meowcaller.SampleRate/4 {
				break
			}
			a.bypassed++
			copy(a.aecChunk, a.rawMic[:aecFrame])
			a.rawMic = a.rawMic[aecFrame:]
			a.pushMicLocked(a.aecChunk)
			continue
		}
		// Hold the queue at its target length. Playback arrives in bursts
		// while capture trickles in evenly, so the lead the priming
		// established drifts back and forth by a hundred milliseconds -
		// and a reference that early or late is worse than none, because
		// the filter adapts to the wrong alignment and has to relearn.
		// Trimming the surplus keeps echo and reference on top of each
		// other; the reference is what we played, so dropping the oldest
		// surplus loses nothing but stale lead.
		if a.refDelay > 0 {
			if surplus := len(a.refQ) - a.refDelay - aecFrame; surplus > aecFrame {
				a.refQ = a.refQ[surplus:]
				a.refTrimmed += surplus
			}
		}
		copy(a.aecChunk, a.rawMic[:aecFrame])
		a.rawMic = a.rawMic[aecFrame:]
		copy(a.refChunk, a.refQ[:aecFrame])
		a.refQ = a.refQ[aecFrame:]
		a.aec.Process(a.aecChunk, a.refChunk)
		a.pushMicLocked(a.aecChunk)
	}
	a.mu.Unlock()
	return len(in), nil
}

func (a *callAudio) pushMicLocked(samples []float32) {
	a.micBuf = append(a.micBuf, samples...)
	if len(a.micBuf) > micBufMax {
		a.micBuf = a.micBuf[len(a.micBuf)-micBufMax:]
	}
}

// onPlay is asked by PulseAudio for the next chunk of peer audio.
func (a *callAudio) onPlay(out []float32) (int, error) {
	a.mu.Lock()
	n := copy(out, a.spkBuf)
	a.spkBuf = a.spkBuf[n:]
	for i := n; i < len(out); i++ {
		out[i] = 0
	}
	if a.ringback && !a.farEndSeen {
		a.fillRingbackLocked(out)
	}
	if a.aec != nil {
		if a.alignSkip > 0 {
			// Der Vorlauf der Wiedergabe: diese Samples sind im Mikrofon
			// noch nicht angekommen und duerfen nicht als Referenz dienen
			n := a.alignSkip
			if n > len(out) {
				n = len(out)
			}
			a.alignSkip -= n
			if n < len(out) {
				a.refQ = append(a.refQ, out[n:]...)
			}
		} else {
			a.refQ = append(a.refQ, out...)
		}
		if len(a.refQ) > refQMax {
			a.refQ = a.refQ[len(a.refQ)-refQMax:]
		}
	}
	a.mu.Unlock()
	return len(out), nil
}

// fillRingbackLocked synthesises the ringback tone into out (adding to
// whatever peer audio is there, normally nothing while it rings).
func (a *callAudio) fillRingbackLocked(out []float32) {
	const cycle = 5 * meowcaller.SampleRate // 1 s on, 4 s off
	const on = 1 * meowcaller.SampleRate
	step := 2 * math.Pi * 425 / float64(meowcaller.SampleRate)
	for i := range out {
		if a.ringPos < on {
			out[i] += 0.22 * float32(math.Sin(a.ringPhase))
			a.ringPhase += step
			if a.ringPhase > 2*math.Pi {
				a.ringPhase -= 2 * math.Pi
			}
		} else {
			a.ringPhase = 0
		}
		a.ringPos++
		if a.ringPos >= cycle {
			a.ringPos = 0
		}
	}
}

// SetRingback switches the synthesised ringback on or off.
func (a *callAudio) SetRingback(on bool) {
	a.mu.Lock()
	a.ringback = on
	if on {
		a.ringPos = 0
		a.ringPhase = 0
	}
	a.mu.Unlock()
}

// Source returns the call-facing microphone source.
func (a *callAudio) Source() meowcaller.AudioSource { return micSource{a} }

// Sink returns the call-facing playback sink.
func (a *callAudio) Sink() meowcaller.AudioSink { return spkSink{a} }

type micSource struct{ a *callAudio }

func (m micSource) ReadFrame() ([]float32, error) {
	a := m.a
	frame := make([]float32, meowcaller.FrameSamples)
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return nil, io.EOF
	}
	if !a.muted && len(a.micBuf) >= meowcaller.FrameSamples {
		copy(frame, a.micBuf[:meowcaller.FrameSamples])
		a.micBuf = a.micBuf[meowcaller.FrameSamples:]
	}
	a.mu.Unlock()
	return frame, nil
}

func (m micSource) Close() error { return nil }

type spkSink struct{ a *callAudio }

func (s spkSink) WriteFrame(frame []float32) error {
	a := s.a
	peak := peakOf(frame)
	a.mu.Lock()
	a.spkSamples += uint64(len(frame))
	a.spkLevel = 0.8*a.spkLevel + 0.2*peak
	if peak > 0.002 && !a.farEndSeen {
		a.farEndSeen = true
		a.ringback = false
	}
	if !a.closed {
		a.spkBuf = append(a.spkBuf, frame...)
		if len(a.spkBuf) > spkBufMax {
			a.spkBuf = a.spkBuf[len(a.spkBuf)-spkBufMax:]
		}
	}
	a.mu.Unlock()
	return nil
}

func (s spkSink) Close() error { return nil }

// Close stops both streams, restores the output port and the sink volume.
func (a *callAudio) Close() {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	a.closed = true
	a.mu.Unlock()
	if a.rec != nil {
		a.rec.Stop()
		a.rec.Close()
	}
	if a.play != nil {
		a.play.Stop()
		a.play.Close()
	}
	if a.routeOn {
		preferEarpiece(a.routeType, false)
		a.routeOn = false
	} else if a.routeType == 0 && a.restorePort != "" {
		a.setPort(a.restorePort)
	}
	if a.aec != nil {
		a.aec.Close()
	}
	if a.volumeTouched && a.sinkName != "" {
		if err := a.pc.RawRequest(&proto.SetSinkVolume{SinkIndex: proto.Undefined, SinkName: a.sinkName,
			ChannelVolumes: a.savedVolume}, nil); err != nil {
			fmt.Printf("📞 sink volume restore failed: %v\n", err)
		}
	}
	a.pc.Close()
}
