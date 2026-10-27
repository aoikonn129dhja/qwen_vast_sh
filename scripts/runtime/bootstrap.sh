#!/usr/bin/env bash
# Source this file from a model setup script, then call runtime_prepare MODEL_ID.

runtime_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

runtime_prepare() {
    local model_id="$1"
    [[ "$model_id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || runtime_die 'Invalid model ID.' || return 1
    WORKSPACE="${WORKSPACE:-/workspace}"
    RUNTIME_ROOT="${RUNTIME_ROOT:-$WORKSPACE/.qwen_runtime}"
    SHARED_COMFY_DIR="$WORKSPACE/ComfyUI"
    RUNTIME_INSTANCE="$RUNTIME_ROOT/instances/$model_id"
    RUNTIME_ENV="$RUNTIME_ROOT/environments/$model_id"
    COMFY_DIR="$RUNTIME_INSTANCE/ComfyUI"
    PYTHON="$RUNTIME_ENV/bin/python"
    COMFY_LOG="$RUNTIME_ROOT/logs/$model_id.log"
    RUNTIME_PID_FILE="$RUNTIME_ROOT/state/$model_id.pid"
    mkdir -p "$RUNTIME_ROOT/locks" "$RUNTIME_ROOT/logs" "$RUNTIME_ROOT/state" "$RUNTIME_INSTANCE" "$SHARED_COMFY_DIR"
    command -v flock >/dev/null 2>&1 || runtime_die 'flock is required.' || return 1
    # All models share downloads, user data and /workspace/bin/uv.
    # Use the workspace (not the model or runtime root) as the lock scope.
    exec {RUNTIME_SETUP_LOCK}>"$WORKSPACE/.qwen-setup.lock"
    if ! flock -xn "$RUNTIME_SETUP_LOCK"; then
        printf 'Another model setup is running; waiting for the workspace setup lock.\n'
        flock -x "$RUNTIME_SETUP_LOCK"
    fi
    if [ ! -x "$PYTHON" ]; then
        if command -v uv >/dev/null 2>&1; then
            uv venv --python "${BASE_PYTHON:-/venv/main/bin/python}" --seed "$RUNTIME_ENV"
        elif [ -x "$WORKSPACE/bin/uv" ]; then
            "$WORKSPACE/bin/uv" venv --python "${BASE_PYTHON:-/venv/main/bin/python}" --seed "$RUNTIME_ENV"
        else
            "${BASE_PYTHON:-/venv/main/bin/python}" -m venv "$RUNTIME_ENV"
        fi
    fi
    export WORKSPACE RUNTIME_ROOT SHARED_COMFY_DIR RUNTIME_INSTANCE RUNTIME_ENV COMFY_DIR PYTHON COMFY_LOG RUNTIME_PID_FILE
}

runtime_link_data() {
    [ -f "$COMFY_DIR/main.py" ] || runtime_die "ComfyUI instance is missing: $COMFY_DIR" || return 1
    local name
    for name in models input output user; do
        mkdir -p "$SHARED_COMFY_DIR/$name"
    done
    "$PYTHON" - "$SHARED_COMFY_DIR" "$RUNTIME_INSTANCE/extra_model_paths.yaml" <<'PY'
from pathlib import Path
import sys

base = Path(sys.argv[1])
destination = Path(sys.argv[2])
categories = (
    'checkpoints', 'configs', 'loras', 'vae', 'text_encoders', 'diffusion_models',
    'clip_vision', 'style_models', 'embeddings', 'diffusers', 'vae_approx',
    'controlnet', 'gligen', 'upscale_models', 'latent_upscale_models',
    'hypernetworks', 'photomaker', 'classifiers', 'model_patches',
    'audio_encoders', 'background_removal', 'frame_interpolation',
    'geometry_estimation', 'optical_flow', 'detection', 'LLM',
)
content = 'qwen_runtime:\n  base_path: ' + str(base) + '\n  is_default: true\n'
content += ''.join(f'  {category}: models/{category}\n' for category in categories)
temporary = destination.with_suffix('.tmp')
temporary.write_text(content, encoding='utf-8')
temporary.replace(destination)
PY
    local extension_source extension_target
    extension_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/comfy_extension"
    extension_target="$COMFY_DIR/custom_nodes/qwen-runtime"
    mkdir -p "$COMFY_DIR/custom_nodes"
    if [ -L "$extension_target" ]; then
        [ "$(readlink -f "$extension_target")" = "$(readlink -f "$extension_source")" ] || runtime_die "Unexpected extension link: $extension_target" || return 1
    elif [ -e "$extension_target" ]; then
        runtime_die "Existing runtime extension path: $extension_target" || return 1
    else
        ln -s "$extension_source" "$extension_target"
    fi
}

runtime_clone_comfy() {
    local config="$1" commit current
    commit="$("$PYTHON" - "$config" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['comfy_commit'])
PY
)"
    if [ -f "$COMFY_DIR/main.py" ] && [ -d "$COMFY_DIR/.git" ]; then
        current="$(git -C "$COMFY_DIR" rev-parse HEAD)"
        [ "$current" = "$commit" ] || runtime_die "Instance commit differs: $current (expected $commit)" || return 1
    elif [ -e "$COMFY_DIR" ]; then
        runtime_die "Incomplete instance is preserved for inspection: $COMFY_DIR" || return 1
    else
        git init -q "$COMFY_DIR"
        git -C "$COMFY_DIR" remote add origin https://github.com/Comfy-Org/ComfyUI.git
        git -C "$COMFY_DIR" fetch -q --depth 1 origin "$commit"
        git -C "$COMFY_DIR" checkout -q --detach FETCH_HEAD
    fi
    runtime_link_data
}

runtime_clone_node() {
    local url="$1" commit="$2" destination="$3"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || runtime_die 'Custom node commit must be a 40-character SHA.' || return 1
    if [ -d "$destination/.git" ]; then
        [ "$(git -C "$destination" remote get-url origin 2>/dev/null || true)" = "$url" ] || runtime_die "Custom node remote differs: $destination" || return 1
        [ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ] || runtime_die "Custom node commit differs: $destination" || return 1
    elif [ -e "$destination" ]; then
        runtime_die "Existing custom node is preserved: $destination" || return 1
    else
        mkdir -p "$(dirname -- "$destination")"
        git init -q "$destination"
        git -C "$destination" remote add origin "$url"
        git -C "$destination" fetch -q --depth 1 origin "$commit"
        git -C "$destination" checkout -q --detach FETCH_HEAD
        [ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ] || runtime_die "Custom node checkout failed: $destination" || return 1
    fi
}

runtime_uv_install_requirements() {
    local uv="$1" python="$2" requirements="$3" backend="${4:-}" constraints="${5:-}"
    local options=()
    [ -z "$backend" ] || options+=(--torch-backend "$backend")
    [ -z "$constraints" ] || options+=(--constraint "$constraints")
    "$uv" pip install --python "$python" "${options[@]}" -r "$requirements"
}

runtime_pid_valid() {
    local pid="$1" port="$2" command_line cwd
    [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] || return 1
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$command_line" == *main.py* && "$command_line" == *"--port $port"* && "$cwd" == "$COMFY_DIR" ]]
}

runtime_port() {
    "$PYTHON" - "$1" <<'PY'
import json, sys
port = json.load(open(sys.argv[1], encoding='utf-8'))['port']
if not isinstance(port, int) or not 1024 <= port <= 65535:
    raise SystemExit('Invalid runtime port')
print(port)
PY
}

runtime_start() {
    local port="$1" pid
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || runtime_die 'Invalid internal port.' || return 1
    if [ -s "$RUNTIME_PID_FILE" ]; then
        read -r pid < "$RUNTIME_PID_FILE"
        if runtime_pid_valid "$pid" "$port"; then
            if "$PYTHON" - "$port" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2).read(1)
PY
            then return 0; fi
            runtime_die "Managed process is alive but internal port $port does not respond" || return 1
        fi
    fi
    (exec {RUNTIME_SETUP_LOCK}>&-; cd "$COMFY_DIR"; nohup "$PYTHON" main.py --listen 127.0.0.1 --port "$port" \
        --extra-model-paths-config "$RUNTIME_INSTANCE/extra_model_paths.yaml" \
        --input-directory "$SHARED_COMFY_DIR/input" \
        --output-directory "$SHARED_COMFY_DIR/output" \
        --user-directory "$SHARED_COMFY_DIR/user" \
        > "$COMFY_LOG" 2>&1 & echo $! > "$RUNTIME_PID_FILE")
    read -r pid < "$RUNTIME_PID_FILE"
    for _ in $(seq 1 90); do
        if "$PYTHON" - "$port" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2).read(1)
