#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# PortAudio WITH ASIO for the Windows Golem Engine (golem's docs/ardour-plan.md, Windows port, 2026-11-20).
# MSYS2's PortAudio has WASAPI, WDM-KS, DirectSound and MME, not ASIO: ASIO needs Steinberg's SDK, which was
# proprietary until 2.3.4 (2025-10-15), now dual-licensed "Steinberg ASIO License or GPL version 3" — compatible with
# Ardour's "GPL v2 or later" as GPL v3. This script builds PortAudio 19.7.0 (MSYS2's version) statically with ASIO into
# a private prefix; win-build.sh puts that prefix first in PKG_CONFIG_PATH, and the backend's configure then finds
# pa_asio.h (WITH_ASIO). Both downloads are pinned to their sha256; the SDK is never committed.
#     golem/tools/win-portaudio-asio.sh          # → .deps/portaudio-asio (prefix), .deps/src (sources, build)
set -euo pipefail
[ "${MSYSTEM:-}" = UCRT64 ] || { echo "run this in an MSYS2 UCRT64 shell (MSYSTEM=UCRT64)" >&2; exit 2; }
test -f gtk2_ardour/wscript || { echo "run this at the root of the golem-engine repository" >&2; exit 2; }
ROOT=$(pwd)
PREFIX="${GOLEM_PA_PREFIX:-$ROOT/.deps/portaudio-asio}"
SRC="$ROOT/.deps/src"
PA_URL=https://github.com/PortAudio/portaudio/archive/refs/tags/v19.7.0.tar.gz
PA_SHA=5af29ba58bbdbb7bbcefaaecc77ec8fc413f0db6f4c4e286c40c3e1b83174fa0
# https://www.steinberg.net/asiosdk redirects here (checked 2026-11-20)
ASIO_URL=https://download.steinberg.net/sdk_downloads/ASIO-SDK_2.3.4_2025-10-15.zip
ASIO_SHA=d5ebf0c20dd2c5f43771fd0c1418f4b361bf52434ee670097cfa6b3a335e2eca
fetch() {   # url sha file : downloaded once, checked every time
  [ -f "$3" ] || curl -fsSL -o "$3.part" "$1" && { [ ! -f "$3.part" ] || mv "$3.part" "$3"; }
  echo "$2  $3" | sha256sum -c --quiet - || { echo "$3: sha256 mismatch — not used" >&2; rm -f "$3"; exit 1; }
}
pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja unzip >/dev/null
mkdir -p "$SRC"
cd "$SRC"
fetch "$PA_URL" "$PA_SHA" portaudio-19.7.0.tar.gz
fetch "$ASIO_URL" "$ASIO_SHA" asiosdk-2.3.4.zip
rm -rf portaudio-19.7.0 ASIOSDK build-pa
tar xzf portaudio-19.7.0.tar.gz
unzip -q asiosdk-2.3.4.zip
cmake -S portaudio-19.7.0 -B build-pa -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DPA_BUILD_SHARED=OFF -DPA_BUILD_STATIC=ON -DPA_USE_ASIO=ON -DASIOSDK_ROOT_DIR="$SRC/ASIOSDK" \
  -DASIOSDK_INCLUDE_DIR="$SRC/ASIOSDK/common" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
# CMAKE_POLICY_VERSION_MINIMUM : cmake 4 refuses 19.7.0's cmake_minimum_required (2.8)
cmake --build build-pa | tail -1
cmake --install build-pa >/dev/null
test -f "$PREFIX/include/pa_asio.h" || { echo "pa_asio.h not installed: ASIO was not built" >&2; exit 1; }
echo "PortAudio 19.7.0 with ASIO -> $PREFIX (pkg-config: $PREFIX/lib/pkgconfig)"
