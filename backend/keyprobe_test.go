package main

import (
	"os"
	"testing"
)

// Der Start nahm den ersten gefundenen Schluessel, ohne ihn zu erproben.
// Lag in einer Uebergabe-Kopie eine veraltete Fassung, scheiterte das
// Oeffnen mit "file is not a database" - und die Sammlung mit dem richtigen
// Schluessel wurde nie erreicht. Der Verlauf sah verloren aus, war es aber
// nicht.
func TestKeyOpensDatabaseWithoutFile(t *testing.T) {
	dir := t.TempDir()
	old, _ := os.Getwd()
	defer os.Chdir(old)
	os.Chdir(dir)

	// Frische Installation: es gibt nichts zu oeffnen, jeder Schluessel passt
	if !keyOpensDatabase(make([]byte, 32)) {
		t.Error("ohne wa.db muss jeder Schluessel als brauchbar gelten")
	}
}

func TestKeyOpensDatabaseRejectsWrongKey(t *testing.T) {
	dir := t.TempDir()
	old, _ := os.Getwd()
	defer os.Chdir(old)
	os.Chdir(dir)

	// Eine Datei, die keine Datenbank ist - so sieht es aus, wenn der
	// Schluessel nicht passt
	if err := os.WriteFile("wa.db", []byte("nicht mal ansatzweise eine Datenbank"), 0600); err != nil {
		t.Fatal(err)
	}
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	if keyOpensDatabase(key) {
		t.Error("eine unlesbare Datei darf nicht als geoeffnet gelten")
	}
}

func TestKeyOpensDatabaseRejectsShortKey(t *testing.T) {
	dir := t.TempDir()
	old, _ := os.Getwd()
	defer os.Chdir(old)
	os.Chdir(dir)
	os.WriteFile("wa.db", []byte("x"), 0600)

	if keyOpensDatabase([]byte("zu kurz")) {
		t.Error("ein Schluessel falscher Laenge darf nie durchgehen")
	}
}
