package main

import "testing"

// Statusmeldungen zeigten Ziffernfolgen, die wie fremde Rufnummern aussehen
// und keine sind: LIDs, WhatsApps versteckte Adressierung. Eine Antwort
// dorthin haette womoeglich jemand voellig Fremden erreicht.
func TestPlausiblePhoneNumber(t *testing.T) {
	real := []string{
		"436766517141",  // AT
		"436781311768",  // AT
		"4926461743244", // DE, 13 Stellen
		"4369981374393", // AT, 13 Stellen
		"12025550123",   // US
		"33612345678",   // FR
		"85212345678",   // HK
		"9711234567",    // AE
	}
	for _, n := range real {
		if !plausiblePhoneNumber(n) {
			t.Errorf("echte Rufnummer %s wurde als LID eingestuft", n)
		}
	}

	lids := []string{
		"108074329239773", // 15 Stellen
		"134080322617393",
		"175290651271319",
		"206265988952162",
		"20590073229563", // 14 Stellen, beginnt zwar mit 20 (Aegypten)
		"71734594162780", // 14 Stellen
	}
	// 5184193331367 und 6098937458744 sind ebenfalls LIDs, lassen sich aber
	// ueber die Vorwahl NICHT erkennen: 518 beginnt mit 51 (Peru), 609 mit
	// 60 (Malaysia), und die Laenge passt zu einer echten Nummer. Genau
	// deshalb haengt der Antwort-Knopf nicht an dieser Schaetzung, sondern
	// an SenderKnown - siehe TestReplyOnlyForKnownSenders.
	for _, n := range lids {
		if plausiblePhoneNumber(n) {
			t.Errorf("LID %s wurde fuer eine Rufnummer gehalten", n)
		}
	}
}

func TestPlausiblePhoneNumberEdges(t *testing.T) {
	bad := []string{"", "12", "1234567", "43abc1234567", "+436766517141",
		"1234567890123456"}
	for _, n := range bad {
		if plausiblePhoneNumber(n) {
			t.Errorf("%q darf nicht als Rufnummer gelten", n)
		}
	}
}

// Der Antwort-Knopf darf sich nie auf die Vorwahl-Schaetzung verlassen:
// eine Antwort an die falsche Nummer erreicht einen Fremden.
func TestReplyOnlyForKnownSenders(t *testing.T) {
	contactsMutex.Lock()
	contacts["436781311768"] = "Bekannte Person"
	contacts["5184193331367"] = ""
	contactsMutex.Unlock()
	out := annotateSenders([]Message{
		{Sender: "436781311768"},   // im Adressbuch
		{Sender: "5184193331367"},  // leerer Name zaehlt nicht
		{Sender: "436603708434"},   // plausible Nummer, aber unbekannt
	})
	if !out[0].SenderKnown {
		t.Error("bekannter Kontakt nicht als bekannt gemeldet")
	}
	if out[1].SenderKnown {
		t.Error("leerer Name darf nicht als bekannt gelten")
	}
	if out[2].SenderKnown {
		t.Error("unbekannte Nummer wurde als bekannt gemeldet - Antwort ginge ins Blaue")
	}
}

// Der eigene Absender und bereits gekennzeichnete Eintraege bleiben unberuehrt.
func TestAnnotateSendersLeavesOwnAlone(t *testing.T) {
	in := []Message{
		{Sender: "108074329239773", FromMe: true},
		{Sender: "108074329239773", FromMe: false},
		{Sender: "436766517141", FromMe: false},
	}
	out := annotateSenders(in)
	if out[0].SenderIsLid {
		t.Error("eigene Nachricht wurde als LID gekennzeichnet")
	}
	if !out[1].SenderIsLid {
		t.Error("fremde LID wurde nicht erkannt")
	}
	if out[2].SenderIsLid {
		t.Error("echte Rufnummer wurde als LID gekennzeichnet")
	}
	// Die Eingabe darf nicht veraendert werden
	if in[1].SenderIsLid {
		t.Error("annotateSenders hat die gespeicherte Nachricht veraendert")
	}
}
