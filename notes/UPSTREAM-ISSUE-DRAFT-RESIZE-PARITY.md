# Draft upstream report for 2x resize rounding

Status: draft prepared on 2026-07-21. This repository records no filed issue
URL. Patch 0042 works around the fault in this Wine build.

File the compositor behavior with
[Mutter](https://gitlab.gnome.org/GNOME/mutter/-/issues). A separate
[Wine report](https://bugs.winehq.org) can cover how winex11 handles the
rounded grant.

The Xwayland 24.1.12 to 24.1.13 source diff was reviewed during the
investigation. It contained no geometry or `hw/xwayland` change, so the
version correlation did not identify an Xwayland regression. Reapplying the
Live `dpiAwareness` setting on 2026-07-19 exposed the behavior again.

## Suggested Mutter title

X11 configure requests with odd physical geometry are rounded up under
xwayland-native-scaling and can cause a resize feedback loop

## Suggested Mutter report

Environment:

- GNOME Shell 50.3 and Mutter 50.3
- xorg-xwayland 24.1.13
- Wayland session on CachyOS
- one monitor at 125% fractional scale with a 2x XWayland framebuffer
- `scale-monitor-framebuffer` and `xwayland-native-scaling` enabled

With `xwayland-native-scaling`, an observed X11 `XConfigureWindow` request
with an odd physical height was granted one pixel larger:

```text
requested: (1182,132)-(3210,2613), height 2481
granted ConfigureNotify height: 2482
```

This repeated on every request. Ableton Live 12 under Wine exposed a parity
loop:

1. Live used per-monitor DPI at 2x and accepted only even physical client
   sizes.
2. Wine's frame calculation added an odd offset between client and outer
   geometry.
3. After an interactive resize, Live requested one pixel more than each
   grant.
4. Mutter rounded that odd request up by one pixel.

The outer window grew two physical pixels per cycle, about 20 to 40 pixels
per second. One trace grew from 2390 to more than 6600 pixels before the test
stopped.

A standalone reproducer still needs to be written. It should request `H + 1`
after each even-height `ConfigureNotify`. On the tested 2x configuration,
that sequence should grow continuously; on 1x it should settle after one
request.

Questions for Mutter:

- Is rounding odd X11 geometry up an intended
  `xwayland-native-scaling` contract?
- Can an unrepresentable grant avoid exceeding the requested size?
- Is there another acknowledgement rule that lets grid-aligned clients
  converge?

The local workaround is
[patch 0042](../patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch).
Wine keeps the requested Win32 rectangle when the host grant differs only by
sub-scale rounding on aligned edges.

## Optional Wine report

winex11 passes a window-manager grant that differs by sub-scale rounding back
to Win32. A per-monitor-aware application with grid-aligned layout can round
again and issue another request without reaching a fixed size.

Suggested Wine behavior: when a grant differs from the request only within
one integer scale unit on aligned edges, record the host geometry but keep
the requested Win32 geometry. Patch 0042 provides a tested implementation.

## Local evidence

The supporting traces are not included in this repository:

- `live-trace-interactive-20260721.log`: full `+win,+x11drv` trace with the
  measured 7-pixel menu band.
- `ratchet-segment.log`: extracted resize cycle.
- `live-trace-band8-20260721.log` and `band8-segment.log`: the same test with
  an 8-pixel band, showing that the frame constant does not stop the loop.
- `xw-diff/`: Xwayland 24.1.12 and 24.1.13 source trees and their diff.
