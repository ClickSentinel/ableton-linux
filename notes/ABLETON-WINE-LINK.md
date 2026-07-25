# Ableton Link support

## Background

Ableton Link is a peer-to-peer, masterless tempo/beat/phase sync
protocol: peers exchange UDP multicast datagrams on group
224.76.78.75 (".76.78.75" spells "LNK"), port 20808, and converge on a
shared timeline. Discovery rides the multicast group; the
tempo/timeline measurement between two peers runs over unicast UDP on
ephemeral ports. Wine forwards WinSock2 multicast to host sockets, so
whether Live joins a session is decided on the host: the kernel route
for 224.0.0.0/4, the firewall, and Wine's socket translation.

## Components

Everything ships in the .run installer; nothing is built by hand.

- `ableton-linkd`: the native session anchor and probe, built from
  the vendored Ableton Link SDK (Link 4.0, header-only C++; GPLv2 or
  later). The vendored tarball `vendor/link-4.0.tar.zst` ships in the
  installer kit as the corresponding source. Installed to
  `~/.local/share/ableton-wine/ableton-linkd`. It joins the session
  natively and anchors it: as the always-on peer it holds the shared
  tempo and timeline across Live restarts (longest-lived-peer rule)
  and relays Start Stop Sync. It is strictly passive: after founding
  a session it never sets the tempo or the timeline, per the Ableton
  Link integration guidelines. It deliberately does no JACK
  bridging. Modes (`--help` lists them): no arguments runs in the
  foreground with status lines on stderr (how the user unit runs it);
  `--daemon` self-backgrounds and logs to `~/.log/ableton-linkd/`
  (how the launcher runs it); `--probe [secs]` (default 10) joins,
  waits, prints `peers: N` and `tempo: T.T`, and exits 0 only when
  N ≥ 1; `--tempo BPM` (default 120) is only the initial tempo when
  the daemon founds a brand-new session.
- `linkprobe.exe` (`tools/`): a small Windows tool that runs under
  this Wine and exercises exactly what Live needs: bind to
  0.0.0.0:20808 with SO_REUSEADDR, join 224.76.78.75, multicast TX and
  RX with self/peer discrimination (it parses the `_asdp_v1`
  datagrams). Output is a verdict: `TX OK`, `RX OK (loopback)`,
  `RX OK (network)`, `PEERS: n`. It settles whether Wine's multicast
  path works before and independently of Live. Its alive datagrams
  carry no session payload, so it never appears in the anchor's peer
  count. It verifies the Wine multicast data path, not session
  membership; `--probe` above is the peer-count check.
- [../scripts/setup-link.sh](../scripts/setup-link.sh): shipped in
  the installer kit and installed to `~/.local/share/ableton-wine/`.
  One idempotent sudo run applies the whole host setup below,
  including the persistent route and the `ableton-linkd.service` user
  unit.
- The launchers (`ableton-live`, `max9`, the beta launcher) start the
  anchor automatically on every Live start: `ableton-linkd --daemon`
  when the binary is installed and no anchor is running yet, a silent
  skip otherwise. `ABLETON_LINKD` overrides the binary path.

`tools/jacklinkd.c`, a stale JACK port guardian from the WineASIO era
whose JACK client name is also `ableton-linkd`, is unrelated despite
the name; nothing starts it.

## Constraints

- Ableton Link does not work over VPN: the multicast route must point
  at the physical LAN interface, never a tunnel. setup-link.sh refuses
  VPN carriers.
- The router must forward multicast; many do not.
- UDP 20808 must pass the host firewall. Link's unicast measurement
  port is ephemeral; outbound-initiated exchanges are covered by
  conntrack, so no second firewall rule is needed.
