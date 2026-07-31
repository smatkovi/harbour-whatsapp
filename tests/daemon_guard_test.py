#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Prueft die Daemon-Wache in start_backend.py gegen ein echtes HTTP-Backend.

Der Fall, um den es geht: laeuft der DAEMON mit einer aelteren Version, darf
die App ihn NICHT per /quit ersetzen - /quit ist ein sauberer Exit, den
systemd absichtlich nicht neu startet, und danach laeuft gar nichts mehr.
Genau diese Wache war von 0.9.181 bis 0.9.186 wirkungslos, weil das noetige
json nur innerhalb einer anderen Funktion importiert war: der NameError
landete in einem leeren except, is_daemon blieb False, und die App erledigte
den Daemon bei jedem Start nach einem Versionssprung.

Aufruf aus dem Repo-Wurzelverzeichnis:  python3 tests/daemon_guard_test.py
"""

import json
import os
import socket
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Der Test laeuft auch auf dem Geraet, auf dem ein ECHTES Backend liegt.
# Zwei Vorkehrungen, damit er es nicht anfasst:
#   1. HOME zeigt auf ein Wegwerfverzeichnis - start() legt Datenordner an
#      und stutzt backend.log; beides darf die Produktivdaten nie treffen.
#   2. Der Portbereich 8085-8089 wird nicht angeruehrt. Statt ihn zu
#      scannen, bekommt find_backend_port einen freien Port untergeschoben.
#      Ohne das haette der Test in einem Fall /quit an den laufenden
#      Daemon geschickt und ihn erledigt.
_sandbox_home = tempfile.mkdtemp(prefix="wa-guard-home-")
os.environ["HOME"] = _sandbox_home


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port

# pyotherside gibt es nur in der App - hier ein Doppel, das mitschreibt
fake_pyotherside = types.ModuleType("pyotherside")
fake_pyotherside.sent = []
fake_pyotherside.send = lambda *a: fake_pyotherside.sent.append(a)
sys.modules["pyotherside"] = fake_pyotherside

sys.path.insert(0, ROOT)
import start_backend  # noqa: E402


class FakeBackend(BaseHTTPRequestHandler):
    """Antwortet wie das echte Backend - und merkt sich jeden Aufruf."""

    version = "0.9.100"
    daemon = True
    hits = []
    alive = True

    def do_GET(self):
        FakeBackend.hits.append(self.path.split("?")[0])
        if self.path.startswith("/status"):
            if not FakeBackend.alive:
                self.send_error(503)
                return
            body = json.dumps({
                "connected": True, "daemon": FakeBackend.daemon,
                "paired": True, "state": "connected",
                "version": FakeBackend.version, "lastError": "",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/quit"):
            FakeBackend.alive = False
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
        else:
            self.send_error(404)

    def log_message(self, *a):
        pass


FAILS = []


def check(name, cond, detail=""):
    if cond:
        print("  ok  %s" % name)
    else:
        FAILS.append(name)
        print("  FEHLGESCHLAGEN  %s\n      %s" % (name, detail))


def run_case(name, daemon, running_version, installed, expect_quit):
    FakeBackend.hits = []
    FakeBackend.alive = True
    FakeBackend.daemon = daemon
    FakeBackend.version = running_version
    fake_pyotherside.sent = []

    port = free_port()
    srv = HTTPServer(("127.0.0.1", port), FakeBackend)
    # Nur UNSER Server ist auffindbar - der echte Portbereich bleibt tabu
    start_backend.find_backend_port = lambda: (port if FakeBackend.alive else None)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()

    start_backend.installed_version = lambda: installed
    # Ein echtes Backend gibt es hier nicht - der Start wird abgefangen
    spawned = {"count": 0}

    class FakeProc(object):
        def poll(self):
            return 1

    real_popen = start_backend.subprocess.Popen

    def fake_popen(*a, **kw):
        spawned["count"] += 1
        return FakeProc()

    start_backend.subprocess.Popen = fake_popen
    try:
        start_backend.start()
    except Exception as e:
        print("      (start() endete mit %r - fuer diesen Fall unerheblich)" % (e,))
    finally:
        start_backend.subprocess.Popen = real_popen
        srv.shutdown()
        srv.server_close()

    quit_called = "/quit" in FakeBackend.hits
    ready = [s for s in fake_pyotherside.sent if s and s[0] == "backendReady"]
    check(name,
          quit_called == expect_quit,
          "/quit %s aufgerufen, erwartet: %s (Aufrufe: %s, backendReady: %s)"
          % ("wurde" if quit_called else "wurde NICHT",
             "ja" if expect_quit else "nein",
             FakeBackend.hits, bool(ready)))
    return ready


print("--- Daemon-Wache in start_backend.py ---")
print("    (HOME zeigt auf %s, Ports 8085-8089 bleiben unberuehrt)" % _sandbox_home)

# Der eigentliche Regressionsfall: alter DAEMON darf nicht sterben
ready = run_case("alter Daemon wird NICHT per /quit ersetzt",
                 daemon=True, running_version="0.9.100",
                 installed="0.9.191", expect_quit=False)
check("App dockt stattdessen an", bool(ready),
      "backendReady wurde nicht gemeldet")

# Eigenes Kind von vor dem Update darf weiterhin ersetzt werden
run_case("altes eigenes Backend wird ersetzt",
         daemon=False, running_version="0.9.100",
         installed="0.9.191", expect_quit=True)

# Gleiche Version: niemand wird angefasst
run_case("gleiche Version, Daemon bleibt",
         daemon=True, running_version="0.9.191",
         installed="0.9.191", expect_quit=False)
run_case("gleiche Version, eigenes Backend bleibt",
         daemon=False, running_version="0.9.191",
         installed="0.9.191", expect_quit=False)

# Regression 0.9.167: keine Antwort ist KEIN Versionskonflikt
run_case("unbekannte installierte Version schiesst nichts ab",
         daemon=False, running_version="0.9.100",
         installed=None, expect_quit=False)

print("--- Namensraum ---")
check("json ist auf Modulebene importiert",
      hasattr(start_backend, "json"),
      "ohne das stirbt die Wache still an einem NameError")

import shutil
shutil.rmtree(_sandbox_home, ignore_errors=True)

print("\nAlle Faelle bestanden." if not FAILS
      else "\n%d Fall/Faelle fehlgeschlagen: %s" % (len(FAILS), ", ".join(FAILS)))
sys.exit(0 if not FAILS else 1)
