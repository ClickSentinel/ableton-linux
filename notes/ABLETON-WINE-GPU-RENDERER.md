# Live's GPU renderer: enablement and effects

This note explains why the stack now runs Live's own GPU renderer, what
that fixes, and how to verify it. Change date: 2026-07-27.

## The change

Remove the line `-_ForceGdiBackend` from every
`drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences/Options.txt`
in the prefix. `scripts/setup-prefix.sh` step 5c does this
automatically. Live then uses its Direct2D/Direct3D 11 renderer instead
of the GDI fallback.

Wine patch 0053 accompanies the change: winex11 exports the app's
`WM_GETMINMAXINFO` minimum tracking size as the X11 `PMinSize` hint, so
the window manager clamps interactive resizes at Live's minimum.

## What it fixes

- The WebView2 pane flicker (Learn View, Splice view): with the GDI
  renderer, Wine's DirectComposition keep-alive reblit (patch 0041) and
  Chromium's stale software frame alternated in the pane at 5 Hz. With
  the GPU renderer both painters hold identical content and the pane is
  stable. Measured 2026-07-27 with xdmg and frame hashing: the 5 Hz
  damage stamps still fire but 30 of 30 pane captures hash identical,
  on both the wine-11.11 production runtime and the wine-11.13 build of
  main.
- Idle CPU drops to 1-2% (reported by the maintainer on the production
  setup). The GDI renderer measured about 59% of one core mid-session.
- Below-minimum interactive resize (patch 0053): without the PMinSize
  hint, shrinking a window below Live's minimum (1610x1346 physical at
  200% scale) made Live counter the grant mid-drag; the window grew at
  the opposite edge and the configure storm could end in a spurious
  maximize. With the hint the window manager stops the drag at the
  minimum.

## Why -_ForceGdiBackend existed

Early setups (before the giang17 d2d1-dcomp base fork and before the
file-dialog portal, patch 0031) hit blank file dialogs when Live's GPU
renderer was on, and the flag was carried into the prefix as a
requirement. Both reasons are gone: the base fork exists to make
Direct2D rendering work, and file dialogs go through the XDG portal.
The old machine-local docs that mark the flag as required are
superseded by this note.

## Verification

1. `grep -r ForceGdiBackend "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/*/Preferences/Options.txt`
   returns nothing.
2. Open the Learn View and the Splice view. Both render their content
   and stay stable.
3. `xprop -id <live-x-window> WM_NORMAL_HINTS` shows
   `program specified minimum size`.
4. Drag a window edge below Live's minimum. The drag stops at the
   minimum and the window does not fight the drag.

Checks that still need a pass after longer real-world use: file dialogs
under sustained work, plugin editor open/close (JUCE, SWAM), and both
panes across scale factors other than 200%.

## Present path (added 2026-07-29, issue 91)

A present is the step where Live hands a finished frame to Wine for
display. With the GPU renderer on, Wine handled every present of Live's
main window on its GDI path: it copied the finished frame from the
graphics card into main memory and sent it to the display server as a
full-window image, about 14 MB per frame at 2560x1350. An idle window
presents nothing, so the idle figures above stay correct. Continuous UI
activity, including mouse movement over the window, produced about
650 MB per second of display-server traffic and used more than one CPU
core. Lucas Gillingham (ClickSentinel) reported and measured this in
issue 91.

Wine patch 0055 marks the main window's frame buffers at creation with
`WINED3D_SWAPCHAIN_PREFER_GL_PRESENT`. Wine then shows each finished
frame directly from the graphics card with `glXSwapBuffers` and skips
the copy. The patch applies this to top-level windows only. Windows
with the `WS_CHILD` style (composition targets, embedded plugin
editors) keep the GDI path because they have no X11 window of their
own. Windows with the `WS_POPUP` style (Settings, the authorisation
dialog, context menus) also keep the GDI path because they show black
content on the direct path until the first click or keypress. Set
`WINE_DISABLE_GL_PRESENT=1` in the environment to restore the GDI path
for every window; a rebuild is unnecessary.

To confirm which path a build uses, start Live with
`WINEDEBUG=fixme+all,err+all` and count the message `Using GDI present`
in the log. One occurrence means the copy path. Zero means the direct
path. The launcher sets `WINEDEBUG=-all` by default, so pass
`WINEDEBUG` explicitly. Turn tracing off when measuring bandwidth,
because the log's own writes count toward `/proc/<pid>/io`.

These measurements come from one machine (AMD Navi 31, COSMIC/Wayland
via XWayland). Confirmation on Intel or NVIDIA hardware and on a
non-Wayland session is still open.

## Related

- [Diagnosis narrative](ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md)
- [Learn View flicker mechanism](ABLETON-WINE-LEARNVIEW-FLICKER.md)
- [Patch 0053](../patches/0053-winex11-export-the-app-minimum-tracking-size-as-PMin.patch)
- [Patch 0055](../patches/0055-dxgi-prefer-GL-present-for-top-level-swapchain-devic.patch)
- Resize trace from the diagnosis session:
  `~/Projects/Code/ableton/live-resize-trace-gpu-20260727.log`
  (machine-local)
