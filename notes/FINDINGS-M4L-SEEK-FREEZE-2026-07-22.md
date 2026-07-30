# Carbon Regulator (Creative Extensions) freeze on interaction, 2026-07-22 (OPEN, not Wine-fork-specific)

**Minimal known repro: drag a fresh Carbon Regulator instance into any
set, including a brand new empty one, and Live freezes.** Carbon
Regulator lives in Ableton's official Creative Extensions pack, under
**Racks > Sounds > Synth Rhythmic**. Not all of Creative Extensions is
affected — the user confirms other devices/racks from the pack work
fine; the bug is scoped to (at least) this specific instrument, and the
`Synth Rhythmic` subfolder is the leading suspect for a shared root
cause, since racks in the same subfolder plausibly share underlying
M4L/JS internals (not yet confirmed device-by-device — see open
questions). No project content, automation, or other devices are
required to reproduce it — this supersedes every earlier, narrower
framing in this document (which had this as a "transport reposition"
bug, then an "in-lane click on a specific track" bug, then a
"clicking/selecting this device" bug — each was a true but incomplete
observation, since all of them happened to involve Carbon Regulator).
It freezes instantly, is not conditional on transport state (playing or
stopped), and is 100% reproducible — not intermittent. Open question:
whether the freeze fires on drag-in itself or needs one more
interaction (a click/selection) right after — see finding 11. This
file records what is proven, what was ruled out, and where the
evidence for the next attempt is. No fix was attempted — see the
ENCORE differential test at the end, which changed the scope of this
entirely.

## Distinct from, but discovered while investigating, a separate real bug

While chasing this, a genuine and unrelated bug was found and fixed:
Wine's builtin `msvcp140.dll` is missing real C++ stdlib exports (e.g.
`std::basic_istream`'s move-assignment operator) that real plugins call,
producing a `wine: Call from ... to unimplemented function
msvcp140.dll.??4?$basic_istream@... aborting` crash. `setup-prefix.sh`
already restored the *native* DLL files onto disk, but never told Wine
to actually *load* them — Wine decides native-vs-builtin per DLL name
from `WINEDLLOVERRIDES` (env var or `HKCU\Software\Wine\DllOverrides`),
not from which file is newest/present. Confirmed via
`WINEDEBUG=+loaddll` that `msvcp140.dll` was loading as builtin despite
a real native file sitting in `system32`. Fixed in `setup-prefix.sh`
(commit 13dd8cc): now writes a `native` registry override for every VC++
redist DLL name it restores. Verified fixed: the specific abort is gone,
confirmed via the same trace showing `msvcp140.dll` loading as native.

That fix is real and worth keeping regardless of the freeze bug below —
they turned out to be two separate crashes on the same interaction path
(seeking the timeline on this project, with this M4L device loaded),
not one bug with two symptoms. Fixing the abort just revealed the
freeze underneath it.

## Proven, with evidence

1. **The freeze is not related to the msvcp140 fix.** It reproduces
   identically before and after that fix (the abort was one bug, the
   freeze is a separate one that was previously masked by the process
   already having aborted before reaching this state).
2. **It is not a shibco/ableton-linux-specific bug.** Reproduced
   identically under ENCORE (a completely different Wine build — its
   own ~9-patch stack on a different base, not the `giang17/wine
   d2d1-dcomp` fork at all) against the user's original, separate
   `~/ableton-prefix`. Same trigger, same freeze, same unresponsive
   result. This rules out every patch this project or ENCORE carries as
   the sole cause.
3. **It is a genuine freeze, not a slow-but-finishing operation.**
   Confirmed via `ps -o stat,etimes` and direct process inspection: the
   main process stays alive and CPU-active far longer than any
   legitimate seek operation should take, with no return to
   responsiveness.
