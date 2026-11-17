ardour {
	["type"]    = "dsp",
	name        = "golem Zone",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[Keyboard zone: notes outside [Zone Low..Zone High] are dropped, the others transposed. Everything else passes.]]
}

-- SPDX-License-Identifier: MIT
-- Le portage à l'identique de reaper/Effects/note-zone.jsfx (golem) pour le Golem Engine (docs/ardour-plan.md §7d) :
--   - note-on / note-off HORS de [Zone Low..Zone High] : éliminés ;
--   - dans la zone : note + Transpose, bornée 0..127 ;
--   - un note-OFF suit la note réellement ENVOYÉE par son note-on (mémorisée par canal et par note) : changer la
--     transposition en tenant des notes ne laisse aucune note fantôme ;
--   - CC, pitch-bend, aftertouch, program, SysEx : passent toujours, inchangés.

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "Zone Low", min = 0, max = 127, default = 0, integer = true },
		{ ["type"] = "input", name = "Zone High", min = 0, max = 127, default = 127, integer = true },
		{ ["type"] = "input", name = "Transpose", min = -24, max = 24, default = 0, integer = true },
	}
end

local active = {}                       -- active[ch*128 + note + 1] = note ENVOYÉE + 1 ; 0 = rien (aucune allocation au jeu)

function dsp_init (rate)
	for i = 1, 16 * 128 do active[i] = 0 end
end

function dsp_run (_, _, n_samples)
	local ctrl = CtrlPorts:array ()
	local lo, hi, tr = math.floor (ctrl[1] + 0.5), math.floor (ctrl[2] + 0.5), math.floor (ctrl[3] + 0.5)
	if lo > hi then lo, hi = hi, lo end   -- des bornes inversées sont tolérées
	local cnt = 1
	for _, ev in ipairs (midiin) do
		local d = ev.data
		local st, ch = d[1] & 0xF0, d[1] & 0x0F
		if st == 0x90 and d[3] > 0 then
			if d[2] >= lo and d[2] <= hi then
				local nn = d[2] + tr
				if nn < 0 then nn = 0 elseif nn > 127 then nn = 127 end
				active[ch * 128 + d[2] + 1] = nn + 1
				midiout[cnt] = { time = ev.time, data = { d[1], nn, d[3] } }
				cnt = cnt + 1
			end
		elseif st == 0x80 or (st == 0x90 and d[3] == 0) then
			local sl = active[ch * 128 + d[2] + 1]
			if sl > 0 then
				active[ch * 128 + d[2] + 1] = 0
				midiout[cnt] = { time = ev.time, data = { d[1], sl - 1, d[3] } }
				cnt = cnt + 1
			end
		else
			midiout[cnt] = { time = ev.time, data = d }
			cnt = cnt + 1
		end
	end
end
