#!/usr/bin/env python3
"""Verify and place model assets without ever replacing an existing model file."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path: Path, expected: str) -> bool:
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"Invalid pinned SHA-256 for {path}")
    if path.is_symlink():
        raise RuntimeError(f"Refusing model symlink: {path}")
    if not path.exists():
        return False
    if not path.is_file():
        raise RuntimeError(f"Model path is not a regular file: {path}")
    print(f"SHA-256 検証中: {path}", flush=True)
    actual = sha256(path)
    if actual != expected:
        raise RuntimeError(
            f"Existing model SHA-256 differs: {path}\n"
            f"expected={expected}\nactual={actual}\n"
            "The existing file was preserved. Inspect it before retrying."
        )
    print(f"検証済み・再利用: {path}", flush=True)
    return True


def fetch(url: str, destination: Path, expected: str, downloader=None) -> bool:
    """Return True when reused; download only when the final file is absent."""
    if verify(destination, expected):
        return True
    if not url.startswith("https://"):
        raise ValueError("Model URL must use HTTPS")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    if partial.is_symlink() or (partial.exists() and not partial.is_file()):
        raise RuntimeError(f"Invalid partial file: {partial}")
    if not partial.exists() or sha256(partial) != expected:
        if downloader is None:
            downloader = lambda: subprocess.run(
                ["wget", "--https-only", "--tries=3", "--timeout=60", "-c",
                 "--progress=bar:force:noscroll", "-O", str(partial), url], check=True
            )
        downloader()
    if not partial.is_file() or sha256(partial) != expected:
        raise RuntimeError(f"Downloaded model SHA-256 differs; partial preserved: {partial}")
    try:
        os.link(partial, destination)
    except FileExistsError:
        verify(destination, expected)
        return True
    partial.unlink()
    print(f"SHA-256 検証後に配置: {destination}", flush=True)
    return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("destination", type=Path)
    parser.add_argument("sha256")
    args = parser.parse_args()
    fetch(args.url, args.destination, args.sha256)


if __name__ == "__main__":
    main()
