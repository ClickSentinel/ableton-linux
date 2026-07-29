# GPU renderer present storm: 600 MB/s of full-window X11 uploads

2026-07-28. Live's GPU renderer (enabled by PR 74, which removes `-_ForceGdiBackend` from `Options.txt` in prefix setup step 5c) routes every `Present()` of the **main Live window** through wined3d's GDI fallback path. Each present is a full-window CPU readback plus a full-window `XPutImage` upload. At idle this costs nothing, but any sustained UI activity — moving the mouse is enough — produces **~600 MB/s** of raw pixel traffic to the display server and pegs a core, which is what the "Live freezes" reports (issue 61) look like from the inside.

## Measured

Live 12.4.3, prefix `wine-test-pr74-fresh`, runtime `main` @ `9cf69c0` (PR 74 merged) plus patch 0054, COSMIC/Wayland (XWayland), 2560x1440. Bandwidth is `/proc/<pid>/io` `wchar` delta (no strace overhead); workload is an identical scripted `liveinject move` sweep across the Live window.

| Config | write bandwidth | `wined3d_cs` CPU |
| --- | --- | --- |
| GPU renderer (PR 74 default, no `Options.txt`) | 612.9 / 617.9 / 519.9 MB/s | 2861 jiffies |
| `-_ForceGdiBackend` restored (pre-PR-74) | 0.40 / 0.43 / 0.58 MB/s | 0 jiffies |

Reversible in both directions (A/B/A), ~1300x. With `-_ForceGdiBackend` the wined3d command-stream thread does *no* work at all: Live never presents a D3D swapchain, so the path is never entered.

Idle with the GPU renderer is 0.01 MB/s, consistent with PR 74's own "idle CPU 1-2%" measurement. The regression is invisible until something presents continuously.

## Wire-level evidence

`strace` of the `wined3d_cs` thread during a hang, 3 s window:

- 74.5% of syscall time in `writev`, ~2800/s; `poll`/`recvmsg` alongside it
- 1.74 GB written in ~3 s
- 89% of X11 requests are opcode 72 `PutImage`
- every `PutImage` is 2560 px wide, 25 rows tall (256 KB, the X11 max-request chunk libX11 splits a large image into), `dst-y` walking 0 -> 1325
- 54 strips per full frame, 126 distinct target drawables over the capture, each receiving exactly one full-window upload; XIDs sequential, stride 5
- => 2560x1350 uploaded ~41x/s = ~570 MB/s, matching the `/proc/io` number

No MIT-SHM: this path uses plain `XPutImage` over the socket. winex11's *window surface* path (`bitblt.c:1883`) does try `put_shm_image()` first and honours dirty rects; the wined3d GDI present path does neither.

## Why the slow path is taken

`swapchain_present` (`dlls/wined3d/swapchain.c:1311`) picks GL present only when `WINED3D_SWAPCHAIN_PREFER_GL_PRESENT` is set. Otherwise a swapchain whose swap effect is `SEQUENTIAL` or `FLIP_SEQUENTIAL` falls to `swapchain_blit_gdi` (`:1334`), which the code itself notes costs "~5-10 ms per frame" in GPU readback plus CPU copies.

`dlls/dxgi/utils.c:606` maps DXGI swap effects 1:1, so `DXGI_SWAP_EFFECT_-` `SEQUENTIAL`/`FLIP_SEQUENTIAL` both land on the GDI branch. The observed swapchain is `SEQUENTIAL`: the sampled stack sits in `comp_buffer_alpha_merge` (`swapchain.c:575`), which `swapchain_blit_gdi` only calls for `WINED3D_SWAP_EFFECT_SEQUENTIAL`.

`PREFER_GL_PRESENT` is set in exactly one place — `dlls/dxgi/factory.c:1064` — inside the DComp *target-window* branch, and only when that target is top-level. Live's own main-window swapchain never enters that branch, so it never gets the flag, so every present is a full-window readback + upload.

## Candidate fix

