FROM pytorch/pytorch:2.11.0-cuda13.0-cudnn9-runtime@sha256:bfbb4a2b4fdba0fefdb428ea737e626d61bb3daf74a16e1ff935bdb03aa7c3f0
WORKDIR /opt
ENV DEBIAN_FRONTEND=noninteractive UV_NO_CACHE=1 UV_SYSTEM_PYTHON=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends bash git wget curl ca-certificates socat libgl1 libglib2.0-0 ffmpeg && rm -rf /var/lib/apt/lists/*
# Verified uv distribution; no global pip installation.
RUN wget -q -O /opt/uv.tar.gz https://github.com/astral-sh/uv/releases/download/0.11.28/uv-x86_64-unknown-linux-gnu.tar.gz && echo 'e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224  /opt/uv.tar.gz' | sha256sum -c - && tar -xzf /opt/uv.tar.gz -C /opt && install -m 0755 /opt/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && rm -rf /opt/uv.tar.gz /opt/uv-x86_64-unknown-linux-gnu
ENV COMFY_DIR=/opt/ComfyUI PYTHON=/usr/local/bin/python
COPY salad/common/ /opt/salad/common/
COPY salad/models/qwen-image-edit-2511/requirements-runtime.lock /opt/profile/requirements-runtime.lock
COPY salad/models/qwen-image-edit-2511/verify_runtime.py /opt/profile/verify_runtime.py
RUN bash -c 'source /opt/salad/common/setup_base.sh; clone_pinned https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR" "$COMFYUI_COMMIT"; uv pip install --system --python "$PYTHON" --no-deps --require-hashes -r /opt/profile/requirements-runtime.lock; uv pip check --system --python "$PYTHON"; mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/input" "$COMFY_DIR/output"; "$PYTHON" /opt/profile/verify_runtime.py'
COPY salad/models/qwen-image-edit-2511/ /opt/salad/model/
COPY vast/models/qwen-image-edit-2511/model.conf /opt/profile/model.conf
COPY vast/models/qwen-image-edit-2511/workflows/ /opt/profile/workflows/
RUN bash /opt/salad/model/setup.sh && uv pip check --system --python "$PYTHON" && "$PYTHON" /opt/profile/verify_runtime.py
COPY salad/common/watch_qwen_download.sh /watch_qwen_download.sh
EXPOSE 8189
CMD ["bash", "/opt/salad/model/start.sh"]
