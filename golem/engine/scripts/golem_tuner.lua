ardour {
	["type"]    = "dsp",
	name        = "golem Tuner",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[golem's tuner: detects the pitch of what passes (YIN on a decimated signal, refined at full rate for high strings) and leaves the audio untouched. Its reading is read by golem's engine watcher.]]
}

-- SPDX-License-Identifier: MIT
-- L'accordeur de golem pour le Golem Engine (golem docs/ardour-plan.md §7d, lot 3), portage du détecteur de
-- reaper/Effects/golem_tuner : mêmes seuils, même machine d'états, même contrat de sortie.
--   - le signal est filtré (coupe-bas 15 Hz, passe-bas 1600 Hz d'ordre 4), gardé à plein débit (2048 échantillons) et
--     DÉCIMÉ vers ~8 kHz (768 échantillons, ~96 ms : trois périodes du si grave d'une basse 5 cordes) ;
--   - YIN sur le signal décimé, ÉTALÉ sur plusieurs cycles (un budget d'itérations par cycle : le fil audio n'attend
--     jamais), en descendant jusqu'au creux puis interpolation parabolique ;
--   - une période courte (cordes aiguës) est raffinée à plein débit ; sous −62 dBFS : pas de note.
-- L'audio traverse INTACT. LA LECTURE est dans la mémoire partagée de l'instance (entiers) :
--   [0] fréquence × 1000   [1] note MIDI fractionnaire × 1000   [2] confiance × 1000 (0 = pas de note)   [3] numéro d'analyse

local MINF, MAXF, THRESH, RMS_GATE, A4 = 28, 1320, 0.15, 0.0008, 440
local HOP, BUDGET_PS, FC_LP, FC_HP, REF_PD_MAX = 2048, 24, 1600, 15, 64
local BUFSZ, DBUF = 2048, 768

function dsp_ioconfig ()
	return { { audio_in = 1, audio_out = 1 } }
end

local rate, DECIM = 48000, 6
local minlag, maxlag, W_d
local buf, lin, dring, dlin, dcm, rdv = {}, {}, {}, {}, {}, {}
local wpos, filled, since, dwpos, dfilled, dacc, dn = 0, 0, 0, 0, 0, 0, 0
local st, seq = 0, 0
local hp_a, hp_x1, hp_y1 = 0, 0, 0
local b10, b11, b12, a11, a12, b20, b21, b22, a21, a22 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
local z11, z12, z21, z22 = 0, 0, 0, 0
-- l'analyse en cours
local tau, runsum, bestlag, bestval, bestval_lag, pd, conf, pfull = 1, 0, 0, 1, 2, 0, 0, 0
local rt, rlo, rhi, rbi, rbv, W_ref = 0, 0, 0, -1, 0, 0

function dsp_init (r)
	rate = r
	DECIM = math.max (1, math.floor (rate / 8000))
	local dsr = rate / DECIM
	minlag = math.max (2, math.floor (dsr / MAXF))
	maxlag = math.min (math.ceil (dsr / MINF), DBUF - 64)
	W_d = DBUF - maxlag
	for i = 0, BUFSZ - 1 do buf[i], lin[i] = 0, 0 end
	for i = 0, DBUF - 1 do dring[i], dlin[i], dcm[i] = 0, 0, 1 end
	for i = 0, 63 do rdv[i] = 0 end
	hp_a = 1 / (1 + 2 * math.pi * FC_HP / rate)
	local w0 = 2 * math.pi * FC_LP / rate
	local cw, sw = math.cos (w0), math.sin (w0)
	local al = sw / (2 * 0.54119610)
	local a0i = 1 / (1 + al)
	b10, b11, a11, a12 = (1 - cw) * 0.5 * a0i, (1 - cw) * a0i, (-2 * cw) * a0i, (1 - al) * a0i
	b12 = b10
	al = sw / (2 * 1.30656296)
	a0i = 1 / (1 + al)
	b20, b21, a21, a22 = (1 - cw) * 0.5 * a0i, (1 - cw) * a0i, (-2 * cw) * a0i, (1 - al) * a0i
	b22 = b20
	self:shmem ():allocate (4)
	self:shmem ():clear ()
end

local function publish (freq, cf)
	local shm = self:shmem ()
	seq = seq + 1
	if freq and freq >= MINF and freq <= MAXF and cf > 0.5 then
		shm:atomic_set_int (0, math.floor (freq * 1000 + 0.5))
		shm:atomic_set_int (1, math.floor ((69 + 12 * math.log (freq / A4) / math.log (2)) * 1000 + 0.5))
		shm:atomic_set_int (2, math.floor (cf * 1000 + 0.5))
	else
		shm:atomic_set_int (2, 0)
	end
	shm:atomic_set_int (3, seq)
end

function dsp_run (ins, outs, n_samples)
	local x = ins[1]:array ()
	for s = 1, n_samples do                           -- les filtres, le tampon plein débit, la décimation
		local v = x[s]
		hp_y1 = hp_a * (hp_y1 + v - hp_x1); hp_x1 = v
		local t0 = b10 * hp_y1 + z11; z11 = b11 * hp_y1 - a11 * t0 + z12; z12 = b12 * hp_y1 - a12 * t0
		local t1 = b20 * t0 + z21; z21 = b21 * t0 - a21 * t1 + z22; z22 = b22 * t0 - a22 * t1
		buf[wpos] = t1
		wpos = wpos + 1; if wpos >= BUFSZ then wpos = 0 end
		dacc = dacc + t1; dn = dn + 1
		if dn >= DECIM then
			dring[dwpos] = dacc / DECIM; dacc, dn = 0, 0
			dwpos = dwpos + 1; if dwpos >= DBUF then dwpos = 0 end
			if dfilled < DBUF then dfilled = dfilled + 1 end
		end
	end
	if filled < BUFSZ then filled = math.min (BUFSZ, filled + n_samples) end
	since = since + n_samples
	if not ins[1]:sameinstance (outs[1]) then ARDOUR.DSP.copy_vector (outs[1], ins[1], n_samples) end   -- l'audio passe, intact

	local budget = BUDGET_PS * n_samples
	if st == 0 then
		if filled >= BUFSZ and dfilled >= DBUF and since >= HOP then since = 0; st = 1 end
	elseif st == 1 then                                -- la photo des deux tampons, et l'énergie (silence ?)
		for i = 0, BUFSZ - 1 do lin[i] = buf[(wpos + i) % BUFSZ] end
		local eng = 0
		for i = 0, DBUF - 1 do
			local v = dring[(dwpos + i) % DBUF]
			dlin[i] = v
			eng = eng + v * v
		end
		if math.sqrt (eng / DBUF) < RMS_GATE then
			publish (nil, 0)
			st = 0
		else
			tau, runsum, bestlag, bestval, bestval_lag = 1, 0, 0, 1, minlag
			st = 2
		end
	elseif st == 2 then                                -- le balayage YIN décimé, étalé
		local n = math.max (1, budget // W_d)
		while n > 0 and tau <= maxlag do
			local sum = 0
			for j = 0, W_d - 1 do
				local dv = dlin[j] - dlin[j + tau]
				sum = sum + dv * dv
			end
			runsum = runsum + sum
			local cmnd = runsum > 0 and (sum * tau / runsum) or 1
			if tau >= minlag then
				if cmnd < bestval then bestval, bestval_lag = cmnd, tau end
				if bestlag == 0 and cmnd < THRESH then bestlag = tau end
			end
			dcm[tau] = cmnd
			tau = tau + 1; n = n - 1
		end
		if tau > maxlag then
			if bestlag > 0 then                           -- DESCENDRE jusqu'au creux (YIN étape 4)
				while bestlag < maxlag and dcm[bestlag + 1] < dcm[bestlag] do bestlag = bestlag + 1 end
			end
			local chosen = bestlag > 0 and bestlag or bestval_lag
			if chosen > minlag and chosen < maxlag then
				local xa, xb, xc = dcm[chosen - 1], dcm[chosen], dcm[chosen + 1]
				local den = xa + xc - 2 * xb
				local shift = den ~= 0 and 0.5 * (xa - xc) / den or 0
				if math.abs (shift) > 1 then shift = 0 end
				pd = chosen + shift
			else
				pd = chosen
			end
			conf = 1 - (bestlag > 0 and dcm[bestlag] or bestval)
			if pd < REF_PD_MAX then                        -- une corde aiguë : on raffine à plein débit
				local rc = math.floor (pd * DECIM + 0.5)
				rlo, rhi = math.max (2, rc - DECIM), rc + DECIM
				W_ref = math.max (256, math.min (1536, 4 * rc))
				if W_ref + rhi + 1 > BUFSZ then W_ref = BUFSZ - rhi - 1 end
				if W_ref < 64 then pfull = pd * DECIM; st = 4
				else rt, rbi, rbv, st = rlo, -1, 0, 3 end
			else
				pfull = pd * DECIM; st = 4
			end
		end
	elseif st == 3 then                                -- le raffinement plein débit, étalé lui aussi
		local n = math.max (1, budget // W_ref)
		while n > 0 and rt <= rhi do
			local s2 = 0
			for j = 0, W_ref - 1 do
				local dv = lin[j] - lin[j + rt]
				s2 = s2 + dv * dv
			end
			rdv[rt - rlo] = s2
			if rbi < 0 or s2 < rbv then rbv, rbi = s2, rt end
			rt = rt + 1; n = n - 1
		end
		if rt > rhi then
			if rbi > rlo and rbi < rhi then
				local xa, xb, xc = rdv[rbi - 1 - rlo], rdv[rbi - rlo], rdv[rbi + 1 - rlo]
				local den = xa + xc - 2 * xb
				local shift = den ~= 0 and 0.5 * (xa - xc) / den or 0
				if math.abs (shift) > 1 then shift = 0 end
				pfull = rbi + shift
			else
				pfull = pd * DECIM
			end
			st = 4
		end
	else
		publish (pfull > 0 and rate / pfull or 0, conf)
		st = 0
	end
end
