from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scheduler import Scheduler, choose_victims


class VictimSelectionTests(unittest.TestCase):
    def setUp(self):
        self.models = {
            "requested": {"state": "UNLOADED", "last_used": 0, "measured_mb": 0},
            "old": {"state": "READY", "last_used": 1, "measured_mb": 1000},
            "busy": {"state": "RUNNING", "last_used": 0, "measured_mb": 5000},
            "recent": {"state": "READY", "last_used": 2, "measured_mb": 2000},
        }

    def test_no_eviction_when_capacity_is_sufficient(self):
        self.assertEqual(choose_victims(self.models, "requested", 3000, 2500), [])

    def test_lru_stops_after_enough_memory(self):
        self.assertEqual(choose_victims(self.models, "requested", 2000, 2500), ["old"])

    def test_running_and_requested_models_are_protected(self):
        self.assertEqual(
            choose_victims(self.models, "requested", 100, 2800),
            ["old", "recent"],
        )

    def test_registry_loads_new_models_and_removes_unregistered_models(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registry = root / "state" / "registered"
            registry.mkdir(parents=True)
            file = registry / "one.json"
            file.write_text('{"model_id":"one"}', encoding="utf-8")
            scheduler = Scheduler(root)
            self.assertIn("one", scheduler.models)
            file.unlink()
            scheduler.load_registry()
            self.assertNotIn("one", scheduler.models)


class AdmissionTests(unittest.IsolatedAsyncioTestCase):
    async def test_low_memory_limit_evicts_only_idle_model(self):
        with tempfile.TemporaryDirectory() as directory:
            scheduler = Scheduler(Path(directory), free_limit_mb=4000)
            scheduler.models = {
                "requested": {"model_id": "requested", "runtime_type": "comfyui", "state": "UNLOADED", "loaded": False,
                              "gpu_policy": {"reserve_mb": 3000}, "measured_mb": 0,
                              "last_used": 0},
                "idle": {"model_id": "idle", "runtime_type": "comfyui", "state": "READY", "loaded": True,
                         "gpu_policy": {"reserve_mb": 2500}, "measured_mb": 2500,
                         "last_used": 1},
                "running": {"model_id": "running", "runtime_type": "comfyui", "state": "RUNNING", "loaded": True,
                            "gpu_policy": {"reserve_mb": 2500}, "measured_mb": 0,
                            "last_used": 0},
            }
            scheduler.load_registry = lambda: None
            scheduler.refresh = AsyncMock()

            async def unload(model, required_free_mb):
                model["state"] = "UNLOADED"
                model["measured_mb"] = 0

            scheduler.unload = AsyncMock(side_effect=unload)
            with patch("scheduler.gpu_free_mb", return_value=10000), \
                 patch("scheduler.managed_pid", return_value=123):
                target = await scheduler.ensure("requested", reserve=True)
            self.assertEqual(target["state"], "UNLOADED")
            scheduler.unload.assert_awaited_once()
            self.assertEqual(scheduler.unload.await_args.args[0]["model_id"], "idle")

    async def test_cli_reservation_releases_without_starting_comfyui(self):
        with tempfile.TemporaryDirectory() as directory:
            scheduler = Scheduler(Path(directory))
            scheduler.models = {
                "cli": {"model_id": "cli", "runtime_type": "cli", "state": "UNLOADED",
                        "loaded": False, "gpu_policy": {"reserve_mb": 1000},
                        "measured_mb": 0, "last_used": 0},
            }
            scheduler.load_registry = lambda: None
            scheduler.refresh = AsyncMock()
            with patch("scheduler.gpu_free_mb", return_value=2000):
                model = await scheduler.ensure("cli", reserve=True, cli_token="secret")
            self.assertEqual(model["state"], "RUNNING")
            await scheduler.heartbeat_cli("cli", "secret")
            await scheduler.release_cli("cli", "secret")
            self.assertEqual(model["state"], "UNLOADED")


if __name__ == "__main__":
    unittest.main()
