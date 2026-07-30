# Text rendering blur findings, 2026-07-21 (GHOSTING FIXED 2026-07-22; unified-top-bar live theming FIXED 2026-07-22; non-Latin font fallback FIXED 2026-07-22 — contrast polish and switch latency remain open)

## Fixed: the disabled/grayed native-menu text ghosting

**Confirmed fixed by direct visual test, 2026-07-22.** The symptom that
started this whole investigation — soft/"blurred" text specifically on
grayed/disabled items in Wine's native menu bar (`Options` dropdown:
"Solo Switches", "Cue Switches", etc., right next to perfectly crisp
enabled items like "Solo in Place") — was never blur or a font-rendering
bug at all. It was a genuine double-image: `dlls/win32u/menu.c`'s
`draw_menu_item` draws disabled menu text **twice** for an old-Windows
"engraved" bevel effect — once in white, offset +1px right and down,
then again in gray at the original position:

```c
if (item->fState & MF_GRAYED)
{
    if (!(item->fState & MF_HILITE))
    {
        ++rect.left; ++rect.top; ++rect.right; ++rect.bottom;
        NtGdiGetAndSetDCDword( hdc, NtGdiSetTextColor, RGB(0xff, 0xff, 0xff), NULL );
        DrawTextW( hdc, item->text, i, &rect, format );
        --rect.left; --rect.top; --rect.right; --rect.bottom;
    }
    NtGdiGetAndSetDCDword( hdc, NtGdiSetTextColor, RGB(0x80, 0x80, 0x80), NULL );
}
DrawTextW( hdc, item->text, i, &rect, format );
```

This code is 100% stock, unmodified Wine — confirmed via `git show` on
the fork's own squash commit for zero diff in this file. The bevel
technique itself is fine on a stock light Windows theme (subtle,
barely visible). It breaks down once the app themes its native menu
(here: `COLOR_MENU`/`MenuText`/`GrayText` set to non-default values,
almost certainly via Ableton calling `SetSysColors` at startup, since
neither this project's scripts nor Wine's own source touch these
registry values) — because the white highlight pass is hardcoded and
never gets themed along with everything else, so it renders as a
glaring, misaligned white ghost offset from the real text instead of a
subtle bevel.

**First attempt (failed, kept as a documented dead end):** routed both
hardcoded colors through `get_sys_color(COLOR_3DHILIGHT)` /
`get_sys_color(COLOR_GRAYTEXT)` instead of the literals, keeping the
two-pass bevel. Built, tested, **zero visible change** — because
`COLOR_3DHILIGHT` is never set in this prefix at all (no registry
value), so it silently falls back to Wine's compiled-in default, which
is white anyway. The one color that *did* change
(`COLOR_GRAYTEXT` = 106,106,106 vs. the old hardcoded 128,128,128) was
too subtle a shift to matter — the actually-glaring part of the bug
(the white ghost) never changed.

**Second attempt (fix, confirmed working):** dropped the two-pass
bevel entirely for the non-`MF_HILITE` grayed case, always drawing
once in `get_sys_color(COLOR_GRAYTEXT)` — matching what the
`MF_HILITE`-grayed case (mouse hovering a disabled item) already did
successfully a few lines below, which never had a bevel at all. Built,
extracted to an isolated test directory (never touched the canonical
install), launched, opened the `Options` menu, and the user confirmed
directly: **"the ghosting really does look resolved."**

Patch: `patches/0047-win32u-drop-the-grayed-menu-item-engraved-bevel-ent.patch`
on branch `wine-11.13-upgrade`.

## Follow-up, now fixed: low contrast on disabled menu text, and making the "unified top bar" actually follow Ableton's theme live

Immediately after the ghosting fix, disabled menu text was
legible-but-dim ("dark grey, kind of hard to read") rather than
ghosted. Measured directly (pixel sample from a saved screenshot, not
just the registry): actual rendered menu background was
`RGB(129,129,129)`; enabled `MenuText` was `RGB(18,18,18)` (contrast
111, reads fine); disabled `GrayText` was `RGB(106,106,106)` (contrast
with the background of only **23** — barely distinguishable). This
kicked off a much bigger investigation than expected: not just "pick a
better gray," but "why doesn't the launcher's existing live
theme-following system (`ABLETON_TOPBAR_MODE=live`, issue 32) manage
`GrayText` at all, and — once we tried to fix that — why does *none* of
it update live while Ableton is already running?" Two real, independent
bugs were found and fixed. Both are documented in full below.

### What "unified top bar" means here, precisely

Before anything else: the user's question was specifically about the
win32-drawn **menu bar** (File/Edit/Create/.../Options/Help and its
dropdowns) — not the OS window decoration. Worth stating precisely,
because it's easy to conflate the two:

- `ActiveTitle`/`TitleText`/`GradientActiveTitle` in
  `[Control Panel\Colors]` only ever paint **Wine's own drawn window
  caption**, which Wine only draws when running inside a Wine virtual
  desktop (`ABLETON_VDESK`, `scripts/ableton-live:700-702`). That's
  opt-in and off by default; without it, each Wine window is a plain
  top-level window handed straight to the host compositor (COSMIC),
  which draws its own decoration using its own theme. Nothing in this
  system can reach that — there's no API for an external process to
  recolor a Wayland/X11 compositor's own window-frame chrome, and nothing
  in this codebase attempts to.
- What *is* real, Wine-drawn, and actually controllable is the **menu
  bar** — rendered by `dlls/win32u/menu.c`'s `draw_menu_item`, the same
  function patch 0047 already fixed. This is the thing that's actually
  being discussed below.

### Bug #1: `win32u`'s per-process sys-color cache never invalidates on `WM_SYSCOLORCHANGE`

This is the reason a live external `SetSysColors` call (from the
launcher's `setsyscolors.exe` helper, run by `theme_watch_loop` while
Ableton is already running) had **zero visible effect**, no matter how
different the new colors were, even though every step up to the actual
paint provably fired correctly.

**How it was found.** `WINEDEBUG=+message` tracing (the same technique
used earlier in this doc to disprove owner-drawing) showed the full,
correct chain: `WM_SYSCOLORCHANGE` reaching the main window and falling
through `DefWindowProc` cleanly, and — after adding an explicit
`DrawMenuBar()` call to `setsyscolors.exe` — a complete, correctly
computed `WM_NCCALCSIZE` → `WM_NCPAINT` → `WM_ERASEBKGND` →
`WM_WINDOWPOSCHANGED` → `WM_PAINT` repaint cycle firing on the right
window. And still nothing changed on screen, with test colors
(`MenuBar=10,10,10 MenuText=250,250,250`) about as different from the
existing `207,207,207`/`18,18,18` as two color sets can be — ruling out
"not different enough" as an explanation.

Reading `dlls/win32u/sysparams.c` found the real mechanism: each
process caches every system color the first time it reads one:

```c
static BOOL get_rgb_entry( union sysparam_all_entry *entry, UINT int_param, void *ptr_param, UINT dpi )
{
    if (!ptr_param) return FALSE;
    if (!entry->hdr.loaded)
    {
        /* ... only reads from the registry/volatile key HERE ... */
    }
done:
    *(COLORREF *)ptr_param = entry->rgb.val;   /* otherwise: always the cached value */
    return TRUE;
}
```

