import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / "salad/models/qwen-image-edit-2511"


class Qwen2511RuntimeImageTests(unittest.TestCase):
    def test_uses_pinned_official_pytorch_cu130_runtime(self):
        dockerfile = (PROFILE / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn(
            "FROM pytorch/pytorch:2.11.0-cuda13.0-cudnn9-runtime@sha256:"
            "bfbb4a2b4fdba0fefdb428ea737e626d61bb3daf74a16e1ff935bdb03aa7c3f0",
            dockerfile,
        )
        self.assertIn("PYTHON=/usr/local/bin/python", dockerfile)
        self.assertNotIn("uv venv", dockerfile)
        self.assertNotIn("python3.12-venv", dockerfile)

    def test_does_not_reinstall_pytorch_or_cuda_stack(self):
        requirements = (PROFILE / "requirements-runtime.in").read_text(encoding="utf-8")
        lock = (PROFILE / "requirements-runtime.lock").read_text(encoding="utf-8")
        forbidden = re.compile(
            r"^(?:torch|torchvision|torchaudio|triton|nvidia-[a-z0-9-]+)==",
            re.MULTILINE,
        )
        self.assertIsNone(forbidden.search(requirements))
        self.assertIsNone(forbidden.search(lock))

        dockerfile = (PROFILE / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("uv pip install", dockerfile)
        self.assertIn("--no-deps", dockerfile)
        self.assertIn("--require-hashes", dockerfile)
        self.assertGreaterEqual(dockerfile.count("uv pip check"), 2)
        verifier = (PROFILE / "verify_runtime.py").read_text(encoding="utf-8")
        self.assertEqual(dockerfile.count("/opt/profile/verify_runtime.py"), 3)
        self.assertIn('"torch": (torch.__version__, "2.11.0+cu130")', verifier)
        self.assertIn('"CUDA": (torch.version.cuda, "13.0")', verifier)


if __name__ == "__main__":
    unittest.main()
