# Base bump: d2d1-dcomp-11.11 → d2d1-dcomp-11.13 (2026-07-21)

Full story of the Wine base version bump, moved here from `patches/BASE.txt`
so that file stays a lean per-patch provenance ledger matching upstream's own
format, rather than growing an ever-larger rebase-narrative header. `BASE.txt`
itself just points here.

## Rationale

11.11 was two point releases behind upstream's actively-maintained branch
(11.12 and 11.13 both already existed, unlike the 11.0/11.8/11.10 snapshots —
11.13 carries a real incremental commit history, last updated the same day as
this bump, including issues 78-84: ownerless WS_POPUP|WS_EX_TOOLWINDOW
z-order/window-type fixes, directly adjacent to this project's own 0037-0039
popup-management patches). Also closes the Wine point-version gap with ENCORE
(github.com/wowitsjack/ENCORE), which runs plain Wine 11.13.

## Rebase method

The 42-patch series (as it stood at 7ea0c8b7dd) was applied as real commits
on the original 7ea0c8b7dd checkout (all 41 patch files applied cleanly —
confirming the vendored tarball matches upstream exactly), then
`git rebase --onto 5c23dd1cf6 7ea0c8b7dd` replayed that commit stack onto the
new base. Real 3-way merges (using actual historical blobs, not blind patch
replay) hit 5 conflicts, all resolved and re-verified against the new base's
own code before resolving:

- `dlls/dxgi/swapchain.c` (old 0001): upstream's own `GetFullscreenDesc`
  rewrite (caches a `fullscreen_desc` struct, populated with a correct
  rational refresh rate elsewhere) already supersedes old 0001's fix for this
  function — confirmed by checking the sibling
  `d3d12_swapchain_GetFullscreenDesc`, which already does exactly what 0001
  wanted. Kept upstream's version, dropped 0001's hunk here.
- `dlls/win32u/window.c`, two spots (old 0002, 0003): upstream refactored DPI
  handling to a `struct ratio` type (`round_dpi()`) and the internal
  `adjust_window_rect()` instead of the public `NtUserAdjustWindowRect()`
  wrapper — unrelated to these patches' actual fix (the window==client
  decoration-mask gate, then patch 0003's `pGetFrameExtents` wrapping). Kept
  both: upstream's DPI call convention + this project's gate logic and
  wrapping structure, combined.
- `dlls/win32u/ntuser_private.h` (old 0004): both sides purely added
  different struct fields at the same point. Kept both.
- `dlls/winex11.drv/opengl.c` (old 0020): a local variable rename upstream
  (`window` -> `surface->window` in `x11drv_egl_surface_create`).
  Substituted through 0020's sRGB-colorspace surface-creation hunk;
  confirmed `has_EGL_KHR_gl_colorspace` and the rest of 0020's own struct
  additions applied cleanly elsewhere in the same commit.

Patches 0021-0042 (dcomp reblit/stale-buffer fixes, the Push2 USB bridge, the
XDG file portal, the config-rounding patch) all applied with zero textual
conflicts despite touching `dxgi/factory.c`, `dcomp/device.c` and similar
files upstream also touched — the overlap turned out to be smaller than the
line-count churn suggested.

## Three silent build breaks the clean rebase didn't catch

A reminder that a clean `git rebase` is necessary but not sufficient — the
container build is still the real gate. All three of these compiled against
the wrong thing rather than conflicting textually, so the rebase itself
looked entirely clean.

