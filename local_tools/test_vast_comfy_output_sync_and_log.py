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

    def test_media_entries_yield_supported_images_and_videos(self):
        history = {"outputs": {"10": {
            "images": [
                {"filename": "still.PNG", "type": "output"},
                {"filename": "savevideo.mp4", "type": "output"},
            ],
            "videos": [
                {"filename": "clip.MP4", "type": "output"},
                {"filename": "preview.mp4", "type": "temp"},
                {"filename": "unknown.xyz", "type": "output"},
            ],
        }}}
        entries = list(sync.media_entries(history))
        self.assertEqual(entries, [
            ("10", {"filename": "still.PNG", "type": "output"}, "image"),
            ("10", {"filename": "savevideo.mp4", "type": "output"}, "video"),
            ("10", {"filename": "clip.MP4", "type": "output"}, "video"),
        ])

    def test_videohelper_output_and_duplicate_collections(self):
        item = {"filename": "clip.webm", "subfolder": "video", "type": "output"}
        history = {"outputs": {"58": {"images": [item], "videos": [item], "gifs": [item]}}}
        self.assertEqual(list(sync.media_entries(history)), [("58", item, "video")])

    def test_real_savevideo_history_is_downloaded_once_and_recorded_as_video(self):
        history = {"job": {
            "outputs": {"58": {"images": [{
                "filename": "Wan22-Turbo_00002_.mp4", "subfolder": "video", "type": "output",
                "metadata": {"kind": "video", "fps": 24.0, "frame_count": 121},
            }], "animated": [True]}},
            "status": {"status_str": "success"},
            "prompt": [0, "job", {"37": {"inputs": {"unet_name": "Wan-Turbo.safetensors"}}}],
        }}
        requests = []

        def fetch(url, authorization):
            requests.append(url)
            return json.dumps(history).encode() if '/history?' in url else b'fake-video-data'

        with patch.object(sync, "OUTPUT_DIR", self.directory), \
                patch("builtins.input", side_effect=["http://127.0.0.1:18188", ""]), \
                patch.object(sync, "fetch", side_effect=fetch), \
                patch.object(sync.time, "sleep", side_effect=[None, KeyboardInterrupt]), \
                patch("builtins.print"):
            self.assertEqual(sync.main(), 0)
        videos = list(self.directory.rglob('*.mp4'))
        self.assertEqual(len(videos), 1)
        self.assertEqual(videos[0].read_bytes(), b'fake-video-data')
        views = [url for url in requests if '/view?' in url]
        self.assertEqual(len(views), 1)
        self.assertIn('subfolder=video', views[0])
        state = json.loads((self.directory / '.vast_comfy_sync_state.json').read_text())
        self.assertEqual(len(state['done']), 1)
        import csv
        with next(self.directory.rglob('*.csv')).open(encoding='utf-8-sig', newline='') as file:
            rows = list(csv.DictReader(file))
        self.assertEqual(rows[0]['media_type'], 'video')
        self.assertEqual(rows[0]['local_image'], '')


class OutputDirectoryTests(unittest.TestCase):
    def test_qwen_v23_workflow_fields(self):
        workflow = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v23.safetensors"}},
            "2": {"inputs": {"steps": 4, "cfg": 1, "sampler_name": "sa_solver"}},
            "3": {"inputs": {"prompt": "edit"}},
            "4": {"inputs": {"prompt": "avoid"}},
            "8": {"inputs": {"image": "v23_batch/image.png"}},
            "10": {"inputs": {"filename_prefix": "v23_result"}},
        }
        fields = sync.workflow_fields(workflow)
        self.assertEqual(fields["positive_prompt"], "edit")
        self.assertEqual(fields["image_1"], "v23_batch/image.png")
        self.assertEqual(fields["filename_prefix"], "v23_result")
        self.assertEqual(fields["model"], "v23.safetensors")
        self.assertEqual(fields["steps"], 4)

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
