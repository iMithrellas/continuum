#!/usr/bin/env python3
"""Offline safety/oracle regressions: no Docker, server, credentials or network.

All subprocess handles and results are mocked. Only uniquely owned temporary
evidence directories under /tmp/opencode are created and automatically removed.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("connected_gate", Path(__file__).with_name("connected-colony-check.py"))
gate_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate_module)
TOKEN = "SYNTHETIC_BEARER_NEVER_RETAIN_THIS_MARKER"
CONTAINER = "a" * 64


class FaultTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="continuum-connected-offline-", dir="/tmp/opencode")
        self.root = Path(self.temporary.name)
        with patch.object(gate_module.socket, "socket") as socket:
            socket.return_value.__enter__.return_value.getsockname.return_value = ("127.0.0.1", 12345)
            self.gate = gate_module.Gate(self.root)
        self.gate.cli = Path("/mock/cli")
        self.output = io.StringIO()
        self.capture = contextlib.redirect_stdout(self.output)
        self.capture.__enter__()

    def tearDown(self):
        # Never invoke close() here: mocked failures deliberately retain handles;
        # teardown must not turn those handles into real subprocess calls.
        self.gate.events.close()
        self.capture.__exit__(None, None, None)
        self.temporary.cleanup()

    def result(self, code=0, out="", err=""):
        return subprocess.CompletedProcess([], code, out, err)

    def events(self):
        return [json.loads(line) for line in (self.root / "evidence.jsonl").read_text().splitlines()]

    def test_publish_success_without_world_readiness_never_consumes_state(self):
        with patch.object(self.gate, "identity", return_value="identity"), \
                patch.object(self.gate, "command", side_effect=["published", RuntimeError(TOKEN)]) as command, \
                patch.object(self.gate, "call") as call, patch.object(self.gate, "rows") as rows:
            self.assert_secret_safe(lambda: self.gate.baseline(Path("/owned/module.wasm")))
        self.assertEqual(command.call_args_list[0].args[0], "publish")
        self.assertEqual(command.call_args_list[1].args[-1], "SELECT table_name FROM st_table")
        self.assertLessEqual(command.call_args_list[1].kwargs["timeout"], 30)
        call.assert_not_called()
        rows.assert_not_called()

    def assert_secret_safe(self, operation):
        try:
            operation()
        except Exception as error:
            rendered = "".join(traceback.format_exception(error))
            self.gate.record("fault_error", error=str(error))
            self.assertNotIn(TOKEN, rendered)
            self.assertNotIn(TOKEN, str(error))
        else:
            self.fail("fault unexpectedly succeeded")
        self.assertNotIn(TOKEN, self.output.getvalue())
        self.assertNotIn(TOKEN, (self.root / "evidence.jsonl").read_text())

    def test_login_timeout_actual_run_path_redacts_traceback_and_evidence(self):
        process = Mock(pid=123, returncode=-9)
        process.poll.return_value = None
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(["cli", "login", "--token", TOKEN], 30, output=TOKEN, stderr=TOKEN),
            (TOKEN, TOKEN),
        ]
        with patch.object(gate_module.subprocess, "Popen", return_value=process) as spawn, \
                patch.object(gate_module.os, "killpg"):
            self.assert_secret_safe(lambda: self.gate.command("login", "--token", TOKEN))
        self.assertIn(TOKEN, spawn.call_args.args[0], "real login must still receive the actual credential")
        self.assertEqual(process.communicate.call_args_list[-1].kwargs, {"timeout": 5})

    def test_login_timeout_injected_at_command_boundary_is_also_redacted(self):
        with patch.object(self.gate, "run", side_effect=subprocess.TimeoutExpired(["--token", TOKEN], 30)):
            self.assert_secret_safe(lambda: self.gate.command("login", "--token", TOKEN))

    def test_spawn_exception_with_token_has_no_visible_exception_chain(self):
        with patch.object(gate_module.subprocess, "Popen", side_effect=OSError(TOKEN)):
            self.assert_secret_safe(lambda: self.gate.command("login", "--token", TOKEN))

    def test_timeout_during_subprocess_disposal_stays_bounded_and_redacted(self):
        process = Mock(pid=123, returncode=None)
        process.poll.return_value = None
        process.communicate.side_effect = subprocess.TimeoutExpired(["--token", TOKEN], 30)
        with patch.object(gate_module.subprocess, "Popen", return_value=process), \
                patch.object(gate_module.os, "killpg"):
            self.assert_secret_safe(lambda: self.gate.command("login", "--token", TOKEN))
        self.assertEqual(process.communicate.call_count, 2)
        self.assertEqual(process.communicate.call_args.kwargs, {"timeout": 5})

    def test_nonzero_login_output_is_redacted(self):
        with patch.object(self.gate, "run", return_value=self.result(1, TOKEN, TOKEN)):
            self.assert_secret_safe(lambda: self.gate.command("login", "--token", TOKEN))

    def test_checked_timeout_and_token_equals_form_are_safe(self):
        process = Mock(pid=123, returncode=-9)
        process.poll.return_value = None
        process.communicate.side_effect = [subprocess.TimeoutExpired(["--token=" + TOKEN], 1), ("", "")]
        with patch.object(gate_module.subprocess, "Popen", return_value=process), \
                patch.object(gate_module.os, "killpg"):
            self.assert_secret_safe(lambda: self.gate.checked(["cli", "login", "--token=" + TOKEN], 1))

    def assert_cleanup_failure(self, responses):
        self.gate.container = CONTAINER
        with patch.object(self.gate, "run", side_effect=responses) as commands:
            with self.assertRaisesRegex(RuntimeError, "owned cleanup failed"):
                self.gate.close(successful=True)
        names = [event["event"] for event in self.events()]
        self.assertIn("cleanup_failed", names)
        self.assertNotIn("cleanup_pass", names)
        self.assertNotIn("CONNECTED_COLONY_PASS", names)
        self.assertFalse(self.gate.private.exists(), "container failure must not prevent independent private cleanup")
        self.assertEqual(self.gate.container, CONTAINER, "retain exact handle for safe retry")
        self.assertTrue(all(call.args[1] == 15 for call in commands.call_args_list))

    def test_failed_container_removal_never_passes(self):
        self.assert_cleanup_failure([self.result(1, err="daemon refuses removal")])

    def test_successful_rm_but_container_still_present_never_passes(self):
        self.assert_cleanup_failure([self.result(), self.result(0, out='[{"Id":"' + CONTAINER + '"}]')])

    def test_inspect_daemon_failure_is_not_proof_of_absence(self):
        self.assert_cleanup_failure([self.result(), self.result(1, err="cannot connect to Docker daemon")])

    def test_container_removal_timeout_never_passes(self):
        self.assert_cleanup_failure([subprocess.TimeoutExpired(["docker", "rm", CONTAINER], 15)])

    def test_verified_disposal_is_required_before_overall_pass(self):
        self.gate.container = CONTAINER
        with patch.object(self.gate, "run", side_effect=[self.result(), self.result(1, err="No such container: " + CONTAINER)]):
            self.gate.close(successful=True)
        names = [event["event"] for event in self.events()]
        self.assertEqual(names, ["owned_container_removed", "cleanup_pass", "CONNECTED_COLONY_PASS"])
        self.assertIsNone(self.gate.container)
        self.assertFalse(self.gate.private.exists())

    def test_private_directory_not_removed_is_cleanup_failure(self):
        with patch.object(gate_module.shutil, "rmtree"), self.assertRaisesRegex(RuntimeError, "private directory still exists"):
            self.gate.close(successful=True)
        self.assertEqual([event["event"] for event in self.events()], ["cleanup_failed"])

    def test_runtime_failure_still_disposes_container_but_preserves_live_data(self):
        self.gate.process = Mock(pid=123)
        self.gate.container = CONTAINER
        with patch.object(self.gate, "stop", side_effect=RuntimeError("mock runtime did not exit")), \
                patch.object(self.gate, "run", side_effect=[self.result(), self.result(1, err="No such container: " + CONTAINER)]):
            with self.assertRaisesRegex(RuntimeError, "owned cleanup failed"):
                self.gate.close(successful=True)
        self.assertIsNone(self.gate.container)
        self.assertTrue(self.gate.private.exists(), "never delete data of an unverified live process")
        names = [event["event"] for event in self.events()]
        self.assertIn("owned_container_removed", names)
        self.assertIn("cleanup_failed", names)
        self.assertNotIn("cleanup_pass", names)
        self.assertNotIn("CONNECTED_COLONY_PASS", names)

    def test_transport_parser_and_generic_admin_errors_are_not_authorization(self):
        for error in ("operator transport failed", "admin credentials could not connect",
                      "invalid arguments for set_time_scale", "HTTP 500 runtime trap"):
            with self.subTest(error=error), patch.object(self.gate, "run", return_value=self.result(1, err=error)):
                with self.assertRaises(AssertionError):
                    self.gate.call("set_time_scale", 600, user="viewer", reject=True)
        self.assertEqual(self.events(), [])

    def test_specific_semantic_authorization_errors_are_accepted(self):
        for user, reason in (("viewer", "caller lacks the required colony role"),
                             ("operator", "caller lacks the required colony role")):
            with patch.object(self.gate, "run", return_value=self.result(1, err=reason)):
                self.gate.call("set_time_scale", 600, user=user, reject=True)
        self.assertEqual(len(self.events()), 2)

    def test_snapshot_scope_includes_policy_seed_and_physical_world(self):
        expected = {"config", "world_seed", "speed_control", "colony", "tile", "terrain", "colonist",
                    "item_stack", "world_geometry", "terrain_chunk", "terrain_material",
                    "excavation_designation", "work_order", "production_policy", "alert", "event_log"}
        with patch.object(self.gate, "rows", return_value=[]) as rows:
            self.assertEqual(set(self.gate.snapshot()), expected)
        self.assertTrue(all(0 < call.kwargs["timeout"] <= 30 for call in rows.call_args_list))

    def test_snapshot_total_deadline_is_enforced(self):
        with patch.object(gate_module.time, "monotonic", side_effect=[0, 91]), \
                patch.object(self.gate, "rows") as rows:
            with self.assertRaisesRegex(RuntimeError, "exceeded 90 seconds"):
                self.gate.snapshot()
        rows.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
