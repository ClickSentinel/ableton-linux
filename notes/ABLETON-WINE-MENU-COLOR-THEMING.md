# How the native menu bar's color theming works

Issue #32 (unified top bar) and #35 (theming fit and finish). Reference
documentation for the system that makes Wine's native win32 menu chrome
(menu bar, dropdowns, dialogs) match Ableton's own active theme instead
of Wine's stock light-Windows-95 gray, and keeps following it live while
Live keeps running. For the investigation behind the remaining gap in
the "live" half (point 4: switching while the Preferences dialog is
still open), see `FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md`.

## Overview

Two sync paths, both in `scripts/ableton-live`, both ultimately writing
the same `HKCU\Control Panel\Colors` values, plus two independent
`win32u` bugs that had to be fixed for the second path to actually be
visible:

1. **Launch-time sync** - a plain registry write before Live starts, so
   the process picks the colors up through Wine's completely normal
   first-read-loads-from-registry behavior. No patch needed for this
   half; it already worked.
2. **Live re-theming** - a background watcher applies the same colors
   to an *already-running* Live process via a real `SetSysColors()`
   call, the instant `Preferences.cfg` shows the user picked a new
   theme. This half needed two real Wine patches
   (`0050`, `0051` below) - the relevant Win32 mechanism already
   existed and was being called correctly, but nothing in `win32u`
   made its effect reach an already-running window.

Two further, narrower fixes round out the "fit and finish" pass:
dropping a Win95-era grayed-text bevel that reads badly once the menu
is dark (`0049`), and hiding the alt-key mnemonic underlines the bar
always drew, since real Windows only shows them once Alt is pressed and
this Wine tree never implements that toggle (`0052`).

## Fixing the grayed-item bevel

`draw_menu_item` (`dlls/win32u/menu.c`) used to draw disabled
(`MF_GRAYED`) menu text twice for a classic Win95 "engraved" look: a
white pass offset `+1,+1`, then a gray pass at the original position.
That assumes `COLOR_3DHILIGHT` is a light color close to the menu
background - true for the stock light theme, but this prefix (like most
apps that theme dark via `SetSysColors`) leaves `COLOR_3DHILIGHT` at its
Windows default (white) regardless of the dark menu around it, so the
highlight pass rendered as a glaring white ghost offset from the real
text instead of a subtle bevel.

**`patches/0049-win32u-drop-the-grayed-menu-item-engraved-bevel-ent.patch`**
drops the two-pass bevel entirely and always single-draws in
`get_sys_color(COLOR_GRAYTEXT)`, matching what the adjacent
`MF_HILITE`-grayed case already did successfully. This code has zero
diff from stock Wine, so the bug is upstream, not fork-specific.

## Launch-time sync

Before Ableton starts, `sync_win32_colors()` (`scripts/ableton-live`)
writes directly into `HKCU\Control Panel\Colors` via `wine reg add`.

