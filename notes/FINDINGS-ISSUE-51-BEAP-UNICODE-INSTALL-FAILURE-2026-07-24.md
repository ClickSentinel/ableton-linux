# Issue #51 investigation: BEAP Unicode filename install failure (2026-07-24)

## The report

https://github.com/shibco/ableton-linux/issues/51 (weatherglow22, Ubuntu
Studio, Surface Laptop 5, Live 12 Intro). During install, a repeating
"Select action" error dialog:

```
An error occurred while trying to rename a file in the destination directory:
MoveFile failed; code 2.
File not found.
```

on `C:\ProgramData\Ableton\Live 12 Intro\Resources\Max\resources\packages\
BEAP\clippings\BEAP\...` — a Max4Live BEAP clip resource. "Try again" loops
forever; "Skip this file (not recommended)" is the installer's own escape
hatch. shibco reproduced it locally, said a fix was in progress, then later
"Fixed in the forthcoming release, I think!" — issue is still **open**, no
commit references #51 yet as of `v2026.07.23.1` (checked full git log,
searched for #51 and for cabinet/codepage/OEM/short-name/GetShortPath/msi
keywords — nothing).

This is very likely the same underlying file that broke a different,
earlier-reported install (`bp.µSeq.maxpat`, U+00B5 MICRO SIGN) — same
`BEAP\clippings\BEAP\MIDI\` path, same MSI rename-failure shape, different
presentation (raw `msi:cabinet_copy_file` trace vs this Inno-style retry
dialog — different installer engine per edition/version, same class of bug).

## What's been ruled out (all tested, not inferred)

1. **Missing/wrong system locale in the wine/MSI layer.** The original
   report this pattern was first seen on had a confirmed, fully-generated
   `en_US.UTF-8` — not a locale gap.

2. **`unzip` mishandling the Unicode filename during `setup-run-header.sh`'s
   own bootstrap extraction** (`scripts/setup-run-header.sh:249`,
   `unzip -q "$live_zip" -d "$unpack_dir"` — the step that runs when a user
   places the raw Ableton `.zip` next to the installer, per the normal
   documented flow). Built a synthetic zip with an identical filename
   (`bp.µSeq.maxpat`, confirmed UTF-8 general-purpose flag bit set —
   `flag_bits & 0x800 == True`, matching modern zip-writer behavior) and ran
   the *exact* `unzip -q` invocation the installer uses:
   - **All four target distros** (Arch, Debian 13, Ubuntu 24.04, Fedora 44)
     extracted it identically and correctly: `bp.\xc2\xb5Seq.maxpat`, byte-
     perfect. Every one of them ships the same `UnZip 6.00 of 20 April 2009`
     Info-ZIP codebase (this hasn't had a new stable release since 2009;
     distros only carry security patches on top) — that's *why* they agree.
   - Locale made no difference either: tested completely unset (`arch-cloud`,
     `LANG=` empty), `C.UTF-8` (Debian/Ubuntu default), `en_US.UTF-8`
     (Fedora), and explicit `LC_ALL=C` forced (matching what
     `setup-run-header.sh` itself now exports, added in `d3c690c` — but
     that commit fixes a *different* bug, #36, French-locale breaking
     `readelf`/`ldd`/`sha256sum` *parsing*, unrelated to filename decoding).
     All four produced the same correct byte-perfect result regardless.
   - **Conclusion: for a UTF-8-flagged zip entry, neither distro nor locale
     affects `unzip`'s output at all.** This was the leading theory and it
     does not hold up under direct test.

3. **A stale/pre-#36-fix installer script.** Not applicable — testing was
   done against `v2026.07.23.1`, today's release, on the real packaged
   `install-ableton-latest.run` kit (not a raw git clone, which is missing
   the built `bin/ableton-linkd` binary and fails for an unrelated reason —
   see below).

4. **Full end-to-end reproduction attempt.** Ran the real
   `install-ableton-latest.run` → extracted kit → `scripts/install.sh` →
   `scripts/setup-prefix.sh` → the real `Ableton Live 12 Suite Installer.exe`
   (already-extracted `.exe`/`.bin` files, not a `.zip`) on `arch-cloud`,
   using the actual packaged `wine-d2d1-nspa-11.11` runtime (not our dev
   branch's `11.13`). **Installed clean, no error at all** — `bp.µSeq.maxpat`
   present and correct in the installed `BEAP/clippings/BEAP/MIDI/` tree.

## What's NOT ruled out — the real gap

Point 4's success and point 2's clean unzip tests both used files/zips
**we constructed or already had**, not the reporter's actual download.
Two live unknowns:

- **Whether Ableton's real distributed zip has the UTF-8 flag set on this
  entry at all.** Everything tested above assumed/confirmed a
  UTF-8-flagged entry. If Ableton's own packaging tool does *not* set that
  flag for this file (plausible — plenty of enterprise zip tooling still
  defaults to legacy 8-bit/OEM codepage encoding), `unzip` falls back to
  locale-driven guessing, and *then* distro/locale genuinely could matter —
  this is a completely different code path than what was tested. Can't
  confirm without a copy of the actual `ableton_live*.zip`, which needs a
  real Ableton account/license to obtain.
- **Whether the failure is actually downstream in Wine's own MSI/cabinet
  extraction**, not the bootstrap's `unzip` step at all — my original
  theory from the earlier locale investigation. Point 4 argues against this
  (real installer, real files, no failure) but doesn't fully rule it out if
  the trigger is something about the *zip-extracted* copy specifically
  (e.g. a subtly different byte sequence than our long-standing
  pre-extracted files have carried since whenever they were first unpacked).

## Practical workaround given to the user — CONFIRMED WORKING

Extract the zip yourself before running the installer (`unzip -O UTF-8` or
`bsdtar -xf`, either avoids the bootstrap's own extraction step entirely),
then run wine directly against the extracted `.exe` rather than going
through `install-ableton-latest.run`'s own zip-handling:

```
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.11/bin/wine \
  "/path/to/Ableton Live 12 Suite Installer.exe"
