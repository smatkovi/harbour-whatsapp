import subprocess
import os
import time
import urllib.request
import pyotherside

backend_process = None

def start():
    global backend_process
    data_dir = os.path.expanduser("~/.local/share/harbour-whatsapp")
    os.makedirs(data_dir, exist_ok=True)
    
    # Check if already running
    try:
        urllib.request.urlopen("http://localhost:8085/status", timeout=1)
        pyotherside.send('backendReady', True)
        return True
    except:
        pass
    
    # Start backend
    if backend_process is None or backend_process.poll() is not None:
        backend_process = subprocess.Popen(
            ["/usr/share/harbour-whatsapp/wa-backend"],
            cwd=data_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        
        # Wait for backend to be ready
        for i in range(50):
            try:
                urllib.request.urlopen("http://localhost:8085/status", timeout=1)
                pyotherside.send('backendReady', True)
                return True
            except:
                time.sleep(0.1)
    
    pyotherside.send('backendReady', False)
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