Where the colors come from, when `ABLETON_TOPBAR_MODE=live` (the
default): `resolve_live_topbar()` reads whichever `.ask` theme file Live
currently has selected (`ableton_live_theme_file()` in
`scripts/detect-theme.sh`, matching the theme name embedded as a UTF-16
string in the running version's `Preferences.cfg` against the installed
`Themes/` directory) and pulls specific keys out of it via
`ableton_ask_color()` (a `sed` one-liner reading `<Key Value="#rrggbb"
/>` out of the theme's flat XML):

| registry value | theme key | rationale |
|---|---|---|
| `MenuBar` / `ActiveTitle` / `GradientActiveTitle` | `Desktop` | the always-visible bar; darker than the surface behind it in every reference (a dark chrome strip framing lighter content) |
| `Menu` (dropdown background) | `ControlBackground` | matches Live's own popup/control surfaces, lighter than the bar |
| `MenuText` / `TitleText` | `ControlForeground` | shared: win32 has only one menu text color for both the bar and its dropdowns |
| `MenuHilight` / `Hilight` / `HilightText` | `SelectionBackground` / `SelectionForeground` | selected-item highlight, always applied as a matched set |
| `GrayText` | *(derived, not a theme key - see below)* | disabled/grayed item text |

`GrayText` has no direct source: Live's own `TextDisabled` token was
tried and rejected (checked against the live theme: it sits closer to
`Desktop` than even Wine's compiled-in default does - that token is
calibrated for Live's own layered Skia surfaces, not a flat `win32u`
menu fill). Instead `blend_gray_text()` computes a 45%-toward-`MenuText`
blend of whatever `Menu`/`MenuText` resolve to, generic enough to track
any theme and either light/dark fallback with no extra parsing; it's
shared between this launch-time path and the live-watch path below.

`ABLETON_TOPBAR_MODE=system` uses the host's own titlebar colors
instead (KDE globals, or GNOME header-bar constants as a generic
fallback) via `ableton_detect_topbar_colors()`; `preserve` leaves the
old flat scheme colors; `#RRGGBB #RRGGBB` forces bar background/text
directly. `ensure_flat_menu()` sets the `SPI_GETFLATMENU` preference bit
so the bar actually honors `COLOR_MENUBAR` instead of `COLOR_MENU`.

## Live re-theming while Live is already running

`theme_watch_loop()` (`scripts/ableton-live`) runs as a background
watcher for the life of the Live process - one per prefix, `flock`-
guarded so a relaunch's watcher waits out the previous session's rather
than racing it. It watches `Preferences.cfg` for changes with
`inotifywait` when `inotify-tools` is installed (event-driven - wakes on
the write itself), falling back to a plain 2-second mtime poll
otherwise.

**Picking the right `Preferences.cfg`**: both `theme_watch_prefs_cfg()`
here and `ableton_live_theme_file()` in `detect-theme.sh` need to find
the currently-relevant `Live <version>/Preferences/Preferences.cfg`
among however many past versions have ever run - both do this by newest
*mtime* of the actual file (`ableton_newest_prefs_dir()`), deliberately
**not** `sort -V` on the directory name: `"Live 12.4/..."` sorts *after*
`"Live 12.4.3/..."` under a plain version sort, because the two paths
diverge right after `"12.4"` into `/` (0x2F) vs `.` (0x2E), and a
byte-compare there picks the wrong one - silently serving a long-dead
old-version prefs file instead of the live one.

When the watched file changes, the colors are re-resolved exactly as at
launch, then applied via `setsyscolors.exe` (`tools/setsyscolors.c`)
rather than another `wine reg add`: a plain registry write only reaches
processes started *afterward*, and making an *already-running* process
pick up new colors needs an actual live `SetSysColors()` call from
inside the same Wine session - nothing short of a real running `.exe`
can do that. `setsyscolors.exe` is a small, no-CRT, hand-built PE binary
(`tools/build_setsyscolors.sh`) that parses `Name=R,G,B` arguments off
its own command line and calls `SetSysColors()` once - that's all it
does now; it used to also `EnumWindows` + `DrawMenuBar` on every window
to work around the non-client-repaint gap `0051` (below) now fixes
upstream instead.

A diff-guard (`theme_watch_loop`'s `applied` tracking) skips re-firing
`setsyscolors.exe` when a `Preferences.cfg` touch resolves to the same
colors as last time - the watched file gets touched for plenty of
reasons besides an actual theme pick (window layout, focus state), and
broadcasting a live color change is not free.

### Why this needed two Wine patches, not just the registry write

`SetSysColors()` alone did nothing visible to an already-running
window, for two separate, independent reasons - both real Wine gaps,
not fork-specific (confirmed: zero diff against stock Wine in both
files):

- **`patches/0050-win32u-invalidate-the-per-process-sys-color-cache-o.patch`**:
  each process caches every system color (and any `HBRUSH`/`HPEN` built
  from it) the first time it reads one (`dlls/win32u/sysparams.c`,
  `get_rgb_entry`/`get_sys_color_brush`), and nothing ever invalidated
  that cache in response to `WM_SYSCOLORCHANGE` - a window that had
  already read `COLOR_MENUBAR` once kept returning the same stale value
  and the same stale brush forever, regardless of how many times
  `SetSysColors` was called from elsewhere. Fixed by resetting every
  entry's cache from `dlls/win32u/message.c`'s `call_window_proc` - the
  common delivery point for every message reaching a window procedure
  regardless of same-thread/cross-thread/cross-process origin - right
  before `WM_SYSCOLORCHANGE` reaches it, in the *receiving* process.
- **`patches/0051-win32u-include-the-non-client-area-in-setsyscolors.patch`**:
  `NtUserSetSysColors` already tried to force a repaint after a color
  change, but its `RedrawWindow` flags (`RDW_INVALIDATE | RDW_ERASE |
  RDW_UPDATENOW | RDW_ALLCHILDREN`) only reach client areas -
  `RDW_FRAME` (the non-client area, where a native menu bar actually
  lives) was missing. One flag added.

### Known limitation: presentation latency

Even with both patches, the actual on-screen pixels can still take
anywhere from well under a second to several seconds to become visible
after a real theme switch - measured directly, not a fixed interval,
and reproducible with zero user interaction at all (so it's not a
"needs a click to wake up" requirement, just a very unreliable delay).
Two additional fixes were tried and **reverted** because they measurably
made no difference in the real `theme_watch_loop`-driven path, despite
looking successful in isolated manual testing: `RedrawWindow(...
RDW_UPDATENOW...)` and a synthetic `SendInput` mouse nudge, both from
`setsyscolors.exe`. Not yet root-caused. One concrete, untested lead:
`theme_watch_loop`'s invocation is a fully detached background process
(`( theme_watch_loop ) </dev/null >/dev/null 2>&1 &`, no controlling
terminal) while the manual tests that looked successful were run from
an interactive shell - that distinction was raised but never actually
isolated.

This is a different, later-stage gap from the one in
`FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md`: that document
covers the *earlier* stage (nothing observable happens at all until the
Preferences dialog closes and `Preferences.cfg` is written); this
section covers the delay *after* that write is observed and
`setsyscolors.exe` has already been invoked.

## Hiding the alt-key mnemonic underlines

Issue 35 point 6: "is it possible to remove the underlines from the
Wine menu bar?" - the underline under each top-level item's first
letter (File, Edit, Create, ...), the standard Win32 alt-key mnemonic
cue. Real Windows only shows these once Alt is pressed (the
`WM_UPDATEUISTATE`/`UISF_HIDEACCEL` "keyboard cues" system); this Wine
tree never implements that message handling at all (confirmed: no
`WM_UPDATEUISTATE`/`WM_QUERYUISTATE`/`WM_CHANGEUISTATE` handling
anywhere outside its own tests), so the bar always drew them, unlike
real Windows or macOS. Implementing the full Alt-to-reveal toggle is a
much larger feature - global UI-state tracking, Alt key press/release
wiring, propagation through every window - so
**`patches/0052-win32u-hide-the-menu-bar-alt-key-mnemonic-underline.patch`**
just permanently hides them instead, which is the actual visual result
that was asked for.

Two parts, because the first alone turned out to be a no-op:

1. `dlls/win32u/menu.c`'s `draw_menu_item` adds `DT_HIDEPREFIX` to the
   menu bar's `DrawTextW` format flags (menu bar only - popup/dropdown
   items keep their mnemonics, where Alt-key in-menu navigation is
   still commonly used).
2. `DT_HIDEPREFIX` turned out to be a *dead flag* in this tree: defined
   in `winuser.h`, but the actual underline-drawing call site in
   `dlls/user32/text.c` only ever checked `DT_NOPREFIX` - not
   equivalent, since that stops `&` being treated as an escape at all
   and would show a literal `&` in the text instead of just hiding the
   underline. Fixed by gating the underscore-drawing call on
   `DT_HIDEPREFIX` too, leaving `&`-stripping and prefix-offset tracking
   (already unaffected by this flag) exactly as before.

Verified live: the top-level bar (File/Edit/Create/...) no longer shows
underlines; an open dropdown's own items still show theirs.

## File map

| file | role |
|---|---|
| `scripts/ableton-live` | `sync_win32_colors`, `blend_gray_text`, `resolve_live_topbar`, `ensure_flat_menu`, `theme_watch_loop`, `theme_watch_prefs_cfg` |
| `scripts/detect-theme.sh` | `ableton_live_theme_file`, `ableton_ask_color`, `ableton_newest_prefs_dir`, `ableton_detect_theme`, `ableton_detect_topbar_colors` (host-theme detection, used by `ABLETON_TOPBAR_MODE=system`) |
| `tools/setsyscolors.c` + `build_setsyscolors.sh` | the live `SetSysColors()` call itself; a small no-CRT PE binary, rebuilt independently of the Wine tarball |
| `patches/0049-*.patch` | drops the grayed-item engraved-bevel double-draw |
| `patches/0050-*.patch` | per-process sys-color/brush/pen cache invalidation on `WM_SYSCOLORCHANGE` |
| `patches/0051-*.patch` | `RDW_FRAME` in `NtUserSetSysColors`'s forced repaint |
| `patches/0052-*.patch` | hides the menu bar's alt-key mnemonic underlines (`DT_HIDEPREFIX`, plus making that flag actually work in `dlls/user32/text.c`) |

## Debugging notes for whoever touches this next

- This launcher defaults `WINEDEBUG=-all` (`scripts/ableton-live`,
  suppressing everything including `err`, unless the caller already
  exports a value). A plain `ableton-live` launch with no `WINEDEBUG`
  set will never show `ERR()`/`FIXME()` output at all, your own debug
  instrumentation included. Always launch with an explicit
  `WINEDEBUG=+something` when tracing anything through this launcher.
- `wine reg query`/reading `system.reg`/`user.reg` directly only ever
  shows the *persistent* registry state. A live `SetSysColors()` call
  writes to a separate "volatile" key and the calling process's own
  memory; neither shows up in the on-disk `.reg` file until wineserver
  flushes on a clean shutdown. Don't use a registry read to check
  whether a live color change actually applied.
- For iterating on a `win32u`-only change without a full ~20-minute
  container rebuild: unpack the base, apply the full patch series,
  `configure`, then a *targeted* `(cd dlls/win32u && make)` - produces
  `dlls/win32u/win32u.so` (not `.../x86_64-unix/win32u.so` - that path
  doesn't exist for this dll) in well under a minute, which can be
  hot-swapped directly into an installed runtime's
  `lib/wine/x86_64-unix/win32u.so` for a fast test loop. This reads
  patches from `ableton-linux/patches/`, **not** any scratch clone's
  working tree - edits made only in a scratch clone and never
  `git commit` + `git format-patch`'d into a numbered patch file are
  silently invisible to this build, with no error or warning. Always
  re-export before rebuilding, even for a one-line tweak.
- This is not a substitute for the real tarball/`install.sh` path
  before calling anything actually fixed - it's for iteration speed
  only, and easy to leave stale debug instrumentation in if you forget
  to do a final clean rebuild + real install before finishing.