`entry->hdr.loaded` is set `TRUE` the first time a process reads *or*
writes that color, and **nothing in the entire file ever resets it back
to `FALSE`** (confirmed by grep — the only two existing `.loaded = FALSE`
resets are for wallpaper mirroring, unrelated). `WM_SYSCOLORCHANGE` is
purely a notification broadcast; nothing in `win32u`'s message handling
responds to it by invalidating this cache. So: Ableton reads
`COLOR_MENUBAR` etc. once at startup and caches it forever, in its own
process memory. `SetSysColors` from another process (the launcher's
tool) updates a registry-backed "volatile key" and its own local cache,
then broadcasts the notification — but there is no channel that tells
Ableton's already-running process to go re-read that key. The forced
repaint we traced is completely real; it's just repainting with the
same stale in-memory value, forever, regardless of how different the
new value is. (Side note: `wine reg query 'HKCU\Control Panel\Colors'`
is *not* a valid way to check this — it only reads the persistent base
key, never the volatile key `SetSysColors` actually writes to, so it
will "look stale" either way. This cost real time before being caught.)

**The fix** (`patches/0048-win32u-invalidate-the-per-process-sys-color-cache-o.patch`,
on top of 0047, same scratch clone of the `giang17/wine` fork):
`dlls/win32u/message.c`'s `call_window_proc` — the single, common
delivery point for every message reaching a window procedure regardless
of same-thread/cross-thread/cross-process origin (confirmed: both call
sites in the file funnel through it, including the receiving-process
handler for sent messages) — now resets every `system_colors[]` entry's
`loaded` flag right before `WM_SYSCOLORCHANGE` is dispatched, in the
*receiving* process, so the repaint that follows re-fetches current
values instead of the cache:

```c
if (msg == WM_SYSCOLORCHANGE) reset_sys_color_cache();
```

**First version of this fix (loaded flag only) still showed zero
change** after a real rebuild and a real live test — the raw value
wasn't the only thing cached. `get_sys_color_brush()`/`get_sys_color_pen()`
create an `HBRUSH`/`HPEN` wrapping whatever `get_sys_color()` returned
*at creation time*, cached separately in `system_colors[].brush`/`.pen`,
and returned as-is with **no re-check of the raw value ever** once
created. The menu bar's background paints through this brush, so it
stayed stuck on the old color even with the raw value already fixed —
the exact same bug, one level up. `set_rgb_entry` already frees these
correctly for the *calling* process's own `SetSysColors`; the fix mirrors
that for the receiving process:

```c
void reset_sys_color_cache(void)
{
    unsigned int i;
    HBRUSH brush;
    HPEN pen;
    for (i = 0; i < ARRAY_SIZE( system_colors ); i++)
    {
        system_colors[i].hdr.loaded = FALSE;
        if ((brush = InterlockedExchangePointer( (void **)&system_colors[i].brush, 0 )))
        { make_gdi_object_system( brush, FALSE ); NtGdiDeleteObjectApp( brush ); }
        if ((pen = InterlockedExchangePointer( (void **)&system_colors[i].pen, 0 )))
        { make_gdi_object_system( pen, FALSE ); NtGdiDeleteObjectApp( pen ); }
    }
}
```

**Confirmed working, 2026-07-22**, by direct visual test: running the
launcher's `setsyscolors.exe` manually against a live, already-running
Ableton instance changed the menu bar's color immediately. User: *"holy
shit. the bar changed colour."*

Diagnosing this also produced two dead ends worth recording so they
aren't re-tried: (a) attaching a real debugger (`gdb`, then `winedbg
--gdb`) to inspect this live never worked in this environment — plain
`gdb` can't resolve symbols in Wine's PE-native process model (`Selected
architecture i386:x86-64 is not compatible with reported target
architecture i386:x64-32`), `sudo winedbg` refuses a prefix it doesn't
own ("not owned by you"), and plain `winedbg` failed to attach even
after relaxing Yama's `ptrace_scope` to 0 (`Can't attach process ...:
error 87`), for a reason never fully root-caused — abandoned in favor of
`WINEDEBUG=+message` tracing, which is what actually solved this. (b) a
full container rebuild (~20 minutes) is not required to test a
single-DLL change: unpacking the base, applying the full patch series,
running `configure`, then a *targeted* `(cd dlls/win32u && make)` and
copying out just `dlls/win32u/win32u.so` (not `.../x86_64-unix/win32u.so`
— that path doesn't exist for this dll) takes well under a minute, and
can be
hot-swapped directly into an installed runtime's
`lib/wine/x86_64-unix/win32u.so` for a fast diagnostic loop. (Not a
substitute for the real tarball/`install.sh` install before calling
anything actually fixed — this was for iteration speed only, and left
temporary `ERR()` debug prints in the swapped copy that were never
built into the real, shipped patch.)

### Bug #2: theme detection was reading a 5-day-old dead preferences file

Even with bug #1 fixed, switching the theme from *inside* Ableton's own
Preferences still didn't update the bar. This is a completely separate,
unrelated bug in this project's own scripts, not Wine.

Both `theme_watch_prefs_cfg()` (`scripts/ableton-live`) and
`ableton_live_theme_file()` (`scripts/detect-theme.sh`) pick "the
current" Ableton preferences directory with `ls ... | sort -V | tail -n
1` — version-sorting the glob of `Live 12.3.6`, `Live 12.3.7`, ...,
`Live 12.4`, `Live 12.4.1`, `Live 12.4.2`, `Live 12.4.3` directories.
In isolation, `sort -V` orders these correctly (`12.4` before `12.4.1`
etc). With the *full path* prepended, it doesn't:

```text
$ printf '%s\n' \
  ".../Live 12.4.1/Preferences/" ".../Live 12.4.2/Preferences/" \
  ".../Live 12.4.3/Preferences/" ".../Live 12.4/Preferences/" | sort -V
.../Live 12.4.1/Preferences/
.../Live 12.4.2/Preferences/
.../Live 12.4.3/Preferences/
.../Live 12.4/Preferences/        <- sorts LAST, wrongly "newest"
```

Root cause: `"Live 12.4"` and `"Live 12.4.3"` diverge right after
`"12.4"` — one continues with `/` (`0x2F`), the other starts a new
version segment with `.` (`0x2E`). `strverscmp`-style comparison falls
back to a plain byte compare at that divergence point, and `/ > .`
numerically, so `"12.4/..."` sorts *after* `"12.4.3/..."`. `tail -n 1`
then picks the bare `"Live 12.4"` directory — a leftover from an older
Ableton point release, last written 2026-07-17, five days stale — every
single time, regardless of what the currently-running `12.4.3` actually
has selected. Confirmed directly: `ableton_live_theme_file` was
resolving to `Default Light Neutral Medium.ask` even freshly after the
theme was switched to `Default Dark Neutral High` (confirmed present as
the only real match via `strings -e l Preferences.cfg`).

**The fix**: replace the directory-name version-sort in both places
with a scan for the actual newest `Preferences.cfg` **by file mtime**
— both simpler and semantically correct (whichever file was genuinely
written to most recently is the one Live actually renders with),
and immune to this class of bug entirely:

```bash
for f in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/"Live ${major:-}"*/Preferences/Preferences.cfg; do
    [ -f "$f" ] || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    if [ "$t" -gt "$newest_t" ]; then newest_t="$t"; newest="$f"; fi