**1. Frame-latency-as-semaphore refactor (`struct d3d11_swapchain`).**
`struct d3d11_swapchain` no longer carries its own `frame_latency_event`
HANDLE upstream (frame-latency signalling moved into wined3d, exposed only
via `wined3d_swapchain_get_frame_latency_waitable_object()`, which
duplicates a semaphore handle per call rather than exposing a plain event).
The old field reference in the dcomp reblit-timer's idle-tick signal (from
the original sashaduke redraw patchset, carried through 0025/0041's
stale-buffer and null-device hardening) compiled against nothing rather than
conflicting textually. Fixed as a new patch — 0043 — rather than folding
into the historical patches it touches: fetches the waitable object,
releases it as a semaphore, and closes the duplicated handle each tick (the
old code held no handle to leak; the new API duplicates one per call, so
closing it is now this project's responsibility).

**2. Fractional-DPI `struct ratio` refactor (same upstream change, different
file).** A second, same-shaped break surfaced on the next build attempt:
0029 (carried through 0040's revised band law) computes the menu-bar band
overshoot via `muldiv( 4, get_dpi_for_window( owner ), 96 )`, and
`get_dpi_for_window()` also now returns `struct ratio` upstream (was a plain
`UINT`) — the same fractional-DPI refactor that the `win32u/window.c` rebase
conflict above was actually about, just showing up in a different file
(`dlls/win32u/menu.c`) that the rebase never touched, so it compiled against
the wrong type instead of conflicting. Fixed as patch 0044: wrap with
`round_dpi()`, matching the convention the refactor established everywhere
else. Grepped the full diff against upstream afterward for every other
`get_dpi_for_window`/`get_win_monitor_dpi`/`get_thread_dpi` call this patch
stack adds, and for any raw int/UINT/DWORD variable assigned directly from
one — no further instances found. Two for two on "clean rebase, broken
build" so far being the exact same upstream refactor recurring in untouched
files.

**3. libusb-1.0 detection macro change (`AC_CHECK_LIB` → `AC_CHECK_FUNC`).**
That prediction was wrong for the third: 0032's Push2 bridge is gated on
`configure.ac` detecting host libusb-1.0 (only built if present), checked
via `$ac_cv_lib_usb_1_0_libusb_interrupt_event_handler` — a cache variable
only `AC_CHECK_LIB` sets. Upstream switched this exact detection from
`AC_CHECK_LIB` to `AC_CHECK_FUNC` between 11.11 and 11.13 (now sets
`ac_cv_func_libusb_interrupt_event_handler` instead), and 0032's added line
sat right after the block with no textual overlap — carried through
unconflicted, silently checking a variable configure never sets under the
new macro, always true, so `enable_libusb_1_0` was unconditionally forced to
`no` and the bridge DLL never got built. This one wasn't caught by the
rebase *or* by two build attempts: `container-build.sh`'s own post-build
sanity checks (which exist precisely to catch this) were bare `test`
commands with no error message, so `set -e` aborted silently right after the
Wine version print with no indication of which check failed or why —
indistinguishable in the log from truncated output. Fixed both: patch 0045
corrects the cache-variable name (also grepped the whole patch series for
any other `ac_cv_lib_`/`ac_cv_func_` reference — only this one existed), and
`container-build.sh`'s existence/non-existence checks around the Push2
bridge and comdlg32 portal now print what they checked and what they
expected before exiting.

**Correction to 0045** (same day, one build attempt later): the first cut
only fixed `configure.ac`, which is a no-op at build time —
`container-build.sh` runs the pre-generated `./configure` script directly
and never regenerates it (no `autoreconf`/`autoconf` step anywhere in this
build), so the actual cache-variable reference the build sees lives in the
committed `configure` shell script, a separate generated artifact 0032
already patches directly (a real Wine module addition always touches both —
see 0032's own `configure`/`configure.ac` hunks). Fixed that copy too; 0045
now carries both hunks, same as 0032's shape.

(Patches 0043-0045 from this bump were later renumbered to 0046-0048 when
this branch merged `upstream/main`'s own new 0043 and 0045 — see the git
history and `patches/BASE.txt`'s 0046-0048 entries for the current mapping.)

## Tooling gotcha

Two build attempts in the middle of this bump were run through
`./build.sh | tee logfile` without `pipefail` in the invoking shell, so a
real failure inside `build.sh` reported the *pipeline's* exit status
(`tee`'s, 0) instead of the actual failure — two apparently "successful"
builds were actually silent failures, indistinguishable from success until
rerun with `set -o pipefail` (or plain `>`) exposed the real exit code.
Worth remembering for anyone scripting around this build: `build.sh`'s own
exit code is only trustworthy if nothing downstream of it in a pipe
swallows it.

## Patch numbering

Unchanged from the 7ea0c8b7dd series otherwise: 0027 stays reserved (its
patch file was removed 2026-07-14, the gap is not closed by this bump).
Patches 0043-0045 (at the time of this bump) were new, added directly
against the 11.13 base with no old-numbering equivalent — see the note above
on their later renumbering to 0046-0048.
