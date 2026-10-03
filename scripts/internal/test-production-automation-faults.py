#!/usr/bin/env python3
"""Backend-free gate faults; only test-owned subprocesses and mocked Docker calls.

No server, user credentials, user database or real Docker resource is touched.
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("test-production-automation.py")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("production_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class GateFaults(unittest.TestCase):
    def test_timeout_is_bounded_secret_free_and_process_is_reaped(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            pidfile = pathlib.Path(tmp) / "pid"
            code = f"import os,time,pathlib; pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)"
            started = time.monotonic()
            with self.assertRaises(gate.GateFailure) as error:
                gate.command([sys.executable, "-c", code, "SYNTHETIC_BEARER_TOKEN"], timeout=0.5)
            self.assertLess(time.monotonic() - started, 6)
            self.assertEqual(str(error.exception), "subprocess timed out")
            self.assertNotIn("SYNTHETIC_BEARER_TOKEN", str(error.exception))
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pidfile.read_text()), 0)

    def test_nonzero_command_never_retains_command_or_output(self):
        with self.assertRaises(gate.GateFailure) as error:
            gate.command([sys.executable, "-c", "import sys; print('SECRET'); sys.exit(9)", "SECRET"])
        self.assertEqual(str(error.exception), "subprocess returned nonzero")

    def test_cleanup_requires_verified_ownership_and_exact_id(self):
        cid = "a" * 64
        info = '[{"Name": "/' + gate.NAME + '", "Config": {"Labels": {"continuum.production-owner": "' + gate.OWNER + '"}}}]'
        with patch.object(gate, "docker", side_effect=[cid, info, "", ""]) as docker:
            gate.cleanup()
        self.assertEqual(docker.call_args_list[2].args, ("rm", "-f", cid))
        with patch.object(gate, "docker", side_effect=[cid, info.replace(gate.OWNER, "not-owned")]) as docker:
            with self.assertRaises(gate.GateFailure):
                gate.cleanup()
        self.assertEqual(docker.call_count, 2)

    def test_cleanup_failure_and_remaining_container_never_pass(self):
        cid = "a" * 64
        info = '[{"Name": "/' + gate.NAME + '", "Config": {"Labels": {"continuum.production-owner": "' + gate.OWNER + '"}}}]'
        for failure in [gate.GateFailure("subprocess timed out"), gate.GateFailure("subprocess returned nonzero")]:
            with patch.object(gate, "docker", side_effect=[cid, info, failure]):
                with self.assertRaises(gate.GateFailure):
                    gate.cleanup()
        with patch.object(gate, "docker", side_effect=[cid, info, "", cid]):
            with self.assertRaises(gate.GateFailure):
                gate.cleanup()
        output = io.StringIO()
        with patch.object(gate, "run_gate", return_value=False), patch.object(gate, "cleanup", side_effect=RuntimeError("SECRET")), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(gate.main(), 1)
        self.assertNotIn("PASS", output.getvalue())
        self.assertNotIn("cleanup_pass", output.getvalue())
        self.assertNotIn("SECRET", output.getvalue())
        self.assertIn("cleanup failed", output.getvalue())

    def test_inventory_failure_is_not_absence(self):
        with patch.object(gate, "docker", side_effect=gate.GateFailure("subprocess returned nonzero")):
            with self.assertRaises(gate.GateFailure):
                gate.cleanup()

    def test_audit_requires_new_exact_policy_event_not_prior_grant(self):
        message = "Production policy Wood target set to 10 by operator caller."
        before = [{"id": 1, "message": "Operator caller granted."}]
        with self.assertRaises(gate.GateFailure):
            gate.require_audit(before, before, message)
        for wrong in [message.replace("caller", "other"), message.replace("Wood", "Meat"), message.replace("10", "20"), "Operator caller granted."]:
            with self.assertRaises(gate.GateFailure):
                gate.require_audit(before, before + [{"id": 2, "message": wrong}], message)
        gate.require_audit(before, before + [{"id": 2, "message": message}], message)

    def test_rejection_requires_reducer_status_and_exact_semantic_class(self):
        for expected in [gate.AUTH_ERROR, gate.VALIDATION_ERROR]:
            self.assertTrue(gate.rejection_matches(530, expected, expected))
            for status, body in [(500, expected), (400, expected), (530, "invalid arguments"), (530, "trap"), (530, "unrelated " + expected)]:
                self.assertFalse(gate.rejection_matches(status, body, expected))

    def test_signals_unwind_active_subprocess_and_run_cleanup(self):
        for sig in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=sig), tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
                pidfile = pathlib.Path(tmp) / "child"
                cleaned = pathlib.Path(tmp) / "cleaned"
                child_code = f"import os,time,pathlib; pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)"
                harness = f"""import importlib.util,pathlib,sys
sys.dont_write_bytecode=True
s=importlib.util.spec_from_file_location('gate', {str(SCRIPT)!r})
g=importlib.util.module_from_spec(s); s.loader.exec_module(g)
g.run_gate=lambda: g.command([sys.executable, '-c', {child_code!r}, 'SECRET'])
g.cleanup=lambda: pathlib.Path({str(cleaned)!r}).write_text('verified')
sys.exit(g.main())
"""
                process = subprocess.Popen([sys.executable, "-c", harness], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not pidfile.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(pidfile.exists())
                    process.send_signal(sig)
                    stdout, stderr = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, 1)
                    self.assertTrue(cleaned.exists())
                    self.assertNotIn("PASS", stdout + stderr)
                    self.assertNotIn("SECRET", stdout + stderr)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(pidfile.read_text()), 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate(timeout=3)
                    if pidfile.exists():
                        try:
                            os.kill(int(pidfile.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    unittest.main()
