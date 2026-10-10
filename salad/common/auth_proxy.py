#!/usr/bin/env python3
"""Authenticated HTTP and WebSocket gateway for the local ComfyUI server."""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import hmac
import os
from urllib.parse import urlsplit

import aiohttp
from aiohttp import WSMsgType, web

HOP_HEADERS = {
    "authorization", "connection", "content-length", "host", "keep-alive",
    "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "x-forwarded-for", "x-forwarded-host",
    "x-forwarded-proto",
}


def credentials() -> tuple[str, str]:
    user = os.environ.get("COMFY_GATEWAY_USER", "")
    password = os.environ.get("COMFY_GATEWAY_PASSWORD", "")
    if not user or ":" in user or "\r" in user or "\n" in user or len(password) < 20:
        raise ValueError("Set COMFY_GATEWAY_USER and a COMFY_GATEWAY_PASSWORD of at least 20 characters.")
    return user, password


def authorized(header: str | None, user: str, password: str) -> bool:
    if not header or not header.startswith("Basic "):
        return False
    try:
        supplied = base64.b64decode(header[6:], validate=True)
    except (ValueError, binascii.Error):
        return False
    expected = f"{user}:{password}".encode("utf-8")
    return hmac.compare_digest(supplied, expected)


def forwarded_headers(headers: aiohttp.typedefs.LooseHeaders) -> dict[str, str]:
    return {key: value for key, value in headers.items() if key.lower() not in HOP_HEADERS}


async def relay_websocket(request: web.Request) -> web.WebSocketResponse:
    session: aiohttp.ClientSession = request.app["session"]
    upstream = f"http://127.0.0.1:{request.app['comfy_port']}{request.rel_url}"
    protocols = tuple(p.strip() for p in request.headers.get("Sec-WebSocket-Protocol", "").split(",") if p.strip())
    headers = forwarded_headers(request.headers)
    headers = {k: v for k, v in headers.items() if not k.lower().startswith("sec-websocket-")}
    try:
        backend = await session.ws_connect(
            upstream, headers=headers, protocols=protocols, max_msg_size=0,
        )
    except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
        raise web.HTTPBadGateway() from exc
    browser = web.WebSocketResponse(protocols=protocols, max_msg_size=0)
    await browser.prepare(request)

    async def to_backend() -> None:
        async for message in browser:
            if message.type == WSMsgType.TEXT:
                await backend.send_str(message.data)
            elif message.type == WSMsgType.BINARY:
                await backend.send_bytes(message.data)
            elif message.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break

    async def to_browser() -> None:
        async for message in backend:
            if message.type == WSMsgType.TEXT:
                await browser.send_str(message.data)
            elif message.type == WSMsgType.BINARY:
                await browser.send_bytes(message.data)
            elif message.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break

    tasks = {asyncio.create_task(to_backend()), asyncio.create_task(to_browser())}
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await backend.close()
        await browser.close()
    return browser


async def relay_http(request: web.Request) -> web.StreamResponse:
    session: aiohttp.ClientSession = request.app["session"]
    upstream = f"http://127.0.0.1:{request.app['comfy_port']}{request.rel_url}"

    async def body():
        async for chunk in request.content.iter_chunked(1024 * 1024):
            yield chunk

    has_body = request.can_read_body
    try:
        async with session.request(
            request.method, upstream, headers=forwarded_headers(request.headers),
            data=body() if has_body else None, allow_redirects=False,
        ) as upstream_response:
            response = web.StreamResponse(status=upstream_response.status, reason=upstream_response.reason)
            for key, value in upstream_response.headers.items():
                if key.lower() not in HOP_HEADERS:
                    response.headers.add(key, value)
            await response.prepare(request)
            async for chunk in upstream_response.content.iter_chunked(1024 * 1024):
                await response.write(chunk)
            await response.write_eof()
            return response
    except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
        raise web.HTTPBadGateway() from exc


async def handle(request: web.Request) -> web.StreamResponse:
    if request.path == "/healthz":
        session: aiohttp.ClientSession = request.app["session"]
        try:
            async with session.get(f"http://127.0.0.1:{request.app['comfy_port']}/system_stats") as response:
                if response.status == 200:
                    return web.Response(text="ok")
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass
        raise web.HTTPServiceUnavailable()

    user, password = request.app["credentials"]
    if not authorized(request.headers.get("Authorization"), user, password):
        raise web.HTTPUnauthorized(headers={"WWW-Authenticate": 'Basic realm="ComfyUI"', "Cache-Control": "no-store"})
    origin = request.headers.get("Origin")
    if origin and urlsplit(origin).netloc.lower() != request.host.lower():
        raise web.HTTPForbidden()
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await relay_websocket(request)
    return await relay_http(request)


async def session_context(app: web.Application):
    timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=None)
    async with aiohttp.ClientSession(timeout=timeout, auto_decompress=False, trust_env=False) as session:
        app["session"] = session
        yield


def make_app(comfy_port: int, user: str, password: str) -> web.Application:
    app = web.Application(client_max_size=1024**3)
    app["comfy_port"] = comfy_port
    app["credentials"] = (user, password)
    app.cleanup_ctx.append(session_context)
    app.router.add_route("*", "/{tail:.*}", handle)
    return app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--comfy-port", type=int, required=True)
    parser.add_argument("--proxy-port", type=int, required=True)
    args = parser.parse_args()
    user, password = credentials()
    web.run_app(make_app(args.comfy_port, user, password), host="127.0.0.1", port=args.proxy_port, access_log=None)


if __name__ == "__main__":
    main()
