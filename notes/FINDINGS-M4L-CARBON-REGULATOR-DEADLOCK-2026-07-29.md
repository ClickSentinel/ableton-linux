# Max for Live hangs: a generic MaxPlug deadlock, not a device-specific bug (2026-07-29)

Follow-up to [FINDINGS-M4L-SEEK-FREEZE-2026-07-22.md](FINDINGS-M4L-SEEK-FREEZE-2026-07-22.md). Two conclusions change.

**The hang is a blocked wait, not a runaway loop.** The older document's findings 5 and 16 read it as an *active spin* — "roughly 30 AudioCalc threads all actively accumulating CPU" plus "an exact 3-address cycle repeating eight consecutive times ... a strong signature of a genuine loop". Resolving the backtrace against the actual Wine PE exports, and then measuring per-thread CPU during a live hang, shows both readings were wrong. The UI thread is parked in a condition variable and burns exactly zero CPU; the "repeating cycle" is an ordinary bounded recursive descent.

**It is not about Carbon Regulator, or Creative Extensions, or any particular device.** Two racks that share no M4L device whatsoever both hang, converging on the identical MaxPlug wait. See "DECISIVE: Stabbed Bass" below. The device-specific framing that has driven this investigation since 2026-07-22 was an artefact of sampling.

Read this note in order: the early sections build a device-level theory that the later sections falsify. The mapping of modules to devices remains factually correct and is worth keeping; the causal conclusion drawn from it is not. Everything else in the older note (the repro, the ENCORE cross-build result, the charset dead end) still stands.

## Method

The committed capture `winedbg-00fc-only.log` (2026-07-22, 90 threads of process `00fc`) carries only `module (+offset)` frames. Offsets were resolved against the export tables of the matching build's PE modules under `~/.local/opt/wine-d2d1-nspa-11.13/lib/wine/x86_64-windows/` via `objdump -p`, taking the nearest preceding export. Every hit landed at `+0x14` into a syscall stub or within a few hundred bytes of an export, so the resolution is exact rather than approximate.

## The main thread is blocked, not spinning

Frames 0-3 of thread `0100`:

```text
0  ntdll       ZwWaitForAlertByThreadId +0x14
1  ntdll       RtlWaitOnAddress +0x16d
2  ntdll       RtlSleepConditionVariableCS +0x36
3  kernelbase  SleepConditionVariableCS +0x2c
4  maxplug     +0x14b619a
```

That is a Win32 condition-variable wait entered from MaxPlug's own code. It is not a spin, and there is no charset call, no timer, and no RPC on the path.

The CPU that finding 5 measured is real but belongs elsewhere. Thread `0214` is mid-`cartopol~.mxe64` under `pfft~.mxe64` under `maxaudio` — genuine spectral DSP work — which is exactly why audio keeps playing while the window is frozen. The AudioCalc pool spinning is the *symptom of audio still running*, not the hang.

## The "repeating loop" is bounded recursion

Frames 34-59 repeat `maxplug+0x880f02 / +0x8822a4 / +0x880b6c`. The stack addresses winedbg prints for those frames form a clean arithmetic progression with a step of `0x180`:

```text
0x10c280, 0x10c400, 0x10c580, 0x10c700, 0x10c880, 0x10ca00, 0x10cb80, 0x10cd00
```

Equal-sized nested frames, eight levels, terminating. That is a recursive walk over a nested patcher hierarchy, which is entirely normal for Max. It is finite and it is not what is wrong. (One caveat: the interleaved `+0x880f02` frames all print a constant `0x10cee8`, which does not fit a pure frame-pointer reading, so treat the exact nesting semantics as "repeated nesting of fixed-size frames" rather than a proven call-graph shape. The bounded-and-blocked conclusion does not depend on it.)

## The full call chain

Read outermost to innermost, with every symbol resolved:

```text
ableton live 12 suite            (message pump)
  win32u  NtUserPeekMessage
  ntdll   KiUserCallbackDispatcher
  user32  window proc  <- msg 0x0401 = WM_USER+1
ableton live 12 suite            (handler for that message)
  win32u  NtUserMoveWindow       <- moves a window
  ntdll   KiUserCallbackDispatcher
  user32  window proc  <- msg 0x0085 = WM_NCPAINT
maxplug                          (Max's window proc)
  ... 8 levels of bounded recursive descent ...
  jsui.mxe64                     <- Color Limiter's meter
  mozjs185-1.0                   <- Max's JS engine
  js.mxe64                       <- Poli
maxplug  (19 frames)
  kernelbase  SleepConditionVariableCS   <- PARKED HERE
```

