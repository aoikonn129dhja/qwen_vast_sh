"""Explicit lifecycle for isolated ComfyUI backends.

Starting a backend selects it for the gateway. Weights reach VRAM on the
first queued workflow; no backend is evicted automatically.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import signal
import subprocess
from urllib.request import Request, urlopen


def managed_pid(model: dict) -> int | None:
    try:
        pid = int(Path(model["pid_file"]).read_text(encoding="ascii").strip())
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ")
        cwd = Path(f"/proc/{pid}/cwd").resolve()
    except (OSError, ValueError):
        return None
    port_arg = f"--port {model['port']}".encode("ascii")
    if b"main.py" not in cmdline or port_arg not in cmdline or cwd != Path(model["comfy_dir"]).resolve():
        return None
    return pid


def api_json(port: int, path: str, payload: dict | None = None) -> dict:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(f"http://127.0.0.1:{port}{path}", data=body)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urlopen(request, timeout=5) as response:
        return json.load(response)


def queue_busy(port: int) -> bool:
    queue = api_json(port, "/queue")
    return bool(queue.get("queue_running") or queue.get("queue_pending"))


class Scheduler:
    """Registry and manual process control, retained under its old import name."""

    def __init__(self, root: Path):
        self.root = root
        self.models: dict[str, dict] = {}
        self.load_registry()

    @property
    def active_path(self) -> Path:
        return self.root / "state" / "active_model"

    def load_registry(self) -> None:
        files = (self.root / "state" / "registered").glob("*.json")
        self.models = {}
        for file in files:
            data = json.loads(file.read_text(encoding="utf-8"))
            self.models[data["model_id"]] = data

    def active_model(self) -> str | None:
        try:
            model_id = self.active_path.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        model = self.models.get(model_id)
        return model_id if model and model["runtime_type"] == "comfyui" else None

    def set_active(self, model_id: str) -> None:
        self.active_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.active_path.with_suffix(".tmp")
        temporary.write_text(model_id + "\n", encoding="utf-8")
        temporary.replace(self.active_path)

    def clear_active(self, model_id: str) -> None:
        if self.active_model() == model_id:
            self.active_path.unlink(missing_ok=True)

    def status(self, model_id: str) -> dict:
        model = self.models[model_id]
        if model["runtime_type"] != "comfyui":
            return {"state": "CLI", "active": False}
        pid = managed_pid(model)
        if pid is None:
            state = "STOPPED"
        else:
            try:
                state = "RUNNING" if queue_busy(model["port"]) else "BACKEND_READY"
            except OSError:
                state = "ERROR"
        return {"state": state, "active": self.active_model() == model_id,
                "port": model["port"], "vram_loaded": None}

    async def start(self, model_id: str) -> dict:
        self.load_registry()
        model = self.models.get(model_id)
        if not model or model["runtime_type"] != "comfyui":
            raise ValueError(f"Unknown ComfyUI model: {model_id}")
        if managed_pid(model) is None:
            with open(model["log_file"], "ab") as log:
                process = subprocess.Popen(
                    [model["python"], "main.py", "--listen", "127.0.0.1", "--port", str(model["port"]),
                     "--extra-model-paths-config", model["extra_model_paths"],
                     "--input-directory", str(Path(model["shared_comfy_dir"]) / "input"),
                     "--output-directory", str(Path(model["shared_comfy_dir"]) / "output"),
                     "--user-directory", str(Path(model["shared_comfy_dir"]) / "user")],
                    cwd=model["comfy_dir"], stdout=log, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            Path(model["pid_file"]).write_text(f"{process.pid}\n", encoding="ascii")
            for _ in range(90):
                try:
                    await asyncio.to_thread(api_json, model["port"], "/system_stats")
                    break
                except (OSError, ValueError):
                    if process.poll() is not None:
                        raise RuntimeError(f"Backend exited; see {model['log_file']}")
                    await asyncio.sleep(2)
            else:
                raise RuntimeError(f"Backend failed to start; see {model['log_file']}")
        else:
            await asyncio.to_thread(api_json, model["port"], "/system_stats")
        self.set_active(model_id)
        return model

    async def unload(self, model_id: str) -> None:
        self.load_registry()
        model = self.models.get(model_id)
        if not model or model["runtime_type"] != "comfyui":
            raise ValueError(f"Unknown ComfyUI model: {model_id}")
        pid = managed_pid(model)
        if pid is None:
            self.clear_active(model_id)
            return
        if await asyncio.to_thread(queue_busy, model["port"]):
            raise RuntimeError("The model has a running or pending job; unload was refused")
        self.clear_active(model_id)
        os.kill(pid, signal.SIGTERM)
        for _ in range(30):
            if managed_pid(model) is None:
                Path(model["pid_file"]).unlink(missing_ok=True)
                return
            await asyncio.sleep(1)
        raise RuntimeError(f"Backend did not stop; inspect PID {pid}. No forced kill was sent")
