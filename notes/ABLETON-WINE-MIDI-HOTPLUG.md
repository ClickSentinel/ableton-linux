# MIDI controller disconnect/reconnect (hotplug)

Status: patch 0028 reconnects a controller that Wine enumerated when Live
started. A controller first connected after startup still requires a Live
restart.

## Symptom

Without the patch, unplugging and reconnecting a MIDI controller while Live
runs leaves its input and LED feedback inactive until Live restarts.

## Cause

Wine's ALSA MIDI driver enumerates sequencer ports once per process.
Each open MIDI input or output subscribes to one ALSA `client:port` address.
Unplugging the device removes that client and its subscriptions. Wine did not
restore them when the port returned.

## Fix

[../patches/0028-winealsa-re-subscribe-MIDI-devices-when-they-reappea.patch](../patches/0028-winealsa-re-subscribe-MIDI-devices-when-they-reappea.patch)
changes `dlls/winealsa.drv/alsamidi.c`:

- `seq_open()` subscribes the driver's shared input port to the System
  Announce port `0:1`.
- On `SND_SEQ_EVENT_PORT_START`, the record thread rebuilds the WinMM display
  name, matches it to the startup device table, adopts the new address, and
  restores open input and output subscriptions.

## Verification

[../tools/fakectl.c](../tools/fakectl.c) supplies a fake controller, and
[../tools/midihot.c](../tools/midihot.c) listens for WinMM MIDI input.
Restarting the fake controller simulates a reconnect. The unpatched driver
stops receiving `MIM_DATA`; the patched driver resumes within one second,
including when the ALSA client ID changes. The same name-based match covers
raw kernel sequencer ports and PipeWire MIDI-Bridge ports.

## Limits

- Only devices present during startup enumeration can reconnect. Growing the
  table at runtime would race its unlocked indexes on other threads.
- Announce processing runs only while at least one MIDI input is open. Live
  keeps enabled inputs open.
- If two controllers have the same display name, the first table entry wins.
