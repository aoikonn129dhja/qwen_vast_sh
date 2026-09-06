# Codex handoff context

This bundle is a compact handoff for the `amamisa4/qwen_comfy_sh` project.

It follows the OpenAI Codex guidance used for this handoff:
- keep `AGENTS.md` short and use it as a navigation/index layer;
- put deeper durable project knowledge in structured files;
- keep instructions specific, testable, and close to the code they govern;
- avoid stuffing a monolithic manual into `AGENTS.md`.

`memory/` contains project facts, decisions, invariants, known drift, and pending requirements. `snapshot/run_batch.sh` is the newest verified implementation available in this conversation and should be compared with the actual local/GitHub repository before edits.

No runtime password or other secret is included in this archive.