Live's main window is top-level and therefore has an X11 `whole_window`, which is the precondition the `factory.c:1043-1051` comment gives for GL present being safe (the reason child/embedded plugin windows are excluded is that they have no `whole_window` and a GL swap would target an invisible drawable). So extending `PREFER_GL_PRESENT` to top-level non-DComp swapchains looks applicable, and would remove the readback entirely rather than making it cheaper. Not yet built or tested.

Cheaper mitigations, in case that turns out not to hold: use `put_shm_image()` for the present blit (the SHM helper already exists in `bitblt.c`), or honour `cs_present_dirty_rects[]` instead of taking the full-blit branch when the app presents without dirty rects.

## Relationship to the freeze reports

Sampled during one occurrence, with a symbol-preserving build:

- exactly one of 133 threads is `R`: `wined3d_cs`, ~57-64% of a core sustained
- the main thread is *not* deadlocked — it is in `ioctl(/dev/ntsync,` `NTSYNC_IOC_WAIT_ANY)` cycling ~2835 voluntary context switches/s at ~12% CPU

Sustained, this is enough to make Live *feel* frozen, and it is a real defect worth fixing on its own. But it turned out **not** to be the defect behind the report that started this investigation: with 0055 applied the storm is gone and the reported symptom still reproduces. See the second section below - that one is a separate input-routing bug with no performance signature at all. Treat the two independently; do not close issue 61 on the strength of 0055.

The DComp reblit counters (`dcomp_reblit_comp_buffer.reblit_count` and friends, patches 0041/0054) read **0** during that occurrence, so the reblit timer is not involved in either failure mode.

Splice is a trigger rather than a cause for the storm: its WebView2 content animates continuously, which is exactly the sustained-present workload that turns the per-frame cost into a lockup. The scripted mouse-move test above reproduces the same bandwidth with no Splice interaction at all.

## Reproducing

```bash
ABLETON_WINEPREFIX=<prefix> ableton-live &
PID=$(pgrep -f '[A]bleton Live 12 Suite\.exe' | head -1)
a=$(grep ^wchar /proc/$PID/io | grep -oE '[0-9]+'); sleep 5
b=$(grep ^wchar /proc/$PID/io | grep -oE '[0-9]+')
echo "$(( (b-a)/5/1000000 )) MB/s"
```

Move the mouse across the Live window during the 5 s. Hundreds of MB/s means the GPU renderer is on the GDI present path.

## Debugging setup used

`ABLETON_KEEP_SYMBOLS=1` (added to `scripts/container-build.sh` and `build.sh`) skips the strip step in `[5/8]`; compilation already carries `-gdwarf-4 -g -O2` by default, so codegen is unchanged and the ccache stays warm (91% hit rate on the symbol build). Tarball grows 61 MB -> 215 MB. Never set it for a shipped build: BUILD-INFO hashes are meant to be post-strip.

Plain `gdb -p` cannot resolve Wine PE modules by itself (it reports an architecture mismatch on this WoW64 build, and `winedbg --gdb` failed to attach with `error 87`). Loading modules manually against the addresses in `/proc/<pid>/maps` does work:

```bash
gdb -p $PID -batch \
  -ex "add-symbol-file .../lib/wine/x86_64-windows/wined3d.dll 0x<base from maps>" \
  -ex "thread apply all bt"
```

## A second, unrelated bug: the Splice panel stops taking input

Same session, after patch 0055 removed the present storm, the originally reported symptom still reproduces, so it is **not** the same defect. Reported as "freeze", but it is not one: only the Splice panel stops responding, the rest of Live stays interactive, and hovering the panel shows a resize cursor. Reproduced by interacting with the panel and switching Live tabs.

What it is not (each ruled out by measurement, not argument):

