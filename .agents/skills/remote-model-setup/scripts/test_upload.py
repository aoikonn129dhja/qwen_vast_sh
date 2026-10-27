import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('remote_upload', HERE / 'upload.py')
upload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upload)
INSTALL_SPEC = importlib.util.spec_from_file_location('remote_install', HERE / 'remote_install.py')
installer = importlib.util.module_from_spec(INSTALL_SPEC)
INSTALL_SPEC.loader.exec_module(installer)
TEMP_ROOT = Path(__file__).resolve().parents[4] / 'tmp'


class UploadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TEMP_ROOT.mkdir(exist_ok=True)

    def test_parse_ssh_does_not_accept_remote_commands(self):
        self.assertEqual(upload.parse_ssh('ssh root@host.test -p 1234 -L 8188:localhost:8188'),
                         (['-p', '1234'], 'root@host.test'))
        with self.assertRaises(ValueError):
            upload.parse_ssh('ssh root@host.test "rm -rf /workspace"')
        self.assertEqual(
            upload.setup_command('ssh root@host.test -p 1234', 'salad', 'sample'),
            "ssh -tt -p 1234 root@host.test 'bash /opt/salad/select_model.sh sample'",
        )

    def test_archive_excludes_images_and_binary_models(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'models' / 'sample').mkdir(parents=True)
            (root / 'scripts' / 'setup.sh').write_text('true\n')
            (root / 'models' / 'sample' / 'setup.sh').write_text('true\n')
            (root / 'models' / 'sample' / 'weight.safetensors').write_bytes(b'weight')
            (root / 'models' / 'sample' / 'image.png').write_bytes(b'image')
            names = [p.relative_to(root).as_posix() for p in upload.source_files(root)]
            self.assertEqual(names, ['models/sample/setup.sh', 'scripts/setup.sh'])

    def test_remote_install_never_changes_model_data_after_bad_transfer(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            base = Path(directory)
            stage = base / 'stage'
            target = base / 'code'
            shared = base / 'ComfyUI' / 'models'
            shared.mkdir(parents=True)
            model = shared / 'keep.safetensors'
            model.write_bytes(b'keep')
            (stage / 'scripts').mkdir(parents=True)
            (stage / 'scripts' / 'setup.sh').write_text('changed')
            (stage / 'manifest.json').write_text(json.dumps({
                'files': {'scripts/setup.sh': '0' * 64}, 'version': 'bad'
            }))
            with self.assertRaisesRegex(ValueError, 'verification failed'):
                installer.install(stage, target)
            self.assertEqual(model.read_bytes(), b'keep')
            self.assertFalse((target / 'scripts' / 'setup.sh').exists())

    def test_remote_install_activates_code_and_preserves_model(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            base = Path(directory)
            stage = base / 'stage'
            target = base / 'code'
            model = base / 'ComfyUI' / 'models' / 'keep.safetensors'
            model.parent.mkdir(parents=True)
            model.write_bytes(b'keep')
            (stage / 'scripts').mkdir(parents=True)
            (stage / 'scripts' / 'setup.sh').write_bytes(b'new code')
            (target / 'scripts').mkdir(parents=True)
            (target / 'scripts' / 'setup.sh').write_bytes(b'old code')
            (stage / 'manifest.json').write_text(json.dumps({
                'files': {'scripts/setup.sh': hashlib.sha256(b'new code').hexdigest()},
                'version': 'test-version',
            }))
            installer.install(stage, target)
            self.assertEqual((target / 'scripts' / 'setup.sh').read_bytes(), b'new code')
            self.assertEqual(model.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