done
```

Confirmed correct in isolation (no rebuild needed, pure bash) before
wiring in: resolves to `Live 12.4.3/Preferences/Preferences.cfg` and
`Default Dark Neutral High.ask` correctly.

### Also added: `GrayText` derivation, and a diff-guard against re-broadcast storms

While investigating, two smaller things were added to
`scripts/ableton-live`'s `sync_win32_colors()` / `theme_watch_loop()`:

- **`GrayText` is now derived**, not left unmanaged (the original
  low-contrast bug's actual fix): a 45%-toward-`MenuText` blend of
  whatever `Menu`/`MenuText` resolve to, computed generically so it
  tracks any theme and both light/dark fallbacks with no extra parsing.
  Considered and **rejected** using Ableton's own theme file
  `TextDisabled` key directly — checked the active theme
  (`Default Light Neutral Medium`: `Desktop=#818181`=129,
  `TextDisabled=#6e6e6e`=110) and the literal value would have made
  contrast *worse* than Wine's own compiled-in default (106), not
  better: that token is calibrated for Ableton's own layered Skia
  surfaces (borders, icons, spacing), not a flat `win32u` menu fill.
  `setsyscolors.exe`'s hardcoded color-name whitelist
  (`tools/setsyscolors.c`) had to gain a `GrayText` entry too — it
  silently rejects the *entire* call ("unknown name: refuse the lot")
  if any single name isn't recognized, which would have broken the
  live re-apply of every other color, not just skipped this one.
- **`theme_watch_loop` now tracks the last color set it actually
  broadcast** and skips re-firing `setsyscolors.exe` when a
  `Preferences.cfg` touch resolves to the same colors as before. The
  poll only checks the file's mtime, not its content, and that file
  gets touched for plenty of reasons beyond a theme pick (window
  layout, focus state, ...) — every prior touch triggered a full
  `SetSysColors` + `WM_SYSCOLORCHANGE` broadcast unconditionally, real
  change or not. Purely a risk-reduction change (fewer broadcasts,
  never a different result when a real change happens) — added after a
  real app freeze during testing that looked timing/storm-related, but
  never conclusively proven to be the freeze's cause (see below).

### The freeze scare, in the end unrelated to any of the above

Mid-session, Ableton hard-froze (one thread pegged at real CPU,
`wchan=0`, every other thread legitimately idle) right after a real
in-app theme switch. Investigated seriously (thread/wchan dump,
`WINEDEBUG` tracing, the `gdb`/`winedbg` dead end above) before
concluding it likely wasn't caused by any of this work at all: the
*next* clean test, after simply reinstalling and relaunching, ran the
same live-recolor path repeatedly without incident. Likely just a bad
interaction from rapid focus-cycling ("tabbing in and out a bunch")
during testing, per the user's own account. Not chased further once it
didn't reproduce; worth remembering as a "if it happens again,
`WINEDEBUG=+message` + thread wchan dump" starting point, not a "known
Wine bug" to work around.

**Bigger, real environment-hygiene finding from that detour**: found
**120 orphaned Wine helper processes** (`services.exe`, `svchost.exe`,
`explorer.exe /desktop`, `rpcss.exe`, `winedevice.exe`, `conhost.exe`,
`MicrosoftEdgeUpdate.exe`, ...) accumulated silently across the entire
session, going back to its very first launch — every prior cleanup only
ever targeted `Ableton Live.*\.exe` and the main `wineserver` process by
name, never Wine's own internal subsystem processes, which don't die
with their parent `wineserver` on an abrupt kill. These don't
self-heal; each one is harmless alone but they accumulate forever and
directly block `scripts/install.sh`'s "still running" safety check
(which correctly refuses to overwrite a runtime out from under a live
process). Detection: same `os.readlink('/proc/<pid>/exe')` scan used
throughout this doc, not `pgrep` by name. Full, reliable cleanup: plain
`SIGTERM` to every PID whose `exe` symlink resolves under the target
`~/.local/opt/wine-d2d1-nspa-*` tree (any rollback suffix included) —
all 120 died cleanly with no `-9` needed.

**Confirmed working end-to-end, 2026-07-22.** User: *"sweet jesus. it
seems to work. the theme switches a little slowly but god damn. it does
work."* Both bugs needed fixing together — bug #1 alone means an in-app
switch is detected and resolved correctly but never visibly applied;
bug #2 alone means the (correctly-working) live-apply mechanism never
gets triggered by a real switch at all, because it's watching the wrong
file.

**Update, 2026-07-22: bar/dropdown color-source swap, confirmed working.**
First real contrast complaint in light mode: the always-visible bar and
its dropdowns had the relationship backwards — bar lighter than its own
dropdowns (`ControlBackground` 207,207,207 driving the bar vs `Desktop`
129,129,129 driving dropdowns, for `Default Light Neutral Medium`),
visually wrong compared to any reference (a darker chrome strip framing
lighter popup/content surfaces). Fixed by swapping which theme key feeds
which element in `resolve_live_topbar()` (`scripts/ableton-live`): bar
now takes `Desktop`, dropdowns take `ControlBackground` — the reverse of
the original assignment. Shared `MenuText` (win32 has only one menu text
color for both contexts) stays high-contrast against both either way.
**Confirmed correct by direct visual test.**

**Side investigation, 2026-07-22: elevated CPU, confirmed unrelated to
any of this.** User noticed Ableton's CPU running higher than normal
during testing. Checked properly rather than dismissed: `ps`'s
cumulative CPU-time delta (not raw `/proc/*/stat` tick math, which
produced confusing/wrong-looking numbers on the first attempt — see
below) showed a real, sustained 150-200% (1.5-2 full cores) with no
playback running. Two clean, independent tests ruled out this
session's work as the cause: stopping `theme_watch_loop` entirely
didn't move the number at all, and thread-state inspection (`AudioCalc`
threads mostly asleep on `anon_pipe_read`, not spinning) was consistent
with normal audio-engine buffer-callback activity, not a bug. Confirmed
conclusively by toggling **Audio Engine Off** in Ableton itself
(Options menu, `Ctrl+Shift+Alt+E`): CPU time went completely flat
(zero growth across three 2-second samples). So: real, and fully
explained by the audio engine running continuously (monitoring/metering)
independent of transport playback — not this project's code. (Minor
methodology note for later: `/proc/<pid>/stat` fields 14+15 read
naively with an assumed 100 ticks/sec produced an apparently-impossible
>100%-of-one-thread reading at one point; `ps -o time=` cumulative-time
deltas across fixed sampling windows is the more reliable technique and
is what actually resolved this.)

**Still open:**

