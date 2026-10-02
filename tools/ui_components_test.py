#!/usr/bin/env python3
"""Run pure GDScript models without project autoloads or live colony access."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STATE = Path("/tmp/opencode/continuum-ui-components-state")
PROJECT = STATE / "model-tests"


def main():
    # Theme resources are copied read-only into an isolated fixture.
    parser = argparse.ArgumentParser()
    parser.add_argument("--theme-root", type=Path, help="repository containing the actual UI theme")
    args = parser.parse_args()
    (PROJECT / "tools").mkdir(parents=True, exist_ok=True)
    scripts = PROJECT / "client/godot/ui/components"
    scripts.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "client/godot/ui/components/models.gd", scripts / "models.gd")
    shutil.copy2(ROOT / "tools/ui_components_test.gd", PROJECT / "tools/ui_components_test.gd")
    (PROJECT / "project.godot").write_text('config_version=5\n[application]\nconfig/name="UI component model tests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    env = dict(os.environ)
    for variable, directory in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")]:
        env[variable] = str(STATE / directory)
        (STATE / directory).mkdir(exist_ok=True)
    godot = os.environ.get("GODOT", "godot")
    commands = [[godot, "--headless", "--path", str(PROJECT), "--script", "res://tools/ui_components_test.gd"]]
    if args.theme_root:
        theme = args.theme_root / "client/godot/ui/theme"
        shutil.copytree(ROOT / "client/godot/ui/components", scripts, dirs_exist_ok=True)
        shutil.copytree(theme, PROJECT / "ui/theme", dirs_exist_ok=True)
        shutil.copy2(ROOT / "tools/ui_components_controls_test.gd", PROJECT / "tools/ui_components_controls_test.gd")
        shutil.copy2(ROOT / "tools/ui_components_regression_test.gd", PROJECT / "tools/ui_components_regression_test.gd")
        commands.append([godot, "--headless", "--path", str(PROJECT), "--editor", "--import"])
        commands.append([godot, "--headless", "--path", str(PROJECT), "--script", "res://tools/ui_components_controls_test.gd"])
        commands.append([godot, "--headless", "--path", str(PROJECT), "--script", "res://tools/ui_components_regression_test.gd"])
    for command in commands:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode or "SCRIPT ERROR" in result.stderr or "ERROR:" in result.stderr:
            print(result.stdout, end="")
            print(result.stderr, end="")
            return result.returncode or 1
        if "--import" in command:
            print("Isolated theme assets and component scripts imported successfully")
        else:
            print(result.stdout, end="")
            print(result.stderr, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
