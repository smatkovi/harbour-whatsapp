package main

import (
	"strings"
	"testing"
)

// Die ngfd-Ereignisnamen sind nicht frei waehlbar: [chat] bindet in
// chat.ini nur "haptic" ein (Vibration), [chat_exists] dagegen "default"
// mit Ton UND mce.led_pattern. Jahrelang wurde "chat" gesendet - kein Ton,
// keine LED. Diese Tabelle haelt die vier Faelle fest.
func feedbackFor(sound, vibrate bool) string {
	var fb []string
	if sound {
		fb = append(fb, "chat_exists")
	}
	if vibrate {
		fb = append(fb, "vibra")
	}
	if !sound {
		fb = append(fb, "communication_led")
	}
	return strings.Join(fb, ",")
}

func TestNotificationFeedback(t *testing.T) {
	cases := []struct {
		name             string
		sound, vibrate   bool
		want             string
	}{
		{"beides an", true, true, "chat_exists,vibra"},
		{"nur Ton", true, false, "chat_exists"},
		{"nur Vibration", false, true, "vibra,communication_led"},
		{"beides aus", false, false, "communication_led"},
	}
	for _, c := range cases {
		got := feedbackFor(c.sound, c.vibrate)
		if got != c.want {
			t.Errorf("%s: %q, erwartet %q", c.name, got, c.want)
		}
	}
}

// Der alte Name darf nirgends mehr auftauchen - "chat" als eigenstaendiges
// Element der Liste war der Fehler.
func TestNoBareChatEvent(t *testing.T) {
	for _, s := range []bool{true, false} {
		for _, v := range []bool{true, false} {
			for _, part := range strings.Split(feedbackFor(s, v), ",") {
				if part == "chat" {
					t.Errorf("sound=%v vibrate=%v liefert das wirkungslose Ereignis 'chat'", s, v)
				}
			}
		}
	}
}

// Ohne Ton muss die LED erhalten bleiben: sie haengt am selben Ereignis,
// und wer stumm schaltet, will trotzdem sehen, dass etwas ungelesen ist.
func TestLedSurvivesMuting(t *testing.T) {
	if !strings.Contains(feedbackFor(false, false), "communication_led") {
		t.Error("stumm geschaltet und ohne LED - die ungelesene Nachricht waere unsichtbar")
	}
	if !strings.Contains(feedbackFor(false, true), "communication_led") {
		t.Error("nur Vibration, aber keine LED")
	}
	// Bei eingeschaltetem Ton bringt chat_exists die LED selbst mit
	if strings.Contains(feedbackFor(true, true), "communication_led") {
		t.Error("communication_led doppelt - chat_exists enthaelt das Muster bereits")
	}
}
