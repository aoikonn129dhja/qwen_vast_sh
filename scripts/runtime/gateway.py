#!/usr/bin/env python3
"""ComfyUI HTTP and WebSocket gateway with per-session model selection."""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from aiohttp import ClientError, ClientSession, WSMsgType, web

from scheduler import Scheduler

SCHEDULER_KEY = web.AppKey("scheduler", Scheduler)
SESSION_KEY = web.AppKey("session", ClientSession)
DEFAULT_MODEL_KEY = web.AppKey("default_model", dict)

HOP_HEADERS = {"authorization", "connection", "content-length", "host", "keep-alive", "origin", "proxy-authenticate",
               "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"}


def identify_prompt(prompt: dict, models: dict[str, dict]) -> str | None:
    explicit = prompt.get("extra_data", {}).get("qwen_model_id")
    if explicit in models:
        return explicit
    nodes = prompt.get("prompt", {})
    matches = set()
    serialized = json.dumps(nodes, ensure_ascii=False)
    for model_id, config in models.items():
        signatures = config.get("signatures", {})
        if any(node.get("class_type") in signatures.get("node_types", []) for node in nodes.values()):
            matches.add(model_id)
        if any(name in serialized for name in signatures.get("model_files", [])):
            matches.add(model_id)
    return next(iter(matches)) if len(matches) == 1 else None


def headers_for_upstream(headers) -> dict[str, str]:
    return {k: v for k, v in headers.items() if k.lower() not in HOP_HEADERS}


async def select_model(request: web.Request) -> web.Response:
    data = await request.json()
    model_id = data.get("model_id")
    scheduler: Scheduler = request.app[SCHEDULER_KEY]
    if model_id not in scheduler.models:
        raise web.HTTPBadRequest(text="Unknown model")
    if scheduler.models[model_id]["runtime_type"] != "comfyui":
        raise web.HTTPBadRequest(text="Model has no ComfyUI backend")
    try:
        await scheduler.ensure(model_id, reserve=True)
    except RuntimeError as exc:
        raise web.HTTPServiceUnavailable(text=str(exc)) from exc
    response = web.json_response({"model_id": model_id, "port": scheduler.models[model_id]["port"]})
    request.app[DEFAULT_MODEL_KEY]["value"] = model_id
    response.set_cookie("qwen_runtime_model", model_id, httponly=True, samesite="Strict", path="/")
    return response


async def selected_model(request: web.Request) -> str:
    scheduler: Scheduler = request.app[SCHEDULER_KEY]
    model_id = request.cookies.get("qwen_runtime_model")
    if model_id in scheduler.models:
        return model_id
    model_id = request.app[DEFAULT_MODEL_KEY]["value"]
    if model_id in scheduler.models:
        return model_id
    if len(scheduler.models) == 1:
        return next(iter(scheduler.models))
    raise web.HTTPConflict(text="Select a model at /runtime/select before using ComfyUI")


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
    if request.path == "/runtime/select" and request.method == "POST":
        return await select_model(request)
    if request.path == "/runtime/models":
        await scheduler.refresh()
        return web.json_response({name: {"state": model["state"], "port": model["port"],
                                        "signatures": model.get("signatures", {})}
                                  for name, model in scheduler.models.items()
                                  if model["runtime_type"] == "comfyui"})
    if request.path.startswith("/runtime/cli/") and request.method == "POST":
        data = await request.json()
        model_id, token = data.get("model_id"), data.get("token")
        if model_id not in scheduler.models or scheduler.models[model_id]["runtime_type"] != "cli":
            raise web.HTTPBadRequest(text="Unknown CLI model")
        if not isinstance(token, str) or len(token) < 32:
            raise web.HTTPBadRequest(text="Invalid reservation token")
        try:
            if request.path == "/runtime/cli/admit":
                await scheduler.ensure(model_id, reserve=True, cli_token=token)
            elif request.path == "/runtime/cli/heartbeat":
                await scheduler.heartbeat_cli(model_id, token)
            elif request.path == "/runtime/cli/release":
                await scheduler.release_cli(model_id, token)
            else:
                raise web.HTTPNotFound()
        except RuntimeError as exc:
            raise web.HTTPServiceUnavailable(text=str(exc)) from exc
        return web.json_response({"ok": True})
    if request.path == "/runtime/current":
        return web.json_response({"model_id": request.cookies.get("qwen_runtime_model") or request.app[DEFAULT_MODEL_KEY]["value"]})
    if request.path == "/prompt" and request.method == "POST":
        body = await request.read()
        try:
            payload = json.loads(body)
        except ValueError as exc:
            raise web.HTTPBadRequest(text="Invalid prompt JSON") from exc
        model_id = identify_prompt(payload, scheduler.models)
        if model_id is None:
            selected = request.cookies.get("qwen_runtime_model")
            if selected in scheduler.models and scheduler.models[selected]["runtime_type"] == "comfyui":
                model_id = selected
            else:
                raise web.HTTPConflict(text="Workflow model is ambiguous; select a model")
        try:
            target = await scheduler.ensure(model_id, reserve=True)
        except RuntimeError as exc:
            raise web.HTTPServiceUnavailable(text=str(exc)) from exc
        async with request.app[SESSION_KEY].post(
            f"http://127.0.0.1:{target['port']}/prompt", data=body,
            headers={"Content-Type": "application/json"},
        ) as upstream:
            response = web.Response(body=await upstream.read(), status=upstream.status,
                                    content_type=upstream.content_type)
            if upstream.status < 400:
                target["loaded"] = True
                target["state"] = "LOADING"
            response.set_cookie("qwen_runtime_model", model_id, httponly=True, samesite="Strict", path="/")
            return response
    model_id = await selected_model(request)
    try:
        target = await scheduler.ensure(model_id)
    except RuntimeError as exc:
        raise web.HTTPServiceUnavailable(text=str(exc)) from exc
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await relay_websocket(request, target["port"])
    return await relay_http(request, target["port"])


async def app_context(app: web.Application):
    app[SESSION_KEY] = ClientSession(auto_decompress=False)
    yield
    await app[SESSION_KEY].close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8188)
    parser.add_argument("--free-limit-mb", type=int)
    args = parser.parse_args()
    app = web.Application(client_max_size=100 * 1024 * 1024)
    app[SCHEDULER_KEY] = Scheduler(args.root, args.free_limit_mb)
    app[DEFAULT_MODEL_KEY] = {"value": next((name for name, model in app[SCHEDULER_KEY].models.items()
                                             if model["runtime_type"] == "comfyui"), None)}
    app.cleanup_ctx.append(app_context)
    app.router.add_route("*", "/{tail:.*}", handle)
    web.run_app(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
