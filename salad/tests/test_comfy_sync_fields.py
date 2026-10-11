"""Offline checks for CSV settings extracted from ComfyUI history prompts."""
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "salad_comfy_output_sync_and_log.py"
spec = importlib.util.spec_from_file_location("salad_comfy_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class WorkflowFieldsTests(unittest.TestCase):
    def test_qwen_v23_renamed_workflow(self):
        workflow = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "qwen-v23.safetensors"}},
            "2": {"class_type": "KSampler", "inputs": {
                "positive": ["3", 0], "negative": ["4", 0], "seed": 42,
                "steps": 4, "cfg": 1, "sampler_name": "sa_solver", "scheduler": "beta", "denoise": 1,
            }},
            "3": {"class_type": "TextEncodeQwenImageEditPlus", "inputs": {"prompt": "edit this image"}},
            "4": {"class_type": "TextEncodeQwenImageEditPlus", "inputs": {"prompt": "avoid blur"}},
            "14": {"class_type": "LoadImageWithFilename", "inputs": {"image": "pasted/image.png"}},
            "15": {"class_type": "SaveImage", "inputs": {"filename_prefix": ["14", 2]}},
        }
        fields = sync.workflow_fields(workflow)
        self.assertEqual(fields["positive_prompt"], "edit this image")
        self.assertEqual(fields["negative_prompt"], "avoid blur")
        self.assertEqual(fields["image_1"], "pasted/image.png")
        self.assertEqual(fields["model"], "qwen-v23.safetensors")
        self.assertEqual([fields[k] for k in ("seed", "steps", "cfg", "sampler", "scheduler", "denoise")],
                         [42, 4, 1, "sa_solver", "beta", 1])
        self.assertIsNone(fields["filename_prefix"])

    def test_existing_fixed_id_workflow(self):
        workflow = {"170:151": {"inputs": {"prompt": "old prompt"}},
                    "170:169": {"inputs": {"seed": 7, "sampler_name": "euler"}}}
        fields = sync.workflow_fields(workflow)
        self.assertEqual(fields["positive_prompt"], "old prompt")
        self.assertEqual(fields["seed"], 7)
        self.assertEqual(fields["sampler"], "euler")


if __name__ == "__main__":
    unittest.main()
