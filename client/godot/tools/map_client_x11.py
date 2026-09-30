"""Run a backend-free Godot scene in an isolated X server, never on the desktop.

Uses Xvfb from PATH or the locally unpacked build/map-client/usr/bin/Xvfb.
The server and only the test child are cleaned up on completion/failure.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys


project = Path(__file__).resolve().parents[1]
(project / "build/map-client").mkdir(parents=True, exist_ok=True)
xvfb = shutil.which("Xvfb") or str(project / "build/map-client/usr/bin/Xvfb")
read_fd, write_fd = os.pipe()
with open(project / "build/map-client/xvfb.log", "w") as log:
    server = subprocess.Popen(
        [xvfb, "-displayfd", str(write_fd), "-screen", "0", "1440x860x24", "-nolisten", "tcp", "-ac"],
        pass_fds=(write_fd,), stdout=log, stderr=log,
    )
    os.close(write_fd)
    try:
        number = os.read(read_fd, 64).decode().strip()
        if not number:
            raise RuntimeError("Xvfb failed; see build/map-client/xvfb.log")
        env = dict(os.environ, DISPLAY=f":{number}")
        result = subprocess.run(
            [os.environ.get("GODOT", "godot"), "--path", str(project), "--display-driver", "x11", "--rendering-method", "gl_compatibility", "--disable-vsync", *sys.argv[1:]],
            env=env, timeout=180,
        )
    finally:
        os.close(read_fd)
        server.terminate()
        server.wait(timeout=10)
sys.exit(result.returncode)