- **Not the present storm.** With 0055 the frozen-state write bandwidth is 0.4 MB/s, versus 677 MB/s for the storm.
- **Not a CPU/message-loop pathology.** Main thread runs ~7300 ctx-switches/s in the broken state, but a *healthy* Live+Splice already runs ~5900/s. The ~6000/s message-pump churn is Live's normal baseline, not a symptom. (An earlier "livelock" reading of this number was wrong.)
- **Not the DComp reblit timer.** `dcomp_reblit_comp_buffer`'s counters (0041/0054) read 0 in the broken process.
- **Not a hung WebView2 process.** All Splice renderer/browser/GPU processes are alive and accumulating CPU (+15/+14/+2 jiffies per 4 s).
- **Not window-tree corruption.** `hwndspy` subtrees for healthy and broken are structurally identical - same classes, styles, nesting, and the same `Chrome_RenderWidgetHostHWND` and layered `Intermediate D3D Window`. Only the panel width differs, which is just the resize that was performed. The large layered `Intermediate D3D Window` covering Live's left half exists in the healthy tree too.
- **Not WireGuard.** An earlier lead: Live logs `Service Discovery: Error sending from 10.99.0.2 to 224.76.78.75:20909:` `Invalid argument` on every start, because `wg0` has no `MULTICAST` flag (the same failure `linkprobe` hits). Real, but unrelated - the symptom reproduces with `wg0` removed entirely and the error absent from the log.

Also ruled out, by probing the live broken process with `swamprobe hit 400 650` (a point inside the panel, which was `(124,123)-(672,1174)` at the time):

- **Not a stuck mouse capture.** `GetCapture()` and `GetGUIThreadInfo`'s `hwndCapture` both report `0`. This was the leading hypothesis - a capture left behind by the divider drag would have routed every mouse message to the main window - and it is wrong.
- **Not broken hit-testing.** `WindowFromPoint(400,650)` correctly returns `Chrome_RenderWidgetHostHWND`, the innermost web-content window, and the whole parent chain resolves cleanly: `Chrome_RenderWidgetHostHWND -> Chrome_WidgetWin_1 -> Chrome_WidgetWin_0 ->` `CHOCWebView -> JUCE_<id> -> AbletonPlatformViewHostFwd -> Live main`.
- **Not an `NCHITTEST` resize code.** `WM_NCHITTEST` at that point returns `1` (`HTCLIENT`). The theory that the whole panel was being classified as a resize border - which would have explained the cursor and the dead input at once - is disproven.

Corrections to earlier readings in this file, all from over-reading a single trace line before checking the pointer position:

