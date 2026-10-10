import hashlib
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT / 'tmp'

class SaladTests(unittest.TestCase):
    def setUp(self):
        TMP.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def script(self, name, text):
        p = self.path / name
        p.write_text('#!/usr/bin/env bash\n' + text)
        p.chmod(0o755)
        return p

    def test_verified_download_and_resume(self):
        self.script('wget', '''printf '%s\\n' "$*" >> "$CALLS"
while (($#)); do
 if [ "$1" = -O ]; then out="$2"; shift 2; else shift; fi
done
printf '%s' "$CONTENT" > "$out"
exit "${WGET_STATUS:-0}"
''')
        dest = self.path / 'model.bin'
        calls = self.path / 'calls'
        env = dict(os.environ, PATH=str(self.path) + ':' + os.environ['PATH'], CALLS=str(calls), CONTENT='valid')
        digest = hashlib.sha256(b'valid').hexdigest()
        library = ROOT / 'salad/common/download_verified.sh'
        command = 'source "$1"; download_resume_verified https://secret.invalid "$2" "$3"'
        def run():
            return subprocess.run(['bash', '-c', command, 'test', str(library), str(dest), digest], env=env, capture_output=True)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(dest.read_bytes(), b'valid')
        self.assertIn('-c', calls.read_text())
        count = calls.read_text()
        self.assertEqual(run().returncode, 0)
        self.assertEqual(calls.read_text(), count)
        dest.write_bytes(b'old invalid')
        env['CONTENT'] = 'corrupt'
        result = run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(dest.read_bytes(), b'old invalid')
        self.assertFalse(Path(str(dest) + '.part').exists())
        self.assertNotIn(b'secret.invalid', result.stdout + result.stderr)
        env['WGET_STATUS'] = '4'
        self.assertNotEqual(run().returncode, 0)
        self.assertTrue(Path(str(dest) + '.part').exists())
        env.update(CONTENT='valid', WGET_STATUS='0')
        self.assertEqual(run().returncode, 0)

    def supervise(self, fail_child=None, sig=None):
        code = '''echo $$ > "$PID_DIR/{name}.pid"
trap 'exit 0' TERM INT
{action}
'''
        python_code = '''if [ "$1" = main.py ]; then name=comfy; else name=proxy; fi
echo $$ > "$PID_DIR/$name.pid"
trap 'exit 0' TERM INT
if [ "$FAIL_CHILD" = "$name" ]; then sleep 0.1; exit 7; fi
while :; do sleep 0.1; done
'''
        self.script('python', python_code)
        socat_action = 'sleep 0.1; exit 7' if fail_child == 'socat' else 'while :; do sleep 0.1; done'
        self.script('socat', code.format(name='socat', action=socat_action))
        env = dict(os.environ, PATH=str(self.path) + ':' + os.environ['PATH'], PYTHON=str(self.path / 'python'), COMFY_DIR=str(self.path), PID_DIR=str(self.path), FAIL_CHILD=fail_child or '', COMFY_GATEWAY_USER='test', COMFY_GATEWAY_PASSWORD='x' * 20)
        process = subprocess.Popen(['bash', str(ROOT / 'salad/common/start_comfyui.sh')], env=env)
        try:
            if sig:
                deadline = time.monotonic() + 5
                while not (self.path / 'socat.pid').exists():
                    if time.monotonic() > deadline: self.fail('child did not start')
                    time.sleep(0.02)
                process.send_signal(sig)
            result = process.wait(timeout=8)
            for name in ['comfy', 'proxy', 'socat']:
                p = self.path / (name + '.pid')
                if p.exists():
                    with self.assertRaises(ProcessLookupError): os.kill(int(p.read_text()), 0)
            return result
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_comfy_failure_stops_proxy(self):
        self.assertEqual(self.supervise(fail_child='comfy'), 7)

    def test_auth_proxy_failure_stops_comfy(self):
        self.assertEqual(self.supervise(fail_child='proxy'), 7)

    def test_proxy_failure_stops_comfy(self):
        self.assertEqual(self.supervise(fail_child='socat'), 7)

    def test_sigterm_stops_children(self):
        self.assertEqual(self.supervise(sig=signal.SIGTERM), 143)

    def test_sigint_stops_children(self):
        self.assertEqual(self.supervise(sig=signal.SIGINT), 130)

    def test_invalid_ports(self):
        for port in ['0', '65536', 'bad', '8189', '8190']:
            env = dict(os.environ, COMFY_PORT=port, COMFY_GATEWAY_USER='test', COMFY_GATEWAY_PASSWORD='x' * 20)
            result = subprocess.run(['bash', str(ROOT / 'salad/common/start_comfyui.sh')], env=env, capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_missing_gateway_credentials_fail_closed(self):
        env = dict(os.environ, COMFY_GATEWAY_USER='', COMFY_GATEWAY_PASSWORD='')
        result = subprocess.run(['bash', str(ROOT / 'salad/common/start_comfyui.sh')], env=env, capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_ltx_only_publishes_completed_download(self):
        spec = importlib.util.spec_from_file_location('download_models', ROOT / 'vast/models/ltx-2.3-uncensored-v1.4-q4/download_models.py')
        downloader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(downloader)
        with mock.patch.dict('sys.modules', download_models=downloader):
            spec = importlib.util.spec_from_file_location('prepare_ltx', ROOT / 'salad/models/ltx-2.3-uncensored-v1.4-q4/prepare_ltx.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        final = self.path / 'model.gguf'
        final.write_bytes(b'old')
        def fake(files, sizes, base, speed):
            files[0][1].write_bytes(b'valid')
        with mock.patch.object(downloader, 'model_sizes', return_value=[5]), mock.patch.object(downloader, 'download', side_effect=RuntimeError('fail')):
            with self.assertRaises(RuntimeError): module.prepare(self.path, 'owner/repo', 'main', [('remote', 'model.gguf')])
        self.assertEqual(final.read_bytes(), b'old')
        with mock.patch.object(downloader, 'model_sizes', return_value=[5]), mock.patch.object(downloader, 'download', side_effect=fake):
            module.prepare(self.path, 'owner/repo', 'main', [('remote', 'model.gguf')])
            self.assertEqual(final.read_bytes(), b'valid')
            module.prepare(self.path, 'owner/repo', 'main', [('remote', 'model.gguf')])
            self.assertEqual(downloader.download.call_count, 1)

if __name__ == '__main__':
    unittest.main()
