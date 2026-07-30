# Text blur in Live's own UI, 2026-07-21

Live 12 Suite renders visibly soft text in its own Skia-drawn UI under
this project's `d2d1-dcomp` runtime, where the identical prefix renders
crisp under ENCORE's build and under stock Wine. Still open. The cause
is narrowed to presentation rather than font rendering, and to something
both 11.11 and 11.13 of the `giang17/wine` fork share, but it has not
been traced.

## Status

Open, and narrower than when this file was opened. Three symptoms
originally filed here together have since been fixed, and all three are
documented in
[ABLETON-WINE-MENU-COLOR-THEMING.md](ABLETON-WINE-MENU-COLOR-THEMING.md)
rather than here:

- Grayed menu-item ghosting, which turned out not to be blur at all but
  a stock-Wine engraved-bevel double-draw. Patch `0049`.
- Menu contrast, and the chrome following Live's theme live. Patches
  `0050`/`0051`.
- Non-Latin menu text rendering as tofu. Patch `0054`, on the
  `language-fallback` branch.

Only the softness in Live's own UI remains, and it is the one symptom
never reproduced outside the fork.

## Scope

Two unrelated rendering paths were conflated for most of this
investigation, and separating them is much of what this note is for.

- **Wine's native win32 chrome** - menu bar, dropdowns, dialogs, drawn
  by `dlls/win32u/menu.c` through GDI. `FontSmoothingType`, font
  substitution and `SetSysColors` all act here. Everything on this path
  is fixed; see the theming note.
- **Live's own UI** - browser panel, track view, mixer, drawn by Live's
  bundled Skia. Nothing Wine implements for GDI or DirectWrite reaches
  it. This is the path still under investigation, and the only one this
  note covers.

The original "the browser panel is blurry too" report was never
re-examined after the chrome half was fixed. It may be a real separate
symptom, or the eye generalising from the menu ghosting, which was by
far the most visible instance of soft-looking text.

## Rendering stack

Live 12 bundles its own renderer and does not paint text through
DirectWrite or D2D1 at all. Confirmed from symbols in `Ableton Live 12
Suite.exe`: `SkiaAndHarfbuzzFont` (in an `ableton::font_rendering`
namespace, with `drawGlyphs`/`drawTextUtf8`), `SkTypeface_FreeType`,
`SkScalerContext_FreeType`, and build paths like
`...\third-party\skia\dist\...`. That is Skia for drawing, HarfBuzz for
shaping, and Skia's own FreeType backend for rasterization. DirectWrite
is loaded only for OS-level font *enumeration*, feeding Skia's font
matching; it never rasterizes a glyph.

FreeType is statically linked into Live's executable. Every DLL and EXE
in the install was checked for an external `freetype`/`ft2` import with
`objdump -p`; none exists. So Wine contributes no font-rendering code on
this path whatsoever - no Wine-side FreeType, no hinting or LCD-filter
setting, nothing GDI or DirectWrite exposes can affect how Live
rasterizes its glyphs, because that step runs self-contained inside
Live's own binary. `AbletonSansSmall-Regular.ttf` was also confirmed
opened directly out of the prefix's `C:\windows\Fonts` (49 opens in one
session, via an `openat` trace), ruling out a font-substitution
explanation as well.

This is why every GDI-level experiment below changed nothing: none of
them sit anywhere on the path Live's text actually renders through.

Together with the fact that the blur is absent on genuinely stock Wine,
this points away from font rendering and toward **presentation**. Skia
renders into its own bitmap regardless of Wine build, and
`_ForceGdiBackend` is active, so the leading remaining suspect is the
GDI blit that transfers Skia's bitmap onto the window
(`BitBlt`/`StretchDIBits`/`SetDIBitsToDevice`) - something the fork's
dcomp and compositing additions could plausibly touch even for a plain
GDI-presented window. Not yet traced.

## Evidence

1. **The blur is real, not a capture artifact.** Captured with
   `cosmic-screenshot --interactive=false --notify=false` (raw native
   PNG, no third-party resizing), cropped at 1:1 pixel scale on the
   output where Live renders. Same tool, monitor and compositor, both
   sessions minutes apart: ENCORE crisp, this project's runtime soft.
