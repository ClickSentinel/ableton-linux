# Migrating from ENCORE

If you're already running Ableton Live through [ENCORE](https://github.com/wowitsjack/ENCORE), you can switch to this project without re-downloading Live or reauthorizing. Ableton's offline authorization binds to the Wine prefix's `MachineGuid`, not to which Wine build runs it — as long as you reuse your existing prefix's files instead of creating a new one, the license carries over.

## Steps

1. **Install this project's Wine runtime.** Download the installer and run it (see the main [README](README.md)). This only touches `~/.local/opt` and `~/.local/bin`/`~/.local/share` — it does not touch your existing ENCORE prefix.

2. **Copy your ENCORE prefix — don't move it.** Keeping the original intact means you always have a fallback if anything goes wrong.

   ```sh
   cp -a ~/ableton-prefix ~/.wine-ableton
   ```

   (Adjust the source path if your ENCORE prefix lives somewhere else.) Naming the copy `~/.wine-ableton` — this project's default prefix location — means the installed launcher and desktop icon work with no extra configuration. If you'd rather use a different path, you can, but you'll need to set `ABLETON_WINEPREFIX` for every launch below, including from the desktop icon (its `Exec=` line won't inherit your shell's environment).

3. **Align the prefix with this project's runtime:**

   ```sh
   ABLETON_WINEPREFIX=~/.wine-ableton ./scripts/setup-prefix.sh --refresh
   ```

   `--refresh` works on an existing prefix: it forces the native VC++ runtime over Wine's builtin stubs, re-registers PipeASIO, and syncs DPI/theme/portal policy. It does not touch your Ableton installation or license.

4. **Launch:**

   ```sh
   ableton-live
   ```

5. **Confirm it opens already authorized.** It should — no prompts.

6. **Do the first-launch checklist** from the README if you haven't already: in Live, Options → uncheck "Auto-Scale Plugin Window"; Preferences → Audio → Driver Type ASIO → Device PipeASIO.

## What not to do

Don't run the installer against a fresh or empty prefix and reinstall Live from a downloaded zip — that creates a new `MachineGuid` and forces reauthorization. The point of this procedure is reusing your existing prefix's files as-is.

## Rolling back

Nothing here is destructive. Your original ENCORE prefix and its own Wine build are untouched throughout — if this project doesn't work out for you, ENCORE is exactly as you left it.
