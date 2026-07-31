# How the menu-bar font fallback works

Issue #35 point 5: non-Latin menu text - a non-Latin locale, a
translated menu, a non-Latin project or track name - rendered as tofu or
nothing at all. Colour theming of the same chrome is a separate system,
documented in `ABLETON-WINE-MENU-COLOR-THEMING.md`.

## Why the substitution broke non-Latin text

`sync_font_substitutes()` / `sync_metric_fonts()` (`scripts/ableton-live`,
issue #32) symlink Live's own `AbletonSans*.ttf` faces into the prefix's
Fonts directory and repoint `MS Shell Dlg`/`MS Shell Dlg 2` plus the
`WindowMetrics` non-client `LOGFONT`s at whichever face is present, so
the chrome matches Live's UI instead of stock Tahoma.

Both faces are Latin-only - checked against their `cmap` tables: Basic
Latin, Latin-1, Latin Extended-A/B, a few Greek symbols, and zero glyphs
in Cyrillic, Arabic, Hebrew, Devanagari, Thai, CJK or Hangul.

The substitution has a second, less obvious effect. Wine's built-in
CJK-fallback population (`load_system_links`, `dlls/win32u/font.c`) is
keyed by string-comparing the current `MS Shell Dlg` substitute against a
fixed list - "Tahoma", "MS UI Gothic", "SimSun", "Gulim". Once the
substitute is anything else, none of those match and the whole step
silently does nothing.

## The chain, and its actual consumer

`sync_font_fallback()` registers Wine's general font-linking mechanism,
`HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`,
which works for any font name, with a six-entry chain:

1. **Tahoma** - Wine's only bundled font with real non-Latin coverage
   (104 Cyrillic + 162 Arabic glyphs).
2. **Noto Sans CJK JP**, then **SC**, then **KR** - Live's own cuts from
   `Resources/Fonts`. The JP cut alone advertises `ja ko zh-cn zh-tw
   zh-hk`, so it is the one that answers in practice; the regional cuts
   differ only in which glyph shape wins for shared Han characters.
3. **Unifont-JP**, then **Unifont Upper** - Live's full-Unicode last
   resort. Blocky and fixed-width, but never tofu.

Registering that chain alone fixes **nothing**. win32u consults
`SystemLink` only when selecting a whole font by charset
(`can_select_face`, driven by the system ANSI codepage), never when
rendering a glyph. `patches/0054-*.patch` adds the missing per-string
consumer: `draw_menu_item` tests coverage with `NtGdiGetGlyphIndicesW`
and, on a miss, walks the registered families for the first that covers
the string. `calc_menu_item_size` measures with that same font, having
previously sized `item->rect` with the original and clipped the wider
fallback render ("オプション" truncating to "プショ").

## The name a chain entry must use

`load_system_links` resolves each entry with `find_face_from_filename`,
which matches the **file basename and the family name together**, and
the family win32u indexes a font under is `name` table **ID 1**. Get it
wrong and the entry is dropped at load with a single `Unable to find
file` trace line - no error, nothing visible except CJK text quietly
rendering in whatever later entry does resolve.

`fc-scan -f '%{family}'` reports the **ID 16** typographic name first,
and Live's `NotoSansCJKjp-Regular.otf` carries `"Noto Sans CJK JP
Regular"` in ID 1 with only the bare `"Noto Sans CJK JP"` in ID 16. So
the entry named no family win32u knew, was dropped, and Japanese fell
through Tahoma to Unifont - rendering, but blocky. `%{fullname}` tracks
ID 1 for every font in this chain and is what the launcher uses.

Proven causally in a prefix built with no host fonts at all, one
variable changed:

| registered family | result |
|---|---|
| `Noto Sans CJK JP` (ID 16) | `Unable to find file` |
| `Noto Sans CJK JP Regular` (ID 1) | `Adding file C:\windows\fonts\NotoSansCJKjp-Regular.otf` |

Two entries still fail where a host `fonts-noto-cjk` install displaces
Live's `sc`/`kr` cuts in the font index (`insert_face_in_family_list
Replacing original ... with Z:\usr\share\fonts\...`), so their basename
no longer matches. Harmless - `jp` answers first.

## Why the fonts come from Live, not a vendored copy

Live ships Noto Sans CJK because its own UI is localized into Japanese
and Chinese, so the files are present whenever Live is, and
`sync_ui_font`'s auto path already returns early unless
`Resources/Fonts` exists. Both weights are linked, so bold menu items
get a real bold face. Reading known files directly with `fc-scan` -
never asking the host's fontconfig for a *match* - is what makes the
chain identical on every distro.

An earlier revision vendored Noto Sans CJK v2.004 into the runtime
(sha256-pinned `.ttc` files under `vendor/noto-cjk/`). Dropped: ~24 MB
compressed on every release, a 40% larger runtime tarball, to replace a
font already on disk. Live's is v1.004 against that v2.004 and the two
differ by under 1% of pixels on the same string. Determinism was the
argument, but Live's copy is pinned to the Live version and is not
host-dependent either.

## Known limitation: whole-string swap, not per-character

Mixed-script text (an English label concatenated with a non-Latin track
name) renders *entirely* in the fallback face. Real per-glyph fallback
is a Uniscribe/DirectWrite-level feature that plain `DrawTextW` - what
`draw_menu_item` calls - has never had.

Tested 2026-07-28 before deciding whether to build the per-run version:
`"Live マニュアルを表示..."` as one whole-string swap versus split into a
Latin run and a CJK run, both measured against the real
`NONCLIENTMETRICS` menu `LOGFONT`, produced visually indistinguishable
output. Not worth a `menu.c` change on that evidence.

## The chain was silently truncated at four entries

`get_fallback_font_for_text` sized its candidate array `WCHAR names[4]`,
so only the first four entries were ever tried, with no diagnostic. The
chain is six, putting both Unifont entries out of reach - had the CJK
candidates failed the result would have been tofu, not a Unifont
fallback. Raised to 16, which covers any chain the launcher builds and
leaves room for Wine's own longer built-in ones (stock `Lucida Sans
Unicode` is nine).

Verified end to end: with host CJK hidden, no Noto in the prefix, and a
chain crafted so the only covering font sat at position five
(`Tahoma, Arial, Courier New, Times New Roman, Unifont-JP`), Japanese
rendered. Unreachable under the old cap.

## Testing gotcha: Wine sees the host's fonts

Wine exposes the **host's** installed fonts to the prefix via
fontconfig, not just `drive_c/windows/Fonts`. Any A/B test of prefix
fonts on a host carrying a same-named font silently renders the host
copy in both arms. Three separate comparisons were lost to this.

`FONTCONFIG_FILE` alone is **not** enough. Wine persists what it found
into the prefix registry - `"Noto Sans CJK JP (TrueType)"="Z:\usr\share\
fonts\opentype\noto\NotoSansCJK-Regular.ttc"` under
`HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts`, 936 such
entries in one real prefix - and reads them back by path regardless of
what fontconfig now reports. A prefix that has ever seen the host's
fonts stays contaminated.

To test in isolation, build a **fresh** prefix with `FONTCONFIG_FILE`
already pointing at a config with no font directories, then confirm
`grep -c 'usr.*share.*fonts' system.reg` is 0. `load_system_links` runs
in any Wine process, so `wine notepad` is enough to trace a chain - no
need to start Live.

## File map

| file | role |
|---|---|
| `scripts/ableton-live` | `sync_ui_font` links Live's faces into the prefix; `sync_font_fallback` registers the `SystemLink` chain |
| `patches/0054-*.patch` | the per-string fallback consumer in `draw_menu_item`, `calc_menu_item_size` measuring with it, and the 16-entry candidate cap |

## Debugging notes for whoever touches this next

- `WINEDEBUG=+font` and grep `load_system_links`: each entry logs either
  `Adding file` or `Unable to find file`. That line is the fastest way
  to tell a naming problem from a rendering one.
- `insert_face_in_family_list` shows which family each file is indexed
  under - the authoritative answer for what a chain entry must name.
- A chain entry that fails is silent in normal use. If non-Latin text
  looks blocky rather than absent, it resolved to Unifont, which means
  an earlier entry was dropped.
