import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError

import salad_cli as cli


class SaladTests(unittest.TestCase):
    def setUp(self):
        self.source = {
            "name": "qwen-edit-2511", "priority": "batch", "autostart_policy": True,
            "container": {"resources": {"cpu": 4, "memory": 16384,
                "gpu_classes": ["gpu-id"], "shm_size": 64}, "hash": "ignored"},
            "networking": {"dns": "ignored", "port": 8189, "auth": False, "protocol": "http"},
        }

    def test_env_quotes_and_bom(self):
        with tempfile.TemporaryDirectory(dir=cli.ROOT / "tmp") as folder:
            path = Path(folder) / "env"
            path.write_text('\ufeff# Comment\nSALAD_API_KEY="abc"\n', encoding="utf-8")
            self.assertEqual(cli.read_env(path), {"SALAD_API_KEY": "abc"})

    def test_summary_retains_current_group_settings(self):
        result = cli.summary(self.source)
        self.assertEqual(result["name"], "qwen-edit-2511")
        self.assertEqual(result["resources"]["memory"], 16384)
        self.assertEqual(result["networking"]["port"], 8189)

    def test_paid_start_blocked_without_authorization(self):
        client = Mock()
        with self.assertRaises(ValueError):
            cli.operate(client, "start", "qwen-edit-2511")
        client.get.assert_not_called()
        client.request.assert_not_called()

    def test_http_error_does_not_expose_key(self):
        client = cli.Client({"SALAD_API_KEY": "secret-value", "SALAD_ORGANIZATION": "image-video-gen", "SALAD_PROJECT": "default"})
        with patch.object(cli, "urlopen", side_effect=HTTPError("url", 401, "secret-value", {}, None)):
            with self.assertRaises(cli.ApiError) as caught:
                client.get("qwen-edit-2511")
        self.assertNotIn("secret-value", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
