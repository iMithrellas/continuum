#!/usr/bin/env python3
"""File/lock-only deletion checks. Never launches a runtime or sends signals."""
import fcntl
from pathlib import Path
import subprocess
import tempfile
import unittest

SUPERVISOR = Path(__file__).resolve().parents[1] / "native-hosting/native-server-supervisor.sh"


class DeletionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="server-delete-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.instance = self.root / "native/servers/server-a"
        self.data = self.instance / "data"
        self.config = self.instance / "config"
        self.data.mkdir(parents=True)
        self.config.mkdir()
        (self.data / "colony.save").write_text("persistent colony")
        (self.config / "private.key").write_text("private key")
        (self.instance / "server.log").write_text("logs")
        self.lock = self.instance / "data.lock"
        self.manifest = self.instance / "server.json"

    def delete(self, instance=None):
        instance = instance or self.instance
        return subprocess.run(
            ["bash", str(SUPERVISOR), "delete", str(instance / "data.lock"),
             str(instance / "server.json"), str(instance)],
            capture_output=True, text=True, timeout=5,
        )

    def test_deletes_only_selected_server_and_preserves_lock_inode(self):
        sibling = self.instance.parent / "server-b/data/colony.save"
        sibling.parent.mkdir(parents=True)
        sibling.write_text("other colony")
        shared = self.root / "native/modules/module.wasm"
        shared.parent.mkdir()
        shared.write_text("shared artifact")
        self.lock.touch()
        inode = self.lock.stat().st_ino
        result = self.delete()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.data.exists())
        self.assertFalse(self.config.exists())
        self.assertFalse((self.instance / "server.log").exists())
        self.assertEqual(self.lock.stat().st_ino, inode)
        self.assertTrue((self.instance / ".continuum-deleted").exists())
        self.assertEqual(sibling.read_text(), "other colony")
        self.assertEqual(shared.read_text(), "shared artifact")
        self.assertEqual(self.delete().returncode, 0, "deletion is retryable")

    def test_held_runtime_lock_refuses_deletion(self):
        with self.lock.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.delete().returncode, 73)
            self.assertTrue((self.data / "colony.save").exists())
            self.assertFalse((self.instance / ".continuum-deleted").exists())

    def test_new_owner_manifest_refuses_deletion(self):
        self.manifest.write_text('{"startup_nonce":"new-owner"}')
        self.assertEqual(self.delete().returncode, 73)
        self.assertIn("new-owner", self.manifest.read_text())
        self.assertTrue((self.data / "colony.save").exists())

    def test_redirected_parent_is_never_followed(self):
        alias = self.root / "redirect"
        alias.symlink_to(self.instance, target_is_directory=True)
        self.assertEqual(self.delete(alias).returncode, 64)
        self.assertTrue((self.data / "colony.save").exists())

    def test_redirected_data_is_never_followed(self):
        other = self.instance / "original-data"
        self.data.rename(other)
        self.data.symlink_to(other, target_is_directory=True)
        self.assertEqual(self.delete().returncode, 64)
        self.assertTrue((other / "colony.save").exists())

    def test_redirected_lock_is_never_opened(self):
        outside = self.root / "outside.txt"
        outside.write_text("do not truncate")
        self.lock.symlink_to(outside)
        self.assertEqual(self.delete().returncode, 64)
        self.assertEqual(outside.read_text(), "do not truncate")


if __name__ == "__main__":
    unittest.main()
