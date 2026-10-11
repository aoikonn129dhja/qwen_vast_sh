FROM pytorch/pytorch:2.11.0-cuda13.0-cudnn9-runtime@sha256:bfbb4a2b4fdba0fefdb428ea737e626d61bb3daf74a16e1ff935bdb03aa7c3f0
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends bash git wget curl ca-certificates socat procps libgl1 libglib2.0-0 ffmpeg && rm -rf /var/lib/apt/lists/*
RUN wget -q -O /tmp/uv.tar.gz https://github.com/astral-sh/uv/releases/download/0.11.28/uv-x86_64-unknown-linux-gnu.tar.gz && echo 'e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224  /tmp/uv.tar.gz' | sha256sum -c - && tar -xzf /tmp/uv.tar.gz -C /tmp && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu
RUN uv venv --python /usr/bin/python3.12 --system-site-packages --seed /venv/main && mkdir -p /workspace
RUN uv pip install --python /venv/main/bin/python aiohttp==3.14.3
RUN /venv/main/bin/python -c "import torch; assert torch.__version__ == '2.11.0+cu130'"
ENV PATH="/venv/main/bin:$PATH" WORKSPACE=/workspace COMFY_DIR=/workspace/ComfyUI PYTHON=/venv/main/bin/python
WORKDIR /workspace/qwen_vast_sh
COPY models/ models/
COPY scripts/ scripts/
COPY salad/common/auth_proxy.py /opt/salad/auth_proxy.py
COPY salad/start.sh /opt/salad/start.sh
COPY salad/select_model.sh /opt/salad/select_model.sh
EXPOSE 8189
CMD ["bash", "/opt/salad/start.sh"]
