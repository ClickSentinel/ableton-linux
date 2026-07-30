# M4L hover tooltips appear far from the pointer (2026-07-30)

**Status: no Wine-side cause found, across seven tested hypotheses.** Each was refuted with a concrete experiment recorded below. The evidence points at Max/JUCE computing the wrong coordinate before any Win32 call: Wine honours every positioning request it is given, exactly, 24 times out of 24.

That is a negative result, not a proof of absence. Wine is large and this investigation only ruled out the paths it thought to check — the ones listed below, plus the specific mechanisms in "Also checked and eliminated". A Wine-side cause upstream of the position Max computes (something it queries and gets a wrong answer to) has *not* been exhaustively excluded; the query APIs actually examined were `GetCursorPos`, `GetMonitorInfo`/`SPI_GETWORKAREA`, and `GetWindowRect`. If you have a new idea for what feeds that computation, it is worth testing — just check it against the refutations here first so the same ground is not re-covered.

A genuine and *separate* Wine bug was found along the way — `GetCursorPos` misbehaving under XWayland. It does not cause this symptom but is worth its own issue. See "Separate finding" near the end.

## Symptom

Hovering a control in a Max for Live device UI pops a tooltip in the wrong place — typically several hundred pixels away, clustered at one spot, while the pointer is elsewhere. It reads as "random" because the spot changes between bursts as the device UI relayouts.

Right-click **context menus** are *not* affected. Every `title="menu"` JUCE menu and every win32u `#32768` menu observed across five captures landed correctly at the cursor. Only the small hover tooltips misplace. If someone reports "menus appear in random places", confirm which of the two they actually mean before investigating — that ambiguity cost several captures here.

## Environment

| | |
| --- | --- |
| Wine | `wine-d2d1-nspa-11.13` (this fork) |
| Session | **Wayland** (XWayland), Pop!_OS |
| Displays | 3, non-rectangular virtual desktop |
| DPI | 96 (100%), `LOGPIXELSX/Y = 96` |
| Live | 12 Suite 12.4.3 |
| Max | 9.1.4 |
| Device used | Poli (Creative Extensions) |

Monitor layout, from `tools/monprobe.exe`:

```text
DISPLAY1 (primary)  (    0,  0)-(2560,1440)   work == full
DISPLAY2            (-1920,360)-(   0,1440)   work == full
DISPLAY3            ( 2560,360)-(4480,1440)   work == full
virtual desktop     (-1920,  0)-(4480,1440)   6400x1440
```

The side monitors start at `y=360` and the primary at `y=0`, so the desktop has a notch across the top. That was investigated as a cause and ruled out (hypothesis 5).

## The tooltip windows

```text
class   JUCE_<hash>          (the hash changes per Max session)
style   0x96080000  = WS_POPUP | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN | WS_SYSMENU
exstyle 0x00080088  = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST
size    26px tall, width varies with the text (41-155 observed)
owner   none (0)
```

Menu drop-shadow slivers appear alongside them as `200x12` / `12x106` windows with `WS_EX_TRANSPARENT` added. They move with the menu and are not themselves interesting.

## What is proven

**1. Wine honours every positioning request exactly.** Parsing `calc_winpos` from a `+win` trace and comparing the requested `swp` against the resulting `new_rects`:

```text
positioning calls where Wine honoured the request EXACTLY: 24
calls where the result differed from the request:           0
```

**2. The application repositions the tooltip itself.** With `+relay,+win` together, the sequence per tooltip is unambiguous:

```text
324594  Call user32.SetWindowPos(0x90364, NULL, 1659,510, 99x26, 0x214)  ret=1408ce916
324595  trace:win:NtUserSetWindowPos hwnd 0x90364, 1659,510 (99x26), flags 00000214
        -> placed AT THE CURSOR (pointer was at 1658,509). Correct.
324647  Call user32.ShowWindow(0x90364, SW_SHOWNA)
324717  Call user32.SetWindowPos(0x90364, HWND_TOPMOST, 0,0,0,0, 0x413)
        -> SWP_NOMOVE|SWP_NOSIZE, z-order only
324837  Call user32.GetCursorPos(0091faa8)  ret=140864ed6
324917  trace:win:NtUserSetWindowPos hwnd 0x90364, 1954,368, flags 00000015
        -> SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE. THE MISPLACEMENT.
```

**3. The destination is right-aligned to a fixed rect, not the pointer.** Widths vary, `left` adjusts to keep `right` constant:

