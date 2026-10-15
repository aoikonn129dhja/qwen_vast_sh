"""Offline checks for Vast ComfyUI output folder selection."""
import importlib.util
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("vast_comfy_output_sync_and_log.py")
spec = importlib.util.spec_from_file_location("vast_comfy_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class OutputDirectoryTests(unittest.TestCase):
    def test_reuses_day_and_model_folder(self):
        workflow = {"1": {"inputs": {"unet_name": "models/qwen-v23.safetensors"}}}
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(sync, "OUTPUT_DIR", Path(temporary)):
                first = sync.image_directory(workflow, datetime(2026, 10, 15, 9, 30))
                second = sync.image_directory(workflow, datetime(2026, 10, 15, 11, 45))
                self.assertEqual(first, second)
                self.assertEqual(first.name, "202610150930_qwen-v23")
                self.assertEqual(sync.candidate_name("abc", {"filename": "out.png"}, first).parent, first)

    def test_unknown_model_gets_own_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(sync, "OUTPUT_DIR", Path(temporary)):
                directory = sync.image_directory({}, datetime(2026, 10, 15, 9, 30))
                self.assertEqual(directory.name, "202610150930_ComfyUI_model_unknown")


if __name__ == "__main__":
    unittest.main()
