#!/usr/bin/env python3
"""Actual-main Atlas contracts and private software-rendered screenshot matrix.

GODOT=godot python3 client/godot/tools/atlas_ui_checks.py
XVFB=/path/to/Xvfb python3 client/godot/tools/atlas_ui_checks.py --render
Use --fixture-only for captures without running the redesign contracts.
Use --render --keep-open --screen=1440x900 --scale=100 --command to retain
an interactive fixture on the private display (not the human desktop).
All settings, workspace files, return snapshots and native discovery are isolated.
"""

import argparse
import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
MATRIX = (
    (1440, 900, 100), (1440, 900, 125),
    (960, 640, 100), (960, 640, 150), (360, 480, 150),
)


def run(command, env, log, marker=None, timeout=180):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    log.write_text(output)
    if result.returncode or "SCRIPT ERROR:" in output or "ERROR:" in output:
        print(output, end="")
        raise RuntimeError(f"Godot failed; see {log}")
    if marker and marker not in output:
        raise RuntimeError(f"Missing {marker}; see {log}")
    print(f"PASS {log.stem}")


def start_xvfb(binary, env, output):
    read_fd, write_fd = os.pipe()
    log = (output / "xvfb.log").open("w")
    process = None
    try:
        process = subprocess.Popen(
            [binary, "-displayfd", str(write_fd), "-screen", "0", "1600x1000x24",
             "-nolisten", "tcp"],
            env=env,
            pass_fds=(write_fd,),
            stdout=log,
            stderr=log,
        )
        os.close(write_fd)
        write_fd = None
        if not select.select([read_fd], [], [], 20)[0]:
            raise RuntimeError("Xvfb did not allocate a private display within 20 seconds")
        display = os.read(read_fd, 128).decode().strip()
        if not display.isdigit():
            raise RuntimeError(f"Xvfb failed; see {output / 'xvfb.log'}")
        env["DISPLAY"] = ":" + display
        return process
    except Exception:
        if process is not None:
            process.terminate()
            process.wait(timeout=10)
        raise
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)
        log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--fixture-only", action="store_true")
    parser.add_argument("--xvfb", default=os.environ.get("XVFB") or shutil.which("Xvfb"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--screen", help="Single size WxH; otherwise use four reference budgets plus 360x480/150%")
    parser.add_argument("--scale", type=int, default=100)
    parser.add_argument("--workspace", default="diagnostics")
    parser.add_argument("--command", action="store_true")
    parser.add_argument("--settings", action="store_true")
    parser.add_argument("--keep-open", action="store_true")
    args = parser.parse_args()
    if args.keep_open and (not args.render or not args.screen):
        parser.error("--keep-open requires --render and --screen")
    if args.render and not args.xvfb:
        parser.error("--render requires --xvfb=/path/to/Xvfb, XVFB, or Xvfb on PATH")
    output = (
        args.output or Path(tempfile.mkdtemp(prefix="atlas-ui-", dir="/tmp/opencode"))
    ).resolve()
    output.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix="atlas-ui-state-", dir="/tmp/opencode"))
    env = dict(os.environ)
    for name in (
        "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
    ):
        directory = state / name.lower()
        directory.mkdir(mode=0o700)
        env[name] = str(directory)
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    env["LIBGL_ALWAYS_SOFTWARE"] = "1"
    env["GALLIUM_DRIVER"] = "llvmpipe"
    env["GODOT_SILENCE_ROOT_WARNING"] = "1"
    godot = shlex.split(os.environ.get("GODOT", "godot"))
    base = godot + ["--path", str(PROJECT), "--audio-driver", "Dummy"]
    xvfb = None
    failures = []
    results = []

    def check_case(command, name, marker, timeout=180):
        try:
            run(command, env, output / f"{name}.log", marker, timeout)
            results.append("PASS " + name)
            return True
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(name)
            results.append("FAIL " + name)
            print(f"FAIL: {error}")
            return False
        finally:
            (output / "summary.log").write_text("\n".join(results) + "\n")

    print(f"Evidence: {output}\nIsolated user state: {state}")
    try:
        run(base + ["--headless", "--editor", "--import"], env, output / "import.log")
        matrix = MATRIX
        if args.screen:
            width, height = map(int, args.screen.lower().split("x"))
            matrix = ((width, height, args.scale),)
        if not args.fixture_only:
            for width, height, scale in matrix:
                name = f"test-{width}x{height}-{scale}"
                command = base + [
                    "--headless", "res://tools/atlas_ui_test.tscn", "--",
                    f"--screen={width}x{height}", f"--scale={scale}",
                ]
                check_case(command, name, "ATLAS_UI_TEST_PASS")
        if args.render:
            xvfb = start_xvfb(args.xvfb, env, output)
            print(f"Private display: {env['DISPLAY']} (llvmpipe; not the human desktop)")
            for width, height, scale in matrix:
                scenarios = [
                    ("diagnostics", ["--workspace=diagnostics", "--command"]),
                    ("daily", ["--workspace=daily"]),
                    ("settings", ["--workspace=daily", "--settings"]),
                ]
                if args.screen:
                    flags = [f"--workspace={args.workspace}"]
                    if args.command:
                        flags.append("--command")
                    if args.settings:
                        flags.append("--settings")
                    suffix = "-settings" if args.settings else "-command" if args.command else ""
                    scenarios = [(args.workspace + suffix, flags)]
                for scenario, flags in scenarios:
                    name = f"{scenario}-{width}x{height}-{scale}"
                    command = base + [
                        "--display-driver", "x11", "--rendering-method", "gl_compatibility",
                        "res://tools/atlas_ui_fixture.tscn", "--",
                        f"--screen={width}x{height}", f"--scale={scale}",
                        f"--capture={output / (name + '.png')}",
                    ] + flags
                    if args.keep_open:
                        command.append("--keep-open")
                    passed = check_case(
                        command, name, "ATLAS_UI_FIXTURE_PASS",
                        timeout=None if args.keep_open else 180,
                    )
                    if passed and not (output / f"{name}.png").is_file():
                        failures.append(name + "-missing-screenshot")
                        results.append("FAIL " + name + "-missing-screenshot")
        (output / "summary.log").write_text("\n".join(results) + "\n")
        return 1 if failures else 0
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        if xvfb is not None:
            xvfb.terminate()
            xvfb.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
