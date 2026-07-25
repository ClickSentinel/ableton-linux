# Live resize growth at 125%

Patch 0042 resolved the resize loop in release 2026.07.21.2.

## Result

On the tested GNOME/XWayland system, Live 12.4.3 now holds its size during
interactive resize, tiling, and movement at 125% display scale. Repeated
sessions settled after at most one 2 px rounding adjustment, with no continued
growth.

Patch 0040 remains in the series for accurate one-shot menu geometry. It fixed
programmatic `_NET_MOVERESIZE_WINDOW` tiles, but it did not fix interactive
resize.

## Cause

On the tested GNOME setup with `xwayland-native-scaling`, XWayland used a 2x
framebuffer at 125% scale. The window manager granted even physical sizes, and
Live's per-monitor layout also produced even sizes. Wine's offset between the
whole window and visible frame was odd.

Each configuration round therefore changed parity. Live requested one pixel
more than the previous grant, the window manager rounded again, and the window
grew by 2 px per cycle. Menu bands of both 7 px and 8 px reproduced the loop,
so no constant frame adjustment could make it converge.

## Fix

Patch 0042 tracks each X11 configuration request. When the window manager's
reply differs only by rounding smaller than the compositor scale, Wine keeps
the requested Win32 rectangle. It also answers requests within that rounding
range without another X11 round trip.

The change was adapted from ENCORE's configuration-rounding work. See
[`patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch`](patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch).

## Evidence

- Real-input keyboard resize grabs reproduced the 2 px loop on Live 12.4.3.
- Traces with menu bands of 7 px and 8 px both reproduced it.
- The traces contained no `map_dpi_winpos` remapping. This ruled out the
  proposed wrong-DPI-context mechanism.
- After patch 0042, interactive resize, tiling, and movement held across
  repeated Live 12.4.3 sessions.
- `tools/wmresize2.c` showed why patch 0040 fixed the earlier model but did not
  represent Live's interactive resize path.

The detailed DPI history remains in
[`notes/ABLETON-WINE-DPI-SCALE-100.md`](notes/ABLETON-WINE-DPI-SCALE-100.md).
