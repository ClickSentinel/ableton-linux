# Ableton Link implementation record

This design shipped in release 2026.07.23.1. Current setup and verification
instructions are in [ABLETON-WINE-LINK.md](ABLETON-WINE-LINK.md). This file
records the implementation choices and remaining test coverage.

## Direct Wine networking

Live joins Ableton Link as its own Wine peer. Wine 11.11 passes the multicast
socket options used by the Link SDK, including `IP_ADD_MEMBERSHIP`,
`IP_MULTICAST_IF`, and `SO_REUSEADDR`. No patch in this project changes the
network stack.

`WSAJoinLeaf` remains a Wine stub, but the Link SDK does not use it. The
Wine-side probe confirmed bidirectional discovery traffic through Wine on
this machine.

An external `jack_link` process cannot synchronize Live with the current
PipeASIO configuration. PipeASIO is a native PipeWire client and has no JACK
transport layer.
JACK-only applications can still use upstream `jack_link` separately.

## Persistent native peer

`tools/ableton-linkd.cpp` builds against the vendored Ableton Link 4.0 SDK.
The daemon joins the session as a native peer. It is designed to retain the
shared timeline state while Live restarts. It enables Start Stop Sync.

After construction, the daemon does not call `setTempo`,
`forceBeatAtTime`, or `requestBeatAtTime`. Its `--tempo` value is only the
construction tempo for a new session. When it joins an existing session, it
adopts that session's state.

Supported modes are:

- No arguments: run in the foreground for the systemd user unit.
- `--daemon`: run in the background and log to
  `~/.log/ableton-linkd/ableton-linkd.log`.
- `--probe [seconds]`: print peer count and session tempo, then exit zero
  after seeing another peer.
- `--tempo BPM`: set the construction tempo, with a default of 120.

The daemon does not bridge JACK. Native applications with Ableton Link
support join the same network session directly.

## Wine multicast probe

`tools/linkprobe.c` builds a Windows PE program that exercises the socket
operations Live needs:

- bind `0.0.0.0:20808` with `SO_REUSEADDR`
- join `224.76.78.75` on each local IPv4 interface
- transmit through `IP_MULTICAST_IF`
- receive and distinguish local from non-local source addresses
- parse the `_asdp_v1` discovery header and node ID

Its verdicts are `LINKPROBE TX`, `LINKPROBE RX-LOOPBACK`,
`LINKPROBE RX-NETWORK`, and `LINKPROBE PEERS`. The process exits zero when
transmit and loopback receive succeed. Network receive requires a packet from
another host.

The probe's discovery packet has no session payload. It verifies Wine's
multicast socket behavior but does not become a full Link peer.

## Build and packaging

The repository vendors `vendor/link-4.0.tar.zst`, including the asio
submodule, and verifies it with `vendor/link.sha256`. `make verify` and
`build.sh` include that checksum.

`build.sh` calls `scripts/build-ableton-linkd.sh`. The installer packager
reuses an executable `dist/ableton-linkd`; if the file is absent or not
executable, the packager calls the same helper. It runs `--help` before
packaging. The helper uses the configured Podman build image, extracts the
vendored SDK, compiles `tools/ableton-linkd.cpp`, and writes
`dist/ableton-linkd`. It validates the new binary before replacing an existing
artifact. The packager copies that artifact to `kit/bin/ableton-linkd`.

The build uses `-static-libstdc++ -static-libgcc`. The tested binary had
`DT_NEEDED` entries for `libm.so.6`, `libc.so.6`, and
`ld-linux-x86-64.so.2`, with no RPATH. When `readelf` and `strings` are
available, `scripts/install.sh` rejects an unexpected shared library.
Otherwise it verifies the package checksum and skips the shared-library and
portal-backend checks.

The installer includes the vendored SDK archive and its GPLv2-or-later
license as corresponding source for `ableton-linkd`. It installs the daemon,
the systemd user unit, and `setup-link.sh` under
`~/.local/share/ableton-wine/`.

## Host and launcher integration

`scripts/setup-link.sh` configures the multicast route, adds a UDP 20808
allowance when UFW or firewalld is installed, and enables the user unit when
its files are present. The script must run as the user because it calls
`systemctl --user`; it requests `sudo` only for host network changes. The
current NetworkManager dispatcher hook is not interface-filtered, so the route
must be checked after VPN and network reconnects.

The Live, Max, and beta launchers start `ableton-linkd --daemon` when the
binary is installed and no process with that name is running.
`ABLETON_LINKD` overrides the binary path.

`tools/jacklinkd.c` is an older JACK port-link restorer. Its JACK client name
is also `ableton-linkd`, but it is not part of Ableton Link and current
launchers do not start it.

## Recorded verification

Tests completed on 2026-07-22:

- The daemon built both with the host compiler and in the configured Podman
  image. `--daemon`, `--probe`, `--tempo`, `--help`, and signal handling ran
  successfully.
- The daemon joined an existing 133.0 BPM LAN session instead of applying its
  120 BPM construction value. A second probe joined the daemon's state.
- `linkprobe.exe` under the installed Wine reported `LINKPROBE TX OK`,
  `LINKPROBE RX-LOOPBACK OK`, and one peer from the same-host daemon.
- A system-call trace showed per-interface `IP_ADD_MEMBERSHIP` and
  `IP_MULTICAST_IF` translation. The daemon received Wine's discovery
  packets and answered with unicast responses.
- Packaging included the daemon, unit, setup script, SDK source archive, and
  license. Install and uninstall paths were exercised.

The `_asdp_v1` signature uses seven ASCII bytes followed by the byte `0x01`.
Treating the final byte as the character `1` produced an invalid packet and
was corrected during probe development.

## Tests still needed

- Confirm `LINKPROBE RX-NETWORK OK` with a second LAN host.
- Verify Live's peer count and two-way tempo changes.
- Measure beat and phase alignment under audio load.
- Verify Start Stop Sync from Live and another peer.
- Confirm session continuity across a full Live restart.
- Run the assembled `.run` installer and Link setup on a fresh machine.

LinkAudio and a bundled JACK transport bridge remain outside this
implementation.
