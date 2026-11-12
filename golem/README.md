# golem overlay

SPDX-License-Identifier: GPL-2.0-or-later

Files that the Golem Engine adds to Ardour. Everything here is new: upstream never touches this
directory, so a rebase onto a new Ardour release never conflicts here. The plan and the rules
(patch budget, branches, updates) are in golem's `docs/ardour-plan.md` §1.

| Path | What |
|---|---|
| `wscript` | Builds `tools/*.cc` against libardour, like `session_utils` |
| `tools/place.cc` | `golem-place`: put an audio file at the start of a track of a saved session (bench input) |
| `bench/` | `build_chain.lua` (session: track → NAM → IR, via luasession) and `render_case.sh` (build → place → export) — prototype of the parity bench |
| `engine/golem_watch.lua` | The command watcher for golem: session, Ardour's OSC surface, then a loop on golem's `presets/.command.json` with an ack — the same contract as golem's REAPER watcher (`ping`, `status`, `rig_recall` / `scene_apply` from the engine plan the bridge joins to the command, `stomp`, `rig_verify`, `dump`) |
| `engine/golem_chain.lua` | The stereo of a chain, shared by the watcher and golem's parity bench: a route stays mono while its plugins are, and turns stereo at the first stereo plugin (the mono signal on both of its inputs, as REAPER does) |
| `engine/scripts/golem_drumtrans.lua` | Lua DSP: e-drum module notes → kit notes, three-position hi-hat (port of golem's `golem_drumtrans.jsfx`); its table is written by the watcher into the instance's shared memory |
| `engine/scripts/golem_safety.lua` | Lua DSP: zero-latency safety limiter (ceiling −1 dBFS), the last plugin of every route that goes to the card |
| `engine/run.sh` | Starts the engine for golem (`run.sh <golem-root> [session] [backend] [device]`), writes `presets/.engine.pid` |
| `dev/env.sh` | Run the binaries from `build/` without installing (`source golem/dev/env.sh`) |

Patches to upstream files (keep this list short; budget 10):

| Patch | Tag | Why |
|---|---|---|
| `wscript`: add `golem` to `children` when the directory exists | `[build]` | Hook the overlay into the build |
| `PROGRAM_SLUG` (`wscript`, `session_utils/wscript`, `libs/ardour/filesystem_paths.cc`, `headless/load_session.cc`) | `[brand]` `[upstreamable]` | A program name with a space ("Golem Engine") gave binaries, config folder and client name with a space; the slug (`golem-engine`) is used for those. Unchanged for "Ardour" |
| `libs/ardour/luabindings.cc`: bind `AudioBackend::enumerate_midi_options`, `midi_option`, `set_midi_option`, `enumerate_midi_devices`, `set_midi_device_enabled`, `midi_device_enabled` | `[headless]` `[upstreamable]` | The watcher picks the ALSA sequencer, closes every MIDI device, then opens only a lane's keyboard (golem's bridge owns the pedalboard); Lua could not reach the backend's MIDI options and devices |
| `libs/surfaces/osc/osc.cc`: no zeroconf announcement when `ARDOUR_OSC_NO_ZEROCONF` is set | `[headless]` `[upstreamable]` | The OSC surface's only client is golem's local bridge; the port must not be advertised on the network (set by `golem/engine/run.sh`) |
| `libs/backends/alsa/alsa_audiobackend.cc`: hot-plugged MIDI devices stay closed when `ARDOUR_ALSA_MIDI_NO_HOTPLUG_OPEN` is set | `[headless]` `[upstreamable]` | The watcher opens only a lane's keyboard; Ardour subscribed to every new sequencer client, golem's pedalboard reader included, and each engine restart cut the pedalboard |

Build (binaries `golem-engine9-*`, config `~/.config/golem-engine9`): `./waf configure --program-name="Golem Engine" --with-backends=alsa,dummy --optimize && ./waf build`.
