#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/setup_base.sh
source /opt/profile/model.conf
clone_pinned https://github.com/Fannovel16/comfyui_controlnet_aux.git "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux" 0cd290477128d42cdc3e76a826a402d866e8c684
clone_pinned https://github.com/dalai2/ComfyUI-AnimePose.git "$COMFY_DIR/custom_nodes/ComfyUI-AnimePose" 315e758b17a578a7efb9b3eb95fdf4061d256866
for node in comfyui_controlnet_aux ComfyUI-AnimePose; do
    if [ -f "$COMFY_DIR/custom_nodes/$node/requirements.txt" ]; then
        uv pip install --python "$PYTHON" -r "$COMFY_DIR/custom_nodes/$node/requirements.txt"
    fi
done
"$PYTHON" - /opt/profile "$COMFY_DIR/user/default/workflows" "$WORKFLOW_SOURCE" "$WORKFLOW_FILE_NAME" "$WORKFLOW_REPLACE_FROM" "$WORKFLOW_REPLACE_TO" <<'PY'
import json,sys
from pathlib import Path
src,dest,relative,name,old,new=sys.argv[1:]
text=(Path(src)/relative).read_text()
if old:
    text=text.replace(old,new)
json.loads(text)
(Path(dest)/name).write_text(text)
PY
