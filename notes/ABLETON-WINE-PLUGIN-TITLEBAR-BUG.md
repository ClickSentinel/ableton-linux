# Plugin title bars and shadows

[Patch 0014](../patches/0014-win32u-winex11-give-captioned-tool-windows-the-nativ.patch)
fixes oversized Wine-drawn plugin title bars.
[Patch 0015](../patches/0015-win32u-sync-layered-attributes-to-the-scaled-surface.patch)
fixes opaque black JUCE shadows.

Both faults appeared at a 2x XWayland framebuffer with `LogPixels=192`.

## Window layout

| Property | Main window | Plugin editor |
| --- | --- | --- |
| Class | `Ableton Live Window Class` | `Vst3PlugWindow` |
| Style | `0x2cf0000` | `0xc80000` |
| Extended style | `0` | `0x80` (`WS_EX_TOOLWINDOW`) |
| DPI space | 192 | 96 |
| Decoration before patch | Native frame | Oversized Wine caption |

Live removes the standard caption from its main window and uses the native
window-manager frame. A plugin editor keeps its Win32 non-client area. Stock
Wine gives `WS_EX_TOOLWINDOW` windows no native decoration, so Wine draws the
caption at 96 DPI and XWayland scales it by 2x.

Live also calculates the editor inset with 192-DPI metrics while the editor
rectangle remains in 96-DPI space. The 29-unit difference exposes the Wine
caption inside the X window. [`tools/fakeplugin.c`](../tools/fakeplugin.c)
reproduces the same rectangles.

## Fixes

Patch 0014 requests native decoration for captioned tool windows. It maps the X
window to the client rectangle, leaving the Win32 caption outside the visible
X surface. The native frame is then the only title bar. It does not reconstruct
frame extents or change Live's window and client rectangles.

The tested editor had `visible == client`, one draggable native title bar, and
no extra `SetWindowPos` traffic outside user drags. The main window was
unchanged.

Patch 0015 handles JUCE DropShadower windows. Before the patch,
`scaled_surface_flush` copied layered alpha values to the target X11 surface
only after a shape change. Shadow windows have no shape, so transparent black
pixels became opaque. The patch synchronizes the layered attributes on every
flush and does nothing when they are unchanged.

## Rejected approaches

Patches 0010 through 0013 preserve two experiments and their reverts:

1. Native decoration without changing the visible rectangle produced two title
   bars.
2. Reconstructing `_NET_FRAME_EXTENTS` collapsed the editor because physical
   frame extents were subtracted from a 96-DPI rectangle.

Do not reconstruct frame extents when the window rectangle and extents use
different DPI spaces.

## Related checks

XGetImage screenshots flatten ARGB without desktop compositing. Check shadow
transparency on screen.

The `visible == client` mapping gives these editors a depth-32 ARGB visual.
[Patch 0026](../patches/0026-winex11-report-the-drawable-s-visual-in-set_dc_drawa.patch)
keeps OpenGL presentation on that visual. See
[ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md](ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md).
