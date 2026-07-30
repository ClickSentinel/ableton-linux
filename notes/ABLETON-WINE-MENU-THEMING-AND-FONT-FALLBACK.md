# How the native menu bar's color theming and font fallback work

Issue #32 (unified top bar) and #35 (theming fit and finish, including
non-Latin fallback). Reference documentation for the two coupled systems
that make Wine's native win32 menu chrome (menu bar, dropdowns, dialogs)
match Ableton's own theme and render any script Ableton's UI is set to,
instead of Wine's stock light-Windows-95 look in Latin-only Tahoma. For
the investigation history, dead ends, and exact trace evidence behind
each piece below, see `FINDINGS-TEXT-RENDERING-BLUR-2026-07-21.md`.

## Overview

Two independent problems, two independent fixes, wired together in
`scripts/ableton-live`:

1. **Color**: the menu bar and its dropdowns should look like part of
   Ableton's own UI (matching whatever `.ask` theme file Live has
   selected), update live if the user switches themes without
   restarting, and use a real color there instead of Wine's stock gray.
2. **Font**: Live's own UI typeface (`Ableton Sans`/`Ableton Sans
   Small`) is substituted onto the win32 chrome for visual consistency
   (issue #32), but that font only has Latin-script glyphs. Any menu
   text needing anything else - a non-Latin locale, a translated menu,
   a non-Latin project/track name - needs to fall back to a font that
   actually has the glyph, or it renders as nothing at all.

Both problems turned out to need real Wine patches, not just
config/registry changes - in both cases because the relevant Wine
mechanism (`SetSysColors`, `SystemLink` font-linking) exists and loads
correctly, but nothing in win32u's actual menu-drawing code was
consuming it. Patches `0048`-`0050` add the missing consumers.

## Color: launch-time sync

Before Ableton starts, `sync_win32_colors()` (`scripts/ableton-live`)
writes directly into `HKCU\Control Panel\Colors` via `wine reg add`.
When Ableton's process starts fresh afterward, it picks these up
through Wine's completely normal first-read-loads-from-registry
behavior - no special mechanism needed for this half.

Where the colors come from, when `ABLETON_TOPBAR_MODE=live` (the
default): `resolve_live_topbar()` reads whichever `.ask` theme file
Live currently has selected (`ableton_live_theme_file()` in
`scripts/detect-theme.sh`, matching the theme name embedded as a UTF-16
string in the running version's `Preferences.cfg` against the
installed `Themes/` directory) and pulls specific keys out of it via
`ableton_ask_color()` (a `sed` one-liner reading `<Key Value="#rrggbb"
/>` out of the theme's flat XML):

| registry value | theme key | rationale |
|---|---|---|
| `MenuBar` / `ActiveTitle` / `GradientActiveTitle` | `Desktop` | the always-visible bar; darker than the surface behind it in every reference (a dark chrome strip framing lighter content) |
| `Menu` (dropdown background) | `ControlBackground` | matches Live's own popup/control surfaces, lighter than the bar |
| `MenuText` / `TitleText` | `ControlForeground` | shared: win32 has only one menu text color for both the bar and its dropdowns |
| `MenuHilight` / `Hilight` / `HilightText` | `SelectionBackground` / `SelectionForeground` | selected-item highlight, always applied as a matched set |
| `GrayText` | *(derived, not a theme key - see below)* | disabled/grayed item text |

`GrayText` has no direct source: Live's own `TextDisabled` token was
tried and rejected (checked against the live theme: it sits closer to
`Desktop` than even Wine's compiled-in default does - that token is
calibrated for Live's own layered Skia surfaces, not a flat `win32u`
menu fill). Instead it's a 45%-toward-`MenuText` blend of whatever
`Menu`/`MenuText` resolve to, computed generically so it tracks any
theme and either light/dark fallback with no extra parsing.

`ABLETON_TOPBAR_MODE=system` uses the host's own titlebar colors
instead (KDE globals, or GNOME header-bar constants as a generic
fallback) via `ableton_detect_topbar_colors()`; `preserve` leaves the
old flat scheme colors; `#RRGGBB #RRGGBB` forces bar background/text
directly. `ensure_flat_menu()` sets the `SPI_GETFLATMENU` preference bit
so the bar actually honors `COLOR_MENUBAR` instead of `COLOR_MENU`.

## Color: live re-theming while Live is already running

