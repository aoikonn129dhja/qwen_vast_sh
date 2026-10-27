import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import network_preflight


class NetworkPreflightTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[3] / "tmp"
        root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "model.safetensors"
        self.expected = hashlib.sha256(b"model").hexdigest()
        self.files = [("https://huggingface.co/example/model", self.path, self.expected)]

    def test_probe_reads_only_requested_bytes(self):
        class Response(io.BytesIO):
            def close(self):
                self.bytes_read = self.tell()
                super().close()

        response = Response(b"x" * 100)
        with mock.patch.object(network_preflight.urllib.request, "urlopen", return_value=response) as opened:
            with mock.patch.object(network_preflight.time, "monotonic", side_effect=[0, 1, 2]):
                self.assertEqual(network_preflight.speed_probe(self.files[0][0], 10),
                                 10 / network_preflight.MIB / 2)
        self.assertEqual(opened.call_args.args[0].get_header("Range"), "bytes=0-9")
        self.assertEqual(response.bytes_read, 10)

    def test_verified_file_skips_network(self):
        self.path.write_bytes(b"model")
        before = self.path.stat().st_mtime_ns
        with mock.patch.object(network_preflight, "speed_probe") as probe:
            self.assertEqual(network_preflight.preflight(self.files, 10, 8 * network_preflight.MIB,
                                                         False, False), 0)
        probe.assert_not_called()
        self.assertEqual(self.path.stat().st_mtime_ns, before)

    def test_bad_existing_file_stops_before_network_and_is_preserved(self):
        self.path.write_bytes(b"wrong")
        with mock.patch.object(network_preflight, "speed_probe") as probe:
            with self.assertRaisesRegex(RuntimeError, "Existing model SHA-256 differs"):
                network_preflight.preflight(self.files, 10, 8 * network_preflight.MIB,
                                            False, False)
        probe.assert_not_called()
        self.assertEqual(self.path.read_bytes(), b"wrong")

    def test_slow_host_stops_noninteractive_and_override_continues(self):
        with mock.patch.object(network_preflight, "speed_probe", return_value=2.0) as probe:
            self.assertEqual(network_preflight.preflight(self.files, 10, 8 * network_preflight.MIB,
                                                         False, False), 2)
            self.assertEqual(network_preflight.preflight(self.files, 10, 8 * network_preflight.MIB,
                                                         True, False), 0)
        self.assertEqual(probe.call_count, 2)
        self.assertFalse(self.path.exists())

    def test_slow_host_interactive_confirmation(self):
        self.assertTrue(network_preflight.allow_download(2, 10, False, True, lambda _: "y"))
        self.assertFalse(network_preflight.allow_download(2, 10, False, True, lambda _: "n"))

    def test_probe_failure_warns_and_continues(self):
        with mock.patch.object(network_preflight, "speed_probe", side_effect=OSError("offline")):
            self.assertEqual(network_preflight.preflight(self.files, 10, 8 * network_preflight.MIB,
                                                         False, False), 0)


if __name__ == "__main__":
    unittest.main()
