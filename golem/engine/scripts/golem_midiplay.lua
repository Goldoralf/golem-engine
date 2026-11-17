ardour {
	["type"]    = "dsp",
	name        = "golem Midiplay",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[Plays a list of MIDI events once, sample-accurately, into what follows it: golem's sound demos play a reference phrase through a keyboard or drum lane without anyone at the keys. Its events are written by golem's engine watcher.]]
}

-- SPDX-License-Identifier: MIT
-- Le lecteur d'une phrase MIDI de référence pour le Golem Engine (golem docs/ardour-plan.md §7d, l'écoute sans jouer) :
-- posé EN TÊTE d'une piste MIDI le temps d'un rendu, il joue UNE fois une liste d'événements datés en ÉCHANTILLONS —
-- sous REAPER, golem_preview pose un item MIDI sur la piste clonée. Ce qui arrive du clavier passe.
--   `Channel` : 0 = tous les événements ; 1..16 = seulement ceux de ce canal (une lane dépliée : les touches d'un côté,
--   les pads de l'autre, comme en jeu).
-- Mémoire partagée (entiers), écrite par golem_watch.lua :
--   [0] nonce (EN DERNIER)  [1] op : 1 joue depuis le début · 0 stop   [8] joue   [16] nombre d'événements
--   [64…] événements, triés : échantillon, octet de statut (canal compris), donnée 1, donnée 2

local EV_BASE, EV_STRIDE, MAX_EV = 64, 4, 32768
local SIZE = EV_BASE + MAX_EV * EV_STRIDE

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return { { ["type"] = "input", name = "Channel", min = 0, max = 16, default = 0, integer = true } }
end

local playing, pos, idx, last_nonce = false, 0, 0, -1
local active = {}                         -- active[canal*128 + note + 1] : la note sonne (pour l'arrêter proprement)

function dsp_init (rate)
	self:shmem ():allocate (SIZE)
	self:shmem ():clear ()
	for i = 1, 16 * 128 do active[i] = false end
end

function dsp_run (_, _, n_samples)
	local shm = self:shmem ()
	local t = shm:to_int (0):array ()
	local cnt = 1
	for _, ev in ipairs (midiin) do
		midiout[cnt] = ev
		cnt = cnt + 1
	end
	local function off_all ()
		for i = 1, 16 * 128 do
			if active[i] then
				midiout[cnt] = { time = 1, data = { 0x80 | ((i - 1) // 128), (i - 1) % 128, 0 } }
				cnt = cnt + 1
				active[i] = false
			end
		end
	end
	local nonce = shm:atomic_get_int (0)
	if nonce ~= last_nonce then
		last_nonce = nonce
		off_all ()
		playing, pos, idx = t[2] == 1 and t[17] > 0, 0, 0
	end
	if playing then
		local want = math.floor (CtrlPorts:array ()[1] + 0.5)
		local nev, lim = t[17], pos + n_samples
		while idx < nev do
			local ea = EV_BASE + idx * EV_STRIDE
			local at = t[ea + 1]
			if at >= lim then break end
			local st, d1, d2 = t[ea + 2], t[ea + 3], t[ea + 4]
			local ch, kind = st & 0x0F, st & 0xF0
			if want == 0 or ch == want - 1 then
				midiout[cnt] = { time = math.max (1, at - pos + 1), data = { st, d1, d2 } }
				cnt = cnt + 1
				if kind == 0x90 and d2 > 0 then active[ch * 128 + d1 + 1] = true
				elseif kind == 0x80 or kind == 0x90 then active[ch * 128 + d1 + 1] = false end
			end
			idx = idx + 1
		end
		pos = lim
		if idx >= nev then playing = false end
	end
	shm:atomic_set_int (8, playing and 1 or 0)
end
