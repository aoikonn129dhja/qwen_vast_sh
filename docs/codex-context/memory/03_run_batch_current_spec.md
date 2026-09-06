# Current `run_batch.sh` specification

## Default invocation

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

Default inputs:
- images: `/workspace/qwen_batch/input/`
- prompts: `/workspace/qwen_batch/prompts.md`
- workflow: `/workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json`
- final output: `/workspace/qwen_batch/output/<RUN_ID>/`

Optional positional form:

```bash
bash run_batch.sh <input_dir> <prompts.md> [workflow.json]
```

## Batch semantics
- The run is a Cartesian product: `number_of_images × number_of_prompts`.
- Images are discovered once at startup and stored in an array.
- Prompts are parsed once at startup and stored as base64 payloads.
- Therefore adding images or editing `prompts.md` after startup does not affect the current run.
- Top-level input directory only; nested directories such as `input/archive/` are ignored.

## Supported input extensions
- `.png`
- `.jpg`
- `.jpeg`
- `.webp`

## Execution path
For each image/prompt pair, the script prepares a workflow override and uses official `comfy-cli`.

Important historical bug already fixed in the verified snapshot/design:
- `--no-json` is a **global** comfy-cli option and must appear before the command:

```bash
/venv/main/bin/comfy --no-json --where local workflow set-slot ...
```

Putting `--no-json` after command-local options can fail and can lead to redirected JSON envelopes causing `workflow_not_api_format` errors.

## Optional generation overrides
Existing design supports environment-variable overrides such as:

```bash
DENOISE=0.8 \
STEPS=6 \
CFG=1 \
SAMPLER=er_sde \
SCHEDULER=beta \
WIDTH=1536 \
HEIGHT=2048 \
SEED=123 \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

Unspecified values remain those saved in the workflow JSON.
