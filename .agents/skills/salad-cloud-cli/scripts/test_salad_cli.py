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

    def test_payload_is_stopped_and_drops_response_fields(self):
        body = cli.payload(self.source, "qwen-edit-2509", "image")
        self.assertFalse(body["autostart_policy"])
        self.assertEqual(body["container"]["priority"], "batch")
        self.assertNotIn("priority", body)
        self.assertNotIn("dns", body["networking"])
        self.assertNotIn("hash", body["container"])
        self.assertEqual(body["container"]["resources"]["memory"], 16384)

    def test_existing_group_not_created(self):
        client = Mock()
        client.get.return_value = self.source
        body = cli.payload(self.source, "qwen-edit-2509", "image")
        self.assertEqual(cli.create(client, "qwen-edit-2509", body)["result"], "already_exists")
        client.request.assert_not_called()

    def test_create_verify_and_no_retry(self):
        client = Mock()
        client.get.side_effect = [cli.ApiError(404), self.source]
        body = cli.payload(self.source, "qwen-edit-2509", "image")
        cli.create(client, "qwen-edit-2509", body)
        self.assertEqual(client.request.call_count, 1)
        client = Mock()
        client.get.side_effect = cli.ApiError(404)
        client.request.side_effect = RuntimeError("unknown outcome")
        with self.assertRaises(RuntimeError):
            cli.create(client, "qwen-edit-2509", body)
        self.assertEqual(client.request.call_count, 1)

    def test_paid_start_blocked_without_authorization(self):
        client = Mock()
        with self.assertRaises(ValueError):
            cli.operate(client, "start", "qwen-edit-2511")
        client.get.assert_not_called()
        client.request.assert_not_called()

    def test_create_rejects_autostart(self):
        with self.assertRaises(ValueError):
            cli.create(Mock(), "qwen-edit-2511", {"name": "qwen-edit-2511", "autostart_policy": True})

    def test_resource_override_keeps_autostart_off(self):
        body = cli.payload(self.source, "bfs-best-face-swap", "image")
        cli.configure_resources(body, 32768, 50)
        self.assertEqual(body["container"]["resources"]["memory"], 32768)
        self.assertEqual(body["container"]["resources"]["storage_amount"], 53687091200)
        self.assertFalse(body["autostart_policy"])
        with self.assertRaises(ValueError):
            cli.configure_resources(body, storage_gb=0)
        with self.assertRaises(ValueError):
            cli.configure_resources(body, memory=999999)

    def test_http_error_does_not_expose_key(self):
        client = cli.Client({"SALAD_API_KEY": "secret-value", "SALAD_ORGANIZATION": "image-video-gen", "SALAD_PROJECT": "default"})
        with patch.object(cli, "urlopen", side_effect=HTTPError("url", 401, "secret-value", {}, None)):
            with self.assertRaises(cli.ApiError) as caught:
                client.get("qwen-edit-2511")
        self.assertNotIn("secret-value", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
