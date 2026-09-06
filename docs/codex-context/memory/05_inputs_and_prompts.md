# Inputs and prompts

## Image discovery
Default location:

```text
/workspace/qwen_batch/input/
```

Only files directly inside that directory are scanned. Subdirectories are deliberately ignored.

The discovered image list is frozen when `run_batch.sh` starts. Adding an image mid-run leaves it for the next run.

## `prompts.md` format
The project migrated away from JSON prompt arrays. The current prompt file is Markdown:

```markdown
# Qwen prompts

## 1
First prompt text...

## anything
Second prompt text...
```

Parser semantics:
- a level-2 heading (`##`) starts a prompt section;
- text on the `##` heading itself is a label only and is excluded from the prompt;
- `##`, `## 1`, `## Prompt 3`, etc. are valid;
- multi-line prompt bodies are supported;
- text before the first `##` is ignored;
- `###` does not start a new prompt.

Prompts are parsed once at batch startup. Editing `prompts.md` after the run header/count has been established affects the next run, not the current run.

## Practical edit rule
It is safe to prepare the next run's `prompts.md` while a batch is already running, as long as the edit occurs after the current run has already read its prompts. Avoid saving exactly during startup file reading.