```text
1549+147 = 1696      1966+87  = 2053      1645+147 = 1792
1609+87  = 1696      1906+147 = 2053      1685+107 = 1792
                     1946+107 = 2053      1705+87  = 1792
                     1990+63  = 2053      1744+48  = 1792
```

Three clusters, each with a constant top (`368`, `320`, `560`). This is placement against a rect. Whatever rect Max is using, it is wrong, and it is not any window on screen.

**4. It is not derived from the pointer.** Sampling `GetCursorPos` at 50ms alongside a `+win` capture: only **5 of 30** destinations fall within 40px of any reported cursor position, and those look coincidental.

**5. It is not derived from the device window.** In one capture the device window moved from `(822,374)-(1700,668)` to `(745,459)-(1623,753)` mid-session while destinations did not track it.

## Hypotheses tested and refuted

| # | Hypothesis | How it died |
| --- | --- | --- |
| 1 | `WS_POPUP\|WS_SYSMENU` makes Wine manage the window, so the WM places it (`is_window_managed`, `winex11.drv/window.c:467`) | `tools/popupplace.exe`: bare `POPUP\|SYSMENU` drifts 5/5 to a WM-chosen spot, but adding `WS_EX_TOOLWINDOW` — the actual JUCE shape — never drifts, 0/5, across three creation sequences, activated and not |
| 2 | Tooltip anchored to the wrong window (Max Console, device window, tray) | `tools/treespy.exe`: `WindowFromPoint` at the destination returns only Live's main window; no window, visible or hidden, has the matching edge |
| 3 | Wrong monitor work area, so a toolkit clamp shoves it into a corner | `tools/monprobe.exe`: every `rcWork` equals its `rcMonitor`; `SPI_GETWORKAREA` correct |
| 4 | The extra floating Max device window confuses hover routing | user closed it; still misplaced |
| 5 | Non-rectangular 3-monitor virtual desktop | destinations do not correspond to any monitor edge, and top values (`320`/`368`/`560`) are not monitor boundaries |
| 6 | Wine moves the window after the app places it | 24/24 requests honoured exactly, 0 deviations |
| 7 | Wine's `GetCursorPos` returns a bad position and JUCE follows it | 5/30 coincidental matches; destinations are rect-aligned, not cursor-aligned |

Also checked and eliminated as the mover:

- **Patch 0007** (`win32u: clamp top-level window size to monitor`) — size-only, and skipped entirely when `SWP_NOSIZE` is set, which it is here.
- **`NtUserUpdateLayeredWindow`** — the window is `WS_EX_LAYERED`, but this path calls `apply_window_pos()` directly and never reaches `NtUserSetWindowPos`, so it cannot produce the observed trace line.
- **`NtUserScrollWindowEx`** (`dce.c:2207`, moves children by a delta) — its flags include `SWP_NOREDRAW|SWP_DEFERERASE` (`0x201d`), not the observed `0x15`.
- **`NtUserArrangeIconicWindows`** (`window.c:4855`) and **`SetWindowPlacement`** (`window.c:3195/3202`) — right flags, wrong context; neither applies to a tooltip.
- **`winex11.drv`** — its only two `NtUserSetWindowPos` call sites use different flags.

No caller in Wine's tree uses exactly `SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE` with a real position. That combination is the canonical "move only" call an application makes, and JUCE emits it for a position-only bounds change.

## Conclusion

On the evidence gathered, Max/JUCE computes a tooltip position against a rect it has wrong, then issues a normal `SetWindowPos` move, and Wine does exactly as asked. That is enough to report to Cycling '74 with unusually good evidence — exact hwnds, both call sites, coordinates, and proof the host honoured both requests. It is not enough to close the door on a Wine-side contribution: see the caveat at the top of this note.

## Separate finding: `GetCursorPos` is unreliable under XWayland

Real, ours, and worth its own issue — but **not** the cause of the above.

Wayland only gives a client pointer coordinates while the pointer is over its own surface, so `XQueryPointer` — which `winex11.drv` uses for `GetCursorPos` — has no dependable global answer. Sampling at 50ms for 45s during normal hovering (`tools/curprobe.sh`):

- `GetCursorPos` returned **(0,0)** at the moment the foreground window was lost
- a **471px** Y jump and back within 100ms, while X moved only 24px — physically impossible for a hand
- **93 of 898 samples (10%)** had no foreground window at all

Possible fix direction: have `winex11.drv` fall back to the last position from motion events when `XQueryPointer` cannot give a trustworthy global answer. Needs its own investigation and repro; do not fold it into the tooltip issue.

## Tooling added

