import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class WorkflowTests(unittest.TestCase):
    def test_workflow_links(self):
        for model, variants in (
            ("qwen-image-2.1-uncensored-gguf", ["edit"]),
            ("bfs-best-face-swap", ["head", "body"]),
        ):
            folder = ROOT / "models" / model
            for variant in variants:
                with self.subTest(model=model, variant=variant):
                    graph = json.loads((folder / "workflows" / (variant + ".json")).read_text())
                    nodes = {n["id"]: n for n in graph["nodes"]}
                    for link, source, slot, dest, input_slot, kind in graph["links"]:
                        self.assertIn(link, nodes[source]["outputs"][slot]["links"])
                        self.assertEqual(nodes[dest]["inputs"][input_slot]["link"], link)
                        self.assertEqual(nodes[dest]["inputs"][input_slot]["type"], kind)
                    text = next(n for n in graph["nodes"] if n["type"] == "TextEncodeQwenImage21")
                    sampler = next(n for n in graph["nodes"] if n["type"] == "KSampler")
                    latent_link = sampler["inputs"][3]["link"]
                    self.assertIn([latent_link, text["id"], 2, sampler["id"], 3, "LATENT"], graph["links"])


if __name__ == "__main__":
    unittest.main()
