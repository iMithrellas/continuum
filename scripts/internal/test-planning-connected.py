#!/usr/bin/env python3
"""Real Main acceptance against candidate WASM, never an existing endpoint.

Copies the passed client unchanged into an owned private home. No generation,
cache, permission, reducer, map intent, or planning row overrides are installed.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

sys.dont_write_bytecode = True
from world_ready import world_starter_origin

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def finish_owned(processes, logs, temp, private, evidence, destination, project=None, port=None):
    """Teardown precedes artifacts; every failure is isolated and secret-free.

    A diagnostic write must never control whether we kill/reap a child. Keep the
    primary scenario failure intact and report secondary failures by stage/type.
    """
    errors = evidence.setdefault('finalization_errors', [])

    def attempt(stage, operation):
        try:
            return operation()
        except BaseException as error:
            errors.append({'stage': stage, 'type': type(error).__name__})
            return None

    previous = {}
    for signum in (signal.SIGTERM, signal.SIGINT):
        previous[signum] = signal.signal(signum, signal.SIG_IGN)
    try:
        for process in reversed(processes):
            if process.poll() is not None:
                continue
            attempt('terminate', lambda: os.killpg(process.pid, signal.SIGTERM))
            attempt('reap_after_terminate', lambda: process.wait(timeout=2))
            if process.poll() is None:
                attempt('kill', lambda: os.killpg(process.pid, signal.SIGKILL))
                attempt('reap_after_kill', lambda: process.wait(timeout=5))
            if process.poll() is None:
                attempt('kill_retry', lambda: os.killpg(process.pid, signal.SIGKILL))
                attempt('reap_retry', lambda: process.wait(timeout=5))
        evidence['owned_processes_reaped'] = all(process.poll() is not None for process in processes)
        evidence['owned_listener_released'] = False
        if port is not None:
            def listener_released():
                with socket.socket() as probe:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    probe.bind(('127.0.0.1', port))
                evidence['owned_listener_released'] = True
            attempt('listener_proof', listener_released)
        if project is not None:
            attempt('bindings_archive', lambda: shutil.copytree(
                project / 'spacetime_bindings', destination / 'candidate-bindings'))
        import re
        for name, stream in logs:
            attempt('log_close', stream.close)
            def archive_log():
                text = (private / name).read_text(errors='replace')
                text = re.sub(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED_TOKEN]', text)
                text = re.sub(r'\b[0-9a-fA-F]{64}\b', '[REDACTED_IDENTITY]', text)
                (destination / name).write_text(text)
            attempt('log_archive', archive_log)
        attempt('private_cleanup', temp.cleanup)
        if private.exists():
            attempt('private_cleanup_retry', temp.cleanup)
        if private.exists():
            attempt('private_cleanup_fallback', lambda: shutil.rmtree(private))
        evidence['private_home_removed'] = not private.exists()
        evidence['pass'] = (evidence['pass'] and not errors and evidence['owned_processes_reaped']
                            and evidence['owned_listener_released'] and evidence['private_home_removed'])
        attempt('result_write', lambda: (destination / 'result.json').write_text(
            json.dumps(evidence, indent=2) + '\n'))
        if errors:
            evidence['pass'] = False
            attempt('failure_result_write', lambda: (destination / 'failure-result.json').write_text(
                json.dumps(evidence, indent=2) + '\n'))
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main():
    native = Path.home() / '.local/share/Continuum/native/spacetimedb/2.10.0'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wasm', type=Path, required=True)
    parser.add_argument('--client', type=Path, default=ROOT / 'client/godot')
    parser.add_argument('--cli', default=os.environ.get('SPACETIME_CLI', str(native / 'spacetimedb-cli')))
    parser.add_argument('--runtime', default=os.environ.get('SPACETIME_RUNTIME', str(native / 'spacetimedb-standalone')))
    parser.add_argument('--godot', default=os.environ.get('GODOT', 'godot'))
    parser.add_argument('--deadline', type=float, default=900)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    def interrupted(_signum, _frame):
        raise RuntimeError('gate interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    require(args.wasm.is_file(), 'candidate WASM missing')
    require(not args.evidence.exists(), 'evidence directory must be new')
    args.evidence.mkdir(parents=True, mode=0o700)
    deadline = time.monotonic() + args.deadline
    processes = []
    logs = []
    evidence = {'pass': False, 'checks': [], 'wasm_sha256': hashlib.sha256(args.wasm.read_bytes()).hexdigest()}
    temp = tempfile.TemporaryDirectory(prefix='planning-connected-', dir='/tmp/opencode')
    private = Path(temp.name)
    os.chmod(private, 0o700)
    env = dict(os.environ, HOME=str(private / 'home'), XDG_DATA_HOME=str(private / 'home/data'),
               XDG_CONFIG_HOME=str(private / 'home/config'), XDG_CACHE_HOME=str(private / 'home/cache'))
    db = 'planning-' + uuid.uuid4().hex[:16]
    counter = 0

    def budget(maximum=60):
        remaining = deadline - time.monotonic()
        require(remaining > 0, 'overall deadline exceeded')
        return min(maximum, remaining)

    def launch(command, log):
        stream = (private / log).open('w')
        logs.append((log, stream))
        process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        processes.append(process)
        return process

    def command(values, timeout=60):
        process = subprocess.Popen(values, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        processes.append(process)
        try:
            out, err = process.communicate(timeout=budget(timeout))
        except subprocess.TimeoutExpired:
            raise AssertionError('bounded command timeout') from None
        require(process.returncode == 0, 'private CLI/import command failed')
        return out

    def cli(*values, timeout=60):
        return command([args.cli, '--root-dir', str(private / 'publisher'), *map(str, values)], timeout)

    def sql(statement, timeout=60):
        return cli('sql', '--format', 'json', '-s', host, db, statement, timeout=timeout)

    def rows(table):
        result = json.loads(sql('SELECT * FROM ' + table))[0]
        names = [element['name']['some'] for element in result['schema']['elements']]
        return sorted([dict(zip(names, row)) for row in result['rows']], key=lambda row: json.dumps(row, sort_keys=True))

    def call(name, *values):
        cli('call', '-s', host, '--', db, name, *(json.dumps(value) for value in values))

    def wait(predicate, message, seconds=60):
        end = time.monotonic() + budget(seconds)
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.1)
        raise AssertionError(message)

    def ui(action='status', **values):
        nonlocal counter
        require(game.poll() is None, 'real Main process exited')
        counter += 1
        target = private / 'command.json'
        staging = private / 'command.tmp'
        staging.write_text(json.dumps(dict(id=counter, action=action, **values)))
        staging.replace(target)

        def response():
            result = private / 'response.json'
            if not result.exists():
                return False
            return json.loads(result.read_text()).get('id') == counter
        wait(response, 'Main did not answer: ' + action, 30)
        response = json.loads((private / 'response.json').read_text())
        recorded = dict(response)
        recorded.pop('identity', None)
        evidence['last_ui'] = dict(action=action, **recorded)
        require(not response.get('driver_error'), 'real input driver: ' + response.get('driver_error', ''))
        return response

    def settled():
        wait(lambda: not ui()['pending'], 'real reducer request did not settle')
        return ui()

    def accepted():
        result = settled()
        require(result['feedback'] == 'Accepted', 'real planning operation did not receive successful outcome')
        return result

    def check(name):
        evidence['checks'].append(name)
        print('PASS ' + name, flush=True)

    def state():
        return {name: rows(name) for name in ('colony', 'building', 'building_thermal_property', 'tile')}

    def wood():
        return rows('colony')[0]['wood']

    def debit(cost):
        return math.isclose(wood(), initial_wood - cost, rel_tol=0, abs_tol=0.0001)

    def tile(x, y):
        return next(row for row in rows('tile') if (row['x'], row['y'], row['z']) == (x, y, 0))

    def role_is(identity, ordinal):
        return any(row['identity'][0].removeprefix('0x') == identity and row['role'][0] == ordinal
                   for row in rows('membership'))

    def room_is(row, x, y):
        require(row == dict(id=row['id'], kind=[0, []], x=x, y=y, z=0,
                            width=2, depth=2, clearance_height=4, wood_cost=20.0),
                'authoritative full room metadata wrong')

    def room_delta(before, after, x, y):
        require(after['tile'] == before['tile'], 'room-only creation implicitly changed usage')
        ids = {row['id'] for row in before['building']}
        added = [row for row in after['building'] if row['id'] not in ids]
        require(len(added) == 1, 'room creation did not add exactly one building')
        room_is(added[0], x, y)
        require([row for row in after['building'] if row['id'] in ids] == before['building'], 'room creation modified unrelated buildings')
        expected = before['building_thermal_property'] + [{
            'building_id': added[0]['id'], 'thermal_resistance_m_2_k_per_w': 2.0}]
        require(after['building_thermal_property'] == sorted(expected, key=lambda row: json.dumps(row, sort_keys=True)),
                'room creation thermal delta wrong')
        require(len(before['colony']) == len(after['colony']) == 1, 'colony authority missing')
        old, new = before['colony'][0], after['colony'][0]
        require({key: value for key, value in old.items() if key != 'wood'}
                == {key: value for key, value in new.items() if key != 'wood'}, 'room creation changed non-wood colony resources')
        require(math.isclose(new['wood'], old['wood'] - 20, rel_tol=0, abs_tol=0.0001), 'room-only step did not debit exactly 20 wood')

    def zone_delta(before, after, x, y):
        cells = {(x + dx, y + dy, 0) for dx in range(2) for dy in range(2)}
        at = lambda row: (row['x'], row['y'], row['z'])
        outside = lambda snapshot: [row for row in snapshot['tile'] if at(row) not in cells]
        require(outside(before) == outside(after), 'zone creation changed unrelated usage rows')
        created = [row for row in after['tile'] if at(row) in cells]
        require(len(created) == 4 and {at(row) for row in created} == cells, 'zone-only step did not create four Storage cells')
        old = {at(row): row for row in before['tile'] if at(row) in cells}
        for row in created:
            require(row == dict(id=row['id'], x=row['x'], y=row['y'], z=0, kind=[3, []],
                                enabled=True, width=1, depth=1, clearance_height=4), 'Storage metadata wrong')
            if at(row) in old:
                require(row['id'] == old[at(row)]['id'], 'zone creation changed durable anchor ID')
        require(all(before[name] == after[name] for name in ('colony', 'building', 'building_thermal_property')),
                'free zone creation changed resources, buildings or thermal properties')

    def clear_delta(before, after, tile_id):
        expected = [dict(row, kind=[0, []], enabled=True) if row['id'] == tile_id else row for row in before['tile']]
        require(after['tile'] == expected, 'clear changed more than one exact usage row')
        require(all(before[name] == after[name] for name in ('colony', 'building', 'building_thermal_property')),
                'clear changed room, thermal property or stored goods')

    def demolish_delta(before, after, building_id):
        require(after['tile'] == before['tile'] and after['colony'] == before['colony'], 'demolition changed usage or goods')
        require(after['building'] == [row for row in before['building'] if row['id'] != building_id], 'demolition removed wrong room rows')
        require(after['building_thermal_property'] == [row for row in before['building_thermal_property'] if row['building_id'] != building_id],
                'demolition removed wrong thermal rows')

    try:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        require(port != 3001, 'refuse live client port')
        host = f'http://127.0.0.1:{port}'
        server = launch([args.runtime, 'start', '--listen-addr', f'127.0.0.1:{port}',
                         '--data-dir', str(private / 'data'), '--jwt-pub-key-path', str(private / 'id.pub'),
                         '--jwt-priv-key-path', str(private / 'id'), '--non-interactive'], 'server.log')
        evidence['runtime'] = {'pid': server.pid, 'port': port, 'database': db, 'private_data': True}

        def healthy():
            require(server.poll() is None, 'owned native runtime exited')
            try:
                with urllib.request.urlopen(host + '/v1/ping', timeout=1) as response:
                    return response.status == 200
            except OSError:
                return False
        wait(healthy, 'owned runtime startup timeout', 30)
        cli('publish', '--yes', '-s', host, '-b', args.wasm.resolve(), db, timeout=180)
        ox, oy = world_starter_origin(lambda statement, remaining: sql(statement, min(60, remaining)),
                                     timeout=budget(600), report=lambda text: print(text, flush=True))
        call('set_time_scale', 0)
        evidence['founded_wood'] = wood()
        # Legacy founding goods live in real stacks rather than colony storage.
        # Let the real scheduler/haulers supply storage; never mint goods via SQL.
        if wood() < 40:
            call('set_time_scale', 600)
            wait(lambda: wood() >= 40, 'normal starter workers cannot supply two 2x2 rooms', 120)
            call('set_time_scale', 0)
        initial_wood = wood()
        evidence['opening_stored_wood'] = initial_wood
        tiles = rows('tile')
        occupied = {(x, y) for row in tiles if row['kind'][0] != 0
                    for x in range(row['x'], row['x'] + row['width'])
                    for y in range(row['y'], row['y'] + row['depth'])}
        sites = []
        for y in range(oy, oy + 4):
            for x in range(ox, ox + 8):
                cells = {(x + dx, y + dy) for dx in range(2) for dy in range(2)}
                if not cells & occupied:
                    sites.append((x, y))
                    occupied |= cells
                if len(sites) == 2:
                    break
            if len(sites) == 2:
                break
        require(len(sites) == 2, 'two blank starter sites missing')
        project = private / 'client'
        shutil.copytree(args.client, project, ignore=shutil.ignore_patterns('.godot'))
        shutil.copyfile(ROOT / 'client/godot/tools/planning_connected_gate.gd', project / 'tools/planning_connected_gate.gd')
        command([args.godot, '--headless', '--path', str(project), '--editor', '--import'], timeout=180)
        # First import establishes addon class names. Delete only OUR disposable
        # generated directory before generating, so removed schema types cannot
        # keep registering competing table decoders (old OwnRole vs Membership).
        shutil.rmtree(project / 'spacetime_bindings/schema')
        # Generate from the actual private candidate schema, only in this disposable
        # copy. The checked-in plugin cache can otherwise regenerate stale OwnRole.
        command([args.godot, '--headless', '--path', str(project), '--script',
                 'res://tools/generate_bindings.gd', '--', '--stdb-host=' + host,
                 '--stdb-db=' + db], timeout=120)
        command([args.godot, '--headless', '--path', str(project), '--editor', '--import'], timeout=180)
        game = launch([args.godot, '--headless', '--path', str(project), '--script',
                       'res://tools/planning_connected_gate.gd', '--', '--gate-dir=' + str(private),
                       '--stdb-host=' + host, '--stdb-db=' + db,
                       '--workspace-file=' + str(private / 'workspace.json'),
                       '--settings-file=' + str(private / 'settings.cfg')], 'client.log')
        wait(lambda: ui()['ready'] and ui()['snapshot'], 'Main not naturally playable', 120)
        identity = ui()['identity']
        require(len(identity) == 64, 'normal client identity missing')
        call('set_operator', identity, True)
        require(role_is(identity, 1), 'publisher did not assign actual normal client identity Operator')
        wait(lambda: ui()['operator'], 'Operator grant did not stream')
        for x, y in sites:
            wait(lambda: ui('detail', x=x, y=y)['resident'], 'exact resident supported detail missing', 90)
        check('public Ready + real Main playable + resident physical detail')
        x, y = sites[0]
        room_only_before = state()
        require(not room_only_before['building'] and not room_only_before['building_thermal_property'], 'fresh fixture already contains rooms')
        result = ui('draw', system='construction', x=x, y=y, width=2, depth=2, double=True)
        require(result['observed_pending'] and 'pending' in result['pending_feedback'].lower(), 'real pending feedback absent')
        accepted()
        room_delta(room_only_before, state(), x, y)
        buildings = rows('building')
        require(len(buildings) == 1 and debit(20), 'busy double gesture duplicated or wrong room debit')
        first = buildings[0]
        room_is(first, x, y)
        require(rows('building_thermal_property') == [{'building_id': first['id'], 'thermal_resistance_m_2_k_per_w': 2.0}], 'actual canonical thermal property wrong')
        check('Operator 2x2 room / 20 wood / R2 / busy double gesture')
        before = state()
        ui('draw', system='construction', x=x, y=y, width=2, depth=2)
        rejected = settled()
        require('rejected' in rejected['feedback'].lower(), 'late server rejection not shown')
        require('building volumes overlap' in rejected['feedback_detail'], 'late denial was not real room overlap validation')
        require(state() == before, 'server-denied overlap changed authoritative state')
        check('late server overlap deny surfaced and atomic')
        before = state()
        ui('draw', system='zones', x=x, y=y, width=2, depth=2)
        accepted()
        zone_delta(before, state(), x, y)
        require(debit(20), 'Storage was not free')
        require(all(tile(x + dx, y + dy)['kind'][0] == 3 for dx in range(2) for dy in range(2)), 'Storage overlap missing')
        inspection = ui('select', x=x, y=y)
        require('R 2.0' in inspection['room'] and 'Storage' in inspection['usage'], 'actual room R2 and Storage inspection absent (canonical m_2 field required)')
        check('free overlapping Storage + actual room R2 and usage inspection')
        before = state()
        cleared_id = tile(x, y)['id']
        ui('remove', system='zones')
        accepted()
        clear_delta(before, state(), cleared_id)
        require(rows('building') == buildings and tile(x, y)['kind'][0] == 0, 'clear usage removed room or failed')
        require(all(tile(x + dx, y + dy)['kind'][0] == 3 for dx, dy in ((1, 0), (0, 1), (1, 1))), 'clear removed other zones')
        before = state()
        ui('remove', system='construction')
        accepted()
        demolish_delta(before, state(), first['id'])
        require(not rows('building') and tile(x + 1, y)['kind'][0] == 3 and debit(20), 'demolition removed zone or refunded')
        check('clear one usage retains room and other zones / demolish retains usage')
        x, y = sites[1]
        zone_only_before = state()
        require(not zone_only_before['building'] and not zone_only_before['building_thermal_property'], 'zone-only fixture still contains room/property rows')
        ui('draw', system='zones', x=x, y=y, width=2, depth=2)
        accepted()
        zone_delta(zone_only_before, state(), x, y)
        require(debit(20), 'reverse-order zone charged wood')
        before = state()
        ui('draw', system='construction', x=x, y=y, width=2, depth=2)
        accepted()
        room_delta(before, state(), x, y)
        require(len(rows('building')) == 1 and debit(40), 'reverse-order room wrong debit')
        second = rows('building')[0]
        room_is(second, x, y)
        require(rows('building_thermal_property') == [{'building_id': second['id'], 'thermal_resistance_m_2_k_per_w': 2.0}], 'reverse-order exact thermal property wrong')
        inspection = ui('select', x=x, y=y)
        require('R 2.0' in inspection['room'] and 'Storage' in inspection['usage'], 'reverse-order inspection absent')
        check('reverse creation order affordable from actual initial wood')
        call('set_operator', identity, False)
        require(role_is(identity, 2), 'publisher did not revoke actual normal identity to Viewer')
        wait(lambda: not ui()['operator'], 'Viewer revocation not observed')
        before = state()
        ui('remove', system='construction')
        ui('draw', system='zones', x=x, y=y, width=1, depth=1)
        denial = ui('wire_denials', x=x, y=y, tile_id=tile(x, y)['id'], building_id=rows('building')[0]['id'])
        require(denial['errors'] == ['caller lacks the required colony role'] * 4, 'real generated reducer denial is not exact role rejection')
        require(state() == before, 'Viewer mutated authoritative data')
        check('Viewer UI blocked and four real generated wire reducers role-denied')
        call('set_operator', identity, True)
        wait(lambda: ui()['operator'], 'restored Operator not observed')
        ui('select', x=x, y=y)
        before = state()
        cleared_id = tile(x, y)['id']
        ui('remove', system='zones')
        accepted()
        clear_delta(before, state(), cleared_id)
        require(tile(x, y)['kind'][0] == 0 and len(rows('building')) == 1, 'restored Operator failed')
        check('restored Operator actual mutation works')
        before = state()
        ui('remove', system='construction')
        accepted()
        demolish_delta(before, state(), second['id'])
        before = state()
        ui('disconnect')
        ui('remove', system='construction')
        disconnected = ui()
        require(state() == before and not disconnected['ready'] and not disconnected['operator'], 'disconnected client mutated or retained actionable authority')
        evidence['disconnected_snapshot_retained'] = disconnected['snapshot']
        check('disconnected Main denies mutation')
        ui('quit')
        require('SCRIPT ERROR:' not in (private / 'client.log').read_text(), 'Main emitted script error during connected gate')
        evidence['pass'] = True
    except Exception as error:
        evidence['failure'] = str(error) if isinstance(error, AssertionError) else type(error).__name__
    finally:
        finish_owned(processes, logs, temp, private, evidence, args.evidence,
                     project=locals().get('project'), port=locals().get('port'))
    print(json.dumps(evidence, sort_keys=True))
    return 0 if (evidence['pass'] and evidence['owned_processes_reaped']
                 and evidence.get('owned_listener_released') and evidence['private_home_removed']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