Two things matter about this shape.

First, the `WM_USER+1` at the top is a *cross-thread* `SendMessage`. Thread `01c8` is sitting in `user32 SendMessageW +0x3b` -> `win32u NtUserMessageCall`, blocked waiting for the UI thread to finish handling it. So the UI thread is inside a synchronous inter-thread send when it parks.

Second, the `WM_NCPAINT` is delivered synchronously from inside `NtUserMoveWindow`. So Max's paint runs re-entrantly, nested two message-callbacks deep, on a thread that cannot pump messages while it is blocked. Anything that needs to signal that condition variable and that also needs the UI thread deadlocks by construction.

## Which device supplies which module

`Carbon Regulator.adg` is a rack, not a single device. Decompressing it (`.adg` is gzipped XML) shows it hosts exactly three Max devices: **Poli** (instrument), **Color Limiter**, and **Spectral Blur**. Profiling the object classes inside all eight `.amxd` files in Creative Extensions gives a clean one-to-one mapping onto the unusual modules in the hang backtrace:

| Module in backtrace | Only device in the pack that supplies it |
| --- | --- |
| `jsui.mxe64` | **Color Limiter** (the only `.amxd` containing `jsui`, 2 instances) |
| `js.mxe64` | **Poli** (the only one containing a `js` object) |
| `pfft~.mxe64`, `cartopol~.mxe64` | **Spectral Blur** (the only one containing `pfft~`) |

Every exotic external on the hung stack is accounted for by one of Carbon Regulator's three devices. Nothing on the stack comes from anywhere else.

## The jsui object is a gain-reduction meter, and its code is clean

Color Limiter's two `jsui` objects load `grmeterbg.js` and `grmeter.js`, both embedded in the `.amxd` after the patcher JSON. The whole of `grmeter.js` is 44 lines:

```js
mgraphics.init();
mgraphics.relative_coords = 0;
mgraphics.autofill = 0;
var grval = 0;

function paint() {
    with (mgraphics) {
        set_source_rgba(fillcolor);
        set_line_width(10);
        arc(82.5, 120, 82.5, degtorad(228), degtorad(228+grval));
        stroke();
    }
}

function msg_float(x) {
    grval = x;
    mgraphics.redraw();
}
```

No loops, no recursion, no allocation, no string handling. It repaints an arc whenever the limiter pushes it a new gain-reduction value — which, on a limiter, is continuously. This is about as benign as M4L JS gets, and it makes "the device's own code is simply broken" (old note, hypothesis 3) much harder to sustain. What it does do is drive `mgraphics.redraw()` at a high rate into Max's paint path, which is precisely the path that deadlocks.

`jsui.mxe64` imports only `MaxAPI.dll`, `mozjs185-1.0.dll` and CRT stubs, so its drawing goes through MaxPlug's graphics layer. `MaxPlug.dll` (31.6 MB, Max 9.1.4) imports **`dxgi.dll`** and **`OPENGL32.dll`**.

## Supporting signal from the Max and Live logs

`~/.wine-ableton/drive_c/users/lgillingham/AppData/Roaming/Cycling '74/Max 9/Logs/` holds six rotated `MaxPlug.*.log` files. Only one of the six ever initialises OpenGL, and it is the only one that stops dead instead of ending on the usual `DrawPushScreen not implemented` line:

```text
[2026-07-29 16:15:40.163046 info] [272] OpenGL Version 4.6 (Core Profile) Mesa 26.1.5 - kisak-mesa PPA, GLSL Version 4.60
[2026-07-29 16:15:40.266868 info] [272] ERROR: typeface name Bitstream Vera Sans with style Regular not found!
[2026-07-29 16:15:40.266880 info] [272] NOTE: system has 289 typefaces
<end of file>
```

Live's own `Live 12.4.3/Preferences/Log.txt` stops at `16:15:12`, 28 seconds *before* that GL init, with no error. The correlation is suggestive, not proof — the other five sessions may simply never have loaded a `jsui` device — but "Max brings up an OpenGL context and both logs then go silent" is worth confirming deliberately.

Also worth noting and not yet explained: that session's memory climbs 1 GB -> 6.4 GB in about 45 seconds of loading.

Max's renderer additionally runs a thread (`03a8`) inside `maxplug -> dxgi -> Sleep`, which resolves to `dxgi_output_WaitForVBlank` — a Wine **semi-stub** that does nothing but `Sleep(16)` (`dlls/dxgi/output.c:371`). Max is frame-pacing against a vblank that Wine does not actually implement.

