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

    def test_manual_selection_opens_gateway_then_comfy_stop_ends_it(self):
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
            self.assertEqual(proc.wait(timeout=5), 2)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


if __name__ == '__main__':
    unittest.main()