- `process_wine_setcursor hwnd 0x1009c` (Live's main window) is **not** evidence of misrouting. The trace shows the pointer was at `(1238,706)` at the time, which is outside the panel (`x > 672`), so the main window servicing the cursor there is simply correct.
- `GetCursorPos` polls at ~48/s, i.e. frame rate, so there is no hot tracking loop either.
- Live's log prints `VST3: embedded view didn't want focus` around the failures. Still unconfirmed as causal, and it is the only remaining lead pointing at focus handoff on the embedded view.

Where that leaves it: Wine's side of input routing looks *correct* - the right window is found, with the right hit code, and nothing holds capture. Child windows have no X11 `whole_window` of their own (Live's main window is `xwin=5200003`; the children have none), so all pointer input arrives on the main X window and is dispatched internally by exactly the hit-testing that was just shown to work. That makes a pure winex11 routing bug unlikely and shifts suspicion onto whether the `WM_MOUSE*` messages that Wine dispatches are being acted on by the Chromium/CHOC side.

One more thing is established, about tooling rather than the bug: `SendMessageTimeoutW(WM_NCHITTEST)` to the `Chrome_RenderWidgetHostHWND` gets a reply, so that window's thread is alive and pumping messages while the panel is dead.

**`liveinject` cannot probe this bug.** Driving synthetic pointer motion over the panel with it produces no measurable work in the Splice renderer process - but the same is true on a *healthy* Live, so the test does not discriminate:

| | renderer idle | renderer during synthetic panel moves |
| --- | --- | --- |
| healthy | 10 jiffies/3 s | 2 jiffies |
| broken  | 8 jiffies/3 s  | 1 jiffy  |

`SendInput` injection evidently does not reach the cross-process WebView2 child even in the working case, so any conclusion drawn from it about input delivery is invalid. Reproduction and probing both need the real pointer.

### Resolved by a `+msg` trace across a real repro

`WINEDEBUG=+msg` filtered to mouse/focus messages, over a run where the user established a healthy baseline, triggered the bug, then hovered the dead panel.

**The webview is destroyed and recreated during the repro.** CHOC mints a unique window class per instance, and it changed:

| | before | after |
| --- | --- | --- |
| CHOC class | `CHOCWebView106439107` | `CHOCWebView106601162` |
| CHOC hwnd | `0x10140` | `0x70204` |
| `Chrome_WidgetWin_1` | `0x101C4` | `0x5013C` |

The Splice **renderer process** restarted with it - process start times put every other WebView2 process in the launch cluster (~10643867-10644135 ticks, Live at 10643270) and the Splice renderer alone at 10660123, about 160 s later, with no older instance surviving. Live's log corroborates the timing: `VST3: embedded view didn't want focus` at 16:44:41, the restart at ~16:44:55, then the same message twice more at 16:44:56. The VST3 plugin itself was *not* reloaded (no second `VST3: Created: SpliceAbletonLive`), so this is WebView2 losing and re-spawning its renderer underneath a surviving plugin instance.

**The message question was the wrong question.** Mouse-message delivery is identical before and after, in thirds of the repro:

| segment | Live main `0x1009c` | Splice chain |
| --- | --- | --- |
| early (healthy) | 3430 | 7 |
| middle | 3436 | 4 |
| late (broken) | 3438 | 3 |

Splice barely receives Win32 mouse messages *even while it works*. The window styles say why: `Chrome_WidgetWin_1` carries `ex=00200000` (`WS_EX_NOREDIRECTIONBITMAP`) and the `Intermediate D3D Window` carries `ex=00280024` (`NOREDIRECTIONBITMAP|LAYERED|TRANSPARENT`). That is WebView2 **composition (visual) hosting**, where the host forwards input programmatically via `ICoreWebView2CompositionController::SendMouseInput` and HWND messages are not the input path at all. Wine dispatching everything to `0x1009c` is correct behaviour, not a defect.

### Conclusion and where a fix belongs

The chain is: the Splice WebView2 renderer dies and WebView2 auto-respawns it → CHOC rebuilds the webview (new class, new HWNDs) → the rebuilt instance never gets its composition-controller input forwarding (and focus handoff) re-established → the panel still composites, so it renders, but nothing routes input into it.

Re-establishing that forwarding after a renderer-loss/recreation is the **host's** responsibility (Splice's plugin, built on CHOC + WebView2 composition hosting), not Wine's. Wine's message routing, hit-testing, capture state and window tree were each measured and found correct. So there is most likely **no patch for this project to write**, and the actionable output is an upstream report to Splice with the evidence above.

Confidence: high that the webview is recreated and that hosting is composition mode (both directly observed); high that Wine's input routing is correct (four independent probes); *inferred*, not directly observed, that the missing piece is host-side input re-wiring - confirming that would need instrumentation inside Splice/CHOC, which is not reachable from here.

### Deterministic trigger, and why the renderer "died"

**Double-clicking the panel divider collapses the left panel.** That is the whole trigger; reopening the panel then yields a dead webview. It reproduces in seconds, which makes this cheap to test.

Re-traced with `WINEDEBUG=+msg,+seh` and the filter widened to keep `err:`, `Backtrace`, `Exception` and `seh:`:

- **No crash.** No exception, no backtrace, no `wine:` fatal. The only `seh:` output is WebView2's normal `WerRegisterCustomMetadata` stubs.
- **Clean teardown.** Exactly 3 `WM_DESTROY`/`WM_NCDESTROY`, all to one window.
- **Webview rebuilt**, confirmed by the CHOC per-instance class: `CHOCWebView106972185` @ `0x1014C` -> `CHOCWebView107097394` @ `0x20152`.
- **Only the renderer process is new.** Live at 10696560 ticks, the Splice browser/gpu/utility processes all in the 10697223-10697459 launch cluster, the renderer alone at 10709746 - about 123 s later, i.e. during the collapse.

