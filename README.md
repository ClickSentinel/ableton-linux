# Ableton Live on Linux

This project runs Ableton Live 12 on x86-64 Linux with a patched Wine build.
Live 11, Max for Live, Ableton Link, and Push support are experimental.

This project is not affiliated with or endorsed by Ableton.

[Download the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)

![Ableton Live running on Linux](screenshot.png)

## Features

- Live 12 Intro, Standard, Suite, Lite, Trial, and beta support
- Experimental Live 11, Max for Live, and Max 9 support
- Push 1 and Push 2 support
- Ableton Link over the local network
- Audio reconnection through WirePlumber
- MIDI reconnection after replugging a controller that Live detected at startup
- PipeASIO audio through PipeWire
- Host open and save dialogs when the XDG portal is available
- Host file manager for Show in Explorer when the portal accepts the request
- Desktop light and dark theme detection
- Live-themed or system-themed menus
- Desktop font support
- Automatic display scaling from 100% to 250%
- Fixes for VST3, JUCE, and OpenGL plugin windows
- Pinned build inputs and patch checksums

## Install

You need:

- an x86-64 Linux system with glibc 2.35 or newer
- PipeWire 0.3.56 or newer
- an `ableton_live*.zip` installer from Ableton

PipeWire 1.6 or newer is recommended for low-latency audio. Run the installer
outside Flatpak, `steam-run`, and other sandboxes.

1. Download the Ableton Live ZIP from Ableton.
2. Download
   [install-ableton-latest.run](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run).
3. Put both files in the same directory.
4. Run the installer:

   ```bash
   sh ~/Downloads/install-ableton-latest.run
   ```

The installer checks the host, installs Wine under `~/.local/opt`, creates
`~/.wine-ableton`, and starts the Ableton installer. It makes no persistent
changes outside your home directory.

Start Live from the applications menu or run:

```bash
ableton-live
```

