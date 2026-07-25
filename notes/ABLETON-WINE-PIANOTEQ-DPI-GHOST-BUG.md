# Pianoteq editor resize loop

Disable **Auto-Scale Plugin Window** in Live, then reopen Pianoteq. This stops
the half-size ghost image and restores modal input. No Wine patch is required.

## Cause

With auto-scale enabled, Live creates the `Vst3PlugWindow` at 96 DPI while its
main window runs at 192 DPI. Wine scales the plugin surface by 2x. The resize
negotiation between JUCE and Live then mixes physical frame metrics with
logical coordinates and never settles.

The editor alternates between about 724x707 and 1183x1211 logical pixels. A
new frame at the smaller size appears over pixels from the previous larger
frame. Clicks on those stale pixels miss JUCE modals.

Standalone Pianoteq is unaffected because it runs in one DPI space.

## Evidence

Rate-limited present and resize traces showed changing buffer sizes while the
thread DPI context stayed constant. A `trace+win` capture showed that the host
resized the top-level window first. This ruled out a DPI-context flip inside
Pianoteq.

[`tools/dpispy.c`](../tools/dpispy.c) reports the unaware
`Vst3PlugWindow`.

## Related Wine patches

[Patch 0023](../patches/0023-wined3d-dxgi-query-present-resize-client-rects-in-th.patch)
queries present and resize rectangles in the target window's DPI context.
This hardens mixed-DPI presentation but does not stop an editor that Live
hosts as DPI-unaware.

[Patch 0024](../patches/0024-wined3d-keep-present-resize-DPI-diagnostics-at-trace.patch)
keeps the related probes behind `WINEDEBUG=trace+d3d`.
