#!/usr/bin/env python3
"""Offline bootstrap contracts: fake SQL and a virtual clock, no IO or sleeps."""
import json
import contextlib
import io
import unittest
from unittest.mock import patch

from world_ready import (WorldGenerationFailed, WorldReadyError, WorldReadyTimeout,
                         decode_rows, wait_world_ready, world_starter_origin)


def result(names, rows):
    return json.dumps([{"schema": {"elements": [{"name": {"some": name}} for name in names]},
                        "rows": rows}])


def state(phase, ready=False, error=""):
    return dict(phase=[phase, []], ready=ready, error=error, completed_chunks=16,
                total_chunks=4096, completed_units=1024, total_units=4194304)


class FakeSQL:
    def __init__(self, phases=(), *, capability=True, colony=True):
        self.phases = list(phases)
        self.capability = capability
        self.colony = colony
        self.now = 0
        self.calls = []
        self.diagnostics = []

    def sleep(self, seconds):
        self.now += seconds

    def sql(self, statement, budget):
        self.calls.append((statement, budget))
        if statement == "SELECT table_name FROM st_table":
            names = ["colony"] + (["world_generation"] if self.capability else [])
            return result(["table_name"], [[name] for name in names])
        if statement == "SELECT * FROM world_generation WHERE id = 0":
            row = self.phases.pop(0) if len(self.phases) > 1 else (self.phases[0] if self.phases else None)
            return result(list(row), [list(row.values())]) if row is not None else result(["id"], [])
        if statement == "SELECT id FROM colony WHERE id = 0":
            return result(["id"], [[0]] if self.colony else [])
        raise AssertionError("unexpected SQL statement")

    def wait(self, timeout=2):
        return wait_world_ready(self.sql, timeout, 0.25, clock=lambda: self.now,
                                sleep=self.sleep, report=self.diagnostics.append)

    def origin(self, timeout=2):
        return world_starter_origin(self.sql, timeout, 0.25, clock=lambda: self.now,
                                    sleep=self.sleep, report=self.diagnostics.append)


