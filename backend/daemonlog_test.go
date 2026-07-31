package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// Der Daemon protokollierte ins Journal, das auf dem Geraet fluechtig und
// fuer den Nutzer unlesbar ist. Diese Tests pruefen, dass seine Ausgabe
// wirklich in einer Datei landet - und dass die App-Instanz unberuehrt
// bleibt, die ihr eigenes Protokoll behaelt.

func withRestoredStdout(t *testing.T, fn func()) {
	t.Helper()
	savedOut, err := unix.Dup(1)
	if err != nil {
		t.Skipf("Dup nicht moeglich: %v", err)
	}
	savedErr, err := unix.Dup(2)
	if err != nil {
		unix.Close(savedOut)
		t.Skipf("Dup nicht moeglich: %v", err)
	}
	defer func() {
		unix.Dup3(savedOut, 1, 0)
		unix.Dup3(savedErr, 2, 0)
		unix.Close(savedOut)
		unix.Close(savedErr)
	}()
	fn()
}

func TestDaemonLogCapturesOutput(t *testing.T) {
	saved := isDaemon
	defer func() { isDaemon = saved }()
	dir := t.TempDir()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)

	isDaemon = true
	marker := "MARKER-4711-daemon-schreibt-mit"
	withRestoredStdout(t, func() {
		redirectDaemonOutput()
		fmt.Println(marker)
		fmt.Fprintln(os.Stderr, marker+"-stderr")
		os.Stdout.Sync()
	})

	b, err := os.ReadFile(filepath.Join(dir, "daemon.log"))
	if err != nil {
		t.Fatalf("daemon.log fehlt: %v", err)
	}
	if !strings.Contains(string(b), marker) {
		t.Error("Ausgabe von stdout fehlt im Protokoll")
	}
	if !strings.Contains(string(b), marker+"-stderr") {
		t.Error("Ausgabe von stderr fehlt im Protokoll")
	}
}

func TestAppInstanceDoesNotRedirect(t *testing.T) {
	saved := isDaemon
	defer func() { isDaemon = saved }()
	dir := t.TempDir()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)

	isDaemon = false
	redirectDaemonOutput()
	if _, err := os.Stat(filepath.Join(dir, "daemon.log")); err == nil {
		t.Error("App-Instanz hat daemon.log angelegt - ihre Ausgabe gehoert in backend.log")
	}
}

func TestDaemonLogTrimmedAtStartup(t *testing.T) {
	saved := isDaemon
	defer func() { isDaemon = saved }()
	dir := t.TempDir()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)

	path := filepath.Join(dir, "daemon.log")
	big := strings.Repeat("alte Zeile die niemand mehr braucht\n", 30000) // ~1 MB
	if err := os.WriteFile(path, []byte(big+"LETZTE-ZEILE\n"), 0600); err != nil {
		t.Fatal(err)
	}
	isDaemon = true
	withRestoredStdout(t, func() { redirectDaemonOutput() })

	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() > 200*1024 {
		t.Errorf("Protokoll nicht gestutzt: %d Bytes", st.Size())
	}
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), "[log trimmed at startup]") {
		t.Error("Schnittmarke fehlt")
	}
	if !strings.Contains(string(b), "LETZTE-ZEILE") {
		t.Error("das Ende des Protokolls wurde weggeworfen statt der Anfang")
	}
}