So the renderer is not dying, it is being torn down and respawned deliberately as part of collapsing the panel, and the rebuilt instance comes back without input. That closes the last branch that could have been ours: there is no Wine fault anywhere in the teardown.

### Wine-side search exhausted (2026-07-28, later session)

Driven by the (reasonable) argument that Splice cannot be this broken on Windows or its users would have said so, every layer Wine owns was probed directly on a confirmed-dead panel. All of it measures correct:

| probe | result |
| --- | --- |
| window tree / parent chain | intact, identical to healthy |
| window styles, ex-styles | identical |
| `GetCapture` / `hwndCapture` | `0` in both states |
| focus / active / foreground | `0x1009c` in both states |
| `WM_NCHITTEST` at panel centre | `1` (`HTCLIENT`) |
| **hit-test resolution, 20 samples while hovering the dead panel** | **20/20 resolve to the webview child** |
| mouse-message routing, controlled 10 s hovers | identical: all to `0x1009c`, 0 to child, *both* healthy and broken |
| teardown | clean: no `err:`, no exception, no backtrace, 3 `WM_DESTROY` |
| DComp props (`dcompspy`) | target/comp_dc present, `comp_size` correct (550x1051) |

Two leads that looked strong and were killed by their own controls:

- *"`window_from_point` stops finding the child"* - the 8147-before vs 170-after comparison was confounded by the panel being resized mid-test and by unequal capture durations. Direct sampling (20/20 above) contradicts it outright.
- *"the DComp swapchain window is 400x400 instead of 550x1051"* - vestigial. `dxgi/factory.c:1320` creates that helper window at the swapchain's initial size and `:1040` then switches the device window to `target_hwnd`, so the helper's rect is never used for presentation.

**Conclusion: no Wine-side defect is findable at any Win32/DComp surface, and therefore no patch target exists in this tree.** That is not the same claim as "Wine is not involved" - something must differ from Windows, and the remaining candidates all sit inside WebView2/CHOC's own COM-level recreation handshake (`ICoreWebView2CompositionController` re-association and `SendMouseInput` re-wiring), which is closed-source and not observable from here.

The actionable output is an upstream report to Splice, not a patch. Evidence to include: deterministic trigger (double-click the panel divider, or switch Places-menu tabs), webview recreated (CHOC per-instance class changes), renderer respawned, panel then renders and **responds to resize** - so the controller is alive and reachable - while never receiving input again until the plugin is reloaded. Collapsing and reopening a second time does not recover it.

### Trap: the launcher disables all Wine diagnostics

`scripts/ableton-live` line 16 does `export WINEDEBUG="${WINEDEBUG:--all}"`. Any diagnostic that relies on Wine's *default* `err`/`fixme` output produces **nothing** when launched normally - silently. A first run of the patch-0056 black-hole instrumentation "passed" with zero hits purely because of this; the log contained no `dcomp`, `err:` or `fixme:` lines at all. Always pass an explicit `WINEDEBUG` (e.g. `err+all,fixme+all`) and validate the capture before reading anything into a negative result:

```bash
grep -c dcomp <log>; grep -cE '^[0-9a-f]+:(err|fixme):' <log>   # must be > 0
```

### Black-hole hypothesis: tested properly, disproven

With a verified-live capture (19k lines, dcomp output flowing), a confirmed webview rebuild (`CHOCWebView117967303` -> `CHOCWebView118003504`) and normal geometry, neither patch-0056 diagnostic fired. The dcomp target subclass is not sending input to `DefWindowProc`; patch 0016's guard holds and the gap hypothesised in it does not occur on this path.

That is consistent with structure: 0016's failure mode kills input on windows whose *own WndProc* is the input path (a JUCE/SWAM editor drawing into its own HWND). Splice is composition-hosted - the target is a transparent overlay and input arrives by host forwarding - so the subclass is not in its input path at all, however similar the symptom reads.

