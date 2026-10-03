#!/usr/bin/env python3
"""Private, bounded backend-free integration gates, including a real exported PCK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import argparse

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parents[1]
GODOT = os.environ.get("GODOT", "godot")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review-only", action="store_true", help="focused F1/F2 production regressions and actual PCK, not unchanged full gates")
    review_only = parser.parse_args().review_only
    state = Path(os.environ.get("UI_CHECK_OUTPUT", tempfile.mkdtemp(prefix="ui-checks-", dir="/tmp/opencode")))
    state.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    for key, leaf in [("HOME", "home"), ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")]:
        path = state / leaf
        path.mkdir(mode=0o700, exist_ok=True)
        env[key] = str(path)
    failures = []

    def run(name, project, *args):
        try:
            result = subprocess.run([GODOT, "--headless", "--path", str(project), *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b""
            (state / (name + ".log")).write_text(output.decode(errors="replace") if isinstance(output, bytes) else output)
            failures.append(name + "-timeout")
            print("FAIL " + name + " (timeout)", flush=True)
            return False
        (state / (name + ".log")).write_text(result.stdout)
        errors = [line for line in result.stdout.splitlines() if "SCRIPT ERROR:" in line or line.startswith("ERROR:")]
        errors = [line for line in errors if not (name == "ui_scale_test" and "ConfigFile parse error" in line)]
        passed = result.returncode == 0 and not errors and "_FAIL" not in result.stdout
        print(("PASS " if passed else "FAIL ") + name + ("" if passed else f" (exit {result.returncode})"), flush=True)
        if not passed:
            failures.append(name)
            print(result.stdout)
        return passed

    if not run("import", PROJECT, "--editor", "--import"):
        (state / "summary.log").write_text("FAIL import\n")
        return True
    for name in (["workspace_test", "map_client_legacy_ui_test", "diagnostics_integration_test"] if review_only else ["workspace_test", "terrain_test", "terrain_ui_test", "map_client_test", "map_client_legacy_ui_test", "main_menu_test", "diagnostics_integration_test", "map_style_test", "planning_test", "world_art_test", "large_map_wire_test", "world_art_review_test", "legacy_surface_stream_test"]):
        run(name, PROJECT, "--scene", f"res://tools/{name}.tscn")
    run("workspace_collapsed_production_test", PROJECT, "--scene", "res://tools/workspace_collapsed_production_test.tscn")
    run("role_panels_test", PROJECT, "--scene", "res://tools/role_panels_test.tscn", "--", "--profile=developer")
    for name in ([] if review_only else ["server_browser_test", "diagnostics_test", "diagnostics_bar_test", "history_test", "session_observations_test", "ui_data_test", "ui_theme_test", "map_regions_test", "ui_scale_test", "large_map_foundations_test", "sdk_subscription_cache_test"]):
        run(name, PROJECT, "--script", f"res://tools/{name}.gd")
    if not review_only:
        run("map-client-cpu-profile", PROJECT, "--scene", "res://tools/map_client_profile.tscn", "--", "--edge=24")
    if review_only:
        run("review-regressions", PROJECT, "--scene", "res://tools/ui_review_regression.tscn", "--", "--status=problem", "--focus", "--reduced-motion")
        run("status-budget", PROJECT, "--scene", "res://tools/ui_status_budget_test.tscn", "--", "--screen=960x640", "--scale=150", "--status=problem", "--focus", "--reduced-motion")
    for status in ([] if review_only else ["nominal", "problem"]):
        run("composition-" + status, PROJECT, "--scene", "res://tools/ui_composition_fixture.tscn", "--", "--screen=1440x900", "--scale=100", "--status=" + status, "--focus", "--reduced-motion", "--layout-qa")

    # Relative component-test imports require the original repository shape.
    copy = state / "export-project"
    shutil.copytree(PROJECT, copy, ignore=shutil.ignore_patterns(".godot", "build"), dirs_exist_ok=True)
    for name in ["ui_components_test", "ui_components_controls_test", "ui_components_regression_test"]:
        destination = copy / "tools" / (name + ".gd")
        source = (ROOT / "tools" / (name + ".gd")).read_text()
        destination.write_text(source.replace("../client/godot/ui/", "../ui/").replace("res://client/godot/ui/", "res://ui/"))
    if not run("export-import", copy, "--editor", "--import"):
        (state / "summary.log").write_text("FAIL " + ", ".join(failures) + "\n")
        return True
    for name in (["ui_components_regression_test"] if review_only else ["ui_components_test", "ui_components_controls_test", "ui_components_regression_test"]):
        run(name, copy, "--script", f"res://tools/{name}.gd")
    # Test-only preset includes actual widgets + fixture; production preset stays untouched.
    preset = copy / "export_presets.cfg"
    preset.write_text(preset.read_text().replace('exclude_filter="tools/*"', 'exclude_filter=""'))
    pack = state / "ui.pck"
    if run("export-pack", copy, "--export-pack", "Linux", str(pack)):
        # No loose project sources: resolve scripts, fonts, glyphs and embedded SVG
        # geometry from the exported pack in an otherwise empty directory.
        empty = state / "pack-runtime"
        empty.mkdir(exist_ok=True)
        fixture = "ui_status_budget_test" if review_only else "ui_composition_fixture"
        run("packed-widgets", empty, "--main-pack", str(pack), "--scene", f"res://tools/{fixture}.tscn", "--", "--screen=960x640" if review_only else "--screen=1440x900", "--scale=150" if review_only else "--scale=100", "--status=problem", "--reduced-motion", "--focus", "--layout-qa")
    (state / "summary.log").write_text("FAIL " + ", ".join(failures) if failures else "ALL_BACKEND_FREE_GATES_PASS\n")
    print("Evidence:", state)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
