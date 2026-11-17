ardour {
	["type"]    = "dsp",
	name        = "golem Looper",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[A four-loop audio looper: four stereo inputs, one stereo output. The first loop sets the length, the others follow it; overdub, per-loop level, a count-in bar and a first loop snapped to the bar. Driven by golem's foot controller through its command parameter.]]
}

-- SPDX-License-Identifier: MIT
-- Le looper du Golem Engine (golem docs/looper.md ; sous REAPER : le JSFX golem_super8, dont il reprend le CONTRAT,
-- pas le code). Quatre PAIRES stéréo en entrée (une par ligne de la table de boucles), une sortie stéréo.
--
-- COMMANDES — les mêmes notes que golem_super8, écrites par le bridge dans « GoleM Cmd » (seq*128 + note) :
--   36/41/45/50 rec d'une paire · 37/42/46/51 play d'une paire · 24..27 effacer une paire · 21 tout jouer/arrêter ·
--   20 tout effacer. « GoleM Tempo » et « GoleM Mode » (temps×10 + 1 calage + 2 décompte + 4 rec→dub) règlent la
--   première boucle ; « GoleM Loop n dB » (-60 = muette) et « GoleM Loops level » le niveau de lecture.
--   L'ORDRE des paramètres est celui des sliders du JSFX : le bridge les adresse par décalage depuis « GoleM Cmd ».
-- MÉMOIRE PARTAGÉE (entiers), lue par golem_watch.lua :
--   [0] longueur (échantillons)  [1] position  [2] firstrec (canal 1-based de la paire qui pose la longueur)
--   [3] battement de cœur  [4] décompte : temps restants  [5] décompte : paire (1-4)  [6] fréquence
--   [8+p*4] état (0 arrêt, 1 joue, 2 enregistre)  [9+p*4] a du contenu  [10+p*4] crête ×1000
--   [100] pointeur d'écriture d'un anneau de commandes (secours par fichier)  [102..117] ses notes
-- L'AUDIO vit dans la même mémoire, après l'en-tête : 8 canaux de MAX_S secondes. Elle n'est jamais mise à zéro en
-- bloc (184 Mo) : chaque paire connaît la RÉGION qu'elle a écrite et ne joue qu'elle ; le reste est mis à zéro par
-- petits morceaux, hors de tout moment critique.

local H, MAXB = 256, 8192
local SCR = H
local AB = SCR + 2 * MAXB
local MAX_S = 120
local REC = { [36] = 1, [41] = 2, [45] = 3, [50] = 4 }
local PLAY = { [37] = 1, [42] = 2, [46] = 3, [51] = 4 }
local REC_NOTE, PLAY_NOTE = { 36, 41, 45, 50 }, { 37, 42, 46, 51 }

function dsp_ioconfig ()
	return { { audio_in = 8, audio_out = 2 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "GoleM Cmd", min = 0, max = 16383, default = 0, integer = true },
		{ ["type"] = "input", name = "GoleM Tempo", min = 0, max = 400, default = 0 },
		{ ["type"] = "input", name = "GoleM Mode", min = 0, max = 999, default = 0, integer = true },
		{ ["type"] = "input", name = "GoleM Loop 1 dB", min = -60, max = 0, default = 0 },
		{ ["type"] = "input", name = "GoleM Loop 2 dB", min = -60, max = 0, default = 0 },
		{ ["type"] = "input", name = "GoleM Loop 3 dB", min = -60, max = 0, default = 0 },
		{ ["type"] = "input", name = "GoleM Loop 4 dB", min = -60, max = 0, default = 0 },
		{ ["type"] = "input", name = "GoleM Loops level", min = 0, max = 1, default = 1 },
	}
end

local rate, MAXLEN = 48000, 0
local len, pos, firstrec, rec_len = 0, 0, 0, 0
local st, vs, vl, rg, pg, pk = {}, {}, {}, {}, {}, {}
local ci_left, ci_total, ci_note, close_at, close_note, clk_on = 0, 0, -1, 0, -1, false
local last_cmd, rptr, heart = 0, 0, 0
local beat, bar, flags = 0, 0, 0
local shm

function dsp_init (r)
	rate = r
	MAXLEN = math.floor (MAX_S * r)
	self:shmem ():allocate (AB + 8 * MAXLEN)
	local a = self:shmem ():to_int (0):array ()
	for i = 1, H do a[i] = 0 end
	for p = 1, 4 do st[p], vs[p], vl[p], rg[p], pg[p], pk[p] = 0, 0, 0, 0, 0, 0 end
end

local function buf (p, c, at) return shm:to_float (AB + ((p - 1) * 2 + c) * MAXLEN + at) end

local function clear_pair (p)
	st[p], vs[p], vl[p], rg[p], pg[p] = 0, 0, 0, 0, 0
	local any = false
	for q = 1, 4 do if vl[q] > 0 or st[q] == 2 then any = true end end
	if (firstrec ~= 0 and (firstrec - 1) // 2 == p - 1) or not any then
		firstrec, len, pos, rec_len, close_at, close_note, clk_on = 0, 0, 0, 0, 0, -1, false
	end
end

-- la PREMIÈRE boucle se ferme : sa longueur devient celle de toutes ; `target` la cale (plus courte que l'enregistré)
local function close_first (p, target)
	local L = rec_len
	if L < rate * 0.1 then clear_pair (p) return false end
	len = math.min (target or L, L)
	firstrec, close_at, close_note, clk_on = 0, 0, -1, false
	pos = (L - len) % len                              -- coupée à la barre : la lecture repart EN PHASE
	for q = 1, 4 do                                    -- ce qu'une autre paire a écrit au-delà est perdu
		if vs[q] >= len then vs[q], vl[q] = 0, 0
		elseif vs[q] + vl[q] > len then vl[q] = len - vs[q] end
	end
	return true
end

local function set_state (p, new)
	if new == 2 and st[p] ~= 2 then
		if len == 0 and firstrec == 0 then
			firstrec, rec_len, pos = (p - 1) * 2 + 1, 0, 0
			for q = 1, 4 do vs[q], vl[q] = 0, 0 end
		end
		st[p] = 2
	elseif st[p] == 2 and new ~= 2 then
		if firstrec ~= 0 and (firstrec - 1) // 2 == p - 1 then
			if not close_first (p) then return end
		end
		st[p] = new
	else
		st[p] = new
	end
end

local function handle (n)
	local was_first = firstrec
	if n == 20 then
		for p = 1, 4 do st[p], vs[p], vl[p], rg[p], pg[p] = 0, 0, 0, 0, 0 end
		firstrec, len, pos, rec_len, close_at, close_note, clk_on = 0, 0, 0, 0, 0, -1, false
	elseif n >= 24 and n <= 27 then
		clear_pair (n - 23)
	elseif n == 21 then
		local want = 0
		for p = 1, 4 do if st[p] ~= 1 and vl[p] > 0 then want = 1 end end
		for p = 1, 4 do if st[p] ~= want and (vl[p] > 0 or st[p] ~= 0) then set_state (p, want) end end
	elseif REC[n] then
		local p = REC[n]
		set_state (p, (st[p] == 2 and was_first == 0) and 1 or 2)
	elseif PLAY[n] then
		local p = PLAY[n]
		set_state (p, (st[p] == 2 or (st[p] == 0 and len > 0)) and 1 or 0)
	end
end

local function then_dub (p) if flags & 4 ~= 0 then handle (REC_NOTE[p]) end end
local function empty ()
	for p = 1, 4 do if st[p] ~= 0 or vl[p] > 0 then return false end end
	return len == 0 and firstrec == 0
end

-- une commande du bridge : le décompte retient le DÉPART de la première boucle, le calage retient ou recadre sa
-- FERMETURE ; tout le reste passe tel quel
local function cmd (n)
	if ci_note ~= -1 then
		if n == ci_note or n == PLAY_NOTE[REC[ci_note] or 0] or n == 20 then
			ci_left, ci_note = 0, -1
			if n == 20 then handle (n) end
		end
	elseif close_at > 0 then
		if n == 20 then close_at, close_note = 0, -1; handle (n)
		elseif n ~= close_note then handle (n) end
	elseif flags & 2 ~= 0 and bar > 0 and REC[n] and empty () then
		ci_total, ci_left, ci_note = bar, bar, n
	elseif firstrec ~= 0 and bar > 0 and (flags & 1 ~= 0 or clk_on) and n == PLAY_NOTE[(firstrec - 1) // 2 + 1] then
		local p, L = (firstrec - 1) // 2 + 1, rec_len
		local target = math.max (1, math.floor (L / bar + 0.5)) * bar
		if target > L then
			close_at, close_note = math.min (target, MAXLEN), n   -- un peu tôt : on enregistre jusqu'à la barre
		else
			if close_first (p, target) then st[p] = 1; then_dub (p) end   -- un peu tard : coupée à la barre
		end
	else
		handle (n)
	end
end

local function approach (cur, target, step)
	if cur < target then return math.min (target, cur + step) end
	return math.max (target, cur - step)
end

-- écrit `k` échantillons de l'entrée de la paire dans sa boucle, à `q` ; ga→gb : le fondu de l'enregistrement.
-- Dans la région déjà écrite : par-dessus (overdub). À sa suite : copie, et la région grandit. Ailleurs : rien.
local function rec_seg (ins, p, q, k, ioff, ga, gb)
	while k > 0 do
		local mix, kk
		if vl[p] == 0 then
			vs[p], mix, kk = q, false, k
		else
			local o = q - vs[p]
			if len > 0 then o = o % len end
			if len > 0 and vl[p] >= len then mix, kk = true, k
			elseif o >= 0 and o < vl[p] then mix, kk = true, math.min (k, vl[p] - o)
			elseif o == vl[p] then mix, kk = false, k
			else return end
		end
		if not mix and len > 0 then kk = math.min (kk, len - vl[p]) end
		if kk <= 0 then return end
		local gm = ga + (gb - ga) * kk / k
		for c = 0, 1 do
			local dst, src = buf (p, c, q), ins[(p - 1) * 2 + c + 1]:offset (ioff)
			if ga == 1 and gb == 1 then
				if mix then ARDOUR.DSP.mix_buffers_no_gain (dst, src, kk) else ARDOUR.DSP.copy_vector (dst, src, kk) end
			else
				local d, s, dg = dst:array (), src:array (), (gm - ga) / kk
				if mix then for i = 1, kk do d[i] = d[i] + s[i] * (ga + dg * (i - 1)) end
				else for i = 1, kk do d[i] = s[i] * (ga + dg * (i - 1)) end end
			end
		end
		if not mix then vl[p] = vl[p] + kk end
		q, ioff, k, ga = q + kk, ioff + kk, k - kk, gm
		if len > 0 then q = q % len end
	end
end

local function play_seg (p, q, k, soff, ga, gb)
	local o = (q - vs[p]) % len
	if o >= vl[p] then return end
	local kk = math.min (k, vl[p] - o)
	for c = 0, 1 do
		local src, dst = buf (p, c, q), shm:to_float (SCR + c * MAXB + soff)
		if ga == gb then
			ARDOUR.DSP.mix_buffers_with_gain (dst, src, kk, ga)
		else
			local d, s, dg = dst:array (), src:array (), (gb - ga) / k
			for i = 1, kk do d[i] = d[i] + s[i] * (ga + dg * (i - 1)) end
		end
	end
end

local function chunk (ins, outs, off, m, lvl)
	local L, R = shm:to_float (SCR), shm:to_float (SCR + MAXB)
	ARDOUR.DSP.memset (L, 0, m)
	ARDOUR.DSP.memset (R, 0, m)
	if ci_note ~= -1 and ci_left <= 0 then              -- la mesure de décompte est passée : la boucle part sur le 1
		local n = ci_note
		ci_note, clk_on = -1, true
		handle (n)
	end
	if ci_left > 0 then
		-- le DÉCOMPTE : une mesure de tics à la sortie du looper (jamais enregistrés), puis la boucle part sur le 1
		local l, r, e, tick = L:array (), R:array (), ci_total - ci_left, math.floor (rate * 0.012)
		for i = 1, math.min (m, ci_left) do
			local t = (e + i - 1) % beat
			if t < tick then
				local f = ((e + i - 1) // beat == 0) and 1568 or 1046
				local s = math.sin (6.283185307 * f * t / rate) * 0.4 * (1 - t / tick)
				l[i], r[i] = l[i] + s, r[i] + s
			end
		end
		ci_left = math.max (0, ci_left - m)
	end
	-- LECTURE (avant d'écrire : une couche qu'on enregistre ne s'entend pas deux fois)
	if len > 0 then
		for p = 1, 4 do
			local g0 = pg[p]
			local g1 = approach (g0, (st[p] ~= 0 and vl[p] > 0) and lvl[p] or 0, m / (0.02 * rate))
			pg[p] = g1
			if (g0 > 0 or g1 > 0) and vl[p] > 0 then
				local s, q = 0, pos
				while s < m do
					local k = math.min (m - s, len - q)
					play_seg (p, q, k, s, g0 + (g1 - g0) * s / m, g0 + (g1 - g0) * (s + k) / m)
					q, s = (q + k) % len, s + k
				end
			end
		end
	end
	-- ENREGISTREMENT : l'entrée monte en un bloc, redescend en 30 ms — la queue d'une première boucle retombe sur
	-- son début (un fondu enchaîné à la couture)
	for p = 1, 4 do
		local r0 = rg[p]
		local r1 = st[p] == 2 and 1 or approach (r0, 0, m / (0.03 * rate))
		rg[p] = r1
		if r0 > 0 or r1 > 0 then
			if len == 0 then
				if firstrec ~= 0 and rec_len + m <= MAXLEN then rec_seg (ins, p, rec_len, m, off, r0, r1) end
			else
				local s, q = 0, pos
				while s < m do
					local k = math.min (m - s, len - q)
					rec_seg (ins, p, q, k, off + s, r0 + (r1 - r0) * s / m, r0 + (r1 - r0) * (s + k) / m)
					q, s = (q + k) % len, s + k
				end
			end
		end
		pk[p] = math.max (pk[p] * 0.9, ARDOUR.DSP.compute_peak (ins[(p - 1) * 2 + 1]:offset (off), m, 0))
	end
	-- LE TEMPS AVANCE
	if len == 0 then
		if firstrec ~= 0 then
			rec_len = rec_len + m
			local p = (firstrec - 1) // 2 + 1
			if close_at > 0 and rec_len >= close_at then
				if close_first (p, close_at) then st[p] = 1; then_dub (p) end
			elseif rec_len + MAXB > MAXLEN then        -- au bout de la mémoire : la boucle se ferme d'elle-même
				close_at, close_note = 0, -1
				handle (PLAY_NOTE[p])
			end
		end
	else
		pos = (pos + m) % len
		for p = 1, 4 do                                -- le reste d'une boucle partielle : mis à zéro par morceaux
			if st[p] ~= 2 and rg[p] == 0 and vl[p] > 0 and vl[p] < len then
				local e = (vs[p] + vl[p]) % len
				local k = math.min (32768, len - vl[p], len - e)
				ARDOUR.DSP.memset (buf (p, 0, e), 0, k)
				ARDOUR.DSP.memset (buf (p, 1, e), 0, k)
				vl[p] = vl[p] + k
			end
		end
	end
	ARDOUR.DSP.copy_vector (outs[1]:offset (off), L, m)
	ARDOUR.DSP.copy_vector (outs[2]:offset (off), R, m)
end

function dsp_run (ins, outs, n_samples)
	shm = self:shmem ()
	local a = shm:to_int (0):array ()
	local ctrl = CtrlPorts:array ()
	local tempo, mode = ctrl[2], math.floor (ctrl[3] + 0.5)
	local beats = mode // 10
	flags = mode % 10
	beat = (tempo > 20 and beats > 0) and math.floor (rate * 60 / tempo + 0.5) or 0
	bar = beat > 0 and math.floor (rate * 60 / tempo * beats + 0.5) or 0
	local lvl = {}
	for p = 1, 4 do
		local db = ctrl[3 + p]
		lvl[p] = db <= -59.9 and 0 or (10 ^ (db / 20)) * ctrl[8]
	end
	local v = math.floor (ctrl[1] + 0.5)
	if v ~= last_cmd then
		last_cmd = v
		if v >= 128 then cmd (v % 128) end
	end
	local w = a[101]
	if w < rptr then rptr = w end
	while rptr < w do
		cmd (a[103 + rptr % 16])
		rptr = rptr + 1
	end
	if len == 0 and firstrec == 0 and ci_note == -1 and ci_left <= 0 then
		-- AU REPOS (aucune boucle, rien qui enregistre, pas de décompte) : du silence, et rien d'autre — le looper est
		-- posé en permanence, il ne doit rien coûter tant qu'on ne s'en sert pas (mesuré : 42 µs par cycle avant)
		ARDOUR.DSP.memset (outs[1], 0, n_samples)
		ARDOUR.DSP.memset (outs[2], 0, n_samples)
		for p = 1, 4 do pk[p] = 0 end
	else
		local done = 0
		while done < n_samples do
			local m = math.min (n_samples - done, MAXB)
			chunk (ins, outs, done, m, lvl)
			done = done + m
		end
	end
	heart = (heart + 1) % 1000000
	a[1], a[2], a[3], a[4] = (len > 0) and len or rec_len, (len > 0) and pos or rec_len, firstrec, heart
	a[5] = (ci_left > 0 and beat > 0) and math.ceil (ci_left / beat) or 0
	a[6] = ci_note ~= -1 and (REC[ci_note] or 0) or 0
	a[7] = rate
	for p = 1, 4 do
		local b = 8 + (p - 1) * 4
		a[b + 1], a[b + 2], a[b + 3] = st[p], vl[p] > 0 and 1 or 0, math.floor (pk[p] * 1000)
	end
end