`theme_watch_loop()` (`scripts/ableton-live`) runs as a background
watcher for the life of the Live process (one per prefix, `flock`-
guarded). It watches `Preferences.cfg` for changes with `inotifywait`
when `inotify-tools` is installed (event-driven - wakes on the write
itself), falling back to a plain 2-second mtime poll otherwise, same
graceful-degradation pattern already used for the `flock` dependency.

**Picking the right `Preferences.cfg`, and the file it's actually
watching**: both `theme_watch_prefs_cfg()` here and
`ableton_live_theme_file()` in `detect-theme.sh` need to find the
currently-relevant `Live <version>/Preferences/Preferences.cfg` among
however many past versions have ever run. Both do this by newest
*mtime* of the actual file, deliberately **not** `sort -V | tail -1` on
the directory name - version-sorting the *path* has a real gotcha:
`"Live 12.4/Preferences/..."` sorts *after*
`"Live 12.4.3/Preferences/..."`, because the two strings diverge right
after `"12.4"` into `/` (0x2F) vs `.` (0x2E) starting a new version
segment, and `strverscmp` falls back to a plain byte compare there,
where `/ > .`. That silently picked a long-dead old-version prefs file
over the live one every time it was tried.

When the watched file changes, the colors are re-resolved exactly as at
launch, then applied via the launcher's own `setsyscolors.exe` helper
(`tools/setsyscolors.c`) rather than another `wine reg add` - a plain
registry write only reaches processes started *afterward*; making an
*already-running* process pick up new colors needs an actual live
`SetSysColors()` call from inside the same Wine session, which nothing
short of a real running `.exe` can do. `setsyscolors.exe` is a small,
no-CRT, hand-built PE binary (`tools/build_setsyscolors.sh`) that
parses `Name=R,G,B` arguments off its own command line and calls
`SetSysColors()` once. As of patch 0049 that's *all* it does; it used
to also `EnumWindows`+`DrawMenuBar` on every window to work around a
gap now fixed in Wine itself (see below).

