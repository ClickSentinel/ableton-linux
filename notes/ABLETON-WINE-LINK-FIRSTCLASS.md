# First-class Ableton Link: design proposal

Status: implemented, shipped in 2026.07.23.1 (updated 2026-07-23; proposed
2026-07-22). This design superseded the "experimental" phase;
notes/ABLETON-WINE-LINK.md documents the shipped setup.

## Goal

Ableton Link works for Live 12 under this project exactly as it does on Windows
and macOS — toggle on, join the session, sync tempo/beat/phase, optional
Start Stop Sync — with zero hand-built dependencies, plus the two things the
platform cannot give us by itself: the session survives a Live restart, and
native Linux apps join the same session.

## Where we are today (verified by code review, 2026-07-22)

- Option A (Live joins directly from Wine) is **plausible but unproven**. Stock
  Wine 11.11 WinSock2 passes through every multicast sockopt Link needs
  (`IP_ADD_MEMBERSHIP` etc. — `dlls/ntdll/unix/socket.c:2120` ff.), the
  wineserver emulates `SO_REUSEADDR` sharing correctly, and no patch in
  `patches/` touches networking. The only latent gap is the `WSAJoinLeaf` stub
  (`dlls/ws2_32/socket.c:4165`), which modern Link stacks never use. Nobody has
  ever run the verification checklist to completion; CHANGELOG says "I have no
  idea if this works yet."
- Option B (external `jack_link`) is anchor-only on this stack: PipeASIO has no
  JACK transport layer, so the bridge **cannot drive Live's tempo**. It also
  requires a manual clone/build/install/unit, none of which ships in the `.run`
  installer (`setup-link.sh` is not even staged).
- Networking setup (multicast route, firewall) is a manual sudo script with a
  non-persistent route and a copy-paste NetworkManager dispatcher hook.
- Naming hazard: `tools/jacklinkd.c` is a stale JACK **port-link** guardian
  (WineASIO era) that registers the JACK client name `ableton-linkd`. It is not
  Ableton Link and is no longer started by anything.

## Design

Three components, all first-party, all built by the existing pipeline.

### 1. `ableton-linkd` — native session anchor + probe (replaces jack_link)

A small native daemon built from the **vendored Ableton Link SDK** (Link 4.0,
header-only C++17 + asio; the clone at `../ableton-link` becomes
`vendor/link-4.0.tar.zst` + `vendor/link.sha256`). It joins
224.76.78.75:20808 natively and:

- **anchors the session** — it is the always-on peer, so the session tempo and
  timeline survive Live restarts (longest-lived-peer rule);
- **relays Start Stop Sync** (`enableStartStopSync(true)`) without owning a
  transport;
- is **strictly passive**: it never calls `forceBeatAtTime`/`setTempo` after
  founding, per the Ableton Link anti-hijack guidelines;
- doubles as the **verification probe** the project has never had:
  `ableton-linkd --probe 10` prints peer count and session tempo and exits 0
  iff peers ≥ 1 — an automated, scriptable verdict on whether Live's
  Wine-side membership works, with no eyeballing Live's UI.

It deliberately does **not** do JACK transport bridging. Native Link-enabled
Linux apps (Bitwig, Ardour, SuperCollider, Sonic Pi, VCV Rack) join the same
session over the network directly; JACK-only apps can still run upstream
`jack_link` alongside. Dropping JACK also drops the `libjack` host dependency
and jack_link's client-churn instability (upstream issue #9).

Modes: foreground (systemd), `--daemon` (self-backgrounding, logs to
`~/.log/ableton-linkd/`, for the launcher), `--probe [secs]`, `--tempo BPM`
(initial tempo when founding, default 120). Built with
`-static-libstdc++ -static-libgcc`; DT_NEEDED limited to libc/libm/libpthread/
libatomic host sonames, no RPATH — same loader-cleanliness rule as PipeASIO.

### 2. `linkprobe.exe` — Wine-side multicast verdict (the missing evidence)

A tiny Windows PE tool (`tools/linkprobe.c`, built like the other `tools/`
PE helpers) that runs under the project's Wine and exercises exactly what Live
needs: `SO_REUSEADDR` bind to 0.0.0.0:20808, `IP_ADD_MEMBERSHIP` on
224.76.78.75, multicast TX, and RX with self/peer discrimination (parses the
`_asdp_v1` header: msgType + nodeId). Output is a verdict:
`TX OK`, `RX OK (loopback)`, `RX OK (network)`, `PEERS: n`.

This settles Option A mechanically, before and independently of Live.
**If network RX fails under Wine, the fix lands as a new numbered patch in
`dlls/ntdll/unix/socket.c` or `server/sock.c`** — the first networking patch in
the series. That is the only contingency in which Wine-side work is needed.

### 3. Packaging, setup, and launcher integration

- **Vendoring** follows the pinned-blob rule: `vendor/link-4.0.tar.zst` (full
  repo incl. asio submodule, minus `.git`; deterministic tar) +
  `vendor/link.sha256`, added to the verify lists in `build.sh` and `Makefile`.
- **Build at pack time**, exactly like `cabextract-static`: `make-installer.sh`
  compiles `tools/ableton-linkd.cpp` in the pinned container against the
  vendored tarball → `kit/bin/ableton-linkd`. The vendored tarball itself is
  also staged in the kit: it is the GPL corresponding source accompanying the
  binary (Link is GPLv2+, no linking exception; this project is an appropriate
  GPL distribution point, and the kit will carry the license text).
