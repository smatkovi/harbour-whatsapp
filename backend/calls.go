package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/purpshell/meowcaller"
	"github.com/rs/zerolog"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
)

// ---- Voice calls (meowcaller on top of whatsmeow) ----
//
// meowcaller carries the WhatsApp Web VoIP stack in pure Go, MLow codec
// included. It hooks into the whatsmeow client at construction time, so
// initCalls() runs from initClient() before the first Connect(). The
// backend owns the call: signalling, media and audio routing all happen
// here, in the child backend as well as in the daemon - the app is only a
// remote control over /call/*. One call at a time; a second incoming call
// is answered with busy.
//
// Ringing is delegated to lipstick: the incoming-call notification carries
// x-nemo-feedback=ringtone, which ngfd plays (profile ringtone, vibration,
// silent profile respected) until the notification is closed. That is what
// lipstick does for the phone app too, and it works with the app closed.

// ---- System call UI plugin (voicecallplugin/): it polls us over HTTP
// with a marker header. While it is around, ringing and audio routing are
// the call engine's job: voicecall-ui rings via ngfd and shows the call
// over the lock screen, the playback manager routes earpiece/speaker ----
var (
	pluginMu    sync.Mutex
	pluginSeen  time.Time
	pluginAcked = map[string]time.Time{}
)

func notePlugin(r *http.Request) {
	if r.Header.Get("X-WhatsApp-Voicecall-Plugin") == "" {
		return
	}
	pluginMu.Lock()
	pluginSeen = time.Now()
	pluginMu.Unlock()
}

func pluginActive() bool {
	pluginMu.Lock()
	defer pluginMu.Unlock()
	return !pluginSeen.IsZero() && time.Since(pluginSeen) < 90*time.Second
}

// noteCallAck records that the plugin actually registered THIS call with
// the call engine. Seeing the plugin poll is not enough: if the provider
// never got the call to the system UI, nothing would ring at all - so the
// backend waits a moment for this ack and falls back to its own ringing
// notification when it does not come.
func noteCallAck(id string) {
	pluginMu.Lock()
	pluginAcked[id] = time.Now()
	for k, t := range pluginAcked {
		if time.Since(t) > 10*time.Minute {
			delete(pluginAcked, k)
		}
	}
	pluginMu.Unlock()
}

func callAcked(id string) bool {
	pluginMu.Lock()
	defer pluginMu.Unlock()
	_, ok := pluginAcked[id]
	return ok
}

var (
	callClient *meowcaller.Client
	callMu     sync.Mutex
	curCall    *callSession
	// call IDs handled here: the CallTerminate bookkeeping in eventHandler
	// must not add a second "missed call" line for them
	callSeen = map[string]bool{}
)

type callSession struct {
	call *meowcaller.Call

	ID        string
	Peer      string // phone-number user part, or the LID user part if unresolvable
	PeerIsLid bool
	Name      string
	Outgoing  bool
	Phase     string // ringing|calling|connecting|active|ended|waiting
	Reason    string
	Created   time.Time
	Started   time.Time
	Ended     time.Time
	Muted     bool
	Speaker   bool
	Answered  bool // we answered (incoming) or the peer accepted (outgoing)
	AudioErr  string
	audio     *callAudio
	notifID   uint32
	mu        sync.Mutex
}

func initCalls() {
	if client == nil {
		return
	}
	logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stdout, NoColor: true, TimeFormat: "15:04:05"}).
		Level(zerolog.InfoLevel)
	callClient = meowcaller.NewClient(client, meowcaller.WithLogger(logger))
	callClient.OnIncomingCall(onIncomingCall)
	fmt.Println("📞 Voice calls ready (meowcaller)")
}

// callHandledLocally tells the old CallTerminate path to stay quiet.
func callHandledLocally(id string) bool {
	callMu.Lock()
	defer callMu.Unlock()
	return callSeen[id]
}

// phase reads the lifecycle phase under the session lock.
func (s *callSession) phase() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.Phase
}

