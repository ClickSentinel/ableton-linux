# Consolidating the "is Live running?" check (2026-08-03)

Nine scripts ask whether Ableton Live is running and no two of them ask the
same question. Six distinct patterns are in tracked code, spread across the
launcher, the installer, three diagnostic scripts, the beta tester kit and the
hang-capture tool. They disagree about which processes count, whether the
prefix matters, whether the Live major version is hardcoded, and whether the
pattern excludes itself. The launcher alone asks six times, in two spellings.

This is not tidiness. The installer's check is a safety gate on a file swap
and the launcher's is a concurrency guard on a launch; today they can return
different answers about the same machine, and none of them can be tested
without a PATH shim.

## Dialects

| Site | Pattern |
| --- | --- |
| `ableton-live` (121, 188, 203, 460, 465, 710) | `pgrep -af "Ableton Live.*\.exe"` piped to `grep ProgramData` |
| `install.sh` (58-59) | `pgrep -af '[A]bleton Live.*\.exe\|[P]ush2DisplayProcess.exe'`, or `pgrep -af "$OPT/$NAME"` |
| `check-live-audio.sh` (32), `setup-link.sh` (20) | `pgrep -f "Ableton Live.*\.exe"`, no prefix filter |
| `beta/tester-kit/lib/run-probes.sh` (336, 373) | `pgrep -f 'Ableton Live 12.*[.]exe'` |
| `bench-run.sh` (56) | `pgrep -f 'Ableton Live.*\.exe' \| head -n 1`, wants a PID |
| `tools/m4l-hang-capture.sh` (24) | `pgrep -f 'Ableton Live [0-9]+ .*\.exe' \| head -1` |

The same fragmentation exists one layer down. `wineserver` is found by
`pgrep -x wineserver` in `check-m4l-fonts.sh` and `check-ntsync.sh` but by
`pgrep -f "$WINE_ROOT.*bin/wineserver"` in `bench-run.sh` — only the second is
scoped to this build's server. The `ableton-linkd` guard is byte-identical in
`ableton-live` (791) and `max9` (46).

## Consequences

The two checks that must agree, don't. `install.sh` refuses to install over a
running Live because it is about to swap the runtime tree underneath it, so it
also counts `Push2DisplayProcess.exe` and anything running out of
`$OPT/$NAME`. The launcher counts neither. A Push 2 display process outliving
Live blocks an install while the launcher considers the machine idle; a
process under the runtime path does the same.

Self-matching is handled in one place only. `install.sh` uses the `[A]bleton`
bracket idiom so the pattern cannot match a shell whose own command line
carries it. The launcher does not. `pgrep` excludes its own PID but not a
parent or sibling shell, so any wrapper that passes the pattern or an install
path on a command line trips the launcher's guard. This is observable: a
diagnostic shell command containing the pattern matches itself.

Two sites pin a Live version. `run-probes.sh` hardcodes `Live 12` and
`m4l-hang-capture.sh` requires a `Live <digits>` prefix. Both stop matching
when the naming changes — no error, just a probe that reports nothing and a
capture tool that finds no PID. The launcher's pattern survives the same
change, so the failure is partial and quiet.

None of it is testable as written. Every one of these reads the host process
table, which no environment variable redirects. That is why `launcher-cli.bats`
failed three tests on any developer machine with Live open until
`stub pgrep 1` was added to `launcher_sandbox` — the launcher took the
"already running" branch and skipped the code under test. Every other script
here has the same property and no tests at all.

## Shape

One sourced helper, following the pattern the repo already uses for
`detect-scale.sh` and `detect-theme.sh`: staged into the kit by
`make-installer.sh`, installed to `~/.local/share/ableton-wine/`, sourced by
the launcher at start. The mechanism, the install path and the packaging test
that enforces staging all exist already — `packaging.bats` asserts that every
script a kit script sources is itself staged, so that invariant applies the
moment anything sources it.

Two named predicates, not one, because the breadth difference is deliberate:

- `live_running` — a Live process for this prefix. The launch serialisation
  and re-sync guards want this.
- `runtime_busy` — anything executing out of the installed runtime, including
  `Push2DisplayProcess.exe`. The installer's swap gate wants this, and
  flattening it into `live_running` would make the installer weaker.

Plus `live_pid` for `bench-run.sh` and `m4l-hang-capture.sh`, and
`wineserver_running` / `linkd_running` for the remaining duplicates. One
pattern, one self-exclusion idiom, no hardcoded major.

## Sequencing

`pr119-installer-family` is editing `install.sh` and merges soon. Doing the
consolidation after it lands avoids a conflict in the file that matters most.
But the helper's shape should be settled before then, because `install.sh`
holds the broadest predicate and is therefore the one that constrains the
design — agreeing `runtime_busy` after the fact means revisiting the installer
a second time.

The beta tester kit and `tools/` can follow separately; they are diagnostics,
not shipped paths, and their version-pinned patterns are the least urgent
because they fail visibly to whoever is running them.

## Status

Open, and intended to be resolved rather than filed and forgotten. Nothing in
this note has been consolidated: all six dialects are still in tracked code as
described. The only change made so far is to the test harness, not the
scripts. The work is sequenced behind `pr119-installer-family` for the reason
given above, which is a scheduling decision, not a deferral.

## Limits

Nothing here is a live bug report. The divergences are latent: no issue traces
to them, and the launcher's own pattern has been correct in production. The
case for consolidating is that the installer gate and the launcher guard are
one concept implemented six ways, that two implementations will silently stop
working at Live 13, and that none of them can be tested where they are.

The stub added to `launcher_sandbox` fixes the test harness, not the scripts.
It makes the launcher's six checks deterministic under test; it does nothing
for the other eight sites, which remain untested.
