# How the native menu bar's color theming and font fallback work

Issue #32 (unified top bar) and #35 (theming fit and finish). Reference
documentation for the system that makes Wine's native win32 menu chrome
(menu bar, dropdowns, dialogs) match Ableton's own active theme instead
of Wine's stock light-Windows-95 gray, keeps following it live while
Live keeps running, and renders its text in Live's own font without
losing non-Latin scripts. For the investigation behind the remaining gap
in the "live" half (point 4: switching while the Preferences dialog is
still open), see `FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md`.

## Overview

Two sync paths, both in `scripts/ableton-live`, both ultimately writing
the same `HKCU\Control Panel\Colors` values, plus two independent
`win32u` bugs that had to be fixed for the second path to actually be
visible:

1. **Launch-time sync** - a plain registry write before Live starts, so
   the process picks the colors up through Wine's completely normal
   first-read-loads-from-registry behavior. No patch needed for this
   half; it already worked.
2. **Live re-theming** - a background watcher applies the same colors
   to an *already-running* Live process via a real `SetSysColors()`
   call, the instant `Preferences.cfg` shows the user picked a new
   theme. This half needed two real Wine patches
   (`0050`, `0051` below) - the relevant Win32 mechanism already
   existed and was being called correctly, but nothing in `win32u`
   made its effect reach an already-running window.

Two further, narrower fixes round out the "fit and finish" pass:
dropping a Win95-era grayed-text bevel that reads badly once the menu
is dark (`0049`), and hiding the alt-key mnemonic underlines the bar
always drew, since real Windows only shows them once Alt is pressed and
this Wine tree never implements that toggle (`0052`).

Font is a third, largely independent axis on the same chrome. The
launcher substitutes Live's own face into the non-client `LOGFONT`s so
the bar matches Live's UI; because that face is Latin-only, and because
substituting it also disables Wine's built-in CJK fallback population, a
further patch was needed to make missing glyphs resolve through the
`SystemLink` chain at draw time (`0054`, on the `language-fallback`
branch, not yet in `main`).

## Fixing the grayed-item bevel

`draw_menu_item` (`dlls/win32u/menu.c`) used to draw disabled
(`MF_GRAYED`) menu text twice for a classic Win95 "engraved" look: a
white pass offset `+1,+1`, then a gray pass at the original position.
That assumes `COLOR_3DHILIGHT` is a light color close to the menu
background - true for the stock light theme, but this prefix (like most
apps that theme dark via `SetSysColors`) leaves `COLOR_3DHILIGHT` at its
Windows default (white) regardless of the dark menu around it, so the
highlight pass rendered as a glaring white ghost offset from the real
text instead of a subtle bevel.

**`patches/0049-win32u-drop-the-grayed-menu-item-engraved-bevel-ent.patch`**
drops the two-pass bevel entirely and always single-draws in
`get_sys_color(COLOR_GRAYTEXT)`, matching what the adjacent
`MF_HILITE`-grayed case already did successfully. This code has zero
diff from stock Wine, so the bug is upstream, not fork-specific.

## Launch-time sync

Before Ableton starts, `sync_win32_colors()` (`scripts/ableton-live`)
writes directly into `HKCU\Control Panel\Colors` via `wine reg add`.

Where the colors come from, when `ABLETON_TOPBAR_MODE=live` (the
default): `resolve_live_topbar()` reads whichever `.ask` theme file Live
currently has selected (`ableton_live_theme_file()` in
`scripts/detect-theme.sh`, matching the theme name embedded as a UTF-16
string in the running version's `Preferences.cfg` against the installed
`Themes/` directory) and pulls specific keys out of it via
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
menu fill). Instead `blend_gray_text()` computes a 45%-toward-`MenuText`
blend of whatever `Menu`/`MenuText` resolve to, generic enough to track
any theme and either light/dark fallback with no extra parsing; it's
shared between this launch-time path and the live-watch path below.

