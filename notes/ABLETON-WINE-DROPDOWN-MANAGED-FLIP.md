# Preferences dropdowns change window-management mode

Patch 0039 fixes issue #3 and shipped in release 2026.07.19.2. A runtime
trace on GNOME confirmed the cause and the fix. Reported effects included a
flash or lost click on Cinnamon, a second-click requirement on GNOME, and an
extra shadow frame on KDE.

Patch 0038 remains valid but fixes a different FocusOut path used by win32u
menus. Live's Preferences lists do not use that path. See
[ABLETON-WINE-MENU-FOCUSOUT.md](ABLETON-WINE-MENU-FOCUSOUT.md).

## Cause

A reproduction was traced with:

```bash
WINEDEBUG=warn+event,trace+event,trace+x11drv,trace+menu
```

Live's menu bar uses win32u `#32768` menus. Their tracking completed normally
and never reached patch 0038's FocusOut gate.

Preferences lists are Live-owned `WS_POPUP` windows. Live first shows them
with `SWP_NOACTIVATE`, so Wine maps them as override-redirect windows. Live
then sends an otherwise inert `SetWindowPos` call with
`NOSIZE|NOMOVE|NOZORDER` and without `NOACTIVATE`.

Wine interpreted that second call as a request to manage the already mapped
popup. `X11DRV_WindowPosChanged` called `window_set_managed(TRUE)`, which
required an unmap and remap:

```text
window_set_wm_state  0x30156 WM_STATE 0x1 -> 0
window_set_managed   0x30156 override-redirect 1 -> 0
window_set_wm_state  0x30156 WM_STATE 0 -> 0x1
```

The unmap loses the click and causes the flash. The remapped popup is a
window-manager-controlled, dialog-typed top-level, so compositors may animate,
decorate, or restyle it.

## Fix

[Patch 0039](../patches/0039-winex11-never-flip-a-mapped-window-to-managed.patch)
changes `dlls/winex11.drv/window.c`. `window_set_managed` now rejects an
unmanaged-to-managed change while the window's desired `WM_STATE` is not
`Withdrawn`.

Wine still chooses the management mode when it maps a window. A hidden window
shown with activation can change mode before its map request. Embedded
windows are withdrawn before their mode changes, and the desktop window is
created withdrawn. Wine already rejected the reverse change while mapped.

## Verification

The full 0001 to 0039 series applied to base `7ea0c8b7`, and winex11 built
successfully. The GNOME trace no longer showed
`override-redirect 1 -> 0` for a mapped popup.

For desktop checks, open every Preferences dropdown on GNOME, Cinnamon, and
KDE, including over a full-screen Live window. With
`WINEDEBUG=warn+x11drv`, each rejected change logs:

```text
is mapped, refusing to make it managed
```

`scripts/build-audit.sh` checks for this string in `winex11.so`.