- **Install**: `install.sh` copies the daemon to
  `~/.local/share/ableton-wine/ableton-linkd` with the usual required-file and
  `readelf` gates; `uninstall.sh` learns to disable/remove the user unit (its
  `$HOME`-only rule is preserved — the unit lives under
  `~/.config/systemd/user`).
- **`setup-link.sh` hardening** and first shipment in the kit:
  - Option B now means the shipped `ableton-linkd.service` user unit, which the
    script installs and enables — no more "build jack_link yourself" bail-out;
  - fix the spurious exit-1 when only Option A networking was requested;
  - auto-install the NetworkManager dispatcher hook for route persistence
    (today a copy-paste heredoc in the note) when NM is present;
  - keep VPN refusal, ufw/firewalld 20808/udp allowance; document that Link's
    unicast measurement port is ephemeral and covered by conntrack for
    outbound-initiated exchanges.
- **Launchers**: the `jack_link` auto-start block in `scripts/ableton-live`
  (:651-658) becomes an `ableton-linkd` auto-start (`--daemon`, silent skip if
  not installed, `ABLETON_LINKD` override); the same block is added to
  `scripts/max9` and `bin/ableton-live-beta`.
- **Docs**: rewrite `notes/ABLETON-WINE-LINK.md` for the new architecture;
  README loses the "experimental / unverified" wording once the probe verdict
  is in; CHANGELOG entry. Naming follows the Ableton Link Guidelines:
  "Ableton Link", two words, capital A/L; enablement language is
  "Enabled/Disabled".

## What "1:1" means — acceptance checklist

- [ ] `linkprobe.exe` under this Wine: TX OK, network RX OK (or a Wine patch
      landed that makes it so).
- [ ] Live's Link toggle shows peer count ≥ 1 when `ableton-linkd` runs.
- [ ] Tempo change on any peer propagates to all others, both directions;
      Live is not hijacked on join (TEMPO-1..5 of the SDK's TEST-PLAN).
- [ ] Beat/phase alignment audible/measurable; AUDIOENGINE-1 < 3 ms on a
      healthy machine.
- [ ] Start Stop Sync works when enabled on both sides.
- [ ] Session tempo survives a full Live restart (anchor holds it).
- [ ] A native app (e.g. SuperCollider `LinkClock` or Bitwig) syncs with Live.
- [ ] Fresh machine: `.run` installer + one `setup-link.sh` run (sudo) = all of
      the above; no git checkout, no manual builds, route persists reboots.

## Explicitly out of scope

- LinkAudio (SDK 4.0 networked audio) — separate API, days old upstream.
- JACK transport bridging — upstream `jack_link` remains supported for that.
- Reimplementing the Link protocol — embedding the vendored SDK inherits the
  conformance-tested session arbitration (ghost-time measurement, 500 µs EPS
  session selection, anti-hijack resets) and future upstream fixes. The wire
  protocol (`_asdp_v1`/`_link_v1`) has been stable since 2016, but the
  arbitration logic is where reimplementations go to die.
- `WSAJoinLeaf` un-stubbing — only if the probe ever proves Live needs it.

## Status 2026-07-22 (build complete, verification partial)

Built and verified on this machine:

- `ableton-linkd` built from the vendored SDK (host g++ and the pinned
  pack-time container both; DT_NEEDED = libm/libc/ld-linux only, no
  libstdc++, no RPATH). `--daemon`, `--probe`, `--tempo`, `--help`,
  signal handling all exercised.
- Anti-hijack proven live: the anchor adopted a real LAN peer's 133.0 BPM
  session tempo; a `--probe` client adopted the anchor's tempo rather
  than forcing its construction tempo.
- `linkprobe.exe` under the installed patched Wine: `TX OK`,
  `RX-LOOPBACK OK`, `PEERS: 1` (the anchor). strace showed Wine's
  sockopt translation byte-perfect (per-interface `IP_ADD_MEMBERSHIP`,
  `IP_MULTICAST_IF`), and the anchor receives the Wine peer's alives and
  answers them with unicast kResponses — Option A's Wine-side data path
  is evidence-backed in both directions. Protocol gotcha found and fixed
  during bring-up: the `_asdp_v1` magic is 7 ASCII bytes + the integer
  0x01, not the ASCII string "_asdp_v1".
- `setup-link.sh` route step switched to `ip route replace` after a
  pre-existing `224.0.0.0/4 dev lo` route on this host proved the old
  silent `append` never landed.
- Full packaging wired: make-installer pack-time build, kit staging
  (daemon, unit, setup-link.sh, GPL source + license), install.sh gates
  + share-dir installs, uninstall.sh unit cleanup, launcher autostart in
  ableton-live/max9/beta, docs/README/CHANGELOG.

Still open (needs a live LAN peer and/or a Live run):

- `RX-NETWORK OK` from linkprobe.exe (no second host was online).
- Live's Control-Bar peer count, tempo propagation both directions,
  Start Stop Sync, phase < 3 ms.
- Session survival across a real Live restart (anchor semantics are
  proven; the Live-side observation is not).
- Fresh-machine install from the assembled `.run` + one sudo
  `setup-link.sh` run.

## Build order

1. Vendor the SDK; write and host-build `ableton-linkd`; smoke-test `--probe`.
2. Write and build `linkprobe.exe`; run it under the project's Wine for the
   first real Option A verdict.
3. Packaging: make-installer / install.sh / audit / GPL license staging.
4. `setup-link.sh` hardening, systemd unit, launcher wiring.
5. Docs, README, CHANGELOG.
6. Full container build + installer assembly; end-to-end verification against
   the acceptance checklist (needs a second Link peer on the LAN, e.g.
   `ableton-linkd` on another machine or any Link iOS app).