A diff-guard (`theme_watch_loop`'s `applied` tracking) skips re-firing
`setsyscolors.exe` when a `Preferences.cfg` touch resolves to the same
colors as last time - the watched file gets touched for plenty of
reasons besides an actual theme pick (window layout, focus state), and
broadcasting a live color change is not free.

### Why this needed two Wine patches, not just the registry write

`SetSysColors()` alone did nothing visible to an already-running
window, for two separate, independent reasons - both real Wine gaps,
not fork-specific (confirmed: zero diff against stock Wine in both
files):

- **`patches/0048-win32u-invalidate-the-per-process-sys-color-cache-o.patch`**:
  each process caches every system color (and any `HBRUSH`/`HPEN`
  built from it) the first time it reads one
  (`dlls/win32u/sysparams.c`, `get_rgb_entry`/`get_sys_color_brush`),
  and nothing ever invalidated that cache in response to
  `WM_SYSCOLORCHANGE` - a window that had already read `COLOR_MENUBAR`
  once kept returning the same stale value and the same stale brush
  forever, regardless of how many times `SetSysColors` was called from
  elsewhere. Fixed by resetting every entry's cache from
  `dlls/win32u/message.c`'s `call_window_proc` - the common delivery
  point for every message reaching a window procedure regardless of
  same-thread/cross-thread/cross-process origin - right before
  `WM_SYSCOLORCHANGE` reaches it, in the *receiving* process.
- **`patches/0049-win32u-include-the-non-client-area-in-setsyscolors.patch`**:
  `NtUserSetSysColors` already tried to force a repaint after a color
  change, but its `RedrawWindow` flags (`RDW_INVALIDATE | RDW_ERASE |
  RDW_UPDATENOW | RDW_ALLCHILDREN`) only reach client areas;
  `RDW_FRAME` (the non-client area, where a native menu bar actually
  lives) was missing. One flag added.

### Known limitation: presentation latency

Even with both patches, the actual on-screen pixels can still take
anywhere from well under a second to several seconds to become visible
after a real theme switch - measured directly, not a fixed interval,
and reproducible with zero user interaction at all (so it is not an
"needs a click to wake up" requirement, just a very unreliable delay).
Two additional fixes were tried and **reverted** because they measurably
made no difference in the real `theme_watch_loop`-driven path, despite
looking successful in isolated manual testing:
`RedrawWindow(...RDW_UPDATENOW...)` and a synthetic `SendInput` mouse
nudge, both from `setsyscolors.exe`. Not yet root-caused. One concrete,
untested lead: `theme_watch_loop`'s invocation is a fully detached
background process (`( theme_watch_loop ) </dev/null >/dev/null 2>&1
&`, no controlling terminal) while the manual tests that looked
successful were run from an interactive shell - that distinction was
raised but never actually isolated.

## Font: the substitution, and why it broke non-Latin text

`sync_font_substitutes()` / `sync_metric_fonts()` (`scripts/ableton-live`,
issue #32) symlink Live's own `AbletonSans*.ttf` faces into the
prefix's Fonts directory and repoint `MS Shell Dlg`/`MS Shell Dlg 2`
plus the `WindowMetrics` non-client `LOGFONT`s (`MenuFont`,
`MessageFont`, `CaptionFont`, etc.) at whichever face is present
(`Ableton Sans Small`, falling back to plain `Ableton Sans`), so the
chrome visually matches Live's own UI instead of rendering stock
Tahoma.

Checked directly via the font files' own `cmap` tables: both faces
cover Latin script only - Basic Latin, Latin-1, Latin Extended-A/B,
plus a handful of Greek symbols. Zero glyphs anywhere in Cyrillic,
Arabic, Hebrew, Devanagari, Thai, CJK, or Hangul. Substituting this
font onto every menu, dialog, and message box also has a side effect
beyond narrowing glyph coverage: Wine's own built-in Unicode/CJK
font-fallback population (`dlls/win32u/font.c`, `load_system_links`) is
keyed by literally string-comparing the current `MS Shell Dlg`
substitute against a small fixed list of recognized names ("Tahoma",
"MS UI Gothic", "SimSun", "Gulim") - once that substitute is anything
else, none of those matches ever fire, and that whole population step
silently does nothing.

## Font: the fallback chain, and its actual consumer

`sync_font_fallback()` (`scripts/ableton-live`) registers Wine's real,
general font-linking mechanism -
`HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`,
which (unlike the hard-coded population above) works for any font name
- with a two-entry fallback chain for whichever family was just
substituted in:

1. **Tahoma** - Wine's only bundled font with any real non-Latin
   coverage (checked: 104 Cyrillic + 162 Arabic glyphs).
2. **Whatever real CJK font the host happens to have installed**,
   found via `fc-match -f '%{file}'/'%{family}' ':lang=ja'` and
   symlinked into the prefix's Fonts directory. Best-effort: silently
   skipped if `fc-match` is unavailable or the host genuinely has no
   CJK font, same as a stock Wine install would be either way (Wine
   itself bundles no CJK font at all, so this is strictly additive,
   never a regression).

Registering this chain alone was tried first and **made no visible
difference whatsoever** - confirmed via `WINEDEBUG=+font` trace that
Wine loads it correctly and resolves it to real font files (including
correctly picking the Japanese face out of a 5-face `.ttc` collection),
yet menu text needing those glyphs still rendered as tofu. Root cause,
found by reading `dlls/win32u/freetype.c` and `dlls/user32/text.c`:
`SystemLink` is only ever consulted by `can_select_face` during
whole-font *selection*, gated on the system's ANSI codepage matching a
*requested* charset - never during glyph *rendering*. The actual glyph
lookup (`freetype_get_glyph_index`) is a direct FreeType charmap query
against whichever single font is already selected, with zero awareness
of any linked fallback; `DrawTextExW` (what the menu-drawing code
actually calls) has no font-substitution logic of its own either. A
registered chain sitting unused fixes nothing until something walks it
per string being drawn.

**`patches/0050-win32u-fall-back-to-a-linked-font-for-missing-glyph.patch`**
adds that missing consumer, in `dlls/win32u/menu.c`'s `draw_menu_item`
(the same function patch 0047 already touches for the disabled-text
bevel):

1. `get_fallback_font_for_text()` checks whether the currently selected
   font can render the item's text at all, via `NtGdiGetGlyphIndicesW`
   with `GGI_MARK_NONEXISTING_GLYPHS` (confirmed by reading
   `font_GetGlyphIndices`: this, too, only ever checks the one font
   actually selected - exactly the per-font coverage test wanted here).
   Control characters (`< ' '`) are excluded from this check: the item
   text includes its raw `'\t'`-separated shortcut column, and no font
   has an actual renderable glyph for a literal tab - it's a layout
   separator, not a character, and flagging it as "missing" was failing
   every otherwise-fully-covered string that happened to show a
   keyboard shortcut.
2. If something is missing, it walks that font's registered
   `SystemLink` families (`get_font_link_families()`, new in
   `dlls/win32u/font.c` - a thin accessor exposing what
   `find_gdi_font_link` already tracks internally, otherwise
   unreachable outside that file) and temporarily selects the first
   candidate that actually covers the text (matching size/weight via
   `NtGdiExtGetObjectW` + `NtGdiHfontCreate`, the same idiom this file
   already uses for its Marlett-glyph drawing) for that item's
   `DrawTextW` calls, then restores and deletes it.

One naming wrinkle along the way: `NtGdiExtGetObjectW` returns the
*resolved face's* full name (e.g. `"Ableton Sans Small Regular"`), not
the family name the `SystemLink` chain is registered under
(`"Ableton Sans Small"`) - the code strips the known style suffix
(`" Regular"`, `" Bold"`, `" Italic"`, `" Bold Italic"`,
`" Regular Italic"`) and retries before giving up.

A third bug was reported against this patch after it shipped (issue
35): CJK menu text rendered with its first and last characters missing
on menu bar items (centered) or cut off on the right on popup items
(left-aligned) - e.g. `"オプション"` showing as `"プショ"`. The cause:
`calc_menu_item_size` (the function that sizes `item->rect`, sharing
this file with `draw_menu_item`) measures `item->text` with whatever
font is already selected in `hdc` - the *original* font, never the
fallback font `draw_menu_item` actually renders with. A fallback font's
real glyphs are typically wider than the original font's notdef/tofu
metrics, so `item->rect` ended up sized for the wrong font, and
`draw_menu_item`'s `DrawTextW` clipped the wider real render to fit.
Fixed by forward-declaring `get_fallback_font_for_text` and calling it
in `calc_menu_item_size` the same way `draw_menu_item` already does,
before measuring instead of before drawing - both call sites already
select the same plain (non-bold) menu font into `hdc` before their
respective loops, so the two selections stay in lockstep. Verified
live: a previously-truncated Japanese settings label renders in full.

### Known limitation: whole-string swap, not per-character

Text mixing scripts (an English label concatenated with a non-Latin
project/track name, say) renders *entirely* in the fallback font rather
than mixing faces mid-string. Real per-glyph fallback is a
Uniscribe/DirectWrite-level feature that plain `DrawTextW` - what
`draw_menu_item` actually calls - has never had; implementing that
properly (splitting a string into per-script runs and drawing each with
its own face) is a materially larger undertaking than this. This trades
a rarer, minor font-consistency slip for the text actually rendering at
all instead of showing nothing.

### Dead end, investigated 2026-07-23: suspected wrong glyph, actually correct

Looked into after the truncation fix (0050/0051): the File menu's
`パックをインストール...` ("Install a Pack...") appeared, from a
screenshot, to render its first character as `バ` (U+30D0) instead of
the correct `パ` (U+30D1). `WINEDEBUG=+menu` confirmed the raw string
Ableton hands to Wine is already correct (`debugstr_menuitem`'s `Text=`
field shows `\30d1` as the first character), and the fallback font in
use (Noto Sans CJK JP) has distinct, correct glyphs for both codepoints
(fontTools cmap: U+30D0 -> glyph 1601, U+30D1 -> glyph 1602) - so if the
render really were wrong, it'd have been a real, fairly deep Wine bug
(a stale glyph/font cache, given `get_fallback_font_for_text` creates a
fresh throwaway `HFONT` per item rather than reusing a long-lived one).

Turned out to be a misread, not a bug: `パ`'s handakuten (small circle)
and `バ`'s dakuten (two short strokes) are easy to confuse at
screenshot compression/scale, and that's exactly what happened here -
a zoomed-in look at the actual rendered character confirmed the circle
is there. No further action; the font-fallback + truncation fix (0050)
renders this item correctly.

Ableton's own browser panel, track list, and other in-app UI were never
affected by any of this and needed no fix - that's Live's own bundled
Skia+HarfBuzz+FreeType stack, a completely separate rendering path from
the win32 chrome (menu bar, dropdowns, dialogs) these patches touch,
and it already has correct font fallback built in.

## Menu bar: hiding the alt-key mnemonic underlines

Issue 35 point 6: "is it possible to remove the underlines from the
Wine menu bar?" - the underline under each top-level item's first
letter (File, Edit, Create, ...), the standard Win32 alt-key mnemonic
cue. Real Windows only shows these once Alt is pressed (the
`WM_UPDATEUISTATE`/`UISF_HIDEACCEL` "keyboard cues" system); this Wine
tree never implements that message handling at all (confirmed: no
`WM_UPDATEUISTATE`/`WM_QUERYUISTATE`/`WM_CHANGEUISTATE` handling
anywhere outside its own tests), so the bar always drew them, unlike
real Windows or macOS. Implementing the full Alt-to-reveal toggle is a
much larger feature - global UI-state tracking, Alt key press/release
wiring, propagation through every window - so **`patches/0051-*.patch`**
just permanently hides them instead, which is the actual visual result
that was asked for.

Two parts, because the first alone turned out to be a no-op:

1. `dlls/win32u/menu.c`'s `draw_menu_item` adds `DT_HIDEPREFIX` to the
   menu bar's `DrawTextW` format flags (menu bar only - popup/dropdown
   items keep their mnemonics, where Alt-key in-menu navigation is
   still commonly used).
2. `DT_HIDEPREFIX` turned out to be a *dead flag* in this tree: defined
   in `winuser.h` and mentioned in a `dlls/user32/text.c` comment, but
   the actual underline-drawing call site there only ever checked
   `DT_NOPREFIX` - which isn't equivalent, it stops `&` being treated as
   an escape at all, so it would show a literal `&` in the text instead
   of just hiding the underline. Fixed by gating the underscore-drawing
   call in `dlls/user32/text.c` on `DT_HIDEPREFIX` too, leaving
   `&`-stripping and prefix-offset tracking (already unaffected by this
   flag) exactly as before.

Verified live: the top-level bar (File/Edit/Create/...) no longer shows
underlines; an open dropdown's own items still show theirs.

## File map

| file | role |
|---|---|
| `scripts/ableton-live` | `sync_win32_colors`, `resolve_live_topbar`, `theme_watch_loop`, `theme_watch_prefs_cfg`, `sync_font_substitutes`, `sync_metric_fonts`, `sync_font_fallback`, `ensure_flat_menu` |
| `scripts/detect-theme.sh` | `ableton_live_theme_file`, `ableton_ask_color`, `ableton_detect_theme`, `ableton_detect_topbar_colors` (host-theme detection, used by `ABLETON_TOPBAR_MODE=system`) |
| `tools/setsyscolors.c` + `build_setsyscolors.sh` | the live `SetSysColors()` call itself; a small no-CRT PE binary, rebuilt independently of the Wine tarball |
| `patches/0047-*.patch` | disabled-menu-item engraved-bevel ghosting (separate bug, same function family) |
| `patches/0048-*.patch` | per-process sys-color/brush/pen cache invalidation on `WM_SYSCOLORCHANGE` |
| `patches/0049-*.patch` | `RDW_FRAME` in `NtUserSetSysColors`'s forced repaint |
| `patches/0050-*.patch` | per-string `SystemLink` font fallback in `draw_menu_item`, and `calc_menu_item_size` measuring with it |
| `patches/0051-*.patch` | hides the menu bar's alt-key mnemonic underlines (`DT_HIDEPREFIX`, plus making that flag actually work in `dlls/user32/text.c`) |

## Debugging notes for whoever touches this next

- This launcher defaults `WINEDEBUG=-all` (`scripts/ableton-live` line
  ~15, suppressing everything including `err`, unless the caller
  already exports a value). A plain `ableton-live` launch with no
  `WINEDEBUG` set will never show `ERR()`/`FIXME()` output at all, your
  own debug instrumentation included. Always launch with an explicit
  `WINEDEBUG=+something` when tracing anything through this launcher.
- `wine reg query`/reading `system.reg`/`user.reg` directly only ever
  shows the *persistent* registry state. A live `SetSysColors()` call
  writes to a separate "volatile" key and the calling process's own
  memory; neither shows up in the on-disk `.reg` file until wineserver
  flushes on a clean shutdown. Don't use a registry read to check
  whether a live color change actually applied.
- For iterating on a `win32u`-only change without a full ~20-minute
  container rebuild: unpack the base, apply the full patch series,
  `configure`, then a *targeted* `(cd dlls/win32u && make)` - produces
  `dlls/win32u/win32u.so` (not `.../x86_64-unix/win32u.so` - that path
  doesn't exist for this dll) in well under a minute, which can be
  hot-swapped directly into an installed runtime's
  `lib/wine/x86_64-unix/win32u.so` for a fast test loop. This reads
  patches from `ableton-linux/patches/`, **not** any scratch clone's
  working tree - edits made only in a scratch clone and never
  `git commit` + `git format-patch`'d into a numbered patch file are
  silently invisible to this build, with no error or warning. Always
  re-export before rebuilding, even for a one-line tweak - this cost a
  full debug session once.
- This is not a substitute for the real tarball/`install.sh` path
  before calling anything actually fixed - it's for iteration speed
  only, and easy to leave stale debug instrumentation in if you forget
  to do a final clean rebuild + real install before finishing.
