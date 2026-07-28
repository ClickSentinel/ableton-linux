# Max for Live selection flicker

## Symptom

With a Max for Live device such as Convolution Reverb Pro selected, choosing a
different track and then choosing the M4L track again can flash Live's whole
window black. The device continues to run and its rendered contents remain
healthy.

## Window transition

The visible M4L device contributes a child window to Live's client area.
Selecting away hides the child; selecting back shows it. That changes the
client clipping region evaluated by `needs_client_window_clipping()` in
`dlls/winex11.drv/init.c`.

For a simple region, `needs_offscreen_rendering()` returns false and the client
window is attached to Live's whole X window. For a clipped region it returns
true, `client_surface_update_offscreen()` redirects the client through
XComposite, and `detach_client_window()` reparents it to winex11's dummy
parent. Reversing the selection reverses the operation.

The observed full-client sequence was:

```text
Unmap    win=0x3000100 parent=0x3000056 geo=0,23 1920x1057
Reparent win=0x3000100 parent=0x3200003 geo=0,23 1920x1057
Map      win=0x3000100 parent=0x3200003 geo=0,23 1920x1057

Unmap    win=0x3000100 parent=0x3200003 geo=0,0 1920x1057
Reparent win=0x3000100 parent=0x3000056 geo=0,0 1920x1057
Map      win=0x3000100 parent=0x3000056 geo=0,0 1920x1057
```

Those transitions began 8-13 ms after the corresponding selection clicks. A
first-M4L-device capture included a compositor frame with mean luminance
`0.0120`; stable Live frames measured about `0.2205`.

## Patch 0057

Patch 0057 adds `WINE_X11_FORCE_OFFSCREEN_CLASS`. When it exactly matches a
top-level Windows class, winex11 keeps that window's client surface on the
offscreen-composited path. The Live launcher defaults it to:

```bash
WINE_X11_FORCE_OFFSCREEN_CLASS="Ableton Live Window Class"
```

This changes neither child visibility nor device rendering. It removes the
full-client attach/detach operation caused by those visibility changes.

Across six track-away/track-back cycles with the patch enabled:

- full-client `Unmap`/`Reparent`/`Map` transitions: 0
- compositor frames captured: 347
- minimum mean luminance: `0.224746`
- frames below `0.10`: 0

For a one-launch control using the original behavior:

```bash
WINE_X11_FORCE_OFFSCREEN_CLASS=off ableton-live
```

`off` is simply a class name that does not match Live, so the Wine behavior is
not forced.
