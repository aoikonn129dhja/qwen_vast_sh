#!/usr/bin/env bash
set -Eeuo pipefail
bash /opt/salad/model/prepare_models.sh
exec bash /opt/salad/common/start_comfyui.sh
