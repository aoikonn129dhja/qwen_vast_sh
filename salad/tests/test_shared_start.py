import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


SALAD = Path(__file__).resolve().parents[1]


class SharedStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for model in ('sample', 'second'):
            directory = self.root / 'models' / model
            directory.mkdir(parents=True)
            (directory / 'setup.sh').write_text(
                'mkdir -p "$WORKSPACE/.qwen_runtime/state"\n'
                'printf "%s\\n" "$TEST_GATEWAY_PID" > "$WORKSPACE/.qwen_runtime/state/gateway.pid"\n',
                encoding='utf-8',
            )
        self.fake_gateway = subprocess.Popen(
            ['bash', '-c', 'exec -a /workspace/qwen_vast_sh/scripts/runtime/gateway.py sleep 1000'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.fake_gateway.wait)
        self.addCleanup(self.fake_gateway.kill)
        for _ in range(50):
            if b'gateway.py' in Path(f'/proc/{self.fake_gateway.pid}/cmdline').read_bytes():
                break
            time.sleep(0.01)
        self.env = dict(os.environ, SALAD_REPO_ROOT=str(self.root), WORKSPACE=str(self.root),
                        PYTHON=sys.executable, TEST_GATEWAY_PID=str(self.fake_gateway.pid),
                        COMFY_GATEWAY_USER='user', COMFY_GATEWAY_PASSWORD='x' * 20)

    def run_script(self, script, *args, env=None):
        return subprocess.run(['bash', str(SALAD / script), *args], env=env or self.env,
                              capture_output=True, timeout=5)

    def test_unknown_model_is_rejected(self):
        for model in ('', '../sample', 'unknown'):
            self.assertEqual(self.run_script('select_model.sh', model).returncode, 2)

    def test_start_requires_gateway_credentials(self):
        env = dict(self.env, COMFY_GATEWAY_PASSWORD='short')
        self.assertEqual(self.run_script('start.sh', env=env).returncode, 2)

    def test_start_rejects_invalid_ports(self):
        for port in ('0', '65536', 'bad', '8189', '8190'):
            env = dict(self.env, COMFY_PORT=port)
            self.assertEqual(self.run_script('start.sh', env=env).returncode, 2)

    def test_failed_setup_does_not_mark_ready(self):
        (self.root / 'models' / 'sample' / 'setup.sh').write_text('exit 17\n', encoding='utf-8')
        self.assertEqual(self.run_script('select_model.sh', 'sample').returncode, 17)
        self.assertFalse((self.root / '.salad-setup-ready').exists())

    def test_multiple_models_can_be_selected(self):
        self.assertEqual(self.run_script('select_model.sh', 'sample').returncode, 0)
        self.assertEqual(self.run_script('select_model.sh', 'second').returncode, 0)
        self.assertEqual((self.root / '.salad-setup-ready').read_text().splitlines(),
                         ['sample', 'second'])

    def test_reset_requires_model_and_preserves_other_data(self):
        registry = self.root / '.qwen_runtime' / 'state' / 'registered'
        registry.mkdir(parents=True)
        for model in ('sample', 'second'):
            (registry / f'{model}.json').write_text(json.dumps({
                'model_id': model, 'runtime_type': 'comfyui',
                'pid_file': str(self.root / f'{model}.pid'),
                'comfy_dir': str(self.root / 'instances' / model),
                'port': 18219,
            }), encoding='utf-8')
        shared = self.root / 'ComfyUI' / 'models' / 'checkpoints' / 'keep.safetensors'
        shared.parent.mkdir(parents=True)
        shared.write_text('keep', encoding='utf-8')
        (self.root / '.salad-setup-ready').write_text('sample\nsecond\n')
        self.assertEqual(self.run_script('reset_model.sh').returncode, 2)
        self.assertEqual(self.run_script('reset_model.sh', 'sample').returncode, 0)
        self.assertFalse((registry / 'sample.json').exists())
        self.assertTrue((registry / 'second.json').exists())
        self.assertEqual(shared.read_text(), 'keep')
        self.assertEqual((self.root / '.salad-setup-ready').read_text(), 'second\n')

    def test_reset_refuses_unrelated_pid(self):
        registry = self.root / '.qwen_runtime' / 'state' / 'registered'
        registry.mkdir(parents=True)
        pid_file = self.root / 'sample.pid'
        pid_file.write_text(str(os.getpid()))
        config = registry / 'sample.json'
        config.write_text(json.dumps({'model_id': 'sample', 'runtime_type': 'comfyui',
                                      'pid_file': str(pid_file),
                                      'comfy_dir': str(self.root / 'instances' / 'sample'),
                                      'port': 18219}), encoding='utf-8')
        self.assertNotEqual(self.run_script('reset_model.sh', 'sample').returncode, 0)
        self.assertTrue(config.exists())


if __name__ == '__main__':
    unittest.main()