func callActive() bool {
	callMu.Lock()
	s := curCall
	callMu.Unlock()
	return s != nil && s.phase() != "ended"
}

// callDisplayName resolves a name the way the chat list does, trying the
// phone number first and the LID second; push names from the whatsmeow
// store are the last resort before the bare number.
func callDisplayName(user, alt string, isLid bool) string {
	contactsMutex.RLock()
	name := contacts[user]
	if name == "" && alt != "" {
		name = contacts[alt]
	}
	contactsMutex.RUnlock()
	if name == "" && client != nil && client.Store != nil {
		for _, j := range []types.JID{
			{User: user, Server: types.DefaultUserServer},
			{User: alt, Server: types.HiddenUserServer},
		} {
			if j.User == "" {
				continue
			}
			if info, err := client.Store.Contacts.GetContact(ctx, j); err == nil && info.Found {
				if info.FullName != "" {
					name = info.FullName
				} else if info.PushName != "" {
					name = info.PushName
				}
				if name != "" {
					break
				}
			}
		}
	}
	if name == "" {
		if isLid {
			return "Unknown caller"
		}
		return "+" + user
	}
	return name
}

func newCallSession(call *meowcaller.Call, outgoing bool) *callSession {
	pj := call.Peer().ToNonAD()
	pn := resolvePN(pj, types.EmptyJID)
	s := &callSession{
		call:      call,
		ID:        call.ID(),
		Peer:      pn.User,
		PeerIsLid: pn.Server == types.HiddenUserServer,
		Outgoing:  outgoing,
		Created:   time.Now(),
	}
	alt := ""
	if pj.User != pn.User {
		alt = pj.User
	}
	s.Name = callDisplayName(pn.User, alt, s.PeerIsLid)
	return s
}

func phaseName(p meowcaller.CallPhase) string {
	switch p {
	case meowcaller.CallPhaseCalling:
		return "calling"
	case meowcaller.CallPhaseRinging:
		return "ringing"
	case meowcaller.CallPhaseConnecting:
		return "connecting"
	case meowcaller.CallPhaseActive:
		return "active"
	case meowcaller.CallPhaseEnded:
		return "ended"
	case meowcaller.CallPhaseWaitingRoom:
		return "waiting"
	}
	return "idle"
}

func (s *callSession) wire() {
	c := s.call
	c.OnStateChange(func(p meowcaller.CallPhase) {
		name := phaseName(p)
		if name == "ended" {
			return // OnEnd carries the reason and does the bookkeeping
		}
		s.mu.Lock()
		if s.Phase != "ended" {
			s.Phase = name
			if name == "active" && s.Started.IsZero() {
				s.Started = time.Now()
			}
		}
		s.mu.Unlock()
		if name == "active" {
			mceCallState("active")
		}
		fmt.Printf("📞 call %s: %s\n", s.ID, name)
		bumpEvent()
	})
	c.OnPeerAccept(func() {
		s.mu.Lock()
		s.Answered = true
		if s.audio != nil {
			s.audio.SetRingback(false)
		}
		s.mu.Unlock()
		closeCallNotification(s)
		bumpEvent()
	})
	c.OnReady(func() {
		s.mu.Lock()
		if s.Started.IsZero() {
			s.Started = time.Now()
		}
		if s.Phase != "ended" && s.Phase != "active" {
			s.Phase = "active"
		}
		if s.audio != nil {
			s.audio.SetRingback(false)
		}
		s.mu.Unlock()
		s.startAudio()
		mceCallState("active")
		bumpEvent()
	})
	c.OnEnd(func(reason string) { s.finish(reason) })
}

