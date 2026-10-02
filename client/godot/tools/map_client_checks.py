"""Backend-free client regression suite, including runtime-error detection.

python client/godot/tools/map_client_checks.py [--gpu] [--profile] [--record-evidence]
GPU tests use an isolated Xvfb, never the user's display or running game.
Ordinary runs write ignored build outputs; recording tracked evidence is explicit.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


parser = argparse.ArgumentParser()
parser.add_argument("--gpu", action="store_true")
parser.add_argument("--profile", action="store_true")
parser.add_argument("--record-evidence", action="store_true", help="explicitly replace saved comparison evidence")
options = parser.parse_args()
project = Path(__file__).resolve().parents[1]
output = project / "build/map-client"
output.mkdir(parents=True, exist_ok=True)
evidence = project / "tools/map_client_evidence" if options.record_evidence else output
summary = []


def run(name, args, marker, gpu=False):
    command = (
        [sys.executable, str(project / "tools/map_client_x11.py")]
        if gpu else [os.environ.get("GODOT", "godot"), "--headless", "--path", str(project)]
    )
    # Dense workspace/focus coverage legitimately exceeds 1200 frames under
    # DummyAudio. Keep a crash-safe frame cap; the real wall timeout is below.
    command += ["--quit-after", "12000", *args]
    start = time.monotonic()
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    (output / f"{name}.log").write_text(result.stdout)
    unexpected_errors = [
        line for line in result.stdout.splitlines()
        if line.startswith("ERROR:")
        and not (name == "ui_scale_test" and "ConfigFile parse error" in line)
    ]
    bad = result.returncode != 0 or marker not in result.stdout or "SCRIPT ERROR:" in result.stdout or "_FAIL" in result.stdout or unexpected_errors
    line = f"{'FAIL' if bad else 'PASS'} {name} elapsed_s={time.monotonic() - start:.2f}"
    summary.append(line)
    print(line, flush=True)
    if bad:
        print(result.stdout)
        raise SystemExit(1)
    return result.stdout


for name, scene, marker in [
    ("terrain", "terrain_test", "TERRAIN_TEST_PASS"),
    ("terrain-ui", "terrain_ui_test", "TERRAIN_UI_PASS"),
    ("map-client", "map_client_test", "MAP_CLIENT_TEST_PASS"),
    ("workspace", "workspace_test", "WORKSPACE_PASS"),
    ("menu", "main_menu_test", "MAIN_MENU_PASS"),
    ("diagnostics-ui", "diagnostics_integration_test", "DIAGNOSTICS_INTEGRATION_PASS"),
]:
    run(name, ["--scene", f"res://tools/{scene}.tscn"], marker)
run("legacy-map-ui", ["--scene", "res://tools/map_client_legacy_ui_test.tscn", "--", "--settings-file=res://build/map-client/checks-legacy.cfg"], "MAP_UI_PASS")
run("session", ["--scene", "res://tools/session_switch_test.tscn", "--", "--settings-file=res://build/map-client/checks-session.cfg", "--workspace-file=res://build/map-client/checks-session.json"], "SESSION_SWITCH_PASS")
for name, marker in [
    ("ui_scale_test", "UI_SCALE_PASS"),
    ("history_test", "HISTORY_PASS"),
    ("subscription_lifecycle_test", "SUBSCRIPTION_LIFECYCLE_PASS"),
    ("diagnostics_test", "DIAGNOSTICS_PASS"),
]:
    run(name, ["--script", f"res://tools/{name}.gd"], marker)
if options.gpu:
    for name, marker in [("terrain_render_test", "TERRAIN_RENDER_PASS"), ("terrain_composed_test", "TERRAIN_COMPOSED_PASS")]:
        run(name, ["--scene", f"res://tools/{name}.tscn"], marker, gpu=True)
    for edge in (24, 128, 256):
        run(f"camera-render-{edge}", ["--scene", "res://tools/map_client_render_test.tscn", "--", f"--edge={edge}"], "MAP_CLIENT_RENDER_PASS", gpu=True)
if options.profile:
    for edge in (24, 128):
        text = run(f"profile-{edge}", ["--scene", "res://tools/map_client_profile.tscn", "--", f"--edge={edge}"], "MAP_CLIENT_PROFILE_DONE")
        (evidence / f"after-{edge}.log").write_text(text)
        if options.gpu:
            text = run(f"profile-render-{edge}", ["--scene", "res://tools/map_client_profile.tscn", "--", f"--edge={edge}"], "MAP_CLIENT_PROFILE_DONE", gpu=True)
            (evidence / f"after-render-{edge}.log").write_text(text)
    text = run("profile-ui", ["--scene", "res://tools/map_client_ui_profile.tscn", "--", "--settings-file=res://build/map-client/checks-ui.cfg", "--workspace-file=res://build/map-client/checks-ui.json"], "MAP_CLIENT_UI_PROFILE_DONE")
    (evidence / "ui-after.log").write_text(text)
(evidence / "checks.log").write_text("\n".join(summary) + "\n")
