"""Run the restart script against a local HTTP fixture, without GPU or models."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/runtime'))
from scheduler import managed_pid


@unittest.skipUnless(sys.platform == 'linux', 'Linux /proc required')
class RestartTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.comfy = self.root / 'instances/sample/ComfyUI'
        self.comfy.mkdir(parents=True)
        (self.root / 'state').mkdir()
        python = self.root / 'environments/sample/bin/python'
        python.parent.mkdir(parents=True)
        python.symlink_to(sys.executable)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        (self.comfy / 'main.py').write_text('''
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        busy = pathlib.Path('busy').exists()
        payload = {'system': {'comfyui_version': 'fixture'}} if self.path == '/system_stats' else {'queue_running': [1] if busy else [], 'queue_pending': []}
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())
    def log_message(self, *args):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[sys.argv.index('--port') + 1])), Handler).serve_forever()
''', encoding='utf-8')
        self.process = subprocess.Popen(
            [str(python), 'main.py', '--port', str(self.port)], cwd=self.comfy,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        self.pid_file = self.root / 'state/sample.pid'
        self.pid_file.write_text(str(self.process.pid))
        self.addCleanup(self.stop_backends)
        self.wait_ready()

    def stop_backends(self):
        for pid in {self.process.pid, int(self.pid_file.read_text())}:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.process.wait(timeout=5)

    def wait_ready(self):
        for _ in range(100):
            try:
                with urlopen(f'http://127.0.0.1:{self.port}/system_stats', timeout=0.1):
                    return
            except OSError:
                time.sleep(0.05)
        self.fail('fixture did not start')

    def restart(self):
        return subprocess.run(['bash', str(ROOT / 'scripts/restart_comfyui.sh')],
                              env=dict(os.environ, RUNTIME_ROOT=str(self.root)),
                              capture_output=True, text=True, timeout=20)

    def test_restart_updates_pid_and_can_be_repeated(self):
        for _ in range(2):
            before = int(self.pid_file.read_text())
            result = self.restart()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after = int(self.pid_file.read_text())
            self.assertNotEqual(before, after)
            self.assertEqual(managed_pid({'pid_file': str(self.pid_file),
                                         'port': self.port, 'comfy_dir': str(self.comfy)}), after)

    def test_busy_queue_is_not_stopped(self):
        (self.comfy / 'busy').touch()
        result = self.restart()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restart refused', result.stderr)
        self.assertIsNone(self.process.poll())
        self.assertEqual(int(self.pid_file.read_text()), self.process.pid)


if __name__ == '__main__':
    unittest.main()
