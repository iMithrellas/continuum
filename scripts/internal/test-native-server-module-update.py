#!/usr/bin/env python3
"""Disposable module-install files/locks only; no runtimes or host signals."""
import fcntl
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SUPERVISOR = Path(__file__).resolve().parents[1] / "native-hosting/native-server-supervisor.sh"


class ModuleUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="server-module-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.instance = self.root / "native/servers/server-a"
        self.data = self.instance / "data"
        self.config = self.instance / "config"
        self.data.mkdir(parents=True)
        self.config.mkdir()
        self.save = self.data / "colony.save"
        self.save.write_bytes(b"persistent colony")
        self.key = self.config / "private.key"
        self.key.write_bytes(b"private publisher identity")
        self.pin = self.data / ".continuum-module.sha256"
        self.pin.write_text("a" * 64)
        self.source = self.root / "current.wasm"
        self.source.write_bytes(b"current module")
        self.digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.destination = self.instance / "continuum_module.wasm"
        self.destination.write_bytes(b"old per-server module")
        self.lock = self.instance / "data.lock"
        self.manifest = self.instance / "server.json"

    def install(self, instance=None, digest=None):
        instance = instance or self.instance
        return subprocess.run(
            ["bash", str(SUPERVISOR), "install-module", str(instance / "data.lock"),
             str(instance / "server.json"), str(instance), str(self.source), digest or self.digest],
            capture_output=True, text=True, timeout=5,
        )

    def assert_preserved(self):
        self.assertEqual(self.save.read_bytes(), b"persistent colony")
        self.assertEqual(self.key.read_bytes(), b"private publisher identity")
        self.assertEqual(self.pin.read_text(), "a" * 64, "only successful publication may change the pin")

    def test_installs_only_profile_module_and_preserves_deployed_pin(self):
        shared = self.root / "native/modules/continuum_module.wasm"
        shared.parent.mkdir()
        shared.write_bytes(b"shared pinned module")
        sibling = self.instance.parent / "server-b/continuum_module.wasm"
        sibling.parent.mkdir()
        sibling.write_bytes(b"another running server module")
        self.lock.touch()
        inode = self.lock.stat().st_ino
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.lock.stat().st_ino, inode)
        self.assertEqual(shared.read_bytes(), b"shared pinned module")
        self.assertEqual(sibling.read_bytes(), b"another running server module")
        self.assert_preserved()
        self.assertEqual(self.install().returncode, 0, "module preparation is retryable")

    def test_held_runtime_lock_refuses_update(self):
        with self.lock.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.install().returncode, 73)
        self.assertEqual(self.destination.read_bytes(), b"old per-server module")
        self.assert_preserved()

    def test_owner_manifest_refuses_update(self):
        self.manifest.write_text('{"startup_nonce":"other-owner"}')
        self.assertEqual(self.install().returncode, 73)
        self.assertIn("other-owner", self.manifest.read_text())
        self.assertEqual(self.destination.read_bytes(), b"old per-server module")
        self.assert_preserved()

    def test_deleted_profile_cannot_be_updated(self):
        (self.instance / ".continuum-deleted").write_text("deleted")
        self.assertEqual(self.install().returncode, 66)
        self.assertEqual(self.destination.read_bytes(), b"old per-server module")

    def test_checksum_failure_preserves_previous_module(self):
        self.assertEqual(self.install(digest="b" * 64).returncode, 65)
        self.assertEqual(self.destination.read_bytes(), b"old per-server module")
        self.assertEqual(list(self.instance.glob("continuum_module.wasm.tmp.*")), [])
        self.assert_preserved()

    def test_redirected_paths_are_never_followed(self):
        alias = self.root / "redirect"
        alias.symlink_to(self.instance, target_is_directory=True)
        self.assertEqual(self.install(alias).returncode, 64)
        self.destination.unlink()
        self.destination.symlink_to(self.source)
        self.assertEqual(self.install().returncode, 64)
        self.assertEqual(self.source.read_bytes(), b"current module")
        self.assert_preserved()

    def test_redirected_lock_is_not_opened(self):
        outside = self.root / "outside"
        outside.write_text("do not truncate")
        self.lock.symlink_to(outside)
        self.assertEqual(self.install().returncode, 64)
        self.assertEqual(outside.read_text(), "do not truncate")

    def test_publication_never_deletes_data_or_pins_a_failed_publish(self):
        source = SUPERVISOR.read_text()
        publish = source.index('"$cli" publish')
        pin = source.index('> "$data/.continuum-module.sha256"', publish)
        self.assertIn("--delete-data=never", source[publish:pin])
        self.assertIn('"$(<"$data/.continuum-module.sha256")" != "$module_sha256"', source[publish - 180:publish])


if __name__ == "__main__":
    unittest.main()
