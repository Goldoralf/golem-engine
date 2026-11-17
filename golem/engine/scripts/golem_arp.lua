ardour {
	["type"]    = "dsp",
	name        = "golem Arp",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[Arpeggiator in front of a keyboard instrument: held notes are played one after the other, in time with the BPM. Off = everything passes.]]
}

-- SPDX-License-Identifier: MIT
-- L'arpégiateur d'un instrument de clavier sur le Golem Engine (golem docs/ardour-plan.md §7d). Sous REAPER, golem pose
-- le JSFX de série midi_arp avec des configurations nommées (golem_rig.lua, ARP_CONFIGS : Rate ×BPM, Mode, une
-- variante à +12) ; celui-ci est écrit pour golem, avec les mêmes réglages utiles :
--   On         0 = tout passe ; 1 = les notes tenues sont arpégées (les note-on/off du clavier sont avalés)
--   Rate       pas par temps : 1 = noire, 2 = croche, 4 = double-croche
--   Mode       0 descend, 1 monte, 2 descend puis monte, 3 monte puis descend
--   Octaves    0 = les notes tenues ; 1 = puis les mêmes une octave au-dessus
--   Length     durée de chaque note, en part du pas (0,7 : un arpège qui respire)
--   BPM        le tempo du morceau, posé par le veilleur
-- La vélocité jouée est celle reçue. CC, pitch-bend, aftertouch, program, SysEx passent toujours.

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "On", min = 0, max = 1, default = 0, toggled = true },
		{ ["type"] = "input", name = "Rate", min = 1, max = 8, default = 2, integer = true },
		{ ["type"] = "input", name = "Mode", min = 0, max = 3, default = 1, integer = true },
		{ ["type"] = "input", name = "Octaves", min = 0, max = 2, default = 0, integer = true },
		{ ["type"] = "input", name = "Length", min = 0.05, max = 1, default = 0.7 },
		{ ["type"] = "input", name = "BPM", min = 30, max = 300, default = 120 },
	}
end

local rate = 48000
local held = {}                         -- held[note + 1] = vélocité (0 = relâchée)
local nheld = 0
local seq, nseq = {}, 0                 -- la suite à jouer, recalculée quand les notes tenues changent
local step = 0                          -- rang du prochain pas dans la suite
local to_step = 0                       -- échantillons avant le prochain pas
local sounding, to_off, chan = -1, 0, 0 -- la note en cours, échantillons avant son note-off, son canal
local was_on = false
local out, nout = {}, 0

function dsp_init (r)
	rate = r
	for i = 1, 128 do held[i] = 0 end
end

local function rebuild (mode, octs)
	local up, n = {}, 0
	for o = 0, octs do
		for note = 0, 127 do
			if held[note + 1] > 0 and note + 12 * o <= 127 then n = n + 1; up[n] = note + 12 * o end
		end
	end
	nseq = 0
	local function add (v) nseq = nseq + 1; seq[nseq] = v end
	if mode == 1 then for i = 1, n do add (up[i]) end
	elseif mode == 0 then for i = n, 1, -1 do add (up[i]) end
	elseif mode == 3 then
		for i = 1, n do add (up[i]) end
		for i = n - 1, 2, -1 do add (up[i]) end
	else
		for i = n, 1, -1 do add (up[i]) end
		for i = 2, n - 1 do add (up[i]) end
	end
end

local function emit (time, data)
	nout = nout + 1
	out[nout] = { time = time, data = data }
end

function dsp_run (_, _, n_samples)
	local ctrl = CtrlPorts:array ()
	local on = ctrl[1] > 0.5
	local mode, octs = math.floor (ctrl[3] + 0.5), math.floor (ctrl[4] + 0.5)
	local step_len = math.max (64, math.floor (rate * 60 / math.max (30, ctrl[6]) / math.max (1, math.floor (ctrl[2] + 0.5))))
	nout = 0
	if was_on and not on then                              -- coupé : la note en cours s'arrête, plus rien de tenu
		if sounding >= 0 then emit (1, { 0x80 | chan, sounding, 0 }); sounding = -1 end
		for i = 1, 128 do held[i] = 0 end
		nheld, nseq = 0, 0
	end
	was_on = on
	local changed = false
	for _, ev in ipairs (midiin) do
		local d = ev.data
		local st = d[1] & 0xF0
		if on and st == 0x90 and d[3] > 0 then
			if held[d[2] + 1] == 0 then nheld = nheld + 1 end
			held[d[2] + 1] = d[3]
			chan = d[1] & 0x0F
			if nheld == 1 then step = 0; to_step = ev.time - 1 end   -- la première note part tout de suite
			changed = true
		elseif on and (st == 0x80 or (st == 0x90 and d[3] == 0)) then
			if held[d[2] + 1] > 0 then nheld = nheld - 1; held[d[2] + 1] = 0; changed = true end
		else
			emit (ev.time, d)
		end
	end
	if not on then
		for i = 1, nout do midiout[i] = out[i] end
		return
	end
	if changed then rebuild (mode, octs) end
	-- le temps avance d'un cycle : la fin de la note en cours, puis les pas qui tombent dans ce cycle
	local t = 0
	while t < n_samples do
		local next_ev = n_samples - t
		if sounding >= 0 and to_off < next_ev then next_ev = to_off end
		if nseq > 0 and to_step < next_ev then next_ev = to_step end
		if next_ev < 0 then next_ev = 0 end
		t = t + next_ev
		if sounding >= 0 then to_off = to_off - next_ev end
		if nseq > 0 then to_step = to_step - next_ev end
		if t >= n_samples then break end
		if sounding >= 0 and to_off <= 0 then
			emit (t + 1, { 0x80 | chan, sounding, 0 })
			sounding = -1
		elseif nseq > 0 and to_step <= 0 then
			if sounding >= 0 then emit (t + 1, { 0x80 | chan, sounding, 0 }) end
			local note = seq[(step % nseq) + 1]
			local base = note
			while base > 127 or held[base + 1] == 0 do base = base - 12; if base < 0 then break end end
			local vel = (base >= 0 and held[base + 1] > 0) and held[base + 1] or 100
			emit (t + 1, { 0x90 | chan, note, vel })
			sounding = note
			to_off = math.max (1, math.floor (step_len * ctrl[5]))
			step = step + 1
			to_step = step_len
		else
			break
		end
	end
	if nseq == 0 and sounding >= 0 and to_off > n_samples then to_off = 1 end   -- plus rien de tenu : la note s'éteint
	for i = nout + 1, #out do out[i] = nil end              -- le tableau est réutilisé : rien d'un cycle d'avant
	table.sort (out, function (a, b) return a.time < b.time end)
	for i = 1, nout do midiout[i] = out[i] end
end
