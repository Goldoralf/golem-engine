ardour {
	["type"]    = "dsp",
	name        = "golem Chordseq",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[golem's standards player: plays a rendered chord chart (comping, bass, drums, rhythm guitar, click) in time with the BPM. Its sequence is written by golem's engine watcher.]]
}

-- SPDX-License-Identifier: MIT
-- Le lecteur de STANDARDS de golem pour le Golem Engine (golem docs/ardour-plan.md §7d, lot 3), portage de
-- reaper/Effects/golem_chordseq.jsfx. Le musical (voicings, walking bass, comping) est rendu par le bridge
-- (bridge/standards.py) ; ici on ne fait que JOUER la séquence, à l'échantillon près, transport arrêté, au tempo (`BPM`).
-- Sous REAPER, une instance par partie lit la même banque et toutes avancent du même pas. Ici UNE SEULE instance émet
-- TOUTES les parties, chacune sur son canal — les pistes d'instrument l'écoutent, chacune la sienne : une seule horloge.
--     lane 0 accords -> canal 1   ·   1 basse -> canal 2   ·   2 batterie -> canal 10   ·   3 click -> canal 16
--     4 pompe (guitare) -> canal 4
-- LA SÉQUENCE vit dans la mémoire partagée de l'instance (entiers), écrite par golem_watch.lua :
--   [0] nonce (EN DERNIER : la commande est lue sur son front)  [1] op : 0 stop · 1 joue · 2 ARMÉE  [2] 1 = boucle  [3] ticks/noire
--   ARMÉE (la prise d'un standard, golem docs/compo.md §11) : la grille attend le transport et part AVEC lui, sa
--   position prise sur la sienne — le tick 0 tombe sur l'échantillon 0 de la prise. [12] armée  [14] l'échantillon du
--   transport où elle l'a pris  [15] celui de son premier événement. Une boucle armée reprend APRÈS le décompte ([20]).
--   [8] joue  [9] mesure (-1 à l'arrêt)  [10] temps  [11] battement  [13] position (ticks)
--   [16] nombre d'événements  [17] longueur  [18] une mesure  [19] 1 = chargée  [20] décompte (ticks)
--   [64…] événements : tick, note, vélocité (0 = note-off), lane

local CTL_NONCE, CTL_OP, CTL_LOOP, CTL_PPQ = 0, 1, 2, 3
local ST_PLAYING, ST_BAR, ST_BEAT, ST_HB, ST_PPQ = 8, 9, 10, 11, 13
local SEQ_NEV, SEQ_LEN, SEQ_BAR, SEQ_LOADED, SEQ_CIN = 16, 17, 18, 19, 20
local ST_ARMED, ST_T0, ST_FIRST = 12, 14, 15
local EV_BASE, EV_STRIDE, MAX_EV = 64, 4, 16384
local SIZE = EV_BASE + MAX_EV * EV_STRIDE
local EPS = 0.0000001
local CHAN = { [0] = 0, [1] = 1, [2] = 9, [3] = 15, [4] = 3 }

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return { { ["type"] = "input", name = "BPM", min = 20, max = 400, default = 120 } }
end

local rate = 48000
local playing, ppq, ev_cur, last_nonce, hb = false, 0, 0, -1, 0
local armed, taken, t0, first, blk_pos = false, false, -1, -1, -1
local active, nact = {}, 0                -- active[canal*128 + note + 1] = la note sonne
local t, cnt

function dsp_init (r)
	rate = r
	self:shmem ():allocate (SIZE)
	self:shmem ():clear ()
	for i = 1, 16 * 128 do active[i] = false end
end

local function g (ix) return t[ix + 1] end

local function out (time, a, b, c)
	midiout[cnt] = { time = time, data = { a, b, c } }
	cnt = cnt + 1
end

local function panic (at)                         -- tout ce qui sonne s'arrête : jamais de note tenue à l'arrêt
	if nact > 0 then
		for i = 1, 16 * 128 do
			if active[i] then
				out (at or 1, 0x80 | ((i - 1) // 128), (i - 1) % 128, 0)
				active[i] = false
			end
		end
	end
	nact = 0
end

local function emit (off, note, vel, lane)
	local ch = CHAN[lane]
	if not ch then return end
	local k = ch * 128 + note + 1
	if vel > 0 then
		out (off, 0x90 | ch, note, vel)
		if not active[k] then nact = nact + 1; active[k] = true end
	else
		out (off, 0x80 | ch, note, 0)
		if active[k] then nact = nact - 1; active[k] = false end
	end
end

function dsp_run (_, _, n_samples)
	local shm = self:shmem ()
	t = shm:to_int (0):array ()
	hb = hb + 1
	cnt = 1
	for _, ev in ipairs (midiin) do
		midiout[cnt] = ev
		cnt = cnt + 1
	end
	local ppqres = g (CTL_PPQ)
	if ppqres < 1 then ppqres = 960 end
	local nonce = shm:atomic_get_int (CTL_NONCE)
	if nonce ~= last_nonce then
		last_nonce = nonce
		armed, taken, t0, first = false, false, -1, -1
		if g (CTL_OP) == 1 and g (SEQ_LOADED) > 0 and g (SEQ_NEV) > 0 then
			panic ()
			playing, ppq, ev_cur = true, 0, 0
		elseif g (CTL_OP) == 2 and g (SEQ_LOADED) > 0 and g (SEQ_NEV) > 0 then
			panic ()
			playing, armed, ppq, ev_cur = false, true, 0, 0
		else
			playing = false
			panic ()
			ppq, ev_cur = 0, 0
		end
	end
	-- LE DÉPART ARMÉ. Ce que le moteur lit sur la timeline (le click-fichier d'un riff, une backing) sort en avance de
	-- la latence de sortie, pour tomber juste ; des notes fabriquées ICI, en direct, sortiraient en retard d'autant
	-- (mesuré 2026-11-17 : 280 échantillons). La grille court donc en avance de cette latence, et part PENDANT le
	-- pré-roulement du transport : sa position est celle du transport, moins ce qu'il reste de pré-roulement, plus
	-- la latence — elle commence à l'échantillon où cette position passe par zéro.
	blk_pos = -1
	local lead = 0
	if armed or (taken and first < 0) then
		local pre = Session:remaining_latency_preroll ()
		if pre > 0 or Session:transport_rolling () then
			blk_pos = Session:transport_sample () - pre + Session:worst_output_latency ()
			if armed and blk_pos + n_samples > 0 then
				local bpm0 = math.max (20, CtrlPorts:array ()[1])
				armed, taken, playing, t0 = false, true, true, blk_pos
				if blk_pos < 0 then lead, ppq = -blk_pos, 0 else ppq = blk_pos * bpm0 * ppqres / (60 * rate) end
				ev_cur = 0
			end
		end
	end
	local bar_ppq = g (SEQ_BAR)
	if bar_ppq < 1 then bar_ppq = ppqres * 4 end
	if playing then
		local nev, len = g (SEQ_NEV), g (SEQ_LEN)
		if len < 1 then len = bar_ppq end
		local bpm = math.max (20, CtrlPorts:array ()[1])
		local ppq_ps = bpm * ppqres / (60 * rate)
		local remaining = ppq_ps * (n_samples - lead)
		local blk_off, guard = lead, 0
		while remaining > EPS and playing and guard < 4096 do
			guard = guard + 1
			local seg = len - ppq                       -- la prochaine frontière : la fin de la grille
			if seg > remaining then seg = remaining end
			local lim = ppq + seg
			while ev_cur < nev do
				local ea = EV_BASE + ev_cur * EV_STRIDE
				local ev_ppq = g (ea)
				if ev_ppq >= lim then break end
				if ev_ppq >= ppq then
					local off = math.floor (blk_off + (ev_ppq - ppq) / ppq_ps + 0.5) + 1
					if off > n_samples then off = n_samples end
					if taken and first < 0 and blk_pos > -1000000 then first = blk_pos + off - 1 end
					emit (off, g (ea + 1), g (ea + 2), g (ea + 3))
				end
				ev_cur = ev_cur + 1
			end
			ppq = ppq + seg
			blk_off = blk_off + seg / ppq_ps
			remaining = remaining - seg
			if ppq >= len - EPS then                    -- fin de grille : le chorus suivant, ou l'arrêt net
				panic (math.min (n_samples, math.floor (blk_off + 0.5) + 1))   -- à SA place dans le cycle
				if g (CTL_LOOP) > 0 then
					-- le tour suivant : depuis le début — ou, grille ARMÉE, après son décompte (rejoué, il ferait une
					-- mesure de silence ou de tics au milieu de la prise)
					local cin = taken and g (SEQ_CIN) or 0
					ppq, ev_cur = cin, 0
					while cin > 0 and ev_cur < nev and g (EV_BASE + ev_cur * EV_STRIDE) < cin do ev_cur = ev_cur + 1 end
				else playing = false end
			end
		end
	end
	shm:atomic_set_int (ST_PLAYING, playing and 1 or 0)
	shm:atomic_set_int (ST_BAR, playing and math.floor (ppq / bar_ppq) or -1)
	shm:atomic_set_int (ST_BEAT, playing and math.floor (ppq / ppqres) or -1)
	shm:atomic_set_int (ST_ARMED, armed and 1 or 0)
	shm:atomic_set_int (ST_T0, t0)
	shm:atomic_set_int (ST_FIRST, first)
	shm:atomic_set_int (ST_HB, hb % 1000000000)
	shm:atomic_set_int (ST_PPQ, math.floor (ppq))
end
