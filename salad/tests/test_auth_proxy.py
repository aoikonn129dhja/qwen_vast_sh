import base64
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("auth_proxy", ROOT / "salad/common/auth_proxy.py")
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


class AuthProxyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        async def backend(request):
            if request.path == "/system_stats":
                return web.json_response({"system": "ready"})
            if request.path == "/headers":
                return web.json_response({"authorization": request.headers.get("Authorization"), "forwarded_for": request.headers.get("X-Forwarded-For")})
            if request.path == "/ws":
                ws = web.WebSocketResponse()
                await ws.prepare(request)
                async for message in ws:
                    if message.type == aiohttp.WSMsgType.TEXT:
                        await ws.send_str(message.data)
                    elif message.type == aiohttp.WSMsgType.BINARY:
                        await ws.send_bytes(message.data)
                return ws
            return web.Response(body=await request.read(), text=None) if request.can_read_body else web.Response(text="private")

        app = web.Application()
        app.router.add_route("*", "/{tail:.*}", backend)
        self.backend = TestServer(app)
        await self.backend.start_server()
        self.proxy = TestServer(proxy.make_app(self.backend.port, "owner", "p" * 20))
        await self.proxy.start_server()
        self.client = aiohttp.ClientSession()
        self.auth = {"Authorization": "Basic " + base64.b64encode(b"owner:" + b"p" * 20).decode()}

    async def asyncTearDown(self):
        await self.client.close()
        await self.proxy.close()
        await self.backend.close()

    async def test_http_requires_auth_and_streams_body(self):
        async with self.client.get(self.proxy.make_url("/history")) as response:
            self.assertEqual(response.status, 401)
            self.assertEqual(response.headers.get("WWW-Authenticate"), 'Basic realm="ComfyUI"')
        async with self.client.get(self.proxy.make_url("/history"), headers=self.auth) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(await response.text(), "private")
        async with self.client.get(self.proxy.make_url("/headers"), headers={**self.auth, "X-Forwarded-For": "spoofed"}) as response:
            self.assertEqual(await response.json(), {"authorization": None, "forwarded_for": None})
        async with self.client.post(self.proxy.make_url("/upload/image"), data=b"test payload", headers=self.auth) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(await response.read(), b"test payload")

    async def test_websocket_requires_auth_and_relays_messages(self):
        with self.assertRaises(aiohttp.WSServerHandshakeError) as caught:
            await self.client.ws_connect(self.proxy.make_url("/ws"))
        self.assertEqual(caught.exception.status, 401)
        async with self.client.ws_connect(self.proxy.make_url("/ws"), headers=self.auth) as ws:
            await ws.send_str("hello")
            self.assertEqual((await ws.receive()).data, "hello")
            await ws.send_bytes(b"binary")
            self.assertEqual((await ws.receive()).data, b"binary")

    async def test_health_and_cross_origin(self):
        async with self.client.get(self.proxy.make_url("/healthz")) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(await response.text(), "ok")
        headers = {**self.auth, "Origin": "https://attacker.invalid"}
        async with self.client.post(self.proxy.make_url("/prompt"), headers=headers) as response:
            self.assertEqual(response.status, 403)

    def test_credential_validation(self):
        with mock.patch.dict("os.environ", {"COMFY_GATEWAY_USER": "", "COMFY_GATEWAY_PASSWORD": ""}):
            with self.assertRaises(ValueError):
                proxy.credentials()
        self.assertFalse(proxy.authorized("Basic !!!", "owner", "p" * 20))
        self.assertFalse(proxy.authorized(None, "owner", "p" * 20))


if __name__ == "__main__":
    unittest.main()
