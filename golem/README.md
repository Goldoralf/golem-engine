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
| `tools/win-build.sh` | Windows build, natively in an MSYS2 UCRT64 shell: packages, configure, build (what each flag is for: in the script) |

Patches to upstream files (keep this list short; budget 10 — 12 since 2026-11-19, the two Windows ones are upstreamable):

| Patch | Tag | Why |
|---|---|---|
| `wscript`: add `golem` to `children` when the directory exists | `[build]` | Hook the overlay into the build |
| `PROGRAM_SLUG` (`wscript`, `session_utils/wscript`, `libs/ardour/filesystem_paths.cc`, `headless/load_session.cc`) | `[brand]` `[upstreamable]` | A program name with a space ("Golem Engine") gave binaries, config folder and client name with a space; the slug (`golem-engine`) is used for those. Unchanged for "Ardour" |
| `libs/ardour/luabindings.cc`: bind `AudioBackend::enumerate_midi_options`, `midi_option`, `set_midi_option`, `enumerate_midi_devices`, `set_midi_device_enabled`, `midi_device_enabled` | `[headless]` `[upstreamable]` | The watcher picks the ALSA sequencer, closes every MIDI device, then opens only a lane's keyboard (golem's bridge owns the pedalboard); Lua could not reach the backend's MIDI options and devices |
| `libs/surfaces/osc/osc.cc`: no zeroconf announcement when `ARDOUR_OSC_NO_ZEROCONF` is set | `[headless]` `[upstreamable]` | The OSC surface's only client is golem's local bridge; the port must not be advertised on the network (set by `golem/engine/run.sh`) |
| `libs/ardour/vst3_plugin.cc`: the re-activation delegated to the butler on `kLatencyChanged` takes the plugin's process lock | `[upstreamable]` | The butler thread called `setActive` while the audio thread was in `process()`: a nih-plug plugin (golem-fx) panics on it ("already mutably borrowed") and aborts the engine — three engine crashes at a rig recall on the rack on 2026-11-17 |
| `libs/surfaces/osc/osc.cc`: the OSC port is `ARDOUR_OSC_PORT` when set, with no fallback to the next port | `[headless]` `[upstreamable]` | A bench engine started next to the engine that plays took 3820 silently while its bridge kept sending to 3819 — the rack (measured 2026-11-17: a bench started the rack's transport). `run.sh` passes `GOLEM_ENGINE_OSC` |
| `libs/backends/alsa/alsa_audiobackend.cc`: hot-plugged MIDI devices stay closed when `ARDOUR_ALSA_MIDI_NO_HOTPLUG_OPEN` is set | `[headless]` `[upstreamable]` | The watcher opens only a lane's keyboard; Ardour subscribed to every new sequencer client, golem's pedalboard reader included, and each engine restart cut the pedalboard |
| `libs/ardour/ardour/lua_api.h`, `libs/ardour/lua_api.cc`, `libs/ardour/luabindings.cc`: `ARDOUR.LuaAPI.place_audio_file (session, route, path, position)`, `ARDOUR.LuaAPI.release_sources (session, sources)` and `Session:set_auto_loop_location` bound | `[headless]` `[upstreamable]` | The watcher places a file on a track without importing it (an external source, resampled on the fly when its rate differs, no fades): a backing track's stems, the DI of a sound demo; and it sets the loop of a section. `release_sources` removes a take's capture sources once golem has copied or moved their files, with one session save: the files are closed (on Windows an open file cannot be deleted — every take stayed twice on disk; on Linux a moved file kept its space) |
| `libs/ardour/luabindings.cc`: `Session:remaining_latency_preroll` bound | `[headless]` `[upstreamable]` | A Lua DSP that generates notes live and must fall on the timeline (the armed start of a standard: its tick 0 on sample 0 of the take) has to start inside the latency preroll, ahead by the output latency |
| `libs/ardour/midi_track.cc`, `libs/ardour/plugin.cc`: a transport stop or locate no longer sends all-notes-off nor resolves plugin MIDI when `ARDOUR_MIDI_KEEP_NOTES_ON_TRANSPORT` is set | `[headless]` | The engine hosts instruments played live: notes come from a keyboard, a pad or a foot switch, not from the timeline. Starting or stopping a take, or seeking in a backing track, cut a held chord or a ringing sample (set by `golem/engine/run.sh`) |
| `libs/backends/portaudio/wscript`: `jack64` is linked only when configure finds it | `[build]` `[upstreamable]` | The native Windows build linked `-ljack64` unconditionally, for Ardour's private PortAudio; MSYS2's static PortAudio does not use JACK and has no such library, so the backend failed to link |
| `libs/surfaces/osc/osc.cc`: the pause after each outgoing message is a yield (`Glib::usleep (0)`) on Windows | `[upstreamable]` | `Glib::usleep (1)` is a `Sleep (1)` on Windows — a full timer tick, 15.6 ms when the process is throttled. With meters on ~40 strips (~500 messages/s) the surface slept all the time: a command waited up to 752 ms, the first strip dump held commands 11 s, the looper closed its loop late (measured 2026-11-19). Now 4 ms |

Non-code addition: `gtk2_ardour/icons/Golem Engine.ico` (golem's own icon) — the Windows resource file names the icon after
`--program-name`.

Build (binaries `golem-engine9-*`, config `~/.config/golem-engine9`): `./waf configure --program-name="Golem Engine" --with-backends=alsa,dummy --optimize && ./waf build`.
Windows: `golem/tools/win-build.sh` in an MSYS2 UCRT64 shell (2026-11-19: builds; `luasession` creates a session on the
dummy backend and loads golem's Lua DSP — plugins, the watcher and ASIO are the next steps).

## The package (`golem/tools/bundle.py`)

`python3 golem/tools/bundle.py` (after `./waf build`) writes `build/bundle/golem-engine-<version>-linux-<arch>.tar.gz`
and its `.sha256`: what golem's installer downloads and places in `~/opt/golem-engine` (golem `docs/install-v2.md`).
It keeps the shape of this tree (`build/libs/…`, `build/luasession/luasession`, `golem/engine/run.sh`, `share/`) and
adds `deps/` (system libraries, without glibc, ALSA, udev and the C++ runtime), `VERSION`, `SOURCES` (the exact
commit) and `COPYING`. `golem/dev/env.sh` adds `deps/` to the library path when it exists, and an installed package
(a `VERSION` file) keeps its configuration in `~/.config`, never in its own folder. Build it on the oldest
distribution to support: the package needs at least the glibc it was built with.
