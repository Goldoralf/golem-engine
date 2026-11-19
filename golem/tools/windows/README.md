# The engine's LV2 plugins on Windows

SPDX-License-Identifier: GPL-2.0-or-later

What the Golem Engine needs on Windows besides golem-fx (VST3, installed by golem): the LV2 plugins of golem's engine
table (`library/catalog/effects-golem-engine.json` in golem). Found and checked on 2026-11-19 during the Windows port;
each one loads in the Windows build (`win-build.sh`) and renders through a session on the dummy backend.

| Plugin | golem blocks | Source (sha256) | Note |
|---|---|---|---|
| NAM LV2 0.2.3 | amp-nam, amp, pedal-nam, preamp-nam, comp-nam | `github.com/mikeoliphant/neural-amp-modeler-lv2/releases/download/v0.2.3/neural_amp_modeler_lv2_win_x64.zip` (`d64aec20…ad0ef`) | the same plugin as on Linux: captures load by its `#model` property |
| x42 zeroconvolv 0.7.2 | cab, ir-fx | `x42-plugins.com/x42/win/x42-zconvolver-v0.7.2-w64-Setup.exe` (`6e459046…b18e3c`) | an NSIS installer: the bundle is `$COMMONFILES64/LV2/zeroconvo.lv2` inside (`7z x`) |
| sfizz 1.2.3 | piano, pads, samples, the standards' piano and guitar, drum machine kits, MIDI phrase demos | `github.com/sfztools/sfizz-ui/releases/download/1.2.3/sfizz-1.2.3-win64.exe` (`56f57dfe…71b937`, the pin golem already uses for REAPER) | an Inno Setup installer (`innoextract`): `commoncf/LV2/sfizz.lv2`. **Its `controllers.ttl` is missing** (generated at build time): sfizz refused to instantiate. `sfizz_controllers_ttl.py` writes it, identical to the project's cmake generator |
| setBfree 0.8.17 | organ | **rebuilt**: `github.com/pantherb/setBfree` at `2f41983` + `setbfree-state-nul.patch`, `make MOD=1 XWIN=x86_64-w64-mingw32` in MSYS2 UCRT64 | the x42 Windows build (`setBfree-lv2-w64-v0.8.17.zip`, `1b87222e…84a2fe`) **crashes the engine** (0xC0000005) when Ardour saves the session state — which it does when a take or a demo arms recording: its Windows state save read a temp file into a buffer that was not NUL-terminated, then `strlen`/`strcat` ran past it. The patch terminates it. The rebuilt `b_synth.dll` depends only on the UCRT; the bundle is the dll, `b_synth.ttl`, `manifest.ttl`, `modgui.ttl` (no UI) |
| AVL Drumkits 0.7.6 | drumkit | `x42-plugins.com/x42/win/x42-avldrums-lv2-w64-v0.7.6.zip` (`de4d5c61…60d4e`) | loads as is |

Not available as LV2 on Windows (golem's table needs another plugin there): `bitcrusher` (mda Degrade — golem-fx Crusher is
the candidate), `capture-module` (golem's own capture reader, LV2 built on Linux only), `ep` (Dexed VST3) and `grit`
(Prisma VST3) are not installed on the measuring machine.

Status (2026-11-19): measured on one Windows 11 machine with golem's adapter bench (`tools/check-engine-ardour.py
--only …`). One intermittent engine crash remains after the setBfree fix (1 run in 7, during the CPU-bench render), not
caught under ProcDump or gdb — open.