## Working hypothesis (FALSIFIED — see "Stabbed Bass" below)

The hypothesis this note originally advanced was that Color Limiter's `jsui` meter drives `mgraphics.redraw()` continuously, and that servicing that redraw re-entrantly parks the UI thread. **A direct test killed it.** The device-level mapping in the two sections above is still factually correct — those modules really do come from those devices — but it is not the cause. Keep the mapping, discard the conclusion.

## CONFIRMED by a second live capture (2026-07-29 17:03)

A fresh capture during a new hang (`m4l-hang-20260729T170321/`, via `tools/m4l-hang-capture.sh`) settles the one open question and confirms the whole reading.

**The hang is bit-for-bit deterministic.** Different Live process (`0114` vs `00fc`), different module load addresses a week apart — yet identical module *offsets* on every frame, identical 87-frame depth, identical eight-level recursion, and even identical frame-pointer values (`0x10c280, 0x10c400, ...`). `WM_NCPAINT (0x85)` at frame 64, `NtUserMoveWindow` at frame 68, `WM_USER+1 (0x401)` at frame 77, exactly as before.

**The UI thread is genuinely blocked, and the old note's CPU evidence was misattribution.** Two samples ten seconds apart:

- Of Live's 92 threads, **89 had byte-identical stacks**; the two that moved are ordinary Ableton workers, unrelated to the hang.
- The UI thread (wine tid `0118`) was byte-identical across both samples.
- The process's real main thread is the lowest Linux tid, `3413122`. Its CPU went **4585 -> 4585 jiffies: exactly zero over ten seconds.**

The reason finding 5 of the old note saw "a MainThread actively consuming CPU" is that **Ableton names 46 separate threads `MainThread`**. The busy one (`3413608`, +32 jiffies) is a background worker, not the UI thread. Identifying the UI thread by name is unreliable here; it must be found by lowest tid or by deepest stack. There is no spin. This is a hard deadlock.

**Both partner threads reappear unchanged:**

- Wine tid `01dc` — blocked in `user32 SendMessageW +0x3b` -> `win32u NtUserMessageCall`, the same 5-frame shape and the same Ableton call site (`+0x31936a0`) as `01c8` in the older capture. This is the `WM_USER+1` sender, waiting on the UI thread that can no longer pump.
- Wine tid `040c` — `maxplug+0x89cb4f` -> `dxgi` -> `Sleep`, Max's renderer inside `dxgi_output_WaitForVBlank`. Its stack is *also* identical across the ten seconds, even though `Sleep(16)` returns every 16 ms. So Max's render thread is going round its vblank loop without ever making progress, while the UI thread waits.

That pairing — UI thread parked in a MaxPlug condition variable during a re-entrant paint, render thread circling a vblank that Wine only stubs — is the most likely shape of the deadlock, though which thread owns the condvar is still not proven.

## DECISIVE: Stabbed Bass hangs too — this is a generic M4L deadlock

`m4l-hang-20260729T171059/`, captured while `Racks > Sounds > Synth Rhythmic > Stabbed Bass` was hung in a brand new empty set.

Stabbed Bass shares **no M4L device at all** with Carbon Regulator (Bass, Pitch Hack, Re-Enveloper vs Color Limiter, Poli, Spectral Blur). Its hung UI thread stack contains **zero** `jsui`, `js.mxe64`, `mozjs185`, `pfft~` or `cartopol~` frames. The `jsui`/JS/OpenGL theory is dead.

What survives is far more interesting: **both hangs converge on the same MaxPlug wait.** Frames 0-18 are byte-identical between the two, despite entirely different devices and a 20-frame difference in total depth:

```text
0  ntdll       ZwWaitForAlertByThreadId
1  ntdll       RtlWaitOnAddress
2  ntdll       RtlSleepConditionVariableCS
3  kernelbase  SleepConditionVariableCS
4  maxplug     +0x14b619a          <- identical offset in both
5  maxplug     +0x730fd0
6  maxplug     +0x700174
7  maxplug     +0x71ccb1
8  maxplug     +0x7314de
...  through +0x72d37e, +0x730ff1, +0x700174, +0x71ccb1, +0x7314de,
     +0x8508f3, +0x1142d6, +0x85093e, +0x72d744, +0x733a2b
```