All build with plain mingw, no Wine source tree needed:

```bash
x86_64-w64-mingw32-gcc -O2 -o tools/popupspy.exe   tools/popupspy.c   -lgdi32
x86_64-w64-mingw32-gcc -O2 -o tools/popupplace.exe tools/popupplace.c -lgdi32
x86_64-w64-mingw32-gcc -O2 -o tools/monprobe.exe   tools/monprobe.c   -lgdi32 -luser32
x86_64-w64-mingw32-gcc -O2 -o tools/treespy.exe    tools/treespy.c    -lgdi32 -luser32
x86_64-w64-mingw32-gcc -O2 -o tools/curprobe.exe   tools/curprobe.c   -luser32
```

| Tool | Purpose |
| --- | --- |
| `popupspy` | logs each new top-level window: first vs settled rect, cursor delta, styles, owner, and an anchor hunt over other windows |
| `popupplace` | creates popups with chosen style/creation-sequence combinations at a known position and reports drift — isolates "which style bit makes Wine hand placement to the WM" |
| `monprobe` | monitor rects, work areas, virtual screen, DPI, `MonitorFromPoint` |
| `treespy` | full window tree with rects, and resolves an arbitrary screen point to a window and its ancestors |
| `curprobe` | samples `GetCursorPos` + foreground window, flags physically impossible jumps |

## Capture recipes

Window positioning with the requested and resulting rects (channel `win`, function `calc_winpos`):

```bash
WINEPREFIX=~/.wine-ableton WINEDEBUG=+win ableton-live > /tmp/win.log 2>&1
```

Application calls plus results, interleaved:

```bash
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine \
  reg add 'HKCU\Software\Wine\Debug' /v RelayInclude /t REG_SZ /d \
  'user32.SetWindowPos;user32.MoveWindow;user32.DeferWindowPos;user32.EndDeferWindowPos;user32.SetWindowPlacement;user32.ShowWindow;user32.GetCursorPos' /f

WINEPREFIX=~/.wine-ableton WINEDEBUG=+relay,+win ableton-live > /tmp/both.log 2>&1
```

Always remove the filter afterwards, it is slow:

```bash
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine \
  reg delete 'HKCU\Software\Wine\Debug' /v RelayInclude /f
```

## Measurement traps

These cost most of the eight captures this investigation took. Read before writing another probe.

1. **Reporting the first rect you see catches popups pre-move.** A menu looked stuck at `(0,0)` when it was simply about to be placed.
2. **Reporting after a fixed settle delay catches popups post-teardown.** Max parks a dismissed popup at a fixed anchor *and* collapses it to a sliver (`300px` wide -> `16px`). Distinguish by size: a **same-size** move is a real misplacement; a move that also resizes is teardown. Conflating these produced a wrong "all menus were placed correctly" verdict.
3. **Do not mark a window "seen" before checking visibility.** Windows that exist but are hidden at probe startup then get suppressed forever, so they never appear when shown. This hid the Max device window from three captures despite it being a popup's owner.
4. **Exclude the popup itself from any anchor search.** Otherwise every popup "matches" its own rect and the report is worthless.
5. **`... | grep -q` under `set -o pipefail` returns 141.** `grep -q` exits on first match, the writer takes `SIGPIPE`, and a *present* string reads as absent. Use a herestring or capture first.
6. **Never pipe a long capture into `grep`.** Buffered output is lost when the process is killed; an early attempt produced 7 lines instead of ~1M. Redirect to a file and filter afterwards.
7. **`RelayInclude` needs `module.function` entries.** The module-only form (`user32`) traces nothing at all, silently.
8. **`win32u` exports are syscall stubs and relay cannot hook them.** `RelayInclude=win32u.NtUserSetWindowPos` yields zero output. Use the `+win` channel for win32u-level visibility.
9. **`calc_winpos` with `SWP_NOMOVE` logs the window's *current* position**, because win32u fills `winpos.x/y` from the existing rect. Do not read that as a move request. Check the flags first.
10. **hwnds are reused across sessions.** Never compare a rect from one capture against an hwnd in another — that produced a false "Wine is reporting the wrong window size" conclusion.

## Artifacts

Captures are not committed (large, and `*.log` is gitignored). Regenerate with the recipes above.

## Related

- [FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md](FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md) — the M4L font-fallback deadlock, same "Max defect surfaced under Wine" shape, but that one had a shippable fix.
- [ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md](ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md) — patch 0039, the managed-flip fix for Live's own Preferences dropdowns. Related mechanism, different windows, and the starting point for hypothesis 1.