PY
        then return 0; fi
        runtime_pid_valid "$pid" "$port" || runtime_die "ComfyUI exited; see $COMFY_LOG" || return 1
        sleep 2
    done
    runtime_die "ComfyUI did not respond; see $COMFY_LOG"
}

runtime_register() {
    local config="$1" port
    [ -f "$config" ] || runtime_die "Runtime config is missing: $config" || return 1
    mkdir -p "$RUNTIME_ROOT/state/registered"
    "$PYTHON" - "$config" "$SHARED_COMFY_DIR/user/default/workflows" <<'PY'
import json
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
destination_dir = Path(sys.argv[2])
config = json.loads(config_path.read_text(encoding='utf-8'))
destination_dir.mkdir(parents=True, exist_ok=True)
for name in config['workflows']:
    destination = destination_dir / name
    if destination.exists():
        continue
    for source in (config_path.parent / 'workflows' / name, config_path.parent / name):
        if source.is_file():
            data = json.loads(source.read_text(encoding='utf-8'))
            data.setdefault('extra', {})['qwen_model_id'] = config['model_id']
            temporary = destination.with_suffix(destination.suffix + '.tmp')
            temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            temporary.replace(destination)
            break
PY
    "$PYTHON" - "$config" "$RUNTIME_ROOT/state/registered" "$RUNTIME_PID_FILE" "$COMFY_DIR" "$PYTHON" "$COMFY_LOG" "$SHARED_COMFY_DIR" "$RUNTIME_INSTANCE/extra_model_paths.yaml" <<'PY'
import json
from pathlib import Path
import sys

config, registry, pid_file, comfy_dir, python, log_file, shared_comfy_dir, extra_model_paths = sys.argv[1:]
data = json.loads(Path(config).read_text(encoding='utf-8'))
required = {'model_id', 'runtime_type', 'comfy_commit', 'python_requirements',
            'model_paths', 'custom_nodes', 'workflows', 'gpu_policy',
            'unload_strategy', 'port'}
missing = required - data.keys()
if missing:
    raise SystemExit(f'Missing runtime fields: {sorted(missing)}')
if data['runtime_type'] != 'comfyui':
    raise SystemExit('Only ComfyUI runtimes can register with this gateway')
data.update(pid_file=pid_file, comfy_dir=comfy_dir, python=python, log_file=log_file,
            shared_comfy_dir=shared_comfy_dir, extra_model_paths=extra_model_paths)
destination = Path(registry) / (data['model_id'] + '.json')
temporary = destination.with_suffix('.tmp')
temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
temporary.replace(destination)
print(data['port'])
PY
}

