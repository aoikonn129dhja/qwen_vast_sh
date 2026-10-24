"""Keep pose estimation and generation separate without reconnecting nodes."""


class QwenPoseStage:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {"stage": (["estimate", "generate"],)},
            "optional": {"detected_pose": ("POSE_KEYPOINT", {"lazy": True})},
        }

    RETURN_TYPES = ("POSE_KEYPOINT", "BOOLEAN")
    RETURN_NAMES = ("pose_for_editor", "generate")
    FUNCTION = "select"
    CATEGORY = "Qwen/Pose"

    def check_lazy_status(self, stage, detected_pose=None):
        return ["detected_pose"] if stage == "estimate" and detected_pose is None else []

    def select(self, stage, detected_pose=None):
        if stage == "estimate":
            if detected_pose is None:
                raise ValueError("Connect a pose estimator before estimating")
            return detected_pose, False
        if stage != "generate":
            raise ValueError(f"Unknown pose stage: {stage}")
        # OpenPose Studio uses its edited pose_json widget when this is None.
        return None, True


class QwenPoseResult:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "generate": ("BOOLEAN", {"forceInput": True}),
            "pose_preview": ("IMAGE", {"lazy": True}),
            "generated_image": ("IMAGE", {"lazy": True}),
        }}

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "select"
    CATEGORY = "Qwen/Pose"

    def check_lazy_status(self, generate, pose_preview=None, generated_image=None):
        name, value = ("generated_image", generated_image) if generate else ("pose_preview", pose_preview)
        return [name] if value is None else []

    def select(self, generate, pose_preview=None, generated_image=None):
        result = generated_image if generate else pose_preview
        if result is None:
            raise ValueError("The selected pose workflow branch has no image")
        return (result,)


NODE_CLASS_MAPPINGS = {"QwenPoseStage": QwenPoseStage, "QwenPoseResult": QwenPoseResult}
NODE_DISPLAY_NAME_MAPPINGS = {
    "QwenPoseStage": "1. Pose stage: estimate / generate",
    "QwenPoseResult": "Pose preview / generated result",
}
