#!/bin/sh
# Faehrt alle automatischen Testfaelle (A-Faelle der TESTMATRIX).
# Aufruf:  sh tests/run.sh      (von ueberall)
#
# Bewusst reines POSIX-sh: auf dem Geraet ist /bin/bash BusyBox und kennt
# weder ${BASH_SOURCE[0]} noch "trap ... RETURN" - beides liess frueher
# ROOT leer werden, und saemtliche Pfade zeigten auf /.
#
# Warum die Go-Tests in einer Kopie laufen: go.sum liegt NICHT im Repo,
# weil die Hashes aus den replace-Umleitungen des Baurechners stammen und
# einen normalen Build brechen wuerden. Aufgeloest wird in /tmp, der
# Arbeitsbaum bleibt unberuehrt.

ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
if [ -z "$ROOT" ] || [ ! -f "$ROOT/start_backend.py" ]; then
    echo "Repo-Wurzel nicht gefunden (aufgerufen als: $0)" >&2
    exit 2
fi
echo "Repo: $ROOT"

FAILED=""
run() {
    name=$1
    shift
    echo
    echo "=== $name ==="
    if "$@"; then
        echo "--- $name: bestanden"
    else
        echo "--- $name: FEHLGESCHLAGEN"
        FAILED="$FAILED
  - $name"
    fi
}

go_tests() {
    if ! command -v go > /dev/null 2>&1; then
        echo "go nicht installiert - uebersprungen"
        return 0
    fi
    tmp=$(mktemp -d) || return 1
    cp "$ROOT"/backend/*.go "$ROOT"/backend/go.mod "$tmp"/ 2>/dev/null
    # Optionale lokale Umleitungen (Spiegel, Firewall) - nicht im Repo
    if [ -f "$ROOT/backend/go.replace.local" ]; then
        cat "$ROOT/backend/go.replace.local" >> "$tmp/go.mod"
    fi
    rc=0
    # Protokoll an einen festen Ort: frueher lag es im Wegwerfverzeichnis
    # und war nach dem Aufraeumen weg - genau dann, wenn man es braucht
    log=/tmp/wa-gotest.log
    echo "(Protokoll: $log)"
    if ! ( cd "$tmp" && GOFLAGS=-mod=mod GOTOOLCHAIN=local go mod tidy ) > "$log" 2>&1; then
        echo "Abhaengigkeiten liessen sich nicht aufloesen:"
        tail -5 "$log"
        rc=1
    else
        ( cd "$tmp" && go test ./... ) 2>&1 | tee -a "$log"
        # Ergebnis von go test, nicht von tee
        grep -q "^FAIL" "$log" && rc=1
    fi
    rm -rf "$tmp"
    return $rc
}

qml_syntax() {
    lint=$(command -v qmllint 2>/dev/null)
    [ -n "$lint" ] || [ ! -x /usr/lib/qt6/bin/qmllint ] || lint=/usr/lib/qt6/bin/qmllint
    [ -n "$lint" ] || [ ! -x /usr/lib/qt5/bin/qmllint ] || lint=/usr/lib/qt5/bin/qmllint
    if [ -z "$lint" ]; then
        echo "qmllint nicht gefunden - uebersprungen"
        return 0
    fi
    n=$("$lint" "$ROOT/qml/harbour-whatsapp.qml" 2>&1 | grep -cE "Expected|syntax error|Could not parse")
    echo "Syntaxfehler: $n"
    [ "$n" = "0" ]
}

if [ -z "$DBUS_SYSTEM_BUS_ADDRESS" ]; then
    echo "Hinweis: kein Test-Systembus gesetzt, der connman-Fall wird uebersprungen."
    echo "  dbus-daemon --config-file=$ROOT/tests/testbus.conf --print-address --fork > /tmp/busaddr"
    echo "  export DBUS_SYSTEM_BUS_ADDRESS=\$(cat /tmp/busaddr)"
fi

run "Go: Reconnect, connman, Waechter, Portdatei, Rollen, Szenario" go_tests
run "JS: Fehlertexte und Kataloge" node "$ROOT/tests/senderror_test.js"
run "Python: Daemon-Wache" python3 "$ROOT/tests/daemon_guard_test.py"
run "QML-Syntax" qml_syntax
run "Python-Syntax start_backend.py" python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROOT/start_backend.py"

echo
if [ -z "$FAILED" ]; then
    echo "Alle automatischen Testfaelle bestanden."
    exit 0
fi
printf 'Fehlgeschlagen:%s\n' "$FAILED"
exit 1
