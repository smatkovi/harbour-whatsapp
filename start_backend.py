import subprocess
import os
import time
import urllib.request
import pyotherside

backend_process = None

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
    subprocess.call(["pkill", "-f", "wa-backend"])
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
            stderr=subprocess.STDOUT
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
                    stderr=subprocess.STDOUT
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
