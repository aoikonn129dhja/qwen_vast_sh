import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


START = Path(__file__).resolve().parents[1] / 'start.sh'


class SharedStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / 'models' / 'sample'
        self.model.mkdir(parents=True)
        self.setup = self.model / 'setup.sh'

    def run_start(self, model='sample', password='x' * 20):
        env = dict(os.environ, SALAD_REPO_ROOT=str(self.root), WORKSPACE=str(self.root),
                   MODEL=model, COMFY_GATEWAY_USER='user', COMFY_GATEWAY_PASSWORD=password)
        return subprocess.run(['bash', str(START)], env=env, capture_output=True, timeout=5)

    def test_missing_or_unknown_model(self):
        self.assertEqual(self.run_start(model='').returncode, 2)
        self.assertEqual(self.run_start(model='../sample').returncode, 2)
        self.assertEqual(self.run_start(model='unknown').returncode, 2)

    def test_bad_credentials_prevent_setup(self):
        marker = self.root / 'called'
        self.setup.write_text(f'touch "{marker}"\n', encoding='utf-8')
        self.assertEqual(self.run_start(password='short').returncode, 2)
        self.assertFalse(marker.exists())

    def test_failed_setup_does_not_start_gateway(self):
        marker = self.root / 'called'
        self.setup.write_text(f'touch "{marker}"\nexit 17\n', encoding='utf-8')
        self.assertEqual(self.run_start().returncode, 17)
        self.assertTrue(marker.exists())

    def test_missing_comfy_process_prevents_gateway(self):
        self.setup.write_text('exit 0\n', encoding='utf-8')
        self.assertEqual(self.run_start().returncode, 2)

    def test_comfy_stop_ends_gateway(self):
        self.setup.write_text('sleep 1000 &\necho $! > "$WORKSPACE/comfyui.pid"\n', encoding='utf-8')
        fake = self.root / 'fake-process'
        fake.write_text('#!/usr/bin/env bash\nsleep 1000\n', encoding='utf-8')
        fake.chmod(0o755)
        (self.root / 'socat').symlink_to(fake)
        env = dict(os.environ, SALAD_REPO_ROOT=str(self.root), WORKSPACE=str(self.root),
                   MODEL='sample', COMFY_GATEWAY_USER='user', COMFY_GATEWAY_PASSWORD='x' * 20,
                   PYTHON=str(fake), PATH=str(self.root) + ':' + os.environ['PATH'])
        proc = subprocess.Popen(['bash', str(START)], env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        try:
            pid_file = self.root / 'comfyui.pid'
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pid_file.exists())
            os.kill(int(pid_file.read_text().strip()), 15)
            self.assertEqual(proc.wait(timeout=5), 2)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


if __name__ == '__main__':
    unittest.main()
