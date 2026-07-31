# Testmatrix

Stand: 0.9.193

**Welches Protokoll wohin gehört:** Das App-Backend schreibt nach
`backend.log` (umgeleitet von `start_backend.py`), der Daemon seit 0.9.193
nach `daemon.log` (er lenkt selbst um, weil systemd ihn sonst ins flüchtige
Journal schickt). Beide liegen in
`~/.local/share/harbour/harbour-whatsapp`. Wer nur in `backend.log` sucht,
sieht die halbe Wahrheit — genau dieser Irrtum hat heute mehrere Diagnosen
verzerrt.

Zwei Sorten Fälle stehen hier nebeneinander. **A**-Fälle laufen automatisch und
sollten vor jedem Release grün sein. **G**-Fälle brauchen ein Gerät, weil sie
Sailjail, systemd, connman oder die WhatsApp-Server berühren — sie lassen sich
nicht simulieren, und genau dort saßen bisher die teuersten Fehler.

```bash
sh tests/run.sh            # von ueberall aufrufbar
```

Das Skript ist reines POSIX-sh, weil `/bin/bash` auf dem Geraet BusyBox ist:
`${BASH_SOURCE[0]}` und `trap ... RETURN` gibt es dort nicht, und beides liess
in der ersten Fassung den Repo-Pfad leer werden. Findet es die Repo-Wurzel
nicht, bricht es mit Code 2 ab, statt gegen `/` zu laufen.

Das Skript faehrt alle A-Faelle und sagt am Ende, was durchgefallen ist. Die
Go-Tests laufen bewusst in einer Kopie unter `/tmp`: `go.sum` liegt **nicht**
im Repo, weil die Hashes aus den replace-Umleitungen des Build-Rechners
stammen und einen normalen Build brechen wuerden. Das Skript loest die
Abhaengigkeiten in der Kopie auf und laesst den Arbeitsbaum in Ruhe.

Einzeln, falls man nur eine Sorte braucht — jeweils aus dem
Repo-Wurzelverzeichnis und mit Subshell, damit ein Fehlschlag einen nicht im
Unterverzeichnis stehen laesst:

```bash
( cd backend && go test ./... )       # braucht ein aufgeloestes go.sum, s.o.
node tests/senderror_test.js
python3 tests/daemon_guard_test.py
```

Der connman-Fall braucht einen Bus. Ohne ihn ueberspringt der Test sich
selbst, statt zu scheitern:

```bash
dbus-daemon --config-file=tests/testbus.conf --print-address --fork > /tmp/busaddr
export DBUS_SYSTEM_BUS_ADDRESS=$(cat /tmp/busaddr)
sh tests/run.sh
```

Hinter einer Firewall oder ohne Zugriff auf `go.mau.fi` nimmt das Skript
optionale Umleitungen aus `backend/go.replace.local` (nicht im Repo, steht in
der `.gitignore`) und haengt sie an die Kopie der `go.mod` an.

---

## A — Reconnect-Wache (`backend/reconnect_test.go`)

| ID | Fall | Erwartet |
|----|------|----------|
| A01 | Backoff nach 0 Fehlversuchen | 0 s, sofort verbinden |
| A02 | Backoff nach 1–6 Fehlversuchen | 5, 10, 20, 40, 80, 160 s |
| A03 | Backoff nach 7 Fehlversuchen | 5 min (320 s vom Deckel gestutzt) |
| A04 | Backoff nach 8, 20 Fehlversuchen | 5 min |
| A05 | Backoff nach 61, 62, 64, 128, 10000 | 5 min — **hier lief die alte Formel über und lieferte 0** |
| A06 | Backoff bei negativem Zähler | 0 s, nie negativ |
| A07 | Wartezeit für alle n von −5 bis 200 | niemals negativ |

## A — Minuten-Wächter (`watchdogShouldConnect`)

| ID | Zustand | verbunden | Netz | Erwartet |
|----|---------|-----------|------|----------|
| A08 | connected | ja | online | kein Versuch |
| A09 | reconnecting | nein | online | Versuch |
| A10 | reconnecting | nein | ready | Versuch |
| A11 | reconnecting | nein | offline | kein Versuch (Funkloch) |
| A12 | reconnecting | nein | idle | kein Versuch |
| A13 | reconnecting | nein | unknown | Versuch — connman unbekannt heißt „probier es" |
| A14 | logged_out | nein | online | kein Versuch |
| A15 | relogin_required | nein | online | kein Versuch |
| A16 | waiting_for_pair | nein | online | kein Versuch |
| A17 | standby | nein | online | kein Versuch (andere Instanz hält die Session) |
| A18 | error | nein | online | Versuch |

## A — connman-Auswertung (`handleNetworkProperty`)

