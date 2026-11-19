"""Le controllers.ttl de sfizz 1.2.3, que son installeur Windows n'emporte pas (il est GÉNÉRÉ au build par
cmake/LV2Config.cmake generate_lv2_controllers_ttl) : reproduit à l'identique, réglages par défaut du projet —
MIDI_CC_COUNT 512, PLUGIN_LV2_PSA ON (les CC < 128 sont automatisés côté plugin : pas de paramètre LV2 pour eux)."""
import sys

URI, NAME, COUNT, PSA = "http://sfztools.github.io/sfizz", "sfizz", 512, True
out = ["# LV2 parameters for MIDI CC controllers\n"
       "@prefix atom:   <http://lv2plug.in/ns/ext/atom#> .\n"
       "@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .\n"
       "@prefix midi:   <http://lv2plug.in/ns/ext/midi#> .\n"
       "@prefix patch:  <http://lv2plug.in/ns/ext/patch#> .\n"
       "@prefix rdfs:   <http://www.w3.org/2000/01/rdf-schema#> .\n"
       f"@prefix {NAME}:  <{URI}#> .\n"]
for i in range(COUNT):
    if i < 128 and PSA:
        continue
    s = f"{i:03d}"
    out.append(f"\n{NAME}:cc{s}\n  a lv2:Parameter ;\n  rdfs:label \"Controller {s}\" ;\n  rdfs:range atom:Float ;\n"
               f"  lv2:minimum 0.0 ;\n  lv2:maximum 1.0")
    if i < 128 and not PSA:
        out.append(f" ;\n  midi:binding \"B0{i:02X}00\"^^midi:MidiEvent .\n")
    else:
        out.append(" .\n")
ids = ", ".join(f"{NAME}:cc{i:03d}" for i in range(128 if PSA else 0, COUNT))
out.append(f"\n<{URI}>\n  a lv2:Plugin ;\n  patch:readable {ids} ;\n  patch:writable {ids} .\n")
open(sys.argv[1], "w", encoding="utf-8", newline="\n").write("".join(out))
print("written", sys.argv[1])
