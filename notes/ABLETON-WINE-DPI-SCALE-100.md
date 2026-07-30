# Display scale and window sizing

Release 2026.07.21.2 fixes the two faults documented here. The launcher
recalibrates the Wine prefix before each start. On the tested Live 12.4.3
GNOME/XWayland setup at 125%, Wine patches 0040 and 0042 kept the main window
stable during tiles, moves, and interactive resizes.

## Scale calibration

A prefix calibrated for 125% GNOME scaling misbehaves after the desktop
changes to 100%. Live can appear magnified, show a doubled cursor, move down
by one or two pixels per cycle, or repeatedly request a different size from
the window manager.

GNOME with `xwayland-native-scaling` uses an integer-scaled XWayland
framebuffer. These settings must agree:

| Setting | 125% display scale | 100% display scale |
|---|---:|---:|
| `HKCU\Control Panel\Desktop\LogPixels` | 192 | 96 |
| Live IFEO `dpiAwareness` | `2` | absent |
| Mutter `xwayland-native-scaling` | enabled | disabled |

For GNOME, `LogPixels = 96 * ceil(display scale)`. The Live
`dpiAwareness=2` value is present only when the framebuffer is scaled above
1x.

The stale values cause distinct symptoms:

- `LogPixels=192` on a 1x framebuffer doubles Live's rendering scale.
- A stale `dpiAwareness=2` value makes Live and XWayland disagree about the
  surface scale. The traced window then moved down by one or two pixels per
  cycle.
- `xwayland-native-scaling` on a 1x setup doubles Wine's X11 cursor.

[`scripts/detect-scale.sh`](../scripts/detect-scale.sh) detects GNOME, KDE,
sway, Hyprland, COSMIC, and an Xft DPI fallback. On non-GNOME desktops it
uses `LogPixels = round(96 * display scale)` with no IFEO value. Supported
display scales range from 100% to 250%.

The launcher updates `LogPixels` and the Live-specific IFEO value before
each start. It does not change Mutter settings. It warns when
`xwayland-native-scaling` disagrees with the selected DPI block.

Use a launcher override to force a known block:

```bash
# 100%, with LogPixels 96 and no IFEO value
ABLETON_DPI_MODE=100 "$HOME/.local/bin/ableton-live"

# GNOME fractional scaling, with LogPixels 192 and dpiAwareness=2
ABLETON_DPI_MODE=fractional "$HOME/.local/bin/ableton-live"
```

`ABLETON_DPI_MODE=preserve` leaves the prefix unchanged. Generic non-GNOME
blocks use `dpi<N>`, such as `dpi120` for 125%. If you change Mutter's
experimental features, preserve every unrelated entry and log out before
testing again.

## Main-window growth

At 100%, Live used to add about 56 pixels to the main window during one
interactive resize. A trace showed that Live recalculates its outer rectangle
after each window-manager `ConfigureNotify`. Its calculation uses the client
rectangle, `AdjustWindowRectExForDpi(menu=TRUE)`, and an extra menu-band
allowance.

[Patch 0029](../patches/0029-win32u-lay-out-the-menu-bar-4px-taller-than-SM_CYMEN.patch)
matched the 96 DPI allowance. Live 12.4.3 uses a 4-pixel allowance at 96 DPI
and a 7-pixel allowance at 192 DPI.
[Patch 0040](../patches/0040-win32u-scale-the-menu-bar-band-with-the-menu-dpi.patch)
uses:

```text
max(4, muldiv(4, dpi, 96) - 1)
```

This gives 4 pixels at 96 DPI, 5 at 144 DPI, and 7 at 192 DPI. Popup menus
remain font-sized.

Patch 0040 fixed programmatic moves and tiles, but interactive resizing at
125% could still add two pixels per cycle. The remaining cause was parity:

1. XWayland granted only even physical sizes at a 2x framebuffer scale.
2. Live's per-monitor layout also produced even sizes.
3. Wine's frame offset between those grids was odd.
4. Live rounded each odd grant up, and the window manager rounded the next
   request again. Neither a 7-pixel nor an 8-pixel menu band could converge.

[Patch 0042](../patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch)
tracks each configure request. When a granted rectangle differs from the
request only by sub-scale rounding on scale-aligned edges, Wine reports the
requested rectangle to Live. It answers later requests in that range without
another X request.

Live 12.4.3 at 125% was tested with interactive resizes, window-manager
tiles, and moves. Each operation settled once and held across sessions. The
full trace analysis is in
[FINDINGS-RESIZE-GROWTH-2026-07-21.md](../FINDINGS-RESIZE-GROWTH-2026-07-21.md).

## Diagnostic tools

The relevant probes are in [`tools/`](../tools/):

- `metricprobe.c` and `metricprobe2.c` inspect frame metrics.
- `wmresize.c` and `wmresize2.c` reproduce window-manager resizes.
- `menumeasure.c` measures the menu band.
- `showrestore.c` checks restored geometry.
- `xsettle.c` records when X geometry settles.

Run probes under the Live IFEO `dpiAwareness` value, not raw. Every raw
probe run at 125% collapses into the unaware doubling loop described
above, so its output is noise rather than signal; the committed drift-0
probe logs date from the 100% era, when raw runs were still meaningful.
Comparing a raw 125% run against those logs invalidated one runtime
bisect before the trap was recognised.

Probes are also a weaker oracle than they look: they hold one thread in
one DPI context for their whole life, so any mechanism that depends on
the context changing under the window cannot reproduce in them. Patch
0040 was validated against `wmresize2` and still did not fix Live.
