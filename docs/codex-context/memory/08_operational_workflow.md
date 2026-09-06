# Operational workflow

## User's preferred invariant
The normal flow must stay this simple:

```text
1. setup
2. put images + prompts.md in place
3. run run_batch.sh
```

The user explicitly does not want to add mandatory steps such as:
- opening/configuring another service;
- manually creating notification subscriptions;
- starting a second server by hand;
- running an npm build;
- setting a new password every batch.

## During a run
- Adding files to `input/`: does not affect the active run; picked up next run.
- Editing `prompts.md`: does not affect the active run after startup parsing; picked up next run.
- Starting a second `run_batch.sh` concurrently: avoid. Preview PID files/port/tunnel and output state are not designed for concurrent independent runners.
- Running flatten-output while generation is active: avoid.

## Interruption semantics
`Ctrl+C` stops the shell runner, but a ComfyUI job already submitted/running may continue briefly because it is a separate process/service.

## Preview use
The preview page is typically kept open on the user's Windows PC. It may be in a background tab or the browser may be minimized to the taskbar. This matters for the pending browser-audio alert.