| ID | Ausgangszustand | Eigenschaft | Wert | verbunden | Erwartet |
|----|-----------------|-------------|------|-----------|----------|
| A19 | offline | State | online | nein | Versuch `network-up`, netState=online |
| A20 | idle | State | ready | nein | Versuch `network-up`, netState=ready |
| A21 | idle | State | online | **ja** | kein Versuch — wir sind schon verbunden |
| A22 | online | State | idle | nein | kein Versuch, netState=idle |
| A23 | online | State | online | nein | kein Versuch — unveränderter Zustand macht keinen Lärm |
| A24 | online | State | "" | nein | kein Versuch, Zustand bleibt |
| A25 | idle | OfflineMode | false | nein | Versuch `flight-mode-off` |
| A26 | online | OfflineMode | true | nein | kein Versuch |
| A27 | online | OfflineMode | false | **ja** | kein Versuch |
| A28 | online | SessionMode | true | nein | kein Versuch — fremde Eigenschaft |
| A29 | online | OfflineMode | "nein" (String) | nein | kein Versuch — falscher Typ |

## A — Weckkanal

| ID | Fall | Erwartet |
|----|------|----------|
| A30 | Weckruf während laufendem Backoff-Schlaf | Schlaf bricht in unter 500 ms ab |
| A31 | 50 Weckrufe ohne Wartenden | blockiert nicht |

## A — Daemon-Wache (`tests/daemon_guard_test.py`)

Fährt `start_backend.start()` gegen ein echtes HTTP-Backend und zählt mit,
welche Endpunkte angefasst werden.

**Der Test ist gegen die Produktivinstallation abgeschottet**, weil er auch auf
dem Gerät läuft: `HOME` zeigt während des Laufs auf ein Wegwerfverzeichnis
(`start()` legt Datenordner an und stutzt `backend.log`), und statt den
Portbereich 8085–8089 zu durchsuchen, bekommt `find_backend_port` einen freien
Port untergeschoben. Ohne beides hätte der Test auf dem Telefon `/quit` an den
laufenden Daemon geschickt und die echte Logdatei gekürzt — nachgestellt und
gegengeprüft mit einem simulierten Daemon auf 8085, der unangetastet blieb.

| ID | Laufende Instanz | Version läuft / installiert | Erwartet |
|----|------------------|------------------------------|----------|
| A45 | **Daemon** | 0.9.100 / 0.9.191 | **kein `/quit`**, App dockt an — der Fehler von 0.9.181–0.9.186 |
| A46 | eigenes Kind | 0.9.100 / 0.9.191 | `/quit`, Ersatz wie vorgesehen |
| A47 | Daemon | gleich / gleich | kein `/quit` |
| A48 | eigenes Kind | gleich / gleich | kein `/quit` |
| A49 | eigenes Kind | 0.9.100 / unbekannt | kein `/quit` — Regression 0.9.167 |
| A50 | — | — | `json` ist auf Modulebene importiert |

Gegenprobe gemacht: gegen den Stand von 0.9.186 (lokales `import json`, leeres
`except`) fallen A45 und A50 durch. Der Test prüft also wirklich etwas.

## A — connman am echten Bus (`backend/connman_bus_test.go`)

Startet einen nachgebauten `net.connman` auf einem Test-Systembus und lässt
`watchNetwork()` unverändert dagegen laufen. Deckt ab, was Tabellentests nicht
können: Match-Regel, Signalname, Objektpfad, Variant-Auspacken.

| ID | Fall | Erwartet |
|----|------|----------|
| A51 | `GetProperties` beim Start | Anfangszustand übernommen (idle) |
| A52 | `PropertyChanged State=online` | Zustand übernommen, Weckruf abgesetzt |
| A53 | `PropertyChanged SessionMode=true` | kein Weckruf |
| A54 | `PropertyChanged OfflineMode=false` | Weckruf abgesetzt |

## A — Portdatei (`backend/portfile_test.go`)

| ID | Inhalt der Datei | Erwartet |
|----|------------------|----------|
| A55 | eigener Port | gelöscht |
| A56 | fremder Port | bleibt stehen |
| A57 | eigener Port mit Zeilenumbruch | gelöscht |
| A58 | unlesbarer Inhalt | bleibt stehen |
| A59 | Datei fehlt | kein Absturz |

## A — Beide Rollen: Daemon und Kind-Backend (`backend/instances_test.go`)

Der Daemon und das von der App gestartete Backend sind **dasselbe Binary**.
An `isDaemon` hängen nur fünf Dinge: die Port-Übernahme beim Start, der
30-Sekunden-Wächter (beendet sich bei abgeschalteten Benachrichtigungen), der
D-Bus-Name für die Antwort aus der Benachrichtigung, der Reply-Empfänger und
der Selbst-Update-Poller. Reconnect-Wache, Backoff, connman-Beobachter,
Minuten-Wächter, Portdatei und der Sendepfad laufen in beiden Rollen
unverändert — die folgenden Fälle prüfen das, statt es zu behaupten.