```

**The reporter confirmed this worked** — they installed successfully this
way. This was previously "logically sound but untested against their exact
files"; it's now verified against the real report, not just our synthetic
zip.

This doesn't nail down the exact internal mechanism (still can't inspect
their actual zip to confirm the UTF-8 flag bit), but it's strong practical
evidence for the "bootstrap's own zip-handling is where the corruption
happens, not Wine/MSI's cabinet extraction" side of the two remaining open
questions above — bypassing `setup-run-header.sh`'s `unzip` step entirely
(by extracting yourself, or in this case just already having an extracted
`.exe` to run) resolved it, while nothing about Wine/MSI itself changed.

## Next step, if this keeps coming up

Ask a future reporter (or weatherglow22 directly) to run, on their own zip,
before ever touching the installer:
```
python3 -c "
import zipfile
z = zipfile.ZipFile('/path/to/ableton_live*.zip')
for i in z.infolist():
    if 'clippings' in i.filename and 'µ' in i.filename:
        print(i.filename, bool(i.flag_bits & 0x800))
"
```
That one flag check resolves the remaining ambiguity directly — no VM lab
needed for it.

## Environment used for this investigation

- `arch-cloud`, `ubuntu2404-cloud`, `fedora-cloud`, `debian-cloud`
  (ableton-vm-tools, see /mnt/storage-2tb/GitHub/ableton-vm-tools)
- Pristine clone of `shibco/ableton-linux` main at `v2026.07.23.1`
  (`/mnt/storage-2tb/GitHub/ableton-linux-scratch`), separate from the
  working dev repo — used specifically so results reflect what a real
  default-path user has, not our `wine-11.13-*` dev branches.
- Real packaged `install-ableton-latest.run` + `wine-d2d1-nspa-11.11`
  release tarball, downloaded via `gh release download v2026.07.23.1`.
