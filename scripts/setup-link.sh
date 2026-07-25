#!/usr/bin/env bash
# Optional Ableton Link setup: host multicast networking (Option A) plus the
# ableton-linkd session anchor (Option B). Idempotent: safe to re-run.
# The daemon ships in the .run installer (installed to
# ~/.local/share/ableton-wine/ableton-linkd); this script never builds software.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

if pgrep -f "Ableton Live.*\.exe" >/dev/null 2>&1; then
    echo "!! Live is running: close it before changing Link networking" >&2
    exit 1
fi

echo "== [1/4] primary LAN interface =="
# Link speaks UDP multicast (group 224.76.78.75, port 20808) and does not
# work over VPN: the multicast route must land on the physical LAN device
# carrying the default route, never on a tunnel.
iface="$(ip -4 route show default | awk '/^default/ {for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
if [ -z "$iface" ]; then
    echo "!! no IPv4 default route found: connect to your LAN and re-run" >&2
    exit 1
fi
case "$iface" in
    tun*|wg*|tap*)
        echo "!! the default route is a VPN interface ($iface); Link needs a physical LAN interface" >&2
        echo "!! disconnect the VPN (or give the LAN default route priority) and re-run" >&2
        exit 1 ;;
esac
echo "   primary LAN interface: $iface"

echo "== [2/4] Option A: multicast route + firewall allowance =="
# Many kernels ship no route for 224.0.0.0/4, so multicast traffic from Wine
# apps never leaves the host. 'replace' is add-or-overwrite: idempotent by
# construction, and it evicts a conflicting route for the same prefix (e.g. a
# default 'dev lo' route) so multicast leaves via the physical LAN device.
sudo ip route replace 224.0.0.0/4 dev "$iface" metric 0
echo "   multicast route 224.0.0.0/4 via $iface"
# Discovery rides the fixed UDP port 20808; unicast measurement uses ephemeral
# ports, which conntrack already covers for outbound-initiated exchanges, so
# 20808/udp is the only firewall rule Link needs.
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 20808/udp
elif command -v firewall-cmd >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-port=20808/udp
    sudo firewall-cmd --reload
else
    echo "   no ufw/firewalld found: skipping; if you run another firewall, allow UDP 20808 yourself"
fi

echo "== [3/4] Option A: route persistence (NetworkManager dispatcher hook) =="
# The route above dies with the interface. On NetworkManager systems a
# dispatcher hook re-installs it every time an interface comes up (same
# 'replace' semantics); on anything else, print the note and move on.
hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
hook_body='#!/bin/sh
[ "$2" = "up" ] || exit 0
ip route replace 224.0.0.0/4 dev "$1" metric 0'
if [ -d /etc/NetworkManager/dispatcher.d ]; then
    if [ -f "$hook" ] && [ "$(cat "$hook")" = "$hook_body" ]; then
        echo "   $hook already in place"
    else
        printf '%s\n' "$hook_body" | sudo tee "$hook" >/dev/null
        sudo chmod 755 "$hook"
        echo "   installed $hook (re-installs the route on every interface-up)"
    fi
else
    echo "   NetworkManager not found: the route will not survive a reconnect"
    echo "   persist 224.0.0.0/4 dev $iface with your network manager, or re-run this script"
fi

echo "== [4/4] Option B: ableton-linkd session anchor =="
# The daemon and its unit ship in the .run installer; a missing binary is a
# skip, not a failure: Option A networking above already stands on its own.
linkd="${ABLETON_LINKD:-$HOME/.local/share/ableton-wine/ableton-linkd}"
anchor=skipped
if [ ! -x "$linkd" ]; then
    echo "   ableton-linkd not found (looked at $linkd): skipping" >&2
    echo "   the .run installer provides it; re-run this script after installing" >&2
else
    # The unit ships next to the daemon; fall back to a copy beside this
    # script (repo checkout, or the kit's scripts directory).
    unit_src="$(dirname "$linkd")/ableton-linkd.service"
    [ -f "$unit_src" ] || unit_src="$here/ableton-linkd.service"
    if [ ! -f "$unit_src" ]; then
        echo "   ableton-linkd.service not found next to $linkd or in $here: skipping" >&2
    else
        unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$unit_dir"
        cp "$unit_src" "$unit_dir/ableton-linkd.service"
        systemctl --user daemon-reload
        systemctl --user enable --now ableton-linkd.service
        anchor=enabled
    fi
fi

echo
if [ "$anchor" = enabled ]; then
    echo "OK: Link networking via $iface; ableton-linkd.service enabled"
else
    echo "OK: Link networking via $iface; ableton-linkd anchor skipped"
fi
echo "Verify with the checklist in $root/notes/ABLETON-WINE-LINK.md"