- **Presentation latency requiring interaction — tried two fixes, both
  reverted, root cause not found.** Even once a real `SetSysColors` +
  `WM_SYSCOLORCHANGE` + `DrawMenuBar` cycle is confirmed reaching the
  right window (see bug #1 above), the actual on-screen pixels can sit
  unpresented for anywhere from well under a second to several seconds
  — and in the live, in-app-triggered path, **reliably need some
  unrelated interaction** (hovering the bar, clicking an object in
  Live) to actually appear; measured with zero interaction at all, it
  eventually updates on its own after a variable delay, so this isn't
  a hard requirement, just a very unreliable one. Two things were tried
  on top of the already-necessary `DrawMenuBar` call in
  `tools/setsyscolors.c`'s `redraw_menu_bar()`:
  - `RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE|RDW_FRAME|RDW_ERASE|RDW_UPDATENOW|RDW_ALLCHILDREN)`
    — forces a synchronous repaint instead of DrawMenuBar's own deferred
    invalidate. Looked promising in isolated manual tests (three
    back-to-back trials all updated near-instantly with this in place)
    but **did not fix the real theme_watch_loop-driven path** — user
    confirmed interaction was still required after a real in-app theme
    switch with this build installed.
  - `SendInput` synthesizing a net-zero-movement mouse nudge (genuine
    OS-level input, not a message posted to one window), on the theory
    that Live's own Skia compositor gates its next frame presentation on
    detecting real input activity, same as a genuine mouse move/click
    was observed to do. Also did not fix the real path.
  
  Both reverted (2026-07-22) rather than keep code that measurably
  didn't solve the actual problem — `tools/setsyscolors.c` is back to
  just `SetSysColors` + `EnumWindows`/`DrawMenuBar`. The isolated-test
  results (both fixes *looked* like they worked, repeatedly, in direct
  manual testing) versus the real path never actually improving is
  itself a real clue worth remembering: something about `theme_watch_loop`'s
  own invocation context (a fully detached background process,
  `( theme_watch_loop ) </dev/null >/dev/null 2>&1 &`, no controlling
  terminal) may behave differently from an interactive foreground shell
  calling the exact same `wine setsyscolors.exe ...` command — that
  distinction was raised but never actually isolated/tested before the
  session moved on to a CPU concern (see below) and then this revert.
  **Next step, if picked up again: test setsyscolors.exe invoked from a
  matching detached/background context (not an interactive terminal)
  in isolation, to check whether SendInput's effect (or lack of it)
  actually depends on that, before trying anything else.**
- `theme_watch_loop` also polls `Preferences.cfg`'s mtime every 2
  seconds (`scripts/ableton-live`); whatever fixes the above, this adds
  its own separate, smaller latency on top — lowering the sleep interval
  is the straightforward lever if faster response is wanted there, at
  the cost of more frequent wakeups while Live is running. Confirmed
  NOT the cause of the elevated CPU investigated the same session (see
  below) — stopping the watcher entirely did not reduce Ableton's CPU
  at all.
- **Contrast/prettiness polish** — the mechanism now works and is
  theme-correct (including the bar/dropdown swap above), but the
  45%-blend `GrayText` (and the rest of the derived palette) hasn't had
  a design pass; explicitly requested as a next step.
- Whether the low-contrast pairing (before this fix) was fork-specific
  or also reproduces on stock Wine/ENCORE was never actually checked —
  moot now that it's fixed here, but the underlying win32u cache bug
  (#1) almost certainly is **not** fork-specific (confirmed zero diff
  against stock Wine in this exact file, same as 0047's finding for
  `menu.c`) and would be worth an upstream report.
- `patches/BASE.txt` provenance entries for 0047 and 0048 are already
  written; nothing outstanding there.

**Update, 2026-07-22, retracted:** an earlier version of this section
claimed the root cause was found in `dlls/d2d1/device.c`'s
`d2d_device_context_draw_glyph_run` (a forced
`ALIASED`/`OUTLINE` → `NATURAL` rendering-mode substitution in the
`giang17/wine` fork). That code is real and the substitution does
happen, but a live trace proved it is **not reachable from Ableton at
all** — see "Why the D2D1 lead was wrong" below. Kept in this doc as a
dead end so it isn't re-investigated; the actual next lead is in
"Real rendering stack, confirmed" further down.

**Why the D2D1 lead was wrong, confirmed by live trace (2026-07-22):**
launched Live with `WINEDEBUG=+dwrite,+d2d`, interacted with the UI
(opened the Options menu, browser panel visible) to force real
redraws, and checked both the trace and `/proc/<pid>/maps`:

- `d2d1.dll` is **not loaded in the process at all** (`grep -oE
  "[^ /]+d2d1\.dll" /proc/<pid>/maps` returns nothing) — the forced
  `NATURAL` substitution in `dlls/d2d1/device.c` cannot be involved in
  anything Live's main UI draws, since that module never runs.
- `dwrite.dll` **is** loaded, but every single `trace:dwrite:` hit
  across the entire session (font enumeration and real UI interaction
  alike) is a font-metadata call — `localizedstrings_*`,
  `dwritefontfile_*`, `dwritefontcollection_*`, `opentype_*` — building
  a font list. Zero calls to any glyph-rendering function
  (`CreateGlyphRunAnalysis`, `DrawGlyphRun`, `IDWriteBitmapRenderTarget`
  methods, etc.) ever appeared.

## Fixed, 2026-07-22: no fallback font for non-Latin languages (issue 35, item 5)

Ableton's own translated UI (confirmed live with Ableton set to Japanese)
rendered every menu bar label and dropdown item as solid tofu boxes —
raised separately from the color/theme work above, same investigation
session, same underlying substitution (`sync_font_substitutes` forcing
Ableton's own `Ableton Sans`/`Ableton Sans Small` face onto all win32
chrome, issue 32). Directly measured that font's actual glyph coverage
via its cmap table: Latin script only, zero glyphs anywhere in Cyrillic,
Arabic, Hebrew, Devanagari, Thai, CJK, or Hangul.

**First attempt (looked complete, measurably did nothing): register a
`SystemLink` fallback chain.** `HKLM\...\FontLink\SystemLink` is Wine's
real, general font-linking mechanism, and it's genuinely there for any
font name, not just the four Wine's own built-in default population
hard-codes ("Tahoma", "MS UI Gothic", "SimSun", "Gulim" — which stop
working the moment `MS Shell Dlg` is substituted to anything else, as
this project's own substitution does). Added `sync_font_fallback()` to
`scripts/ableton-live`, registering Tahoma (Wine's only bundled font
with real non-Latin coverage — checked, 104 Cyrillic + 162 Arabic
glyphs) plus whatever real CJK font the host has installed (via
`fc-match :lang=ja`, best-effort, silently skipped if none). Confirmed
via `WINEDEBUG=+font` trace that Wine correctly loaded this and resolved
real font files, including correctly picking the Japanese face out of a
5-face `.ttc` collection (`NotoSansCJK-Regular.ttc`'s JP/KR/SC/TC/HK
variants). **Made zero visible difference.** Removed per instruction
rather than leave dead config in place.

**Root cause, found by reading `dlls/win32u/freetype.c` and
`dlls/user32/text.c`:** `SystemLink` is only ever consulted by
`can_select_face` during whole-font *selection*, gated on the system's
ANSI codepage matching a *requested* charset — never during glyph
*rendering*. The actual glyph lookup, `freetype_get_glyph_index`, is a
direct FreeType charmap query against whichever single font is already
selected, with no font-link awareness of any kind; `DrawTextExW`
(`dlls/user32/text.c`, what `draw_menu_item` actually calls) has no
font-substitution logic either. A registered fallback chain sitting
unused doesn't help until something actually walks it per string being
drawn — which nothing did.

**The fix** (`patches/0050-win32u-fall-back-to-a-linked-font-for-missing-glyph.patch`,
on top of 0047-0049, same scratch clone): added that missing consumer.
`get_font_link_families()` (new, `dlls/win32u/font.c`) is a thin
accessor exposing what `find_gdi_font_link` already tracks internally
(otherwise unreachable outside that file). `get_fallback_font_for_text()`
(new, `dlls/win32u/menu.c`) checks whether the currently selected font
can render an item's text at all (`NtGdiGetGlyphIndicesW` with
`GGI_MARK_NONEXISTING_GLYPHS` — confirmed by reading
`font_GetGlyphIndices` that this, too, only ever checks the one selected
font, exactly the primitive wanted here) and, if not, walks that font's
registered `SystemLink` families trying each in turn for one that
actually covers the text, temporarily selecting it (matching size/weight,
via `NtGdiExtGetObjectW` + `NtGdiHfontCreate`, the same idiom this file
already uses for its Marlett-bitmap-glyph drawing) for that item's
`DrawTextW` calls, then restoring and deleting it.

Whole-string swap, not per-character: text mixing scripts renders
entirely in the fallback font rather than mixing faces mid-string. Real
per-glyph fallback is a Uniscribe/DirectWrite-level feature that plain
`DrawTextW` has never had; implementing that properly is a much larger
undertaking — this trades a rarer, minor font-consistency slip for the
text actually rendering at all.

**Two further bugs found and fixed by tracing real Japanese menu text
through this code end-to-end** (`WINEDEBUG=+message` plus temporary
`ERR()` instrumentation — the same technique used throughout this doc;
each looked like a dead end in isolation until traced):

1. `NtGdiExtGetObjectW` returns the *resolved face's* full name (e.g.
   `"Ableton Sans Small Regular"`), not the family name the `SystemLink`
   chain is registered under (`"Ableton Sans Small"`) — confirmed via
   trace showing `found 0 linked families` every time despite the chain
   being correctly registered. Fixed by stripping the known style suffix
   (`" Regular"`, `" Bold"`, `" Italic"`, `" Bold Italic"`,
   `" Regular Italic"`) and retrying. Hit a second bug fixing this one:
   used plain `L"..."` string literals for the suffix table, which
   silently produced garbage comparisons (`comparing tail L"r" against
   suffix L" "` in the trace) — this file is compiled against the host's
   `wchar_t` (32-bit on Linux) for the unix `.so`, not Wine's own `WCHAR`
   (always 16-bit); spelled out as `{'a','b','c',0}` char arrays instead,
   matching `tahoma_ttfW`/`ms_shell_dlgW` elsewhere in `font.c`.