`ABLETON_TOPBAR_MODE=system` uses the host's own titlebar colors
instead (KDE globals, or GNOME header-bar constants as a generic
fallback) via `ableton_detect_topbar_colors()`; `preserve` leaves the
old flat scheme colors; `#RRGGBB #RRGGBB` forces bar background/text
directly. `ensure_flat_menu()` sets the `SPI_GETFLATMENU` preference bit
so the bar actually honors `COLOR_MENUBAR` instead of `COLOR_MENU`.

## Live re-theming while Live is already running

`theme_watch_loop()` (`scripts/ableton-live`) runs as a background
watcher for the life of the Live process - one per prefix, `flock`-
guarded so a relaunch's watcher waits out the previous session's rather
than racing it. It watches `Preferences.cfg` for changes with
`inotifywait` when `inotify-tools` is installed (event-driven - wakes on
the write itself), falling back to a plain 2-second mtime poll
otherwise.

**Picking the right `Preferences.cfg`**: both `theme_watch_prefs_cfg()`
here and `ableton_live_theme_file()` in `detect-theme.sh` need to find
the currently-relevant `Live <version>/Preferences/Preferences.cfg`
among however many past versions have ever run - both do this by newest
*mtime* of the actual file (`ableton_newest_prefs_dir()`), deliberately
**not** `sort -V` on the directory name: `"Live 12.4/..."` sorts *after*
`"Live 12.4.3/..."` under a plain version sort, because the two paths
diverge right after `"12.4"` into `/` (0x2F) vs `.` (0x2E), and a
byte-compare there picks the wrong one - silently serving a long-dead
old-version prefs file instead of the live one.

When the watched file changes, the colors are re-resolved exactly as at
launch, then applied via `setsyscolors.exe` (`tools/setsyscolors.c`)
rather than another `wine reg add`: a plain registry write only reaches
processes started *afterward*, and making an *already-running* process
pick up new colors needs an actual live `SetSysColors()` call from
inside the same Wine session - nothing short of a real running `.exe`
can do that. `setsyscolors.exe` is a small, no-CRT, hand-built PE binary
(`tools/build_setsyscolors.sh`) that parses `Name=R,G,B` arguments off
its own command line and calls `SetSysColors()` once - that's all it
does now; it used to also `EnumWindows` + `DrawMenuBar` on every window
to work around the non-client-repaint gap `0051` (below) now fixes
upstream instead.

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

- **`patches/0050-win32u-invalidate-the-per-process-sys-color-cache-o.patch`**:
  each process caches every system color (and any `HBRUSH`/`HPEN` built
  from it) the first time it reads one (`dlls/win32u/sysparams.c`,
  `get_rgb_entry`/`get_sys_color_brush`), and nothing ever invalidated
  that cache in response to `WM_SYSCOLORCHANGE` - a window that had
  already read `COLOR_MENUBAR` once kept returning the same stale value
  and the same stale brush forever, regardless of how many times
  `SetSysColors` was called from elsewhere. Fixed by resetting every
  entry's cache from `dlls/win32u/message.c`'s `call_window_proc` - the
  common delivery point for every message reaching a window procedure
  regardless of same-thread/cross-thread/cross-process origin - right
  before `WM_SYSCOLORCHANGE` reaches it, in the *receiving* process.
- **`patches/0051-win32u-include-the-non-client-area-in-setsyscolors.patch`**:
  `NtUserSetSysColors` already tried to force a repaint after a color
  change, but its `RedrawWindow` flags (`RDW_INVALIDATE | RDW_ERASE |
  RDW_UPDATENOW | RDW_ALLCHILDREN`) only reach client areas -
  `RDW_FRAME` (the non-client area, where a native menu bar actually
  lives) was missing. One flag added.

### Known limitation: presentation latency