runtime_register_cli() {
    local config="$1" engine_dir="$2"
    [ -f "$config" ] && [ -d "$engine_dir" ] || runtime_die 'CLI configuration or engine is missing.' || return 1
    mkdir -p "$RUNTIME_ROOT/state/registered"
    "$PYTHON" - "$config" "$RUNTIME_ROOT/state/registered" "$engine_dir" "$PYTHON" "$RUNTIME_ROOT/state/$(basename -- "$MODEL_DIR").cli.pid" <<'PY'
import json
from pathlib import Path
import sys
config, registry, engine, python, pid_file = sys.argv[1:]
data = json.loads(Path(config).read_text(encoding='utf-8'))
if data['runtime_type'] != 'cli':
    raise SystemExit('CLI registration requires runtime_type=cli')
data.update(engine_dir=engine, python=python, pid_file=pid_file)
destination = Path(registry) / (data['model_id'] + '.json')
temporary = destination.with_suffix('.tmp')
temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
temporary.replace(destination)
PY
}

runtime_gateway_start() (
    exec 9>"$RUNTIME_ROOT/locks/gateway.start.lock"
    flock -x 9
    if [ -n "${RUNTIME_SETUP_LOCK:-}" ]; then exec {RUNTIME_SETUP_LOCK}>&-; fi
    local script pid gateway_pid_file="$RUNTIME_ROOT/state/gateway.pid"
    script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/gateway.py"
    if [ -s "$gateway_pid_file" ]; then
        read -r pid < "$gateway_pid_file"
        if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] \
            && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$script"; then
            if "$PYTHON" - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen('http://127.0.0.1:8188/runtime/healthz', timeout=2).read(1)
PY
            then return 0; fi
            runtime_die 'Managed Gateway process is alive but does not respond.' || return 1
        fi
    fi
    nohup "$PYTHON" "$script" --root "$RUNTIME_ROOT" --port 8188 \
        > "$RUNTIME_ROOT/logs/gateway.log" 2>&1 9>&- &
    echo "$!" > "$gateway_pid_file"
    for _ in $(seq 1 30); do
        if "$PYTHON" - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen('http://127.0.0.1:8188/runtime/healthz', timeout=2).read(1)
PY
        then return 0; fi
        sleep 1
    done
    runtime_die "Gateway did not start; see $RUNTIME_ROOT/logs/gateway.log"
)
