#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Construit le Golem Engine et son paquet (golem/tools/bundle.py) sur une Ubuntu/Debian NUE — ce que la CI de
# Goldoralf/golem-binaries lance dans un conteneur de la plus vieille distribution visée (le paquet demande au moins la
# glibc de sa construction). Se lance à la racine du dépôt, en root dans le conteneur :
#     golem/tools/ci-build.sh [version]        -> build/bundle/golem-engine-<version>-linux-<arch>.tar.gz
# Les dépendances sont celles d'Ardour pour `--with-backends=alsa,dummy` ; l'interface graphique est construite (waf
# ne sait pas s'en passer) mais n'entre pas dans le paquet.
set -euo pipefail
VERSION="${1:-}"
export DEBIAN_FRONTEND=noninteractive
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq --no-install-recommends \
  build-essential git python3 python-is-python3 pkg-config ca-certificates \
  libboost-dev libasound2-dev libglibmm-2.4-dev libsndfile1-dev libcurl4-gnutls-dev libarchive-dev liblo-dev \
  libtag1-dev vamp-plugin-sdk librubberband-dev libudev-dev libusb-1.0-0-dev libfftw3-dev libaubio-dev libxml2-dev \
  libcppunit-dev libcairomm-1.0-dev libpangomm-1.4-dev libcairo2-dev libpango1.0-dev liblrdf0-dev libsamplerate0-dev \
  lv2-dev libserd-dev libsord-dev libsratom-dev liblilv-dev libwebsockets-dev libxrandr-dev libxinerama-dev \
  libxext-dev libx11-dev libxi-dev libxcursor-dev libxcomposite-dev libxdamage-dev libxfixes-dev libxrender-dev \
  libfontconfig1-dev libfreetype-dev libpng-dev libjpeg-dev libtiff-dev libharfbuzz-dev libfribidi-dev libepoxy-dev \
  libsoundtouch-dev libdbus-1-dev libreadline-dev libcwiid-dev libpulse-dev libjack-jackd2-dev itstool gettext
python3 ./waf configure --program-name="Golem Engine" --with-backends=alsa,dummy --optimize
python3 ./waf build -j"$(nproc)"
python3 golem/tools/bundle.py ${VERSION:+--version "$VERSION"}