class ReadinessTests(unittest.TestCase):
    def test_starter_origin_is_queried_not_computed_from_width_or_tile_id(self):
        fake = FakeSQL([{**state(5, True), "starter_x": 1012, "starter_y": 777, "width": 2048}])
        self.assertEqual(fake.origin(), (1012, 777))
        self.assertEqual([sql for sql, _ in fake.calls], [
            "SELECT table_name FROM st_table", "SELECT * FROM world_generation WHERE id = 0",
            "SELECT id FROM colony WHERE id = 0"])

    def test_starter_origin_uses_final_ready_row_not_preparing_row(self):
        fake = FakeSQL([{**state(0), "starter_x": 0, "starter_y": 0},
                        {**state(5, True), "starter_x": 1012, "starter_y": 1012}])
        self.assertEqual(fake.origin(), (1012, 1012))
        self.assertEqual(fake.now, 0.25)

    def test_origin_zero_fallback_only_for_initialized_missing_legacy_state(self):
        for capability in (False, True):
            self.assertEqual(FakeSQL(capability=capability).origin(), (0, 0))
            with self.assertRaises(WorldReadyTimeout):
                FakeSQL(capability=capability, colony=False).origin()

    def test_missing_or_invalid_new_origin_is_error_not_legacy_fallback(self):
        for coordinates in ({}, {"starter_x": 1012}, {"starter_x": "1012", "starter_y": 1012},
                            {"starter_x": True, "starter_y": 1012}, {"starter_x": -1, "starter_y": 0}):
            with self.subTest(coordinates=coordinates), self.assertRaisesRegex(WorldReadyError, "starter origin"):
                FakeSQL([{**state(5, True), **coordinates}]).origin()

    def test_failed_error_and_sql_failure_never_produce_zero_origin(self):
        for row, error in ((state(6), WorldGenerationFailed), (state(1, error="bad"), WorldReadyError)):
            with self.assertRaises(error):
                FakeSQL([row]).origin()
        for statement in ("SELECT table_name FROM st_table", "SELECT * FROM world_generation WHERE id = 0",
                          "SELECT id FROM colony WHERE id = 0"):
            fake = FakeSQL([{**state(5, True), "starter_x": 1012, "starter_y": 1012}])
            original = fake.sql

            def sql(query, budget):
                if query == statement:
                    raise RuntimeError("SECRET query error")
                return original(query, budget)

            fake.sql = sql
            with self.assertRaisesRegex(WorldReadyError, "SQL/schema error"):
                fake.origin()

    def test_all_scheduled_phases_wait_even_when_colony_already_exists(self):
        fake = FakeSQL([state(i) for i in range(6)] + [state(5, True)])
        self.assertEqual(fake.wait(), "Ready")
        self.assertEqual(fake.now, 1.5)
        for name in ("Preparing", "Terrain", "Overview", "Validating", "Founding", "Ready"):
            self.assertTrue(any("phase=" + name in message for message in fake.diagnostics))
        self.assertIn("chunks=16/4096 units=1024/4194304", fake.diagnostics[-1])
        self.assertTrue(all(0 < budget <= 2 for _, budget in fake.calls))

    def test_ready_requires_founded_colony(self):
        fake = FakeSQL([state(5, True)], colony=False)
        with self.assertRaisesRegex(WorldReadyTimeout, "founding colony missing"):
            fake.wait()
        self.assertEqual(fake.now, 2)

    def test_initialized_legacy_absent_table_or_absent_row(self):
        for capability in (False, True):
            with self.subTest(capability=capability):
                fake = FakeSQL(capability=capability)
                self.assertEqual(fake.wait(), "Legacy")
                self.assertEqual(fake.now, 0)
                self.assertEqual(fake.calls[0][0], "SELECT table_name FROM st_table")
                if not capability:
                    self.assertFalse(any("FROM world_generation" in sql for sql, _ in fake.calls))

    def test_missing_new_state_on_uninitialized_is_not_ready(self):
        for capability in (False, True):
            fake = FakeSQL(capability=capability, colony=False)
            with self.assertRaisesRegex(WorldReadyTimeout, "missing; colony uninitialized"):
                fake.wait()
            self.assertEqual(fake.now, 2)

    def test_missing_row_can_appear_later(self):
        fake = FakeSQL([None, state(0), state(5, True)], colony=False)
        original = fake.sql

        def sql(statement, budget):
            if statement.startswith("SELECT id") and fake.phases[0] is not None and fake.phases[0]["ready"]:
                fake.colony = True
            return original(statement, budget)

        fake.sql = sql
        self.assertEqual(fake.wait(), "Ready")

    def test_each_pending_phase_times_out_with_last_progress(self):
        for phase in range(6):
            fake = FakeSQL([state(phase)])
            with self.assertRaisesRegex(WorldReadyTimeout, "phase=.*chunks=16/4096"):
                fake.wait(timeout=0.6)
            self.assertEqual(fake.now, 0.6)

    def test_failed_distinct_from_error_and_timeout_even_if_ready_flag_true(self):
        for ready in (False, True):
            fake = FakeSQL([state(6, ready, "failure details")])
            with self.assertRaises(WorldGenerationFailed):
                fake.wait()
            self.assertEqual(fake.now, 0)
        fake = FakeSQL([state(1, error="generation error")])
        with self.assertRaisesRegex(WorldReadyError, "error field is nonempty") as error:
            fake.wait()
        self.assertNotIsInstance(error.exception, WorldGenerationFailed)
        self.assertNotIsInstance(error.exception, WorldReadyTimeout)

    def test_contradictory_and_malformed_generation_is_error_not_legacy(self):
        malformed = [state(1, True), {**state(0), "phase": [99, []]},
                     {**state(0), "phase": "Preparing"}, {**state(0), "ready": "true"},
                     {**state(0), "total_chunks": -1}, {**state(0), "error": None}, {}]
        for row in malformed:
            with self.subTest(row=row), self.assertRaises(WorldReadyError) as error:
                FakeSQL([row]).wait()
            self.assertNotIsInstance(error.exception, WorldReadyTimeout)

    def test_query_errors_at_every_stage_are_never_legacy_or_secret_leaks(self):
        for failing_statement in ("SELECT table_name FROM st_table",
                                  "SELECT * FROM world_generation WHERE id = 0",
                                  "SELECT id FROM colony WHERE id = 0"):
            fake = FakeSQL([state(5, True)])
            original = fake.sql

            def sql(statement, budget):
                if statement == failing_statement:
                    raise RuntimeError("SECRET permission/network/syntax failure")
                return original(statement, budget)

            fake.sql = sql
            with self.assertRaisesRegex(WorldReadyError, "SQL/schema error") as error:
                fake.wait()
            self.assertNotIn("SECRET", str(error.exception))

    def test_slow_query_deadline_never_reports_ready(self):
        fake = FakeSQL([state(5, True)])
        original = fake.sql

        def sql(statement, budget):
            fake.now += budget
            return original(statement, budget)

        fake.sql = sql
        with self.assertRaises(WorldReadyTimeout):
            fake.wait()

    def test_malformed_catalog_and_missing_colony_capability_fail(self):
        for raw in ("not JSON", result(["table_name"], [[None]]),
                    result(["table_name"], [["world_generation"]]), "[]"):
            with self.assertRaises(WorldReadyError):
                wait_world_ready(lambda *_: raw)

    def test_cli_schema_decoder(self):
        self.assertEqual(decode_rows(result(["id", "ready"], [[0, True]])), [{"id": 0, "ready": True}])
        with self.assertRaises(ValueError):
            decode_rows(result(["id"], [[0, 1]]))

    def test_invalid_deadlines_and_poll_intervals_do_not_query(self):
        for timeout, poll in ((0, 1), (-1, 1), (float("inf"), 1), (1, 0), (1, float("nan"))):
            with self.assertRaises(ValueError):
                wait_world_ready(lambda *_: self.fail("must not query"), timeout, poll)

    def test_main_shell_prefix_and_failure_status(self):
        import world_ready
        for error in (None, WorldGenerationFailed("world generation Failed"), WorldReadyTimeout("deadline")):
            with patch.object(world_ready.sys, "argv", ["world_ready.py", "--timeout", "12", "--", "docker", "exec", "owned", "spacetime", "sql"]), \
                    patch.object(world_ready, "wait_world_ready", side_effect=error) as wait, \
                    patch.object(world_ready.sys, "stderr"):
                self.assertEqual(world_ready.main(), 0 if error is None else 1)
                self.assertEqual(wait.call_args.args[1], 12)

    def test_shell_origin_mode_prints_only_two_authoritative_coordinates(self):
        import world_ready
        output = io.StringIO()
        with patch.object(world_ready.sys, "argv", ["world_ready.py", "--starter-origin", "--", "owned-cli", "sql"]), \
                patch.object(world_ready, "world_starter_origin", return_value=(1012, 777)) as origin, \
                patch.object(world_ready, "wait_world_ready") as ready, contextlib.redirect_stdout(output):
            self.assertEqual(world_ready.main(), 0)
        self.assertEqual(output.getvalue(), "1012 777\n")
        origin.assert_called_once()
        ready.assert_not_called()

    def test_shell_sql_appends_statement_and_bounds_owned_subprocess(self):
        import world_ready
        from unittest.mock import Mock
        import subprocess
        process = Mock(pid=123, returncode=0)
        process.communicate.return_value = (result(["id"], [[0]]), "")

        def wait(sql, *_args, **_kwargs):
            self.assertEqual(decode_rows(sql("SELECT id FROM colony", 0.75)), [{"id": 0}])

        with patch.object(world_ready.sys, "argv", ["world_ready.py", "--", "owned-cli", "sql"]), \
                patch.object(world_ready, "wait_world_ready", side_effect=wait), \
                patch.object(world_ready.subprocess, "Popen", return_value=process) as spawn:
            self.assertEqual(world_ready.main(), 0)
        self.assertEqual(spawn.call_args.args[0], ["owned-cli", "sql", "SELECT id FROM colony"])
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        process.communicate.assert_called_once_with(timeout=0.75)

        process.communicate.side_effect = [subprocess.TimeoutExpired("SECRET", 0.75), ("", "")]

        def timed_out_wait(sql, *_args, **_kwargs):
            with self.assertRaises(subprocess.TimeoutExpired):
                sql("SELECT id FROM colony", 0.75)

        with patch.object(world_ready.sys, "argv", ["world_ready.py", "--", "owned-cli", "sql"]), \
                patch.object(world_ready, "wait_world_ready", side_effect=timed_out_wait), \
                patch.object(world_ready.subprocess, "Popen", return_value=process), \
                patch.object(world_ready.os, "killpg") as kill:
            self.assertEqual(world_ready.main(), 0)
        kill.assert_called_once_with(123, world_ready.signal.SIGKILL)
        self.assertEqual(process.communicate.call_args.kwargs, {"timeout": 2})


if __name__ == "__main__":
    unittest.main()