For Live 11, follow the [Live 11 instructions](#live-11).

## First launch

Set these options in Live:

1. In the Options menu, disable **Auto-Scale Plugin Window**.
2. Under **Audio**, set **Driver Type** to **ASIO** and **Device** to
   **PipeASIO**.

Report problems with the
[GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
The scripts in [`beta/scripts`](beta/scripts/) collect diagnostic reports.

## Update

Download the current installer, then run:

```bash
sh ~/Downloads/install-ableton-latest.run --update
```

This updates Wine, the launchers, and prefix policy. It keeps Live, its
settings, and its authorization. Running the installer without `--update`
offers the same update when it finds an existing installation.

Updates from 2026.07.18.1 also remove `-DontCombineAPCs` from Live's
`Options.txt`. That option caused stuttering and slowed playback in issue 29.

## Live 11

Live 11 support is experimental.

1. Prepare the prefix for Live 11:

   ```bash
   ABLETON_LIVE_VERSION=11 sh ~/Downloads/install-ableton-latest.run
   ```

   Setup downloads the Live 11 support files, so it needs network access.

2. After the first Live 11 launch, run the Max for Live repair once:

   ```bash
   sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
   bash /tmp/ableton-kit/scripts/setup-prefix.sh --post-first-run
   ```

   The repair moves a stale Max 8 preferences file aside. Max recreates it on
   its next start.

3. Avoid previewing or importing WMA or video files because Wine's
   `wmvcore.dll` stubs can crash Live 11. See
   [the WMVCore investigation](notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md).

The launcher detects Live 11. If the prefix contains Live 11 and 12, it starts
the newest version. Use `ABLETON_LIVE_VERSION=11 ableton-live` to select Live
11, or set `ABLETON_LIVE_EXE` to select an exact installation.

## Plugins

Run a Windows plugin installer in Live's prefix:

```bash
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine \
  "/path/to/PluginInstaller.exe"
```

You can also copy `.vst3` bundles to:

```text
~/.wine-ableton/drive_c/Program Files/Common Files/VST3/
```

An untested option is to run Linux-native plugins in Carla beside Live and
route audio and MIDI through PipeWire. See
[Linux-native plugin bridging](notes/ABLETON-WINE-PLUGIN-BRIDGING.md).

## Push 2 setup

Under **Preferences > Link, Tempo & MIDI**, configure exactly one `Push2`
control-surface row. Select **Ableton Push 2 Live Port** for its input and
output, then enable the Remote switches.

## Ableton Link

Ableton Link syncs tempo, beat, and phase between devices on the local network.
The installer includes `ableton-linkd`, a passive native peer that remains in
the session while Live restarts. After construction, it does not call the Link
methods that set tempo or beat position.

Run the host setup once as your normal user. It asks for `sudo` when it changes
the route or firewall:

```bash
~/.local/share/ableton-wine/setup-link.sh
```

From a repository checkout, run `./scripts/setup-link.sh`. The script:

- routes multicast traffic through the selected LAN interface
- allows UDP port 20808 when UFW or firewalld is installed
- installs a NetworkManager hook when its dispatcher directory exists
- enables `ableton-linkd.service` when the daemon and unit files are present

Initial setup refuses `tun`, `wg`, and `tap` default routes. The NetworkManager
hook does not repeat this check, so verify `ip route show 224.0.0.0/4` after a
network or VPN reconnect. This project does not support Link over a VPN.

In Live, enable **Show Link Toggle** under **Preferences > Link, Tempo & MIDI**.
Then enable the Link control-bar indicator.

Test the connection while another Link peer is active:

```bash
~/.local/share/ableton-wine/ableton-linkd --probe 10
```

Success prints a peer count and tempo, then exits with status 0. For diagnosis,
see [Ableton Link support](notes/ABLETON-WINE-LINK.md).

## Lower latency

From a repository checkout, the optional host tuning script grants realtime
scheduling, lowers swappiness, and configures the performance CPU governor:

```bash
./scripts/setup-realtime.sh
```

It uses `sudo` and prints each persistent configuration file it writes. It
applies swappiness and the CPU governor immediately. It recommends
kernel-package and bootloader changes without applying them.

Log out and back in after it finishes. `ulimit -r` should then print `95`. Some
distributions already grant realtime permission. The launcher uses realtime
scheduling when `chrt` is installed and `chrt -r 10 true` succeeds.

Use `ABLETON_RT=off ableton-live` to compare normal scheduling or to avoid
realtime scheduling on a low-core system.

## Build from source

The build requires Podman and about 10 GB of free space. `install.sh` requires
`zstd`, and `setup-prefix.sh` requires `cabextract`. `make-installer.sh`
requires both `zstd` and `binutils`.

```bash
./build.sh
./scripts/install.sh
./scripts/setup-prefix.sh
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine \
  "/path/to/Ableton Live 12 Suite Installer.exe"
ableton-live
```

`build.sh` creates the Wine runtime and `dist/ableton-linkd` with the pinned
Podman image. `install.sh` installs both.

Build the single-file installer with:

```bash
./scripts/make-installer.sh
```

The result is `dist/ableton-wine-setup-<version>.run`.

### Display scale

`setup-prefix.sh` and the launcher detect display scale on GNOME, KDE, COSMIC,
sway, Hyprland, and X11. The launcher recalibrates the prefix at each start.
Live must restart after moving between monitors with different DPI values.

Use `ABLETON_DPI_MODE` to override detection.

### Common environment variables

- `ABLETON_WINE_ROOT` selects the Wine runtime. The default is
  `~/.local/opt/wine-d2d1-nspa-11.13`.
- `ABLETON_WINEPREFIX` selects the Wine prefix. The default is
  `~/.wine-ableton`.
- `ABLETON_LIVE_VERSION=11|12` selects a Live major version.
- `ABLETON_LIVE_EXE` selects one Live executable inside the prefix.
- `ABLETON_DPI_MODE=auto|preserve|100|fractional|dpi<N>|fractional<N>`
  overrides display-scale detection.
- `ABLETON_THEME_MODE=auto|dark|light|preserve` controls desktop theme sync.
- `ABLETON_TOPBAR_MODE=live|system|preserve|'#RRGGBB #RRGGBB'` controls menu
  colors.
- `ABLETON_UI_FONT=auto|preserve|off|<family>` controls the Wine UI font.
- `ABLETON_DCOMP=off` disables DirectComposition for one launch.
- `ABLETON_RT=off` disables realtime scheduling for one launch.
- `PIPEASIO_*` variables override driver settings for one launch. For example,
  set `PIPEASIO_PREFERRED_BUFFERSIZE=512` to increase the buffer.
- `ENGINE` overrides the `podman` command used by the build scripts.

### Steam Deck

Use Desktop Mode.

## Repository layout

- [`patches`](patches/): Wine and PipeASIO patches
- [`scripts`](scripts/): build, install, setup, and launch scripts
- [`vendor`](vendor/): pinned build inputs
- [`notes`](notes/): implementation notes and investigations
- [`tools`](tools/): diagnostic and build tools
- [`bin`](bin/): installed launchers
- [`dist`](dist/): build output
- [`beta`](beta/): beta test kit

The patch list and provenance are in [`patches/BASE.txt`](patches/BASE.txt).

## Credits

Maintained by [Cade "shibco" Diehm](https://shiba.computer/about), with work
from [ClickSentinel](https://github.com/ClickSentinel),
[jackson-57](https://github.com/jackson-57),
[jttdev](https://github.com/jttdev),
[astrazds](https://github.com/astrazds),
[Version33](https://github.com/Version33), and
[0tanh](https://github.com/0tanh). [yioannides](https://github.com/yioannides)
made the application and MIME icons. ENCORE by wowitsjack informed several
patches.

Questions: [cade@parare.al](mailto:cade@parare.al)

## AI disclosure

Qwen 3.6, Claude Opus, and Codex (GPT-5) assisted with QA, documentation
review, and build scripts.