func (s *callSession) startAudio() {
	s.mu.Lock()
	if s.audio != nil || s.Phase == "ended" {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	a, err := openCallAudio(pluginActive())
	if err != nil {
		fmt.Printf("📞 audio unavailable: %v\n", err)
		s.mu.Lock()
		s.AudioErr = err.Error()
		s.mu.Unlock()
		bumpEvent()
		return
	}
	s.mu.Lock()
	if s.Phase == "ended" {
		s.mu.Unlock()
		a.Close()
		return
	}
	s.audio = a
	a.SetMuted(s.Muted)
	if s.Speaker {
		a.SetSpeaker(true)
	}
	s.mu.Unlock()
	s.call.Receive(a.Sink())
	s.call.Play(a.Source())
	bumpEvent()
}

func (s *callSession) finish(reason string) {
	s.mu.Lock()
	if s.Phase == "ended" {
		s.mu.Unlock()
		return
	}
	s.Phase = "ended"
	s.Reason = reason
	s.Ended = time.Now()
	audio := s.audio
	s.audio = nil
	s.mu.Unlock()
	if audio != nil {
		audio.Close()
	}
	closeCallNotification(s)
	mceCallState("none")
	s.logCall()
	fmt.Printf("📞 call %s ended (%s)\n", s.ID, reason)
	bumpEvent()
	// The ended state stays visible long enough for the app to show it,
	// then the slot is freed for the next call
	time.AfterFunc(30*time.Second, func() {
		callMu.Lock()
		if curCall == s {
			curCall = nil
		}
		callMu.Unlock()
		bumpEvent()
	})
}

// logCall writes the call into the chat like the old CallTerminate path
// did - same "call-<id>" message IDs, so nothing is counted twice.
func (s *callSession) logCall() {
	s.mu.Lock()
	dur := time.Duration(0)
	if !s.Started.IsZero() {
		dur = s.Ended.Sub(s.Started).Round(time.Second)
	}
	answered := s.Answered || (!s.Started.IsZero() && s.Phase == "ended")
	reason := strings.ToLower(s.Reason)
	outgoing, peer, name := s.Outgoing, s.Peer, s.Name
	s.mu.Unlock()
	durText := func() string {
		m := int(dur.Minutes())
		sec := int(dur.Seconds()) % 60
		return fmt.Sprintf(" \u00b7 %d:%02d", m, sec)
	}
	var text string
	switch {
	case outgoing && answered:
		text = "📞 Outgoing call" + durText()
	case outgoing:
		text = "📞 Outgoing call (no answer)"
	case answered:
		text = "📞 Incoming call" + durText()
	case strings.Contains(reason, "elsewhere") || strings.Contains(reason, "other"):
		text = "📞 Incoming call (answered on your phone)"
	case reason == "declined" || reason == "reject":
		text = "📞 Declined call"
	default:
		text = "📞 Missed call"
	}
	sender := peer
	if outgoing && client != nil && client.Store != nil && client.Store.ID != nil {
		sender = client.Store.ID.User
	}
	addMessage(Message{
		ID: "call-" + s.ID, Sender: sender, Text: text,
		Timestamp: time.Now().Unix(), FromMe: outgoing, ChatJID: peer,
	})
	if !outgoing && !answered && !strings.Contains(reason, "elsewhere") && reason != "declined" && reason != "reject" {
		go notifyMissedCall(peer, name)
	}
}

// notifyUncarriedCall rings for a call the voice stack could not take
// (video, group, unknown variant). Declining works over whatsmeow; there
// is no way to answer such a call here, so the notification offers the
// decline action only and says what it is.
func notifyUncarriedCall(callID string, from types.JID) {
	pn := resolvePN(from.ToNonAD(), types.EmptyJID)
	alt := ""
	if from.User != pn.User {
		alt = from.User
	}
	name := callDisplayName(pn.User, alt, pn.Server == types.HiddenUserServer)
	s := &callSession{ID: callID, Peer: pn.User, Name: name, Created: time.Now(), Phase: "ringing"}
	prefsMutex.RLock()
	title := prefs["call_incoming_label"]
	declineLabel := prefs["call_decline_label"]
	prefsMutex.RUnlock()
	if title == "" {
		title = "Incoming WhatsApp call"
	}
	if declineLabel == "" {
		declineLabel = "Decline"
	}
	conn, err := dbus.SessionBus()
	if err != nil {
		return
	}
	gui := "harbour.harbour-whatsapp / harbour.whatsapp.Gui "
	hints := map[string]dbus.Variant{
		"x-nemo-preview-summary":       dbus.MakeVariant(title),
		"x-nemo-preview-body":          dbus.MakeVariant(name),
		"urgency":                      dbus.MakeVariant(byte(2)),
		"x-nemo-display-on":            dbus.MakeVariant(true),
		"x-nemo-feedback":              dbus.MakeVariant("chat"),
		"x-nemo-remote-action-default": dbus.MakeVariant(gui + "openChat string:'" + pn.User + "'"),
		"x-nemo-remote-action-decline": dbus.MakeVariant(gui + "declineUncarriedCall string:'" + callID + "'"),
	}
	obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
	var id uint32
	c := obj.Call("org.freedesktop.Notifications.Notify", 0,
		notifAppName(), uint32(0), "harbour-whatsapp", title, name,
		[]string{"default", "", "decline", declineLabel}, hints, int32(0))
	if c.Err != nil {
		fmt.Printf("📞 uncarried ring notification failed: %v\n", c.Err)
		return
	}
	c.Store(&id)
	s.notifID = id
	uncarriedMu.Lock()
	uncarried[callID] = s
	uncarriedFrom[callID] = from
	uncarriedMu.Unlock()
	// Normally clearUncarried() closes this the moment the call ends. If no
	// terminate ever arrives, the ringing notice would otherwise keep
	// claiming there is an incoming call: after 45 seconds it is replaced
	// by the plain missed-call notice and logged in the chat.
	go func() {
		for i := 0; i < 45; i++ {
			time.Sleep(time.Second)
			uncarriedMu.Lock()
			_, still := uncarried[callID]
			uncarriedMu.Unlock()
			if !still {
				return
			}
		}
		clearUncarried(callID)
		addMessage(Message{
			ID: "call-" + callID, Sender: pn.User, Text: "📞 Missed call",
			Timestamp: time.Now().Unix(), FromMe: false, ChatJID: pn.User,
		})
		fmt.Printf("📞 uncarried call %s timed out - marked as missed\n", callID)
		notifyMissedCall(pn.User, name)
	}()
}

var (
	uncarriedMu   sync.Mutex
	uncarried     = map[string]*callSession{}
	uncarriedFrom = map[string]types.JID{}
)

// clearUncarried closes the ringing notification of a call the voice stack
// could not take, as soon as that call is over.
func clearUncarried(callID string) {
	uncarriedMu.Lock()
	s := uncarried[callID]
	delete(uncarried, callID)
	delete(uncarriedFrom, callID)
	uncarriedMu.Unlock()
	if s != nil {
		closeCallNotification(s)
	}
}

// rejectUncarriedCall declines a call the voice stack could not take.
func rejectUncarriedCall(callID string) {
	uncarriedMu.Lock()
	s := uncarried[callID]
	from, ok := uncarriedFrom[callID]
	uncarriedMu.Unlock()
	if s != nil {
		closeCallNotification(s)
	}
	if ok && client != nil {
		if err := client.RejectCall(ctx, from, callID); err != nil {
			fmt.Printf("📞 reject uncarried call: %v\n", err)
		}
	}
}

// notifyMissedCall posts a plain, quiet notice about a call that was not
// taken. Deliberately not a call notification: no ringtone feedback, no
// urgency 2, no display wake-up and no answer/decline buttons - the call
// is over, so all that is left is the note. Tapping opens the chat.
func notifyMissedCall(chatJid, name string) {
	conn, err := dbus.SessionBus()
	if err != nil {
		return
	}
	prefsMutex.RLock()
	title := prefs["call_missed_label"]
	sound := prefs["notif_sound"] != "0"
	vibrate := prefs["notif_vibrate"] != "0"
	prefsMutex.RUnlock()
	if title == "" {
		title = "Missed WhatsApp call"
	}
	hints := map[string]dbus.Variant{
		"x-nemo-preview-summary": dbus.MakeVariant(title),
		"x-nemo-preview-body":    dbus.MakeVariant(name),
		// Same category as a chat notification. NOT x-nemo.call.missed:
		// lipstick fills a category's defaults from its .conf file, and
		// the call categories bring the ringtone feedback with them -
		// which then rings on, because a ringtone event only stops when
		// the notification is closed, and a missed call never closes.
		"category": dbus.MakeVariant("x-nemo.messaging.im"),
		"x-nemo-remote-action-default": dbus.MakeVariant(
			"harbour.harbour-whatsapp / harbour.whatsapp.Gui openChat string:'" + chatJid + "'"),
	}
	// Sound and vibration follow the message switches, with the gentle
	// chat feedback. Always set explicitly, even when empty: an absent
	// hint would let the category defaults decide again.
	fb := []string{}
	if sound {
		fb = append(fb, "chat")
	}
	if vibrate {
		fb = append(fb, "vibra")
	}
	hints["x-nemo-feedback"] = dbus.MakeVariant(strings.Join(fb, ","))
	obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
	c := obj.Call("org.freedesktop.Notifications.Notify", 0,
		notifAppName(), uint32(0), "harbour-whatsapp", title, name,
		[]string{"default", ""}, hints, int32(-1))
	if c.Err != nil {
		fmt.Printf("📞 missed call notification failed: %v\n", c.Err)
	}
}

// importCallLog turns the phone's call log (delivered with a history sync)
// into chat entries. Only calls we never saw ourselves are added, and only
// those that ended without us: a missed call while the connection was down
// is exactly the case this covers. Entries older than callLogMaxAge are
// ignored so an initial sync does not announce last month's calls.
const callLogMaxAge = 24 * time.Hour

func importCallLog(records []*waSyncAction.CallLogRecord) {
	if len(records) == 0 {
		return
	}
	own := ""
	if client != nil && client.Store != nil && client.Store.ID != nil {
		own = client.Store.ID.User
	}
	added := 0
	for _, rec := range records {
		if rec == nil || rec.GetCallID() == "" {
			continue
		}
		id := rec.GetCallID()
		if callHandledLocally(id) {
			continue // we carried this call ourselves
		}
		started := time.Unix(rec.GetStartTime(), 0)
		if rec.GetStartTime() <= 0 || time.Since(started) > callLogMaxAge {
			continue
		}
		peer := ""
		if j, err := types.ParseJID(rec.GetCallCreatorJID()); err == nil {
			peer = resolvePN(j.ToNonAD(), types.EmptyJID).User
		}
		if peer == "" || peer == own {
			continue
		}
		chatJid := peer
		if g := rec.GetGroupJID(); g != "" {
			if j, err := types.ParseJID(g); err == nil {
				chatJid = j.ToNonAD().User
			}
		}
		var text string
		switch rec.GetCallResult() {
		case waSyncAction.CallLogRecord_MISSED:
			text = "📞 Missed call"
		case waSyncAction.CallLogRecord_UNAVAILABLE, waSyncAction.CallLogRecord_CANCELLED:
			text = "📞 Missed call"
		case waSyncAction.CallLogRecord_ACCEPTEDELSEWHERE:
			text = "📞 Incoming call (answered on your phone)"
		case waSyncAction.CallLogRecord_REJECTED:
			text = "📞 Declined call"
		default:
			continue // connected, upcoming or invalid: nothing to announce
		}
		if rec.GetIsVideo() {
			text += " (video)"
		}
		before := messageExists("call-" + id)
		addMessage(Message{
			ID: "call-" + id, Sender: peer, Text: text,
			Timestamp: started.Unix(), FromMe: !rec.GetIsIncoming(), ChatJID: chatJid,
		})
		if before {
			continue // already known - do not announce again
		}
		added++
		fmt.Printf("📞 call log: %s from %s at %s\n", text, chatJid, started.Format("15:04:05"))
		if rec.GetIsIncoming() && rec.GetCallResult() == waSyncAction.CallLogRecord_MISSED {
			go notifyMissedCall(chatJid, callDisplayName(peer, "", false))
		}
	}
	if added > 0 {
		bumpEvent()
	}
}

func onIncomingCall(call *meowcaller.Call) {
	callMu.Lock()
	if curCall != nil && curCall.phase() != "ended" {
		callMu.Unlock()
		fmt.Printf("📞 busy - rejecting call %s from %s\n", call.ID(), call.Peer())
		_ = call.Reject()
		return
	}
	s := newCallSession(call, false)
	s.Phase = "ringing"
	curCall = s
	callSeen[s.ID] = true
	callMu.Unlock()
	s.wire()
	fmt.Printf("📞 incoming call %s from %s (%s)\n", s.ID, s.Peer, s.Name)
	mceCallState("ringing")
	// Always ring ourselves. The plugin acknowledging a call only proves it
	// registered a handler with the call engine - the field log shows
	// "system call UI took call" for calls that never appeared or rang
	// anywhere. A notification we control is the one thing that reliably
	// reaches the user; if the system UI does show the call as well, both
	// stop together when the call is answered or declined.
	s.notifyRinging()
	if pluginActive() {
		fmt.Println("📞 system call UI present - ringing anyway until it proves it shows the call")
	}
	bumpEvent()
}

func startCall(user string) (*callSession, error) {
	if callClient == nil || client == nil || !isConnected {
		return nil, fmt.Errorf("not connected")
	}
	callMu.Lock()
	busy := curCall != nil && curCall.phase() != "ended"
	callMu.Unlock()
	if busy {
		return nil, fmt.Errorf("another call is in progress")
	}
	target := user
	if !strings.Contains(target, "@") {
		target = user + "@" + types.DefaultUserServer
	}
	call, err := callClient.Call(ctx, target)
	if err != nil {
		return nil, err
	}
	s := newCallSession(call, true)
	if s.Peer == "" || s.PeerIsLid && !strings.Contains(user, "@") {
		// keep the number the user dialled as the chat key
		s.Peer = user
		s.PeerIsLid = false
		s.Name = callDisplayName(user, "", false)
	}
	s.Phase = phaseName(call.State())
	if s.Phase == "idle" || s.Phase == "ended" {
		s.Phase = "calling"
	}
	callMu.Lock()
	curCall = s
	callSeen[s.ID] = true
	callMu.Unlock()
	s.wire()
	mceCallState("active")
	fmt.Printf("📞 outgoing call %s to %s (%s)\n", s.ID, s.Peer, s.Name)
	// Audio right away for the ringback tone; the mic stays idle until
	// the engine starts pulling frames
	s.startAudio()
	s.mu.Lock()
	if s.audio != nil && s.Phase != "ended" {
		s.audio.SetRingback(true)
	}
	s.mu.Unlock()
	bumpEvent()
	return s, nil
}

// ---- MCE: the system's own call mode (display on while ringing,
// proximity blanking during the call) - the same D-Bus call the phone
// app makes, no sensor access needed on our side ----
func mceCallState(state string) {
	conn, err := dbus.SystemBus()
	if err != nil {
		return
	}
	obj := conn.Object("com.nokia.mce", "/com/nokia/mce/request")
	var ok bool
	if err := obj.Call("com.nokia.mce.request.req_call_state_change", 0, state, "normal").Store(&ok); err != nil {
		fmt.Printf("📞 mce call state %s: %v\n", state, err)
	}
}

// ---- Notification with ringtone feedback ----
func (s *callSession) notifyRinging() {
	conn, err := dbus.SessionBus()
	if err != nil {
		fmt.Printf("📞 notification bus error: %v\n", err)
		return
	}
	prefsMutex.RLock()
	answerLabel := prefs["call_answer_label"]
	declineLabel := prefs["call_decline_label"]
	title := prefs["call_incoming_label"]
	prefsMutex.RUnlock()
	if answerLabel == "" {
		answerLabel = "Answer"
	}
	if declineLabel == "" {
		declineLabel = "Decline"
	}
	if title == "" {
		title = "Incoming WhatsApp call"
	}
	gui := "harbour.harbour-whatsapp / harbour.whatsapp.Gui "
	hints := map[string]dbus.Variant{
		"x-nemo-preview-summary":       dbus.MakeVariant(title),
		"x-nemo-preview-body":          dbus.MakeVariant(s.Name),
		"urgency":                      dbus.MakeVariant(byte(2)),
		"x-nemo-display-on":            dbus.MakeVariant(true),
		"x-nemo-feedback":              dbus.MakeVariant("ringtone"),
		"x-nemo-remote-action-default": dbus.MakeVariant(gui + "openCall"),
		"x-nemo-remote-action-answer":  dbus.MakeVariant(gui + "answerCall"),
		"x-nemo-remote-action-decline": dbus.MakeVariant(gui + "declineCall"),
	}
	obj := conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
	var id uint32
	call := obj.Call("org.freedesktop.Notifications.Notify", 0,
		notifAppName(), uint32(0), "harbour-whatsapp", title, s.Name,
		[]string{"default", "", "answer", answerLabel, "decline", declineLabel}, hints, int32(0))
	if call.Err != nil {
		fmt.Printf("📞 ring notification failed: %v\n", call.Err)
		return
	}
	call.Store(&id)
	s.mu.Lock()
	s.notifID = id
	s.mu.Unlock()
}

func closeCallNotification(s *callSession) {
	s.mu.Lock()
	id := s.notifID
	s.notifID = 0
	s.mu.Unlock()
	if id == 0 {
		return
	}
	if conn, err := dbus.SessionBus(); err == nil {
		conn.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications").
			Call("org.freedesktop.Notifications.CloseNotification", 0, id)
	}
}

// ---- HTTP ----
func callStateJSON() map[string]interface{} {
	callMu.Lock()
	s := curCall
	callMu.Unlock()
	if s == nil {
		return map[string]interface{}{"active": false}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	secs := 0
	if !s.Started.IsZero() {
		end := s.Ended
		if end.IsZero() {
			end = time.Now()
		}
		secs = int(end.Sub(s.Started).Seconds())
	}
	var micLevel, spkLevel float32
	if s.audio != nil {
		micLevel, spkLevel = s.audio.Levels()
	}
	return map[string]interface{}{
		"plugin":     pluginActive(),
		"micLevel":   micLevel,
		"spkLevel":   spkLevel,
		"active":     s.Phase != "ended",
		"id":         s.ID,
		"peer":       s.Peer,
		"peerIsLid":  s.PeerIsLid,
		"name":       s.Name,
		"outgoing":   s.Outgoing,
		"phase":      s.Phase,
		"reason":     s.Reason,
		"seconds":    secs,
		"muted":      s.Muted,
		"speaker":    s.Speaker,
		"audioError": s.AudioErr,
		"audioUp":    s.audio != nil,
		"answered":   s.Answered,
	}
}

func writeCallJSON(w http.ResponseWriter, extra map[string]interface{}) {
	st := callStateJSON()
	for k, v := range extra {
		st[k] = v
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(st)
}

func currentCall() *callSession {
	callMu.Lock()
	s := curCall
	callMu.Unlock()
	if s == nil || s.phase() == "ended" {
		return nil
	}
	return s
}

func registerCallHandlers() {
	http.HandleFunc("/call/state", func(w http.ResponseWriter, r *http.Request) {
		notePlugin(r)
		writeCallJSON(w, nil)
	})
	http.HandleFunc("/call/start", func(w http.ResponseWriter, r *http.Request) {
		jid := strings.TrimSpace(r.URL.Query().Get("jid"))
		if jid == "" {
			writeCallJSON(w, map[string]interface{}{"error": "jid required"})
			return
		}
		if _, err := startCall(jid); err != nil {
			writeCallJSON(w, map[string]interface{}{"error": "Call failed: " + err.Error()})
			return
		}
		writeCallJSON(w, map[string]interface{}{"ok": true})
	})
	http.HandleFunc("/call/accept", func(w http.ResponseWriter, r *http.Request) {
		s := currentCall()
		if s == nil {
			writeCallJSON(w, map[string]interface{}{"error": "no call"})
			return
		}
		s.mu.Lock()
		s.Answered = true
		s.mu.Unlock()
		closeCallNotification(s)
		if err := s.call.Answer(); err != nil {
			writeCallJSON(w, map[string]interface{}{"error": "Answer failed: " + err.Error()})
			return
		}
		mceCallState("active")
		bumpEvent()
		writeCallJSON(w, map[string]interface{}{"ok": true})
	})
	http.HandleFunc("/call/reject", func(w http.ResponseWriter, r *http.Request) {
		s := currentCall()
		if s == nil {
			writeCallJSON(w, map[string]interface{}{"error": "no call"})
			return
		}
		closeCallNotification(s)
		err := s.call.Reject()
		if err != nil {
			fmt.Printf("📞 reject: %v\n", err)
		}
		s.finish("declined")
		writeCallJSON(w, map[string]interface{}{"ok": err == nil})
	})
	http.HandleFunc("/call/hangup", func(w http.ResponseWriter, r *http.Request) {
		s := currentCall()
		if s == nil {
			writeCallJSON(w, map[string]interface{}{"error": "no call"})
			return
		}
		closeCallNotification(s)
		err := s.call.Hangup()
		if err != nil {
			fmt.Printf("📞 hangup: %v\n", err)
		}
		s.finish("hangup")
		writeCallJSON(w, map[string]interface{}{"ok": err == nil})
	})
	http.HandleFunc("/call/mute", func(w http.ResponseWriter, r *http.Request) {
		s := currentCall()
		if s == nil {
			writeCallJSON(w, map[string]interface{}{"error": "no call"})
			return
		}
		on := r.URL.Query().Get("on") == "1"
		s.mu.Lock()
		s.Muted = on
		a := s.audio
		s.mu.Unlock()
		if a != nil {
			a.SetMuted(on)
		}
		bumpEvent()
		writeCallJSON(w, map[string]interface{}{"ok": true})
	})
	http.HandleFunc("/call/speaker", func(w http.ResponseWriter, r *http.Request) {
		s := currentCall()
		if s == nil {
			writeCallJSON(w, map[string]interface{}{"error": "no call"})
			return
		}
		on := r.URL.Query().Get("on") == "1"
		s.mu.Lock()
		s.Speaker = on
		a := s.audio
		s.mu.Unlock()
		if a != nil {
			if err := a.SetSpeaker(on); err != nil {
				writeCallJSON(w, map[string]interface{}{"error": "Speaker switch failed: " + err.Error()})
				return
			}
		}
		bumpEvent()
		writeCallJSON(w, map[string]interface{}{"ok": true})
	})
	// The plugin calls this once it has handed a call to the call engine
	http.HandleFunc("/call/rejectraw", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		if id != "" {
			rejectUncarriedCall(id)
		}
		writeCallJSON(w, map[string]interface{}{"ok": id != ""})
	})
	http.HandleFunc("/call/uiack", func(w http.ResponseWriter, r *http.Request) {
		notePlugin(r)
		id := r.URL.Query().Get("id")
		if id != "" {
			noteCallAck(id)
			fmt.Printf("📞 system call UI took call %s\n", id)
			// Die System-UI klingelt selbst - unsere eigene Klingel-
			// Benachrichtigung kann jetzt weg, sonst laeutet es doppelt.
			// Sie wurde trotzdem gesendet, weil die Quittung erst kommt,
			// wenn die Uebergabe wirklich geklappt hat.
			callMu.Lock()
			s := curCall
			callMu.Unlock()
			if s != nil && s.ID == id && s.phase() != "ended" {
				closeCallNotification(s)
			}
		}
		writeCallJSON(w, map[string]interface{}{"ok": id != ""})
	})
	http.HandleFunc("/call/dismiss", func(w http.ResponseWriter, r *http.Request) {
		callMu.Lock()
		if curCall != nil && curCall.phase() == "ended" {
			curCall = nil
		}
		callMu.Unlock()
		bumpEvent()
		writeCallJSON(w, map[string]interface{}{"ok": true})
	})
}
