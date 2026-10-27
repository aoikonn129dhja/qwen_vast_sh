import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

MODEL_DIR = Path(__file__).resolve().parents[1]
ROOT = MODEL_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location('wan_turbo_download', MODEL_DIR / 'download_models.py')
downloader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(downloader)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / 'tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cached = self.root / 'cache.bin'
        self.cached.write_bytes(b'data')
        expected = hashlib.sha256(b'data').hexdigest()
        self.files = [('turbo.bin', 'diffusion_models', 4, expected),
                      ('encoder.bin', 'text_encoders', 4, expected),
                      ('vae.bin', 'vae', 4, expected)]

    def run_download(self, download):
        downloader.download_models(self.files, 'turbo-repo', 'pinned', 'shared-repo',
                                   self.root, download=download)

    def test_all_assets_are_counted_and_existing_files_are_skipped(self):
        download = Mock(return_value=self.cached)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.run_download(download)
            self.assertEqual(download.call_count, 3)
            self.assertEqual(download.call_args_list[0].kwargs['revision'], 'pinned')
            self.assertEqual(download.call_args_list[1].kwargs['repo_id'], 'shared-repo')
            download.reset_mock()
            self.run_download(download)
            download.assert_not_called()
        log = output.getvalue()
        for prefix in ('[7/10] [1/3 files]', '[8/10] [2/3 files]', '[9/10] [3/3 files]'):
            self.assertIn(prefix, log)
        self.assertIn('completed 3/3 files', log)
        self.assertIn('100.0%', log)
        self.assertIn('MiB/s | ETA', log)
        self.assertIn('Verified SHA-256; reuse:', log)

    def test_bad_download_preserves_existing_destination(self):
        destination = self.root / 'models/diffusion_models/turbo.bin'
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b'old')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(RuntimeError, 'Existing model SHA-256 differs'):
                self.run_download(Mock(return_value=self.cached))
        self.assertEqual(destination.read_bytes(), b'old')
        self.assertNotIn('completed 1/3 files', output.getvalue())

    def test_copy_error_preserves_destination_and_removes_partial(self):
        destination = self.root / 'destination.bin'
        destination.write_bytes(b'old')
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'Copy size mismatch'):
                downloader.copy_model(self.cached, destination, 5, '[7/10]')
        self.assertEqual(destination.read_bytes(), b'old')
        self.assertFalse(list(self.root.glob('*.part.*')))

    def test_heartbeat_reports_while_operation_is_waiting(self):
        reported = threading.Event()
        messages = []

        def capture(prefix, message):
            messages.append((prefix, message))
            if not message.startswith(('START', 'DONE')):
                reported.set()

        with patch.object(downloader, 'REPORT_SECONDS', 0.01), patch.object(downloader, 'log', capture):
            with downloader.activity('[8/10]', 'Copy', lambda: (2, 4)):
                self.assertTrue(reported.wait(timeout=2))
        self.assertIn('50.0%', messages[1][1])
        self.assertTrue(messages[-1][1].startswith('DONE'))


if __name__ == '__main__':
    unittest.main()
