ardour {
	["type"]    = "dsp",
	name        = "golem Drumseq",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[golem's drum machine sequencer: plays drum patterns in a loop, in time with the BPM, with variations at the bar, fills and a song sequence. Its bank is written by golem's engine watcher.]]
}

-- SPDX-License-Identifier: MIT
-- Le séquenceur de la boîte à rythmes de golem pour le Golem Engine (golem docs/ardour-plan.md §7d, lot 3), portage à
-- l'identique de reaper/Effects/golem_drumseq.jsfx : une tête de lecture en ticks qui tourne TRANSPORT ARRÊTÉ au tempo
-- (`BPM`, posé par le veilleur), et émet les note-on à l'échantillon près, canal 10.
--   - un groove boucle ; une VARIATION prend à la prochaine barre ; un FILL joue une fois à la prochaine barre puis
--     rend la main au groove ; le mode MORCEAU enchaîne des étapes {slot, passages (0 = sans fin)}, en boucle ou une fois ;
--   - seuls des note-on : un kit de batterie joue ses frappes jusqu'au bout.
-- LA BANQUE vit dans la mémoire partagée de l'instance (entiers), écrite par golem_watch.lua :
--   [0] nonce (changé EN DERNIER : la commande est lue sur son front)  [1] op  [2] slot  [3] ticks par noire
--       op : 0 stop · 1 joue le slot · 2 variation · 3 fill · 4 morceau
--   [8] joue  [9] slot courant  [10] 1 = dans un fill  [11] battement  [13] étape du morceau (-1 hors morceau)  [14] morceau
--   [16] nombre d'étapes  [17] 0 = boucle, 1 = une fois  [18…] étapes : slot, passages (64 au plus)
--   slot s à 256 + s × 8192 : [0] nombre d'événements  [1] longueur (ticks)  [2] une mesure (ticks)
--                             [8…] événements : tick, note, vélocité, 0

local CTL_NONCE, CTL_OP, CTL_SLOT, CTL_PPQ = 0, 1, 2, 3
local ST_PLAYING, ST_SLOT, ST_MODE, ST_HB, ST_SEQIDX, ST_SEQON = 8, 9, 10, 11, 13, 14
local SEQ_LEN, SEQ_MODE, SEQ_STEPS = 16, 17, 18
local SLOT_BASE, SLOT_STRIDE, EV_OFF, EV_STRIDE = 256, 8192, 8, 4
local SLOTS = 14
local SIZE = SLOT_BASE + SLOTS * SLOT_STRIDE
local EPS = 0.0000001
local CHAN = 9                           -- canal 10

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return { { ["type"] = "input", name = "BPM", min = 20, max = 400, default = 120 } }
end

local rate = 48000
local playing, cur_slot, cur_len, cur_bar, cur_nev = false, -1, 0, 1, 0
local ppq, ev_cur, mode_fill, return_slot = 0, 0, false, -1
local pending_op, pending_slot = 0, -1
local seq_on, seq_idx, seq_rep = false, 0, 0     -- seq_rep : passages restants de l'étape (-1 = sans fin)
local last_nonce, hb = -1, 0
local t                                           -- la mémoire partagée, vue comme un tableau d'entiers (index 1 = [0])

function dsp_init (r)
	rate = r
	self:shmem ():allocate (SIZE)
	self:shmem ():clear ()
end

local function g (ix) return t[ix + 1] end
local function slot_addr (s) return SLOT_BASE + s * SLOT_STRIDE end

local function load_slot (s)                     -- (re)cale la tête de lecture au tick 0 du slot
	if s < 0 or s >= SLOTS then s = 0 end
	cur_slot = s
	local ba = slot_addr (s)
	cur_nev, cur_len, cur_bar = g (ba), g (ba + 1), g (ba + 2)
	if cur_bar < 1 then cur_bar = 1 end
	if cur_len < cur_bar then cur_len = cur_bar end
	ppq, ev_cur = 0, 0
end

local function seq_load_step ()
	local sa = SEQ_STEPS + seq_idx * 2
	local n = g (sa + 1)
	seq_rep = n < 1 and -1 or n
	load_slot (g (sa))
end