| ID | Rolle | Lage | Erwartet |
|----|-------|------|----------|
| A60 | Daemon | keine zweite Instanz | verbinden |
| A61 | Daemon | andere Instanz **verbunden** | zurücktreten (Standby) |
| A62 | Daemon | andere Instanz vorhanden, aber nicht verbunden | verbinden |
| A63 | Daemon | eigener Port antwortet | sich selbst nicht für fremd halten |
| A64 | Kind-Backend | keine zweite Instanz | verbinden |
| A65 | Kind-Backend | Daemon **verbunden** | zurücktreten (Standby) |
| A66 | Kind-Backend | Daemon vorhanden, nicht verbunden | verbinden |
| A67 | Kind-Backend | eigener Port antwortet | sich selbst nicht für fremd halten |
| A68 | beide Rollen | Zustand `standby` | Minuten-Wächter funkt nicht dazwischen |

A63/A67 sind der Fall, der sonst zum Dauerstandby führen würde: Wer den
eigenen Port mitzählt, findet immer eine „fremde" verbundene Instanz und
verbindet sich nie wieder.

## A — Protokoll des Daemons (`backend/daemonlog_test.go`)

| ID | Fall | Erwartet |
|----|------|----------|
| A69 | Daemon schreibt stdout und stderr | beides landet in `daemon.log` |
| A70 | App-Instanz | legt **kein** `daemon.log` an — ihre Ausgabe gehört in `backend.log` |
| A71 | Protokoll über 512 KB beim Start | gestutzt, Schnittmarke gesetzt, **Ende** behalten statt Anfang |

## A — Langzeitszenario (`backend/offline_scenario_test.go`)

| ID | Fall | Erwartet |
|----|------|----------|
| A32 | Acht Stunden ohne Netz, neue Formel | ≤ 100 Versuche, Dauerabstand 5 min |
| A33 | Acht Stunden ohne Netz, alte Formel | 1752 Versuche, Abstand 10 s — der Test belegt, dass das Szenario überhaupt etwas prüft |

## A — Fehlertexte der App (`tests/senderror_test.js`)

| ID | Eingabe | Erwartet |
|----|---------|----------|
| A34 | `server returned error 463` | als Ablehnung erkannt (463) |
| A35 | `... 400` / `... 499` | Grenzen der 4xx-Familie, erkannt |
| A36 | `... 500` / `... 399` | **keine** Ablehnung |
| A37 | `no LID found for …` | keine Ablehnung, Text unverändert durchgereicht |
| A38 | leerer Text, `undefined` | keine Ablehnung, kein Absturz |
| A39 | `upload failed after 463 seconds` | keine Fehldeutung durch Ziffern im Fließtext |
| A40 | 463, deutscher Katalog | Klartext mit Codenummer, ohne Rohtext, mit Warnung vor Wiederholung |
| A41 | 463, englischer Katalog | „do not retry" enthalten |
| A42 | Status 0, leerer Body | „keine Antwort vom Backend" |
| A43 | Body > 200 Zeichen | gekürzt mit Auslassungszeichen |
| A44 | alle 23 Kataloge | `%1` überall ersetzt, Code bzw. Status im Text |

---

## G — Gerätefälle

Diese Fälle brauchen das Telefon. Die Spalte „Beleg" sagt, woran man das
Ergebnis erkennt, ohne raten zu müssen.