Above frame 18 the two diverge — Carbon Regulator goes out through `jsui`/`mozjs`/`js.mxe64` and a `WM_NCPAINT` nested inside `NtUserMoveWindow`; Stabbed Bass goes out through `patcher+0xc295` and twelve recursive frames of Ableton's own `+0x30c9f49` under `NtUserGetMessage`. Two different routes into one shared deadlock.

Everything else matches exactly:

- UI thread (wine tid `0110`) stack byte-identical across ten seconds.
- Main Linux thread CPU **1038 -> 1038 jiffies: zero**.
- Entered from **`WM_USER+1` (0x401)** on the UI thread, same as both earlier captures.
- Same blocked sender: wine tid `01d8`, `SendMessageW` -> `NtUserMessageCall`, same Ableton call site `+0x31936a0`.
- Same Max renderer thread: wine tid `03dc`, `maxplug+0x89cb4f` -> `dxgi` -> `Sleep` (`dxgi_output_WaitForVBlank`).

**The device is irrelevant.** This is a Max for Live deadlock in MaxPlug's core, reached whenever a device is instantiated. The "specific devices" framing that has driven this investigation since 2026-07-22 was an artefact of which devices happened to get tested.

## ROOT CAUSE (confirmed by fix): Max's font fallback chain terminates at a font that no longer exists

**Installing `ttf-bitstream-vera` fixes the hang.** Verified: Stabbed Bass, which hung 100% reliably, now loads and runs. The Max log proves the mechanism precisely — Geneva *still* fails, but the session continues past it:

```text
ERROR: typeface name Geneva with style Regular not found!
NOTE: system has 292 typefaces          <- was 289
[... session continues normally ...]
```

Before the fix there were two errors (the requested face, then `Bitstream Vera Sans`) and then silence. After, only the first remains. The deadlock needed **both** the requested face *and* the terminal fallback to be missing.

The causal chain:

1. Max patches name third-party typefaces — **Lato**, **Consolas**, **Geneva**. None ship with Live, none ship with Wine, none are among the prefix's 40 fonts (MS corefonts + Ableton Sans + Noto CJK + unifont).
2. On real Windows this never surfaces: GDI's font mapper never fails. `CreateFontIndirect` always returns *some* face, silently substituting. Max never learns the font was missing.
3. Under Wine the lookup honestly reports failure, so Max walks its **own** hardcoded fallback chain. `strings MaxPlug.dll` confirms the terminal entries are baked into the binary:

   ```text
   Bitstream Vera Serif
   Bitstream Vera Sans Mono
   Bitstream Vera Sans
   ```

4. Bitstream Vera is a 2003-era open family that is **not** part of MS corefonts and is shipped by neither Wine nor Live. Worse, modern distros ship its *successor* DejaVu, not Bitstream Vera itself — so the chain's last resort is absent on essentially every current Linux system.
5. Chain exhausted, MaxPlug's font resolution parks the UI thread on a condition variable (`maxplug+0x14b619a` -> `SleepConditionVariableCS`) and never signals it. Zero CPU, deterministic, permanent.

**So the bug is Max's, not Wine's.** Wine's only contribution is reporting the failure accurately where Windows silently papers over it — arguably the more correct behaviour, which happens to expose a latent MaxPlug defect. That is exactly why it reproduced identically under ENCORE: nothing about it is patch-stack-specific, and no Wine patch was ever going to fix it.

It also retroactively explains the two hangs' different log signatures. Carbon Regulator's devices request **Lato** and **Consolas** but not Geneva — and its log showed only a `Bitstream Vera Sans` error. Stabbed Bass's devices request **Geneva** — and its log showed Geneva *then* `Bitstream Vera Sans`. Different primary face, same terminal failure.

## Scope

Only three requested faces are genuinely unavailable. `Ableton Sans Medium` / `Book` look alarming in the patch files but are red herrings — Live ships 28 Ableton Sans files (including `AbletonSansMedium-Regular.otf` and `AbletonSansBook-Regular.otf`) and registers them at runtime.

Per device, across Creative Extensions' eight M4L devices:

| Device | Missing face requested | Affected |
| --- | --- | --- |
| Color Limiter | Lato x17 | yes |
| Spectral Blur | Lato x15 | yes |
| Poli | Consolas x11 | yes |
| Bass | Geneva x9 | yes |
| Re-Enveloper | Geneva x2 | yes |
| Gated Delay | none | **no** |
| Pitch Hack | none | **no** |
| Melodic Steps | none | **no** |

