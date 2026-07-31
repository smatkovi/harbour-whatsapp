package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Die Portdatei zeigte nach einem Prozessende auf einen toten Port. Sie darf
// nur geloescht werden, wenn WIR darin stehen - laeuft parallel eine zweite
// Instanz auf einem anderen Port, gehoert der Eintrag ihr.
func TestReleasePortFile(t *testing.T) {
	savedPort := boundPort
	defer func() { boundPort = savedPort }()

	dir := t.TempDir()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)

	write := func(content string) {
		if err := os.WriteFile(filepath.Join(dir, "backend.port"), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	exists := func() bool {
		_, err := os.Stat(filepath.Join(dir, "backend.port"))
		return err == nil
	}

	boundPort = 8085

	write("8085")
	releasePortFile()
	if exists() {
		t.Error("eigener Eintrag wurde nicht entfernt")
	}

	write("8086")
	releasePortFile()
	if !exists() {
		t.Error("fremder Eintrag wurde faelschlich entfernt")
	}

	write("8085\n")
	releasePortFile()
	if exists() {
		t.Error("eigener Eintrag mit Zeilenumbruch wurde nicht entfernt")
	}

	write("kaputt")
	releasePortFile()
	if !exists() {
		t.Error("unlesbarer Eintrag wurde entfernt statt in Ruhe gelassen")
	}

	os.Remove(filepath.Join(dir, "backend.port"))
	releasePortFile() // darf nicht knallen, wenn gar keine Datei da ist
}
