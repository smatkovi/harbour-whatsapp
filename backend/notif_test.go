package main

import (
	"net/url"
	"testing"
)

// Die Antwort aus der Benachrichtigung heraus schickte "jid", der Endpunkt las
// "chat" - Ergebnis: 400, und die Benachrichtigung blieb stehen, obwohl man
// geantwortet hatte. Beide Namen muessen tragen.
func TestChatOpenedAcceptsBothNames(t *testing.T) {
	for _, raw := range []string{
		"/chat/opened?chat=436766517141@s.whatsapp.net",
		"/chat/opened?jid=436766517141@s.whatsapp.net",
	} {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		chat := u.Query().Get("chat")
		if chat == "" {
			chat = u.Query().Get("jid")
		}
		if chat == "" {
			t.Errorf("%s: kein Chat erkannt - die Benachrichtigung bliebe stehen", raw)
		}
	}
	u, _ := url.Parse("/chat/opened")
	chat := u.Query().Get("chat")
	if chat == "" {
		chat = u.Query().Get("jid")
	}
	if chat != "" {
		t.Error("ohne Angabe darf nichts erkannt werden")
	}
}

// Der Anzeigename der Benachrichtigung muss dem der App folgen, sonst stehen
// nach dem Umbenennen zwei Absender im Ereignisfeld nebeneinander.
func TestNotifAppNameFollowsSetting(t *testing.T) {
	prefsMutex.Lock()
	delete(prefs, "app_name")
	prefsMutex.Unlock()
	if got := notifAppName(); got != "WhatsApp" {
		t.Errorf("ohne Einstellung erwartet WhatsApp, bekommen %q", got)
	}

	prefsMutex.Lock()
	prefs["app_name"] = "WhatsSail"
	prefsMutex.Unlock()
	if got := notifAppName(); got != "WhatsSail" {
		t.Errorf("erwartet WhatsSail, bekommen %q", got)
	}

	prefsMutex.Lock()
	delete(prefs, "app_name")
	prefsMutex.Unlock()
}