4. **It is not a classic single-thread SendMessage deadlock**, despite
   first appearing that way. A `WINEDEBUG=+message` trace shows the
   main thread's last logged action as sending `WM_NCPAINT` to a
   JUCE-classed child window (class `{JUCE_...}`, almost certainly the
   M4L device's own UI) with no returned exit logged, concurrently with
   a second thread stuck sending a custom `WM_USER+1` to the main
   window. This read like a two-thread circular wait at first.
5. **That reading was wrong — it's a many-thread active spin, not a
   passive wait.** Direct `/proc/<pid>/task/*/stat` sampling (two
   samples 5 seconds apart, comparing per-thread jiffies deltas) shows
   roughly **30 separate threads named `AudioCalc`** (Live's own audio
   calculation worker pool) all *actively accumulating real CPU time
   simultaneously*, sustained across the whole sampling window — not
   the near-zero CPU signature a thread blocked on `WaitForSingleObject`
   would show. A `MainThread`-named thread is also actively consuming
   CPU throughout. This is far more consistent with a runaway
   computation spread across Live's entire audio-calc thread pool than
   with two threads waiting on each other.
6. **`WINEDEBUG=+loaddll` full-session capture and a `winedbg`
   thread-by-thread backtrace of the process are both preserved**
   (session scratchpad only, not committed — see below) and show the
   main thread's stack running through `maxplug` (Max for Live's
   engine) → `mozjs185-1.0` (the bundled Mozilla JS engine) →
   `jsui.mxe64`/`js.mxe64` at the point of the freeze, confirming the
   JS-based M4L device is directly on the call path, not incidental.
7. **Correction to an earlier claim below.** A clean set with no
   devices from the affected project does not freeze on seek/click —
   but that test never had Carbon Regulator in it. It was not ruling
   out the device; it was only showing that the project's other
   content (dense automation, other tracks) isn't required. See
   finding 11: the device alone, freshly dragged into a brand new set,
   is sufficient. "Project-content-specific" was the wrong
   conclusion — "this-device-specific" is the right one.
8. **The trigger is specifically an in-lane click, not the ruler.**
   Seeking via the timeline ruler at the top (which relocates the
   transport and can start playback from the new position) works fine,
   repeatedly, in the same project. Clicking inside a track's own
   arrangement lane — the content area under the ruler, over that
   track's clips/automation — freezes instantly, on the click itself.
   Both actions reposition the transport; only the in-lane one
   triggers the freeze. This points at something specific to whatever
   Live does when a click lands inside a track lane (e.g. hit-testing
   or evaluating that track's automation/clip content at the click
   point) rather than at transport relocation in general.
9. **It is track-specific, not lane-wide.** Not every track's lane
   triggers it — only specific tracks do. The user has identified one
   culprit device by name: **Carbon Regulator**, from Ableton's own
   official **Creative Extensions** pack. Clicking in the lane of a
   track carrying that device reliably freezes; this narrows the
   earlier "any M4L JS device" framing to a specific, officially-shipped
   device (or a family of related ones — the project has multiple
   similarly-named "Regulator" devices/clips, e.g. "Crystal Tube
   Regulator", "1-Carbon Regulator 1" — not yet individually tested,
   but plausibly all from the same pack). Being first-party Ableton
   content rather than a hobbyist script raises the odds that this
   reproduces identically on real Windows too, since Creative
   Extensions ships broadly and would already be a known issue if it
   crashed Live outright there — pointing more toward "Wine mishandles
   something this specific device does" than "the device's own code is
   simply broken."
10. **The trigger is not specific to arrangement-lane seeking at
    all.** Simply clicking on the Carbon Regulator instrument in
    Session View — no arrangement lane, no transport reposition, no
    playback involved — freezes it too. This supersedes finding 8's
    framing ("in-lane click vs. ruler click"): that was one instance of
    a broader pattern, "interacting with/selecting this device", not
    something unique to arrangement-view seek behavior. The ruler
    stays clean only because a ruler click never touches this specific
    device at all, not because seeking-via-ruler is inherently safe.
11. **Decisive: the whole `truecarbon-latest` project is unnecessary.**
    Dragging a fresh Carbon Regulator instance into a brand new, empty
    set reproduces the freeze. No arrangement content, no automation,
    no other devices, no project-specific state of any kind is needed —
    just this device, loaded into any set. This is now the minimal
    known repro and corrects finding 7 (renumbered above): the earlier
    "clean set" test wasn't a true negative control, since it never
    actually contained the device. Every other project-specific detail
    in this document (dense automation, related "Regulator"-family
    devices, track position) can likely be discarded as irrelevant —
    open question: whether the freeze fires on drag-in itself or needs
    one more interaction (a click/selection) right after.
