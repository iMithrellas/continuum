#!/usr/bin/env python3
"""Render production-main chrome in a private software-GL X server."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xvfb", default=shutil.which("Xvfb"))
    parser.add_argument("--label", default="after")
    parser.add_argument("--screen", action="append", help="WIDTHxHEIGHT:SCALE")
    parser.add_argument("--scene", default="res://tools/ui_header_polish_test.tscn")
    parser.add_argument("--argument", action="append", default=[])
    parser.add_argument("--import-project", action="store_true")
    args = parser.parse_args()
    if not args.xvfb:
        parser.error("--xvfb is required when Xvfb is not on PATH")
    project = Path(__file__).resolve().parents[1]
    output = project / "build" / "header-polish" / args.label
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE="1", GODOT_SILENCE_ROOT_WARNING="1")
    env.pop("WAYLAND_DISPLAY", None)
    for key, name in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")]:
        env[key] = str(output / name)
        Path(env[key]).mkdir(exist_ok=True)
    godot = [os.environ.get("GODOT", "godot"), "--audio-driver", "Dummy", "--path", str(project)]
    if args.import_project:
        imported = subprocess.run(godot + ["--headless", "--editor", "--import"], env=env, capture_output=True, text=True, timeout=120)
        (output / "import.log").write_text(imported.stdout + imported.stderr)
        if imported.returncode or "ERROR:" in imported.stdout + imported.stderr:
            raise SystemExit(imported.returncode or 1)
    read_fd, write_fd = os.pipe()
    server = subprocess.Popen([args.xvfb, "-displayfd", str(write_fd), "-screen", "0", "3000x1900x24", "-nolisten", "tcp"], pass_fds=(write_fd,), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    os.close(write_fd)
    try:
        with os.fdopen(read_fd) as ready:
            display = ready.readline().strip()
        if not display:
            raise SystemExit(server.stderr.read().decode())
        env["DISPLAY"] = ":" + display
        failures = []
        for spec in args.screen or ["2856x1711:100", "2856x1711:150", "1440x900:100", "960x640:150", "360x640:150"]:
            screen, scale = spec.split(":")
            name = f"{screen}-{scale}"
            capture = output / (name + ".png")
            scene = ["--script", args.scene] if args.scene.endswith(".gd") else [args.scene]
            command = godot + ["--display-driver", "x11", "--rendering-method", "gl_compatibility"] + scene + ["--", f"--screen={screen}", f"--scale={scale}", f"--capture={capture}"] + args.argument
            if args.label == "before":
                command.append("--before")
            try:
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
            except subprocess.TimeoutExpired as error:
                log = (error.stdout or b"") + (error.stderr or b"")
                (output / (name + ".log")).write_bytes(log)
                print(log.decode(errors="replace"))
                raise
            log = result.stdout + result.stderr
            (output / (name + ".log")).write_text(log)
            print(name, "PASS" if result.returncode == 0 and "ERROR:" not in log else "FAIL", capture)
            if result.returncode or "ERROR:" in log:
                failures.append(name)
                print(log)
        return int(bool(failures))
    finally:
        server.terminate()
        server.communicate(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
