import io
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import download_models


class DownloadModelsTest(unittest.TestCase):
    def test_speed_probe_reads_at_most_eight_mib(self):
        class Response(io.BytesIO):
            def close(self):
                self.bytes_read = self.tell()
                super().close()

        response = Response(b"a" * (download_models.PROBE_BYTES + 1))
        with mock.patch.object(download_models.urllib.request, "urlopen", return_value=response) as open_url:
            speed = download_models.speed_probe("https://example.test/model.gguf")
        self.assertGreater(speed, 0)
        self.assertEqual(response.bytes_read, download_models.PROBE_BYTES)
        self.assertEqual(
            open_url.call_args.args[0].get_header("Range"),
            f"bytes=0-{download_models.PROBE_BYTES - 1}",
        )

    def test_model_sizes_requires_every_file(self):
        files = [("split/a.gguf", Path("a.gguf"), "0" * 64),
                 ("split/b.gguf", Path("b.gguf"), "0" * 64)]
        body = io.BytesIO(json.dumps([{"path": "split/a.gguf", "size": 100}]).encode())
        with mock.patch.object(download_models.urllib.request, "urlopen", return_value=body):
            with self.assertRaisesRegex(RuntimeError, "split/b.gguf"):
                download_models.model_sizes("owner/repo", "main", files)

    def test_progress_and_resume(self):
        root = Path(__file__).resolve().parents[4] / "tmp"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            first = Path(temporary) / "a.gguf"
            second = Path(temporary) / "b.gguf"
            first.write_bytes(b"aaaa")
            second.with_name(second.name + ".part").write_bytes(b"bb")
            files = [("split/a.gguf", first, hashlib.sha256(b"aaaa").hexdigest()),
                     ("split/b.gguf", second, hashlib.sha256(b"bbbbbb").hexdigest())]
            self.assertEqual(download_models.existing_bytes(files, [4, 6]), 6)
            self.assertIn("60.0%", download_models.progress_line(6, 10, 0))
            self.assertIn("残り約", download_models.progress_line(6, 10, 2))

            def download_file(url, destination, expected):
                self.assertEqual(url.rsplit('/', 1)[-1], destination.name)
                if destination == second:
                    destination.write_bytes(b"bbbbbb")
                self.assertEqual(hashlib.sha256(destination.read_bytes()).hexdigest(), expected)

            with mock.patch.object(download_models, "fetch", side_effect=download_file) as fetch:
                with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
                    download_models.download(files, [4, 6], "https://example.test", 0)
            self.assertEqual(fetch.call_count, 2)
            self.assertIn("(100.0%)", output.getvalue())
            self.assertIn("(2/2)", output.getvalue())

    def test_oversized_existing_file_fails(self):
        root = Path(__file__).resolve().parents[4] / "tmp"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            destination = Path(temporary) / "a.gguf"
            destination.write_bytes(b"too big")
            with self.assertRaisesRegex(RuntimeError, "Existing model SHA-256 differs"):
                download_models.existing_bytes([("split/a.gguf", destination, "0" * 64)], [3])
            self.assertEqual(destination.read_bytes(), b"too big")

    def test_slow_preflight_stops_before_model_download(self):
        argv = ["download_models.py", "--repo", "owner/repo", "--revision", "pinned",
                "--file", "split/a.gguf", "missing.gguf", "0" * 64]
        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(download_models, "model_sizes", return_value=[100]), \
             mock.patch.object(download_models, "existing_bytes", return_value=0), \
             mock.patch.object(download_models, "speed_probe", return_value=2 * download_models.MIB), \
             mock.patch.object(download_models, "download") as download, \
             mock.patch.object(sys.stdin, "isatty", return_value=False), \
             mock.patch.dict("os.environ", {"MIN_DOWNLOAD_MIB_S": "10", "ALLOW_SLOW_DOWNLOAD": "0"}):
            with self.assertRaises(SystemExit) as exit_info:
                download_models.main()
        self.assertEqual(exit_info.exception.code, 2)
        download.assert_not_called()


if __name__ == "__main__":
    unittest.main()
