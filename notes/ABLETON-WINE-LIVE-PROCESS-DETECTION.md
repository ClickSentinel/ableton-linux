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

The implementation is not to be designed — it already exists on
`fix/ableton-linkd-better-installer` (PR #120) and is better than a pattern
match can be. `runtime_pids()` walks `/proc/[0-9]*`, resolves each `exe`
symlink, and keeps the pids whose binary lives under the runtime root:

```sh
for d in /proc/[0-9]*; do
    case "$(readlink "$d/exe" 2>/dev/null)" in
        "$OPT/$NAME"/*) printf '%s\n' "${d#/proc/}" ;;
    esac
done
```

Its own comment carries the reason every `pgrep -f` site here is structurally
incomplete: Wine's in-prefix helpers show a Windows path in argv
(`C:\windows\system32\...`), so **no command-line pattern reaches them**. The
`exe` link is the real binary — the preloader every in-prefix process runs
from — so the match is exact rather than a guess, immune to self-matching, and
unaffected by Live's version naming.

Both predicates are there too. `ableton_up()` takes `/proc` first and keeps
`pgrep` as an explicit second opinion, because detection failing open means
installing over a running runtime. `live_up` walks only runtime-scoped pids and
reads their cmdline, so a Live under an unrelated Wine install is neither
prompted for nor killed.

So the consolidation is promote-and-delete, not design-and-write: lift these
into the shared helper once PR #120 lands, then remove the five other dialects.
`live_pid` for `bench-run.sh` and `m4l-hang-capture.sh` falls out of
`runtime_pids` directly.

This does not make every `pgrep` site wrong. Live's own process does carry a
visible cmdline, so the launcher's liveness guard works; what `pgrep` misses is
the support processes, which is precisely why the installer needed `/proc` and
the launcher did not. Same split, different requirements.

One constraint the better implementation introduces: `/proc/PID/exe` cannot be
stubbed through `PATH` the way `pgrep` can, so the helper needs a seam —
reading `${ABLETON_PROC_ROOT:-/proc}` lets tests point it at a fixture tree of
fake `exe` symlinks. Without it the accurate implementation is also the
untestable one, trading one hermeticity problem for another.

## Sequencing

PR #120 has landed, so nothing blocks this. The implementation it promotes is
in `install.sh` on main today; the work is to lift it out and delete the five
other dialects.
The shape no longer needs agreeing — PR #120 settles it. What should be agreed
*before* it lands is the `${ABLETON_PROC_ROOT:-/proc}` seam, because retro-
fitting testability into a helper several scripts already source is harder than
building it in, and because without it the consolidation would delete five
testable-in-principle dialects in favour of one that cannot be tested at all.

The beta tester kit and `tools/` can follow separately; they are diagnostics,
not shipped paths, and their version-pinned patterns are the least urgent
because they fail visibly to whoever is running them.

## Status

Unblocked and not started. PR #120 landed the `/proc` implementation inside
`install.sh`; the remaining five dialects are untouched, and the only other
change so far is to the test harness.

One consequence already surfaced. PR #120's three new runtime-scoped sites
hardcoded `$OPT/$NAME`, which collided with this branch's `ABLETON_WINE_ROOT`
work: resolved naively, `runtime_pids` would have scanned the default path
while the install swapped the overridden one, so the gate would find nothing
and the wrong wineserver would be stopped. That is the shape of every future
collision here — a safety predicate and a path resolver that must agree — and
it is the argument for one helper rather than six.

## Limits

Nothing here is a live bug report. The divergences are latent: no issue traces
to them, and the launcher's own pattern has been correct in production. The
case for consolidating is that the installer gate and the launcher guard are
one concept implemented six ways, that two implementations will silently stop
working at Live 13, and that none of them can be tested where they are.

The stub added to `launcher_sandbox` fixes the test harness, not the scripts.
It makes the launcher's six checks deterministic under test; it does nothing
for the other eight sites, which remain untested.
