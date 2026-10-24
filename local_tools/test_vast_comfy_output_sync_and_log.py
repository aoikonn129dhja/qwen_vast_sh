"""Offline checks for Vast ComfyUI output folder selection."""
import importlib.util
import io
import json
import tempfile
import unittest
from datetime import datetime
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("vast_comfy_output_sync_and_log.py")
spec = importlib.util.spec_from_file_location("vast_comfy_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class TerminalLogTests(unittest.TestCase):
    def test_every_line_has_local_timestamp_and_is_flushed(self):
        with patch.object(sync, "datetime") as clock, patch("builtins.print") as output:
            clock.now.return_value = datetime(2026, 10, 25, 9, 8, 7)
            sync.log("接続先: localhost\n監視開始")
        self.assertEqual(output.call_args_list, [
            unittest.mock.call("[2026-10-25 09:08:07] 接続先: localhost", flush=True),
            unittest.mock.call("[2026-10-25 09:08:07] 監視開始", flush=True),
        ])

    def test_retry_uses_time_at_each_occurrence(self):
        output = io.StringIO()
        with patch.object(sync, "datetime") as clock, \
                patch("builtins.input", side_effect=["http://127.0.0.1:18188", ""]), \
                patch.object(sync, "select_sync_state", return_value=(Path("state.json"), {"done": {}})), \
                patch.object(sync, "fetch", side_effect=[OSError("offline"), OSError("offline"), KeyboardInterrupt]), \
                patch.object(sync.time, "sleep"), redirect_stdout(output):
            clock.now.side_effect = [datetime(2026, 10, 25, 9, 0, second) for second in range(6)]
            self.assertEqual(sync.main(), 0)
        retries = [line for line in output.getvalue().splitlines() if "再試行:" in line]
        self.assertEqual(retries, [
            "[2026-10-25 09:00:03] 再試行: offline",
            "[2026-10-25 09:00:04] 再試行: offline",
        ])


class SyncHistoryTests(unittest.TestCase):
    def setUp(self):
        temporary_root = SCRIPT.resolve().parents[1] / "tmp"
        temporary_root.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def history(self, suffix, state):
        path = self.directory / f".vast_comfy_sync_state{suffix}.json"
        path.write_text(json.dumps(state), encoding="utf-8")
        return path

    def test_creates_default_history(self):
        path, state = sync.select_sync_state(self.directory, "new")
        self.assertEqual(path.name, ".vast_comfy_sync_state.json")
        self.assertEqual(json.loads(path.read_text()), state)

    def test_other_server_history_is_preserved_and_numbered(self):
        old = self.history("", {"server_key": "old", "done": {"saved": {"image": "old.png"}}})
        original = old.read_bytes()
        path, state = sync.select_sync_state(self.directory, "new")
        self.assertEqual(path.name, ".vast_comfy_sync_state_1.json")
        self.assertEqual(state, {"server_key": "new", "done": {}})
        self.assertEqual(old.read_bytes(), original)
        self.assertEqual(sync.select_sync_state(self.directory, "new"), (path, state))

    def test_reuses_matching_numbered_history_before_filling_gap(self):
        self.history("", {"server_key": "other", "done": {}})
        saved = {"server_key": "target", "done": {"job": {"image": "saved.png"}}}
        expected = self.history("_3", saved)
        self.assertEqual(sync.select_sync_state(self.directory, "target"), (expected, saved))
        self.assertFalse((self.directory / ".vast_comfy_sync_state_1.json").exists())

    def test_invalid_histories_are_preserved(self):
        broken = self.directory / ".vast_comfy_sync_state.json"
        broken.write_bytes(b"invalid json")
        wrong_shape = self.history("_1", {"server_key": "target", "done": []})
        wrong_original = wrong_shape.read_bytes()
        path, _ = sync.select_sync_state(self.directory, "target")
        self.assertEqual(path.name, ".vast_comfy_sync_state_2.json")
        self.assertEqual(broken.read_bytes(), b"invalid json")
        self.assertEqual(wrong_shape.read_bytes(), wrong_original)

    def test_main_reaches_polling_despite_conflict(self):
        self.history("", {"server_key": "other", "done": {}})
        with patch.object(sync, "OUTPUT_DIR", self.directory), \
                patch("builtins.input", side_effect=["http://127.0.0.1:18188", ""]), \
                patch.object(sync, "fetch", side_effect=KeyboardInterrupt) as fetch, \
                patch("builtins.print"):
            self.assertEqual(sync.main(), 0)
        fetch.assert_called_once()
        self.assertTrue((self.directory / ".vast_comfy_sync_state_1.json").exists())


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
