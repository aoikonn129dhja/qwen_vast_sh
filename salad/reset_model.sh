#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
READY_FILE="${SALAD_READY_FILE:-$WORKSPACE/.salad-setup-ready}"
ROOT="$WORKSPACE/.qwen_runtime"
MODEL="${1:-}"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] && [ "$#" -eq 1 ] || fail 'Specify exactly one model ID.'
LOCK="$WORKSPACE/.salad-setup-lock"
mkdir "$LOCK" 2>/dev/null || fail 'Another model setup or reset is running.'
trap 'rmdir "$LOCK"' EXIT
REGISTRY="$ROOT/state/registered/$MODEL.json"
[ -f "$REGISTRY" ] || fail "Model is not registered: $MODEL"

"${PYTHON:-/venv/main/bin/python}" - "$REGISTRY" <<'PY'
import json, os, pathlib, signal, sys, time, urllib.request
registry = pathlib.Path(sys.argv[1])
data = json.loads(registry.read_text(encoding='utf-8'))
if data['model_id'] != registry.stem:
    raise SystemExit('Registry model ID mismatch')
pid_file = pathlib.Path(data['pid_file'])
if pid_file.exists():
    pid = int(pid_file.read_text().strip())
    try:
        cmdline = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ')
        cwd = pathlib.Path(f'/proc/{pid}/cwd').resolve()
    except OSError:
        pid = None
    if pid is not None:
        if data['runtime_type'] == 'cli':
            if cwd == pathlib.Path(data['engine_dir']).resolve():
                raise SystemExit('CLI inference is still running; reset refused')
            raise SystemExit('CLI PID does not identify the managed engine')
        port_arg = f"--port {data['port']}".encode('ascii')
        if b'main.py' not in cmdline or port_arg not in cmdline or cwd != pathlib.Path(data['comfy_dir']).resolve():
            raise SystemExit('PID does not identify the managed model process')
        with urllib.request.urlopen(f"http://127.0.0.1:{data['port']}/queue", timeout=5) as response:
            queue = json.load(response)
        if queue.get('queue_running') or queue.get('queue_pending'):
            raise SystemExit('Model has running or queued jobs; reset refused')
        os.kill(pid, signal.SIGTERM)
        for _ in range(30):
            if not pathlib.Path(f'/proc/{pid}').exists():
                break
            try:
                state = pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
                if state in {'Z', 'X'}:
                    break
            except OSError:
                break
            time.sleep(1)
        else:
            raise SystemExit('Managed process did not stop')
pid_file.unlink(missing_ok=True)
PY
rm -f -- "$REGISTRY"
if [ -f "$READY_FILE" ]; then
    grep -Fxv "$MODEL" "$READY_FILE" > "$READY_FILE.part" || true
    mv -- "$READY_FILE.part" "$READY_FILE"
fi
printf 'Model unregistered; disk data and environment were preserved: %s\n' "$MODEL"
