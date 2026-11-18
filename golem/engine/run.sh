#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Lance le Golem Engine pour golem : luasession + le veilleur (golem_watch.lua), sans interface.
#   run.sh <golem-root> [session-dir] [backend] [device]
# Écrit son PID dans <golem-root>/presets/.engine.pid avant de se remplacer par luasession (exec) : le bridge lit
# ce PID pour savoir si le moteur tourne et pour l'arrêter (bridge/engine/ardour.py).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LE LANCEUR EST run.py (2026-11-18) : le même sur Linux, Windows et macOS. Ce script reste pour ceux qui l'appellent
# (golem provision/lib-engine.sh) ; il ne fait que passer la main — le PID écrit par run.py reste celui du moteur.
exec python3 "$HERE/run.py" "$@"
