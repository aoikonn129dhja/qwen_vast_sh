#!/usr/bin/env python3
"""Compatibility entry point for the shared Vast.ai and SaladCloud sync tool."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "local_tools"))
from vast_comfy_output_sync_and_log import main, workflow_fields  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main(salad=True))
