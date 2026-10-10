#!/usr/bin/env python3
"""Vast.ai ComfyUI manual GUI image sync. Python standard library only."""
from __future__ import annotations
import base64
import csv
import getpass
import hashlib
import ipaddress
import json
import os
import re
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

OUTPUT_DIR = Path(r"D:\po\NSFW_cos\tmp")
POLL_SECONDS = 2
HISTORY_LIMIT = 500
TIMEOUT_SECONDS = 30
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff"}
CSV_FIELDS = ("source", "filename", "subfolder", "local_image", "saved_at", "bytes",
              "sha256", "started_at", "finished_at", "duration_seconds", "status",
              "positive_prompt", "negative_prompt", "image_1", "image_2",
              "filename_prefix", "model", "model_weight_dtype", "clip", "clip_type",
              "clip_device", "vae", "lora", "lora_strength", "lora_enabled",
              "sampling_shift", "cfg_norm_strength", "cfg_norm_pre_cfg",
              "reference_latents_method", "seed", "steps", "cfg", "sampler",
              "scheduler", "denoise")


def workflow_fields(workflow: object) -> dict:
    """Extract the effective scalar settings from the current ComfyUI workflow."""
    if not isinstance(workflow, dict):
        return {}

    def inputs(node_id: str) -> dict:
        node = workflow.get(node_id)
        value = node.get("inputs") if isinstance(node, dict) else None
        return value if isinstance(value, dict) else {}

    def setting(node_id: str, key: str):
        value = inputs(node_id).get(key)
        return value if not isinstance(value, (list, dict)) else None

    lora_enabled = setting("170:168", "value")
    sampler = inputs("170:169")
    return {
        "positive_prompt": setting("170:151", "prompt"),
        "negative_prompt": setting("170:149", "prompt"),
        "image_1": setting("41", "image"),
        "image_2": setting("83", "image"),
        "filename_prefix": setting("9", "filename_prefix"),
        "model": setting("170:161", "unet_name"),
        "model_weight_dtype": setting("170:161", "weight_dtype"),
        "clip": setting("170:162", "clip_name"),
        "clip_type": setting("170:162", "type"),
        "clip_device": setting("170:162", "device"),
        "vae": setting("170:146", "vae_name"),
        "lora": setting("170:153", "lora_name") if lora_enabled is not False else None,
        "lora_strength": setting("170:153", "strength_model") if lora_enabled is not False else None,
        "lora_enabled": lora_enabled,
        "sampling_shift": setting("170:145", "shift"),
        "cfg_norm_strength": setting("170:152", "strength"),
        "cfg_norm_pre_cfg": setting("170:152", "pre_cfg"),
        "reference_latents_method": setting("170:148", "reference_latents_method"),
        "seed": sampler.get("seed") if not isinstance(sampler.get("seed"), (list, dict)) else None,
        "steps": setting("170:165" if lora_enabled else "170:166", "value"),
        "cfg": setting("170:155" if lora_enabled else "170:154", "value"),
        "sampler": setting("170:169", "sampler_name"),
        "scheduler": setting("170:169", "scheduler"),
        "denoise": setting("170:169", "denoise"),
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def fetch(url: str, authorization: str | None = None) -> bytes:
    headers = {"User-Agent": "vast-comfy-sync/1.0"}
    if authorization:
        headers["Authorization"] = authorization
    req = urllib.request.Request(url, headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(req, timeout=TIMEOUT_SECONDS) as response:
        return response.read()


def atomic_json(path: Path, obj: object) -> None:
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.part")
    try:
        with temp.open("xb") as f:
            f.write(json.dumps(obj, ensure_ascii=False, indent=2, default=str).encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def safe_filename(value: str) -> str:
    return re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")[:110] or "image"


def time_fields(history: dict) -> dict:
    events = {}
    for msg in (history.get("status") or {}).get("messages", []):
        if isinstance(msg, (list, tuple)) and len(msg) >= 2 and isinstance(msg[1], dict):
            ts = msg[1].get("timestamp")
            if msg[0] in ("execution_start", "execution_success", "execution_error", "execution_interrupted") and isinstance(ts, (int, float)):
                events[msg[0]] = float(ts)
    start = events.get("execution_start")
    end = next((events[x] for x in ("execution_success", "execution_error", "execution_interrupted") if x in events), None)
    def stamp(ms):
        try:
            return datetime.fromtimestamp(ms / 1000, timezone.utc).astimezone().isoformat(timespec="milliseconds") if ms is not None else None
        except (ValueError, OSError, OverflowError):
            return None
    return {"started_at": stamp(start), "finished_at": stamp(end),
            "duration_seconds": round((end - start) / 1000, 3) if start is not None and end is not None and end >= start else None,
            }


def image_entries(history: dict):
    for node_id, node in (history.get("outputs") or {}).items():
        if not isinstance(node, dict):
            continue
        for item in node.get("images", []):
            if (isinstance(item, dict) and isinstance(item.get("filename"), str)
                    and Path(item["filename"]).suffix.lower() in IMAGE_EXTS
                    and item.get("type", "output") == "output"):
                yield str(node_id), item


def candidate_name(prompt_id: str, image: dict) -> Path:
    base = safe_filename(prompt_id)[:36] + "__" + safe_filename(Path(image["filename"]).name)
    dest = OUTPUT_DIR / base
    index = 2
    while dest.exists():
        stem, suffix = os.path.splitext(base)
        dest = OUTPUT_DIR / f"{stem}_{index}{suffix}"
        index += 1
    return dest


def write_csv_row(path: Path, metadata: dict) -> None:
    row = {key: metadata.get(key) for key in CSV_FIELDS}
    status = metadata.get("status")
    row["status"] = status.get("status_str") if isinstance(status, dict) else None
    row.update(workflow_fields(metadata.get("api_workflow")))
    with path.open("a", encoding="utf-8", newline="") as out:
        csv.DictWriter(out, fieldnames=CSV_FIELDS).writerow(row)
        out.flush()
        os.fsync(out.fileno())


def main() -> int:
    try:
        url = input("ComfyUI の Gateway ドメインまたは SSH 転送 URL: ").strip()
    except EOFError:
        print("接続先が入力されませんでした。")
        return 2
    if url and "://" not in url:
        url = "https://" + url
    parsed = urllib.parse.urlsplit(url)
    try:
        port = parsed.port
    except ValueError:
        port = -1
    try:
        loopback = parsed.hostname == "localhost" or ipaddress.ip_address(parsed.hostname).is_loopback
    except (ValueError, TypeError):
        loopback = parsed.hostname == "localhost"
    valid_gateway = parsed.scheme == "https" and port is None
    valid_ssh = parsed.scheme == "http" and loopback and port is not None and port > 0
    if (not (valid_gateway or valid_ssh) or not parsed.hostname or parsed.username
            or parsed.password or parsed.path not in ("", "/") or parsed.query):
        print("HTTPS Gateway ドメイン、または http://127.0.0.1:ポート の SSH 転送 URL を入力してください。")
        return 2
    url = f"{parsed.scheme}://{parsed.netloc}"
    try:
        username = input("Gateway認証ユーザー (不要なら空欄): ").strip()
        password = getpass.getpass("Gateway認証パスワード: ") if username else ""
    except EOFError:
        print("認証情報の入力が完了しませんでした。")
        return 2
    authorization = ("Basic " + base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")) if username else None
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    state_file = OUTPUT_DIR / ".vast_comfy_sync_state.json"
    server_key = hashlib.sha256(url.encode("utf-8")).hexdigest()
    state = {"server_key": server_key, "done": {}}
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))
        if not isinstance(state, dict) or state.get("server_key") != server_key or not isinstance(state.get("done"), dict):
            print("保存先に別サーバーの同期履歴があります。OUTPUT_DIR を変更してください。")
            return 2
    session_csv = OUTPUT_DIR / f"vast_comfy_sync_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.csv"
    with session_csv.open("x", encoding="utf-8-sig", newline="") as out:
        csv.DictWriter(out, fieldnames=CSV_FIELDS).writeheader()
        out.flush()
        os.fsync(out.fileno())
    print(f"接続先: {url}\n保存先: {OUTPUT_DIR}\nセッションログ: {session_csv.name}\n監視周期: {POLL_SECONDS}秒。終了: Ctrl+C")
    try:
        while True:
            try:
                history_all = json.loads(fetch(f"{url}/history?max_items={HISTORY_LIMIT}", authorization))
                if not isinstance(history_all, dict):
                    raise ValueError("Invalid /history response")
                for prompt_id, history in history_all.items():
                    if not isinstance(history, dict):
                        continue
                    prompt = history.get("prompt")
                    workflow = prompt[2] if isinstance(prompt, list) and len(prompt) > 2 else None
                    extra_data = prompt[3] if isinstance(prompt, list) and len(prompt) > 3 else None
                    for node_id, item in image_entries(history):
                        identity = json.dumps([prompt_id, node_id, item.get("filename"), item.get("subfolder", ""), item.get("type", "output")], ensure_ascii=False)
                        if identity in state["done"]:
                            record = state["done"][identity]
                            if isinstance(record, dict) and isinstance(record.get("image"), str) and (OUTPUT_DIR / record["image"]).is_file():
                                continue
                            del state["done"][identity]
                        qs = urllib.parse.urlencode({"filename": item["filename"], "subfolder": item.get("subfolder") or "", "type": "output"})
                        data = fetch(f"{url}/view?{qs}", authorization)
                        if not data:
                            raise ValueError("Empty image response")
                        dest = candidate_name(str(prompt_id), item)
                        metadata = {"source": "Vast.ai ComfyUI", "prompt_id": prompt_id, "node_id": node_id,
                                    "filename": item["filename"], "subfolder": item.get("subfolder", ""), "local_image": dest.name,
                                    "saved_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                                    "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                    **time_fields(history), "status": history.get("status"),
                                    "api_workflow": workflow, "extra_data": extra_data}
                        with dest.open("xb") as out:
                            out.write(data)
                            out.flush()
                            os.fsync(out.fileno())
                        write_csv_row(session_csv, metadata)
                        state["done"][identity] = {"image": dest.name}
                        atomic_json(state_file, state)
                        print(f"保存: {dest.name} / {session_csv.name}")
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                print(f"再試行: {exc}")
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        print("同期を終了しました。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