12. **It is scoped within Creative Extensions, not pack-wide.** Other
    devices/racks from Creative Extensions work fine; the user has not
    seen this outside Carbon Regulator's specific location, **Racks >
    Sounds > Synth Rhythmic**. A second device from the same subfolder
    also froze on test, and a full pack reinstall did not fix it —
    ruling out a corrupted local install as the cause. It narrows the
    search space from "some M4L device" to "this rack, or this rack
    subfolder, in one official pack."
13. **A genuine Max-emitted diagnostic error correlates with the
    freeze, found in Ableton's own `Log.txt`** (`AppData/Roaming/
    Ableton/Live 12.4.3/Preferences/Log.txt`, not previously examined):

    ```text
    2026-07-22T10:10:13.644787: error: Message from Max: mfl_device charset: error getting wide character buffer size
    2026-07-22T10:10:13.645787: error: Message from Max: mfl_device charset: error getting wide character buffer size
    ```

    `mfl_device` is Max for Live's own device-host component. The
    message's wording matches the standard Win32 two-call idiom
    (`WideCharToMultiByte`/`MultiByteToWideChar` called first with a
    null buffer to ask the required size, then again to actually
    convert) — implying the first call returned failure/zero. Depending
    on how `mfl_device` reacts to that failure (a retry loop, an
    unbounded realloc-and-retry), this is a very plausible mechanism
    for the many-thread `AudioCalc` spin. It appears exactly once across
    the entire log (all recorded crash days), in the session logged
    right after Carbon Regulator's presumed first post-reinstall load —
    consistent with Live's device indexer converting some string from
    the device's own files (name, embedded JS source, or a resource
    path) only on a fresh/uncached load, which also fits why a plain
    drag-in is enough to trigger it. Not yet confirmed which specific
    Win32 API call is failing or on what input string.
14. **A scoped `WINEDEBUG=+relay` trace targeting charset functions
    (via `HKCU\Software\Wine\Debug\RelayInclude`) was captured during a
    session where Carbon Regulator loaded and ran successfully** (Live
    was open and usable — no freeze this time). Investigated and
    **ruled out**: Ableton's bundled `sentry.native/0.13.5` crash-report
    HTTP client did attempt to POST an error envelope to Sentry's
    ingest API during this session, and its header-string
    `WideCharToMultiByte` conversions did fail — but only for two
    attempts total, not a runaway loop. This is a real but minor,
    self-resolving hiccup, not the freeze mechanism. (Initial analysis
    of this trace over-generalized from a short window and wrongly
    called it an infinite retry loop — corrected once the full trace
    was checked.)
15. **Two new symptoms observed in that same session, not yet
    root-caused:** (a) audible white noise coming from the "Spectral
    Blur" stage inside the Carbon Regulator rack once the device was
    loaded and running; (b) resizing the Live window caused it to go
    black and stop responding, requiring the user to kill the
    launching script (Ctrl+C) — a **hang, not a hard crash**: no Wine
    unhandled-exception report, no core dump (core dumps are disabled,
    `ulimit -c 0`), no apport crash file, and no OOM-kill in the
    kernel log correlate with it. This is the same family as the
    original freeze (unresponsive, needs a manual kill) but via a new
    trigger — window resize — rather than a click/selection. Whether
    it shares the same root cause as findings 1-13 or is a second,
    distinct bug in the same device is not yet determined.
16. **Decisive: a live winedbg attach during an actual hang (device
    loaded, hang occurred before the user even got to resize) caught
    the main UI thread mid-hang, with a genuinely deep, meaningful call
    stack** — unlike every other thread in the process, which sat in
    short, ordinary mutex-wait patterns (2-9 frames, `ntdll` →
    `kernelbase`/`msvcp140` → `maxplug`, indistinguishable from a normal
    idle thread pool; this includes ~35 threads whose stack bottoms out
    in `spliceabletonlive.vst3`, Ableton's bundled third-party Splice
    sample-browser plugin — investigated and **ruled out** as the
    cause, since they show the standard blocking-wait shape, not an
    active spin). The main thread (Wine thread id `0100`), by contrast,
    was ~87 frames deep:

    ```text
    Ableton Live 12 Suite.exe (UI code)
      -> user32 (SendMessage/DispatchMessage)
        -> maxplug (Max for Live engine), ~20 frames
          -> [maxplug+0x700174 / +0x71ccb1 / +0x7314de] x2 back-to-back
          -> jsui.mxe64 -> mozjs185-1.0 (the actual JS interpreter) -> back to jsui.mxe64
          -> maxplug, ~25 frames, containing:
             [maxplug+0x880b6c / +0x880f02 / +0x8822a4] repeating 8 TIMES IN A ROW
        -> user32 (a second SendMessage)
      -> Ableton Live 12 Suite.exe (UI code again)
        -> user32 (a third SendMessage)
      -> Ableton Live 12 Suite.exe (UI code again)
    ```

    The exact 3-address cycle repeating eight consecutive times (twice,
    in two different places in the stack) is a strong signature of a
    genuine loop — either inside Carbon Regulator's own Max patch
    structure (e.g. two connected objects feeding back into each other
    with no exit condition), or an unusually large object chain being
    walked. Critically, **this is happening on the main UI thread
    itself**, which explains the black/unresponsive window directly:
    the thread that should be pumping Windows messages is stuck deep
    inside this call chain and never returns to do so. Full raw
    backtrace (86 processes' worth, ~1200 lines for this process alone)
    saved in the session scratchpad, not committed: `winedbg-carbon-
    regulator/{full-dump,live-process-only}.log`.

Given the freeze reproduces identically across two structurally
different Wine builds (different base versions, different patch
counts, unrelated patch authors), the most likely explanations, in
order of plausibility:

1. **(Ruled out) A charset-conversion retry made unbounded by a
   Wine-specific API failure.** The natural unifying theory (finding
   13's `mfl_device charset` error + finding 16's repeating call cycle)
   was tested directly: the same scoped `RelayInclude` charset trace
   (finding 14's method) was run simultaneously with a second live
   winedbg attach during a fresh hang (device hung before any resize
   attempt was even possible this time). Result: the hung main thread
   (Wine tid `00fc`) made exactly 28 charset calls total, all
   succeeding normally — an ordinary scan of `Resources\Max\`'s
   subfolders (Misc, Python, Schema, Templates, Themes, Versions) and
   one Max external object load, `vs.ratio.mxe64`. After that load, the
   thread made zero further charset-filtered calls, yet was still
   hung — proving whatever it's actually looping on afterward does
   **not** touch string conversion at all. Hypothesis demoted;
   see (3) below for the corrected picture. A second live backtrace
   from this same session confirmed the repeating dispatch pattern is
   real and deterministic (the entry frames into `maxplug` matched
   almost exactly between two independent hang captures, minutes
   apart), just not charset-related — it lands in `patcher` (Max's
   graph engine) and deep into Ableton's own EXE code this time,
   rather than `jsui.mxe64`/`mozjs185-1.0`.
2. **(Leading theory, refined) A normally-bounded loop in Carbon
   Regulator's/`patcher`'s own graph-processing logic, made unbounded
   by some Wine-specific API failure that is NOT charset conversion.**
   Two live captures, minutes apart, both show the main thread
   re-entering the same `maxplug` dispatch entry point deterministically
   (near-identical addresses for the first ~13 frames each time), then
   proceeding into either `jsui.mxe64`/`mozjs185-1.0` or `patcher` and
   deep into Ableton's own EXE code depending on when sampled — the
   signature of a real, repeating outer loop, not two threads waiting
   on each other. With charset conversion ruled out (see (1)), the
   failing dependency is something else this loop relies on to
   terminate: a timer, an event/handle wait, a different Rtl/kernel32
   call, or a COM/RPC call inside `maxplug` or `patcher`. Still the
   most plausible read given how implausible an unconditional infinite
   loop is for shipped, official Ableton content — but the specific
   failing call is now unknown again and needs the same
   trace-plus-live-attach technique with a broader (or different)
   `RelayInclude` filter.
3. **A real bug in the device's own code that also reproduces on
   Windows** — still not logically ruled out without an actual Windows
   test, but the pattern (deterministic re-entry into the same dispatch
   point, not a wild crash) reads more like "something this loop
   depends on never resolves under Wine" than "the device's logic
   itself is simply wrong."

## What was NOT attempted

No fix was attempted for the freeze itself. `maxplug.dll` (Max for
Live's engine) and Ableton Live's own binary are closed-source with no
symbols available in this environment. Unlike initially assumed, the
culprit device (Carbon Regulator) is not one-off custom project
content — it ships in Ableton's official Creative Extensions pack, so
it is reproducible by anyone with that pack installed, not just against
this specific `.als`. Root-causing further would need either:

- A minimal repro project: an otherwise-empty set with just Carbon
  Regulator (or the other "Regulator"-family devices, unconfirmed) on
  one track, to isolate whether the freeze needs this project's
  automation/graph complexity or fires on the device alone.
- The device's `.amxd`/`.js` internals (Creative Extensions devices are
  typically at least partially inspectable, unlike fully compiled
  third-party externals), to inspect what its transport-position-change
  handler actually does.
- A real Windows environment, to settle the Wine-vs-device-bug question
  definitively — notably easier to arrange now that the culprit is a
  named, publicly-available official device rather than private
  project content.
- Deeper Wine-side tooling (perf/symbol-level profiling of the spin, or
  instrumenting `maxplug`'s calls into Wine's threading/RPC primitives)
  if the device-side explanation is ruled out first.
- **Done (finding 16):** a live-attached debugger, run during an actual
  hang rather than post-hoc log mining, which is what caught the main
  thread's real backtrace. Post-mortem analysis had failed to recover
  anything from the resize-triggered hang (finding 15): no Wine
  exception report, no core dump (disabled), no apport crash file, no
  OOM-kill — a live attach was the only way to get real signal.
- **Next concrete step:** combine both techniques in one session —
  the scoped `RelayInclude` charset trace (finding 14's method,
  `kernel32.WideCharToMultiByte;kernel32.MultiByteToWideChar;ntdll.
  RtlUnicodeToMultiByteN;ntdll.RtlMultiByteToUnicodeN`, still set in
  the prefix's `HKCU\Software\Wine\Debug` registry key) running *at the
  moment* a live winedbg attach catches the hang, to see the actual
  string and call arguments the repeating cycle is stuck on. That would
  either confirm hypothesis 1 outright (a charset call never
  succeeding) or rule it out in favor of hypothesis 2 (some other
  failing API).
- Following up on the white-noise symptom (finding 15a) specifically,
  independent of the hang: does the noise appear immediately on device
  load, or only after some interaction? Does it correlate with the
  `mfl_device charset` error's timing?

## Reproduction

Minimal repro:

1. Any Live 12 Suite set, including a brand new empty one.
2. Drag a Carbon Regulator (Creative Extensions pack) instance onto a
   track.
3. Live freezes: process stays alive, CPU-active (dozens of
   `AudioCalc` threads all actively spinning), never returns to
   responsiveness. Not yet isolated whether the drag-in alone is
   sufficient or whether one more interaction (a click/selection) is
   needed right after — see finding 11.

Originally-discovered (narrower, superseded) repro, kept for the
evidence trail: in the `truecarbon-latest.als` project, both clicking
inside the arrangement lane of the track carrying Carbon Regulator, and
separately clicking the instrument in Session View, froze it the same
way; the timeline ruler and other tracks' lanes did not.

Reproduced on:

- `wine-d2d1-nspa-11.13` (this project), both the pre-merge 45-patch
  build and the post-upstream-merge 46-patch build (patch-head
  `765e22db...`) — ruling out this session's own changes as the cause.
- ENCORE's own Wine build (a separate, unrelated patch stack) against
  the user's original, separate prefix — ruling out this project
  specifically as the cause.

## Session artifacts (not preserved past this session)

`WINEDEBUG=+loaddll` and `+message` traces, and a `winedbg bt all`
thread dump of the frozen process, lived in the session scratchpad
(`/tmp/claude-*/scratchpad/crash-trace2.log`, `msg-trace.log`,
`winedbg-out.log`) and were not copied anywhere durable. Re-run the
repro (above) with the same `WINEDEBUG` channels to regenerate them.
