import subprocess
import signal
import os
import time
import urllib.request
import pyotherside

backend_process = None

def _pdeathsig():
    """Kind stirbt mit dem Elternprozess - auch bei Crash/OOM-Kill der App.
    Ohne das lief das Backend nach einem harten App-Tod als Waise weiter,
    bis der naechste App-Start aufraeumte."""
    try:
        import ctypes, signal
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass  # besser ohne Absicherung starten als gar nicht

DAEMON_UNIT = "harbour-whatsapp-daemon.service"

voice_process = None
voice_path = None

def debug_log(msg):
    """UI-Diagnose in Datei (Journal ist auf dem Geraet unzugaenglich)."""
    try:
        p = os.path.expanduser("~/.local/share/harbour/harbour-whatsapp/ui-debug.log")
        with open(p, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass
    return True

def _pactl():
    p = "/usr/share/harbour-whatsapp/pactl"
    return p if os.path.exists(p) else "pactl"

def sink_volume_get():
    """Aktuelle Lautstaerke des Standard-Sinks, z.B. '45%' ('' bei Fehler)."""
    try:
        out = subprocess.check_output([_pactl(), "get-sink-volume", "@DEFAULT_SINK@"],
                                      stderr=subprocess.DEVNULL, timeout=3).decode()
        for tok in out.replace("/", " ").split():
            if tok.endswith("%"):
                return tok
    except Exception:
        pass
    return ""

def sink_volume_set(vol):
    """Lautstaerke des Standard-Sinks setzen, vol z.B. '60%'."""
    try:
        subprocess.call([_pactl(), "set-sink-volume", "@DEFAULT_SINK@", vol],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        return True
    except Exception:
        return False

def voice_start():
    """Sprachaufnahme starten: PulseAudio -> Opus/OGG (16 kHz mono, wie
    WhatsApp-Voice-Notes). SIGINT + -e finalisiert die Datei sauber."""
    global voice_process, voice_path
    voice_cancel()  # evtl. Reste
    data_dir = os.path.expanduser("~/.local/share/harbour/harbour-whatsapp")
    media = os.path.join(data_dir, "media", "Voice")
    os.makedirs(media, exist_ok=True)
    voice_path = os.path.join(media, "voice_%d.ogg" % int(time.time() * 1000))
    # /usr/bin kann im Jail auf eine Positivliste reduziert sein (EACCES) -
    # /usr/share/harbour-whatsapp ist nachweislich ausfuehrbar (wa-backend
    # startet von dort); der Hardlink wird bei der Installation angelegt
    gst = "/usr/share/harbour-whatsapp/gst-launch-1.0"
    if not os.path.exists(gst):
        gst = "gst-launch-1.0"
    errlog = os.path.join(media, "recorder.err")
    try:
        errf = open(errlog, "w")
        voice_process = subprocess.Popen(
            [gst, "-e", "-q", "pulsesrc", "!", "audioconvert",
             "!", "audioresample", "!", "audio/x-raw,rate=16000,channels=1",
             "!", "opusenc", "bitrate=24000", "!", "oggmux",
             "!", "filesink", "location=" + voice_path],
            stdout=subprocess.DEVNULL, stderr=errf,
            preexec_fn=_pdeathsig)  # Mikrofon darf die App NIE ueberleben
        errf.close()
        # Sofortiger Tod (z.B. Berechtigung fehlt) sofort und WOERTLICH melden
        time.sleep(0.4)
        if voice_process.poll() is not None:
            rc = voice_process.returncode
            voice_process = None
            tail = ""
            try:
                with open(errlog) as f:
                    tail = " ".join(f.read().strip().splitlines()[-2:])[:200]
            except Exception:
                pass
            return "recorder exited (code %s): %s" % (rc, tail or "no error output")
        return True
    except Exception as e:
        voice_process = None
        return str(e)

def voice_stop():
    """Aufnahme beenden; liefert den Dateipfad (oder Fehlertext)."""
    global voice_process
    if not voice_process:
        return ""
    try:
        voice_process.send_signal(signal.SIGINT)
        voice_process.wait(timeout=5)
    except Exception:
        voice_process.kill()
    voice_process = None
    if voice_path and os.path.exists(voice_path) and os.path.getsize(voice_path) > 0:
        return voice_path
    return ""

def voice_cancel():
    """Aufnahme verwerfen und Datei loeschen."""
    global voice_process, voice_path
    if voice_process:
        try:
            voice_process.kill()
        except Exception:
            pass
        voice_process = None
    if voice_path and os.path.exists(voice_path):
        try:
            os.remove(voice_path)
        except Exception:
            pass
    voice_path = None
    return True

def daemon_enabled():
    try:
        r = subprocess.run(["systemctl", "--user", "is-enabled", DAEMON_UNIT],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() == "enabled"
    except Exception:
        return False

def stop_daemon_via_quit():
    """Sandbox-tauglicher Daemon-Stopp: /quit statt systemctl (das die
    Sandbox verbietet). Sauberer Exit -> Restart=on-failure zieht nicht
    neu hoch. Danach Kind-Backend nachstarten, damit die offene App
    nicht ohne Backend dasteht. Der Autostart-Symlink bleibt bestehen -
    beim naechsten Login beendet der Watchdog den Daemon selbst wieder,
    solange Benachrichtigungen aus sind."""
    port = find_backend_port()
    if port:
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/quit" % port, timeout=2)
        except Exception:
            pass
        for _ in range(30):
            if not find_backend_port():
                break
            time.sleep(0.2)
    start()
    return True

def daemon_set(enable):
    """Daemon ein-/ausschalten MIT sauberer Uebergabe. Liefert (ok, meldung).

    Einschalten: erst das eigene Kind-Backend beenden (sonst laufen zwei
    Backends mit denselben Credentials - WhatsApp kickt eine Verbindung),
    dann den Daemon starten und warten, bis er den Port haelt; die GUI
    laeuft am selben Port nahtlos weiter.
    Ausschalten: Daemon stoppen, dann sofort ein Kind-Backend nachstarten,
    damit die offene App nicht ohne Backend dasteht.
    Innerhalb der Sailjail-Sandbox kann systemctl blockiert sein - dann
    bekommt der Nutzer die Terminal-Kommandos gezeigt (Fallback in der UI)."""
    try:
        subprocess.run(["systemctl", "--user", "daemon-reload"],
                       capture_output=True, timeout=5)
        if enable:
            stop()  # Kind-Backend raeumen, Port freigeben
            r = subprocess.run(["systemctl", "--user", "enable", "--now", DAEMON_UNIT],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                for _ in range(40):  # bis 8s auf den Daemon warten
                    if find_backend_port():
                        return True, "ok"
                    time.sleep(0.2)
                return False, "daemon enabled but backend did not come up - check journalctl --user -u " + DAEMON_UNIT
        else:
            r = subprocess.run(["systemctl", "--user", "disable", "--now", DAEMON_UNIT],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                start()  # Kind-Backend fuer die laufende Sitzung nachstarten
                return True, "ok"
        return False, (r.stderr or r.stdout or "systemctl failed").strip()
    except Exception as e:
        return False, str(e)

def installed_version():
    try:
        with open("/usr/share/harbour-whatsapp/VERSION") as f:
            return f.read().strip()
    except Exception:
        return None

def backend_version(port):
    try:
        import json
        with urllib.request.urlopen("http://127.0.0.1:%d/status" % port, timeout=1) as r:
            return json.loads(r.read().decode()).get("version")
    except Exception:
        return None

def stop_stale_backend(port):
    """Altes Backend beenden: erst hoeflich per /quit, dann pkill."""
    try:
        urllib.request.urlopen("http://127.0.0.1:%d/quit" % port, timeout=2)
    except Exception:
        pass  # alte Backends kennen /quit nicht
    for _ in range(20):
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/status" % port, timeout=1)
            time.sleep(0.1)
        except Exception:
            return True  # Port frei
    subprocess.call(["pkill", "-f", "wa-backend|harbour-whatsapp-daemon"])
    time.sleep(0.5)
    return True

def find_backend_port():
    """Return the port of a running backend, or None."""
    data_dir = os.path.expanduser("~/.local/share/harbour/harbour-whatsapp")
    candidates = []
    try:
        with open(os.path.join(data_dir, "backend.port")) as f:
            candidates.append(int(f.read().strip()))
    except Exception:
        pass
    candidates += [p for p in range(8085, 8090) if p not in candidates]
    for p in candidates:
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/status" % p, timeout=1)
            return p
        except Exception:
            continue
    return None

def start():
    global backend_process
    # Under Sailjail (OrganizationName=harbour) the persistent app data dir is
    # ~/.local/share/harbour/harbour-whatsapp - the old path was not persisted,
    # which made the login disappear on every app restart.
    data_dir = os.path.expanduser("~/.local/share/harbour/harbour-whatsapp")
    os.makedirs(data_dir, exist_ok=True)
    # Die fruehere Einmal-Migration aus ~/.local/share/harbour-whatsapp ist
    # entfernt: sie hat nach "Reset & pair again" die dort liegende uralte
    # Klartext-wa.db immer wieder zurueckkopiert und so eine Endlosschleife
    # mit relogin_required erzeugt. Wer noch Altdaten dort hat, paart unter
    # der Secrets-only-Policy ohnehin neu.
    
    # Check if already running (scan the port range the backend may use)
    port = find_backend_port()
    if port:
        want = installed_version()
        have = backend_version(port)
        if want is not None and have != want:
            # veraltetes Backend von vor dem Update -> ersetzen
            stop_stale_backend(port)
            port = None
        else:
            pyotherside.send('backendReady', True, port)
            return True
    
    # Start backend
    if backend_process is None or backend_process.poll() is not None:
        # keep a log so users can actually report backend errors
        log_path = os.path.join(data_dir, "backend.log")
        try:
            if os.path.exists(log_path) and os.path.getsize(log_path) > 1024 * 1024:
                os.replace(log_path, log_path + ".old")
            log_file = open(log_path, "a")
        except Exception:
            log_file = subprocess.DEVNULL
        backend_process = subprocess.Popen(
            ["/usr/share/harbour-whatsapp/wa-backend"],
            cwd=data_dir,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            preexec_fn=_pdeathsig
        )
        
        # Wait for backend to be ready. Cold start after a reboot can be slow
        # because sailfishsecretsd may still be coming up, so be patient
        # (up to ~25 s) and retry once if the backend exits early.
        for attempt in range(2):
            for i in range(250):
                port = find_backend_port()
                if port:
                    pyotherside.send('backendReady', True, port)
                    return True
                if backend_process.poll() is not None:
                    break  # backend exited - see backend.log; maybe retry
                time.sleep(0.1)
            # backend died before binding the port: try one more time
            if backend_process.poll() is not None and attempt == 0:
                time.sleep(1.0)
                try:
                    log_file2 = open(log_path, "a")
                except Exception:
                    log_file2 = subprocess.DEVNULL
                backend_process = subprocess.Popen(
                    ["/usr/share/harbour-whatsapp/wa-backend"],
                    cwd=data_dir,
                    stdout=log_file2,
                    stderr=subprocess.STDOUT,
                    preexec_fn=_pdeathsig
                )
                continue
            break
    
    pyotherside.send('backendReady', False, 0)
    return False

def stop():
    global backend_process
    if backend_process:
        backend_process.terminate()
        try:
            backend_process.wait(timeout=2)
        except:
            backend_process.kill()
        backend_process = None
