# Environment profilers

These scripts produce redacted system summaries for bug reports:

- `ableton-linux-profiler.sh`
- `ableton-macos-profiler.sh`
- `ableton-windows-profiler.ps1`

Each profiler prints a Markdown-formatted summary. It also copies the summary
when a supported clipboard tool is available. Review the output before sharing
it.

- **Linux:** distribution and kernel, CPU model and count, memory, system
  vendor/product, OpenGL vendor/renderer/version, desktop and session
  type, PipeWire/WirePlumber state and versions, audio devices, MIDI
  devices.
- **macOS:** OS version, hardware model, CPU, memory, audio devices
  (device names generalised), installed Ableton Live versions.
- **Windows:** OS, CPU, memory, system model, graphics, audio, MIDI, and
  installed Ableton Live versions.

## Redaction scope

All three profilers apply these rules:

- The configured home-directory string becomes `<HOME>` wherever it appears.
- Native account paths replace the account name with `<USER>`:
  `/home/<name>` on Linux, `/Users/<name>` on macOS, and
  `C:\Users\<name>` on Windows.
- MAC addresses become `<MAC>`, and email addresses become `<EMAIL>`.
- Lines keyed by unique identifiers are removed. These include serial
  numbers, UUIDs, GUIDs, asset tags, processor IDs, device IDs, addresses,
  location IDs, and mount points.
- Credential and licence values become `<key>=<REDACTED>`. The patterns cover
  passwords, tokens, secrets, API keys, `MachineGuid`, `Unlock.json`, and
  Ableton serial or licence fields.

The Linux profiler also replaces `/run/user/<uid>` with `/run/user/<UID>` and
LUKS volume UUIDs with `luks-<REDACTED>`. The macOS profiler also removes
lines keyed by BSD names.

The tester-kit collector also replaces captured window titles and removes
credential-like lines.

## Privacy gate

`check-profiler-privacy.sh` checks for forbidden collection patterns, required
redaction rules, and private values in a mocked macOS profiler run. Run it after
editing a profiler or collector. A report containing excluded data is a
collector failure. Keep it local.

```bash
./beta/scripts/check-profiler-privacy.sh
```
