---
name: Bug report
about: Report a problem with Ableton Live on Linux
---

## What happened

<!-- Describe the problem and what you expected instead. -->

## Steps to reproduce

1.

## System summary

Run the profiler on the affected machine from the root of this repository. It
prints a redacted system summary and copies it when a supported clipboard tool
is available.

If the same setup works on macOS or Windows, add that profiler's output for
comparison.

- Linux: `./beta/scripts/ableton-linux-profiler.sh`
- macOS: `./beta/scripts/ableton-macos-profiler.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File beta\scripts\ableton-windows-profiler.ps1`

Review the summary, then paste it here:
