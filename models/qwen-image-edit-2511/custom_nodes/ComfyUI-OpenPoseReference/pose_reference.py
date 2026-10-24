"""Coordinate adjustment for OpenPose Studio's centered reference preview."""

from copy import deepcopy


KEYPOINT_FIELDS = (
    "pose_keypoints_2d",
    "face_keypoints_2d",
    "hand_left_keypoints_2d",
    "hand_right_keypoints_2d",
)


def center_scale_pose(pose_keypoint, scale):
    """Scale visible keypoints with a centered reference, preserving missing points."""
    if pose_keypoint is None:
        return None
    if not 0.1 <= scale <= 1.0:
        raise ValueError("reference_scale must be between 0.1 and 1.0")
    result = deepcopy(pose_keypoint)
    frames = result if isinstance(result, list) else [result]
    for frame in frames:
        width = frame["canvas_width"]
        height = frame["canvas_height"]
        offset_x = width * (1.0 - scale) / 2.0
        offset_y = height * (1.0 - scale) / 2.0
        for person in frame.get("people", []):
            for field in KEYPOINT_FIELDS:
                points = person.get(field)
                if not isinstance(points, list):
                    continue
                for index in range(0, len(points) - 2, 3):
                    if points[index + 2] <= 0:
                        continue
                    points[index] = points[index] * scale + offset_x
                    points[index + 1] = points[index + 1] * scale + offset_y
    return result
