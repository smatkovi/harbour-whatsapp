package main

import (
	"testing"
	"time"
)

// Die Wache gegen Verbindungsstuerme ist der Teil, dessen Versagen teuer ist -
// eine Server-Abmeldung und eine Kontobeschraenkung waren die Rechnung.
// Deshalb liegen ihre Entscheidungen hier als Tabelle vor.

func TestReconnectDelayLadder(t *testing.T) {
	saved := consecReconnects
	defer func() { consecReconnects = saved }()

	cases := []struct {
		attempts int
		want     time.Duration
	}{
		{0, 0},
		// Seit 0.9.289 laeuft der erste Versuch sofort: ein Anruf, der
		// waehrend der Trennung angeboten wird, ist endgueltig verloren -
		// der Server liefert ihn nie nach. Die Staffelung beginnt daher
		// erst beim zweiten Versuch.
		{1, 0},
		{2, 5 * time.Second},
		{3, 10 * time.Second},
		{4, 20 * time.Second},
		{5, 40 * time.Second},
		{6, 80 * time.Second},
		{7, 160 * time.Second},
		{8, 5 * time.Minute}, // 320 s, vom Deckel gestutzt
		{20, 5 * time.Minute},
		// Jenseits von 61 lief die alte Formel in int64 ueber und lieferte 0.
		// Nach etwa fuenf Stunden ohne Netz waere daraus ein Zehn-Sekunden-
		// Takt geworden - genau der Sturm, den die Wache verhindern soll.
		{61, 5 * time.Minute},
		{62, 5 * time.Minute},
		{64, 5 * time.Minute},
		{128, 5 * time.Minute},
		{10000, 5 * time.Minute},
	}
	for _, c := range cases {
		consecReconnects = c.attempts
		if got := reconnectDelay(); got != c.want {
			t.Errorf("nach %d Fehlversuchen: %v, erwartet %v", c.attempts, got, c.want)
		}
	}
}

func TestReconnectDelayNeverNegative(t *testing.T) {
	saved := consecReconnects
	defer func() { consecReconnects = saved }()
	for n := -5; n < 200; n++ {
		consecReconnects = n
		if d := reconnectDelay(); d < 0 {
			t.Fatalf("negative Wartezeit bei %d Versuchen: %v", n, d)
		}
	}
}

func TestWatchdogDecisions(t *testing.T) {
	cases := []struct {
		name      string
		state     string
		connected bool
		net       string
		want      bool
	}{
		{"verbunden, alles gut", "connected", true, "online", false},
		{"getrennt bei Netz", "reconnecting", false, "online", true},
		{"getrennt, Netz ready", "reconnecting", false, "ready", true},
		{"getrennt im Funkloch", "reconnecting", false, "offline", false},
		{"getrennt, connman idle", "reconnecting", false, "idle", false},
		{"connman unbekannt -> probieren", "reconnecting", false, "unknown", true},
		{"abgemeldet, nicht anfassen", "logged_out", false, "online", false},
		{"Neuanmeldung noetig", "relogin_required", false, "online", false},
		{"wartet auf Pairing", "waiting_for_pair", false, "online", false},
		{"andere Instanz haelt Session", "standby", false, "online", false},
		{"Fehlerzustand darf es versuchen", "error", false, "online", true},
	}
	for _, c := range cases {
		if got := watchdogShouldConnect(c.state, c.connected, c.net); got != c.want {
			t.Errorf("%s: %v, erwartet %v", c.name, got, c.want)
		}
	}
}

func TestNetworkPropertyHandling(t *testing.T) {
	saved := netState
	defer func() { netState = saved }()

	cases := []struct {
		name      string
		start     string
		prop      string
		val       interface{}
		connected bool
		want      string
		wantState string
	}{
		{"WLAN kommt", "offline", "State", "online", false, "network-up", "online"},
		{"Datenverbindung steht", "idle", "State", "ready", false, "network-up", "ready"},
		{"online, aber schon verbunden", "idle", "State", "online", true, "", "online"},
		{"Netz faellt weg", "online", "State", "idle", false, "", "idle"},
		{"unveraendert -> kein Laerm", "online", "State", "online", false, "", "online"},
		{"leerer Wert", "online", "State", "", false, "", "online"},
		{"Flugmodus aus", "idle", "OfflineMode", false, false, "flight-mode-off", "idle"},
		{"Flugmodus an", "online", "OfflineMode", true, false, "", "online"},
		{"Flugmodus aus, schon verbunden", "online", "OfflineMode", false, true, "", "online"},
		{"fremde Eigenschaft", "online", "SessionMode", true, false, "", "online"},
		{"falscher Typ", "online", "OfflineMode", "nein", false, "", "online"},
	}
	for _, c := range cases {
		netState = c.start
		got := handleNetworkProperty(c.prop, c.val, c.connected)
		if got != c.want {
			t.Errorf("%s: Grund %q, erwartet %q", c.name, got, c.want)
		}
		if netState != c.wantState {
			t.Errorf("%s: netState %q, erwartet %q", c.name, netState, c.wantState)
		}
	}
}

// Kehrt das Netz zurueck, darf ein laufender Backoff-Schlaf nicht bis zu
// fuenf Minuten ausgesessen werden.
func TestWakeAbortsBackoff(t *testing.T) {
	drain()
	start := time.Now()
	done := make(chan time.Duration, 1)
	go func() {
		select {
		case <-time.After(2 * time.Second):
			done <- time.Since(start)
		case <-connectWake:
			done <- time.Since(start)
		}
	}()
	time.Sleep(100 * time.Millisecond)
	select {
	case connectWake <- struct{}{}:
	default:
		t.Fatal("Weckkanal nahm das Signal nicht an")
	}
	elapsed := <-done
	if elapsed > 500*time.Millisecond {
		t.Errorf("Schlaf wurde nicht unterbrochen: %v", elapsed)
	}
}

// Ein Weckruf ohne Wartenden darf nicht blockieren - sonst haengt der
// Netzbeobachter beim naechsten Zustandswechsel fest.
func TestWakeDoesNotBlockWithoutSleeper(t *testing.T) {
	drain()
	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			select {
			case connectWake <- struct{}{}:
			default:
			}
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Weckruf blockierte ohne Wartenden")
	}
	drain()
}

func drain() {
	for {
		select {
		case <-connectWake:
		default:
			return
		}
	}
}
