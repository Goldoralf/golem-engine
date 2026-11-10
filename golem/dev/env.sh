# Environnement de dev du Golem Engine : lancer les binaires depuis build/ sans installer.
TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
libs=$TOP/build/libs
export LD_LIBRARY_PATH="$(find "$libs" -name '*.so*' -printf '%h\n' | sort -u | tr '\n' ':')${LD_LIBRARY_PATH:-}"
export ARDOUR_SURFACES_PATH=$libs/surfaces/osc:$libs/surfaces/mcp_http:$libs/surfaces/websockets:$libs/surfaces/generic_midi
export ARDOUR_PANNER_PATH=$libs/panners
export ARDOUR_DATA_PATH=$TOP/share:$TOP/build:$TOP/gtk2_ardour:$TOP/build/gtk2_ardour
export ARDOUR_MIDIMAPS_PATH=$TOP/share/midi_maps
export ARDOUR_MIDI_PATCH_PATH=$TOP/share/patchfiles
export ARDOUR_EXPORT_FORMATS_PATH=$TOP/share/export
export ARDOUR_BACKEND_PATH=$libs/backends/dummy:$libs/backends/alsa
export ARDOUR_CONFIG_PATH=$TOP:$TOP/gtk2_ardour:$TOP/build:$TOP/build/gtk2_ardour
export ARDOUR_DLL_PATH=$libs
export ARDOUR_MCP_PATH=$TOP/share/mcp
export VAMP_PATH=$libs/vamp-plugins
# configuration isolée : ne touche pas un ~/.config/ardour9 éventuel
export XDG_CONFIG_HOME="${GOLEM_ENGINE_CONFIG:-$TOP/golem/dev/config}"
