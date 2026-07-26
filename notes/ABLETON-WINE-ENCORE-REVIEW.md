# ENCORE changes used by this project

The 2026-07-14 ENCORE review produced Wine patches 0033 and 0034. The later
resize investigation also adapted ENCORE's configuration rounding logic for
patch 0042.

ENCORE carries its Wine changes in `patches/encore-wine.patch`. This project
ports only the relevant parts onto the base recorded in
[`patches/BASE.txt`](../patches/BASE.txt).

## Patch 0033: show Unix mount points as directories

ENCORE's `dlls/ntdll/unix/file.c` change became patch 0033. Wine otherwise
reports Unix mount boundaries as `IO_REPARSE_TAG_MOUNT_POINT` junctions
without matching `FSCTL_GET_REPARSE_POINT` data. Live treats those entries as
unresolvable and omits them from its browser.

The patch adds `WINE_DISABLE_UNIX_MOUNT_REPARSE`. When set to `1`, Wine
reports those mount points as normal directories. The Live launchers set it.

## Patch 0034: flush XdndStatus replies

ENCORE's `dlls/winex11.drv/event.c` change became patch 0034. It flushes
each `XdndStatus` reply before a queued `XdndLeave` can overtake it. This
prevents intermittent drag rejection from file managers under XWayland.

## Patch 0042: handle window-manager rounding

The first 2026-07-21 review rejected ENCORE's winex11 configuration-rounding
state because a menu-band mismatch appeared to explain Live's window growth.
Further interactive-resize traces disproved that conclusion. Both the
measured 7-pixel band and a tested 8-pixel band repeated the resize.

The final cause was parity between Live's layout grid, XWayland's physical
grid, and Wine's odd frame offset.
[Patch 0042](../patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch)
therefore adapts ENCORE's state machine. It suppresses only sub-scale,
scale-aligned differences between a Wine request and the window manager's
grant. See
[`FINDINGS-RESIZE-GROWTH-2026-07-21.md`](../FINDINGS-RESIZE-GROWTH-2026-07-21.md).

Two related ENCORE changes remain unused:

- Its `WM_WINE_WINDOW_STATE_CHANGED` DPI-context change did not run in the
  failing trace; no `map_dpi_winpos` remapping occurred.
- Its `calc_menu_bar_size` rule adds 8 pixels at 192 DPI. Live 12.4.3's
  measured allowance is 7 pixels, which patch 0040 implements.

## Other changes not used

ENCORE's comdlg32 portal backend overlaps this project's patch 0031. Applying
both would register the comdlg32 Unix library twice, so this project keeps
the upstream Wine merge-request implementation used by patch 0031.

The 2026-07-21 comparison also found the same WebView2 flags in both
launchers. ENCORE disabled `dcomp.dll` by default at that date. In this
project's runtime, disabling it makes WebView2 show an error page, so that
setting was not adopted.