Even with both patches, the actual on-screen pixels can still take
anywhere from well under a second to several seconds to become visible
after a real theme switch - measured directly, not a fixed interval,
and reproducible with zero user interaction at all (so it's not a
"needs a click to wake up" requirement, just a very unreliable delay).
Two additional fixes were tried and **reverted** because they measurably
made no difference in the real `theme_watch_loop`-driven path, despite
looking successful in isolated manual testing: `RedrawWindow(...
RDW_UPDATENOW...)` and a synthetic `SendInput` mouse nudge, both from
`setsyscolors.exe`. Not yet root-caused. One concrete, untested lead:
`theme_watch_loop`'s invocation is a fully detached background process
(`( theme_watch_loop ) </dev/null >/dev/null 2>&1 &`, no controlling
terminal) while the manual tests that looked successful were run from
an interactive shell - that distinction was raised but never actually
isolated.

This is a different, later-stage gap from the one in
`FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md`: that document
covers the *earlier* stage (nothing observable happens at all until the
Preferences dialog closes and `Preferences.cfg` is written); this
section covers the delay *after* that write is observed and
`setsyscolors.exe` has already been invoked.

## Substituting Live's own font

`sync_font_substitutes()` / `sync_metric_fonts()` (`scripts/ableton-live`,
issue #32) symlink Live's own `AbletonSans*.ttf` faces into the prefix's
Fonts directory and repoint `MS Shell Dlg`/`MS Shell Dlg 2` plus the
`WindowMetrics` non-client `LOGFONT`s (`MenuFont`, `MessageFont`,
`CaptionFont`, and the rest) at whichever face is present (`Ableton Sans
Small`, falling back to plain `Ableton Sans`), so the chrome matches
Live's own UI instead of rendering stock Tahoma.

Both faces cover Latin script only - checked directly against the font
files' own `cmap` tables: Basic Latin, Latin-1, Latin Extended-A/B, and
a handful of Greek symbols. Zero glyphs in Cyrillic, Arabic, Hebrew,
Devanagari, Thai, CJK, or Hangul.

The substitution has a second effect beyond narrowing glyph coverage.
Wine's built-in Unicode/CJK fallback population (`dlls/win32u/font.c`,
`load_system_links`) is keyed by string-comparing the current `MS Shell
Dlg` substitute against a small fixed list of recognised names
("Tahoma", "MS UI Gothic", "SimSun", "Gulim"). Once that substitute is
anything else, none of those matches fire and the whole population step
silently does nothing.

## Falling back for missing glyphs

`sync_font_fallback()` (`scripts/ableton-live`) registers Wine's real,
general font-linking mechanism -
`HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`,
which unlike the hard-coded population above works for any font name -
with a two-entry chain for whichever family was just substituted in:

1. **Tahoma**, Wine's only bundled font with real non-Latin coverage
   (checked: 104 Cyrillic + 162 Arabic glyphs).
2. **Whatever CJK font the host has installed**, found via `fc-match -f
   '%{file}'/'%{family}' ':lang=ja'` and symlinked into the prefix's
   Fonts directory. Best-effort: skipped silently if `fc-match` is
   unavailable or the host has no CJK font, which leaves the prefix
   exactly where a stock Wine install would be - Wine bundles no CJK
   font at all, so this is strictly additive.

Registering the chain alone made no visible difference. `WINEDEBUG=+font`
confirmed Wine loads it and resolves it to real font files, including
correctly picking the Japanese face out of a 5-face `.ttc` collection,
yet menu text needing those glyphs still rendered as tofu. `SystemLink`
is only consulted by `can_select_face` during whole-font *selection*,
gated on the system ANSI codepage matching a *requested* charset, never
during glyph *rendering* (`dlls/win32u/freetype.c`,
`dlls/user32/text.c`). The actual lookup, `freetype_get_glyph_index`, is
a direct FreeType charmap query against the single already-selected
font, with no awareness of any linked fallback, and `DrawTextExW` - what
the menu-drawing code calls - has no substitution logic of its own. A
registered chain fixes nothing until something walks it per string
drawn.