| ID | Fall | Vorgehen | Erwartet | Beleg |
|----|------|----------|----------|-------|
| G01 | Netz kehrt zurück | Flugmodus an, 20 s warten, aus | Verbindung binnen Sekunden, nicht erst nach dem Backoff | `grep "📶" daemon.log` zeigt Zustandswechsel, danach `🔌 connecting (network-up)` |
| G02 | connman **im Jail** erreichbar | Daemon neu starten | Beobachter meldet sich | `📶 connman watcher active (state=…)` in `daemon.log` — die Protokoll-Logik selbst ist durch A51–A54 abgedeckt, offen bleibt allein Sailjail |
| G03 | connman **nicht** erreichbar | — (nur falls G02 scheitert) | saubere Meldung, Minuten-Wächter trägt allein | `⚠ connman: signal subscription failed` in `daemon.log` |
| G04 | Langes Funkloch | Flugmodus über Nacht | keine Versuchslawine, Abstand bleibt bei 5 min | `grep -c "🔌 connecting" daemon.log` bleibt zweistellig |
| G05 | Gescheiterter Verbindungsaufbau plant nach | Flugmodus an, `systemctl --user restart` des Daemons | Versuche laufen weiter, statt nach einem Fehler zu enden | `retry-after-error` in `daemon.log` |
| G06 | Daemon überlebt Update | RPM installieren, Daemon **nicht** anfassen, App öffnen | Daemon läuft weiter, neue Version | `grep -c "Quit requested"` bleibt gleich; `/status` zeigt neue Version |
| G07 | `%post` erledigt den Neustart | wie G06 | Sailjail-Abfrage erscheint, Version steigt ohne App-Start | `/status` vor dem ersten App-Start bereits neu |
| G08 | Daemon-Wache greift | wie G06, falls `%post` einmal ausfällt | App dockt an, statt `/quit` zu senden | kein neues `Quit requested` — die Entscheidung selbst ist durch A45–A50 abgedeckt |
| G09 | Toter Daemon wird gemeldet | `systemctl --user stop`, App öffnen, 20 s warten | rote Meldung auf der Hauptseite | Meldung sichtbar |
| G10 | Senden in bestehenden Chat | Nachricht an bekannten Kontakt | HTTP 200, Nachricht erscheint | `/send` liefert `ok` |
| G11 | Erstkontakt bei Beschränkung | **eine** Nachricht an neue Nummer | Klartextmeldung statt stummem Knopf | rote Notiz mit Erklärung |
| G12 | Erstkontakt-Bremse | nach G11 nochmal senden wollen | Hinweis statt zweitem Versuch | keine zweite Zeile im Log |
| G13 | Erstkontakt nach Ablauf | eine Nachricht an neue Nummer | HTTP 200 | Nachricht kommt an |
| G14 | Anhang: Auswahlfrage | Büroklammer antippen | Frage nach Medienbibliothek oder Dateibrowser | beide Einträge sichtbar |
| G15 | Anhang: Medienbibliothek | Medienbibliothek wählen | nach Typ sortierte Ansicht, Datei geht raus | Nachricht erscheint |
| G16 | Anhang: Standard gesetzt | Weitere Einstellungen → Dateiauswahl auf Dateibrowser | Büroklammer fragt nicht mehr | direkt im Dateibaum |
| G17 | Anhang: Rückweg | im Wähler zurückwischen | landet im Chat, nicht in der Frage | eine Geste genügt |
| G18 | Portdatei nach sauberem Ende | `/quit` an das eigene Backend | `backend.port` verschwindet | Datei weg |
| G19 | Portdatei fremder Instanz | App-Backend beenden, während Daemon läuft | Daemon-Eintrag bleibt stehen | Datei enthält weiter den Daemon-Port |
| G20 | Sprachen | App-Sprache umstellen, Fehler provozieren | Meldung in der gewählten Sprache, kein `%1` | Text lesbar |
| G21 | Antwort aus der Benachrichtigung | einmal mit laufendem Daemon, einmal nur mit offener App | in beiden Fällen wird gesendet | Nachricht erscheint im Chat |

---

## Was diese Matrix nicht abdeckt

Die Grenze liegt nicht dort, wo sie zuerst schien. Zwei der drei teuersten
Fehler dieses Projekts sind inzwischen automatisiert: die wirkungslose
Daemon-Wache fällt bei A45 und A50 durch (gegengeprüft am kaputten Stand), der
Überlauf im Backoff bei A05. Auch das connman-Protokoll ist mit einem echten
Bus geprüft, nicht nur nachgedacht.

Was wirklich nur das Gerät beantworten kann, ist schmaler geworden:

- **Sailjail** — ob der Daemon im Jail an den System-Bus darf (G02/G03). Die
  Berechtigung ist nachgewiesen, der Vollzug nicht.
- **systemd** — ob `%post` die Sitzung erreicht und der Neustart zum richtigen
  Zeitpunkt kommt (G06/G07). Im Container gibt es kein systemd.
- **Die Gegenseite** — was WhatsApp bei einem Erstkontakt tatsächlich antwortet
  (G11/G13). Nachbauen ließe sich nur die eigene Erwartung.
- **Die Oberfläche** — ob der Wähler sich öffnet, die Frage lesbar ist, der
  Rückweg stimmt (G14–G17).

Rollenunterschiede gehören ausdrücklich **nicht** mehr dazu: A60–A68 fahren
dieselben Entscheidungen einmal als Daemon und einmal als Kind-Backend der
App. Was auf dem Gerät noch rollenabhängig bleibt, ist allein der
D-Bus-Name für die Antwort aus der Benachrichtigung (G21).

Und die alte Lehre bleibt gültig, nur genauer: Der Session-Sturm mit
Kontosperre stand im Log, nicht in einem Testfall. Wo ein Protokoll mitläuft,
lohnt es sich, zuerst dort zu schauen.
