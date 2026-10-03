"""Private software-GL matrix; no human display or live colony connection.

GODOT and PATH may point to the supplied private DummyAudio/Xvfb tools.
--live exercises typed production-main composition and actual GUI contracts.
"""
import itertools
import argparse
import os
from pathlib import Path
import shutil
import subprocess


parser = argparse.ArgumentParser()
parser.add_argument("--live", action="store_true", help="render actual typed-fixture production main, not phase 2 chrome")
parser.add_argument("--review-only", action="store_true", help="three focused review-fix GPU cases, not the unchanged full matrix")
parser.add_argument("--floating-only", action="store_true", help="eight actual-main viewport/scale/status cases for floating integration")
parser.add_argument("--header-only", action="store_true", help="focused two-strip header matrix plus a 4K window")
parser.add_argument("--budget-only", action="store_true", help="five multi-warning status budgets, including 240 logical px")
parser.add_argument("--collapsed-only", action="store_true", help="production resize/collapse/drag at 100/125/150 percent and the floating boundary")
options = parser.parse_args()
scene = "ui_composition_fixture" if options.live or options.floating_only or options.header_only else "ui_chrome_fixture"
if options.review_only:
    scene = "ui_review_regression"
if options.budget_only:
    scene = "ui_status_budget_test"
if options.collapsed_only:
    scene = "workspace_collapsed_production_test"
marker = "UI_LIVE_FIXTURE_PASS" if options.live or options.review_only or options.floating_only or options.header_only or options.budget_only or options.collapsed_only else "UI_INTEGRATION_FIXTURE_PASS"
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
    server = subprocess.Popen([xvfb, "-displayfd", str(write_fd), "-screen", "0", "3840x2160x24" if options.header_only else "1440x900x24", "-nolisten", "tcp", "-ac"], env=env, pass_fds=(write_fd,), stdout=log, stderr=log)
    os.close(write_fd)
    try:
        number = os.read(read_fd, 64).decode().strip()
        if not number:
            raise RuntimeError("Private Xvfb failed")
        env["DISPLAY"] = ":" + number
        results = []
        cases = [(screen, scale, status, reduced, focus, "") for screen, scale, status, reduced, focus in itertools.product(["1440x900", "960x640"], [100, 125, 150], ["nominal", "problem"], [False, True], [False, True])]
        if options.live:
            cases += [("1440x900", scale, status, True, True, "floating") for scale, status in itertools.product([100, 125], ["nominal", "problem"])]
            cases += [(screen, scale, "problem", True, True, "digest") for screen, scale in [("1440x900", 100), ("960x640", 150)]]
        if options.review_only:
            cases = [("1440x900", 100, "problem", False, True, ""), ("960x640", 125, "problem", False, True, ""), ("960x640", 150, "problem", True, True, "digest")]
        if options.floating_only:
            cases = [(screen, scale, status, True, True, "") for screen, scale, status in itertools.product(["1440x900", "960x640"], [100, 150], ["nominal", "problem"])]
        if options.header_only:
            cases = [(screen, scale, status, True, True, "") for screen, scale, status in itertools.product(["1440x900", "960x640"], [100, 125, 150], ["nominal", "problem"])]
            cases += [("3840x2160", 150, status, True, True, "") for status in ["nominal", "problem"]]
            cases += [("1440x900", 100, "nominal", True, True, "map-view"), ("960x640", 150, "problem", True, True, "map-view")]
        if options.budget_only:
            cases = [("960x640", scale, "problem", True, True, "") for scale in [100, 125, 150]]
            cases += [(screen, 150, "problem", True, True, "") for screen in ["600x640", "360x640"]]
        if options.collapsed_only:
            cases = [("1440x900", scale, "nominal", True, False, "") for scale in [100, 125, 150]]
            cases += [("960x748", 150, "nominal", True, False, "")]
        for screen, scale, status, reduced, focus, extra in cases:
            name = f"{screen}-{scale}-{status}-motion{'reduced' if reduced else 'normal'}-focus{int(focus)}"
            if extra:
                name += "-" + extra
            command = [godot, "--disable-vsync", "--path", str(project), "--display-driver", "x11", "--rendering-method", "gl_compatibility", "--scene", f"res://tools/{scene}.tscn", "--", f"--screen={screen}", f"--scale={scale}", f"--status={status}", f"--capture={base / (name + '.png')}"]
            command += (["--reduced-motion"] if reduced else []) + (["--focus"] if focus else [])
            if (options.live or options.floating_only or options.header_only) and not options.budget_only:
                command.append("--layout-qa")
            if extra:
                command.append("--" + extra)
            try:
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired as error:
                def text(value):
                    return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
                output = text(error.stdout) + text(error.stderr) + "\nTIMEOUT 60s: " + repr(command)
                (base / (name + ".log")).write_text(output)
                results.append("FAIL timeout " + name)
                (base / "summary.log").write_text("\n".join(results) + "\n")
                raise SystemExit(output) from error
            output = result.stdout + result.stderr
            (base / (name + ".log")).write_text(output)
            passed = result.returncode == 0 and marker in output and "ERROR:" not in output
            results.append(f"{'PASS' if passed else 'FAIL'} {name}")
            print(results[-1], flush=True)
            (base / "summary.log").write_text("\n".join(results) + "\n")
            if not passed:
                raise SystemExit(output)
    finally:
        os.close(read_fd)
        server.terminate()
        server.wait(timeout=10)
