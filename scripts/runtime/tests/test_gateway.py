import json
from pathlib import Path
import sys
import tempfile
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
        self.directory = tempfile.TemporaryDirectory()
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
                self.root = Path(self_directory)
                self.models = {
                    "model-a": {"model_id": "model-a", "runtime_type": "comfyui", "port": port,
                                "signatures": {"model_files": ["a.safetensors"]}},
                    "model-b": {"model_id": "model-b", "runtime_type": "comfyui", "port": port,
                                "signatures": {"node_types": ["SpecialNode"]}},
                }
                self.active = "model-a"
                self.started = []
                self.busy = False

            def load_registry(self):
                pass

            def active_model(self):
                return self.active

            def status(self, model_id):
                return {"state": "RUNNING" if self.busy else "BACKEND_READY", "active": model_id == self.active,
                        "port": self.models[model_id]["port"], "vram_loaded": None}

            async def start(self, model_id):
                self.started.append(model_id)
                self.active = model_id
                return self.models[model_id]

        self_directory = self.directory.name
        app = web.Application()
        self.scheduler = FakeScheduler(self.backend.port)
        app[gateway.SCHEDULER_KEY] = self.scheduler
        app.cleanup_ctx.append(gateway.app_context)
        app.router.add_route("*", "/{tail:.*}", gateway.handle)
        self.server = TestServer(app)
        self.client = TestClient(self.server)
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.backend.close()
        self.directory.cleanup()

    async def test_workflow_can_select_backend_without_manual_load(self):
        response = await self.client.post("/runtime/select", json={"model_id": "model-b"})
        self.assertEqual(response.status, 200)
        response = await self.client.get("/object_info")
        self.assertEqual((await response.json())["path"], "/object_info")
        self.assertEqual(self.scheduler.active, "model-b")

    async def test_prompt_selects_required_backend_automatically(self):
        payload = {"prompt": {"1": {"class_type": "SpecialNode", "inputs": {}}}}
        response = await self.client.post("/prompt", json=payload)
        self.assertEqual(response.status, 200)
        self.assertEqual(self.scheduler.active, "model-b")
        self.assertEqual(self.scheduler.started, ["model-b"])

    async def test_metadata_identifies_workflow_without_signature(self):
        response = await self.client.post("/prompt", json={"prompt": {}, "extra_data": {
            "extra_pnginfo": {"workflow": {"extra": {"qwen_model_id": "model-a"}}}}})
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["prompt_id"], "accepted")

    async def test_editor_starts_backend_when_no_model_is_active(self):
        self.scheduler.active = None
        response = await self.client.get("/object_info")
        self.assertEqual(response.status, 200)
        self.assertEqual(self.scheduler.started, ["model-a"])

    async def test_running_model_is_not_switched_or_unloaded(self):
        self.scheduler.busy = True
        response = await self.client.post("/prompt", json={"prompt": {
            "1": {"class_type": "SpecialNode", "inputs": {}}}})
        self.assertEqual(response.status, 409)
        self.assertEqual(self.scheduler.active, "model-a")
        self.assertEqual(self.scheduler.started, [])

    async def test_ambiguous_prompt_is_rejected_instead_of_using_previous_model(self):
        response = await self.client.post("/prompt", json={"prompt": {}})
        self.assertEqual(response.status, 409)
        self.assertEqual(self.scheduler.started, [])

    async def test_websocket_progress_reaches_selected_backend(self):
        socket = await self.client.ws_connect("/ws")
        await socket.send_str("progress")
        message = await socket.receive(timeout=2)
        self.assertEqual(message.data, "progress")
        await socket.close()


if __name__ == "__main__":
    unittest.main()
