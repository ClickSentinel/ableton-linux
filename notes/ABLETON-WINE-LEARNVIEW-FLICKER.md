# Learn View stale rendering and automatic refresh

Superseded 2026-07-27: enabling Live's GPU renderer removes the visible
pane flicker described here. The mechanism analysis below remains
accurate for the GDI renderer. See
[the GPU renderer note](ABLETON-WINE-GPU-RENDERER.md).

[`Patch 0041`](../patches/0041-dxgi-make-dcomp-presents-visible-on-webview2-s-unat.patch)
makes WebView2 frames visible and keeps the latest frame on screen.
`learnheal.exe`, added in release 2026.07.21.2, refreshes each settled Learn
View automatically. A stale, clipped band can remain visible for about three
seconds while the helper waits for the pane size to stabilize.

If the helper is missing, move the Learn View splitter once.
`tools/posteresize.exe` performs the same size change from inside the prefix.

## Patch 0041

Patch 0041 changes three parts of `dlls/dxgi`.

1. At `WM_WINE_DCOMP_SET_TARGET`, Wine normalizes a target that has
   `WS_EX_NOREDIRECTIONBITMAP`, or has `WS_EX_LAYERED` without layered
   attributes:

   ```c
   SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
   ```

   Windows treats this as a no-op for a `NOREDIRECTIONBITMAP` window. Wine
   turns the target into an opaque surface, which gives the DirectComposition
   buffer a visible destination. Attributed layered windows, including JUCE
   DropShadower and `UpdateLayeredWindow` users, are unchanged.

2. A stale-size skip starts one 120 ms reblit timer. The callback checks the
   current size again, stops after five attempts, and is removed by both
   `WM_NCDESTROY` paths and `d3d11_swapchain_Release`.

3. Patch 0025 used to stop reblits after three idle seconds. Patch 0041
   removes that timeout. Otherwise Chromium's old GDI frame returned after a
   correct DirectComposition frame had been shown.

Live 12.4.3 at 125% scale was tested by moving the splitter, reopening the
pane, and running `tools/posteresize.exe`. Correct content remained visible
after the refresh.

## Automatic refresh

The launcher starts `learnheal.exe` with Live. The helper waits until a Learn
View or documentation pane keeps the same rectangle for about three seconds,
then changes its width by one pixel and restores it. It refreshes the first
stable rectangle. A combined width and height change greater than four pixels
rearms it. It exits about 60 seconds after Live closes.

An instrumented `tools/fakepane.c` test confirmed one delayed refresh and no
repeat at the same size. A refresh sent when WebView2 first binds did not
update the content and could make later manual resizing ineffective.

Until the helper runs, Chromium's stale GDI frame and Wine's current reblit
can alternate at about 10 Hz. Once refreshed, both contain the same content
and the pane remains stable. The documentation sidebar uses the same WebView2
layout and helper.

## Cause

Traces from `+dxgi`, `dcompspy`, `hwndspy`, and X11 pixel sampling established
this sequence:

1. Chromium created a composition swapchain at the pane's temporary size,
   observed as 1273x1552. About 400 ms later it called
   `ResizeBuffers(299x804)` for the final pane.
2. Before that resize, `WM_PAINT` and `dcomp_reblit_comp_buffer` copied the
   wide snapshot into the narrow window. The result was a clipped band laid
   out for the old width. Patch 0030 rejects those stale-size copies.
3. After the resize, the composition buffer was correct and full-frame
   `BitBlt` calls ran, but the X11 pixels did not change. The Intermediate
   D3D Window had `WS_EX_LAYERED | WS_EX_NOREDIRECTIONBITMAP |
   WS_EX_TRANSPARENT` and no layered attributes. winex11 did not map that
   window, and the server suppressed its redraws. The visible sibling below
   it, `Chrome_RenderWidgetHostHWND`, still held Chromium's old software
   frame. Patch 0041 gives the composition buffer a visible target.
4. The window chain is `AbletonWebViewHelperWindow`, `Chrome_WidgetWin_0`,
   `Chrome_WidgetWin_1`, then sibling windows
   `Chrome_RenderWidgetHostHWND` and `Intermediate D3D Window`.

## Rejected approaches

- Discarding GDI draws to `NOREDIRECTIONBITMAP` windows removed the
  alternation but also discarded Wine's reblit. Child windows had no other
  working rendering method.
- `UpdateLayeredWindow` could not deliver the frame because win32u does not
  give child windows their own surface. It took the driver-only branch and
  copied nothing.
- Copying into the sibling window's DC remained hidden behind the sibling's
  own X child window.
- Hiding either sibling stopped Chromium presentation through occlusion
  tracking.
- `ABLETON_DCOMP=off` made WebView2 show its error page.
- Tested WebView2 GPU and software-composition flags did not produce a stable
  pane. Ableton's browser process supplies its own
  `--disable-gpu --disable-gpu-compositing --disable-direct-composition
  --disable-accelerated-2d-canvas` flags. Launcher flags affect only the GPU
  process backend.
- A bind-time one-pixel refresh failed in six of six starts and could prevent
  the later manual refresh. `learnheal.exe` waits for stable geometry instead.

## Regression checks

Check JUCE DropShadower windows and SWAM plugin editors after dxgi changes.
They use the
[layered-attribute handling](../patches/0015-win32u-sync-layered-attributes-to-the-scaled-surface.patch),
not the unattributed `NOREDIRECTIONBITMAP` target handled by patch 0041. A
visual test still covers the shared DirectComposition handling.

Test the Learn View and documentation sidebar at 100% and 125% scale. Relevant
tools are:

- [`dcompspy.c`](../tools/dcompspy.c)
- [`hwndspy.c`](../tools/hwndspy.c)
- [`xdmg.c`](../tools/xdmg.c)
- [`xsamp.c`](../tools/xsamp.c)
- [`xgrid.c`](../tools/xgrid.c)
- [`xsettle.c`](../tools/xsettle.c)
- [`posteresize.c`](../tools/posteresize.c)