Also worth recording, since it cost a false alarm: a dump taken while Live is minimised shows every window at ~`(-32000,-32000)` with a 160x40 main window. That is Windows' standard minimised placement (`WS_MINIMIZE` set), not a coordinate bug - decode the style before reacting to the rect.

## Patch 0055 took three revisions: the black-window regression

The first two versions of 0055 shipped a real regression - windows painting black until interacted with, intermittently. Recorded in full because the failure mode is subtle and the two wrong fixes were both plausible.

| revision | condition | outcome |
| --- | --- | --- |
| v1 | `parent == desktop` | Settings window painted black |
| v2 | `+ !(style & WS_POPUP)` | authorisation dialog painted black |
| v3 | `+ !(style & WS_CHILD)` | only the main window flagged; no black windows |

**Root cause.** `dxgi_factory_CreateSwapChainForComposition` does not use the application's window. It creates its own:

```c
window = CreateWindowExW(WS_EX_NOPARENTNOTIFY, L"WineDCompSwapchain", L"DComp Swapchain",
        WS_CHILD, 0, 0, desc->Width, desc->Height, GetDesktopWindow(), NULL, ...);
```

That window is `WS_CHILD` **parented to the desktop**, so `GetAncestor(GA_PARENT)` returns the desktop and a parent-only "is this top-level?" test classifies it as top-level. `WS_POPUP` is absent, so excluding popups does not catch it either. Every DComp composition swapchain was therefore flagged for GL present, and `glXSwapBuffers` on a child window with no on-screen drawable produces nothing - while the GDI blit is immune because it writes through the window surface, which survives map/expose. The window being flagged was never the dialog that appeared black; it was the hidden composition window behind it.

**Two traps this exposed, both of which cost a wrong conclusion:**

- `WS_POPUP` and `WS_CAPTION` coexist. Live's Settings window is framed, with min/max/close buttons, and is still `WS_POPUP` (style `96c80000`). A title bar is not evidence that a window is not a popup - decode the style.
- A patch comment asserting "child windows are left alone" was simply false for desktop-parented `WS_CHILD` windows, and it went unquestioned for two revisions because it *sounded* right.

**What finally worked was instrumentation, not reasoning.** v3 logs the class and style of every window it flags. That converts the check from "no black windows appeared this session" - which both broken versions passed at some point - into a positive statement about what is on the GL path. A full session including Learn View, Splice and Settings yields exactly one line:

```
GL present for device window 0x1009C class L"Ableton Live Window Class" style 0ecf0000
```

This `FIXME` is diagnostic scaffolding and must be removed or downgraded before the patch is proposed upstream; it fires on a normal code path.

**Validation of v3** (same workload as the table above): 0.12-0.20 MB/s and ~21% of a core, against ~650 MB/s and ~107% without the patch. Confirmed by bisect that the regression belonged to 0055 alone - a build with 0054 only was clean across three separate sessions, and a build predating both patches was clean.

### The `FORCE_GDI_PRESENT` latch: untested, but structurally out of reach

`dxgi/factory.c` sets `FORCE_GDI_PRESENT` (which beats `PREFER_GL_PRESENT`) when a DComp popup is destroyed, and nothing clears it except the DComp branch adopting a new top-level target. That would silently revert a swapchain to GDI presenting for the rest of the session.

Driving Learn View, Splice and Settings never reached it - both DComp counters stayed at zero, so that machinery is dormant for those panels; plugin editors are what create DComp targets, and none were available to test with. The structural argument is that after the `WS_CHILD` fix the swapchains that latch touches are exactly the ones 0055 no longer flags, and Live's main-window swapchain is created via `CreateSwapChainForHwnd` and never becomes a popup target. That is reasoning corroborated by counters, not a measurement.

### Unrelated: F11 fullscreen

F11 does not extend the window to the bottom of the screen. This predates 0055 and is unchanged by it - issue 42, tested and not regressed, not fixed.
