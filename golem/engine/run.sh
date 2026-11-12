#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Lance le Golem Engine pour golem : luasession + le veilleur (golem_watch.lua), sans interface.
#   run.sh <golem-root> [session-dir] [backend] [device]
# Écrit son PID dans <golem-root>/presets/.engine.pid avant de se remplacer par luasession (exec) : le bridge lit
# ce PID pour savoir si le moteur tourne et pour l'arrêter (bridge/engine/ardour.py).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/../.." && pwd)"
ROOT="${1:?golem root}"
SESSION="${2:-$ROOT/sets/golem-engine}"   # dans golem : état local, comme sets/golem-set.rpp
BACKEND="${3:-None (Dummy)}"
DEVICE="${4:-}"
mkdir -p "$(dirname "$SESSION")" "$ROOT/presets"   # pas $SESSION lui-même : create_session refuse un dossier existant
# shellcheck source=../dev/env.sh
source "$TOP/golem/dev/env.sh"
LUA="$TOP/build/luasession/luasession"
# la surface OSC n'a qu'un client, le bridge local : pas d'annonce avahi de son port sur le réseau (patch [headless] de
# libs/surfaces/osc/osc.cc). Le port lui-même écoute sur toutes les interfaces (liblo 0.31 ne sait pas lier une seule
# adresse en UDP) : c'est le pare-feu de golem (provision/harden.sh : deny in) qui le ferme.
export ARDOUR_OSC_NO_ZEROCONF=1
# un appareil MIDI branché APRÈS le démarrage reste FERMÉ (patch [headless] du backend ALSA) : le veilleur n'ouvre que le
# clavier d'une lane. Sans ça, Ardour s'abonnait au lecteur du pédalier du bridge (aseqdump) relancé après lui, et
# chaque redémarrage du moteur coupait le pédalier un instant (mesuré 2026-11-12)
export ARDOUR_ALSA_MIDI_NO_HOTPLUG_OPEN=1
# les NOMS DE PARAMÈTRES en anglais quelle que soit la langue du système : golem retrouve un potard par son nom
# (catalogue) et lilv traduit les plugins (sfizz en français : « Polyphonie », « Nombre de régions »), mesuré 2026-11-12
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# LES VST3 (Proteus, Surge XT Effects, Prisma, ZamGrains, Vital) : Ardour sans interface ne lit que son CACHE VST3, que
# rien ne remplit -> le scanner d'Ardour (process séparé : un plugin qui plante ne tue pas le moteur), avant chaque
# démarrage ; il saute ce qui est déjà en cache (quelques ms par bundle)
SCAN="$TOP/build/libs/fst/ardour-vst3-scanner"
if [ -x "$SCAN" ]; then
  for d in "$HOME/.vst3" /usr/lib/vst3 /usr/local/lib/vst3; do
    [ -d "$d" ] || continue
    for b in "$d"/*.vst3; do [ -e "$b" ] && timeout 30 "$SCAN" -q "$b" >/dev/null 2>&1 || true; done
  done
fi
# un plantage laisse un core (apport, /var/lib/apport/coredump) : la pile d'appels se lit ensuite avec gdb
ulimit -c unlimited 2>/dev/null || true
echo $$ > "$ROOT/presets/.engine.pid"
exec "$LUA" "$HERE/golem_watch.lua" "$ROOT" "$SESSION" "$BACKEND" "$DEVICE"
