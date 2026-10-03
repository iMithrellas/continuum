#!/usr/bin/env python3
"""Own a private 2.10 server; never deploy to/reset the shared backend.

Fresh-world proof is the default. Optional CONTINUUM_BASELINE_WASM checks an upgrade.
Evidence stays in target.
Set CONTINUUM_GENERATION_PROBE_WASM for the optional private fault-injection gate.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'backend/spacetimedb/target'
NATIVE = Path.home() / '.local/share/Continuum/native/spacetimedb/2.10.0'
CLI = os.environ.get('SPACETIME_CLI', str(NATIVE / 'spacetimedb-cli'))
RUNTIME = os.environ.get('SPACETIME_RUNTIME', str(NATIVE / 'spacetimedb-standalone'))
BASELINE = os.environ.get('CONTINUUM_BASELINE_WASM')
WASM = TARGET / 'wasm32-unknown-unknown/release/continuum_module.wasm'
TABLES = ('config', 'colony', 'world_seed', 'speed_control', 'colonist', 'tile',
          'terrain', 'work_order', 'production_policy', 'item_stack',
          'excavation_designation', 'excavation_jobs', 'terrain_material',
          'alert', 'event_log', 'membership', 'world_geometry', 'terrain_chunk')
tmp = Path(tempfile.mkdtemp(prefix='world-generation-evidence-', dir=TARGET))
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
HOST = f'http://127.0.0.1:{port}'
server = None
stop = threading.Event()
peak_rss_kib = 0
db = 'continuum-generation-baseline-test'
evidence = {'directory': str(tmp), 'baseline': BASELINE, 'timings': {}, 'progress': []}


def monitor():
    global peak_rss_kib
    while not stop.wait(.02):
        try:
            for line in Path(f'/proc/{server.pid}/status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    peak_rss_kib = max(peak_rss_kib, int(line.split()[1]))
        except FileNotFoundError:
            continue # the exclusively owned runtime may be between restart PIDs


def cli(*args, viewer=False, fail=False, expected=None):
    result = subprocess.run([CLI, '--root-dir', str(tmp / ('viewer' if viewer else 'cli')),
                             *map(str, args)], capture_output=True, text=True, timeout=120)
    if fail:
        assert result.returncode, ('unexpected success', args)
        if expected:
            assert expected in result.stdout + result.stderr, (args, result.stdout, result.stderr)
    else:
        assert not result.returncode, (args, result.stdout, result.stderr)
    return result.stdout


def call(name, *args, **kwargs):
    return cli('call', '-s', HOST, '--', db, name, *args, **kwargs)


def query(sql):
    response = json.loads(cli('sql', '--format', 'json', '-s', HOST, db, sql))[0]
    names = [e['name']['some'] for e in response['schema']['elements']]
    result = [dict(zip(names,row)) for row in response['rows']]
    for row in result:
        for k in ('soil_depth','soil_fertility','forest_density','moisture'):
            if isinstance(row.get(k),str):
                row[k] = list(bytes.fromhex(row[k]))
    return sorted(result,key=lambda row:json.dumps(row,sort_keys=True))


def rows(table):
    return query('SELECT * FROM ' + table)


def snapshot(tables=TABLES):
    return {t: json.dumps(rows(t), sort_keys=True, separators=(',', ':')).encode() for t in tables}


def state():
    return rows('world_generation')[0]


def wait(predicate, message, timeout=180):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, (message, rows('world_generation'))
        time.sleep(.025)


def ready_with_progress(timeout=180):
    start = time.monotonic()
    previous = None
    phases = []
    while True:
        s = state()
        phase = s['phase'][0]
        if previous and phase == previous['phase'][0]:
            assert s['completed_units'] >= previous['completed_units'], 'progress regressed'
        assert 0 <= s['completed_units'] <= s['total_units']
        assert s['completed_chunks'] <= s['total_chunks']
        if not phases or phases[-1] != phase:
            phases.append(phase)
        evidence['progress'].append({'seconds': time.monotonic()-start, 'phase': phase,
                                     'completed_units': s['completed_units'], 'total_units': s['total_units']})
        assert phase != 6, s
        if s['ready']:
            assert phase == 5
            return time.monotonic()-start, phases
        if rows('colonist') or rows('tile'):
            # Separate SQL requests can straddle the atomic Founding commit.
            assert state()['ready'], 'colony founded before Ready'
        previous = s
        assert time.monotonic()-start < timeout, ('generation timed out', s)
        time.sleep(.025)


def column_id(x, y):
    return y << 32 | x


def validate_complete_world():
    s = state()
    assert s['width'] == s['height'] == 2048
    assert (s['starter_x'], s['starter_y']) == (1012,1012)
    assert s['completed_chunks'] == s['total_chunks'] == 4096
    ids = query('SELECT id FROM terrain_column_chunk')
    assert {r['id'] for r in ids} == {column_id(x,y) for y in range(64) for x in range(64)}
    kept = {}
    physical_bytes = ecology_bytes = 0
    minimum = 15
    maximum = -16
    material_tops = set()
    for cx in range(64):
        columns = query(f'SELECT * FROM terrain_column_chunk WHERE chunk_x = {cx}')
        assert len(columns) == 64
        for c in columns:
            assert c['id'] == column_id(c['chunk_x'], c['chunk_y'])
            assert c['generation_id'] == s['generation_id'] and c['revision'] == 0
            assert all(len(c[k]) == 1024 for k in ('base_z','soil_depth','soil_fertility','forest_density','moisture'))
            assert all(-6 <= z <= 10 for z in c['base_z'])
            assert all(0 <= d <= 5 for d in c['soil_depth'])
            for k in ('soil_fertility','forest_density','moisture'):
                assert all(0 <= v <= 255 for v in c[k])
            for i,z in enumerate(c['base_z']):
                if i % 32 != 31:
                    assert abs(z-c['base_z'][i+1]) <= 1
                if i < 992:
                    assert abs(z-c['base_z'][i+32]) <= 1
            minimum = min(minimum,min(c['base_z']))
            maximum = max(maximum,max(c['base_z']))
            material_tops.update(1 if d else 2 for d in c['soil_depth'])
            physical_bytes += 3072
            ecology_bytes += 3072
            if cx in (31,32) and c['chunk_y'] in (31,32):
                kept[(cx,c['chunk_y'])] = c
    assert maximum-minimum >= 8 and material_tops == {1,2}
    assert physical_bytes == ecology_bytes == 12*1024*1024
    colonists = rows('colonist')
    tiles = rows('tile')
    assert [c['id'] for c in sorted(colonists,key=lambda c:c['id'])] == list(range(1,9))
    assert {t['id'] for t in tiles} == set(range(1,577))
    assert all(1012 <= t['x'] < 1036 and 1012 <= t['y'] < 1036 and t['z'] == 0 for t in tiles)
    ecology = {r['tile_id']: r for r in rows('terrain')}
    for t in tiles:
        c = kept[(t['x']//32,t['y']//32)]
        i = t['x']%32+32*(t['y']%32)
        assert c['base_z'][i] == 0 and c['soil_depth'][i] == 1
        for k in ('soil_fertility','forest_density','moisture'):
            assert abs(ecology[t['id']][k] - c[k][i]/255) < 1e-6
        if t['kind'][0] == 4:  # Farm ordinal from existing schema.
            assert ecology[t['id']]['soil_fertility'] >= 192/255-1e-6
    for c in colonists:
        assert 1012 <= c['x'] < 1036 and 1012 <= c['y'] < 1036 and c['z'] == 0
        assert 1012 <= c['target_x'] < 1036 and 1012 <= c['target_y'] < 1036
        assert 1012 <= c['next_x'] < 1036 and 1012 <= c['next_y'] < 1036
    config = rows('config')[0]
    assert config['time_scale'] == 0 and config['game_seconds'] == 28800
    assert rows('world_seed')[0]['seed'] == s['seed']
    jobs = rows('excavation_jobs')
    assert len(jobs) == 1 and len(jobs[0]['cells']) == 48
    assert len(rows('terrain_chunk')) == 1, 'initial terrain expanded into dense voxels'
    overview_ids = query('SELECT id FROM terrain_overview_chunk')
    assert len(overview_ids) == 8768
    for lod in (3,5,7,9):
        view = query(f'SELECT * FROM terrain_overview_chunk WHERE lod = {lod} AND chunk_x = 0 AND chunk_y = 0')
        assert len(view) == 32
        for r in view:
            assert all(len(r[k]) == 256 for k in ('surface_z','material','soil_fertility','forest_density','moisture'))
            assert r['generation_id'] == s['generation_id']
            assert set(r['material']) <= {0,1,2}
            for i,m in enumerate(r['material']):
                assert (m == 0) == (r['surface_z'][i] == -17)
    evidence['raw_physical_bytes'] = physical_bytes
    evidence['raw_ecology_bytes'] = ecology_bytes
    evidence['raw_overview_array_bytes'] = 8768*256*7
    evidence['raw_9x9_column_viewport_bytes'] = 81*1024*6
    evidence['bsatn_column_row_bytes']=6192 # checked by Rust serialization test
    evidence['bsatn_overview_row_bytes']=1845
    evidence['bsatn_9x9_column_viewport_row_bytes']=81*6192
    evidence['private_server_peak_rss_after_ready_kib']=peak_rss_kib


def integration():
    global db
    if BASELINE:
        cli('publish','--yes','-s',HOST,'-b',BASELINE,db)
        call('set_time_scale',0)
        assert rows('world_geometry')[0]['width'] == 128
        original = snapshot()
        cli('publish','--yes','--delete-data=never','-s',HOST,'-b',WASM,db)
        assert snapshot() == original, 'additive update changed baseline state'
        assert not rows('world_generation') and not rows('terrain_column_chunk')
        print('WORLD_BASELINE_705A72C_UPDATE_PRESERVATION_PASS',flush=True)
    db = 'continuum-generation-fresh-test'
    start = time.monotonic()
    cli('publish','--yes','-s',HOST,'-b',WASM,db)
    call('set_time_scale',0)  # records desired post-generation pause, not gameplay bypass
    request = urllib.request.Request(HOST+'/v1/identity',method='POST')
    with urllib.request.urlopen(request,timeout=5) as response:
        viewer = json.load(response)
    cli('login','--token',viewer['token'],viewer=True)
    call('set_operator',json.dumps(viewer['identity']),'false')
    call('reset_world_large',2048,2048,123,viewer=True,fail=True,expected='caller lacks the required colony role')
    call('retry_world_generation',viewer=True,fail=True,expected='caller lacks the required colony role')
    if not state()['ready']:
        call('designate_excavation',1012,1012,1012,1012,-1,1,1,fail=True,expected='world generation is not ready')
    task={'scheduled_id':0,'scheduled_at':{'Time':{'__timestamp_micros_since_unix_epoch__':0}},'generation_id':1}
    call('advance_world_generation',json.dumps(task),fail=True,expected='scheduler')
    elapsed, phases = ready_with_progress()
    evidence['timings']['publish_to_ready_s'] = time.monotonic()-start
    evidence['observed_phases'] = phases
    validate_complete_world()
    print('WORLD_2048_COMPLETE_CENTERED_READY_PASS',json.dumps(evidence['timings']),flush=True)
    before = snapshot(('world_generation','config','colony','world_geometry','world_seed'))
    for w,h in [(0,2048),(8193,2048),(2048,-1),(2147483647,2048)]:
        call('reset_world_large',w,h,1,fail=True)
        assert snapshot(('world_generation','config','colony','world_geometry','world_seed')) == before
    call('expand_world',2048,2048,fail=True)
    call('expand_world_varied',2048,2048,fail=True)
    fixture_id=rows('excavation_designation')[0]['id']
    evidence['tick_measurement_fixture_paused']=False
    start = time.monotonic()
    call('set_time_scale',6)
    wait(lambda: rows('config')[0]['game_seconds'] > 28800,'full compact tick did not advance',timeout=60)
    call('set_time_scale',0)
    evidence['timings']['first_tick_wait_inclusive_s'] = time.monotonic()-start
    assert len(rows('colonist')) == 8
    assert len(query('SELECT id FROM terrain_column_chunk')) == 4096
    print('WORLD_FULL_COMPACT_WASM_TICK_ACTIVE_FIXTURE_PASS',flush=True)
    call('set_excavation_enabled',fixture_id,'false') # isolate the following one-cell conservation test
    original_view=query('SELECT * FROM terrain_overview_chunk WHERE lod = 3 AND cut_z = 15 AND chunk_x = 7 AND chunk_y = 7')[0]
    assert original_view['surface_z'][255]==-1 and original_view['material'][255]==1
    call('designate_excavation',1020,1020,1020,1020,-1,1,3)
    job=max(rows('excavation_designation'),key=lambda j:j['id'])
    call('set_time_scale',600)
    wait(lambda: next(j for j in rows('excavation_designation') if j['id']==job['id'])['completed_cells']==1,'representative excavation did not finish',timeout=60)
    call('set_time_scale',0)
    updated_view=query('SELECT * FROM terrain_overview_chunk WHERE lod = 3 AND cut_z = 15 AND chunk_x = 7 AND chunk_y = 7')[0]
    assert updated_view['surface_z'][255]==-2 and updated_view['material'][255]==2
    assert updated_view['revision']>original_view['revision']
    assert len(query('SELECT id FROM terrain_column_chunk'))==4096
    print('WORLD_OVERVIEW_REAL_EXCAVATION_REVISION_PASS',flush=True)
    if rows('colony')[0]['wood']<20:
        call('set_time_scale',3600)
        wait(lambda: rows('colony')[0]['wood']>=20,'centered forest did not supply room wood',timeout=120)
        call('set_time_scale',0)
    start=time.monotonic()
    call('construct_room',1009,1009,1010,1010,0,6)
    evidence['timings']['compact_room_region_cli_inclusive_ms']=(time.monotonic()-start)*1000
    building=rows('building')[0]
    assert (building['x'],building['y'],building['width'],building['depth'])==(1009,1009,2,2)
    before_zone=rows('colony')[0]['wood']
    call('designate_zone_at',1009,1009,1010,1010,0,'{"storage":{}}')
    assert rows('colony')[0]['wood']==before_zone
    property_row=rows('building_thermal_property')[0]
    assert property_row['building_id']==building['id']
    assert property_row['thermal_resistance_m_2_k_per_w']==2.0
    print('WORLD_COMPACT_ROOM_FREE_ZONE_PASS',flush=True)
    evidence['private_server_peak_rss_after_tick_kib']=peak_rss_kib
    call('reset_world_large',2048,2048,1234)
    wait(lambda: state()['phase'][0] == 1 and state()['completed_chunks'] > 0,'Terrain phase not observed')
    saved = state()
    restart_server()
    recovered = state()
    assert recovered['generation_id'] == saved['generation_id']
    assert recovered['completed_chunks'] >= saved['completed_chunks']
    call('retry_world_generation')
    ready_with_progress()
    assert state()['generation_id'] == saved['generation_id']
    print('WORLD_GENERATION_RESTART_RETRY_PASS',flush=True)
    probe = os.environ.get('CONTINUUM_GENERATION_PROBE_WASM')
    if probe:
        db = 'continuum-generation-fault-test'
        cli('publish','--yes','-s',HOST,'-b',probe,db)
        call('set_time_scale',0)
        call('generation_test_force_missing_source')
        wait(lambda: state()['phase'][0] == 6,'generation fault did not persist Failed')
        failed=state()
        assert not failed['ready'] and 'missing' in failed['error']
        call('retry_world_generation')
        wait(lambda: state()['phase'][0] == 6,'retry falsely marked missing terrain ready')
        call('generation_test_repair_source')
        ready_with_progress()
        assert state()['generation_id'] == failed['generation_id']
        samples=[]
        for _ in range(5):
            start=time.monotonic()
            call('generation_test_profile_snapshot')
            samples.append((time.monotonic()-start)*1000)
        evidence['timings']['snapshot_probe_cli_inclusive_ms']=samples
        evidence['snapshot_linear_memory_bytes']=[int(e['message'].split('=')[1]) for e in rows('event_log') if e['message'].startswith('GENERATION_TEST_SNAPSHOT_LINEAR_BYTES=')]
        for label,x,y in [('nearby',1088,1024),('far_corner',2047,2047)]:
            start=time.monotonic()
            try:
                call('generation_test_route',x,y)
                result='success'
            except AssertionError as error:
                result=str(error)[-2048:]
            evidence['timings'][f'route_{label}_cli_inclusive_s']=time.monotonic()-start
            evidence[f'route_{label}_result']=result
            print(f'WORLD_ROUTE_{label.upper()}_MEASUREMENT',result,flush=True)
            if label=='nearby' or os.environ.get('CONTINUUM_REQUIRE_FAR_ROUTE')=='1':
                assert result=='success',result
        evidence['successful_route_linear_memory_bytes']=[int(e['message'].split('=')[1]) for e in rows('event_log') if e['message'].startswith('GENERATION_TEST_ROUTE_LINEAR_BYTES=')]
        print('WORLD_DURABLE_FAILURE_REPAIR_PASS',flush=True)


log = open(tmp/'server.log','a+')


def start_server():
    global server
    server=subprocess.Popen([RUNTIME,'start','--listen-addr',f'127.0.0.1:{port}',
        '--data-dir',str(tmp/'data'),'--jwt-pub-key-path',str(tmp/'id.pub'),
        '--jwt-priv-key-path',str(tmp/'id'),'--non-interactive'],stdout=log,stderr=log)
    deadline=time.monotonic()+30
    while True:
        try:
            urllib.request.urlopen(HOST+'/v1/ping',timeout=1).close()
            return
        except OSError:
            assert time.monotonic()<deadline,'private runtime did not start'
            time.sleep(.05)


def stop_server():
    server.terminate()
    try:
        server.wait(timeout=15)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()


def restart_server():
    stop_server()
    start_server()


try:
    start_server()
    thread=threading.Thread(target=monitor,daemon=True)
    thread.start()
    integration()
finally:
    stop.set()
    if server:
        stop_server()
    evidence['private_server_peak_rss_kib']=peak_rss_kib
    (tmp/'evidence.json').write_text(json.dumps(evidence,indent=2))
    print('WORLD_GENERATION_EVIDENCE',tmp,flush=True)
    log.close()
