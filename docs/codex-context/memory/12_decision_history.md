# Decision history

## Prompts: JSON → Markdown
The project moved from `prompts.json` to `prompts.md` so prompts are easier to author/edit. Level-2 Markdown headings delimit prompt blocks.

## Final output path moved out of ComfyUI
Generated files are ultimately collected under `/workspace/qwen_batch/output/<RUN_ID>/` rather than treating `/workspace/ComfyUI/output/...` as the user-facing final location.

## Preview added to batch runner
A simple browser preview was preferred over Jupyter terminal image rendering. It follows the current run and exposes generated images through a Quick Tunnel.

## Preview hardened with Basic Auth
Initially the Quick Tunnel preview was unauthenticated. It was changed to Basic Auth with fixed username `qwen` and a random password.

## Generic static serving removed
The preview server uses explicit routes with `BaseHTTPRequestHandler` to avoid accidentally exposing unrelated files from the server working directory.

## Password lifetime changed
Generating a new password on every batch was inconvenient. The design changed so the first batch in a rented instance creates `/workspace/qwen_preview/password.txt`, and later runs reuse it. The secret remains outside Git and disappears on Destroy.

## Keep architecture lightweight
A ChatGPT-like full web UI was considered technically feasible but rejected for now. The user wants to preserve the existing setup → upload inputs/prompts → run workflow with minimal moving parts.

## Completion notification choice
External push services were considered but rejected for now. The chosen direction is a ~5-second browser alert from the already-open preview page.
