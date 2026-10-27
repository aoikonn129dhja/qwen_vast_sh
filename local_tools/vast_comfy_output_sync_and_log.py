#!/usr/bin/env python3
"""Vast.ai and SaladCloud ComfyUI image and video sync. Standard library only."""
from __future__ import annotations
import base64
import csv
import getpass
import hashlib
import ipaddress
import json
import os
import re
import sys
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
VIDEO_EXTS = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v"}
CSV_FIELDS = ("source", "filename", "subfolder", "media_type", "local_file", "local_image", "saved_at", "bytes",
              "sha256", "started_at", "finished_at", "duration_seconds", "status",
              "positive_prompt", "negative_prompt", "image_1", "image_2",
              "filename_prefix", "model", "model_weight_dtype", "clip", "clip_type",
              "clip_device", "vae", "lora", "lora_strength", "lora_enabled",
              "sampling_shift", "cfg_norm_strength", "cfg_norm_pre_cfg",
              "reference_latents_method", "seed", "steps", "cfg", "sampler",
              "scheduler", "denoise")


def gateway_credentials() -> tuple[str, str]:
    """Read Salad Gateway credentials without displaying them."""
    env_path = Path(__file__).resolve().parents[1] / ".env"
    values: dict[str, str] = {}
    if env_path.is_file():
        for line in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            key, sep, value = line.partition("=")
            if not sep:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            values[key.strip()] = value

    def setting(*keys: str) -> str:
        for key in keys:
            found = os.environ.get(key) or values.get(key)
            if found:
                return found
        return ""

    return (setting("SALAD_COMFY_GATEWAY_USER", "COMFY_GATEWAY_USER"),
            setting("SALAD_COMFY_GATEWAY_PASSWORD", "SALADA_COMFY_GATEWAY_PASSWORD",
                    "COMFY_GATEWAY_PASSWORD"))


def is_salad_gateway(hostname: str | None) -> bool:
    return bool(hostname and hostname.lower().endswith(".salad.cloud"))


