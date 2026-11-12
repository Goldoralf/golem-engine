-- SPDX-License-Identifier: GPL-2.0-or-later
-- LA STÉRÉO D'UNE CHAÎNE, partagée par le veilleur (golem_watch.lua) et le banc de parité de golem
-- (tools/engine-render-case.lua) : le banc teste ainsi le code même du rack (docs/ardour-plan.md §7c, A3).
--
-- Ce que fait REAPER (mesuré 2026-11-12, tools/check-engine-parity.py) : une piste golem a 2 canaux, l'entrée mono y est
-- sur les deux ; un plugin MONO voit le canal 1 et sa sortie va sur les DEUX canaux ; un plugin STÉRÉO reçoit la DI sur
-- ses deux entrées et rend deux canaux différents (chorus, ping-pong…).
-- Ici, sans doubler le calcul (un NAM ne tourne qu'une fois) : la route reste MONO tant que ses plugins le sont — un port
-- de sortie relié aux deux sorties de la carte, comme le « mono vers les deux » de REAPER — et passe en STÉRÉO au
-- premier plugin stéréo : ses deux entrées reçoivent le canal mono (Ardour : « copier le premier tampon vers les
-- autres »), ses deux sorties deviennent les deux canaux de la route. Un plugin mono ensuite est doublé par Ardour.

local M = {}

local AUDIO = ARDOUR.DataType ("audio")

-- le plugin d'un processeur a-t-il deux entrées audio (stéréo) ?
function M.is_stereo (proc)
	local pi = proc:to_insert ()
	return not pi:isnil () and pi:natural_input_streams ():n_audio () >= 2 and pi:natural_output_streams ():n_audio () >= 2
end

-- passer la route en stéréo À ce plugin : deux sorties, les deux entrées sur le canal 1, la sortie de la route à 2 ports
function M.go_stereo (route, proc)
	route:customize_plugin_insert (proc, 1, ARDOUR.ChanCount (AUDIO, 2), ARDOUR.ChanCount (AUDIO, 0))
	local m = ARDOUR.ChanMapping ()
	m:set (AUDIO, 0, 0)                      -- broche 0 <- tampon 0
	m:set (AUDIO, 1, 0)                      -- broche 1 <- tampon 0 : la DI sur les deux entrées, comme REAPER
	proc:to_insert ():set_input_map (0, m)
	while route:output ():n_ports ():n_audio () < 2 do route:output ():add_port ("", AUDIO) end
end

-- ajoute `proc` en fin de chaîne de `route` dont le nombre de canaux est `nch` ; rend le nouveau nombre de canaux
function M.add (route, proc, nch)
	route:add_processor_by_index (proc, -1, nil, true)
	if nch < 2 and M.is_stereo (proc) then
		M.go_stereo (route, proc)
		return 2
	end
	return nch
end

return M
