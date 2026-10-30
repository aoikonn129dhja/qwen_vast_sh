import importlib.util
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


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

    def test_upload_wraps_detection_and_activation_for_direct_exec_gateway(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            model = root / 'models' / 'sample'
            model.mkdir(parents=True)
            (model / 'setup.sh').write_text('true\n')
            (model / 'runtime.json').write_text('{}')
            commands = []

            def gateway(command, **kwargs):
                commands.append(command)
                if command[0] == 'scp':
                    return subprocess.CompletedProcess(command, 0)
                argv = shlex.split(command[-1])
                self.assertEqual(argv[:2], ['bash', '-c'])
                self.assertEqual(len(argv), 3)
                script = argv[2]
                if script.startswith('if '):
                    output = 'Connecting to container\nPROVIDER=salad\n'
                else:
                    self.assertIn(' && tar -xf ', script)
                    self.assertIn(' && python3 ', script)
                    output = 'Connecting to container\nTRANSFER_OK test-version\n'
                # Salad can return 1 even when the requested command succeeded.
                return subprocess.CompletedProcess(command, 1, stdout=output)

            with mock.patch.object(upload, 'ROOT', root), \
                    mock.patch.object(upload, 'build_archive', return_value={'version': 'test-version'}), \
                    mock.patch.object(upload.subprocess, 'run', side_effect=gateway):
                self.assertEqual(upload.upload('ssh root@host.test -p 1234', 'sample'),
                                 ('salad', 'test-version'))
            self.assertEqual([command[0] for command in commands], ['ssh', 'scp', 'ssh'])

    def test_failed_remote_command_without_marker_is_rejected(self):
        result = subprocess.CompletedProcess([], 1, stdout='mkdir: invalid option -- x\n')
        with mock.patch.object(upload.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'SSH verification failed'):
                upload.checked_marker(['ssh', 'host', 'command'], 'TRANSFER_OK ')

    def test_workflow_source_resolves_setup_output_name_without_executing_config(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            model = Path(directory)
            (model / 'workflows').mkdir()
            source = model / 'workflows' / 'official.json'
            source.write_text('{}')
            (model / 'model.conf').write_text(
                'WORKFLOW_FILE_NAME="installed.json"\n'
                'WORKFLOW_SOURCE="workflows/official.json"\n'
                'OTHER=$(this_must_never_execute)\n')
            self.assertEqual(upload.workflow_source(model, 'installed.json'), source)
            self.assertEqual(upload.workflow_source(model, 'official.json'), source)
            with self.assertRaisesRegex(ValueError, 'Workflow source is missing'):
                upload.workflow_source(model, 'missing.json')
            (model / 'model.conf').write_text(
                'WORKFLOW_FILE_NAME="installed.json"\nWORKFLOW_SOURCE="../outside.json"\n')
            with self.assertRaisesRegex(ValueError, 'Workflow source is missing'):
                upload.workflow_source(model, 'installed.json')

    def test_requested_models_have_valid_workflow_sources(self):
        root = HERE.parents[3]
        for name in ('qwen-image-2.1-int8-lightning', 'qwen-image-edit-2511'):
            model = root / 'models' / name
            config = json.loads((model / 'runtime.json').read_text(encoding='utf-8'))
            for workflow in config['workflows']:
                with self.subTest(model=name, workflow=workflow):
                    source = upload.workflow_source(model, workflow)
                    json.loads(source.read_text(encoding='utf-8'))

    @unittest.skipUnless(shutil.which('bash'), 'Linux bash is required')
    def test_shell_script_runs_with_gateway_and_regular_ssh_semantics(self):
        script = "if [ 'two words' = 'two words' ]; then printf '%s\\n' \"it's working\"; fi && printf '%s\\n' COMPLETE"
        command = upload.shell_command(script)
        # Direct argv execution matches the Salad gateway; bash -c matches sshd.
        for argv in (shlex.split(command), ['bash', '-c', command]):
            with self.subTest(argv=argv):
                result = subprocess.run(argv, text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout, "it's working\nCOMPLETE\n")

    def test_archive_excludes_images_and_binary_models(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'models' / 'sample').mkdir(parents=True)
            (root / 'scripts' / 'setup.sh').write_text('true\n')
            (root / 'models' / 'sample' / 'setup.sh').write_text('true\n')
            candidates = {part: list((root / part).rglob('*')) for part in ('scripts', 'models')}
            # Only supply image/model path metadata; never create or open them.
            candidates['models'].extend(root / 'models' / 'sample' / name
                                        for name in ('weight.safetensors', 'image.png'))
            with mock.patch.object(Path, 'rglob', autospec=True,
                                   side_effect=lambda path, pattern: iter(candidates[path.name])):
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
