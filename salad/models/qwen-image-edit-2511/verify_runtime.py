"""Fail the image build if the pinned PyTorch CUDA runtime was replaced."""

import torch
import torchaudio
import torchvision


EXPECTED = {
    "torch": (torch.__version__, "2.11.0+cu130"),
    "torchvision": (torchvision.__version__, "0.26.0+cu130"),
    "torchaudio": (torchaudio.__version__, "2.11.0+cu130"),
    "CUDA": (torch.version.cuda, "13.0"),
}

errors = [f"{name}: expected {expected}, got {actual}" for name, (actual, expected) in EXPECTED.items() if actual != expected]
if errors:
    raise RuntimeError("PyTorch runtime verification failed: " + "; ".join(errors))

print("PyTorch runtime verified: torch 2.11.0, CUDA 13.0")
