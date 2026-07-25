# Historical Wine 11.13 rebase assessment

Status: this is a snapshot from 2026-07-17, not a current rebase plan. It
describes the 33-patch series and upstream branches available on that date.
The project now carries later patches, so upstream state, conflicts, and test
coverage must be checked again before a rebase.

The dated recommendation was to move from Wine 11.11 to 11.12 first, then
take 11.13 after a matching d2d1-dcomp base appeared or after porting that
base locally.

## Upstream state on 2026-07-17

- Wine 11.12 was tagged on 2026-06-29 and 11.13 on 2026-07-10. The range
  from 11.11 through 11.13 contained 414 commits.
- `giang17/wine` provided `d2d1-dcomp-11.12` at `b6a83690`. Its parent was
  the Wine 11.12 tag, followed by one 50-file squash commit. No
  `d2d1-dcomp-11.13` branch existed.
- Wine merge request 10060, the source for portal patch 0031, remained an
  unmerged draft. comdlg32 had no changes in 11.12 or 11.13.
- Wine bug 57955 remained open, so patches 0002 and 0003 were still needed.
- Wine had accepted the d2d1 vertex-type leak fix from bug 59916. A local
  11.13 base port would need to omit the duplicate hunk.

## Expected conflicts

The review found no material upstream changes in dcomp, winealsa, comdlg32,
or ntdll mount handling. Patches 0001, 0016, 0021, 0028, 0031, 0032, and
0033 were expected to apply with little or no change.

Wine 11.13 changed the areas below:

1. win32u began creating GL and Vulkan client surfaces.
   `client_surface_update` and surface-rectangle calculation moved out of
   winex11. This affected patches 0015, 0026, and window-frame patches 0004
   through 0014.
2. The 23-commit OpenGL rewrite moved `wglShareLists` to PE code, introduced
   one shared Unix context, and removed thunks. Patch 0020 required a new
   implementation.
3. Monitor DPI became a ratio structure and moved into server shared memory.
   The shared-memory layout also changed. This affected patches 0018, 0019,
   0023, 0024, and 0029.
4. The raw-input rewrite removed the old motion and `ConfigureNotify`
   merging path, added XI2 motion frames, moved accumulation to win32u, and
   changed X11 scancode mapping. Patches 0002, 0003, 0017, and 0034 touched
   the same files.
5. dxgi and wined3d changed frame latency and full-screen swapchain checks.
   Patches 0022 through 0025 and 0030 needed review.

Patches 0008 through 0013 were experiments followed by their reverts. The
dated plan called for dropping all six if they conflicted, rather than
resolving changes with no final effect.

## Dated implementation plan

The proposed 11.12 step was:

1. Record a baseline with the tester kit and
   `scripts/check-live-audio.sh`.
2. Verify that `d2d1-dcomp-11.12` had the Wine 11.12 tag as its parent.
3. Vendor the base archive and checksum.
4. Apply the local series with the fixed-header wrapper and `git am --3way`
   logic in `scripts/container-build.sh`.
5. Regenerate `patches/SERIES.sha256` with
   `scripts/build-audit.sh --freeze`.
6. Build and test both a fresh prefix and a prefix upgraded from 11.11.

The proposed 11.13 step was to rework patches in this order:

1. Shared session memory, patches 0018 and 0019.
2. OpenGL sRGB support, patch 0020.
3. Client-surface handling, patches 0015 and 0026.
4. dxgi frame-latency changes, patches 0022 through 0025 and 0030.
5. DPI structures, patch 0029.
6. winex11 input and frame patches.

That order remains useful as historical conflict analysis, but the patch
numbers and upstream code are no longer current.

## Dated test gates

The plan required all build checks plus matching results from fresh and
upgraded prefixes. Relevant probe groups were:

- Window geometry: `resizeprobe`, `wmresize`, `hwndspy`, `menumeasure`,
  `menutest`, and `metricprobe`.
- DPI and shared memory: `dpispy` and `metricprobe`.
- DirectComposition, dxgi, and OpenGL: `dcompspy`, `glchild`,
  `pluginwindowprobe`, and `fakeplugin`.
- Devices and portal: `midihot`, `portalprobe`, and
  `scripts/check-live-audio.sh`.
- Stability: `swamprobe` and `stresstest`.

Manual coverage included Live window sizing, plugin editors, Learn View,
audio and MIDI reconnects, Push 2 hardware, portal dialogs, input, file
dragging under XWayland, and browsing across a Unix mount.

Wine 11.13 also required new checks for non-US keyboard layouts, long pointer
drags, full-screen swapchains, and X11 driver selection in Wayland sessions.
The planned environment matrix covered GNOME, KDE, plain X11, and Steam Deck
at 100%, fractional, and 200% scale.
