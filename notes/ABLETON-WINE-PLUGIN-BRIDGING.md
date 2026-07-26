# Linux-native plugin routing test

This workflow is untested. It runs Linux plugins in Carla, then connects them
to PipeASIO through PipeWire. This keeps the Linux plugin host outside Live's
Wine process. The PipeASIO port layout was verified for issue #15 on
2026-07-18.

## Setup

1. Install Carla from the distribution packages.
2. Start the host through PipeWire's JACK compatibility layer:

   ```bash
   pw-jack carla
   ```

3. Load the Linux plugin.
4. In Live, select **ASIO** and **PipeASIO** under
   **Preferences > Audio**.
5. Connect the ports with qpwgraph or `pw-link`.

List and connect ports from the shell:

```bash
pw-link -o
pw-link -i
pw-link 'OUTPUT_PORT' 'INPUT_PORT'
```

Replace `OUTPUT_PORT` and `INPUT_PORT` with names from the two lists. For audio
into Live, connect the plugin host's outputs to PipeASIO's inputs.
For an external effect loop, connect PipeASIO outputs to the host inputs and
return the processed signal to PipeASIO inputs.

The default PipeASIO configuration provides `in_1`, `in_2`, `out_1`, and
`out_2` at a fixed 256-frame buffer. Settings are in
`~/.config/pipeasio/config.ini`.

For MIDI, use the ALSA sequencer ports exposed to Live by `winealsa.drv`.
qpwgraph shows them in its MIDI view, and `aconnect -l` lists them from the
shell.

Save the connections as a qpwgraph patchbay profile if they should return with
the session.

## Limits

- Carla port names depend on the installed build. Confirm them before saving a
  profile.
- The plugin chain shares PipeWire's graph quantum with Live. Watch `pw-top`
  for xruns under load.
- [Winesulin](https://github.com/falkTX/winesulin) embeds a Linux plugin host
  inside a Windows VST host process. This project does not ship or test that
  path.
