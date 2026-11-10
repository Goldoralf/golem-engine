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
| `dev/env.sh` | Run the binaries from `build/` without installing (`source golem/dev/env.sh`) |

Patches to upstream files (keep this list short; budget 10):

| Patch | Tag | Why |
|---|---|---|
| `wscript`: add `golem` to `children` when the directory exists | `[build]` | Hook the overlay into the build |
| `PROGRAM_SLUG` (`wscript`, `session_utils/wscript`, `libs/ardour/filesystem_paths.cc`, `headless/load_session.cc`) | `[brand]` `[upstreamable]` | A program name with a space ("Golem Engine") gave binaries, config folder and client name with a space; the slug (`golem-engine`) is used for those. Unchanged for "Ardour" |

Build (binaries `golem-engine9-*`, config `~/.config/golem-engine9`): `./waf configure --program-name="Golem Engine" --with-backends=alsa,dummy --optimize && ./waf build`.