**`patches/0054-win32u-fall-back-to-a-linked-font-for-missing-glyph.patch`**
adds that missing consumer in `dlls/win32u/menu.c`'s `draw_menu_item`,
the same function `0049` already touches for the disabled-text bevel:

1. `get_fallback_font_for_text()` tests whether the selected font can
   render the item's text at all, via `NtGdiGetGlyphIndicesW` with
   `GGI_MARK_NONEXISTING_GLYPHS` (`font_GetGlyphIndices` also only ever
   checks the one selected font, which is exactly the per-font coverage
   test wanted). Control characters (`< ' '`) are excluded: item text
   carries its raw `'\t'`-separated shortcut column, no font has a
   renderable glyph for a literal tab, and flagging it as missing failed
   every otherwise-covered string that happened to show a shortcut.
2. If something is missing, it walks that font's registered `SystemLink`
   families (`get_font_link_families()`, new in `dlls/win32u/font.c` - a
   thin accessor over what `find_gdi_font_link` already tracks
   internally and is otherwise unreachable outside that file) and
   temporarily selects the first candidate that covers the text,
   matching size and weight via `NtGdiExtGetObjectW` +
   `NtGdiHfontCreate` as this file already does for its Marlett-glyph
   drawing, for that item's `DrawTextW` calls, then restores and deletes
   it.

`NtGdiExtGetObjectW` returns the resolved *face* name (e.g. `"Ableton
Sans Small Regular"`), not the family name the chain is registered under
(`"Ableton Sans Small"`), so the code strips a known style suffix
(`" Regular"`, `" Bold"`, `" Italic"`, `" Bold Italic"`, `" Regular
Italic"`) and retries before giving up.

The same patch also fixes CJK menu-item truncation, reported against it
after it shipped (issue 35): first and last characters missing on
centered menu bar items, cut off on the right on left-aligned popup
items - `"オプション"` showing as `"プショ"`. `calc_menu_item_size`, which
sizes `item->rect` and shares this file with `draw_menu_item`, measured
`item->text` with whatever font was already selected in `hdc` - the
original font, never the fallback `draw_menu_item` actually renders
with. A fallback font's real glyphs are typically wider than the
original's notdef metrics, so `item->rect` came out sized for the wrong
font and `DrawTextW` clipped the wider render to fit. Fixed by
forward-declaring `get_fallback_font_for_text` and calling it in
`calc_menu_item_size` before measuring, the way `draw_menu_item` already
calls it before drawing; both call sites select the same plain
(non-bold) menu font into `hdc` first, so the two selections stay in
lockstep.

Live's own browser panel, track list, and other in-app UI were never
affected and needed no fix - that is Live's bundled Skia + HarfBuzz +
FreeType stack, a separate rendering path from the win32 chrome these
patches touch, and it already has correct font fallback.

### Known limitation: whole-string swap

Text mixing scripts - an English label concatenated with a non-Latin
project or track name - renders *entirely* in the fallback font rather
than mixing faces mid-string. Real per-glyph fallback is a
Uniscribe/DirectWrite-level feature plain `DrawTextW` has never had, and
implementing it properly means splitting a string into per-script runs
and drawing each with its own face. This trades a rarer, minor
font-consistency slip for the text rendering at all.

### Dead end: the suspected wrong glyph

Investigated 2026-07-23, after the truncation fix. The File menu's
`パックをインストール...` ("Install a Pack...") appeared from a screenshot
to render its first character as `バ` (U+30D0) instead of the correct
`パ` (U+30D1). `WINEDEBUG=+menu` confirmed the raw string Ableton hands
to Wine is already correct (`debugstr_menuitem`'s `Text=` field shows
`\30d1` first), and the fallback font in use, Noto Sans CJK JP, has
distinct correct glyphs for both codepoints (fontTools cmap: U+30D0 ->
1601, U+30D1 -> 1602). A genuinely wrong render would have meant a deep
Wine bug, most likely a stale glyph or font cache, since
`get_fallback_font_for_text` creates a fresh throwaway `HFONT` per item.

