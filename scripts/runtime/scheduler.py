"""Model process admission and conservative GPU eviction for the ComfyUI gateway."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from urllib.request import Request, urlopen


STATES = {"UNLOADED", "LOADING", "READY", "RUNNING", "UNLOADING", "ERROR"}


def choose_victims(models: dict, requested: str, free_mb: int, required_mb: int) -> list[str]:
    """Choose only idle loaded models, oldest use first, until capacity suffices."""
    if free_mb >= required_mb:
        return []
    victims = []
    candidates = sorted(
        ((name, data) for name, data in models.items()
         if name != requested and data.get("state") == "READY"),
        key=lambda item: item[1].get("last_used", 0),
    )
    for name, data in candidates:
        victims.append(name)
        free_mb += max(0, int(data.get("measured_mb", 0)))
        if free_mb >= required_mb:
            break
    return victims


def gpu_free_mb() -> int:
    result = subprocess.run(
        ["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
        check=True, capture_output=True, text=True, timeout=10,
    )
    values = [int(line.strip()) for line in result.stdout.splitlines() if line.strip()]
    if not values:
        raise RuntimeError("nvidia-smi returned no GPU memory information")
    return min(values)


def process_gpu_mb(pid: int) -> int:
    result = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=pid,used_gpu_memory", "--format=csv,noheader,nounits"],
        check=True, capture_output=True, text=True, timeout=10,
    )
    total = 0
    for line in result.stdout.splitlines():
        fields = [part.strip() for part in line.split(",")]
        if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) == pid and fields[1].isdigit():
            total += int(fields[1])
    return total


def managed_pid(model: dict) -> int | None:
    pid_file = Path(model["pid_file"])
    try:
        pid = int(pid_file.read_text(encoding="ascii").strip())
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
    def __init__(self, root: Path, free_limit_mb: int | None = None):
        self.root = root
        self.models: dict[str, dict] = {}
        self.lock = asyncio.Lock()
        self.free_limit_mb = free_limit_mb
        self.load_registry()

    def load_registry(self) -> None:
        files = list((self.root / "state" / "registered").glob("*.json"))
        active = set()
        for file in files:
            model = json.loads(file.read_text(encoding="utf-8"))
            active.add(model["model_id"])
            if model["model_id"] not in self.models:
                model["state"] = "UNLOADED"
                model["last_used"] = 0
                model["measured_mb"] = 0
                model["loaded"] = False
                self.models[model["model_id"]] = model
            else:
                self.models[model["model_id"]].update(model)
        for model_id in set(self.models) - active:
            del self.models[model_id]

    async def refresh(self) -> None:
        for model in self.models.values():
            if model["runtime_type"] == "cli":
                pid_file = Path(model["pid_file"])
                try:
                    pid = int(pid_file.read_text(encoding="ascii").strip())
                    running = Path(f"/proc/{pid}/cwd").resolve() == Path(model["engine_dir"]).resolve()
                except (OSError, ValueError):
                    running = False
                reserved = model.get("cli_token") and model.get("cli_deadline", 0) > time.monotonic()
                model["state"] = "RUNNING" if running or reserved else "UNLOADED"
                model["measured_mb"] = int(model["gpu_policy"]["reserve_mb"]) if running or reserved else 0
                model["loaded"] = False
                continue
            pid = managed_pid(model)
            if pid is None:
                model["state"] = "UNLOADED"
                model["measured_mb"] = 0
                model["loaded"] = False
                continue
            try:
                model["measured_mb"] = await asyncio.to_thread(process_gpu_mb, pid)
                model["loaded"] = model["loaded"] or model["measured_mb"] >= 1024
                busy = await asyncio.to_thread(queue_busy, model["port"])
                model["state"] = "RUNNING" if busy else "READY" if model["loaded"] else "UNLOADED"
            except (OSError, ValueError, RuntimeError):
                model["state"] = "ERROR"

    async def unload(self, model: dict, required_free_mb: int) -> None:
        if model["state"] == "RUNNING":
            raise RuntimeError("Cannot unload a running model")
        pid = managed_pid(model)
        if pid is None:
            model["state"] = "UNLOADED"
            return
        model["state"] = "UNLOADING"
        try:
            await asyncio.to_thread(api_json, model["port"], "/free", {"unload_models": True, "free_memory": True})
        except (OSError, ValueError):
            pass
        for _ in range(10):
            await asyncio.sleep(0.5)
            after = await asyncio.to_thread(process_gpu_mb, pid)
            model["measured_mb"] = after
            free = await asyncio.to_thread(gpu_free_mb)
            if self.free_limit_mb is not None:
                used = sum(item["measured_mb"] for item in self.models.values())
                free = min(free, max(0, self.free_limit_mb - used))
            if free >= required_free_mb:
                model["state"] = "UNLOADED"
                model["loaded"] = False
                return
        os.kill(pid, signal.SIGTERM)
        for _ in range(30):
            if managed_pid(model) is None:
                model["state"] = "UNLOADED"
                model["measured_mb"] = 0
                model["loaded"] = False
                return
            await asyncio.sleep(1)
        if managed_pid(model) == pid:
            os.kill(pid, signal.SIGKILL)
        model["state"] = "UNLOADED"
        model["measured_mb"] = 0
        model["loaded"] = False

    async def ensure(self, model_id: str, reserve: bool = False, cli_token: str | None = None) -> dict:
        async with self.lock:
            self.load_registry()
            if model_id not in self.models:
                raise KeyError(model_id)
            await self.refresh()
            target = self.models[model_id]
            if target["state"] == "ERROR":
                raise RuntimeError(f"Backend is unresponsive; see {target['log_file']}")
            if target["runtime_type"] == "cli" and target["state"] == "RUNNING":
                raise RuntimeError("CLI model already has a running job")
            required = int(target["gpu_policy"]["reserve_mb"])
            if reserve and not target["loaded"]:
                free = await asyncio.to_thread(gpu_free_mb)
                if self.free_limit_mb is not None:
                    used = sum(model["measured_mb"] for model in self.models.values())
                    free = min(free, max(0, self.free_limit_mb - used))
                attempted = set()
                deadline = time.monotonic() + 3600
                while free < required:
                    victims = [name for name in choose_victims(self.models, model_id, free, required)
                               if name not in attempted]
                    if not victims:
                        if any(model["state"] == "RUNNING" for name, model in self.models.items()
                               if name != model_id) and time.monotonic() < deadline:
                            await asyncio.sleep(2)
                            await self.refresh()
                            free = await asyncio.to_thread(gpu_free_mb)
                            if self.free_limit_mb is not None:
                                used = sum(model["measured_mb"] for model in self.models.values())
                                free = min(free, max(0, self.free_limit_mb - used))
                            continue
                        raise RuntimeError("Insufficient VRAM; use a low-VRAM mode or reduce the model reserve")
                    victim = victims[0]
                    attempted.add(victim)
                    await self.unload(self.models[victim], required)
                    free = await asyncio.to_thread(gpu_free_mb)
                    if self.free_limit_mb is not None:
                        used = sum(model["measured_mb"] for model in self.models.values())
                        free = min(free, max(0, self.free_limit_mb - used))
            if target["runtime_type"] == "cli":
                if not cli_token:
                    raise RuntimeError("CLI admission requires a reservation token")
                target["cli_token"] = cli_token
                target["cli_deadline"] = time.monotonic() + 120
                target["state"] = "RUNNING"
                target["last_used"] = time.monotonic()
                return target
            if managed_pid(target) is None:
                target["state"] = "LOADING"
                with open(target["log_file"], "ab") as log:
                    process = subprocess.Popen(
                        [target["python"], "main.py", "--listen", "127.0.0.1", "--port", str(target["port"]),
                         "--extra-model-paths-config", target["extra_model_paths"],
                         "--input-directory", str(Path(target["shared_comfy_dir"]) / "input"),
                         "--output-directory", str(Path(target["shared_comfy_dir"]) / "output"),
                         "--user-directory", str(Path(target["shared_comfy_dir"]) / "user")],
                        cwd=target["comfy_dir"], stdout=log, stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                Path(target["pid_file"]).write_text(f"{process.pid}\n", encoding="ascii")
                for _ in range(90):
                    try:
                        await asyncio.to_thread(api_json, target["port"], "/system_stats")
                        break
                    except (OSError, ValueError):
                        if process.poll() is not None:
                            target["state"] = "ERROR"
                            raise RuntimeError(f"Backend exited; see {target['log_file']}")
                        await asyncio.sleep(2)
                else:
                    target["state"] = "ERROR"
                    raise RuntimeError(f"Backend failed to start; see {target['log_file']}")
            target["state"] = "READY" if target["loaded"] else "UNLOADED"
            target["last_used"] = time.monotonic()
            return target

    async def heartbeat_cli(self, model_id: str, token: str) -> None:
        async with self.lock:
            model = self.models[model_id]
            if model.get("cli_token") != token:
                raise RuntimeError("CLI reservation token mismatch")
            model["cli_deadline"] = time.monotonic() + 120

    async def release_cli(self, model_id: str, token: str) -> None:
        async with self.lock:
            model = self.models[model_id]
            if model.get("cli_token") != token:
                raise RuntimeError("CLI reservation token mismatch")
            model.pop("cli_token", None)
            model.pop("cli_deadline", None)
            model["state"] = "UNLOADED"
