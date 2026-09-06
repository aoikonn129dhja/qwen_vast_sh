# Known drift, constraints, and failure modes

## Version drift
- GitHub `main/run_batch.sh` is older than the verified password-persistent snapshot in this handoff.
- The real local working tree may be newer than both. Always inspect before overwriting.
- Historical README/handbook versions repeatedly lagged behind implementation (for example `prompts.json` vs `prompts.md`, old output paths).

## Setup text drift
Current GitHub setup output still mentions `prompts.json`; intended batch format is `prompts.md`.

## Preview/Tunnel lifecycle
- Quick Tunnel URL can change after process restart/Stop→Start.
- Password should remain stable for the same rented instance because it is stored under `/workspace`.
- Never put that runtime password in Git.

## Browser audio limitations
The requested completion alert runs in a browser environment. Background tabs/minimized windows can be timer-throttled, and autoplay policy can block untrusted audio starts. Implement best-effort Web Audio without changing the user's normal workflow; do not claim a universal browser guarantee.

## Temporary data growth
The batch design creates per-run temporary/staging directories such as:
- `/workspace/ComfyUI/input/batch/<RUN_ID>/`
- `/workspace/qwen_batch/tmp/<RUN_ID>/`

Historically these were not always automatically removed. Check current code before adding cleanup. Cleanup must not delete data needed by an active run or preview.

## Filename collision/data-loss rule
Never overwrite generated user images silently. Any flatten/move/rename operation must detect collision and preserve both files.

## Cloudflare exposure
Authenticated live preview routes output images through Cloudflare Quick Tunnel. ComfyUI itself should stay localhost-bound. Setup may separately expose ComfyUI GUI through its own Quick Tunnel; this is distinct from authenticated preview.