def log(message: str) -> None:
    """Print each terminal log line with the current local date and time."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    for line in message.splitlines():
        print(f"[{timestamp}] {line}", flush=True)


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

    checkpoint = workflow.get("1")
    checkpoint_fields = {}
    if isinstance(checkpoint, dict) and checkpoint.get("class_type") == "CheckpointLoaderSimple":
        checkpoint_fields = {
            "positive_prompt": setting("3", "prompt"),
            "negative_prompt": setting("4", "prompt"),
            "image_1": setting("8", "image"),
            "filename_prefix": setting("10", "filename_prefix"),
            "model": setting("1", "ckpt_name"),
            "seed": setting("2", "seed"),
            "steps": setting("2", "steps"),
            "cfg": setting("2", "cfg"),
            "sampler": setting("2", "sampler_name"),
            "scheduler": setting("2", "scheduler"),
            "denoise": setting("2", "denoise"),
        }

    lora_enabled = setting("170:168", "value")
    sampler = inputs("170:169")
    fields = {
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
    def node_by_type(*types: str) -> dict:
        for node in workflow.values():
            if isinstance(node, dict) and node.get("class_type") in types:
                value = node.get("inputs")
                return value if isinstance(value, dict) else {}
        return {}

    def scalar(value):
        return value if not isinstance(value, (list, dict)) else None

    sampler_inputs = node_by_type("KSampler", "KSamplerAdvanced")
    if sampler_inputs:
        for field, input_name in (("positive_prompt", "positive"), ("negative_prompt", "negative")):
            link = sampler_inputs.get(input_name)
            if isinstance(link, list) and link:
                prompt_inputs = inputs(str(link[0]))
                fields[field] = scalar(prompt_inputs.get("prompt")) or scalar(prompt_inputs.get("text")) or fields[field]
        for field, input_name in (("seed", "seed"), ("steps", "steps"), ("cfg", "cfg"),
                                  ("sampler", "sampler_name"), ("scheduler", "scheduler"),
                                  ("denoise", "denoise")):
            value = scalar(sampler_inputs.get(input_name))
            if value is not None:
                fields[field] = value

    model_inputs = node_by_type("CheckpointLoaderSimple", "UNETLoader")
    if model_inputs:
        fields["model"] = scalar(model_inputs.get("ckpt_name")) or scalar(model_inputs.get("unet_name"))
        fields["model_weight_dtype"] = scalar(model_inputs.get("weight_dtype"))
    image_inputs = node_by_type("LoadImageWithFilename", "LoadImage")
    if image_inputs:
        fields["image_1"] = scalar(image_inputs.get("image"))
    save_inputs = node_by_type("SaveImage", "SaveImageAdvanced")
    if save_inputs and "filename_prefix" in save_inputs:
        fields["filename_prefix"] = scalar(save_inputs["filename_prefix"])
    for key, value in checkpoint_fields.items():
        if fields.get(key) is None and value is not None:
            fields[key] = value
    return fields


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


def media_entries(history: dict):
    """Classify saved media by extension; SaveVideo also uses the images array."""
    for node_id, node in (history.get("outputs") or {}).items():
        if not isinstance(node, dict):
            continue
        seen = set()
        for collection in ("images", "videos", "gifs"):
            items = node.get(collection)
            if not isinstance(items, list):
                continue
            for item in items:
                if (not isinstance(item, dict) or not isinstance(item.get("filename"), str)
                        or item.get("type", "output") != "output"):
                    continue
                extension = Path(item["filename"]).suffix.lower()
                if extension in VIDEO_EXTS:
                    media_type = "video"
                elif extension in IMAGE_EXTS:
                    media_type = "image"
                else:
                    continue
                identity = (item["filename"], item.get("subfolder") or "", media_type)
                if identity not in seen:
                    seen.add(identity)
                    yield str(node_id), item, media_type


def model_label(workflow: object) -> str:
    """Identify an actual model filename in the API workflow, if present."""
    if isinstance(workflow, dict):
        for node in workflow.values():
            if not isinstance(node, dict) or not isinstance(node.get("inputs"), dict):
                continue
            for key in ("unet_name", "ckpt_name", "model_name"):
                value = node["inputs"].get(key)
                if isinstance(value, str) and value.strip():
                    return safe_filename(Path(value.replace("\\", "/")).stem)[:70]
    return "ComfyUI_model_unknown"


def image_directory(workflow: object, now: datetime) -> Path:
    """Reuse an existing folder for this calendar day and model across sessions."""
    label = model_label(workflow)
    day = now.strftime("%Y%m%d")
    existing = sorted(
        item for item in OUTPUT_DIR.glob(f"{day}????_{label}")
        if item.is_dir() and re.fullmatch(r"\d{12}_" + re.escape(label), item.name)
    )
    destination = existing[0] if existing else OUTPUT_DIR / f"{now:%Y%m%d%H%M}_{label}"
    destination.mkdir(parents=True, exist_ok=True)
    return destination


def candidate_name(prompt_id: str, image: dict, directory: Path) -> Path:
    base = safe_filename(prompt_id)[:36] + "__" + safe_filename(Path(image["filename"]).name)
    dest = directory / base
    index = 2
    while dest.exists():
        stem, suffix = os.path.splitext(base)
        dest = directory / f"{stem}_{index}{suffix}"
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


def select_sync_state(output_dir: Path, server_key: str, salad: bool = False) -> tuple[Path, dict]:
    """Reuse this server's history, or reserve an unused numbered history."""
    output_dir.mkdir(parents=True, exist_ok=True)
    if salad:
        legacy = output_dir / ".salad_comfy_sync_state.json"
        if legacy.is_file():
            try:
                old_state = json.loads(legacy.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeError):
                old_state = None
            if (isinstance(old_state, dict) and old_state.get("server_key") == server_key
                    and isinstance(old_state.get("done"), dict)):
                return legacy, old_state
    pattern = re.compile(r"\.vast_comfy_sync_state(?:_([1-9][0-9]*))?\.json")
    while True:
        histories = {}
        for path in output_dir.glob(".vast_comfy_sync_state*.json"):
            match = pattern.fullmatch(path.name)
            if match:
                histories[int(match.group(1) or 0)] = path
        for number, path in sorted(histories.items()):
            try:
                state = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeError):
                continue
            if (isinstance(state, dict) and state.get("server_key") == server_key
                    and isinstance(state.get("done"), dict)):
                return path, state
        number = 0
        while number in histories:
            number += 1
        suffix = f"_{number}" if number else ""
        path = output_dir / f".vast_comfy_sync_state{suffix}.json"
        state = {"server_key": server_key, "done": {}}
        try:
            with path.open("x", encoding="utf-8") as out:
                json.dump(state, out, ensure_ascii=False, indent=2)
                out.flush()
                os.fsync(out.fileno())
        except FileExistsError:
            continue
        return path, state


