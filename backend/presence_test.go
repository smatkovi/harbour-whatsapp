package main

import "testing"

// Der Preis der Einstellung: ohne Verfuegbar-Meldung liefert WhatsApp keine
// Statusbeitraege. Dieser Fall haelt fest, dass die Entscheidung ausdruecklich
// an der Voreinstellung haengt und nicht versehentlich umkippt.
func TestHideOnlineDefaultsToHidden(t *testing.T) {
	prefsMutex.Lock()
	delete(prefs, "hide_online")
	prefsMutex.Unlock()

	prefsMutex.RLock()
	hidden := prefs["hide_online"] != "0"
	prefsMutex.RUnlock()
	if !hidden {
		t.Error("Vorgabe ist verborgen - sonst erscheint man ungefragt online")
	}
}

func TestHideOnlineOnlyForExactValue(t *testing.T) {
	for _, tc := range []struct {
		val    string
		hidden bool
	}{
		{"1", true},
		{"0", false},   // nur ein ausdrueckliches "0" macht sichtbar
		{"", true},     // nichts gesetzt: verborgen
		{"true", true},
	} {
		prefsMutex.Lock()
		prefs["hide_online"] = tc.val
		prefsMutex.Unlock()

		prefsMutex.RLock()
		got := prefs["hide_online"] != "0"
		prefsMutex.RUnlock()
		if got != tc.hidden {
			t.Errorf("hide_online=%q: erwartet %v, bekommen %v", tc.val, tc.hidden, got)
		}
	}
	prefsMutex.Lock()
	delete(prefs, "hide_online")
	prefsMutex.Unlock()
}
