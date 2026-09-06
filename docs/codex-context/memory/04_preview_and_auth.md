# Preview and authentication

## Current intent
The preview is intentionally lightweight and embedded in `run_batch.sh`; the user explicitly rejected replacing the system with a larger ChatGPT-like web UI for now.

## Authentication
- HTTP Basic Auth.
- fixed username: `qwen`
- password: 20-character alphanumeric random string.
- password is **not** stored in Git.
- password file: `/workspace/qwen_preview/password.txt`
- file mode is restricted (`chmod 600` in the design).

## Password lifetime
Desired/current persistent behavior:
- First `run_batch.sh` in a newly rented instance: generate password and store it under `/workspace`.
- Later runs in the same instance: reuse the same password.
- Same continuously Running instance: reuse the preview HTTP server/tunnel when alive, so URL and password remain stable.
- Stop → Start: `/workspace` survives, so password survives; processes die, therefore Quick Tunnel URL may change when restarted.
- Destroy → new Rent: `/workspace` is gone, so a new password is generated.

## Security-sensitive server behavior
The authenticated preview implementation uses `BaseHTTPRequestHandler`, not `SimpleHTTPRequestHandler`, and explicitly handles only known routes. Preserve this design so unexpected filesystem paths are not accidentally served.

Expected route classes:
- `/` / `/index.html`
- `/api/manifest`
- `/image/...`

Unknown routes should return 404. Authentication should be required before returning preview content/images.

## State / live following
The page polls preview state and follows the current run. `state.json` contains run/output state but must not contain the password.

Current UI supports concepts such as:
- current run and completed/total jobs;
- latest output;
- previous/next/latest navigation;
- auto-follow latest.

## Pending alert
The user wants a ~5 second completion alert from this existing preview page, with no new operational step. See `10_pending_requirements.md`.
