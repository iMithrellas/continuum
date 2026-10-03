#!/usr/bin/env python3
"""Private actual-Main fresh-2048 visual evidence. No fixture data or client overrides."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]


def require(value, message):
    if not value:
        raise AssertionError(message)


def main():
    native = Path.home() / '.local/share/Continuum/native/spacetimedb/2.10.0'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wasm', type=Path, required=True)
    parser.add_argument('--client', type=Path, default=ROOT / 'client/godot')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--runtime', default=str(native / 'spacetimedb-standalone'))
    parser.add_argument('--cli', default=str(native / 'spacetimedb-cli'))
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--deadline', type=float, default=720)
    args = parser.parse_args()
    require(args.wasm.is_file(), 'WASM missing')
    require(not args.evidence.exists(), 'use a new evidence directory')
    args.evidence.mkdir(parents=True, mode=0o700)
    private = Path(tempfile.mkdtemp(prefix='fresh-visual-', dir='/tmp/opencode'))
    os.chmod(private, 0o700)
    env = dict(os.environ, HOME=str(private / 'home'), XDG_DATA_HOME=str(private / 'home/data'),
               XDG_CONFIG_HOME=str(private / 'home/config'), XDG_CACHE_HOME=str(private / 'home/cache'),
               LIBGL_ALWAYS_SOFTWARE='1', SDL_AUDIODRIVER='dummy')
    env.pop('WAYLAND_DISPLAY', None)
    processes, logs = [], []
    result = {'complete': False, 'screens': [], 'checks': [],
              'wasm_sha256': hashlib.sha256(args.wasm.read_bytes()).hexdigest(),
              'provenance': 'Actual unmodified Main, fresh private production WASM; connected publisher reset observes real generation pipeline.'}
    deadline = time.monotonic() + args.deadline
    counter = 0
    db = 'visual-' + uuid.uuid4().hex[:12]

    def interrupt(_signum, _frame):
        raise RuntimeError('interrupted')

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)

    def budget(maximum=60):
        remaining = deadline - time.monotonic()
        require(remaining > 0, 'overall deadline')
        return min(maximum, remaining)

    def launch(command, log):
        stream = (private / log).open('w')
        logs.append((log, stream))
        process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        processes.append(process)
        return process

    def command(values, timeout=60):
        process = subprocess.Popen(list(map(str, values)), env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        processes.append(process)
        out, err = process.communicate(timeout=budget(timeout))
        require(process.returncode == 0, 'command failed: ' + ' '.join(map(str, values[:2])) + '\n' + err[-2000:])
        return out

    def cli(*values, timeout=60):
        return command([args.cli, '--root-dir', private / 'publisher', *values], timeout)

    def rows(table):
        value = json.loads(cli('sql', '--format', 'json', '-s', host, db, 'SELECT * FROM ' + table))[0]
        names = [field['name']['some'] for field in value['schema']['elements']]
        return [dict(zip(names, row)) for row in value['rows']]

    def call(name, *values):
        return cli('call', '-s', host, '--', db, name, *(json.dumps(value) for value in values))

    def wait(predicate, label, seconds=60):
        end = time.monotonic() + budget(seconds)
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            time.sleep(.1)
        raise AssertionError(label)

    def ui(action='status', **values):
        nonlocal counter
        require(game.poll() is None, 'Main exited')
        counter += 1
        (private / 'command.tmp').write_text(json.dumps(dict(id=counter, action=action, **values)))
        (private / 'command.tmp').replace(private / 'command.json')

        def response():
            path = private / 'response.json'
            if not path.exists():
                return False
            value = json.loads(path.read_text())
            return value if value.get('id') == counter else False

        value = wait(response, 'Main response deadline: ' + action, 45)
        clean = {key: item for key, item in value.items() if key != 'identity'}
        result['last_ui'] = clean
        require(not value['driver_error'], value['driver_error'])
        return value

    def screen(name):
        state = ui('capture', name=name)
        result['screens'].append(name)
        print('CAPTURE', name, state['phase'], state['mode'], state['resident'], flush=True)
        return state

    def healthy():
        require(server.poll() is None, 'owned runtime exited')
        try:
            with urllib.request.urlopen(host + '/v1/ping', timeout=1) as response:
                return response.status == 200
        except OSError:
            return False

    def settled(seconds=60):
        return wait(lambda: (state if state['ready'] and not state['pending'] and not state['loading_error']
                            and state['terrain_pending_samples'] == 0 else False)
                    if (state := ui()) else False, 'Main did not settle', seconds)

    def observe_settled(label, seconds=60):
        started = time.monotonic()
        try:
            state = settled(seconds)
            result.setdefault('loading_observations', []).append(
                {'label': label, 'settled': True, 'seconds': time.monotonic() - started})
            return state
        except AssertionError as error:
            result.setdefault('loading_observations', []).append(
                {'label': label, 'settled': False, 'seconds': time.monotonic() - started,
                 'failure': str(error), 'last_ui': result.get('last_ui')})
            screen(label + '-deadline')
            return None

    try:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        require(port != 3001, 'refuse shared port')
        host = f'http://127.0.0.1:{port}'
        server = launch([args.runtime, 'start', '--listen-addr', f'127.0.0.1:{port}',
                         '--data-dir', str(private / 'data'), '--jwt-pub-key-path', str(private / 'id.pub'),
                         '--jwt-priv-key-path', str(private / 'id'), '--non-interactive'], 'server.log')
        result['runtime'] = {'port': port, 'database': db, 'pid': server.pid}
        wait(healthy, 'runtime startup', 30)
        cli('publish', '--yes', '-s', host, '-b', args.wasm.resolve(), db, timeout=180)
        wait(lambda: rows('world_generation')[0]['ready'], 'initial generation Ready', 60)
        call('set_time_scale', 0)
        project = private / 'client'
        result['client_sha'] = command(['git', '-C', args.client, 'rev-parse', 'HEAD']).strip()
        source_files = [path for folder in ('scripts', 'spacetime_bindings', 'addons/SpacetimeDB', 'shaders')
                        for path in (args.client / folder).rglob('*') if path.suffix in ('.gd', '.gdshader')]
        source_hashes = {str(path.relative_to(args.client)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in source_files}
        shutil.copytree(args.client, project, ignore=shutil.ignore_patterns('.godot', 'build'))
        shutil.copyfile(ROOT / 'client/godot/tools/fresh_world_visual.gd', project / 'tools/fresh_world_visual.gd')
        import_log = command([args.godot, '--headless', '--path', project, '--editor', '--import'], 180)
        (private / 'import.log').write_text(import_log)
        require(all(hashlib.sha256((project / path).read_bytes()).hexdigest() == digest
                    for path, digest in source_hashes.items()), 'disposable import changed production scripts/bindings')
        result['unchanged_production_source_files'] = len(source_hashes)
        read_fd, write_fd = os.pipe()
        xlog = (private / 'xvfb.log').open('w')
        logs.append(('xvfb.log', xlog))
        xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0', '1920x1080x24', '-nolisten', 'tcp'],
                                env=env, pass_fds=(write_fd,), stdout=xlog, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(xvfb)
        os.close(write_fd)
        import select
        require(select.select([read_fd], [], [], budget(15))[0], 'private Xvfb display deadline')
        display = os.read(read_fd, 32).decode().strip()
        os.close(read_fd)
        require(display.isdigit(), 'Xvfb did not provide display')
        env['DISPLAY'] = ':' + display
        result['display'] = env['DISPLAY']
        game = launch([args.godot, '--display-driver', 'x11', '--rendering-method', 'gl_compatibility',
                       '--audio-driver', 'Dummy', '--path', str(project), '--script', 'res://tools/fresh_world_visual.gd',
                       '--', '--gate-dir=' + str(private), '--workspace-file=' + str(private / 'workspace.json'),
                       '--settings-file=' + str(private / 'settings.cfg')], 'client.log')
        screen('00-menu-1280')
        ui('servers')
        screen('01-servers-1280')
        ui('join', host=host, database=db)
        settled(120)
        identity = ui()['identity']
        call('set_operator', identity, True)
        wait(lambda: ui()['operator'], 'normal Operator grant')
        screen('03-initial-ready-centered-1280')
        result['initial_generation'] = rows('world_generation')
        ui('build_view')
        ui('watch', enabled=True)
        call('reset_world_large', 2048, 2048, 1234)
        result['reset_started'] = True
        wait(lambda: (state := ui())['overlay'] and not state['ready'], 'connected reset overlay did not appear', 10)
        early = ui('early_attempt')
        result['early_attempt'] = {key: value for key, value in early.items() if key != 'identity'}
        require(not early['before_attempt']['ready'] and early['before_attempt']['overlay'], 'generation input attempt missed real non-ready window')
        require(not early['pending'] and not rows('building'), 'early input mutated a room')
        wait(lambda: rows('world_generation')[0]['ready'], 'reset generation Ready', 60)
        call('set_time_scale', 0)
        settled(120)
        ui('watch', enabled=False)
        result['fresh_generation'] = rows('world_generation')
        result['starter_colonists'] = rows('colonist')
        screen('04-reset-ready-centered-1280')
        ui('map_only', enabled=True)
        screen('05-starter-near-1280')
        ui('camera', x=1024, y=1024, pixels=8)
        settled()
        screen('06-starter-mid-1280')
        ui('camera', x=1024, y=1024, pixels=32)
        settled()
        ui('build_view')
        screen('07-construction-zones-1280')
        if rows('colony')[0]['wood'] < 20:
            call('set_time_scale', 600)
            wait(lambda: rows('colony')[0]['wood'] >= 20, 'actual haulers did not supply room resources', 120)
            call('set_time_scale', 0)
        result['stored_wood_before_room'] = rows('colony')[0]['wood']
        gen = rows('world_generation')[0]
        ox, oy = gen['starter_x'], gen['starter_y']
        occupied = {(x, y) for row in rows('tile') if row['kind'][0] != 0
                    for x in range(row['x'], row['x'] + row['width'])
                    for y in range(row['y'], row['y'] + row['depth'])}
        site = next((x, y) for y in range(oy, oy + 8) for x in range(ox, ox + 8)
                    if not {(x + dx, y + dy) for dx in range(2) for dy in range(2)} & occupied)
        x, y = site
        ui('camera', x=x + 1, y=y + 1, pixels=32)
        settled()
        result['room_request'] = {k: v for k, v in ui('draw', system='construction', x=x, y=y,
                                  width=2, depth=2, name='08-room-request-pending-1280').items() if k != 'identity'}
        settled()
        result['buildings'] = rows('building')
        result['thermal'] = rows('building_thermal_property')
        require(len(result['buildings']) == 1, 'actual UI room did not create one building')
        ui('draw', system='zones', x=x, y=y, width=2, depth=2, name='09-zone-request-pending-1280')
        settled()
        ui('select', x=x, y=y)
        ui('build_view')
        screen('10-room-storage-inspection-1280')
        ui('map_only', enabled=True)
        for z, name in ((-1, '10b-cut-zminus1-1280'), (15, '10c-cut-z15-1280')):
            ui('cut', z=z)
            settled()
            screen(name)
        ui('cut', z=0)
        settled()
        ui('build_view')
        ui('resize', width=1920, height=1080)
        settled()
        screen('11-room-storage-inspection-1920')
        ui('map_only', enabled=True)
        ui('camera', x=1024, y=1024, pixels=16)
        settled()
        screen('12-starter-landscape-1920')
        ui('cut', z=0)
        settled()
        screen('13-cut-z0-1920')
        ui('cut', z=-1)
        settled()
        screen('14-cut-zminus1-1920')
        ui('cut', z=15)
        settled()
        ui('navigate_capture', x=512, y=512, pixels=16, name='14b-navigation-real-pending-1920')
        settled()
        screen('14c-remote-detail-loaded-1920')
        hover = ui('hover_capture', name='14d-remote-ecology-tooltip-1920')
        result['remote_ecology_tooltip'] = {key: value for key, value in hover.items() if key != 'identity'}
        ui('camera', x=960, y=960, pixels=8)
        observe_settled('15-landscape-mid-1920', 60)
        screen('15-landscape-mid-1920')
        ui('fit')
        screen('16-fit-pending-1920')
        end = time.monotonic() + budget(90)
        fit_started = time.monotonic()
        states = []
        while time.monotonic() < end:
            state = ui()
            states.append({**{k: state[k] for k in ('overview_rows', 'loading_error', 'ready', 'mode', 'terrain_pending_samples')},
                           'seconds': time.monotonic() - fit_started})
            if state['loading_error'] or state['overview_rows'] >= 256:
                break
            time.sleep(.25)
        result['fit_observations'] = states
        result['fit_observation_seconds'] = time.monotonic() - fit_started
        screen('17-fit-bounded-outcome-1920')
        ui('resize', width=1280, height=720)
        screen('18-fit-1280')
        if not ui()['loading_error']:
            try:
                ui('resize', width=1920, height=1080)
                ui('camera', x=x + 1, y=y + 1, pixels=32)
                ui('cut', z=0)
                settled()
                ui('select', x=x, y=y)
                ui('build_view')
                ui('scale', percent=150)
                screen('19-room-storage-1920-scale150')
            except Exception as error:
                result['secondary_scale_error'] = str(error)
        result['complete'] = True
        ui('quit')
    except Exception as error:
        result['failure'] = str(error)
        if 'game' in locals() and game.poll() is None:
            try:
                screen('failure-state')
            except Exception:
                pass
    finally:
        cleanup_errors = []
        for process in reversed(processes):
            try:
                # Completed CLI/import processes were already waited for. Their
                # numeric PID/PGID may now belong to an unrelated process.
                if process.poll() is not None:
                    continue
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
        result['owned_processes_reaped'] = all(process.poll() is not None for process in processes)
        if 'port' in locals():
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    probe.bind(('127.0.0.1', port))
                    result['owned_listener_released'] = True
                except OSError:
                    result['owned_listener_released'] = False
        try:
            for _, stream in logs:
                stream.close()
            for path in private.iterdir():
                if path.suffix in ('.png', '.ndjson', '.log') or (path.suffix == '.json' and path.stem not in ('command', 'response', 'workspace')):
                    if path.suffix == '.png':
                        shutil.copyfile(path, args.evidence / path.name)
                    else:
                        text = path.read_text(errors='replace')
                        text = re.sub(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED_TOKEN]', text)
                        text = re.sub(r'\b[0-9a-fA-F]{64}\b', '[REDACTED_IDENTITY]', text)
                        (args.evidence / path.name).write_text(text)
        except Exception as error:
            result['archive_error'] = type(error).__name__
        finally:
            try:
                shutil.rmtree(private)
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
        result['private_home_removed'] = not private.exists()
        result['cleanup_errors'] = cleanup_errors
        (args.evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result.get(key) for key in ('complete', 'failure', 'owned_processes_reaped', 'owned_listener_released', 'private_home_removed')}), flush=True)
    return 0 if result['complete'] and result.get('owned_listener_released') and result['private_home_removed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