- Bluetooth links are unsupported (Ableton's own requirement).

## Setup

Run the shipped script once (idempotent, safe to re-run, refuses to
run while Live is up):

    sudo ~/.local/share/ableton-wine/setup-link.sh

(from a checkout of this repository: `sudo ./scripts/setup-link.sh`).
It:

1. detects the primary LAN interface (carrier of the default route),
   refusing VPN carriers (tun*/wg*/tap*);
2. Option A: `ip route replace 224.0.0.0/4 dev <iface> metric 0`. On
   NetworkManager systems it also installs the dispatcher hook
   `/etc/NetworkManager/dispatcher.d/50-link-multicast`, so the
   route survives reconnects and reboots (other network managers: add
   the equivalent up-hook by hand). Then `ufw allow 20808/udp`, or
   `firewall-cmd --permanent --add-port=20808/udp` + reload on
   firewalld systems;
3. Option B: installs `scripts/ableton-linkd.service` as
   `~/.config/systemd/user/ableton-linkd.service` and enables it, so
   the anchor runs from login. The unit runs the daemon in the
   foreground; its status lines land in
   `journalctl --user -u ableton-linkd`.

Even without the unit, the launcher starts the anchor on every Live
start, so the session is anchored either way.

## Verification

- [ ] `ip route show 224.0.0.0/4` lists the route via the physical LAN
  interface, not a VPN device; with the dispatcher hook installed it
  comes back by itself after a reconnect
- [ ] `sudo ufw status | grep 20808` or `firewall-cmd --list-ports`
  shows `20808/udp`
- [ ] `pgrep -a ableton-linkd` shows the anchor running, and
  `~/.log/ableton-linkd/` records session activity when the launcher
  started it (unit runs log to the journal instead)
- [ ] the native probe verdict, with any other peer active (Live's
  Link toggle Enabled, or any Link app on the LAN):
  `~/.local/share/ableton-wine/ableton-linkd --probe 10` prints
  `peers: N` and `tempo: T.T` and exits 0 with N ≥ 1
- [ ] the Wine-side verdict, from a checkout:
  `WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.11/bin/wine tools/linkprobe.exe`
  reports `TX OK` and `RX OK (network)` while the anchor runs
- [ ] Live's Control-Bar Link indicator (Preferences → Link/Tempo/MIDI
  → "Show Link Toggle") is Enabled and reports a peer count ≥ 1
- [ ] a tempo change on any peer propagates to all others; a peer
  leaving drops the count cleanly; the shared tempo is still there
  after a full Live restart (the anchor holds it)
- [ ] raw-packet fallback when the verdicts above disagree:
  `sudo tcpdump -i <iface> -n udp port 20808` shows datagrams to
  `224.76.78.75.20808` once any peer is active; the Wireshark filter
  `ip.dst == 224.76.78.75 || ip.dst == 224.0.0.22` adds the IGMPv3
  membership reports

Triage: the native probe is the fork in the road. If it exits 1 (no
peers) and tcpdump shows no datagrams either, the problem is host
networking: the route, the firewall, or a router that does not
forward multicast. If the native probe sees peers but Live's count
stays zero, and linkprobe.exe shows `TX OK` without
`RX OK (network)`, Wine's multicast receive path is failing: that is a
Wine socket-layer bug, not a setup problem. The anchor holds and
monitors the session either way.

## Caveats

- The anchor never sets Live's tempo, by design (it is passive) and
  by construction: PipeASIO is a native PipeWire client with no JACK
  transport layer, so nothing on the host can drive Live's transport
  (WineASIO had such a layer; it went with the PipeASIO switch). Live
  joins the session as its own peer via the Option A networking and
  follows the shared timeline itself.
- Native Link-enabled Linux apps (Bitwig, Ardour, SuperCollider, Sonic
  Pi, VCV Rack) join the same session over the network directly; no
  bridge is involved. For JACK-transport apps, upstream
  [jack_link](https://github.com/rncbc/jack_link) remains usable
  alongside; it is a separate project, built and installed by hand,
  and no longer part of this setup.
- Ableton Link is Ableton's technology; this integration follows the
  Ableton Link guidelines (two words, capital A/L; enablement language
  is Enabled/Disabled). This project is not affiliated with or
  endorsed by Ableton.
