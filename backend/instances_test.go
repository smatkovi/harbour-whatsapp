package main

import (
	"fmt"
	"net"
	"net/http"
	"testing"
)

// Die Ein-Verbindungs-Wache muss in BEIDEN Rollen gleich urteilen: als
// Daemon und als Kind-Backend der App. Der Zwei-Instanzen-Streit war die
// Ursache der Server-Abmeldung - hier wird er nachgestellt.

func serveStatus(t *testing.T, port int, connected bool, daemon bool) func() {
	t.Helper()
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Skipf("Port %d belegt: %v", port, err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"connected":%v,"daemon":%v,"paired":true,"state":"connected","version":"0.9.192"}`,
			connected, daemon)
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	return func() { srv.Close(); ln.Close() }
}

func TestAnotherInstanceDetection(t *testing.T) {
	savedPort, savedDaemon := boundPort, isDaemon
	defer func() { boundPort, isDaemon = savedPort, savedDaemon }()

	// Rolle spielt fuer die Erkennung keine Rolle - beide Rollen pruefen
	for _, role := range []struct {
		name   string
		daemon bool
	}{{"als Daemon", true}, {"als Kind-Backend der App", false}} {
		isDaemon = role.daemon
		boundPort = 8085

		t.Run(role.name+"/niemand sonst da", func(t *testing.T) {
			if anotherInstanceConnected() {
				t.Error("meldet fremde Instanz, obwohl keine laeuft")
			}
		})

		t.Run(role.name+"/andere Instanz haelt die Session", func(t *testing.T) {
			stop := serveStatus(t, 8087, true, !role.daemon)
			defer stop()
			if !anotherInstanceConnected() {
				t.Error("fremde verbundene Instanz nicht erkannt - beide wuerden um die Session kaempfen")
			}
		})

		t.Run(role.name+"/andere Instanz ist NICHT verbunden", func(t *testing.T) {
			stop := serveStatus(t, 8087, false, !role.daemon)
			defer stop()
			if anotherInstanceConnected() {
				t.Error("nicht verbundene Instanz blockiert uns faelschlich")
			}
		})

		t.Run(role.name+"/eigener Port wird uebersprungen", func(t *testing.T) {
			stop := serveStatus(t, 8085, true, role.daemon)
			defer stop()
			if anotherInstanceConnected() {
				t.Error("haelt sich selbst fuer eine fremde Instanz - Dauerstandby waere die Folge")
			}
		})
	}
}

// Der Minuten-Waechter darf im Standby nicht dazwischenfunken, egal in
// welcher Rolle.
func TestWatchdogRespectsStandbyInBothRoles(t *testing.T) {
	saved := isDaemon
	defer func() { isDaemon = saved }()
	for _, d := range []bool{true, false} {
		isDaemon = d
		if watchdogShouldConnect("standby", false, "online") {
			t.Errorf("isDaemon=%v: Waechter wuerde im Standby verbinden", d)
		}
		if !watchdogShouldConnect("reconnecting", false, "online") {
			t.Errorf("isDaemon=%v: Waechter verbindet nicht, obwohl er sollte", d)
		}
	}
}