2. **Absent on stock Wine, not just on ENCORE.** A launcher
   misconfiguration accidentally ran Live against `/opt/wine-stable`, a
   distro-packaged vanilla Wine with zero `d2d1-dcomp` patches. Text
   rendered crisp there too. The blur reproduces specifically and only
   on the `giang17/wine` `d2d1-dcomp` fork.
3. **Not the Wine base version.** The project was rebased onto Wine
   11.13 specifically to close the version gap with ENCORE. A 4x
   nearest-neighbor zoom on the identical region shows the same fringing
   and softness on both 11.11 and 11.13, confirmed by eye as well. A
   launcher template missed in the rename first produced a false "it's
   fixed" read against the old 11.11 build still running; the running
   build was verified through `/proc/<pid>/maps` before any conclusion
   was drawn.
4. **Not a DPI or scale mismatch.** `LogPixels` = 96 in the prefix,
   matching a flat 100% host scale on every output. No `dpiAwareness`
   IFEO set.
5. **Not the win32 chrome font substitution.** `ABLETON_UI_FONT=off`
   makes no visible difference.
6. **Not `FontSmoothingType`.** Found at `0x1` (grayscale AA), inherited
   unchanged from the ENCORE-created prefix. Forcing `0x2` (ClearType)
   plus a `FontSmoothingGamma` of 1400 makes no visible difference.
7. **Not DirectComposition presentation.** `ABLETON_DCOMP=off` makes no
   visible difference.
8. **Not Wine's Wayland driver.** This build ships only `winex11.drv`;
   both ENCORE and this project render through Xwayland.
9. **Not the compositor's Xwayland descaling.** All outputs report
   integer 100% scale, and descaling only fires for fractional factors.
10. **Not the dcomp-swapchain patches.** They are scoped to an `HWND`
    property (`__wine_dcomp_swapchain`/`dcomp_target_wndproc`) set on
    WebView2 and JUCE composition targets. A
    `WINEDEBUG=+dxgi,+d3d11,+win32u` trace across a full normal-use
    launch shows zero `dcomp` mentions and exactly one `dxgi` call
    (`dxgi_output_GetDesc`, plain adapter enumeration). The main window
    never touches this codepath, confirming `_ForceGdiBackend` is
    honoured.
11. **Not the sub-scale WM config-rounding patch.** Its logic is gated
    on `dpi > USER_DEFAULT_SCREEN_DPI`; at a flat 100% scale every gate
    returns `FALSE` immediately.
12. **DirectWrite is load-bearing for Live's UI even so**, not a
    coincidental dependency. `dwrite.dll`/`dwrite.so` are mapped in the
    process, and relaunching with `WINEDLLOVERRIDES=dwrite=` does not
    fall back gracefully - Live creates its windows, then crashes
    (`EXCEPTION_WINE_CXX_EXCEPTION`, exit 1) the moment something uses
    it. Live depends on DirectWrite for font enumeration separately from
    the GDI-drawn chrome that `FontSmoothingType` governs.

## Rejected approaches

**The D2D1 rendering-mode substitution.** Retracted; do not
re-investigate. This was the first hypothesis after finding a real,
deliberate rendering-mode substitution in the fork, and it looked like a
strong match until a live trace showed `d2d1.dll` is not loaded in
Live's process at all. The code cannot run.

Found by diffing the fork's squash commits against the stock tree they
are based on. `dlls/dwrite/font.c`'s rendering-mode *selection* logic is
untouched stock Wine; the real change is in `dlls/d2d1/device.c`'s
`d2d_device_context_draw_glyph_run`, which every D2D1 text draw goes
through:

```c
/* Force NATURAL rendering mode for better font quality with FreeType.
 * ALIASED and OUTLINE modes produce poor results with Wine's FreeType
 * backend. This forcing is intentional; because it leaves OUTLINE
 * unreachable here the outline draw path (and its helper) was removed as
 * dead code — all glyph runs go through the bitmap path below. */
if (rendering_mode == DWRITE_RENDERING_MODE_ALIASED ||
    rendering_mode == DWRITE_RENDERING_MODE_OUTLINE)
{
    rendering_mode = DWRITE_RENDERING_MODE_NATURAL;
}
```

