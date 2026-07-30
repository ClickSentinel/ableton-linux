# Splice panel goes input-dead after collapse and reopen (2026-07-29)

Collapsing and reopening the Splice panel silently tears down and
rebuilds the whole WebView2 stack, and the rebuilt instance never gets
its input forwarding re-established. The panel renders and resizes but
no input reaches it. Every layer Wine owns measures correct - hit
testing, capture, focus, window tree, the dcomp subclass, message
delivery - including from inside Wine via instrumentation. The remaining
suspects are in WebView2/CHOC's own recreation handshake, which is
closed source.

One live lead: clicking the panel's own back/forward arrows restores
input, so an in-app navigation completes whatever the rebuild skips.
That lead has not been chased with a trace yet.

Covers [#87](https://github.com/shibco/ableton-linux/issues/87) and its
sibling [#34](https://github.com/shibco/ableton-linux/issues/34). The
issue body for #87 is our own write-up; this file adds the raw-evidence
locations, the user findings that arrived after filing, and the open
leads. Everything below was measured, not reasoned about, unless marked
otherwise.

## Scope

- **#87, input death.** Open, filed by us 2026-07-28. Collapse and
  reopen the panel and it renders fine, resizes fine, and accepts no
  click, hover or keystroke. Permanent until plugin reload or Live
  restart. Deterministic here.
- **#34, drag fails with a no-entry cursor.** Filed by amenohi2
  2026-07-20, closed by shibco 2026-07-21 as fixed in 2026.07.21.2,
  contested the same day by amenohi2 with detailed evidence it is not,
  +1'd by Pajamaland 2026-07-22, still closed. Cross-process OLE
  drag-and-drop - the same area as patch 0045's `RevokeDragDrop`
  cross-process guard, which is upstream in the d2d1-dcomp-11.14 base.

amenohi2 links the two explicitly ("I did a lot of testing trying to
figure out what was going on with #34 ... and I had the same issue").
Both sit on the same underlying behaviour: CHOC and Splice park and
rebuild the WebView2 stack instead of keeping it alive, and things break
across the rebuild. The 11.14 Learn View tearing has the same trigger
shape - correct on first open, broken after two or more open/close
cycles - so three separate symptoms now cluster on that rebuild path.

## Cause

**The panel is not frozen, it is rebuilt.** CHOC mints a unique window
class per webview instance, and the class changes across the repro
(`CHOCWebView117967303` @ 0x10148 to `CHOCWebView118003504` @ 0x2014E in
the documented run; archived hwndspy dumps show the same pattern in
another). Only the WebView2 renderer process respawns - browser, GPU and
utility processes survive from the original launch cluster - so the
webview is reparented into a new host window, which Microsoft documents
as unsupported unless the host calls `put_ParentWindow`.

**Input never went through Win32 messages in the first place.** Splice
uses WebView2 composition hosting: `Chrome_WidgetWin_1` carries
`WS_EX_NOREDIRECTIONBITMAP`, and the `Intermediate D3D Window` is
`NOREDIRECTIONBITMAP|LAYERED|TRANSPARENT`. In that mode the host
receives pointer input itself and must forward it through
`ICoreWebView2CompositionController::SendMouseInput`. During a
controlled 10 s hover strictly inside the panel, every mouse message
went to Live's main window (0x1009c) and none to the Splice child chain,
in both states:

| | mouse messages | to Live main | to Splice chain |
| --- | --- | --- | --- |
| healthy hover | 28730 | 28730 | 0 |
| broken hover | 710 | 710 | 0 |

So the failure is the rebuilt instance never re-establishing the
app-side forwarding path. Rendering survives because composition
presents independently of input, which is exactly why the panel renders
and resizes while dead.

No Wine-side defect was found, and that is what was filed on the issue.

## Evidence

| checked | result |
| --- | --- |
| Wine hit-testing | correct - 20/20 sampled in-panel cursor positions resolve to the webview child while dead (`samples.txt`) |
| `WM_NCHITTEST` at panel centre | `HTCLIENT`, not a resize-border code |
| stuck mouse capture | `GetCapture` and `GetGUIThreadInfo().hwndCapture` both 0 |
| focus / active / foreground | identical healthy vs broken (0x1009c throughout) |
| window tree, styles, ex-styles | structurally identical healthy vs broken; parent chain intact; only panel width differs |
| target thread alive | `SendMessageTimeoutW(WM_NCHITTEST)` gets a reply |
| WebView2 processes | all alive, accumulating CPU |
| teardown | clean - no `err:`, no exception, no backtrace, 3 `WM_DESTROY` |
| dcomp props / comp buffer | `target`, `origproc`, `comp_dc` present; `comp_size` correct (`dcomp-BROKEN.txt`) |
| dcomp subclass "black hole" (0016's failure mode) | instrumented inside Wine - never fires |
| swapchain-keyed desktop prop leak | balanced - 2 props / 2 live swapchains |
| message-loop rate | ~6000/s is normal for Live+Splice; broken state not anomalous |
| CPU / bandwidth signature | none - 0.4 MB/s, no hot thread |
| WireGuard / Service Discovery | reproduces with `wg0` removed entirely |
| DComp reblit timer (0041 + visibility gate) | counters read 0 during the failure |

Reproduced on runtime 2026.07.23.1, Wine base d2d1-dcomp-11.13
(5c23dd1c) plus patches 0001-0053 and the visibility gate, Live 12.4.3
Suite, Splice `SpliceAbletonLive` v1.1.0 (VST3), WebView2 Evergreen
150.0.4078.105, COSMIC on Wayland via XWayland, isolated test prefix.

Cross-machine confirmation rules out driver- and distro-specific causes:
amenohi2 is on CachyOS, KDE Wayland, an NVIDIA RTX 3070 and a Ryzen
5700X; we are on COSMIC, Wayland, an AMD GPU and an Intel i5-12600KF.

## Rejected approaches

**`window_from_point` stops finding the child.** An 8147-before versus
170-after comparison was confounded by a mid-test panel resize and
unequal capture durations. Direct sampling, 20/20 above, contradicts it.

**The dcomp subclass black hole.** Patch 0016's comments describe this
exact symptom ("the editor painted fine but was completely input-dead"),
which made it the leading theory. A diagnostic patch instrumenting both
entry points never fired, and structurally it cannot apply: 0016's
failure mode kills input on windows whose own WndProc is the input path,
and a composition-hosted webview's target is a transparent overlay
outside that path entirely.

## Reproduction

1. Open a Live set with the Splice panel visible.
2. Double-click the panel divider to collapse the left panel. Switching
   tabs in the Places menu appears to do the same.
3. Reopen the panel.
4. The panel no longer responds to clicks, hover or keys. Resizing still
   works. Hovering shows a resize cursor, which is misleading -
   hit-testing is actually correct.

## Reports from users

**amenohi2, #87, 2026-07-29 - the back/forward arrows restore input.**
"Using the back and forward arrows in the top left corner actually lets
it accept inputs again. Maybe that's some kind of lead." Confirmed here
the same day. This is the most important post-filing fact: the dead
state is recoverable in-app, so an in-app navigation completes whatever
handshake the rebuild skips, presumably forcing the composition
controller and input forwarding to be re-wired. It reopens an
investigation closed as "nothing further observable from here".

**amenohi2, #34, 2026-07-21 - the fix does not hold.** Tested both
`install-ableton-latest.run` and a build from top of branch, GPU
acceleration on and off:

- Drag a sample after a failed drag, then double-click it, and Simpler
  shows "Sample is Offline"; the `.wav` in the samples download folder
  is 0 kB.
- A sample that does start dragging can end up stuck to the mouse -
  waveform visible, so it downloaded, but it never places on the
  timeline. Right-click dismisses it, but reloading the Splice window
  brings it back, still unplaceable.
- In that state the Splice window goes black and cannot be refreshed,
  option menus stop working, and closing Live skips the save prompt and
  hangs until the force-terminate dialog.

**Pajamaland, #34, 2026-07-22.** +1 on the latest build, dragging still
broken.

## Diagnostics

- `scripts/ableton-live` sets `WINEDEBUG="${WINEDEBUG:--all}"`. Any
  diagnostic relying on default `err`/`fixme` output silently produces
  nothing. Always pass `WINEDEBUG` explicitly and validate the capture
  (`grep -c dcomp <log>` must be greater than 0) before trusting a
  negative. A first run of the black-hole instrumentation "passed" with
  zero hits purely because of this.
- `+relay` cannot trace app-to-DLL API calls in this WoW64 build; it
  only logs callbacks, so it will not show what Live or CHOC called.
- `liveinject` cannot probe this bug. Synthetic `SendInput` produces no
  renderer activity even on a healthy panel, so any conclusion drawn
  from it is invalid.
- A dump taken while Live is minimised shows every window at about
  (-32000,-32000). That is standard `WS_MINIMIZE` placement, not a
  coordinate bug.

## Next steps

1. **The back/forward-arrow recovery**, primary. Capture a targeted
   `WINEDEBUG` log across the arrow click on a dead panel and diff it
   against the rebuild sequence; whatever fires there is the step the
   rebuild path skips. Not yet attempted.
2. **Retest #34 on the 11.14 base.** Patch 0045's `RevokeDragDrop`
   cross-process guard is upstream there, so drag behaviour may differ.
   Blocked in practice because the 11.14 bump is unshippable on Learn
   View tearing, but a one-off drag test on the bump build costs little.
3. **WebView2 version dependence**, untested for #87. The parked-pane
   flicker (#57) reproduces on 150.0.4078.65 and .105 but not
   143.0.3650.96. Whether #87 has the same dependence is unknown, and
   rolling back is impractical anyway - Microsoft ships only the latest
   two majors and Ableton's bootstrapper fetches current.
4. **Push back on #34's closed state.** It is closed as fixed with two
   users reporting otherwise and detailed contrary evidence in-thread.
5. **Keep the rebuild-path cluster in view.** #57, #87 and the 11.14
   tearing all trigger on WebView2 park/rebuild cycles. A fix or insight
   in any one should be re-checked against the other two.

## Artifacts

Captured 2026-07-28, in `/mnt/storage-2tb/ableton-splice-evidence/`:

| file | contents |
| --- | --- |
| `collapse-repro-trace.log` (9.8 MB) | WINEDEBUG trace across the collapse/reopen repro |
| `hwndspy-HEALTHY.txt` / `hwndspy-BROKEN.txt` | full window-tree dumps either side of the repro; show the CHOC class-instance change and the structurally identical trees |
| `dcomp-BROKEN.txt` | desktop dcomp props and per-window dcomp state while dead - props balanced, comp buffers correct |
| `samples.txt` | the 20/20 cursor-position samples proving hit-testing resolves to the webview child while dead |

The diagnostic Wine patch that instrumented 0016's black-hole path lives
on the fork branch `wip/dxgi-present-storm-0054-0055` as
`patches/0056-DIAGNOSTIC-log-dcomp-subclass-DefWindowProc-black-ho.patch`
(commit `add8038`). It is unrelated to the shipped 0056, the reblit
visibility gate merged via PR #95 - the diagnostic patch predates the
renumbering and exists only on that branch, never for merge.
