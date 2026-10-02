#!/usr/bin/env python3
"""Runner regression tests: no Godot, servers, or network required."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ui_theme_check as runner


class RunnerTest(unittest.TestCase):
    def test_unique_private_fallback(self):
        states = []

        def record(project, env, executable, timeout):
            state = Path(env["XDG_DATA_HOME"]).parent
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertEqual(executable, "/chosen/godot")
            self.assertEqual(timeout, 7)
            states.append(state)

        with patch.dict(os.environ, {"GODOT": "/chosen/godot"}, clear=True), patch.object(runner, "check", record):
            runner.main(["--timeout", "7"])
            runner.main(["--timeout", "7"])
        self.assertNotEqual(states[0], states[1])
        self.assertTrue(all(not state.exists() for state in states))

    def test_explicit_state_overrides_environment(self):
        with tempfile.TemporaryDirectory() as root:
            explicit = Path(root) / "explicit"
            environment = Path(root) / "environment"
            with patch.dict(os.environ, {"UI_THEME_STATE_DIR": str(environment)}), patch.object(runner, "check") as check:
                runner.main(["--state-dir", str(explicit)])
                self.assertEqual(check.call_args.args[1]["XDG_CONFIG_HOME"], str(explicit / "config"))
                runner.main([])
                self.assertEqual(check.call_args.args[1]["XDG_CACHE_HOME"], str(environment / "cache"))

    def test_executable_and_timeout_forwarded(self):
        result = subprocess.CompletedProcess([], 0, "passed")
        with patch.object(runner.subprocess, "run", return_value=result) as run:
            runner.run(Path("/project"), {"XDG_DATA_HOME": "/private"}, "/custom/godot", 9, "--editor")
        self.assertEqual(run.call_args.args[0][0], "/custom/godot")
        self.assertEqual(run.call_args.kwargs["timeout"], 9)
        self.assertEqual(run.call_args.kwargs["env"]["XDG_DATA_HOME"], "/private")

    def test_timeout_reports_clear_failure_and_partial_output(self):
        with patch.object(runner.subprocess, "run", side_effect=subprocess.TimeoutExpired("godot", 2, output=b"partial output")), contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(SystemExit, "timed out after 2s"):
                runner.run(Path("/project"), {}, "godot", 2)
        self.assertIn("partial output", output.getvalue())

    def test_invalid_timeouts(self):
        for value in ["0", "-1", "nan", "inf"]:
            with self.subTest(value=value), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    runner.main(["--timeout", value])
                self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
