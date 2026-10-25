"""Offline tests for the Windows V23 batch launcher."""

import importlib.util
import io
import tarfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("qwen_v23_batch.py")
spec = importlib.util.spec_from_file_location("qwen_v23_batch", SCRIPT)
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


class ConnectionTests(unittest.TestCase):
    def test_vast_ssh_url(self):
        self.assertEqual(
            batch.parse_target("ssh://root@ssh.example.com:31234", None),
            ("root@ssh.example.com", 31234),
        )

    def test_ssh_config_alias_and_port(self):
        self.assertEqual(batch.parse_target("vast-v23", 2200), ("vast-v23", 2200))
        self.assertEqual(batch.parse_target("vast-v23", None), ("vast-v23", None))
        self.assertEqual(
            batch.ssh_command("ssh", "vast-v23", 2200, None),
            ["ssh", "-T", "-p", "2200", "vast-v23"],
        )

    def test_rejects_target_starting_with_option(self):
        with self.assertRaises(ValueError):
            batch.parse_target("-oProxyCommand=bad", None)


class InputTests(unittest.TestCase):
    def test_quoted_windows_directory(self):
        directory = Path(r"C:\Users\amami\My Pictures")
        with patch.object(batch.Path, "is_dir", return_value=True):
            self.assertEqual(batch.image_directory(f'"{directory}"'), directory)

    def test_only_top_level_supported_images(self):
        directory = Path("input")
        candidates = [Path("input/a.png"), Path("input/b.txt"), Path("input/c.WEBP")]
        with patch.object(batch.Path, "iterdir", return_value=iter(candidates)), \
                patch.object(batch.Path, "is_file", return_value=True), \
                patch.object(batch.Path, "is_symlink", return_value=False):
            self.assertEqual(batch.list_images(directory), [candidates[0], candidates[2]])


class PromptTests(unittest.TestCase):
    def test_multiline_prompt_preserves_blank_lines(self):
        with patch("builtins.input", side_effect=["SCENE:", "first line", "", "second line", "."]), \
                patch("builtins.print"):
            self.assertEqual(batch.read_prompt(), "SCENE:\nfirst line\n\nsecond line")

    def test_empty_prompt_is_rejected(self):
        with patch("builtins.input", side_effect=["", "."]), patch("builtins.print"):
            with self.assertRaises(ValueError):
                batch.read_prompt()


class LaunchTests(unittest.TestCase):
    def test_upload_stream_contains_prompt(self):
        class OutputBuffer(io.BytesIO):
            def close(self):
                pass

        class FakeProcess:
            def __init__(self):
                self.stdin = OutputBuffer()

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def wait(self):
                return 0

        process = FakeProcess()
        with patch.object(batch.subprocess, "Popen", return_value=process) as popen:
            batch.upload_images(["ssh", "target"], "/workspace/ComfyUI/input/v23_batch/" + "a" * 32, [], "line one\nline two")
        self.assertIn("tar -x", popen.call_args.args[0][-1])
        with tarfile.open(fileobj=io.BytesIO(process.stdin.getvalue()), mode="r:") as archive:
            self.assertEqual(archive.extractfile("prompt.txt").read(), b"line one\nline two")

    def test_interrupt_closes_archive_before_ssh_pipe(self):
        closed = []

        class FakeStream:
            def close(self):
                closed.append("archive")

        class FakeArchive:
            fileobj = FakeStream()

            def addfile(self, *_):
                pass

            def add(self, *_ , **__):
                raise KeyboardInterrupt

        class FakePipe:
            def close(self):
                closed.append("pipe")

        class FakeProcess:
            stdin = FakePipe()

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def poll(self):
                return None

            def terminate(self):
                closed.append("ssh")

        with patch.object(batch.subprocess, "Popen", return_value=FakeProcess()), \
                patch.object(batch.tarfile, "open", return_value=FakeArchive()), \
                patch("builtins.print"):
            with self.assertRaises(KeyboardInterrupt):
                batch.upload_images(["ssh", "target"], "/workspace/ComfyUI/input/v23_batch/" + "a" * 32,
                                    [Path("input/example.png")], "a prompt")
        self.assertEqual(closed, ["archive", "pipe", "ssh"])

    def test_prompts_once_then_uploads_and_runs(self):
        image = Path("input/example.png")
        with patch("builtins.input", side_effect=["input", "A prompt", "."]), \
                patch.object(batch, "image_directory", return_value=Path("input")), \
                patch.object(batch, "list_images", return_value=[image]), \
                patch.object(batch, "ssh_executable", return_value="ssh"), \
                patch.object(batch, "upload_images") as upload, \
                patch.object(batch.subprocess, "run") as run, \
                patch.object(batch.uuid, "uuid4") as identifier, \
                patch("builtins.print"):
            identifier.return_value.hex = "a" * 32
            run.return_value.returncode = 0
            self.assertEqual(batch.main(["vast-v23"]), 0)
        stage = f"{batch.REMOTE_INPUT_ROOT}/{'a' * 32}"
        upload.assert_called_once_with(["ssh", "-T", "vast-v23"], stage, [image], "A prompt")
        run.assert_called_once_with(
            ["ssh", "-T", "vast-v23", f"bash {batch.REMOTE_RUNNER} {stage}"],
            check=False,
        )

    def test_accepts_usual_ssh_command_with_local_forward(self):
        image = Path("input/example.png")
        with patch("builtins.input", side_effect=["input", "A prompt", "."]), \
                patch.object(batch, "image_directory", return_value=Path("input")), \
                patch.object(batch, "list_images", return_value=[image]), \
                patch.object(batch, "ssh_executable", return_value="ssh"), \
                patch.object(batch, "upload_images") as upload, \
                patch.object(batch.subprocess, "run") as run, \
                patch.object(batch.uuid, "uuid4") as identifier, \
                patch("builtins.print"):
            identifier.return_value.hex = "b" * 32
            run.return_value.returncode = 0
            result = batch.main([
                "ssh", "-p", "40455", "root@174.94.107.156",
                "-L", "8080:localhost:8080",
            ])
        self.assertEqual(result, 0)
        expected_ssh = ["ssh", "-T", "-p", "40455", "root@174.94.107.156"]
        upload.assert_called_once_with(expected_ssh, f"{batch.REMOTE_INPUT_ROOT}/{'b' * 32}", [image], "A prompt")
        self.assertEqual(run.call_args.args[0][:5], expected_ssh)


if __name__ == "__main__":
    unittest.main()
