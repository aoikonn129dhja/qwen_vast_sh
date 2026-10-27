"""Exercise the real Bash/flock lock without downloads or environment creation."""

import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('flock'), 'Linux flock required')
class SetupLockTests(unittest.TestCase):
    def read_line(self, process):
        ready, _, _ = select.select([process.stdout], [], [], 10)
        self.assertTrue(ready, 'setup did not reach the expected lock state')
        return process.stdout.readline().decode().strip()

    def test_different_models_and_runtime_roots_share_workspace_lock(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            workspace = Path(directory)
            processes = []
            try:
                for name in ('first', 'second'):
                    runtime_root = workspace / name
                    python = runtime_root / 'environments' / name / 'bin/python'
                    python.parent.mkdir(parents=True)
                    python.symlink_to(sys.executable)
                    env = dict(os.environ, WORKSPACE=str(workspace), RUNTIME_ROOT=str(runtime_root))
                    script = 'source "$1"; runtime_prepare "$2"; printf "acquired\\n"; read -r release'
                    process = subprocess.Popen(
                        ['bash', '-euc', script, 'setup-lock-test',
                         str(ROOT / 'scripts/runtime/bootstrap.sh'), name],
                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    processes.append(process)
                    if name == 'first':
                        self.assertEqual(self.read_line(process), 'acquired')
                    else:
                        self.assertIn('waiting for the workspace setup lock', self.read_line(process))
                        self.assertFalse(select.select([process.stdout], [], [], 0)[0])
                first, second = processes
                first.communicate(b'release\n', timeout=10)
                self.assertEqual(first.returncode, 0)
                self.assertEqual(self.read_line(second), 'acquired')
                second.communicate(b'release\n', timeout=10)
                self.assertEqual(second.returncode, 0)
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
