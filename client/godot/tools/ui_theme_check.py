#!/usr/bin/env python3
"""Offline theme checks; --state-dir/UI_THEME_STATE_DIR selects XDG state."""
import argparse
from contextlib import ExitStack
import hashlib
import math
import os
from pathlib import Path
import subprocess
import tempfile

CANONICAL_LICENSE_SHA256 = "7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da"


def run(project, env, executable, timeout, *args):
    command = [executable, "--headless", "--path", str(project), *args]
    try:
        result = subprocess.run(command, env=env, timeout=timeout, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        print(output)
        raise SystemExit(f"UI check timed out after {timeout:g}s: {command!r}") from error
    except OSError as error:
        raise SystemExit(f"Cannot execute GODOT={executable!r}: {error}") from error
    print(result.stdout)
    if result.returncode or "SCRIPT ERROR:" in result.stdout or "ERROR:" in result.stdout:
        raise SystemExit(result.returncode or 1)


def check(project, env, executable, timeout):
    def invoke(*args):
        run(project, env, executable, timeout, *args)

    license_bytes = (project / "ui/theme/fonts/OFL.txt").read_bytes()
    if hashlib.sha256(license_bytes).hexdigest() != CANONICAL_LICENSE_SHA256:
        raise SystemExit("OFL bytes differ from the canonical supplied license (including CRLF)")
    invoke("--editor", "--import")
    theme = project / "ui/theme/theme.tres"
    invoke("--script", "res://ui/theme/generate_theme.gd")
    first = hashlib.sha256(theme.read_bytes()).hexdigest()
    invoke("--script", "res://ui/theme/generate_theme.gd")
    if hashlib.sha256(theme.read_bytes()).hexdigest() != first:
        raise SystemExit("Theme generation must be byte deterministic")
    invoke("--script", "res://tools/ui_theme_test.gd")
    source = project / "ui/theme/tokens.json"
    fixture = source.with_suffix(".json.test-fixture")
    if fixture.exists():
        raise SystemExit("An earlier fixture needs recovery before tests")
    source.rename(fixture)
    try:
        invoke("--script", "res://tools/ui_theme_test.gd", "--", "--packaged")
    finally:
        fixture.rename(source)
    print("UI import, determinism and contract checks passed:", first)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", default=os.environ.get("UI_THEME_STATE_DIR"),
                        help="XDG state root (default: a unique private temporary directory)")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="maximum seconds per Godot subprocess (default: 120)")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    project = Path(__file__).resolve().parents[1]
    executable = os.environ.get("GODOT", "godot")
    with ExitStack() as stack:
        if args.state_dir:
            state = Path(args.state_dir).expanduser().resolve()
            state.mkdir(parents=True, exist_ok=True, mode=0o700)
        else:
            preferred = Path("/tmp/opencode")
            state = Path(stack.enter_context(tempfile.TemporaryDirectory(
                prefix="ui-theme-", dir=preferred if preferred.is_dir() else None)))
        env = dict(os.environ)
        for name, leaf in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")]:
            env[name] = str(state / leaf)
            (state / leaf).mkdir(parents=True, exist_ok=True, mode=0o700)
        print("UI check state:", state)
        check(project, env, executable, args.timeout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
