#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The engine's LV2 plugins for WINDOWS, into .deps/lv2 (golem/tools/windows/README.md says what each one is, where it
# comes from and why it is patched). golem's own installer already places AVL Drumkits and sfizz in Common Files\LV2
# for REAPER; the engine ships its own sfizz anyway: the installer's copy lacks controllers.ttl and does not
# instantiate. bundle.py copies .deps/lv2 into the package's lib/lv2; run.py puts that folder first in LV2_PATH.
#     golem/tools/win-lv2-deps.sh        # → .deps/lv2/{neural_amp_modeler,zeroconvo,sfizz,b_synth}.lv2
set -euo pipefail
[ "${MSYSTEM:-}" = UCRT64 ] || { echo "run this in an MSYS2 UCRT64 shell (MSYSTEM=UCRT64)" >&2; exit 2; }
test -f gtk2_ardour/wscript || { echo "run this at the root of the golem-engine repository" >&2; exit 2; }
ROOT=$(pwd)
OUT="$ROOT/.deps/lv2"
SRC="$ROOT/.deps/src/lv2"
HERE="$ROOT/golem/tools/windows"
NAM_URL=https://github.com/mikeoliphant/neural-amp-modeler-lv2/releases/download/v0.2.3/neural_amp_modeler_lv2_win_x64.zip
NAM_SHA=d64aec201ae0285e0adb9f1ac22e720d62a15c9947b9506e61dd7c6f8e9ad0ef
ZC_URL=https://x42-plugins.com/x42/win/x42-zconvolver-v0.7.2-w64-Setup.exe
ZC_SHA=6e459046ba5264d9c9aba74e8056cd01d887124bf9a98d7397059808bcb18e3c
SFIZZ_URL=https://github.com/sfztools/sfizz-ui/releases/download/1.2.3/sfizz-1.2.3-win64.exe
SFIZZ_SHA=56f57dfe443018e947b82b8e2bf4c9d824a9c961ff2b8eb6c5e929030b71b937
SETBFREE_GIT=https://github.com/pantherb/setBfree.git
SETBFREE_REV=2f41983
fetch() {   # url sha file : downloaded once, checked every time
  [ -f "$3" ] || { curl -fsSL -o "$3.part" "$1" && mv "$3.part" "$3"; }
  echo "$2  $3" | sha256sum -c --quiet - || { echo "$3: sha256 mismatch — not used" >&2; rm -f "$3"; exit 1; }
}
pacman -S --needed --noconfirm p7zip mingw-w64-ucrt-x86_64-innoextract mingw-w64-ucrt-x86_64-lv2 unzip make git >/dev/null
mkdir -p "$SRC" "$OUT"
cd "$SRC"

# NAM LV2 : the official Windows build, as is
fetch "$NAM_URL" "$NAM_SHA" nam.zip
rm -rf nam && mkdir nam && unzip -q nam.zip -d nam
b=$(find nam -type d -name neural_amp_modeler.lv2 | head -1); [ -n "$b" ] || { echo "neural_amp_modeler.lv2 not in the zip" >&2; exit 1; }
rm -rf "$OUT/neural_amp_modeler.lv2" && cp -r "$b" "$OUT/"

# x42 zeroconvolv : the bundle inside the official NSIS installer
fetch "$ZC_URL" "$ZC_SHA" zconvolver.exe
rm -rf zc && 7z x -y -ozc zconvolver.exe >/dev/null
b=$(find zc -type d -name zeroconvo.lv2 | head -1); [ -n "$b" ] || { echo "zeroconvo.lv2 not in the installer" >&2; exit 1; }
rm -rf "$OUT/zeroconvo.lv2" && cp -r "$b" "$OUT/"

# sfizz : the bundle inside the official Inno Setup installer, plus the controllers.ttl its build generates
fetch "$SFIZZ_URL" "$SFIZZ_SHA" sfizz.exe
rm -rf sfizz && innoextract -s -d sfizz sfizz.exe
b=$(find sfizz -type d -name sfizz.lv2 | head -1); [ -n "$b" ] || { echo "sfizz.lv2 not in the installer" >&2; exit 1; }
rm -rf "$OUT/sfizz.lv2" && cp -r "$b" "$OUT/"
python "$HERE/sfizz_controllers_ttl.py" "$OUT/sfizz.lv2/controllers.ttl" >/dev/null

# setBfree : rebuilt from its sources with the state-save fix (the x42 Windows build crashes the engine)
[ -d setBfree/.git ] || git clone -q "$SETBFREE_GIT" setBfree
git -C setBfree fetch -q origin && git -C setBfree checkout -q -f "$SETBFREE_REV" && git -C setBfree clean -qfdx
git -C setBfree apply "$HERE/setbfree-state-nul.patch"
make -C setBfree -j"$(nproc)" MOD=1 XWIN=x86_64-w64-mingw32 >/dev/null
rm -rf "$OUT/b_synth.lv2" && mkdir "$OUT/b_synth.lv2"
cp setBfree/b_synth/{b_synth.dll,b_synth.ttl,manifest.ttl,modgui.ttl} "$OUT/b_synth.lv2/"

for b in neural_amp_modeler zeroconvo sfizz b_synth; do test -f "$OUT/$b.lv2/manifest.ttl" || { echo "$b.lv2 incomplete" >&2; exit 1; }; done
echo "engine LV2 plugins -> $OUT: $(ls "$OUT" | tr '\n' ' ')"