2. `item->text` includes its raw `'\t'`-separated shortcut column (see
   `draw_menu_item`'s own tab-handling just below); no font has an
   actual renderable glyph for a literal tab — it's a layout separator,
   never meant to be drawn as a character. Confirmed by trace: every
   failing lookup was for a string containing a keyboard shortcut
   (`"MIDIマップアサインモード\tCtrl+M"` and its siblings), and every
   *successful* one was shortcut-free — the tab was being flagged as a
   "missing" glyph in every candidate font tried, Tahoma and the CJK
   fallback alike, failing otherwise-fully-covered strings. Control
   characters (`< ' '`) are no longer treated as glyphs needing coverage.

**Confirmed working end-to-end** on the real, clean (non-debug) shipped
build: with Ableton's own UI language set to Japanese, every menu bar
label, every dropdown item, and every tab-separated keyboard shortcut
(`Ctrl+M`, `Ctrl+1`–`Ctrl+5`, `Ctrl+Shift+B`, `Ctrl+Shift+Alt+E`,
`Ctrl+,`) renders correctly — zero tofu remaining anywhere in the menu.
(Ableton's own browser panel, left-hand library tree, etc. were already
correctly localized throughout this whole investigation — that's
Ableton's own Skia/HarfBuzz-rendered UI, a completely separate stack
from the win32 chrome this patch touches, and never had this bug.)

**Process note, since it cost real time twice this session:** the "fast
targeted `win32u`-only build" technique (unpack base, apply patches,
`configure`, `(cd dlls/win32u && make)`) reads patches from
`ableton-linux/patches/`, **not** the scratch clone's working tree.
Edits made only in the scratch clone and never `git commit` +
`git format-patch`'d into a numbered patch file are silently invisible
to that build — it just rebuilds whatever the last real patch left, with
zero error or warning. Burned an entire debug session with `ERR()`
traces that could never have fired, because the "fix" being tested
wasn't actually compiled in. Always re-export the patch after every
scratch-clone edit before rebuilding, even for a "quick" one-line
tweak. Separately: this launcher also defaults `WINEDEBUG=-all`
(`scripts/ableton-live` line 15, suppressing everything including
`err`, unless the caller already exports a value) — a plain
`ableton-live` launch with no `WINEDEBUG` set will never show `ERR()`
output at all, debug instrumentation or Wine's own; always launch with
an explicit `WINEDEBUG=+<something>` when tracing anything through this
launcher specifically.

## Update, 2026-07-23: CJK menu-item truncation (patch 0051, folded into 0050)

Reported against 0050 by issue 35 commenters once it shipped: menu bar
items lost their first and last characters (centered items) or text off
the right edge (left-aligned popup items) - e.g. "オプション" showing as
"プショ". Root cause: `calc_menu_item_size` (`dlls/win32u/menu.c`) sizes
`item->rect` by measuring `item->text` with whatever font is already
selected in `hdc` - the *original* font, never the fallback font
`draw_menu_item` actually renders with. A fallback font's real glyphs
are typically wider than the original font's notdef/tofu metrics, so
`item->rect` ended up sized for the wrong font, and `draw_menu_item`'s
`DrawTextW` clipped the wider real render to fit.

