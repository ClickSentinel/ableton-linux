# Ableton Live fullscreen layout and exit state

Issue 42 has two related fullscreen failures. `View -> Full Screen` can leave
the native menu visible, while F11 can shift or clip Live's client area and
offset pointer input. Exiting fullscreen can also leave the compositor showing
a fullscreen-sized surface until the window is moved or resized.

## Menu and client offset

Live uses custom chrome but leaves its Win32 menu attached while entering
fullscreen. Wine therefore continues to reserve and paint a menu band during
non-client calculation. Live compensates with a slightly oversized and shifted
window, so the Win32 client origin no longer agrees with the compositor's
viewport. The rendered controls and their input coordinates are displaced by
the unwanted menu allowance.

Patch 0065 lets the launcher select one exact top-level Windows class through
`WINE_WIN32_FULLSCREEN_CLASS`. When that class requests a rectangle covering a
monitor with no more than a small edge overshoot, win32u marks the window as
fullscreen before non-client calculation and clamps the request to the exact
monitor rectangle. The still-attached menu contributes no layout or painting
while that mark is active. Leaving fullscreen clears the mark and restores
ordinary menu handling.

The monitor-covering check is deliberately bounded: it does not turn arbitrary
large window requests into fullscreen, and it does not affect child windows or
classes that the launcher did not select.

## Fullscreen exit

Wine's X11 driver tracks both the compositor's current rectangle and a pending
configure request. During fullscreen entry, a ConfigureNotify can satisfy the
requested rectangle with a serial older than a later equivalent request. The
window is already at the requested geometry, but `configure_serial` remains
set.

If Live exits fullscreen in that state, Wine delays the
`_NET_WM_STATE_FULLSCREEN` removal while waiting for another configure. The
window manager in turn keeps the fullscreen surface until the EWMH state is
removed. An interactive move or resize produces a new configure and happens to
break that wait, which is why dragging the window appeared to repair it.

On the selected class's fullscreen-to-windowed transition, patch 0065 retires
only a pending configure whose rectangle is already identical to the current
compositor rectangle. It then updates `_NET_WM_STATE` before queuing the restored
window geometry. No synthetic move, recursive `SetWindowPos`, or compositor
specific command is involved.

The diagnostic trace for the repaired path includes:

```text
retiring redundant fullscreen config ... before exit
requesting _NET_WM_STATE 0
```

## Launcher and comparison override

The Live launcher selects the exact main-window class by default:

```text
WINE_WIN32_FULLSCREEN_CLASS="Ableton Live Window Class"
```

For a one-launch unpatched comparison:

```bash
WINE_WIN32_FULLSCREEN_CLASS=off ableton-live
```

`off` is simply a non-matching class name, so both 0065 paths remain dormant.
Without the variable, or for every other class, Wine keeps its existing
behavior.

This patch does not change general minimum-size handling. Patch 0053 remains
responsible for exporting Live's `WM_GETMINMAXINFO` minimum as the X11
`PMinSize` hint.

## Validation

- The complete Wine 11.13 patch stack built successfully and the build audit
  passed 88 checks, including the win32u and winex11 0065 fingerprints.
- `View -> Full Screen` and F11 entry/exit were exercised repeatedly on both
  Niri with xwayland-satellite and Plasma/KWin with Xwayland.
- Fullscreen covered the 1920x1080 output without a title bar, native menu, or
  desktop panel; client content and pointer input remained aligned.
- Each exit returned directly to normal floating geometry without a stale
  fullscreen surface, and the window could be moved and resized immediately.
- Ordinary windowed menu layout and post-fullscreen resizing remained intact.
