import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SALAD = Path(__file__).resolve().parents[1]


class SharedStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        model = self.root / 'models' / 'sample'
        model.mkdir(parents=True)
        self.setup = model / 'setup.sh'
        self.env = dict(os.environ, SALAD_REPO_ROOT=str(self.root), WORKSPACE=str(self.root),
                        COMFY_GATEWAY_USER='user', COMFY_GATEWAY_PASSWORD='x' * 20)

    def select(self, model='sample'):
        return subprocess.run(['bash', str(SALAD / 'select_model.sh'), model],
                              env=self.env, capture_output=True, timeout=5)

    def test_unknown_model_is_rejected(self):
        for model in ('', '../sample', 'unknown'):
            self.assertEqual(self.select(model).returncode, 2)

    def test_start_requires_gateway_credentials(self):
        env = dict(self.env, COMFY_GATEWAY_PASSWORD='short')
        result = subprocess.run(['bash', str(SALAD / 'start.sh')], env=env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)

    def test_failed_setup_does_not_mark_ready(self):
        self.setup.write_text('exit 17\n', encoding='utf-8')
        self.assertEqual(self.select().returncode, 17)
        self.assertFalse((self.root / '.salad-setup-ready').exists())

    def test_missing_comfy_process_does_not_mark_ready(self):
        self.setup.write_text('exit 0\n', encoding='utf-8')
        self.assertEqual(self.select().returncode, 2)
        self.assertFalse((self.root / '.salad-setup-ready').exists())

    def test_reset_restores_base_environment_and_preserves_user_data(self):
        comfy = self.root / 'ComfyUI'
        (comfy / 'models').mkdir(parents=True)
        (comfy / 'models' / 'checkpoint').write_text('model')
        (comfy / 'output').mkdir()
        (comfy / 'output' / 'result.txt').write_text('result')
        venv = self.root / 'venv'
        (venv / 'bin').mkdir(parents=True)
        (venv / 'bin' / 'python').write_text('changed')
        base = self.root / 'base-venv'
        (base / 'bin').mkdir(parents=True)
        (base / 'bin' / 'python').write_text('base')
        (base / 'bin' / 'python').chmod(0o755)
        (self.root / '.salad-setup-ready').write_text('sample 999999\n')
        (self.root / 'comfyui.pid').write_text('999999\n')
        env = dict(self.env, SALAD_VENV_DIR=str(venv), SALAD_BASE_VENV=str(base))
        result = subprocess.run(['bash', str(SALAD / 'reset_model.sh')], env=env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(comfy.exists())
        self.assertFalse((self.root / '.salad-setup-ready').exists())
        self.assertEqual((venv / 'bin' / 'python').read_text(), 'base')
        archives = list((self.root / 'salad-user-data').glob('*/output/result.txt'))
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].read_text(), 'result')
        self.setup.write_text('exit 17\n', encoding='utf-8')
        self.assertEqual(self.select().returncode, 17)

    def test_reset_refuses_unrelated_pid(self):
        base = self.root / 'base-venv'
        (base / 'bin').mkdir(parents=True)
        (base / 'bin' / 'python').write_text('base')
        (base / 'bin' / 'python').chmod(0o755)
        (self.root / 'comfyui.pid').write_text(str(os.getpid()))
        (self.root / '.salad-setup-ready').write_text('sample 1\n')
        env = dict(self.env, SALAD_VENV_DIR=str(self.root / 'venv'),
                   SALAD_BASE_VENV=str(base))
        result = subprocess.run(['bash', str(SALAD / 'reset_model.sh')], env=env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertFalse((self.root / '.salad-setup-ready').exists())

    def test_reset_stops_recorded_comfy_process(self):
        comfy = self.root / 'ComfyUI'
        comfy.mkdir()
        base = self.root / 'base-venv'
        (base / 'bin').mkdir(parents=True)
        (base / 'bin' / 'python').write_text('base')
        (base / 'bin' / 'python').chmod(0o755)
        proc = subprocess.Popen(['bash', '-c', 'exec -a main.py sleep 1000'], cwd=comfy)
        self.addCleanup(lambda: proc.kill() if proc.poll() is None else None)
        (self.root / 'comfyui.pid').write_text(f'{proc.pid}\n')
        (self.root / '.salad-setup-ready').write_text(f'sample {proc.pid}\n')
        env = dict(self.env, SALAD_VENV_DIR=str(self.root / 'venv'),
                   SALAD_BASE_VENV=str(base))
        result = subprocess.run(['bash', str(SALAD / 'reset_model.sh')], env=env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        proc.wait(timeout=5)
        self.assertFalse(comfy.exists())

    def test_manual_selection_keeps_container_alive_during_comfy_restart(self):
        self.setup.write_text('sleep 1000 >/dev/null 2>&1 &\necho $! > "$WORKSPACE/comfyui.pid"\n', encoding='utf-8')
        fake = self.root / 'fake-process'
        fake.write_text('#!/usr/bin/env bash\nexec sleep 1000\n', encoding='utf-8')
        fake.chmod(0o755)
        (self.root / 'socat').symlink_to(fake)
        env = dict(self.env, PYTHON=str(fake), PATH=str(self.root) + ':' + os.environ['PATH'])
        proc = subprocess.Popen(['bash', str(SALAD / 'start.sh')], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.2)
            self.assertIsNone(proc.poll())
            self.assertFalse((self.root / '.salad-setup-ready').exists())
            self.assertEqual(self.select().returncode, 0)
            self.assertEqual(self.select().returncode, 2)
            pid = int((self.root / 'comfyui.pid').read_text().strip())
            time.sleep(2.2)
            self.assertIsNone(proc.poll())
            os.kill(pid, 15)
            time.sleep(2.2)
            self.assertIsNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


if __name__ == '__main__':
    unittest.main()
