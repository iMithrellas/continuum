"""Private software-GL chrome matrix; no human display or live colony connection.

GODOT and PATH may point to the supplied private DummyAudio/Xvfb tools.
Full component/map coverage is added only after dependency handoffs land.
"""
import itertools
import os
from pathlib import Path
import shutil
import subprocess


project = Path(__file__).resolve().parents[1]
base = Path(os.environ.get("UI_RENDER_OUTPUT", "/tmp/opencode/continuum-ui-integration-state/matrix"))
base.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env.pop("DISPLAY", None)
env.pop("WAYLAND_DISPLAY", None)
for variable, directory in [("HOME", "home"), ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")]:
    path = base / directory
    path.mkdir(exist_ok=True, mode=0o700)
    env[variable] = str(path)
env.update(LIBGL_ALWAYS_SOFTWARE="1", MESA_LOADER_DRIVER_OVERRIDE="llvmpipe")
godot = env.get("GODOT", "godot")
xvfb = shutil.which("Xvfb", path=env.get("PATH"))
if not xvfb:
    raise SystemExit("Xvfb must be available on PATH; refusing the human display")
imported = subprocess.run([godot, "--headless", "--path", str(project), "--editor", "--quit"], env=env, capture_output=True, text=True, timeout=120)
(base / "import.log").write_text(imported.stdout + imported.stderr)
if imported.returncode or "SCRIPT ERROR:" in imported.stdout + imported.stderr:
    raise SystemExit("Import failed; see import.log")
read_fd, write_fd = os.pipe()
with (base / "xvfb.log").open("w") as log:
    server = subprocess.Popen([xvfb, "-displayfd", str(write_fd), "-screen", "0", "1440x900x24", "-nolisten", "tcp", "-ac"], env=env, pass_fds=(write_fd,), stdout=log, stderr=log)
    os.close(write_fd)
    try:
        number = os.read(read_fd, 64).decode().strip()
        if not number:
            raise RuntimeError("Private Xvfb failed")
        env["DISPLAY"] = ":" + number
        results = []
        for screen, scale, status, reduced, focus in itertools.product(["1440x900", "960x640"], [100, 125, 150], ["nominal", "problem"], [False, True], [False, True]):
            name = f"{screen}-{scale}-{status}-motion{'reduced' if reduced else 'normal'}-focus{int(focus)}"
            command = [godot, "--path", str(project), "--display-driver", "x11", "--rendering-method", "gl_compatibility", "--scene", "res://tools/ui_chrome_fixture.tscn", "--", f"--screen={screen}", f"--scale={scale}", f"--status={status}", f"--capture={base / (name + '.png')}"]
            command += (["--reduced-motion"] if reduced else []) + (["--focus"] if focus else [])
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            (base / (name + ".log")).write_text(output)
            passed = result.returncode == 0 and "UI_INTEGRATION_FIXTURE_PASS" in output and "ERROR:" not in output
            results.append(f"{'PASS' if passed else 'FAIL'} {name}")
            print(results[-1], flush=True)
            (base / "summary.log").write_text("\n".join(results) + "\n")
            if not passed:
                raise SystemExit(output)
    finally:
        os.close(read_fd)
        server.terminate()
        server.wait(timeout=10)
