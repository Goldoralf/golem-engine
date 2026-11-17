ardour {
	["type"]    = "dsp",
	name        = "golem Click",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[golem's metronome: a free-running click in time with the BPM, with accents by beat groups and a silent clock.]]
}

-- SPDX-License-Identifier: MIT
-- Le métronome de golem pour le Golem Engine (golem docs/ardour-plan.md §7d, lot 3), portage du compteur et du son de
-- reaper/Effects/golem_click.jsfx :
--   - une horloge qui tourne TRANSPORT ARRÊTÉ : un accumulateur fractionnaire d'échantillons (aucune dérive) ;
--   - la MESURE : `Beats` pulsations d'unité `Den` (le BPM désigne toujours la noire), `Div` subdivisions par pulsation ;
--     un pas = 240 / (BPM × Den × Div) secondes ;
--   - les ACCENTS : `Groups` est un masque de bits, le bit i dit que la pulsation i démarre un groupe (3+2+2 = 41) ;
--   - le SON : sinus, attaque 1 ms, −60 dB en 25 ms ; le « 1 » = 1000 Hz plein, un début de groupe = 800 Hz plein,
--     une autre pulsation = 800 Hz à −3 dB, une subdivision = 800 Hz à −8 dB ;
--   - `Clock` : l'horloge tourne SANS son (un arrangement compte ses mesures même quand le groupe ne veut pas de click).
-- Le tempo (`BPM`) est posé par le veilleur depuis celui du morceau. TÉMOINS, dans la mémoire partagée de l'instance
-- (2 entiers) : [0] le nombre de pas émis, [1] le tempo vu × 100 — la preuve que le fil audio tourne.
-- LE CLICK JOUÉ PAR UNE GRILLE (`Grid` = 1, posé par le veilleur pendant qu'un standard joue) : deux horloges libres au
-- même tempo ne sont jamais en phase — le click devient donc des ÉVÉNEMENTS de la grille, joués par le séquenceur des
-- accords et reçus ici en MIDI (canal 16) : note 76 = le « 1 », 77 = un autre temps, 78 = une subdivision. Le compteur
-- interne se tait pendant ce temps, et reprend à l'identique ensuite.
-- Pas encore ici : les temps d'un morceau (carte des mesures d'une backing) et le recalage sur le transport.

function dsp_ioconfig ()
	return { { midi_in = 1, audio_in = 0, audio_out = 2 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "On", min = 0, max = 1, default = 0, toggled = true },
		{ ["type"] = "input", name = "Level", min = -60, max = 6, default = -12, unit = "dB" },
		{ ["type"] = "input", name = "Beats", min = 1, max = 32, default = 4, integer = true },
		{ ["type"] = "input", name = "Div", min = 1, max = 4, default = 1, integer = true },
		{ ["type"] = "input", name = "Den", min = 1, max = 16, default = 4, integer = true },
		{ ["type"] = "input", name = "Groups", min = 0, max = 4294967295, default = 1, integer = true },
		{ ["type"] = "input", name = "Clock", min = 0, max = 1, default = 0, toggled = true },
		{ ["type"] = "input", name = "BPM", min = 20, max = 400, default = 120 },
		{ ["type"] = "input", name = "Grid", min = 0, max = 1, default = 0, toggled = true },
	}
end

local rate = 48000
local acc, beat_idx, ticks = 0, 0, 0     -- échantillons avant le prochain pas (fractionnaire), son rang, le compte
local was_run = false
local env, atk_rem, phase, om, vgain = 0, 0, 0, 0, 0
local atk_inc, dec = 0, 0

function dsp_init (r)
	rate = r
	atk_inc = 1 / math.max (1, 0.001 * rate)
	dec = math.exp (-6.907755 / math.max (1, 0.025 * rate))      -- ln(1000) : −60 dB en 25 ms
	self:shmem ():allocate (2)
	self:shmem ():clear ()
end

function dsp_run (_, outs, n_samples)
	local ctrl = CtrlPorts:array ()
	local on = ctrl[1] > 0.5
	local run = on or ctrl[7] > 0.5
	local bt = math.max (1, math.min (32, math.floor (ctrl[3] + 0.5)))
	local dv = math.max (1, math.min (4, math.floor (ctrl[4] + 0.5)))
	local dn = math.max (1, math.min (16, math.floor (ctrl[5] + 0.5)))
	local gmask = math.floor (ctrl[6] + 0.5)
	local bpm = math.max (20, ctrl[8])
	local nsteps = bt * dv
	local spb = rate * 240 / (bpm * dn * dv)
	local gain = 10 ^ (ctrl[2] / 20)
	local l, r = outs[1]:array (), outs[2]:array ()
	ARDOUR.DSP.memset (outs[1], 0, n_samples)
	ARDOUR.DSP.memset (outs[2], 0, n_samples)
	if run and not was_run then acc, beat_idx, env, atk_rem = 0, 0, 0, 0 end   -- remis en route : il repart sur le « 1 »
	was_run = run
	local from = 1                                   -- premier échantillon pas encore rendu de ce cycle
	local function render (to)                       -- la voix en cours, de `from` à `to` compris
		if env <= 0.00001 and atk_rem <= 0 then from = to + 1; return end
		for s = from, to do
			if atk_rem > 0 then
				env = env + atk_inc
				atk_rem = atk_rem - 1
			else
				env = env * dec
			end
			local v = math.sin (phase) * env * vgain * gain
			phase = phase + om
			l[s] = v
			r[s] = v
		end
		from = to + 1
	end
	local grid = ctrl[9] > 0.5
	if grid then                                     -- le click de la grille : une voix par note reçue, à sa place
		for _, ev in ipairs (midiin) do
			local d = ev.data
			if (d[1] & 0xF0) == 0x90 and (d[1] & 0x0F) == 15 and d[3] > 0 and d[2] >= 76 and d[2] <= 78 then
				local at = math.max (1, math.min (n_samples, ev.time))
				if at > from then render (at - 1) end
				om = 2 * math.pi * (d[2] == 76 and 1000 or 800) / rate
				vgain = d[2] == 78 and 0.398 or (d[2] == 76 and 1 or 0.708)
				if on then phase, env, atk_rem = 0, 0, math.ceil (0.001 * rate) end
				ticks = ticks + 1
			end
		end
		was_run = false                               -- la grille finie, le compteur repartira sur le « 1 »
	elseif run then
		while acc < n_samples do                     -- chaque pas qui tombe dans ce cycle
			local at = math.floor (acc) + 1
			if at > from then render (at - 1) end
			local pi = beat_idx // dv
			local sub = (beat_idx - pi * dv) > 0
			local grp = (not sub) and ((gmask >> pi) & 1) == 1
			om = 2 * math.pi * ((pi == 0 and not sub) and 1000 or 800) / rate
			vgain = sub and 0.398 or ((pi == 0 or grp) and 1 or 0.708)
			if on then phase, env, atk_rem = 0, 0, math.ceil (0.001 * rate) end   -- horloge silencieuse : on compte, sans sonner
			beat_idx = (beat_idx + 1) % nsteps
			acc = acc + spb                           -- += : la fraction est gardée, aucune dérive
			ticks = ticks + 1
		end
		acc = acc - n_samples
	end
	if from <= n_samples then render (n_samples) end
	local shm = self:shmem ()
	shm:atomic_set_int (0, ticks % 1000000000)
	shm:atomic_set_int (1, math.floor (bpm * 100 + 0.5))
end
