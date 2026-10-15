import asyncio
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from aiohttp import web
    from aiohttp.test_utils import TestClient, TestServer
    import gateway
except ImportError:
    web = None


@unittest.skipIf(web is None, "aiohttp is not installed in this test environment")
class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        backend = web.Application()

        async def echo(request):
            return web.json_response({"path": request.path})

        async def prompt(request):
            return web.json_response({"prompt_id": "accepted", "request": await request.json()})

        async def websocket(request):
            socket = web.WebSocketResponse()
            await socket.prepare(request)
            async for message in socket:
                if message.type.name == "TEXT":
                    await socket.send_str(message.data)
            return socket

        backend.router.add_post("/prompt", prompt)
        backend.router.add_get("/ws", websocket)
        backend.router.add_route("*", "/{tail:.*}", echo)
        self.backend = TestServer(backend)
        await self.backend.start_server()

        class FakeScheduler:
            def __init__(self, port):
                self.models = {
                    "model-a": {"model_id": "model-a", "runtime_type": "comfyui", "port": port,
                                "state": "READY", "signatures": {"model_files": ["a.safetensors"]}},
                    "model-b": {"model_id": "model-b", "runtime_type": "comfyui", "port": port,
                                "state": "READY", "signatures": {"node_types": ["SpecialNode"]}},
                }

            def load_registry(self):
                pass

            async def refresh(self):
                pass

            async def ensure(self, model_id, reserve=False, cli_token=None):
                return self.models[model_id]

        app = web.Application()
        app[gateway.SCHEDULER_KEY] = FakeScheduler(self.backend.port)
        app[gateway.DEFAULT_MODEL_KEY] = {"value": "model-a"}
        app.cleanup_ctx.append(gateway.app_context)
        app.router.add_route("*", "/{tail:.*}", gateway.handle)
        self.server = TestServer(app)
        self.client = TestClient(self.server)
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.backend.close()

    async def test_explicit_selection_and_backend_proxy(self):
        response = await self.client.post("/runtime/select", json={"model_id": "model-b"})
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["model_id"], "model-b")
        response = await self.client.get("/object_info")
        self.assertEqual((await response.json())["path"], "/object_info")

    async def test_prompt_identifies_model_from_node_type(self):
        payload = {"prompt": {"1": {"class_type": "SpecialNode", "inputs": {}}}}
        response = await self.client.post("/prompt", json=payload)
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["prompt_id"], "accepted")

    async def test_ambiguous_prompt_is_rejected(self):
        response = await self.client.post("/prompt", json={"prompt": {}})
        self.assertEqual(response.status, 409)

    async def test_selected_model_accepts_workflow_without_signature(self):
        response = await self.client.post("/runtime/select", json={"model_id": "model-b"})
        self.assertEqual(response.status, 200)
        response = await self.client.post("/prompt", json={"prompt": {}})
        self.assertEqual(response.status, 200)

    async def test_websocket_progress_reaches_selected_backend(self):
        socket = await self.client.ws_connect("/ws")
        await socket.send_str("progress")
        message = await socket.receive(timeout=2)
        self.assertEqual(message.data, "progress")
        await socket.close()


if __name__ == "__main__":
    unittest.main()
