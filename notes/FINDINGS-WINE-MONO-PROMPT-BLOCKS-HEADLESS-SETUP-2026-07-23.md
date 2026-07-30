# Wine Mono installer prompt blocks headless setup-prefix.sh (2026-07-23)

`wineboot -u` opens Wine's interactive Wine Mono Installer dialog on a
genuinely fresh prefix, because this build vendors no Mono runtime. With
no display attached the dialog cannot even render, so `wineserver` never
goes idle and every later `wineserver -w` blocks forever. Unfixed here;
it only bites unattended provisioning, which is the one path that always
starts from a fresh prefix.

## Symptom

`setup-prefix.sh` on a genuinely fresh `WINEPREFIX` hangs indefinitely with no
error output, after printing `== [1/5] initialise prefix ... ==` and (if step
2 is reached) partway through the winetricks pass. No message from our own
error handling, no message from winetricks' `w_die`/`w_try`, no OOM/segfault
in host or guest logs. `wineserver -w` never returns.

Reproduced 3/3 times, always at the same point, on a debian-cloud VM
(ableton-vm-tools) dispatching the run over SSH with no attached display.

## Cause

`wineboot -u` triggers Wine's own built-in interactive **"Wine Mono
Installer"** dialog the first time it needs `mscoree.dll` and finds no local
Mono runtime — this project's Wine build (`wine-d2d1-nspa-11.13`) does not
vendor/bundle wine-mono (confirmed: no `*.msi` under
`$WINE_ROOT/share/wine/mono` or anywhere in the runtime tree, only an
unrelated `monodebg.vxd` stub). The dialog blocks waiting for a human to
click Install/Cancel; with nothing to click it, `wineserver` never goes
idle and any subsequent `wineserver -w` (setup-prefix.sh's own, or
winetricks' internal ones) blocks forever.

**Why this was invisible before:** dispatched over plain SSH with no
`DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY`/`DBUS_SESSION_BUS_ADDRESS`, Wine
can't even render the dialog and the process just silently stops (no crash
logged anywhere) — looks exactly like an unexplained hang/kill with zero
diagnostic trail. Only visible by exporting the real desktop session's
display env vars over SSH and taking a screenshot: two real dialogs are
sitting there — "Wine Mono Installer" ("Wine could not find a wine-mono
package which is needed for .NET applications to work correctly...") and
"Wine configuration in /home/tester/.wine-ableton is being updated, please
wait...".

Existing dev prefixes presumably already had this resolved from an earlier
one-time interactive click (or a system-wide Mono cache), so it never
surfaced during normal manual testing — only shows up on a **truly fresh**
prefix, which is exactly what unattended/CI-style provisioning always
starts from.

## Repro

```
rm -rf ~/.wine-ableton
ABLETON_LIVE_VERSION=12 ABLETON_DPI_MODE=100 bash scripts/setup-prefix.sh
```
run with no attached display (e.g. over SSH) — hangs after step 1/5 with no
output and no way to tell it's stuck versus just slow.

## Open question

`setup-prefix.sh`'s own winetricks recipe (`corefonts vcrun2022 mfc42` /
`vcrun6`) never references mono or dotnet, which reads as "Live doesn't need
it" — but the prompt fires anyway, unconditionally, as part of plain
`wineboot -u`. Whether Live actually needs Mono functionally, or this is
just wineboot's generic first-run nag that happens to block instead of
no-op when unanswered, isn't confirmed yet.

## Fix directions

- Vendor a wine-mono MSI matching this Wine build the same way
  `vendor/winetricks-cache/{corefonts,vcrun2022,vcrun6}` are already
  vendored, and have `setup-prefix.sh` install it via `msiexec /qn` before
  `wineboot -u` ever gets a chance to prompt.
- At minimum, `setup-prefix.sh` should fail fast with a clear message on a
  stuck/interactive-only wineboot instead of hanging on `wineserver -w`
  with no timeout — silent infinite hangs are much worse than a clear
  error.

## Workaround

None yet in ableton-vm-tools — flagged for a bug report rather than
worked around. If needed
before upstream fixes it: `winetricks -q mono` (or a vendored MSI, per
above) run once against a fresh prefix before `setup-prefix.sh`'s own
`wineboot -u` step would avoid the prompt entirely, since winetricks calls
`msiexec /qn` directly rather than going through wineboot's interactive
path.
