package main

import (
	"os"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// Integrationstest gegen einen ECHTEN Bus mit nachgebautem connman.
// Er prueft, was die Tabellentests nicht koennen: ob Match-Regel,
// Signalname, Pfad und Variant-Auspacken zusammenpassen. Ohne Bus wird
// uebersprungen statt zu scheitern.

type fakeManager struct{ props map[string]dbus.Variant }

func (f *fakeManager) GetProperties() (map[string]dbus.Variant, *dbus.Error) {
	return f.props, nil
}

func TestConnmanSignalRoundTrip(t *testing.T) {
	if os.Getenv("DBUS_SYSTEM_BUS_ADDRESS") == "" {
		t.Skip("kein Test-Systembus gesetzt")
	}
	srv, err := dbus.SystemBus()
	if err != nil {
		t.Skipf("Systembus nicht erreichbar: %v", err)
	}
	mgr := &fakeManager{props: map[string]dbus.Variant{
		"State":       dbus.MakeVariant("idle"),
		"OfflineMode": dbus.MakeVariant(true),
	}}
	if err := srv.Export(mgr, dbus.ObjectPath("/"), "net.connman.Manager"); err != nil {
		t.Fatalf("Export fehlgeschlagen: %v", err)
	}
	reply, err := srv.RequestName("net.connman", dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		t.Fatalf("Namensvergabe fehlgeschlagen: %v / %v", err, reply)
	}

	netState = "unknown"
	drain()
	go watchNetwork()

	// Warten, bis GetProperties gelaufen ist
	deadline := time.Now().Add(5 * time.Second)
	for netState != "idle" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if netState != "idle" {
		t.Fatalf("Anfangszustand nicht uebernommen: %q", netState)
	}
	t.Logf("Anfangszustand von connman gelesen: %s", netState)

	emit := func(name string, v interface{}) {
		if err := srv.Emit(dbus.ObjectPath("/"), "net.connman.Manager.PropertyChanged",
			name, dbus.MakeVariant(v)); err != nil {
			t.Fatalf("Emit fehlgeschlagen: %v", err)
		}
	}

	// WLAN kommt zurueck -> Zustand uebernommen und Weckruf abgesetzt
	emit("State", "online")
	deadline = time.Now().Add(5 * time.Second)
	for netState != "online" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if netState != "online" {
		t.Fatalf("Signal kam nicht an, Zustand blieb %q", netState)
	}
	select {
	case <-connectWake:
		t.Log("Weckruf ausgeloest (network-up)")
	case <-time.After(2 * time.Second):
		t.Fatal("kein Weckruf nach State=online")
	}

	// Fremde Eigenschaft darf nichts ausloesen
	emit("SessionMode", true)
	time.Sleep(300 * time.Millisecond)
	select {
	case <-connectWake:
		t.Fatal("SessionMode hat faelschlich einen Weckruf ausgeloest")
	default:
	}

	// Flugmodus aus
	emit("OfflineMode", false)
	select {
	case <-connectWake:
		t.Log("Weckruf ausgeloest (flight-mode-off)")
	case <-time.After(2 * time.Second):
		t.Fatal("kein Weckruf nach OfflineMode=false")
	}
	drain()
}
