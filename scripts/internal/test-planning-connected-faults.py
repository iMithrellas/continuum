#!/usr/bin/env python3
"""Externally supervised teardown faults, using an actual owned native runtime.

Faults replace only filesystem reporting/cleanup and an import executable. They
never replace gameplay, client dispatch, schema, reducer responses or SQL data.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def child(case, record, arguments):
    sys.path.insert(0, str(HERE))
    spec = importlib.util.spec_from_file_location('planning_gate', HERE / 'test-planning-connected.py')
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    real_popen = subprocess.Popen
    real_copytree = gate.shutil.copytree
    real_write = Path.write_text
    real_killpg = os.killpg
    real_cleanup = gate.tempfile.TemporaryDirectory.cleanup
    injected = set()

    def note(value):
        with record.open('a') as output:
            output.write(json.dumps(value) + '\n')

    def popen(command, **options):
        process = real_popen(command, **options)
        note({'pid': process.pid, 'start': proc_start(process.pid),
              'private': str(Path(options['env']['HOME']).parent),
              'port': int(command[command.index('--listen-addr') + 1].rsplit(':', 1)[1])
              if '--listen-addr' in command else None})
        return process

    def copytree(source, target, *args, **kwargs):
        if Path(target).name == 'candidate-bindings' and case in ('archive', 'combined'):
            note({'injected': 'bindings_archive'})
            raise OSError('unusable secret-free archive fault')
        return real_copytree(source, target, *args, **kwargs)

    def write(path, *args, **kwargs):
        if ((path.name == 'result.json' and case in ('result', 'combined'))
                or (path.name == 'failure-result.json' and case == 'combined')):
            note({'injected': 'result_write' if path.name == 'result.json' else 'failure_result_write'})
            raise OSError('result writer fault')
        if path.name == 'server.log' and case == 'combined':
            note({'injected': 'log_archive'})
            raise OSError('log writer fault')
        return real_write(path, *args, **kwargs)

    def killpg(pid, signum):
        if case == 'terminate' and signum == signal.SIGTERM and 'terminate' not in injected:
            injected.add('terminate')
            note({'injected': 'terminate'})
            raise PermissionError('first group terminate fault')
        return real_killpg(pid, signum)

    def cleanup(temporary):
        if case == 'private-cleanup':
            note({'injected': 'private_cleanup'})
            raise OSError('private cleanup method fault')
        return real_cleanup(temporary)

    gate.subprocess.Popen = popen
    gate.shutil.copytree = copytree
    Path.write_text = write
    gate.os.killpg = killpg
    gate.tempfile.TemporaryDirectory.cleanup = cleanup
    sys.argv = ['test-planning-connected.py', *arguments]
    return gate.main()


def proc_start(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None


def alive_owned(entry):
    return entry.get('start') is not None and proc_start(entry['pid']) == entry['start']


def owned_group_members(resources):
    # Detect descendants even if their launcher/group leader has exited. A live
    # process holds its session/group ID, preventing reuse while children remain.
    sessions = {entry['pid'] for entry in resources if entry.get('start') is not None
                and proc_start(entry['pid']) in (None, entry['start'])}
    found = []
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = path.read_text().rsplit(')', 1)[1].split()
            if int(fields[3]) in sessions:
                found.append({'pid': int(path.parent.name), 'start': fields[19], 'group': int(fields[2])})
        except (OSError, ValueError, IndexError):
            continue
    return found


def recovery(runner, record):
    """Independent bounded disposal, even if supervisor reporting is interrupted."""
    if runner and runner.poll() is None:
        os.killpg(runner.pid, signal.SIGTERM)
        try:
            runner.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(runner.pid, signal.SIGKILL)
            runner.wait(timeout=5)
    entries = [json.loads(line) for line in record.read_text().splitlines()] if record and record.exists() else []
    resources = [entry for entry in entries if 'pid' in entry]
    for member in owned_group_members(resources):
        if alive_owned(member):
            try:
                os.killpg(member['group'], signal.SIGKILL)
            except ProcessLookupError:
                pass
    end = time.monotonic() + 3
    while owned_group_members(resources) and time.monotonic() < end:
        time.sleep(0.05)
    for entry in resources:
        private = Path(entry['private'])
        if private.parent == Path('/tmp/opencode') and private.name.startswith('planning-connected-') and private.exists():
            shutil.rmtree(private)


def supervise(args):
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt('fault supervisor interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    args.evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    verdicts = []
    runner = None
    record = None
    try:
        return supervise_cases(args, verdicts)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        recovery(getattr(args, '_runner', runner), getattr(args, '_record', record))


def supervise_cases(args, verdicts):
    for case in ('missing-layout', 'archive', 'result', 'terminate', 'private-cleanup', 'combined'):
        case_dir = args.evidence / case
        case_dir.mkdir(mode=0o700)
        record = case_dir / 'ownership.jsonl'
        args._record = record
        with tempfile.TemporaryDirectory(prefix='planning-fault-input-', dir='/tmp/opencode') as temporary:
            command = [sys.executable, str(Path(__file__).resolve()), '--child', case,
                       '--record', str(record), '--', '--wasm', str(args.wasm.resolve()),
                       '--client', temporary, '--godot', '/bin/false', '--deadline', '120',
                       '--evidence', str(case_dir / 'gate')]
            for option in ('cli', 'runtime'):
                value = getattr(args, option)
                if value:
                    command += ['--' + option, value]
            with (case_dir / 'runner.log').open('w') as log:
                runner = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                args._runner = runner
                timed_out = False
                try:
                    runner.wait(timeout=150)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(runner.pid, signal.SIGKILL)
                    runner.wait(timeout=5)
            entries = [json.loads(line) for line in record.read_text().splitlines()] if record.exists() else []
            resources = [entry for entry in entries if 'pid' in entry]
            runtime = next((entry for entry in resources if entry['port'] is not None), None)
            # Observe independently before recovery; recovery can never turn a
            # leaked-runtime case into PASS. PID reuse is guarded by start time.
            end = time.monotonic() + 3
            while owned_group_members(resources) and time.monotonic() < end:
                time.sleep(0.05)
            orphan_members = owned_group_members(resources)
            orphans = [entry['pid'] for entry in orphan_members]
            released = False
            if runtime:
                with socket.socket() as probe:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    try:
                        probe.bind(('127.0.0.1', runtime['port']))
                        released = True
                    except OSError:
                        pass
            home_removed = bool(runtime and not Path(runtime['private']).exists())
            summaries = []
            for line in (case_dir / 'runner.log').read_text().splitlines():
                try:
                    value = json.loads(line)
                    if isinstance(value, dict) and 'checks' in value:
                        summaries.append(value)
                except ValueError:
                    pass
            summary = summaries[-1] if summaries else {}
            stages = {error['stage'] for error in summary.get('finalization_errors', [])}
            expected = {'missing-layout': {'bindings_archive'}, 'archive': {'bindings_archive'},
                        'result': {'bindings_archive', 'result_write'},
                        'terminate': {'bindings_archive', 'terminate'},
                        'private-cleanup': {'bindings_archive', 'private_cleanup'},
                        'combined': {'bindings_archive', 'log_archive', 'result_write', 'failure_result_write'}}[case]
            passed = (not timed_out and runner.returncode == 1 and bool(resources) and not orphans
                      and released and home_removed and summary.get('pass') is False
                      and summary.get('failure') == 'FileNotFoundError'
                      and expected <= stages and summary.get('owned_processes_reaped') is True
                      and summary.get('owned_listener_released') is True
                      and summary.get('private_home_removed') is True)
            result = dict(case=case, pass_=passed, orphan_pids=orphans, listener_released=released,
                          private_home_removed=home_removed, timed_out=timed_out,
                          primary_failure=summary.get('failure'), stages=sorted(stages))
            recovery(runner, record)
            (case_dir / 'supervisor-result.json').write_text(json.dumps(result, indent=2) + '\n')
            verdicts.append(result)
            print(json.dumps(result), flush=True)
    (args.evidence / 'result.json').write_text(json.dumps(verdicts, indent=2) + '\n')
    return 0 if all(result['pass_'] for result in verdicts) else 1


if __name__ == '__main__':
    if '--child' in sys.argv:
        separator = sys.argv.index('--')
        child_args = sys.argv[1:separator]
        case = child_args[child_args.index('--child') + 1]
        record = Path(child_args[child_args.index('--record') + 1])
        raise SystemExit(child(case, record, sys.argv[separator + 1:]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wasm', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--cli')
    parser.add_argument('--runtime')
    raise SystemExit(supervise(parser.parse_args()))
