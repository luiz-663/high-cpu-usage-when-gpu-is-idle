# Changelog

## 0.1.3 — 2026-11-18

- Make option 2 show what it is doing at each stage. It reports when it measures System CPU under repeated NVIDIA GPU performance queries, saves or verifies the backup, applies and checks the workaround, and repeats the measurement.
- Show the average System CPU usage before and after the workaround in a boxed comparison. If the final measurement fails, explain that the comparison is incomplete.
- Update the download and usage instructions with the new workflow and the approximate one-minute runtime.

## 0.1.2 — 2026-11-17

- Adopt **High CPU Usage When the GPU Is Idle** as the user-facing title, with **Experimental Windows workaround** as the subtitle.
- Update the repository address, download filename, launcher, menu, and documentation links.
- Keep the explanation of the specific DxgKrnl/DiagLog query interaction and all existing backup/registry behavior.
- Link the related NVIDIA GeForce Forums discussion and r/WindowsHelp post, distinguishing community reports from the project's own evidence.

## 0.1.1 — 2026-11-17

- Rename the project to **DxgKrnl DiagLog CPU Workaround** to identify the diagnostic/performance-query interaction rather than imply GPU inactivity alone is the cause.
- Update repository links, launcher title, menu, and distribution filename.
- Keep the existing data directory, installation-bound backup format, and registry/ETW behavior unchanged for compatibility.

## 0.1.0 — 2026-11-17

Initial experimental public release, originally titled GPU Idle CPU Workaround. Its release assets and checksums remain available as historical artifacts.
