# Main-window DPI layout loop

Status: fixed. On GNOME with an upscaled XWayland framebuffer, the launcher
sets Live's process DPI awareness before startup. This stops the layout loop
described here. Patch 0042 fixes a later, separate loop caused by
window-manager rounding; see
[ABLETON-WINE-DPI-SCALE-100.md](ABLETON-WINE-DPI-SCALE-100.md).

## Symptoms before the fix

At 192 DPI, Live repeatedly recalculated its outer rectangle from the client
area and `AdjustWindowRectExForDpi`, then called `NtUserSetWindowPos`.
Depending on the patch state, the window either:

- grew about two pixels per cycle beyond the monitor; or
- held its size but issued 175 to 400 no-op requests per second, used 80 to
  99% of one CPU core, and repainted a flashing white frame.

## Cause

Instrumented win32u traces showed a mixed process and thread DPI state:

1. Live left the process default DPI-unaware and selected per-monitor-v2
   awareness on individual threads.
2. Its embedded Chromium process window set Wine's one-shot process
   awareness latch to `UNAWARE` about half a second after startup.
3. Live created its main window while the main thread was temporarily
   per-monitor-v2, so the window retained 192 DPI.
4. Wine switched thread DPI context only during hardware-message dispatch.
   During later layout work, the main thread returned to the 96 DPI process
   default.
5. Live combined a 96-DPI client rectangle with a 192-DPI frame.
   `map_dpi_winpos` doubled each request and the readback halved it. The
   expected and actual client rectangles could not match.

One captured cycle was:

```text
NtUserSetWindowPos hwnd 0x100a6, -3,8 (2054x1275), flags 0x14
map_dpi_winpos: thread_dpi 96 -> window_dpi 192: (-6,16)-(4102,2566)
adjust_window_rect style 0x16cf0000 menu 1 dpi 192: (-5,-93)-(5,5)
calc_winpos: old == new (-6,16)-(4102,2566), client (-1,109)-(4097,2561)
```

Every call had identical old and new rectangles, so Wine sent no
`WM_WINDOWPOSCHANGED`. Live's own layout code issued the next call. Changing
or suppressing window messages could not stop this loop. The 37-pixel top
inset was Live's menu bar and was not the changing term.

## Fix

For an upscaled framebuffer, the launcher and `setup-prefix.sh` set this
value for each installed Live executable:

```text
HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<Ableton Live executable>
    dpiAwareness = REG_DWORD 2
```

Wine applies the Image File Execution Options value during process attach,
before Live or Chromium runs. The process, thread, and main window then use
the same per-monitor DPI. Chromium's later attempt to select unaware mode is
rejected, and Live completes layout after one request.

The value belongs only to GNOME configurations with an upscaled XWayland
framebuffer. At 100% scale it causes incorrect scaling. The launcher detects
the desktop scale before each start, adds or removes the value, and warns
when Mutter's `xwayland-native-scaling` setting disagrees.

## Verification

After the fix, main-window `NtUserSetWindowPos` calls stopped about 15
seconds after startup. The last 60 seconds of a 100-second trace contained no
calls. No Live thread exceeded 0.5% CPU, and the frame stopped flashing or
growing.

The following attempts did not fix the cause:

- Removing the `HIGHDPIAWARE` compatibility layer changed nothing.
- `LogPixels=96` stopped the loop but made the UI too small on a 2x
  framebuffer.
- The Wayland driver broke popup and menu placement in the tested build.
- [Patch 0007](../patches/0007-win32u-clamp-top-level-window-size-to-monitor-bug-57.patch)
  stopped growth but left 175 no-op requests per second.
- Re-enabling `_NET_FRAME_EXTENTS` in
  [patch 0008](../patches/0008-re-enable-frame-extents-round-trip-revert-patch-06-d.patch)
  left about 400 requests per second. Patch 0009 reverted it.
- Dark border colors hid the repaint but did not reduce CPU use.
