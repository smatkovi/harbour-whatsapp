import subprocess
import os
import time

backend_process = None

def start():
    global backend_process
    if backend_process is None or backend_process.poll() is not None:
        data_dir = os.path.expanduser("~/.local/share/harbour-whatsapp")
        os.makedirs(data_dir, exist_ok=True)
        backend_process = subprocess.Popen(
            ["/usr/share/harbour-whatsapp/wa-backend"],
            cwd=data_dir
        )
        time.sleep(1)
    return True

def stop():
    global backend_process
    if backend_process:
        backend_process.terminate()
        backend_process = None
