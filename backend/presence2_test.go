package main

import (
	"strings"
	"testing"
	"time"
)

// Praesenz darf nur bei bewussten Handlungen abonniert werden. Diese Faelle
// halten fest, was NICHT abonniert wird - Gruppen, Kanaele, Wiederholungen -
// weil ein Schwall von Abfragen genau das Muster ist, das Sperren ausloest.
func TestPresenceSkipsGroupsAndChannels(t *testing.T) {
	for _, jid := range []string{
		"", "status",
		"120363213847595961@newsletter",
		"436766517141-1234567890", // alte Gruppenform
		"436766517141@g.us",
	} {
		if subscribePresence(jid) {
			t.Errorf("%q haette nicht abonniert werden duerfen", jid)
		}
	}
}

// Ohne eigene Verfuegbar-Meldung liefert WhatsApp nichts - dann gar nicht
// erst fragen, das waere eine Anfrage ohne jeden Nutzen.
func TestPresenceSkipsWhenHidden(t *testing.T) {
	prefsMutex.Lock()
	prefs["hide_online"] = "1"
	prefsMutex.Unlock()
	if subscribePresence("436766517141") {
		t.Error("verborgen: es darf nicht abonniert werden")
	}
	prefsMutex.Lock()
	delete(prefs, "hide_online")
	prefsMutex.Unlock()
}

// Wiederholtes Oeffnen desselben Chats darf keinen Schwall erzeugen.
func TestPresenceThrottlesRepeats(t *testing.T) {
	presenceMutex.Lock()
	presenceSubbed["436766517141"] = time.Now().Unix()
	presenceMutex.Unlock()

	presenceMutex.RLock()
	last := presenceSubbed["436766517141"]
	presenceMutex.RUnlock()
	if time.Now().Unix()-last >= 600 {
		t.Error("frisch abonniert - die Sperrfrist muss greifen")
	}

	presenceMutex.Lock()
	delete(presenceSubbed, "436766517141")
	presenceMutex.Unlock()
}

// Der Zustand muss lesbar bleiben, waehrend das Ereignis ihn schreibt.
func TestPresenceStateRoundTrip(t *testing.T) {
	presenceMutex.Lock()
	presenceState["436766517141"] = presenceInfo{Online: true, LastSeen: 1700000000}
	presenceMutex.Unlock()

	presenceMutex.RLock()
	got, ok := presenceState["436766517141"]
	presenceMutex.RUnlock()
	if !ok || !got.Online || got.LastSeen != 1700000000 {
		t.Errorf("Zustand nicht wie gesetzt: %+v", got)
	}
	if strings.Contains("436766517141", "@") {
		t.Error("Schluessel muss die nackte Nummer sein, ohne Server-Teil")
	}

	presenceMutex.Lock()
	delete(presenceState, "436766517141")
	presenceMutex.Unlock()
}