Fixed by forward-declaring `get_fallback_font_for_text` and calling it
in `calc_menu_item_size` the same way `draw_menu_item` already does,
before measuring instead of before drawing. Initially shipped as a
separate patch 0051, then folded directly into 0050 (still unmerged/
un-PR'd at the time) since it's a correctness fix to 0050's own logic,
not an independent bug - one coherent patch reads better than two.
Verified live: previously-truncated Japanese menu bar and dropdown
text, including a cut-off settings label, renders in full. See
`notes/ABLETON-WINE-MENU-THEMING-AND-FONT-FALLBACK.md` for the full
writeup.

**Dead end, same investigation:** suspected the File menu's
"パックをインストール..." was rendering its first character as "バ"
instead of "パ", based on a screenshot. Traced the raw string and font
file and both were correct, which would have meant a real (and fairly
deep) Wine glyph-cache bug — but a zoomed-in look at the actual render
showed the correct circle-shaped mark all along. Misread of a
compressed screenshot, not a bug; no action needed.

## Update, 2026-07-23: menu bar alt-key underlines (patch 0051)

Issue 35 point 6: "is it possible to remove the underlines from the
Wine menu bar?" Real Windows only shows these mnemonic underlines once
Alt is pressed (`WM_UPDATEUISTATE`/`UISF_HIDEACCEL`); this Wine tree
never implements that message handling at all, so the top-level bar
always drew them. Full Alt-to-reveal is a much bigger feature; hiding
them permanently gets the actual result asked for.

Added `DT_HIDEPREFIX` to the menu bar's `DrawTextW` call in
`dlls/win32u/menu.c` (menu bar only, not popup items) - which alone did
nothing. Traced to `DT_HIDEPREFIX` being a dead flag in this tree:
defined in `winuser.h`, mentioned in a `dlls/user32/text.c` comment, but
the actual underline-drawing site there only ever checked
`DT_NOPREFIX` (which shows a literal `&` instead of just hiding the
underline - not the same thing). Fixed by gating that underscore draw
on `DT_HIDEPREFIX` too. Verified live: bar underlines gone, dropdown
items keep theirs. See `notes/ABLETON-WINE-MENU-THEMING-AND-FONT-FALLBACK.md`
for the full writeup.

## Real rendering stack, confirmed

Ableton Live 12 bundles its own cross-platform renderer and does not
paint text through DirectWrite or D2D1 at all — confirmed directly
from symbols in `Ableton Live 12 Suite.exe` itself:
`SkiaAndHarfbuzzFont` (in an `ableton::font_rendering` namespace, with
`drawGlyphs`/`drawTextUtf8` methods), `SkTypeface_FreeType`,
`SkScalerContext_FreeType`, and literal build paths like
`...\third-party\skia\dist\...`. It's Google's **Skia** (the same 2D
graphics library Chrome uses) combined with **HarfBuzz** for text
shaping and Skia's own **FreeType** backend for rasterization.
DirectWrite is loaded only for OS-level font *enumeration* (asking
Windows what fonts exist, to feed Skia's own font matching) — it never
touches actual glyph rasterization. This is why the earlier GDI-level
toggles (`FontSmoothingType`, font substitution) and every
DirectWrite/D2D1-level experiment made no visible difference: none of
them sit anywhere on the path Live's text actually renders through.

**FreeType is statically compiled into Live's own executable**,
confirmed by checking every DLL/EXE in the Live install for an
external `freetype.dll`/`ft2` import — none exists (`objdump -p`
against every PE file, checked for a "DLL Name" import table entry).
Combined with the bundled Skia/FreeType symbols above, this means
Wine provides **no** font-rendering code on this path at all: no
Wine-side FreeType version, no hinting/LCD-filter setting, nothing
Wine implements for GDI or DirectWrite can affect how Live rasterizes
its own glyphs, since that entire step runs self-contained inside
Live's own binary using its own bundled library. `AbletonSansSmall-Regular.ttf`
was also confirmed opened directly out of the prefix's
`C:\windows\Fonts` (49 opens in one session via an `openat` trace) —
same literal font file either way, ruling out a font-substitution
explanation too.

**New data point: the blur is absent on genuinely stock Wine, not just
ENCORE.** During this session a launcher misconfiguration accidentally
ran Live against `/opt/wine-stable` (a real distro-packaged vanilla
Wine, zero `d2d1-dcomp` patches) — text rendered crisp there too, the
same as ENCORE. So the blur reproduces specifically and only on the
`giang17/wine` `d2d1-dcomp` fork (both 11.11 and 11.13), never on
stock Wine or ENCORE's build.

Put together, these two facts point away from font rendering entirely
and toward **presentation**: since Skia renders into its own bitmap
regardless of Wine build, and `_ForceGdiBackend` is active (finding 8
— Live's main window presents via GDI, not a D3D/DXGI swapchain), the
leading remaining suspect is the GDI blit path that transfers Skia's
rendered bitmap onto the actual window (`BitBlt`/`StretchDIBits`/
`SetDIBitsToDevice`) — something the fork's dcomp/compositing
additions could plausibly touch even for a plain GDI-presented window,
despite the blur having nothing to do with fonts. Not yet traced.

## Correction: "blur" is the wrong word — it's color fringing on disabled text, and it's a *different* rendering path

**2026-07-22, later the same day.** The symptom isn't really blur —
zoomed screenshots (6x nearest-neighbor) of the native `Options`
dropdown menu show it clearly: enabled/checked items ("Solo in
Place") render perfectly clean, solid black, zero fringing. Grayed
*disabled* items right next to them ("Solo Switches", "Cue Switches")
show visible red/cyan color fringing on every letter edge. That's
ClearType's RGB-subpixel antialiasing failing to cancel out to neutral
gray — classic symptom of ClearType blending text against the *wrong
assumed background color*, and it shows up worst on low-contrast
gray-on-gray text (disabled) while being invisible on high-contrast
black-on-gray text (enabled), because the subpixel blend math is far
more sensitive at low contrast. This exact symptom was independently
reported by a different user in issue #35, point 3 ("I think Wine
draws an extra stroke by default" on disabled dropdown entries) — a
real, reproducible thing, not specific to this session's setup.

**Important scope correction:** this is Wine's own native menu bar
(`File`/`Edit`/`Create`/.../`Options`/`Help` and their dropdowns),
rendered by Wine's own `win32u/menu.c` GDI code — a **completely
separate rendering path** from "Real rendering stack, confirmed" above
(Ableton's own Skia-rendered browser panel/track view/mixer). Anything
about Skia/HarfBuzz/bundled-FreeType is irrelevant to *this* specific
symptom; the earlier "browser panel is blurry too" report may be a
distinct issue, or may be the eye generalizing "some UI text looks
soft" from the menu fringing being the most visible instance of it —
not yet re-examined with this correction in mind.

**Tested and ruled out:** the fork changes a new window surface's
initial fill color from white (`0xff`) to black (`0x00`) in
`dlls/win32u/dce.c` (`window_surface_create`). Hypothesis was that
ClearType's blend reads this surface's actual background pixels before
the real background lands, so a black-vs-white initial fill would
shift the blend — testable and cheap (one line). Built an experimental
patch reverting `0x00` back to `0xff`, rebuilt (67/67 audit checks
passed), installed to an isolated test directory (not the canonical
install), launched, opened the same `Options` menu, screenshotted at
the same 6x zoom: **fringing was completely unchanged, pixel-identical
to before.** Patch removed afterward (kept the branch's diff minimal
per no-speculative-changes preference) — do not re-test this specific
line, it's confirmed not the cause.

**Not yet investigated:** the actual `win32u/menu.c` ClearType text
draw call for menu items (what `SetTextColor`/`SetBkColor`/`bkMode`
values it uses per findings above — `COLOR_GRAYTEXT` on `bkgnd`, single
color, no double-draw shadow effect was found on a first read of
`draw_popup_menu_item` — worth re-reading now with the *rendering*
side of ClearType in mind, not just the color-selection side already
read). Also not yet checked: whether this project's own patches
(0028/0029/0039/0040, all touching win32u menu-bar code for DPI/height
reasons) interact with this at all, even though none of them looked
like they touch text color/blending on a first pass.

Ableton Live 12 Suite renders visibly soft/blurred text throughout its
entire UI (menu bar, dropdown menus, browser panel — not one control)
under this project's `wine-d2d1-nspa-11.11` runtime, on a prefix where
the identical install renders crisp text under ENCORE's own Wine build.
This file records what is proven, what was ruled out, and where the
evidence for the next attempt is.

**Update, same day:** the project was rebased onto Wine 11.13
(`d2d1-dcomp-11.13`, see `patches/BASE.txt` and branch
`wine-11.13-upgrade`) specifically to test whether the version gap with
ENCORE's Wine 11.13 was the cause. It is not: verified via
`/proc/<pid>/maps` to confirm the actual running build (a launcher bug
first caused a false "it's fixed" read against the *old* 11.11 build
still running — corrected before drawing any conclusion), a raw 4x
nearest-neighbor zoom on the same menu-bar region shows the identical
RGB subpixel fringing pattern and softness on both 11.11 and genuine
11.13, and the user confirmed the same by eye on the real 11.13 build.
The blur is present in both Wine versions of the `d2d1-dcomp` fork —
narrows the cause to something inherent in that fork's DirectWrite/D2D1
stack itself (present since at least 11.11, still present in 11.13),
not a version-lag artifact. See the Wine-upgrade section below for the
full rebase trail; it was worth doing regardless (closes real gaps,
picks up upstream fixes) but does not resolve this bug.

## Setup under test

- Prefix: a byte-for-byte copy of a real, licensed ENCORE prefix
  (`~/ableton-prefix`, marker `.encore-prefix` = `ENCORE_PREFIX_V1`)
  duplicated to `~/ableton-prefix-shibco` before any shibco tooling
  touched it. Live 12 Suite (12.4.3 install present, several older
  version Preferences dirs also present) was already installed and
  authorized in the source prefix; authorization carried over untouched
  (Ableton's offline auth binds to the prefix `MachineGuid`, which a
  copy preserves — see `setup-prefix.sh` line ~534).
- `scripts/install.sh`'s launcher/helper-file half was staged manually
  (no `dist/*.tar.zst` was present to run the tarball-promotion half of
  the script; the already-installed `~/.local/opt/wine-d2d1-nspa-11.11`
  was left as-is). `scripts/setup-prefix.sh --refresh` was run against
  the copy: forced ~50 native VC++ redist DLLs over Wine's builtin
  stubs, registered PipeASIO, synced theme/DPI/portal policy. None of
  this touches license/auth state.
- Host: COSMIC desktop (System76), Wayland session (`XDG_SESSION_TYPE=wayland`,
  `XDG_CURRENT_DESKTOP=COSMIC`). Three outputs, all **Scale: 100%**
  (`cosmic-randr list`): HDMI-A-2 1920x1080, DP-1 2560x1440@144Hz (Dell
  S2716DG, Xwayland primary — where Live renders), HDMI-A-1 1920x1080.
  `~/.config/cosmic/com.system76.CosmicComp/v1/descale_xwayland` = `fractional`
  (COSMIC's mutter-`xwayland-native-scaling` equivalent — irrelevant
  here since the actual scale is integer 100%, not fractional).
- Compared against: ENCORE's own build (`ENCORE/build/wine64/wine`,
  `ENCORE/runtime/wine`), Wine **11.13**, run via
  `ENCORE/scripts/run-ableton.sh` against the original, un-copied
  `~/ableton-prefix`.

## Proven, with evidence

1. **The blur is real, not a screenshot/chat-tool artifact.** Captured
   with `cosmic-screenshot --interactive=false --notify=false`
   (raw, uncompressed native PNG, no third-party resizing), cropped at
   1:1 pixel scale (`(1920,0)-(2500,550)` on the 6400x1440 multi-monitor
   composite, i.e. the DP-1 output where Live renders). Same tool, same
   monitor, same compositor, both sessions captured minutes apart:
   ENCORE (Wine 11.13) → crisp text. shibco (`wine-d2d1-nspa-11.11`) →
   uniformly soft/blurred text, menu bar and browser panel alike.
2. **Not a DPI/scale mismatch.** `HKCU\Control Panel\Desktop\LogPixels`
   = `0x60` (96, "100%") in the shibco-side prefix, matching the host's
   flat 100% output scale on every monitor. No `dpiAwareness` IFEO set.
3. **Not the win32 chrome font substitution.** `ableton-live`'s
   `sync_ui_font` (Ableton Sans Small vs Tahoma via
   `ABLETON_UI_FONT=off`) — no visible difference either way.
4. **Not `FontSmoothingType`.** Found at `0x1` (standard grayscale AA,
   inherited unchanged from the ENCORE-created prefix, not touched by
   either project's scripts). Forced to `0x2` (ClearType) + a
   `FontSmoothingGamma` of 1400 — no visible difference.
5. **Not DirectComposition presentation.** `ABLETON_DCOMP=off` (forces
   `WINEDLLOVERRIDES=...;dcomp=`) — no visible difference.
6. **Not Wine's native Wayland driver.** `find ~/.local/opt/wine-d2d1-nspa-11.11
   -iname '*wayland*'` returns nothing; this build only ships
   `winex11.drv`. Both ENCORE and shibco render through Xwayland.
7. **Not COSMIC's Xwayland descaling.** All three outputs report
   integer 100% scale; `descale_xwayland=fractional` only fires for
   non-integer scale factors, so it's inert here.
8. **Not the dcomp-swapchain patches (0022/0025/0030/0036).** These are
   scoped to a specific `HWND` property
   (`__wine_dcomp_swapchain`/`dcomp_target_wndproc`) set on WebView2/JUCE
   composition targets. A `WINEDEBUG=+dxgi,+d3d11,+win32u` trace across
   a full normal-use launch (no Learn View opened) shows **zero** `dcomp`
   mentions and exactly one `dxgi` call total
   (`dxgi_output_GetDesc`, a plain adapter-enumeration query) — the main
   window never touches this codepath. Confirms `_ForceGdiBackend`
   (present in every `Options.txt` in the prefix, inherited from
   ENCORE's own runs) is honored: Live's main UI renders via GDI, not a
   D3D/DXGI swapchain.
9. **Not patch 0042** (`alias sub-scale WM config rounding`). Its logic
   is explicitly gated on `dpi > USER_DEFAULT_SCREEN_DPI` (96); at our
   flat 100% scale every gate (`config_matches_dpi_rounding`,
   `config_edges_within_dpi_rounding`) returns `FALSE` immediately.
   Inert in this environment.
10. **DirectWrite is genuinely load-bearing for Live's own UI**, not a
    coincidental dependency. `dwrite.dll`/`dwrite.so` are mapped in the
    live process (`/proc/<pid>/maps`). Relaunching with
    `WINEDLLOVERRIDES=dwrite=` (disabled) does **not** gracefully fall
    back to GDI text: Live creates its windows, then crashes
    (`EXCEPTION_WINE_CXX_EXCEPTION`, exit 1) the moment something tries
    to use DirectWrite. Live 12's own custom-drawn UI depends on
    DirectWrite, separate from and in addition to the GDI-drawn win32
    chrome that `FontSmoothingType`/font-substitution govern — which is
    exactly why none of the GDI-level settings above changed anything:
    they don't touch whatever's rendering the bulk of the window.
11. **Not the Wine base version.** The project was rebased onto Wine
    11.13 (`d2d1-dcomp-11.13`, branch `wine-11.13-upgrade`) specifically
    to test this — closes the exact version gap with ENCORE. Built,
    installed, and launched with the actual running build confirmed via
    `/proc/<pid>/maps` (a launcher template missed in the rename swept
    first produced a false "it's fixed" read against the *old* 11.11
    build still running unnoticed — caught and corrected before drawing
    a conclusion). A raw 4x nearest-neighbor zoom on the identical
    menu-bar region shows the same RGB subpixel fringing and softness on
    both versions; the user confirmed the same by eye on the verified
    11.13 build. The blur predates 11.11 and survives the bump to 11.13
    — it's in something both versions of the `d2d1-dcomp` fork share,
    not a version-lag artifact.

## Background: where the fork comes from

`patches/BASE.txt` reveals `wine-d2d1-nspa-11.11`'s base is not vanilla
Wine 11.11: it's `giang17/wine` branch `d2d1-dcomp-11.11` (vendored
locally, byte-identical, at `vendor/wine-base-7ea0c8b7.tar.zst`,
squash commit `7ea0c8b7dd "d2d1-dcomp stack: port to wine-11.11"`),
*before* any of this project's own 42 patches apply on top. That fork's
own `PATCHES.md` describes itself as adding real D2D1, DirectComposition,
and DirectWrite support so **third-party JUCE8/VSTGUI plugin editors**
(Serum2, Korg Trinity, Korg Prophecy, Pianoteq 9) render correctly in
Reaper — and explicitly lists a "DWrite: Rendering mode 5 fix" among its
changes. It does not mention Ableton Live anywhere.

## Dead end, investigated 2026-07-22: the D2D1 rendering-mode substitution

**Retracted — kept for reference, do not re-investigate.** This was
the first hypothesis after finding a real, deliberate rendering-mode
substitution in the `giang17/wine` fork. It looked like a strong match
right up until a live trace showed `d2d1.dll` isn't even loaded in
Live's process — this code cannot run. See "Why the D2D1 lead was
wrong" near the top of this file for the trace evidence, and "Real
rendering stack, confirmed" for what to investigate instead.

Found by diffing the fork's own squash commits (`7ea0c8b7dd` for 11.11,
`17a857dd` for 11.13 — a local clone of `giang17/wine` carries these as
real, inspectable commits) against the stock Wine tree they're based
on. `dlls/dwrite/font.c`'s rendering-mode *selection* logic
(`GetRecommendedRenderingMode` etc.) is untouched, stock Wine — the
earlier hypothesis pointing there was wrong. The real change is in
`dlls/d2d1/device.c`, function `d2d_device_context_draw_glyph_run` —
the function every D2D1 text draw call actually goes through:

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

Whenever any app requests `DWRITE_RENDERING_MODE_ALIASED` (crisp,
non-antialiased — a natural choice for small, sharp UI text) or
`_OUTLINE`, this silently substitutes `DWRITE_RENDERING_MODE_NATURAL`
(a smoothed/antialiased mode) instead — unconditionally, for every
caller. The fork's own comment confirms this is a deliberate workaround
for FreeType rendering ALIASED/OUTLINE badly under Wine, done for the
fork's actual target (JUCE8/VSTGUI plugin editors), never validated
against Ableton's own UI. If Live requests ALIASED text — plausible,
given how compact and small DAW UI text typically is — it gets
downgraded to NATURAL and comes out softer than intended. This is a
different code path from the earlier `ABLETON_D2D1_FORCE_GRAYSCALE_TEXT`
experiment (patch 0045 on `wine-11.13-upgrade`, which touched
antialiasing-mode *selection* elsewhere), explaining why that
experiment made no visible difference — it never touched this
substitution.

A related, smaller hunk in the same squash commit, in
`dlls/dwrite/font.c`'s `create_glyphrunanalysis`, does the same kind of
thing one mode up the chain: `DWRITE_RENDERING_MODE1_NATURAL_SYMMETRIC_DOWNSAMPLED`
(what the fork's changelog calls "Rendering mode 5") is silently
substituted with plain `DWRITE_RENDERING_MODE1_NATURAL_SYMMETRIC`
instead of being properly implemented, again with an explicit comment
("not fully supported"). Lower priority than the ALIASED/OUTLINE
forcing above since it's one mode removed from what small UI text
would typically request, but the same class of bug and worth checking
if the primary fix doesn't fully resolve things.

**Not yet established:** whether Ableton actually requests ALIASED
specifically (assumed, not traced — see next steps), and whether
removing this forcing regresses the fork's original target (JUCE8/VSTGUI
plugin editors) back to whatever poor FreeType rendering the workaround
was added for. Both are answerable before committing to a fix.

## Proposed fix for the D2D1 substitution (moot — not applicable to this bug)

Would have been: stop unconditionally forcing `NATURAL` for
`ALIASED`/`OUTLINE` in `d2d_device_context_draw_glyph_run`. Not worth
doing for the blur (the code isn't reachable from Live at all) — may
still be worth fixing someday for whatever plugin editors *do* go
through D2D1, but that's a separate concern from this bug.

## Suggested next steps for whoever picks this up

Given Live renders via its own bundled Skia+HarfBuzz+FreeType, not
DirectWrite/D2D1, the right next steps are at the font-file/FreeType
level instead:

1. Trace which actual font **file** Live's Skia backend opens for its
   UI text (`WINEDEBUG=+file` or `strace -e openat` on the process),
   comparing this project's build against ENCORE's on the identical
   prefix — confirm both are opening the same literal `.ttf`/`.ttc`
   file, not silently different fonts that just look similar.
2. If the same font file, compare what Skia's Windows font-host layer
   would query from the OS to configure its FreeType rasterizer —
   likely `SystemParametersInfo(SPI_GETFONTSMOOTHINGTYPE)` /
   `SPI_GETFONTSMOOTHINGCONTRAST` and similar — and whether Wine's
   implementation of those returns different values than what ENCORE's
   build effectively provides, even though the FontSmoothingType
   registry value itself tested identical (finding 4 above) — Skia may
   read it via a different API path than the raw registry key.
3. Only then consider whether this is a FreeType library
   version/config difference at all (unlikely to be host-level, since
   both builds were tested on the identical host — but worth checking
   what FreeType version each Wine build was compiled/linked against,
   if Skia's Windows build ends up depending on it indirectly through
   Wine's own text stack for anything).

## Session artifacts (not preserved past this session)

Raw screenshots and crops lived in the session scratchpad
(`/tmp/claude-*/scratchpad/`, `Screenshot_2026-07-21_15-*.png`,
`crop_menu.png`, `crop_encore.png`, `wine-trace.log`, `no-dwrite2.log`)
and were not copied anywhere durable. Re-run the repro (copy prefix,
`ABLETON_WINEPREFIX=~/ableton-prefix-shibco ableton-live` vs
`ENCORE_PREFIX=~/ableton-prefix ENCORE/scripts/run-ableton.sh`,
`cosmic-screenshot --interactive=false --notify=false --save-dir=<dir>`)
to regenerate.