Any app requesting `ALIASED` (crisp, non-antialiased, a natural choice
for small UI text) or `OUTLINE` silently gets `NATURAL` instead,
unconditionally. The fork's own comment confirms this is a deliberate
workaround for FreeType rendering those modes badly, done for its actual
target of JUCE8/VSTGUI plugin editors and never validated against
Ableton. A related hunk in `create_glyphrunanalysis` substitutes
`DWRITE_RENDERING_MODE1_NATURAL_SYMMETRIC_DOWNSAMPLED` with plain
`NATURAL_SYMMETRIC`, again with an explicit "not fully supported"
comment. Both are the same class of bug and may still be worth fixing
for whatever plugin editors *do* go through D2D1 - but that is a
separate concern, not this one, and the proposed fix of dropping the
forcing is moot here.

An earlier `ABLETON_D2D1_FORCE_GRAYSCALE_TEXT` experiment on
`wine-11.13-upgrade` touched antialiasing-mode selection elsewhere and
made no visible difference, which fits: it never reached this
substitution either.

**ClearType fringing on disabled text.** Superseded. A zoomed screenshot
showed red/cyan fringing on grayed items and this was read as ClearType
blending against a wrong assumed background. It was really the engraved
bevel's white pass, and issue #35's "Wine draws an extra stroke"
described the same thing. Patch `0049` resolved it. The fork's changed
initial surface fill (white to black in `window_surface_create`,
`dlls/win32u/dce.c`) was also tested against this hypothesis with a
one-line revert, rebuilt and installed to an isolated directory: the
result was pixel-identical. Do not re-test that line.

## Background

`patches/BASE.txt` records that the base is not vanilla Wine: it is
`giang17/wine` branch `d2d1-dcomp-<version>`, vendored locally and
byte-identical, before any of this project's own patches apply. That
fork's `PATCHES.md` describes itself as adding D2D1, DirectComposition
and DirectWrite support so third-party JUCE8/VSTGUI plugin editors
(Serum2, Korg Trinity, Korg Prophecy, Pianoteq 9) render correctly in
Reaper, and lists a "DWrite: Rendering mode 5 fix" among its changes. It
does not mention Ableton Live anywhere.

## Next steps

Given Live renders through its own bundled Skia, HarfBuzz and FreeType
rather than DirectWrite or D2D1, the useful next steps sit at the
font-file and presentation level:

1. Trace which font **file** Live's Skia backend opens for its UI text
   (`WINEDEBUG=+file`, or `strace -e openat`), comparing this project's
   build against ENCORE's on the identical prefix. Confirm both open the
   same literal file rather than different fonts that merely look
   similar.
2. If the file matches, compare what Skia's Windows font-host layer
   queries from the OS to configure its rasterizer - likely
   `SystemParametersInfo(SPI_GETFONTSMOOTHINGTYPE)` and
   `SPI_GETFONTSMOOTHINGCONTRAST` - and whether Wine returns different
   values than ENCORE's build effectively provides. Skia may read these
   through a different API path than the raw registry key, which tested
   identical in evidence 6.
3. Trace the GDI blit that presents Skia's bitmap
   (`BitBlt`/`StretchDIBits`/`SetDIBitsToDevice`) on both builds. This
   is the leading suspect and has not been looked at.

## Reproduction

Copy a licensed prefix, then launch the same install both ways and
compare a 1:1 crop of the same region:

```sh
ABLETON_WINEPREFIX=~/ableton-prefix-shibco ableton-live
ENCORE_PREFIX=~/ableton-prefix ENCORE/scripts/run-ableton.sh
cosmic-screenshot --interactive=false --notify=false --save-dir=<dir>
```

The environment this was characterised on: a byte-for-byte copy of a
real licensed ENCORE prefix, Live 12.4.3, COSMIC on Wayland, three
outputs all at 100% scale, Live rendering on a 2560x1440 Xwayland
primary. Screenshots and traces from the original session were not
preserved.
