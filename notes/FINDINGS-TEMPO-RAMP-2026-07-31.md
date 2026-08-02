# Findings: tempo ramp timing differs from Windows (issue 101)

Investigation record as of 2026-07-31. No fix exists yet. This note states
what the report shows, which causes are ruled out, what the sample project
predicts, and which tests come next.

Issue: <https://github.com/shibco/ableton-linux/issues/101>

## The report

Immabed reported on 2026-07-30, from a machine that boots both Windows and
Linux: a Live project that contains tempo ramps plays and exports with
different timing under ableton-linux than on Windows. A tempo ramp is a tempo
automation segment where the tempo changes gradually from one value to the
next.

Three observations, all from the same projects on the same machine:

- A track rendered to an audio file on Windows drifts against the same track
  played live under ableton-linux. The drift appears only across tempo ramps.
- The same loop exported on both systems produces audio files of different
  lengths: about 0.33 seconds over a 7 minute song, or 0.08 percent.
- Several older backups of the project reproduce the difference exactly, so
  the difference is stable and repeatable, not random variation.

Reporter environment: NixOS 26.05, PipeWire 1.6.6 with the graph rate fixed
at 48000 Hz by their own system configuration, Version33's flake at commit
`f9e033a` (contains upstream release 2026.07.29.1 unchanged), Wine 11.13,
Live 12.4.3 on the Linux side. Their Windows Live version is unknown.

## Ruled out

- **Release 2026.07.29.1.** The release changed window handling, graphics,
  the installer, and documentation. It changed no audio code. No earlier
  release is known to behave differently, so nothing marks this as a
  regression.
- **Everything that only acts during live playback.** The exported files
  differ in length. Export renders audio directly to a file and reads no
  clock and no audio device timing. This rules out ntsync, thread scheduling,
  QueryPerformanceCounter, and PipeASIO patch 0002, which only changes the
  timestamp reported to Live for incoming MIDI.
- **The Wine patch series (0001 to 0056).** No patch in the series touches
  the Windows math libraries (msvcrt, ucrtbase) or the code that advances
  Live's playback position.
- **Version33's flake.** The flake builds the same Wine source archive,
  verifies the patch series against `patches/SERIES.sha256`, builds the same
  PipeASIO 1.2.2 with the same two patches, and cross-compiles the Windows
  side with clang, as the container build does. Its `pipeasioSettings`
  option defaults to empty, and it ships the unmodified `setup-prefix.sh`,
  so flake users receive the same seeded PipeASIO configuration. The
  remaining differences (compiler point version, the nixpkgs copy of
  libpipewire) are far too small to move timing by 0.08 percent.

## Environment facts that matter

- PipeASIO patch 0001 keeps the PipeWire graph rate when Live asks for a
  different rate. The reporter's graph allows only 48000 Hz, so Live runs at
  48000 Hz there even for a project made at 44100 Hz. On Windows the same
  project presumably ran at its own rate.
- `setup-prefix.sh` seeds `~/.config/pipeasio/config.ini` with a fixed
  buffer of 256 frames. `PIPEASIO_*` environment variables override the file
  per launch.
- The reporter's PipeWire readout showed a block size of 1024, but it was
  taken while Live was closed. The block size in effect while Live runs is
  unconfirmed. `pw-top` during playback answers this.

## The sample project

The reporter provided `tempo_ramp_test Project` (a Collect and Save copy).
Reading the project file directly shows:

- One linear tempo ramp from 70 to 150 beats per minute across beats 0 to
  128, then a constant 150 to the loop end at beat 160.
- The file was saved by Live 12.4.3, the reporter's Linux install. A project
  file records the saving Live version in its `Creator` attribute:
  `gunzip -c file.als | head -c 200` prints it.

The exact duration of a linear ramp between beats b1 and b2 with tempos T1
and T2 is `60 * (b2 - b1) / (T2 - T1) * ln(T2 / T1)` seconds. For this
project the full 160-beat loop lasts 85.965445 seconds, which is 4,126,342
samples at 48000 Hz.

## Simulation: tempo held constant per audio buffer

Audio engines process samples in fixed-size groups called buffers. A common
design evaluates tempo automation once per buffer and holds that tempo until
the next buffer. Under that design the rendered length of a ramp depends on
buffer size and sample rate. A script integrated the sample project's ramp
under that model:

| buffer and rate  | length (s) | above exact (ms) |
|------------------|------------|------------------|
| 1 at 48000       | 85.96545   | 0.01             |
| 64 at 48000      | 85.96595   | 0.51             |
| 128 at 48000     | 85.96646   | 1.02             |
| 256 at 48000     | 85.96748   | 2.03             |
| 256 at 44100     | 85.96766   | 2.21             |
| 512 at 48000     | 85.96951   | 4.07             |
| 1024 at 48000    | 85.97357   | 8.13             |
| 2048 at 48000    | 85.98170   | 16.26            |

Two results follow:

- The effect is measurable. Exporting this project at buffer 64 and again at
  buffer 2048 changes the file length by 15.8 milliseconds, 756 samples at
  48000 Hz.
- The effect is too small to explain the report. Plausible Windows and Linux
  setting pairs differ by at most about 2 milliseconds on this project. In
  general the error is about half the buffer duration multiplied by the sum
  of `ln(end tempo / start tempo)` over all ramps, which stays in the low
  tens of milliseconds for a full song at normal buffer sizes. The reported
  difference is 330 milliseconds. Per-buffer tempo evaluation at normal
  settings cannot produce it.

## Hypothesis ranking, 2026-07-31

1. **Different Live versions on the reporter's Windows and Linux installs.**
   The only candidate with no size limit. It fits every observation: the
   difference is stable, appears only across ramps, and reproduces on old
   backups, because backups change the project and not the engine. Reading
   the `Creator` attribute of a Windows-saved backup confirms or removes it.
2. **Live evaluates tempo more coarsely than once per buffer.** The export
   test below would show a larger length change than the table predicts.
3. **Buffer size and sample rate differences between the two systems.**
   Real and measurable, but at most a few milliseconds per song. A
   contributor at best.
4. **Wine's built-in math functions.** Wine's ucrtbase implements math
   differently from Microsoft's, but the differences sit in the last binary
   digits. Far too small unless Live's own code multiplies them, which
   nothing currently suggests.

## Pending tests

1. **Export test on Linux. Needs no Windows machine.** Open the sample
   project, export the 160-beat loop at 48000 Hz twice, once per launch
   setting: `PIPEASIO_PREFERRED_BUFFERSIZE=64` and
   `PIPEASIO_PREFERRED_BUFFERSIZE=2048`. Compare lengths with
   `soxi -s file.wav`. Readings:
   - Equal lengths: export ignores the device buffer size. Hypotheses 2 and
     3 lose their export-side support.
   - About 756 samples apart: matches per-buffer evaluation. Hypothesis 3 is
     confirmed as a mechanism and stays too small to explain the report
     alone.
   - Much further apart: Live evaluates tempo more coarsely than per buffer.
     Hypothesis 2 leads.
2. **Ask the reporter** for the `Creator` line of a Windows-saved backup,
   `pw-top` output while Live plays, and the buffer size and sample rate
   their Windows setup uses.
3. **On Windows, once available:** export the same loop twice at two buffer
   sizes there. Different lengths would show Live behaves this way on every
   platform, and the issue becomes a settings-matching problem to document
   rather than a defect in this project.

## Status

Open. No code change proposed. The export test and the `Creator` check are
the next actions.
