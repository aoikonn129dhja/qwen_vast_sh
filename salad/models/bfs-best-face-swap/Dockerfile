FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04@sha256:9175fa92f96de35a8cfb9493f0dfcf9435c7a597e9d95ad41d2cae382a95e3f9
WORKDIR /opt
ENV DEBIAN_FRONTEND=noninteractive UV_NO_CACHE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends bash git wget curl ca-certificates socat python3.12 python3.12-venv libgl1 libglib2.0-0 ffmpeg && rm -rf /var/lib/apt/lists/*
# Verified uv distribution; no global pip installation.
RUN wget -q -O /opt/uv.tar.gz https://github.com/astral-sh/uv/releases/download/0.11.28/uv-x86_64-unknown-linux-gnu.tar.gz && echo 'e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224  /opt/uv.tar.gz' | sha256sum -c - && tar -xzf /opt/uv.tar.gz -C /opt && install -m 0755 /opt/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && rm -rf /opt/uv.tar.gz /opt/uv-x86_64-unknown-linux-gnu && uv venv --python /usr/bin/python3.12 /opt/venv
ENV PATH="/opt/venv/bin:$PATH" COMFY_DIR=/opt/ComfyUI PYTHON=/opt/venv/bin/python
COPY salad/common/ /opt/salad/common/
COPY vast/models/qwen-rapid-aio-nsfw-v19/requirements.lock /opt/profile/requirements.lock
COPY salad/models/bfs-best-face-swap/ /opt/salad/model/
RUN bash /opt/salad/common/setup_qwen21.sh
COPY salad/common/watch_qwen_download.sh /watch_qwen_download.sh
EXPOSE 8189
CMD ["bash", "/opt/salad/model/start.sh"]
