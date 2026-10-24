import importlib.util
import json
from pathlib import Path
import unittest


MODEL_DIR = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "pose_stages", MODEL_DIR / "custom_nodes/ComfyUI-QwenPoseStages/__init__.py"
)
stages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stages)


class PoseStageTests(unittest.TestCase):
    def test_estimation_requires_pose_but_generation_skips_estimator(self):
        stage = stages.QwenPoseStage()
        self.assertEqual(stage.check_lazy_status("estimate"), ["detected_pose"])
        self.assertEqual(stage.check_lazy_status("generate"), [])
        pose = [{"people": []}]
        self.assertEqual(stage.select("estimate", pose), (pose, False))
        self.assertEqual(stage.select("generate", pose), (None, True))
        with self.assertRaises(ValueError):
            stage.select("estimate")

    def test_estimation_never_requests_generated_image(self):
        gate = stages.QwenPoseResult()
        self.assertEqual(gate.check_lazy_status(False), ["pose_preview"])
        self.assertEqual(gate.check_lazy_status(False, pose_preview="pose"), [])
        self.assertEqual(gate.select(False, "pose", "generated"), ("pose",))
        self.assertEqual(gate.check_lazy_status(True), ["generated_image"])
        self.assertEqual(gate.select(True, "pose", "generated"), ("generated",))

    def test_workflow_links_and_safe_initial_stage(self):
        data = json.loads((MODEL_DIR / "workflows/2511-pose-estimate-edit.json").read_text(encoding="utf-8"))
        graphs = [data, *data["definitions"]["subgraphs"]]
        for graph in graphs:
            nodes = {node["id"]: node for node in graph["nodes"]}
            links = graph.get("links", [])
            if links and isinstance(links[0], dict):
                for link in links:
                    source, target = link["origin_id"], link["target_id"]
                    if source in nodes:
                        self.assertIn(link["id"], nodes[source]["outputs"][link["origin_slot"]]["links"])
                    if target in nodes:
                        self.assertEqual(nodes[target]["inputs"][link["target_slot"]]["link"], link["id"])
                image3 = next(port for port in graph["inputs"] if port["name"] == "image3")
                encoders = {node["id"] for node in graph["nodes"] if node["type"] == "TextEncodeQwenImageEditPlus"}
                self.assertEqual({link["target_id"] for link in links if link["id"] in image3["linkIds"]}, encoders)
                continue
            self.assertEqual(len(nodes), len(graph["nodes"]))
            for link_id, source, slot, target, target_slot, kind in links:
                self.assertIn(link_id, nodes[source]["outputs"][slot]["links"])
                self.assertEqual(nodes[target]["inputs"][target_slot]["link"], link_id)
                self.assertEqual(nodes[source]["outputs"][slot]["type"], kind)
                self.assertEqual(nodes[target]["inputs"][target_slot]["type"], kind)
        stage = next(node for node in data["nodes"] if node["type"] == "QwenPoseStage")
        self.assertEqual(stage["widgets_values"], ["estimate"])
        generator = next(node for node in data["nodes"] if node["id"] == 170)
        self.assertIsNotNone(next(port for port in generator["inputs"] if port["name"] == "image3")["link"])


if __name__ == "__main__":
    unittest.main()