At rack level that is **51 of 61 racks affected, 10 safe** — and the ten safe ones are exactly those built solely from Gated Delay or Pitch Hack:

```text
Effect Racks/Modulation & Rhythmic/{2's and Four's, Are We Not, Dub Frolic,
                                    Duck and Cover, Spongecake Reversal}
Effect Racks/Performance & DJ/{A Larger Sky, Dawn Shimmers, Five versus Seven,
                               Ion Reversal, Trilogy Burnout}
```

This is the "specific ones crash" pattern, fully explained. The safe set is small and clustered in two effect-rack folders, which is why casual testing produced the impression that most things worked.

**Beyond this pack the scope is much wider than Creative Extensions.** The trigger is not these three fonts — it is *any* font a device requests that the prefix cannot resolve. Lato and Consolas in particular are common choices in third-party Max patches, so any M4L device naming a non-corefont typeface would have hung Live in exactly this way. Every M4L user on Wine without Bitstream Vera installed was exposed.

## The fix to ship

**The font family must genuinely exist as a file. `FontSubstitutes` does not work — tested and disproven.**

The obvious-looking fix was a registry alias, needing no new package since DejaVu is Bitstream Vera's metric-compatible successor and is present nearly everywhere:

```text
HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes
  "Bitstream Vera Sans" = "DejaVu Sans"   (plus Serif / Sans Mono, and Geneva, Lato, Consolas)
```

All six aliases were written and confirmed live in the registry. `ttf-bitstream-vera` was then removed so the aliases had to carry the load. **Live hung identically** — 67 frames, stack byte-identical across ten seconds, main thread 886 -> 886 jiffies, same `maxplug+0x14b619a`. Max's log still reported *both* names missing, including `Geneva`, which had a direct alias:

```text
ERROR: typeface name Geneva with style Regular not found!
ERROR: typeface name Bitstream Vera Sans with style Regular not found!
```

The reason: `FontSubstitutes` only redirects GDI `CreateFontIndirect` requests. It does **not** add names to `EnumFontFamilies` output. Max enumerates families itself — that is what its `system has N typefaces` line records — and matches requested names against its own copy of that list, so a substitution is invisible to it. This also explains why `Helvetica` counts as missing for Max despite Wine's stock `Helvetica -> Arial` substitute.

So the fix must place a real font file carrying the family name where Wine's enumeration will find it. Two options:

1. **Host package** — `sudo apt install ttf-bitstream-vera` (Fedora `bitstream-vera-fonts`, Arch `ttf-bitstream-vera`). Proven: this is what first fixed the hang. Downside: distro-dependent, needs root, easy for a user not to have.
2. **Prefix-local files, then registered** — put the unmodified Vera `.ttf` files in `$WINEPREFIX/drive_c/windows/Fonts/` **and register each face** under `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts`. Self-contained, no root, distro-independent. The Bitstream Vera licence explicitly permits redistribution of unmodified files (it restricts reuse of the "Bitstream Vera" name only on *modified* versions), and the family is roughly 500 KB.

**Copying the files alone is not enough** — an earlier draft of this note claimed it was, and that is wrong. Wine's font list is registry-driven: `HKLM\...\Fonts` held 733 entries pointing at `Z:\usr\share\fonts\...`, populated by a scan that had already happened, and files dropped in afterwards were never added. With the ten Vera files sitting in `drive_c/windows/Fonts/` and no registry entries, Max still reported 289 typefaces and still hung. After registering them: 292 typefaces, no `Bitstream Vera Sans` error, and Live stayed alive with the UI thread accumulating CPU normally.

Also tested and ruled out: pointing a registry entry named `"Bitstream Vera Sans (TrueType)"` at some other font file (e.g. DejaVu) does **not** work — Wine reads the family name from inside the file, so a made-up value name never enumerates. Verified with a throwaway `"ZZTestFamily"` entry aimed at `arial.ttf`, which did not appear. Real Vera files are unavoidable.

Option 2 is what shipped, in `setup-prefix.sh` (`install_maxplug_fallback_fonts`). It prefers `vendor/fonts/bitstream-vera/`, falls back to a system install, and warns loudly if neither is present. Repairing the terminal fallback fixes the whole class — every unresolvable font degrades to a substituted typeface instead of hanging — rather than chasing individual Mac fonts that cannot legally be shipped.

The `FontSubstitutes` aliases are harmless and can stay (they do help genuinely GDI-based lookups elsewhere in Live); they simply do nothing for Max.

### Verifying it

