import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


MODEL_DIR = Path(__file__).resolve().parents[1]
ROOT = MODEL_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location('wan_turbo_preflight', MODEL_DIR / 'preflight.py')
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def test_speed_boundary_and_explicit_override(self):
        self.assertTrue(preflight.allow_download(10, 10, False, False))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(preflight.allow_download(9.99, 10, False, False))
            self.assertTrue(preflight.allow_download(1, 10, True, False))
            self.assertTrue(preflight.allow_download(1, 10, False, True, lambda _: 'yes'))
            self.assertFalse(preflight.allow_download(1, 10, False, True, lambda _: ''))

    def test_probe_caps_read_even_if_server_ignores_range(self):
        response = io.BytesIO(b'x' * 100)
        with patch.object(preflight.urllib.request, 'urlopen', return_value=response) as request:
            with patch.object(preflight.time, 'monotonic', side_effect=[0, 1, 2]):
                self.assertEqual(preflight.speed_probe('https://example.invalid/model', 10),
                                 10 / preflight.MIB / 2)
        self.assertEqual(request.call_args.args[0].get_header('Range'), 'bytes=0-9')

    def test_existing_sizes_skip_probe_and_partial_files_require_download(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            shared = Path(directory)
            model = shared / 'models/diffusion_models/test.safetensors'
            model.parent.mkdir(parents=True)
            model.write_bytes(b'complete')
            argv = ['preflight', '--url', 'https://example.invalid/model',
                    '--shared-dir', str(shared), '--file', 'diffusion_models/test.safetensors', '8']
            with patch('sys.argv', argv), patch.dict(os.environ, {}, clear=True):
                with patch.object(preflight, 'speed_probe', return_value=1) as probe:
                    with patch.object(preflight.sys.stdin, 'isatty', return_value=False):
                        with contextlib.redirect_stdout(io.StringIO()) as output:
                            self.assertEqual(preflight.main(), 0)
                            probe.assert_not_called()
                            model.write_bytes(b'partial')
                            self.assertEqual(preflight.main(), 2)
                            probe.assert_called_once()
                        self.assertIn('Estimated missing-model download:', output.getvalue())

    def test_failed_probe_warns_and_continues_like_v23(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            argv = ['preflight', '--url', 'https://example.invalid/model',
                    '--shared-dir', directory, '--file', 'diffusion_models/test.safetensors', '8']
            with patch('sys.argv', argv), patch.dict(os.environ, {}, clear=True):
                with patch.object(preflight, 'speed_probe', side_effect=OSError('offline')):
                    with contextlib.redirect_stdout(io.StringIO()) as output:
                        self.assertEqual(preflight.main(), 0)
                    self.assertIn('WARNING:', output.getvalue())


if __name__ == '__main__':
    unittest.main()
