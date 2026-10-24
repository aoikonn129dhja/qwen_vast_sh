import importlib.util
import json
from pathlib import Path
import unittest


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "custom_nodes/ComfyUI-OpenPoseReference/pose_reference.py"
)
spec = importlib.util.spec_from_file_location("pose_reference", MODULE_PATH)
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


class ReferencePoseTests(unittest.TestCase):
    def test_scales_all_visible_points_without_mutating_input(self):
        source = [{
            "canvas_width": 100,
            "canvas_height": 200,
            "people": [{
                "pose_keypoints_2d": [0, 0, 1, 100, 200, 1, 0, 0, 0],
                "hand_left_keypoints_2d": [40, 80, 1],
                "face_keypoints_2d": [20, 40, 0.5],
            }],
        }]
        scaled = reference.center_scale_pose(source, 0.8)
        person = scaled[0]["people"][0]
        for actual, expected in zip(person["pose_keypoints_2d"][:6],
                                    [10, 20, 1, 90, 180, 1]):
            self.assertAlmostEqual(actual, expected)
        self.assertEqual(person["pose_keypoints_2d"][6:], [0, 0, 0])
        for actual, expected in zip(person["hand_left_keypoints_2d"], [42, 84, 1]):
            self.assertAlmostEqual(actual, expected)
        for actual, expected in zip(person["face_keypoints_2d"], [26, 52, 0.5]):
            self.assertAlmostEqual(actual, expected)
        self.assertEqual(source[0]["people"][0]["pose_keypoints_2d"][0], 0)

    def test_none_and_invalid_scale(self):
        self.assertIsNone(reference.center_scale_pose(None, 0.8))
        with self.assertRaises(ValueError):
            reference.center_scale_pose({"canvas_width": 1, "canvas_height": 1}, 0)

    def test_workflow_sends_reference_only_to_editor(self):
        workflow = json.loads(
            (MODULE_PATH.parents[2] / "workflows/2511-pose-reference-edit.json")
            .read_text(encoding="utf-8")
        )
        nodes = {node["id"]: node for node in workflow["nodes"]}
        editor = nodes[213]
        self.assertEqual(editor["type"], "OpenPoseStudioReference")
        self.assertEqual(editor["widgets_values"][-1], 0.8)
        self.assertEqual(editor["inputs"][2]["name"], "reference_image")
        self.assertIn([420, 208, 0, 213, 2, "IMAGE"], workflow["links"])
        self.assertEqual(nodes[208]["outputs"][0]["links"][-1], 420)
        generator_inputs = {port["name"]: port["link"] for port in nodes[170]["inputs"]}
        self.assertEqual(generator_inputs["image2"], 404)
        self.assertIsNone(generator_inputs["image3"])
        self.assertEqual(generator_inputs["output_resolution_image"], 406)
        self.assertIn([404, 213, 0, 170, 1, "IMAGE"], workflow["links"])
        self.assertIn([406, 207, 0, 170, 9, "IMAGE"], workflow["links"])
        self.assertFalse(any(link[1] == 208 and link[3] == 170 for link in workflow["links"]))
        for link_id, source, output_index, target, input_index, kind in workflow["links"]:
            self.assertIn(link_id, nodes[source]["outputs"][output_index]["links"])
            self.assertEqual(nodes[target]["inputs"][input_index]["link"], link_id)
            self.assertEqual(nodes[source]["outputs"][output_index]["type"], kind)
            self.assertEqual(nodes[target]["inputs"][input_index]["type"], kind)


if __name__ == "__main__":
    unittest.main()
