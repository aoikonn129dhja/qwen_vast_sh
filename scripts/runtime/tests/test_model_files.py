import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_files import fetch, sha256, verify


class ModelFilesTests(unittest.TestCase):
    def setUp(self):
        temporary_root = Path(__file__).resolve().parents[3] / 'tmp'
        temporary_root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "models" / "weight.safetensors"
        self.good = hashlib.sha256(b"good").hexdigest()

    def test_second_run_verifies_and_reuses_without_downloading(self):
        self.path.parent.mkdir()
        self.path.write_bytes(b"good")
        before = self.path.stat().st_mtime_ns
        self.assertTrue(fetch("https://example.test/model", self.path, self.good,
                              lambda: self.fail("download must be skipped")))
        self.assertEqual(self.path.stat().st_mtime_ns, before)

    def test_bad_existing_file_is_preserved(self):
        self.path.parent.mkdir()
        self.path.write_bytes(b"wrong")
        with self.assertRaisesRegex(RuntimeError, "Existing model SHA-256 differs"):
            fetch("https://example.test/model", self.path, self.good,
                  lambda: self.fail("download must be skipped"))
        self.assertEqual(self.path.read_bytes(), b"wrong")

    def test_interrupted_download_preserves_partial_and_final_is_absent(self):
        def interrupted():
            self.path.with_name(self.path.name + ".part").write_bytes(b"partial")
            raise RuntimeError("network interrupted")

        with self.assertRaisesRegex(RuntimeError, "network interrupted"):
            fetch("https://example.test/model", self.path, self.good, interrupted)
        self.assertFalse(self.path.exists())
        self.assertEqual(self.path.with_name(self.path.name + ".part").read_bytes(), b"partial")

    def test_verified_partial_is_placed_without_downloading(self):
        self.path.parent.mkdir()
        self.path.with_name(self.path.name + ".part").write_bytes(b"good")
        self.assertFalse(fetch("https://example.test/model", self.path, self.good,
                               lambda: self.fail("download must be skipped")))
        self.assertEqual(sha256(self.path), self.good)

    def test_wrong_download_stays_partial(self):
        with self.assertRaisesRegex(RuntimeError, "Downloaded model SHA-256 differs"):
            fetch("https://example.test/model", self.path, self.good,
                  lambda: self.path.with_name(self.path.name + ".part").write_bytes(b"bad"))
        self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