function dsp_run (_, _, n_samples)
	local shm = self:shmem ()
	t = shm:to_int (0):array ()
	hb = hb + 1
	local cnt = 1
	for _, ev in ipairs (midiin) do                -- ce qui arrive passe (la piste n'en reçoit pas, mais c'est neutre)
		midiout[cnt] = ev
		cnt = cnt + 1
	end
	local ppqres = g (CTL_PPQ)
	if ppqres < 1 then ppqres = 960 end
	local nonce = shm:atomic_get_int (CTL_NONCE)
	if nonce ~= last_nonce then                    -- une commande, sur le front du nonce
		last_nonce = nonce
		local op, slot = g (CTL_OP), g (CTL_SLOT)
		if op == 0 then
			playing, mode_fill, pending_op, return_slot, seq_on = false, false, 0, -1, false
		elseif op == 1 then
			playing, mode_fill, pending_op, return_slot, seq_on = true, false, 0, -1, false
			load_slot (slot)
		elseif op == 2 then
			seq_on = false                             -- une variation sort du mode morceau
			if playing then pending_op, pending_slot = 2, slot
			else playing, mode_fill, return_slot = true, false, -1; load_slot (slot) end
		elseif op == 3 then
			if playing then pending_op, pending_slot = 3, slot end
		elseif op == 4 then
			if g (SEQ_LEN) > 0 then
				playing, mode_fill, pending_op, return_slot = true, false, 0, -1
				seq_on, seq_idx = true, 0
				seq_load_step ()
			else playing, seq_on = false, false end
		end
	end
	if playing then
		local bpm = math.max (20, CtrlPorts:array ()[1])
		local ppq_ps = bpm * ppqres / (60 * rate)    -- ticks par échantillon
		local remaining = ppq_ps * n_samples
		local blk_off, guard = 0, 0
		while remaining > EPS and playing and guard < 4096 do
			guard = guard + 1
			local ba = slot_addr (cur_slot)
			local boundary = math.min ((ppq // cur_bar + 1) * cur_bar, cur_len)   -- la prochaine barre, ou la fin du groove
			local seg = boundary - ppq
			if seg > remaining then seg = remaining end
			local lim = ppq + seg
			while ev_cur < cur_nev do                  -- les frappes dont le tick tombe dans [ppq, lim)
				local ea = ba + EV_OFF + ev_cur * EV_STRIDE
				local ev_ppq = g (ea)
				if ev_ppq >= lim then break end
				if ev_ppq >= ppq then
					local off = math.floor (blk_off + (ev_ppq - ppq) / ppq_ps + 0.5) + 1
					if off > n_samples then off = n_samples end
					midiout[cnt] = { time = off, data = { 0x90 | CHAN, g (ea + 1), g (ea + 2) } }
					cnt = cnt + 1
				end
				ev_cur = ev_cur + 1
			end
			ppq = ppq + seg
			blk_off = blk_off + seg / ppq_ps
			remaining = remaining - seg
			if ppq >= boundary - EPS then
				if ppq >= cur_len - EPS then               -- fin du groove
					if mode_fill and return_slot >= 0 then
						mode_fill = false; load_slot (return_slot); return_slot = -1   -- fin du fill : retour au groove
					elseif pending_op == 2 then
						load_slot (pending_slot); pending_op = 0
					elseif pending_op == 3 then
						return_slot = cur_slot; load_slot (pending_slot); mode_fill = true; pending_op = 0
					elseif seq_on then
						if seq_rep > 0 then seq_rep = seq_rep - 1 end
						if seq_rep ~= 0 then
							ppq, ev_cur = 0, 0                    -- encore des passages (ou sans fin)
						else
							seq_idx = seq_idx + 1
							if seq_idx >= g (SEQ_LEN) then
								if g (SEQ_MODE) == 0 then seq_idx = 0; seq_load_step ()   -- le morceau reboucle
								else playing, seq_on = false, false end               -- une fois : silence net
							else seq_load_step () end
						end
					else
						ppq, ev_cur = 0, 0                     -- le même groove reboucle
					end
				else                                       -- une barre à l'intérieur du groove
					if pending_op == 2 then
						load_slot (pending_slot); pending_op = 0
					elseif pending_op == 3 then
						return_slot = cur_slot; load_slot (pending_slot); mode_fill = true; pending_op = 0
					end
				end
			end
		end
	end
	shm:atomic_set_int (ST_PLAYING, playing and 1 or 0)
	shm:atomic_set_int (ST_SLOT, cur_slot)
	shm:atomic_set_int (ST_MODE, mode_fill and 1 or 0)
	shm:atomic_set_int (ST_HB, hb % 1000000000)
	shm:atomic_set_int (ST_SEQIDX, seq_on and seq_idx or -1)
	shm:atomic_set_int (ST_SEQON, seq_on and 1 or 0)
end
