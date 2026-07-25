# Plugin input, menu, and shortcut fixes

Patches 0016 through 0020 fix four independent faults found in the same
sessions. Symptoms included unresponsive SWAM VST3 editors, menus that closed
immediately, inert shortcuts, `VST3: plug window creation failed`, and a
process abort when opening a nih-plug or baseview editor.

## DirectComposition lost the original window procedure

JUCE 8's Direct2D renderer can recreate a composition device and target on
the same window. Wine's second `CreateTargetForHwnd` call recorded its own
DirectComposition window procedure as the original procedure. Releasing a
target also cleared the shared `__wine_dcomp_target` property.

The window could then retain Wine's subclass without a target. Every message
went to `DefWindowProcW`, including mouse input and `WM_NCHITTEST`. Timer-based
Direct2D painting continued, which made the editor look functional while it
ignored input.

[Patch 0016](../patches/0016-dcomp-never-let-an-orphaned-target-subclass-swallow-.patch)
stores the true original procedure in its own window property. It never
chains the subclass to itself, forwards messages after the target disappears,
and removes only state owned by the released target.

## Mutter rejected activation requests with timestamp zero

winex11 sent `_NET_ACTIVE_WINDOW` requests with `data.l[1] = 0`. GNOME 50's
Mutter dropped those requests as part of focus-stealing prevention. Wine then
deduplicated later requests for the same window, so activation remained
pending. Menus, keyboard focus, and `WM_MOUSEACTIVATE` all depended on that
state.

[Patch 0017](../patches/0017-winex11-send-real-timestamps-in-_NET_ACTIVE_WINDOW-r.patch)
sends the last processed input timestamp. A later user input event supplies a
new timestamp and permits another activation request.

## Shared session mappings stopped receiving updates

Wine clients mapped the wineserver session memfd with `PAGE_READONLY`. ntdll
implemented that view with `MAP_PRIVATE` on Linux, so a client could stop
seeing later server writes. In a captured failure,
`find_shared_session_object` read object ID zero while the memfd contained a
window-class object.

Class registration then failed. Window creation reached `WM_NCCREATE` with a
null window procedure and raised an access violation. Live's vectored
exception handler spent about 2.4 seconds on each failure, which explained
the menu delay and `Vst3PlugWindow` creation failures.

[Patch 0019](../patches/0019-win32u-map-shared-session-views-MAP_SHARED-read-writ.patch)
requests `SECTION_MAP_READ|SECTION_MAP_WRITE` and `PAGE_READWRITE`, which
selects `MAP_SHARED`. It keeps a read-only fallback and never writes through
the view.

[Patch 0018](../patches/0018-server-pre-dirty-shared-session-mapping-pages-win32u.patch)
pre-dirties grown session blocks on the server and corrects a block-boundary
comparison. A 30,000-iteration register, create, and destroy test crossed
mapping growth boundaries without a failure. Boot-time session-object
mismatches fell from between 10 and 12 per boot to zero.

## The EGL backend omitted sRGB-capable formats

Wine 11.11's EGL backend set `framebuffer_srgb_capable = FALSE`. baseview
requests `srgb: true`, so `wglChoosePixelFormatARB` returned no formats. Its
Rust panic crossed a non-unwinding boundary and aborted Live.

[Patch 0020](../patches/0020-opengl-advertise-and-honor-sRGB-capable-pixel-format.patch)
advertises sRGB for 8-bit RGB formats when the display supports
`EGL_KHR_gl_colorspace`. It creates the X11 EGL surface with
`EGL_GL_COLORSPACE_SRGB_KHR` and retries with the default color space if the
driver rejects it.

[`tools/glchild.c`](../tools/glchild.c) reproduces baseview's pixel-format
request with and without the sRGB bit.

## Diagnostics

The relevant programs in [`tools/`](../tools/) are:

- `swamprobe.c` for window trees, DPI, hit testing, and focus.
- `liveinject.c` for Wine-internal mouse input. Its synthetic keyboard mode
  is not reliable enough for shortcut tests.
- `xrec.c`, `xmon.c`, and `xact.c` for X11 focus traces.
- `mousespy.c` with `spyhost.c` for identifying the subclassing module. Keep
  this DLL limited to the mouse hook; adding `WH_CALLWNDPROC` blocks Live's
  UI thread.
- `menutest.c` and `stresstest.c` for standalone reproductions.

Useful Wine debug channels are `+message` for repeated `DefWindowProc` calls,
`warn+winstation,err+class` for session-object failures, and `+seh` for the
handled access violations.

Each fix changes general Wine behavior and may be suitable for upstream
Wine. Patch 0019 also warrants review for other read-only shared-memory
users.
