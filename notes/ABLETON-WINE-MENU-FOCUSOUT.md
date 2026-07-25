# Menu tracking survives transient X11 focus changes

Status: patch 0038 shipped in 2026.07.19.1. It protects Wine's Win32
menu-bar dropdowns from transient X11 focus changes. It did not fix issue #3
because Live's Preferences dropdowns are custom popup windows, not Win32
menus. Patch 0039 fixes that separate bug; see
[ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md](ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md).

## Cause

Wine maps a Win32 popup menu as an override-redirect X11 window. Mutter and
Muffin can move X input focus while that window maps or receives a click.
The foreground Live window then receives a normal `FocusOut`.

`focus_out()` in `dlls/winex11.drv/event.c` responded with
`WM_CANCELMODE`, which ends Win32 menu tracking. Wine already filtered
`NotifyGrab` and `NotifyUngrab`; the remaining path used `NotifyNormal`.
Virtual desktop mode returns before this code, but this project does not use
it as a workaround.

## Fix

[../patches/0038-winex11-don-t-cancel-menu-tracking-while-the-focus-s.patch](../patches/0038-winex11-don-t-cancel-menu-tracking-while-the-focus-s.patch)
changes `dlls/winex11.drv/event.c`. While the foreground thread reports
`GUI_INMENUMODE`, `focus_out()` sends `WM_CANCELMODE` only when
`XGetInputFocus` reports another client's window. `None`, `PointerRoot`, and
other Live windows no longer cancel the menu. Switching to another
application still cancels it. Clicking outside follows the capture path and
still closes it.

## Verification

- `scripts/build-audit.sh` checks the patch marker in `winex11.so`.
- [../tools/menutest.c](../tools/menutest.c) reproduces the Win32 menu path.
- `WINEDEBUG=warn+event` logs `Ignoring FocusOut on ... during menu
  tracking` when the guard runs.

The issue #3 retest established the scope of this patch: Preferences
dropdowns never reached it. Patch 0039 handles those windows.
