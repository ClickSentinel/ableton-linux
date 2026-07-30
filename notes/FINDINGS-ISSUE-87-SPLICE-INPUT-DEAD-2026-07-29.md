# FINDINGS — Splice panel non-responsiveness — 2026-07-29

Consolidated record of the investigation into [shibco/ableton-linux#87](https://github.com/shibco/ableton-linux/issues/87) (panel goes permanently input-dead after collapse/reopen) and its sibling [#34](https://github.com/shibco/ableton-linux/issues/34) (drag-and-drop into the project fails). Everything below was measured, not reasoned about, unless marked otherwise. The GitHub issue body for #87 is our own write-up; this file adds the raw-evidence locations, the user findings that arrived after filing, and the open leads.

## TL;DR

Collapsing and reopening the Splice panel silently tears down and rebuilds the whole WebView2 stack, and the rebuilt instance never gets its input forwarding re-established. The panel renders and resizes but no input reaches it. **Every layer Wine owns measures correct** — hit-testing, capture, focus, window tree, the dcomp subclass, message delivery — including from inside Wine via instrumentation. The remaining suspects are in WebView2/CHOC's own recreation handshake (composition-controller re-association and `SendMouseInput` re-wiring), which is closed-source. **One live lead**: amenohi2 found that clicking the panel's own back/forward arrows restores input, and we reproduced it — so an in-app navigation completes whatever the rebuild skips. That lead has not yet been chased with a trace.

## The two issues and how they relate

- **#87 — input death** (open, filed by us 2026-07-28). Collapse/reopen the panel → renders fine, resizes fine, accepts no click/hover/keystroke. Permanent until plugin reload or Live restart. Deterministic on our machine.
- **#34 — drag fails with a 🚫 cursor** (filed by amenohi2 2026-07-20, closed by shibco 2026-07-21 as "fixed in 2026.07.21.2", **contested the same day** by amenohi2 with detailed evidence it is not fixed, +1'd by Pajamaland 2026-07-22, still closed). Cross-process OLE drag-and-drop territory — the same area as patch 0045 (`RevokeDragDrop` cross-process guard), which is upstream in the d2d1-dcomp-11.14 base.

amenohi2 explicitly links the two ("I did a lot of testing trying to figure out what was going on with #34 … and I had the same issue"). Both sit on the same underlying behaviour: CHOC/Splice parks and rebuilds its WebView2 stack instead of keeping it alive, and things break across the rebuild. The 11.14 Learn View tearing (see the base-bump notes) has the same trigger shape — correct on first open, broken after 2+ open/close cycles — so three separate symptoms now cluster on the WebView2 rebuild path.

## Reproduction (#87)

1. Open a Live set with the Splice panel visible.
2. Double-click the panel divider to collapse the left panel (switching tabs in the Places menu appears to do the same).
3. Reopen the panel.
4. The Splice panel no longer responds to clicks/hover/keys. Resizing still works. Hovering shows a resize cursor (misleading — hit-testing is actually correct, see below).

Deterministic, reproduced many times. Environment: runtime 2026.07.23.1, Wine base d2d1-dcomp-11.13 (5c23dd1c) + patches 0001–0053 + the visibility gate, Live 12.4.3 Suite, Splice `SpliceAbletonLive` v1.1.0 (VST3), WebView2 Evergreen 150.0.4078.105, COSMIC/Wayland (XWayland), isolated test prefix.

## What the investigation established

**The panel is not frozen — it is rebuilt.** CHOC mints a unique window class per webview instance, and the class changes across the repro (`CHOCWebView117967303` @ 0x10148 → `CHOCWebView118003504` @ 0x2014E in the run the issue documents; the archived hwndspy dumps show the same pattern in another run). Only the WebView2 **renderer** process respawns; the browser, GPU and utility processes survive from the original launch cluster — so the webview is reparented into a new host window, which Microsoft documents as unsupported unless the host calls `put_ParentWindow`.

**Input never went through Win32 messages in the first place.** Splice uses WebView2 composition (visual) hosting — `Chrome_WidgetWin_1` carries `WS_EX_NOREDIRECTIONBITMAP`, the `Intermediate D3D Window` is `NOREDIRECTIONBITMAP|LAYERED|TRANSPARENT`. In that mode the host receives pointer input itself and must forward it via `ICoreWebView2CompositionController::SendMouseInput`. Confirmed by measurement — during a controlled 10 s hover strictly inside the panel, every mouse message went to Live's main window (0x1009c) and none to the Splice child chain, **in both the healthy and broken states**:

| | mouse messages | to Live main | to Splice chain |
| --- | --- | --- | --- |
| healthy hover | 28730 | 28730 | 0 |
| broken hover | 710 | 710 | 0 |

So the failure is the rebuilt instance never re-establishing the app-side forwarding path. Rendering survives because composition presents independently of input — exactly why it renders and resizes while dead.

## Ruled out, with method

| checked | result |
| --- | --- |
| Wine hit-testing | correct — 20/20 sampled in-panel cursor positions resolve to the webview child while dead (`samples.txt`) |
| `WM_NCHITTEST` at panel centre | `HTCLIENT`, not a resize-border code |
| stuck mouse capture | `GetCapture` and `GetGUIThreadInfo().hwndCapture` both 0 |
| focus / active / foreground | identical healthy vs broken (0x1009c throughout) |
| window tree, styles, ex-styles | structurally identical healthy vs broken; parent chain intact; only panel width differs |
| target thread alive | `SendMessageTimeoutW(WM_NCHITTEST)` gets a reply |
| WebView2 processes | all alive, accumulating CPU |
| teardown | clean — no `err:`, no exception, no backtrace, 3 `WM_DESTROY` |
| dcomp props / comp buffer | `target`, `origproc`, `comp_dc` present; `comp_size` correct (`dcomp-BROKEN.txt`) |
| dcomp subclass "black hole" (0016's failure mode) | instrumented inside Wine — never fires |
| swapchain-keyed desktop prop leak | balanced — 2 props / 2 live swapchains |
| message-loop rate | ~6000/s is normal for Live+Splice; broken state not anomalous |
| CPU / bandwidth signature | none — 0.4 MB/s, no hot thread |
| WireGuard / Service Discovery | reproduces with `wg0` removed entirely |
| DComp reblit timer (0041 + visibility gate) | counters read 0 during the failure |

Two hypotheses that looked strong and were killed by their own controls:

- **"`window_from_point` stops finding the child."** An 8147-before vs 170-after comparison was confounded by a mid-test panel resize and unequal capture durations. Direct sampling (20/20 above) contradicts it.
- **The dcomp subclass black hole.** Patch 0016's comments describe this exact symptom ("the editor painted fine but was completely input-dead"), making it the leading theory. A diagnostic patch instrumenting both entry points never fired, and structurally it cannot apply: 0016's failure mode kills input on windows whose own WndProc is the input path, and a composition-hosted webview's target is a transparent overlay outside the input path entirely.

**Conclusion filed on the issue: no Wine-side defect found.** Every layer Wine owns measures correct.

## Findings from users on the issues

**amenohi2, #87, 2026-07-29 00:33 UTC — the back/forward arrows restore input.** "Using the back and forward arrows in the top left corner actually lets it accept inputs again. Maybe that's some kind of lead." **We confirmed the repro** (comment, 09:07 UTC). This is the single most important post-filing fact: the dead state is recoverable in-app, so an in-app navigation completes whatever handshake the rebuild skips — presumably forcing the composition controller / input forwarding to be re-wired. It reopens an investigation we had closed as "nothing further observable from here": capturing what fires across that arrow click is now the obvious next step.

**amenohi2, #34, 2026-07-21 22:27 UTC — the "fix" doesn't hold, with specifics.** Tested both `install-ableton-latest.run` and a build from top of branch, GPU acceleration on and off:

- Drag a sample after a failed drag, then double-click it → Simpler shows "Sample is Offline"; the .wav in the samples download folder is **0 kB**.
- A sample that does start dragging can end up **stuck to the mouse** — waveform visible (so it downloaded) but it never places on the timeline; right-click dismisses it but reloading the Splice window brings it back, still unplaceable.
- In that state the Splice window goes black and cannot be refreshed, option menus (e.g. Options > Settings) stop working, and closing Live skips the save prompt and hangs until the force-terminate dialog.

**Pajamaland, #34, 2026-07-22 — +1** on latest build, dragging still broken.

**Cross-machine confirmation matters here:** amenohi2 is on CachyOS / KDE Wayland / NVIDIA RTX 3070 / Ryzen 5700X; we are on COSMIC/Wayland / AMD GPU / Intel i5-12600KF. Reproduction across distro, desktop, and GPU vendor rules out driver- and distro-specific causes.

## Evidence artifacts (local)

All in `/mnt/storage-2tb/ableton-splice-evidence/` (captured 2026-07-28):

| file | contents |
| --- | --- |
| `collapse-repro-trace.log` (9.8 MB) | WINEDEBUG trace across the collapse/reopen repro |
| `hwndspy-HEALTHY.txt` / `hwndspy-BROKEN.txt` | full window-tree dumps either side of the repro; show the CHOC class-instance change and the structurally identical trees |
| `dcomp-BROKEN.txt` | desktop dcomp props + per-window dcomp state while dead — props balanced, comp buffers correct |
| `samples.txt` | the 20/20 cursor-position samples proving hit-testing resolves to the webview child while dead |

The diagnostic Wine patch that instrumented 0016's black-hole path lives on the fork branch `wip/dxgi-present-storm-0054-0055` as `patches/0056-DIAGNOSTIC-log-dcomp-subclass-DefWindowProc-black-ho.patch` (commit `add8038`). **Numbering collision warning:** this is unrelated to the *shipped* 0056 (the reblit visibility gate merged via PR #95) — the diagnostic patch predates the renumbering and exists only on that branch, never for merge.

## Tools and gotchas (verbatim from the investigation — these cost real time)

- `scripts/ableton-live` line 16 sets `WINEDEBUG="${WINEDEBUG:--all}"`. Any diagnostic relying on default `err`/`fixme` output silently produces nothing. Always pass `WINEDEBUG` explicitly and validate the capture (`grep -c dcomp <log>` must be > 0) before trusting a negative. A first run of the black-hole instrumentation "passed" with zero hits purely because of this.
- `+relay` cannot trace app→DLL API calls in this WoW64 build — it only logs callbacks. It will not show what Live or CHOC called.
- `liveinject` cannot probe this bug: synthetic `SendInput` produces no renderer activity even on a **healthy** panel, so any conclusion drawn from it is invalid.
- A dump taken while Live is minimised shows every window at ~(-32000,-32000) — standard `WS_MINIMIZE` placement, not a coordinate bug.

## Open leads and next steps

1. **The back/forward-arrow recovery (primary).** Capture a targeted `WINEDEBUG` log across the arrow click on a dead panel and diff it against the rebuild sequence — whatever fires there is the step the rebuild path skips. Not yet attempted.
2. **Retest #34 on the 11.14 base.** Patch 0045's `RevokeDragDrop` cross-process guard is upstream there, so drag behaviour may differ. Blocked in practice: the 11.14 bump is unshippable (Learn View tearing), but a one-off drag test on the bump build costs little.
3. **WebView2 version dependence — untested for #87.** The parked-pane flicker (#57) reproduces on 150.0.4078.65/.105 but not 143.0.3650.96; whether #87 has the same dependence is unknown, and rolling back isn't practical anyway (Microsoft ships only the latest two majors, Ableton's bootstrapper fetches current).
4. **Push back on #34's closed state.** It is closed as fixed with two users reporting otherwise and detailed contrary evidence in-thread.
5. **Keep the rebuild-path cluster in view.** #57, #87, and the 11.14 tearing all trigger on WebView2 park/rebuild cycles. A fix or insight in any one of them should be re-checked against the other two.
