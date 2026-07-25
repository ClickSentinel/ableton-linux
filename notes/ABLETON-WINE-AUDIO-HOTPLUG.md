# Audio reconnect behavior

Current PipeASIO installs expose Live as a native PipeWire client.
WirePlumber reconnects its streams when an audio device returns. The Live
launcher does not start a hotplug helper.

If Live remains silent after a device reconnect, inspect WirePlumber and the
PipeWire graph. `jacklinkd` cannot repair Live's PipeASIO connections.

## Previous WineASIO behavior

Releases through 2026.07.17.1 routed Live through the PipeWire JACK graph.
Unplugging an interface removed the JACK links between WineASIO and the
hardware ports. PipeWire did not restore those links when the device
returned.

The launcher therefore started `jacklinkd`. It recorded JACK links and
recreated them when ports with the same names returned. PipeASIO removed JACK
from Live's audio path, so release 2026.07.17.2 stopped starting this helper.

## Separate JACK graphs

[`tools/jacklinkd.c`](../tools/jacklinkd.c) remains available for setups that
still use JACK outside Live. The tester kit also includes it under advanced
probes.

`jacklinkd` can restore only links it has already observed. It matches port
names, so renamed or renumbered ports do not match and identical names can
collide.

WirePlumber also needs prior routing state before it can restore a native
stream. Neither tool can infer routing that was never connected.

PipeWire resamples a returning device when its rate differs from the graph.
The [PipeASIO patches](../patches/pipeasio/) also clamp unsupported rate
requests; without that clamp, Live could fail at startup with
`ASE_NoClock`.