`tools/fontprobe.c` (build: `x86_64-w64-mingw32-gcc -O2 -o tools/fontprobe.exe tools/fontprobe.c -lgdi32`) enumerates families through the same `EnumFontFamiliesEx` Max uses, so it answers "would Max find this face?" without launching Live:

```text
$ wine tools/fontprobe.exe "Bitstream Vera Sans" Geneva Arial
398 families enumerated
  Bitstream Vera Sans              FOUND
  Geneva                           MISSING
  Arial                            FOUND
```

`tools/m4l-font-audit.py` scans every `.amxd` on the system, resolves each requested face against fontprobe's output unioned with Max's private font bundle, and reports hang risk. Exit 1 means the fallback chain is broken and devices will hang; exit 0 with findings means missing faces degrade to a substitute.

One subtlety it has to model: Max loads its own bundled faces (Ableton Sans, Lato) with `AddFontResourceEx`, so they are visible to Max but not to any other process. Without unioning those in, the ~60 devices using `Ableton Sans Medium` look broken when they are fine. Inferring availability from `fc-list` alone produced two wrong verdicts before the probe existed — it cannot see registration state, and it counted unregistered files in the Fonts directory as available.

## Superseded: the font correlation as originally recorded

Across the six rotated `MaxPlug.*.log` sessions in the latest capture, the terminal log line correlates perfectly with the outcome:

| sessions | last event | outcome |
| --- | --- | --- |
| `MaxPlug.log`, `.1`, `.3` | `ERROR: typeface name <X> with style Regular not found!` then `NOTE: system has 289 typefaces` | **hung** |
| `MaxPlug.2`, `.4`, `.5` | normal (`jpatcher_attrset...`, `DrawPushScreen not implemented`) | clean |

3/3 hangs, 0/3 clean sessions. The missing faces are **Geneva** (a classic Mac font) and **Bitstream Vera Sans**; neither exists in the prefix's 40 fonts nor anywhere in `fc-list`.

This also decouples the hang from OpenGL: `MaxPlug.log` hung with **no** `OpenGL Version` line at all, so the GL correlation noted earlier in this document is coincidence.

Treat this as a lead, not a conclusion. n=6 and it is confounded — a session that got far enough to fail a font lookup is also a session that got far enough to load a device. The UI thread's stack shows no font module by name, though MaxPlug is statically linked and stripped so font code would be indistinguishable from any other `maxplug+0x...` frame.

## Next steps, in priority order

**1. Is it all of Max for Live, or just this pack?** Load a stock M4L device that does not ship in Creative Extensions — anything from Max for Live Essentials, or one of Live's own bundled Max devices. If that hangs too, the issue is "M4L is broken under this build" rather than anything to do with Creative Extensions, which is a much simpler and much bigger bug report.

**2. (Ruled out) Is it a regression?** No. The user reports this behaviour has been present for as long as M4L has been used on this setup, so back-testing older builds is wasted effort. Not a regression; do not spend time bisecting the patch stack for it.

**3. Test the font lead directly.** Install the missing faces (Geneva has metric-compatible substitutes; `ttf-bitstream-vera` is packaged on most distros) and see whether the hang survives. Cheap, and it either promotes the correlation to a cause or kills it.

**4. A/B the render path.** `WINE_DISABLE_GL_PRESENT=1` (patch 0055) and `ABLETON_DCOMP=off`. Still worth running given Max's renderer sits in the stubbed `dxgi_output_WaitForVBlank` in all three captures.

**5. Only then, symbol-level work.** `MaxPlug.dll` is closed-source and stripped, so identifying what `maxplug+0x14b619a` waits on means a `WINEDEBUG=+sync` trace across the hang, or breakpointing `SleepConditionVariableCS` and dumping the CONDITION_VARIABLE address to find which thread owns it.

## Artifacts

- `winedbg-00fc-only.log` (repo root, gitignored) — the 2026-07-22 90-thread capture.
- `m4l-hang-20260729T170321/` — Carbon Regulator hang, two samples.
- `m4l-hang-20260729T171059/` — Stabbed Bass hang, two samples.
- `tools/m4l-hang-capture.sh` — produces the above in one shot.

## A note on method

Two theories died here in one session: "runaway loop" (killed by the zero-CPU measurement) and "Color Limiter's jsui" (killed by Stabbed Bass). Both had good-looking supporting evidence — a repeating call pattern, a clean one-to-one module-to-device mapping. What killed them was cheap differential testing, not more analysis of the same capture. Prefer the next negative control over the next trace.
