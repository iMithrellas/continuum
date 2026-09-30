#!/usr/bin/env python3
"""Disposable real-WASM gate: no existing server, database, CLI token or client.

Run: python3 backend/spacetimedb/tools/profile_live.py [--parent-gate PATH]
The optional parent checker is read/run unchanged against this owned server and
this worktree's artifact. It is not copied into or edited in the parent tree.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import io
import tarfile

MODULE = Path(__file__).resolve().parents[1]
NATIVE = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "Continuum/native/spacetimedb/2.10.0"
CLI = os.environ.get("SPACETIME_CLI", str(NATIVE / "spacetimedb-cli"))
RUNTIME = os.environ.get("SPACETIME_RUNTIME", str(NATIVE / "spacetimedb-standalone"))
LEGACY_FIXTURE_REV = "c896f937b74f1e0eb8ce9b6b253f27d1497e8f72"  # immutable pre-vertical baseline


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent-gate", type=Path)
    parser.add_argument("--migration", action="store_true", help="also build the immutable pre-vertical fixture and test a genuinely paused additive upgrade")
    args = parser.parse_args()
    subprocess.run(["cargo", "build", "--manifest-path", str(MODULE / "Cargo.toml"), "--release", "--target", "wasm32-unknown-unknown"], check=True)
    wasm = MODULE / "target/wasm32-unknown-unknown/release/continuum_module.wasm"
    with tempfile.TemporaryDirectory(prefix="continuum-backend-profile-", dir="/tmp/opencode") as root:
        root = Path(root)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        host = f"http://127.0.0.1:{port}"
        (root / "data").mkdir()
        (root / "keys").mkdir()
        log = root / "server.log"
        with log.open("w") as output:
            process = subprocess.Popen([RUNTIME, "start", "--listen-addr", f"127.0.0.1:{port}", "--data-dir", str(root / "data"), "--jwt-pub-key-path", str(root / "keys/id.pub"), "--jwt-priv-key-path", str(root / "keys/id"), "--non-interactive"], stdout=output, stderr=subprocess.STDOUT)
            try:
                def cli(*argv):
                    result = subprocess.run([CLI, "--root-dir", str(root / "cli"), *map(str, argv)], capture_output=True, text=True, timeout=60)
                    assert result.returncode == 0, (argv, result.stdout, result.stderr)
                    return result.stdout

                def wait(test, seconds=45):
                    end = time.monotonic() + seconds
                    while time.monotonic() < end:
                        if test():
                            return
                        time.sleep(0.1)
                    raise AssertionError("private WASM gate timed out\n" + log.read_text()[-12000:])

                def healthy():
                    try:
                        return urllib.request.urlopen(host + "/v1/ping", timeout=1).status == 200
                    except OSError:
                        return False

                wait(healthy)
                db = "backend-profile"

                def call(name, *argv):
                    return cli("call", "-s", host, "--", db, name, *(json.dumps(x) if isinstance(x, bool) else str(x) for x in argv))

                def rows(sql):
                    result = json.loads(cli("sql", "--format", "json", "-s", host, db, sql))[0]
                    names = [e["name"]["some"] for e in result["schema"]["elements"]]
                    return [dict(zip(names, row)) for row in result["rows"]]

                cli("publish", "--yes", "-s", host, "-b", wasm, db)
                call("set_time_scale", 0)
                for scale in [6, 60, 600, 3600, 100000]:
                    call("reset_colony")
                    call("set_time_scale", 0)
                    before = rows("SELECT game_seconds FROM config")[0]["game_seconds"]
                    started = time.monotonic()
                    call("set_time_scale", scale)
                    wait(lambda: rows("SELECT game_seconds FROM config")[0]["game_seconds"] >= before + scale)
                    call("set_time_scale", 0)
                    after = rows("SELECT game_seconds FROM config")[0]["game_seconds"]
                    elapsed = time.monotonic() - started
                    assert (after-before) >= scale
                    assert abs((after-before) / scale - round((after-before)/scale)) < 1e-8
                    assert not any(word in log.read_text().lower() for word in ("runtime error", "fuel exhausted", "wasm trap")), log.read_text()[-12000:]
                    print(f"WASM_PASS scale={scale} game_delta={after-before:g} observed_wall={elapsed:.3f}s", flush=True)
                    if scale==100000:
                        started=time.monotonic();before=after
                        call("set_time_scale",scale)
                        wait(lambda:rows("SELECT game_seconds FROM config")[0]["game_seconds"]>=before+3*scale)
                        call("set_time_scale",0)
                        after=rows("SELECT game_seconds FROM config")[0]["game_seconds"]
                        assert abs((after-before)/scale-round((after-before)/scale))<1e-8
                        print(f"WASM_SUSTAIN_PASS scale={scale} game_delta={after-before:g} observed_wall={time.monotonic()-started:.3f}s",flush=True)
                # A large valid job vector is exercised by an actual scheduled tick.
                call("reset_colony"); call("set_time_scale", 0)
                for d in rows("SELECT id FROM excavation_designation"):
                    call("cancel_excavation", d["id"])
                call("designate_excavation", 0, 0, 23, 23, -16, 16, 2)
                assert rows("SELECT total_cells FROM excavation_designation")[0]["total_cells"] == 9216
                before = rows("SELECT game_seconds FROM config")[0]["game_seconds"]
                call("set_time_scale", 600)
                wait(lambda: rows("SELECT game_seconds FROM config")[0]["game_seconds"] >= before + 600)
                call("set_time_scale", 0)
                print("WASM_LARGE_DESIGNATION_PASS cells=9216", flush=True)
                if args.parent_gate:
                    env = dict(os.environ, TERRAIN_TEST_CLI=CLI, TERRAIN_TEST_TMP=str(root), TERRAIN_TEST_PORT=str(port), TERRAIN_TEST_WASM=str(wasm))
                    env.pop("CONTINUUM_BASELINE_WASM", None)
                    subprocess.run(["python3", str(args.parent_gate.resolve())], env=env, check=True, timeout=240)
                assert "runtime error" not in log.read_text().lower(), log.read_text()[-12000:]
                if args.migration:
                    # Test fixture only: read the immutable pre-vertical source
                    # without checking out/reverting/editing another worktree.
                    archive=subprocess.run(["git","archive",LEGACY_FIXTURE_REV,"backend/spacetimedb"],cwd=MODULE.parents[1],capture_output=True,check=True).stdout
                    legacy=root / "legacy"
                    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
                        source.extractall(legacy,filter="data")
                    old=legacy / "backend/spacetimedb"
                    subprocess.run(["cargo","build","--manifest-path",str(old / "Cargo.toml"),"--release","--target","wasm32-unknown-unknown"],check=True)
                    db="backend-paused-migration"
                    cli("publish","--yes","-s",host,"-b",old / "target/wasm32-unknown-unknown/release/continuum_module.wasm",db)
                    call("set_time_scale",6)
                    wait(lambda:any(c["move_progress"]>0 and c["x"]!=0 and c["y"]!=0 for c in rows("SELECT * FROM colonist")))
                    call("set_time_scale",0)
                    snapshots={q:rows(q) for q in ("SELECT * FROM colonist","SELECT * FROM tile","SELECT * FROM work_order","SELECT * FROM colony","SELECT game_seconds FROM config")}
                    cli("publish","--yes","--delete-data=never","-s",host,"-b",wasm,db)
                    wait(lambda:len(rows("SELECT * FROM world_geometry"))==1)
                    before={c["id"]:c for c in snapshots["SELECT * FROM colonist"]}
                    for c in rows("SELECT * FROM colonist"):
                        previous=before[c["id"]]
                        for key,value in previous.items():
                            assert c[key]==value,("paused migration changed legacy field",key,previous,c)
                        expected=(c["x"],c["y"],0)
                        if c["activity"][0]==1:
                            if c["x"]!=c["target_x"]:
                                expected=(c["x"]+(1 if c["target_x"]>c["x"] else -1),c["y"],0)
                            elif c["y"]!=c["target_y"]:
                                expected=(c["x"],c["y"]+(1 if c["target_y"]>c["y"] else -1),0)
                        assert (c["next_x"],c["next_y"],c["next_z"])==expected,("paused next hop",c,expected)
                    for q in ("SELECT * FROM work_order","SELECT * FROM colony","SELECT game_seconds FROM config"):
                        assert rows(q)==snapshots[q],("paused additive state changed",q)
                    tiles={t["id"]:t for t in rows("SELECT * FROM tile")}
                    for previous in snapshots["SELECT * FROM tile"]:
                        assert all(tiles[previous["id"]][k]==v for k,v in previous.items())
                    print("WASM_PAUSED_MIGRATION_PASS nonzero_travellers_fraction_and_xy_resources_orders_preserved",flush=True)
            finally:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=10)


if __name__ == "__main__":
    main()
