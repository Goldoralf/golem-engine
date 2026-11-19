#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the Golem Engine for Windows, natively, in an MSYS2 UCRT64 shell — the Windows counterpart of ci-build.sh
# (golem's docs/ardour-plan.md, Windows port, 2026-11-19). Run from the root of the repository:
#     golem/tools/win-build.sh            # installs the MSYS2 packages it needs, configures, builds
# What it encodes, each learnt on the first Windows build:
#   · UCRT64, not MINGW64: MSYS2 dropped part of the MINGW64 packages (lilv, lv2, glibmm, rubberband…).
#   · --cxx17: gcc 16 defaults to C++20, where Ardour's u8"…" literals become char8_t and no longer compile.
#   · COMSPEC exported: waf runs its rules through Python's subprocess with a shell; without COMSPEC (an MSYS2 login
#     shell started from another bash does not always keep it) every such rule fails with cmd.exe's "syntax error".
#   · --windows-key=Mod4: the default "Mod4><Super" holds shell redirection characters; the engine has no keys anyway.
#   · backends portaudio,dummy: PortAudio is the Windows audio backend (ASIO needs a PortAudio built with the ASIO SDK:
#     a later step); the dummy backend serves the benches.
set -euo pipefail
[ "${MSYSTEM:-}" = UCRT64 ] || { echo "run this in an MSYS2 UCRT64 shell (MSYSTEM=UCRT64)" >&2; exit 2; }
test -f gtk2_ardour/wscript || { echo "run this at the root of the golem-engine repository" >&2; exit 2; }
P=mingw-w64-ucrt-x86_64
pkgs=""
for n in toolchain pkgconf python boost glibmm libsndfile curl libarchive liblo taglib vamp-plugin-sdk rubberband \
         fftw aubio libxml2 cppunit cairomm pangomm cairo pango libsamplerate lv2 serd sord sratom lilv libwebsockets \
         portaudio soundtouch libusb fontconfig freetype harfbuzz libpng libjpeg-turbo libtiff fribidi; do
  pkgs="$pkgs $P-$n"
done
pacman -S --needed --noconfirm $pkgs git patch
export COMSPEC="${COMSPEC:-$(cygpath -w "${SYSTEMROOT:-C:\\Windows}")\\System32\\cmd.exe}"
python ./waf configure --program-name="Golem Engine" --dist-target=mingw --no-dr-mingw --cxx17 --windows-key=Mod4 \
  --with-backends=portaudio,dummy --optimize --no-lrdf --no-phone-home --no-nls
python ./waf build -j"$(nproc)"
