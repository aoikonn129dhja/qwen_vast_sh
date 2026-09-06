# Output and flattening

## Current run output
Final generated images are moved to:

```text
/workspace/qwen_batch/output/<RUN_ID>/
```

A typical output root can therefore accumulate many run folders:

```text
/workspace/qwen_batch/output/
├─ 20260905_200239/
├─ 20260905_202623/
├─ 20260905_203356/
└─ ...
```

This is good for run isolation and preview state, but downloading many folders through Jupyter can produce many ZIP downloads.

## `flatten_output.sh` requirement
The user introduced/asked for a separate flatten operation with this goal:
- destroy the per-session folder structure after generation;
- gather PNG files into one newly created directory;
- destination name: `/workspace/qwen_batch/output/yyyy_mmdd_hhmm/`;
- final directory contains many PNGs directly;
- filename collisions must never overwrite data.

The previously agreed collision-safe naming strategy was:

```text
<source_RUN_ID>__<original_filename>
```

If that still collides, append a numeric suffix rather than overwrite.

Important: the actual latest local `flatten_output.sh` file was not available to this handoff. Treat this as a behavioral spec. If the real repository has a file, inspect it before editing/replacing it.

Do not flatten/move an active run's output while `run_batch.sh` is still using it for live preview/state updates.
