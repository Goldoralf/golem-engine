# Environnement de dev du Golem Engine : lancer les binaires depuis build/ sans installer.
TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
libs=$TOP/build/libs
# le PAQUET (golem/tools/bundle.py) a la forme de l'arbre de dev, plus `deps/` : les bibliothèques du système qu'il
# emporte — après les nôtres, avant celles de la machine
deps=""; [ -d "$TOP/deps" ] && deps="$TOP/deps:"
export LD_LIBRARY_PATH="$(find "$libs" -name '*.so*' -printf '%h\n' | sort -u | tr '\n' ':')${deps}${LD_LIBRARY_PATH:-}"
export ARDOUR_SURFACES_PATH=$libs/surfaces/osc:$libs/surfaces/mcp_http:$libs/surfaces/websockets:$libs/surfaces/generic_midi
export ARDOUR_PANNER_PATH=$libs/panners
# golem/engine d'abord : ses scripts/ (le limiteur golem Safety, DSP Lua) sont trouvés comme ceux d'Ardour
export ARDOUR_DATA_PATH=$TOP/golem/engine:$TOP/share:$TOP/build:$TOP/gtk2_ardour:$TOP/build/gtk2_ardour
export ARDOUR_MIDIMAPS_PATH=$TOP/share/midi_maps
export ARDOUR_MIDI_PATCH_PATH=$TOP/share/patchfiles
export ARDOUR_EXPORT_FORMATS_PATH=$TOP/share/export
export ARDOUR_BACKEND_PATH=$libs/backends/dummy:$libs/backends/alsa
export ARDOUR_CONFIG_PATH=$TOP:$TOP/gtk2_ardour:$TOP/build:$TOP/build/gtk2_ardour
export ARDOUR_DLL_PATH=$libs
export ARDOUR_MCP_PATH=$TOP/share/mcp
export VAMP_PATH=$libs/vamp-plugins
# configuration isolée : ne touche pas un ~/.config/ardour9 éventuel
# la config du moteur : dans l'arbre de dev par défaut ; un paquet installé (fichier VERSION) n'écrit JAMAIS dans son
# dossier d'installation — ~/.config/golem-engine9, comme tout programme
if [ -n "${GOLEM_ENGINE_CONFIG:-}" ]; then export XDG_CONFIG_HOME="$GOLEM_ENGINE_CONFIG"
elif [ ! -f "$TOP/VERSION" ]; then export XDG_CONFIG_HOME="$TOP/golem/dev/config"; fi
