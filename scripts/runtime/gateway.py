#!/usr/bin/env python3
"""Select isolated ComfyUI backends from workflows; unload only on request."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import asynccontextmanager
import fcntl
import json
from pathlib import Path

from aiohttp import ClientError, ClientSession, WSMsgType, web

from scheduler import Scheduler

SCHEDULER_KEY = web.AppKey("scheduler", Scheduler)
SESSION_KEY = web.AppKey("session", ClientSession)
CONTROL_KEY = web.AppKey("control", asyncio.Lock)

HOP_HEADERS = {"authorization", "connection", "content-length", "host", "keep-alive", "origin", "proxy-authenticate",
               "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"}


@asynccontextmanager
async def runtime_lock(request: web.Request):
    async with request.app[CONTROL_KEY]:
        directory = request.app[SCHEDULER_KEY].root / "locks"
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "manual-control.lock").open("a") as lock:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    await asyncio.sleep(0.1)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)


def identify_prompt(prompt: dict, models: dict[str, dict]) -> str | None:
    if not isinstance(prompt, dict) or not isinstance(prompt.get("prompt"), dict):
        raise ValueError("Expected a prompt object")
    extra = prompt.get("extra_data", {})
    workflow = extra.get("extra_pnginfo", {}).get("workflow", {})
    explicit = extra.get("qwen_model_id") or workflow.get("extra", {}).get("qwen_model_id")
    nodes = prompt.get("prompt", {})
    files, types = set(), set()
    serialized = json.dumps(nodes, ensure_ascii=False)
    for model_id, config in models.items():
        if config["runtime_type"] != "comfyui":
            continue
        signatures = config.get("signatures", {})
        if any(node.get("class_type") in signatures.get("node_types", []) for node in nodes.values()):
            types.add(model_id)
        if any(name in serialized for name in signatures.get("model_files", [])):
            files.add(model_id)
    if files:
        if len(files) != 1:
            raise ValueError("Workflow references multiple isolated models")
        return next(iter(files))
    if explicit:
        if explicit not in models or models[explicit]["runtime_type"] != "comfyui":
            raise ValueError(f"Workflow model is not installed: {explicit}")
        return explicit
    return next(iter(types)) if len(types) == 1 else None


async def activate(request: web.Request, model_id: str) -> dict:
    scheduler: Scheduler = request.app[SCHEDULER_KEY]
    current = scheduler.active_model()
    if current and current != model_id and scheduler.status(current)["state"] == "RUNNING":
        raise web.HTTPConflict(text=f"Queue is busy: {current}")
    try:
        return await scheduler.start(model_id)
    except ValueError as exc:
        raise web.HTTPBadRequest(text=str(exc)) from exc
    except (OSError, RuntimeError) as exc:
        raise web.HTTPServiceUnavailable(text=str(exc)) from exc


def headers_for_upstream(headers) -> dict[str, str]:
    return {k: v for k, v in headers.items() if k.lower() not in HOP_HEADERS}


async def selected_model(request: web.Request) -> str:
    scheduler: Scheduler = request.app[SCHEDULER_KEY]
    model_id = scheduler.active_model()
    if model_id and scheduler.status(model_id)["state"] in ("BACKEND_READY", "RUNNING"):
        return model_id
    # A backend is needed to display the editor even before a workflow is opened.
    # Starting it does not queue inference or load model weights.
    async with runtime_lock(request):
        model_id = scheduler.active_model() or next(
            (name for name, model in scheduler.models.items() if model["runtime_type"] == "comfyui"), None)
        if model_id is None:
            raise web.HTTPConflict(text="No installed ComfyUI model; run the model setup first")
        await activate(request, model_id)
    return model_id


async def relay_websocket(request: web.Request, port: int) -> web.WebSocketResponse:
    session: ClientSession = request.app[SESSION_KEY]
    protocols = tuple(p.strip() for p in request.headers.get("Sec-WebSocket-Protocol", "").split(",") if p.strip())
    headers = {k: v for k, v in headers_for_upstream(request.headers).items()
               if not k.lower().startswith("sec-websocket-")}
    try:
        backend = await session.ws_connect(
            f"http://127.0.0.1:{port}{request.rel_url}", headers=headers,
            protocols=protocols, max_msg_size=0,
        )
    except (ClientError, asyncio.TimeoutError) as exc:
        raise web.HTTPBadGateway(text="Backend WebSocket unavailable") from exc
    browser = web.WebSocketResponse(protocols=protocols, max_msg_size=0)
    await browser.prepare(request)

    async def forward(source, destination) -> None:
        async for message in source:
            if message.type == WSMsgType.TEXT:
                await destination.send_str(message.data)
            elif message.type == WSMsgType.BINARY:
                await destination.send_bytes(message.data)
            elif message.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break

    tasks = {asyncio.create_task(forward(browser, backend)),
             asyncio.create_task(forward(backend, browser))}
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await backend.close()
        await browser.close()
    return browser


async def relay_http(request: web.Request, port: int) -> web.StreamResponse:
    session: ClientSession = request.app[SESSION_KEY]
    async def body():
        async for chunk in request.content.iter_chunked(1024 * 1024):
            yield chunk
    try:
        async with session.request(
            request.method, f"http://127.0.0.1:{port}{request.rel_url}",
            headers=headers_for_upstream(request.headers),
            data=body() if request.can_read_body else None,
            allow_redirects=False,
        ) as upstream:
            response = web.StreamResponse(status=upstream.status, reason=upstream.reason)
            for key, value in upstream.headers.items():
                if key.lower() not in HOP_HEADERS:
                    response.headers.add(key, value)
            await response.prepare(request)
            async for chunk in upstream.content.iter_chunked(1024 * 1024):
                await response.write(chunk)
            await response.write_eof()
            return response
    except (ClientError, asyncio.TimeoutError) as exc:
        raise web.HTTPBadGateway(text="Backend unavailable") from exc


async def handle(request: web.Request) -> web.StreamResponse:
    scheduler: Scheduler = request.app[SCHEDULER_KEY]
    scheduler.load_registry()
    if request.path == "/runtime/healthz":
        return web.json_response({"registered": list(scheduler.models)})
    if request.path == "/runtime/frontend.js":
        return web.FileResponse(Path(__file__).with_name("frontend.js"),
                                headers={"Cache-Control": "no-store"})
    if request.path == "/runtime/select" and request.method == "POST":
        data = await request.json()
        if not isinstance(data, dict) or not isinstance(data.get("model_id"), str):
            raise web.HTTPBadRequest(text="Expected a model_id string")
        async with runtime_lock(request):
            target = await activate(request, data.get("model_id"))
        return web.json_response({"model_id": target["model_id"], "port": target["port"]})
    if request.path == "/runtime/models":
        return web.json_response({name: {**scheduler.status(name),
                                        "signatures": model.get("signatures", {})}
                                  for name, model in scheduler.models.items()
                                  if model["runtime_type"] == "comfyui"})
    if request.path == "/runtime/current":
        return web.json_response({"model_id": scheduler.active_model()})
    if request.path == "/prompt" and request.method == "POST":
        body = await request.read()
        try:
            payload = json.loads(body)
            model_id = identify_prompt(payload, scheduler.models)
        except ValueError as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc
        if model_id is None:
            raise web.HTTPConflict(text="Cannot identify workflow model; set extra.qwen_model_id")
        async with runtime_lock(request):
            target = await activate(request, model_id)
            async with request.app[SESSION_KEY].post(
                f"http://127.0.0.1:{target['port']}/prompt", data=body,
                headers={"Content-Type": "application/json"},
            ) as upstream:
                return web.Response(body=await upstream.read(), status=upstream.status,
                                    content_type=upstream.content_type)
    model_id = await selected_model(request)
    target = scheduler.models[model_id]
    if request.path == "/extensions":
        async with request.app[SESSION_KEY].get(
            f"http://127.0.0.1:{target['port']}{request.rel_url}"
        ) as upstream:
            if upstream.status != 200:
                raise web.HTTPBadGateway(text="Backend extension list unavailable")
            extensions = await upstream.json()
        return web.json_response([*extensions, "/runtime/frontend.js"],
                                 headers={"Cache-Control": "no-store"})
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await relay_websocket(request, target["port"])
    return await relay_http(request, target["port"])


async def app_context(app: web.Application):
    app[CONTROL_KEY] = asyncio.Lock()
    app[SESSION_KEY] = ClientSession(auto_decompress=False)
    yield
    await app[SESSION_KEY].close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8188)
    args = parser.parse_args()
    app = web.Application(client_max_size=100 * 1024 * 1024)
    app[SCHEDULER_KEY] = Scheduler(args.root)
    app.cleanup_ctx.append(app_context)
    app.router.add_route("*", "/{tail:.*}", handle)
    web.run_app(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
