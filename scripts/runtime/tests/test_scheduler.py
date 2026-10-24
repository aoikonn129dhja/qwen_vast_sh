import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scheduler import Scheduler


def registered_model(root: Path) -> dict:
    registry = root / "state" / "registered"
    registry.mkdir(parents=True)
    model = {
        "model_id": "qwen3-vl-8b-instruct",
        "runtime_type": "comfyui",
        "port": 18308,
        "pid_file": str(root / "state" / "qwen3-vl-8b-instruct.pid"),
        "comfy_dir": str(root / "instance"),
        "log_file": str(root / "model.log"),
    }
    (registry / "qwen3-vl-8b-instruct.json").write_text(json.dumps(model), encoding="utf-8")
    return model


class ManualLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_start_selects_only_requested_model_without_gpu_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registered_model(root)
            scheduler = Scheduler(root)
            with patch("scheduler.managed_pid", return_value=123), \
                 patch("scheduler.api_json", return_value={}):
                await scheduler.start("qwen3-vl-8b-instruct")
            self.assertEqual(scheduler.active_model(), "qwen3-vl-8b-instruct")
            self.assertEqual(scheduler.status("qwen3-vl-8b-instruct")["vram_loaded"], None)

    async def test_unload_refuses_running_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registered_model(root)
            scheduler = Scheduler(root)
            scheduler.set_active("qwen3-vl-8b-instruct")
            with patch("scheduler.managed_pid", return_value=123), \
                 patch("scheduler.queue_busy", return_value=True), \
                 patch("scheduler.os.kill") as kill:
                with self.assertRaisesRegex(RuntimeError, "running or pending"):
                    await scheduler.unload("qwen3-vl-8b-instruct")
            kill.assert_not_called()
            self.assertEqual(scheduler.active_model(), "qwen3-vl-8b-instruct")

    async def test_unload_stops_only_verified_process_and_preserves_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registered_model(root)
            scheduler = Scheduler(root)
            scheduler.set_active("qwen3-vl-8b-instruct")
            with patch("scheduler.managed_pid", side_effect=[123, None]), \
                 patch("scheduler.queue_busy", return_value=False), \
                 patch("scheduler.os.kill") as kill:
                await scheduler.unload("qwen3-vl-8b-instruct")
            kill.assert_called_once()
            self.assertIsNone(scheduler.active_model())
            self.assertTrue((root / "state" / "registered" / "qwen3-vl-8b-instruct.json").is_file())


if __name__ == "__main__":
    unittest.main()
