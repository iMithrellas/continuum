#!/usr/bin/env python3
"""Offline runner faults: mocks and private Python probes, no Godot/server/SDK."""
import contextlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
import gameplay_client_checks as runner


class RunnerFaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gameplay-runner-fault-", dir="/tmp/opencode")
        self.output = Path(self.tmp.name)
        self.env = runner.private_environment(self.output)
        self.capture = contextlib.redirect_stdout(io.StringIO())
        self.capture.__enter__()

    def tearDown(self):
        self.capture.__exit__(None, None, None)
        self.tmp.cleanup()

    def run_probe(self, code, marker="PROBE_PASS", timeout=3):
        return runner.run_check("probe", [sys.executable, "-u", "-c", code],
                                marker, timeout, self.env, self.output)

    def test_ordinary_success_has_log_and_summary(self):
        result = self.run_probe("print('PROBE_PASS')")
        self.assertTrue(result.passed)
        self.assertEqual(result.log.read_text(), "PROBE_PASS\n")
        self.assertIn("PASS probe", (self.output / "summary.log").read_text())

    def test_exit_zero_with_script_error_error_or_leak_is_failure(self):
        for diagnostic in ("SCRIPT ERROR: parse failed", "ERROR: invalid scene",
                           "WARNING: ObjectDB instances leaked at exit",
                           "ERROR: 2 resources still in use at exit", "PROBE_FAIL"):
            with self.subTest(diagnostic=diagnostic):
                result = self.run_probe(f"print('PROBE_PASS'); print({diagnostic!r})")
                self.assertFalse(result.passed)
                self.assertIn(diagnostic, result.log.read_text())

    def test_all_objectdb_leak_spellings_fail_after_natural_exit_zero(self):
        popen = subprocess.Popen
        producers = []

        def naturally_exited(*args, **kwargs):
            process = popen(*args, **kwargs)
            try:
                process.wait(timeout=3)
            except BaseException:
                runner.dispose_group(process)
                raise
            producers.append(process)
            self.assertEqual(process.returncode, 0)
            return process

        for noun, count in (("instance", "1"), ("instances", "2")):
            for verb in ("", "was ", "were "):
                for prefix in ("", count + " "):
                    diagnostic = f"WARNING: {prefix}ObjectDB {noun} {verb}leaked at exit (run with `--verbose` for details)."
                    with self.subTest(diagnostic=diagnostic), patch.object(runner.subprocess, "Popen", side_effect=naturally_exited):
                        result = self.run_probe(f"print('PROBE_PASS'); print({diagnostic!r})")
                    self.assertFalse(result.passed)
                    self.assertIn("runtime error or leak diagnostic", result.reason)
                    self.assertIn(diagnostic, result.log.read_text())
                    self.assertEqual(producers[-1].returncode, 0)
                    self.assertFalse(runner.group_alive(producers[-1].pid))

    def test_resource_in_use_warning_still_fails_with_success_marker(self):
        result = self.run_probe("print('PROBE_PASS'); print('WARNING: 2 resources still in use at exit')")
        self.assertFalse(result.passed)
        self.assertIn("runtime error or leak diagnostic", result.reason)

    def test_unrelated_normal_warnings_do_not_fail(self):
        result = self.run_probe("print('WARNING: V-Sync is not supported by this graphics driver.'); "
                                "print('WARNING: ObjectDB instance count unavailable.'); print('PROBE_PASS')")
        self.assertTrue(result.passed)

    def test_missing_marker_and_nonzero_are_failure(self):
        self.assertIn("missing expected success marker", self.run_probe("print('not the marker')").reason)
        self.assertIn("nonzero exit", self.run_probe("print('PROBE_PASS'); raise SystemExit(7)").reason)
        self.assertTrue(runner.log_problem("WORLD_BINDINGS_BASE_PASS: base only\n", r"WORLD_BINDINGS_PASS: .+"))
        self.assertTrue(runner.log_problem("prefix PROBE_PASS suffix\n", "PROBE_PASS"))

    def test_timeout_kills_owned_spawned_child_even_when_term_is_ignored(self):
        pidfile = self.output / "child.pid"
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        code = ("import subprocess,sys,pathlib,signal,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                f"pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); "
                "print('PROBE_STARTED', flush=True); time.sleep(60)")
        started = time.monotonic()
        result = self.run_probe(code, timeout=0.6)
        self.assertFalse(result.passed)
        self.assertIn("wall timeout", result.reason)
        self.assertLess(time.monotonic() - started, 4)
        self.assertTrue(pidfile.exists(), "owned child probe actually spawned")
        pid = int(pidfile.read_text())
        stat = Path(f"/proc/{pid}/stat")
        self.assertTrue(not stat.exists() or stat.read_text().rsplit(")", 1)[1].split()[0] in ("Z", "X"))
        self.assertIn("PROBE_STARTED", result.log.read_text())

    def test_successful_leader_cannot_leave_child_running_and_still_pass(self):
        pidfile = self.output / "child.pid"
        code = ("import subprocess,sys,pathlib; "
                "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
                f"pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); print('PROBE_PASS')")
        result = self.run_probe(code)
        self.assertFalse(result.passed)
        self.assertIn("leaked child process", result.reason)
        stat = Path(f"/proc/{int(pidfile.read_text())}/stat")
        self.assertTrue(not stat.exists() or stat.read_text().rsplit(")", 1)[1].split()[0] in ("Z", "X"))

    def test_live_parse_failure_terminates_instead_of_waiting_for_full_timeout(self):
        result = self.run_probe("import time; print('SCRIPT ERROR: bad fixture', flush=True); time.sleep(60)", timeout=20)
        self.assertFalse(result.passed)
        self.assertIn("runtime error", result.reason)
        self.assertLess(result.elapsed, 4)

    def test_cancel_unwinds_and_disposes_exact_spawned_group(self):
        process = Mock(pid=123456, returncode=None)
        process.poll.return_value = None
        process.wait.side_effect = runner.Cancelled("signal")
        with patch.object(runner.subprocess, "Popen", return_value=process) as spawn, \
                patch.object(runner, "dispose_group") as dispose:
            with self.assertRaises(runner.Cancelled):
                self.run_probe("unused")
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        dispose.assert_called_once_with(process)
        self.assertIn("FAIL probe", (self.output / "summary.log").read_text())

    def test_disposal_failure_never_passes(self):
        with patch.object(runner, "dispose_group", side_effect=RuntimeError("disposal failed")):
            result = self.run_probe("print('PROBE_PASS')")
        self.assertFalse(result.passed)
        self.assertIn("disposal unverified", result.reason)

    def test_grace_then_kill_only_the_owned_group_and_restore_signal_handlers(self):
        process = Mock(pid=123456)
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        with patch.object(runner, "group_alive", side_effect=[True, True, True, False]), \
                patch.object(runner.os, "killpg") as kill:
            runner.dispose_group(process, grace=0)
        self.assertEqual(kill.call_args_list[0].args, (123456, signal.SIGTERM))
        self.assertEqual(kill.call_args_list[1].args, (123456, signal.SIGKILL))
        for sig, handler in handlers.items():
            self.assertEqual(signal.getsignal(sig), handler)

    def test_private_environment_does_not_change_parent_or_use_user_display(self):
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMPDIR"):
            self.assertTrue(Path(self.env[key]).is_relative_to(self.output))
            self.assertEqual(Path(self.env[key]).stat().st_mode & 0o777, 0o700)
            self.assertNotEqual(self.env[key], os.environ.get(key))
        self.assertNotIn("DISPLAY", self.env)
        self.assertNotIn("WAYLAND_DISPLAY", self.env)

    def test_manifest_preserves_original_contracts_and_adds_only_requested_tests(self):
        original = [
            "enum_key_cache_test", "unit_enum_key_contract_test", "production_policy_bindings_test",
            "building_properties_bindings_test", "operator_access_test", "colony_operations_model_test",
            "production_suitability_test", "large_map_foundations_test", "large_map_wire_test",
            "sdk_subscription_cache_test", "colony_guidance_test", "production_targets_test",
            "production_wiring_test", "map_feedback_test", "map_inspector_test", "planning_test", "ux_panels_test",
        ]
        self.assertEqual([name for name, _, _ in runner.CHECKS], original + [
            "world_bindings_test", "world_bindings_schema_test", "sdk_u64_bitpatterns_test"])
        self.assertEqual(dict((name, mode) for name, mode, _ in runner.CHECKS)["large_map_wire_test"], "scene")
        for name, mode, _ in runner.CHECKS:
            self.assertTrue((runner.PROJECT / "tools" / (name + (".tscn" if mode == "scene" else ".gd"))).exists())

    def test_planning_zero_failures_is_required_without_modifying_assertions(self):
        marker = next(marker for name, _, marker in runner.CHECKS if name == "planning_test")
        self.assertFalse(runner.log_problem("PLANNING_TEST 12 assertions, 0 failures\n", marker))
        self.assertTrue(runner.log_problem("PLANNING_TEST 12 assertions, 1 failures\n", marker))

    def test_import_error_blocks_tests_and_suite_failure_is_not_success(self):
        with patch.object(runner.tempfile, "mkdtemp", return_value=str(self.output / "suite")), \
                patch.object(runner, "private_environment", return_value=self.env), \
                patch.object(runner, "run_check", return_value=runner.Result("import", False, "parse", 0, self.output / "import.log")) as run:
            self.assertEqual(runner.main([]), 1)
        self.assertEqual(run.call_count, 1)
        self.assertIn("--import", run.call_args.args[1])

    def test_cleanup_unverified_stops_suite_instead_of_spawning_more_tests(self):
        results = [runner.Result("import", True, "ok", 0, self.output / "import.log"),
                   runner.Result("first", False, "owned process group disposal unverified", 0, self.output / "first.log")]
        with patch.object(runner.tempfile, "mkdtemp", return_value=str(self.output / "suite")), \
                patch.object(runner, "private_environment", return_value=self.env), \
                patch.object(runner, "run_check", side_effect=results) as run:
            self.assertEqual(runner.main([]), 1)
        self.assertEqual(run.call_count, 2)

    def test_real_sigterm_cancels_and_disposes_probe_session(self):
        leader_file = self.output / "leader.pid"
        probe = ("import pathlib,os,time; "
                 f"pathlib.Path({str(leader_file)!r}).write_text(str(os.getpid())); "
                 "print('STARTED',flush=True); time.sleep(60)")
        harness = f"""import sys,signal
sys.dont_write_bytecode=True
sys.path.insert(0, {str(Path(__file__).parent)!r})
import gameplay_client_checks as r
from pathlib import Path
def interrupt(sig, frame): raise r.Cancelled('signal')
signal.signal(signal.SIGTERM, interrupt)
try:
    r.run_check('cancel', [sys.executable, '-u', '-c', {probe!r}], 'PROBE_PASS', 30, dict(__import__('os').environ), Path({str(self.output)!r}))
except r.Cancelled:
    sys.exit(1)
sys.exit(0)
"""
        process = subprocess.Popen([sys.executable, "-c", harness], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True, env=self.env)
        try:
            deadline = time.monotonic() + 5
            while not leader_file.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(leader_file.exists(), "owned probe started before cancellation")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1, stdout + stderr)
            self.assertIn("FAIL cancel", stdout)
            self.assertNotIn("PASS cancel", stdout)
            self.assertFalse(runner.group_alive(int(leader_file.read_text())))
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
            if leader_file.exists():
                pgid = int(leader_file.read_text())
                if runner.group_alive(pgid):
                    os.killpg(pgid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
