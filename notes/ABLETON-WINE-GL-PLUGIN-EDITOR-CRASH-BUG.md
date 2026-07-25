# OpenGL plugin editor depth mismatch

Patch 0026 fixes a depth mismatch that affected OpenGL plugin editors on
depth-32 ARGB windows. CHOW Tape Model was the confirmed reproduction.

Before the patch, opening its JUCE/OpenGL VST3 editor reduced the window to
1x1 and stopped Live's rendering. The log ended after
`VST3: Created: CHOWTapeModel`, and stderr reported:

```
X Error of failed request:  BadMatch (invalid parameter attributes)
  Major opcode of failed request:  139 (RENDER)
  Minor opcode of failed request:  4 (RenderCreatePicture)
```

The tested setup failed on the editor's first paint, not when Live loaded the
plugin.

## Cause

Wine composites an OpenGL child surface onto its top-level window in
`X11DRV_client_surface_present` (`dlls/winex11.drv/init.c`) via
`NtGdiStretchBlt` to a display DC. A fresh display DC starts on the depth-24
root pict format (`WXR_FORMAT_ROOT`). The present points the DC at the window
with `set_dc_drawable`, whose `X11DRV_SET_DRAWABLE` escape carries no visual
(`escape.visual == {0}`). `xrenderdrv_ExtEscape` therefore keeps the current
depth-24 format.

Depth-24 windows are unaffected. This patch series gives high-DPI layered
plugin-editor top-levels a depth-32 ARGB visual for title bars and shadows;
see
[ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md](ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md).
A depth-32 window with a depth-24 format makes `XRenderCreatePicture` fail
with `BadMatch` because a window picture's format must match its visual. A
trace recorded `ddepth=32 fmtdepth=24` at the failing call.

## Fix

[Patch 0026](../patches/0026-winex11-report-the-drawable-s-visual-in-set_dc_drawa.patch)
makes two changes:

1. `init.c set_dc_drawable`: query the drawable's visual
   (`XGetWindowAttributes`) and fill `escape.visual`; the escape selects a
   pict format matching the actual depth, so a depth-32 window gets
   `A8R8G8B8`. Non-window drawables such as GLX pbuffers keep the existing
   format.
2. `window.c X11DRV_ReleaseDC`: initialize the escape visual to the root
   window's default visual instead of leaving it uninitialized.

After the patch, the editor opened at the expected size and rendered without
an X error. Live remained responsive.

## Scope

The trigger is an OpenGL client surface presented onto a depth-32 top-level,
not CHOW Tape Model itself. Patch 0026 must remain with the patch that adds
depth-32 visuals for plugin title bars and shadows.
