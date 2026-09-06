# Current pending request

The user most recently asked for two changes to the existing `run_batch.sh` while preserving the current workflow and architecture:

1. **Browser completion alert**
   - Use the already-open live preview page.
   - Play an alert for about **5 seconds** when the batch reaches completion.
   - The browser/PC is expected to remain open, but the preview tab may be backgrounded and the browser may be minimized to the Windows taskbar.
   - Do not add a new setup/operation step or external notification service.
   - Prefer the existing embedded preview HTML/JS and Web Audio API; no extra audio file is required unless there is a strong technical reason.
   - Browser autoplay/background throttling constraints must be handled as gracefully as possible without changing the user's normal three-step workflow.

2. **Per-output timing in the shell**
   - After each generated output, print how many seconds that output took.
   - Also print the running average after every completed output.
   - The user's wording was “平均秒数(枚/s)”; to remove unit ambiguity in implementation/output, it is reasonable to show both `s/image` and `images/s` if this remains concise.

These changes were requested but **were not implemented** before this handoff was created.
