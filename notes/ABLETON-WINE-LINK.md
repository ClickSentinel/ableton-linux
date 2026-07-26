# Ableton Link support

The installer ships the persistent native peer `ableton-linkd`, its systemd
user unit, and `setup-link.sh`. Run the setup script once as your normal user.
It requests `sudo` for route and firewall changes, then uses your user session
to enable `ableton-linkd.service`:

```bash
"$HOME/.local/share/ableton-wine/setup-link.sh"
```

From a repository checkout, run:

```bash
./scripts/setup-link.sh
```

## What the setup changes

The script:

1. Finds the interface on the first IPv4 default route. It rejects interface
   names beginning with `tun`, `wg`, or `tap`.
2. Runs `sudo ip route replace 224.0.0.0/4 dev <interface> metric 0`.
3. Adds UDP port 20808 through `ufw`, or through `firewall-cmd` when `ufw` is
   absent. If neither tool is installed, it leaves the firewall unchanged and
   tells you to allow UDP 20808 manually.
4. When the NetworkManager dispatcher directory exists, installs
   `/etc/NetworkManager/dispatcher.d/50-link-multicast`.
5. Copies the user unit to
   `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service`
   and enables it with `systemctl --user enable --now`.

The script can be repeated and refuses to run while Live is open. It replaces
the route and updates the same firewall rule, hook, and unit. If the daemon or
unit file is missing, it leaves the network changes in place and reports that
the daemon setup was skipped.

The current NetworkManager hook applies the multicast route to every
interface reported as `up`. It does not repeat the default-route or VPN
check. A later VPN or secondary-interface event can therefore move the route.
Verify the route after each network or VPN reconnect:

```bash
ip route show 224.0.0.0/4
```

The listed device must be the LAN interface used by the other Link peers.
Network managers other than NetworkManager need an equivalent persistent
route or another setup run after reconnect.

## Components

### `ableton-linkd`

The installer ships `ableton-linkd`, built from the vendored Ableton Link 4.0
SDK, and installs it at:

```text
~/.local/share/ableton-wine/ableton-linkd
```

It joins the Link session as a native peer and remains active while Live
restarts. This is designed to retain the shared tempo and timeline until Live
rejoins. It enables Start Stop Sync but never calls the SDK methods that set
tempo or beat position after construction.

Its modes are:

- No arguments: run in the foreground and write status to stderr every ten
  seconds. The systemd unit uses this mode.
- `--daemon`: run in the background and write
  `~/.log/ableton-linkd/ableton-linkd.log`. The launchers use this mode.
- `--probe [seconds]`: join, wait up to ten seconds by default, print
  `peers: N` and `tempo: T.T`, and exit zero after seeing at least one other
  peer.
- `--tempo BPM`: set only the construction tempo used when this process
  creates a new session.

The Live, Max, and beta launchers start `ableton-linkd --daemon` when the
binary exists and no process with that name is running. `ABLETON_LINKD`
overrides its path. The user unit instead keeps it running from login.

### `linkprobe.exe`

The repository contains `tools/linkprobe.exe`; the `.run` installer does not
install it. The program runs under this Wine and tests `SO_REUSEADDR`, a bind
to `0.0.0.0:20808`, per-interface `IP_ADD_MEMBERSHIP`, multicast transmit,
and receive.

Its exact verdict lines are:

```text
LINKPROBE TX OK
LINKPROBE RX-LOOPBACK OK
LINKPROBE RX-NETWORK OK
LINKPROBE PEERS: N
```

The process exits zero when transmit and loopback receive succeed.
`RX-NETWORK OK` requires a datagram whose source is not one of the local
machine's addresses. The daemon on the same machine is not enough for that
line, even though it can appear in `PEERS`.

`linkprobe.exe` sends discovery datagrams without a session payload. It tests
Wine's multicast socket behavior, not full Ableton Link session membership.

`tools/jacklinkd.c` is unrelated. It restores JACK port links and happens to
register the JACK client name `ableton-linkd`. Current launchers do not start
it.

## Verification

Check the host setup:

```bash
ip route show 224.0.0.0/4
pgrep -a ableton-linkd
systemctl --user status ableton-linkd.service
```

For `ufw`, run `sudo ufw status` and look for `20808/udp`. For firewalld, run
`firewall-cmd --list-ports`.

With the service or launcher daemon active, the native probe should see at
least that peer:

```bash
"$HOME/.local/share/ableton-wine/ableton-linkd" --probe 10
```

This confirms that two native SDK instances can join. It does not identify
Live as the peer.

From a checkout, test Wine's local multicast socket behavior:

```bash
WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" tools/linkprobe.exe
```

Require `LINKPROBE TX OK` and `LINKPROBE RX-LOOPBACK OK`. To require
`LINKPROBE RX-NETWORK OK`, run another Link peer on a second LAN host during
the test.

In Live, open Preferences, select Link, Tempo & MIDI, enable Show Link
Toggle, then enable Link in the control bar. Confirm that its peer count is
at least one. Change tempo from each peer in turn, check beat and phase
alignment, and restart Live. Confirm that the restarted Live instance rejoins
the same tempo and phase.

For packet-level checks:

```bash
sudo tcpdump -i <interface> -n udp port 20808
```

Discovery uses `224.76.78.75:20808`. The Wireshark filter
`ip.dst == 224.76.78.75 || ip.dst == 224.0.0.22` also includes IGMPv3
membership reports.

If a known remote peer is active but neither the native probe nor tcpdump
sees it, check the selected interface, firewall, access point, and multicast
route. If native tools see the remote peer but Live does not, compare the
linkprobe verdicts and packet capture before treating the result as a Wine
socket fault.

## Protocol and scope

Ableton Link discovers peers with UDP multicast on
`224.76.78.75:20808`. Pairwise timeline measurements use unicast UDP on
ephemeral ports. Host connection tracking covers replies to those outbound
exchanges, so the setup opens only UDP 20808.

Peers must share a LAN that carries multicast. Native Linux applications
with Ableton Link support join the session directly. JACK-only applications
may use the separate upstream
[`jack_link`](https://github.com/rncbc/jack_link) project.

PipeASIO has no JACK transport layer. The persistent native peer therefore
cannot synchronize Live through JACK. Live joins the Link session as its own
Wine peer and follows the shared timeline itself.

Ableton Link is Ableton's technology. This project follows its naming and
enablement guidelines and is not affiliated with or endorsed by Ableton.