def main(salad: bool = False) -> int:
    try:
        url = input("ComfyUI の Gateway ドメインまたは SSH 転送 URL: ").strip()
    except EOFError:
        log("接続先が入力されませんでした。")
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
        log("HTTPS Gateway ドメイン、または http://127.0.0.1:ポート の SSH 転送 URL を入力してください。")
        return 2
    url = f"{parsed.scheme}://{parsed.netloc}"
    salad = salad or is_salad_gateway(parsed.hostname)
    try:
        username, password = gateway_credentials() if salad else ("", "")
        if not username:
            username = input("Gateway認証ユーザー (不要なら空欄): ").strip()
        if username and not password:
            password = getpass.getpass("Gateway認証パスワード: ")
    except EOFError:
        log("認証情報の入力が完了しませんでした。")
        return 2
    authorization = ("Basic " + base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")) if username else None
    server_key = hashlib.sha256(url.encode("utf-8")).hexdigest()
    state_file, state = select_sync_state(OUTPUT_DIR, server_key, salad)
    source = "SaladCloud ComfyUI" if salad else "Vast.ai ComfyUI"
    csv_prefix = "salad" if salad else "vast"
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    session_csvs: dict[Path, Path] = {}
    log(f"接続先: {url}\n保存先の親ディレクトリ: {OUTPUT_DIR}\n監視周期: {POLL_SECONDS}秒。終了: Ctrl+C")
    log(f"同期履歴: {state_file.name}")
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
                    for node_id, item, media_type in media_entries(history):
                        identity = json.dumps([prompt_id, node_id, media_type, item.get("filename"), item.get("subfolder", ""), item.get("type", "output")], ensure_ascii=False)
                        if salad and media_type == "image" and identity not in state["done"]:
                            old_identity = json.dumps([prompt_id, node_id, item.get("filename"), item.get("subfolder", ""), item.get("type", "output")], ensure_ascii=False)
                            old_record = state["done"].get(old_identity)
                            if isinstance(old_record, dict) and isinstance(old_record.get("image"), str):
                                state["done"][identity] = {"file": old_record["image"]}
                        if identity in state["done"]:
                            record = state["done"][identity]
                            if isinstance(record, dict) and isinstance(record.get("file", record.get("image")), str) and (OUTPUT_DIR / record.get("file", record.get("image"))).is_file():
                                continue
                            del state["done"][identity]
                        qs = urllib.parse.urlencode({"filename": item["filename"], "subfolder": item.get("subfolder") or "", "type": "output"})
                        data = fetch(f"{url}/view?{qs}", authorization)
                        if not data:
                            raise ValueError("Empty media response")
                        directory = image_directory(workflow, datetime.now())
                        dest = candidate_name(str(prompt_id), item, directory)
                        session_csv = session_csvs.get(directory)
                        if session_csv is None:
                            session_csv = directory / f"{csv_prefix}_comfy_sync_{session_id}.csv"
                            with session_csv.open("x", encoding="utf-8-sig", newline="") as out:
                                csv.DictWriter(out, fieldnames=CSV_FIELDS).writeheader()
                                out.flush()
                                os.fsync(out.fileno())
                            session_csvs[directory] = session_csv
                        metadata = {"source": source, "prompt_id": prompt_id, "node_id": node_id,
                                    "filename": item["filename"], "subfolder": item.get("subfolder", ""),
                                    "media_type": media_type, "local_file": str(dest.relative_to(OUTPUT_DIR)),
                                    "local_image": str(dest.relative_to(OUTPUT_DIR)) if media_type == "image" else None,
                                    "saved_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                                    "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                    **time_fields(history), "status": history.get("status"),
                                    "api_workflow": workflow, "extra_data": extra_data}
                        with dest.open("xb") as out:
                            out.write(data)
                            out.flush()
                            os.fsync(out.fileno())
                        write_csv_row(session_csv, metadata)
                        state["done"][identity] = {"file": str(dest.relative_to(OUTPUT_DIR))}
                        atomic_json(state_file, state)
                        log(f"保存: {dest.relative_to(OUTPUT_DIR)} / {session_csv.name}")
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                log(f"再試行: {exc}")
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        log("同期を終了しました。")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] != "--salad"):
        raise SystemExit("Usage: python vast_comfy_output_sync_and_log.py [--salad]")
    raise SystemExit(main(salad="--salad" in sys.argv[1:]))