It was a misread. `パ`'s handakuten (small circle) and `バ`'s dakuten
(two short strokes) are easy to confuse at screenshot scale; zooming in
confirmed the circle is there. No action taken.

## Hiding the alt-key mnemonic underlines

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
wiring, propagation through every window - so
**`patches/0052-win32u-hide-the-menu-bar-alt-key-mnemonic-underline.patch`**
just permanently hides them instead, which is the actual visual result
that was asked for.

Two parts, because the first alone turned out to be a no-op:

1. `dlls/win32u/menu.c`'s `draw_menu_item` adds `DT_HIDEPREFIX` to the
   menu bar's `DrawTextW` format flags (menu bar only - popup/dropdown
   items keep their mnemonics, where Alt-key in-menu navigation is
   still commonly used).
2. `DT_HIDEPREFIX` turned out to be a *dead flag* in this tree: defined
   in `winuser.h`, but the actual underline-drawing call site in
   `dlls/user32/text.c` only ever checked `DT_NOPREFIX` - not
   equivalent, since that stops `&` being treated as an escape at all
   and would show a literal `&` in the text instead of just hiding the
   underline. Fixed by gating the underscore-drawing call on
   `DT_HIDEPREFIX` too, leaving `&`-stripping and prefix-offset tracking
   (already unaffected by this flag) exactly as before.

Verified live: the top-level bar (File/Edit/Create/...) no longer shows
underlines; an open dropdown's own items still show theirs.

## File map

| file | role |
|---|---|
| `scripts/ableton-live` | `sync_win32_colors`, `blend_gray_text`, `resolve_live_topbar`, `ensure_flat_menu`, `theme_watch_loop`, `theme_watch_prefs_cfg`, `sync_font_substitutes`, `sync_metric_fonts`, `sync_font_fallback` |
| `scripts/detect-theme.sh` | `ableton_live_theme_file`, `ableton_ask_color`, `ableton_newest_prefs_dir`, `ableton_detect_theme`, `ableton_detect_topbar_colors` (host-theme detection, used by `ABLETON_TOPBAR_MODE=system`) |
| `tools/setsyscolors.c` + `build_setsyscolors.sh` | the live `SetSysColors()` call itself; a small no-CRT PE binary, rebuilt independently of the Wine tarball |
| `patches/0049-*.patch` | drops the grayed-item engraved-bevel double-draw |
| `patches/0050-*.patch` | per-process sys-color/brush/pen cache invalidation on `WM_SYSCOLORCHANGE` |
| `patches/0051-*.patch` | `RDW_FRAME` in `NtUserSetSysColors`'s forced repaint |
| `patches/0052-*.patch` | hides the menu bar's alt-key mnemonic underlines (`DT_HIDEPREFIX`, plus making that flag actually work in `dlls/user32/text.c`) |
| `patches/0054-*.patch` | walks the `SystemLink` chain for menu text the selected font cannot render, and sizes items with the same fallback font. On `language-fallback`, not in `main` |

## Debugging notes for whoever touches this next

- This launcher defaults `WINEDEBUG=-all` (`scripts/ableton-live`,
  suppressing everything including `err`, unless the caller already
  exports a value). A plain `ableton-live` launch with no `WINEDEBUG`
  set will never show `ERR()`/`FIXME()` output at all, your own debug
  instrumentation included. Always launch with an explicit
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
  re-export before rebuilding, even for a one-line tweak.
- This is not a substitute for the real tarball/`install.sh` path
  before calling anything actually fixed - it's for iteration speed
  only, and easy to leave stale debug instrumentation in if you forget
  to do a final clean rebuild + real install before finishing.
