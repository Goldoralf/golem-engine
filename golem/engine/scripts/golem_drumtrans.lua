ardour {
	["type"]    = "dsp",
	name        = "golem Drumtrans",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[e-drum module notes -> rack kit notes, three-position hi-hat from the pedal CC. Its table is written by golem's engine watcher.]]
}

-- SPDX-License-Identifier: MIT
-- Le portage à l'identique de reaper/Effects/golem_drumtrans.jsfx (golem) pour le Golem Engine (docs/ardour-plan.md §7c) :
--   - traduit chaque NOTE du module vers la note du KIT (table de 128 ; -1 = le kit n'a pas cet élément : note droppée) ;
--   - CHARLESTON À TROIS POSITIONS : la pédale arrive par un CC ; quand la note traduite est l'une des trois notes de
--     charleston du kit, c'est la position lue sur le CC (fermée / mi-ouverte / ouverte, bornes en % de la course, sens
--     déclaré par le descripteur) qui choisit la note ;
--   - un note-OFF suit la note réellement ENVOYÉE par son note-on ; le CC de la pédale est AVALÉ ; le reste passe ;
--   - les notes SORTENT sur le canal 10 (les kits avldrums n'écoutent que lui).
-- LA TABLE vit dans la mémoire partagée de l'instance (shmem, 139 entiers), écrite par golem_watch.lua :
--   [0..127] note du kit ou -1, [128] cc (-1 = pas de pédale CC), [129] open_value, [130] closed_value, [131] band_a,
--   [132] band_b, [133] positions (2|3), [134] note fermée, [135] mi-ouverte, [136] ouverte, [137] nonce (>= 1 = table
--   posée ; 0 = PASSTHROUGH), [138] canal attendu du module (témoin).

local IX_CC, IX_OPEN, IX_CLOSED, IX_BA, IX_BB, IX_POS, IX_NC, IX_NH, IX_NO, IX_NONCE = 128, 129, 130, 131, 132, 133, 134, 135, 136, 137
local SIZE = 139
local OUT_CH = 9                        -- canal 10

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

local active = {}                       -- active[ch*128 + note + 1] = note ENVOYÉE + 1 ; 0 = rien (aucune allocation au jeu)
local pos, cc_seen = 0, false           -- 0 fermée, 1 mi-ouverte, 2 ouverte

function dsp_init (rate)
	self:shmem ():allocate (SIZE)
	self:shmem ():clear ()
	for i = 1, 16 * 128 do active[i] = 0 end
end

function dsp_run (_, _, n_samples)
	local t = self:shmem ():to_int (0):array ()
	local function g (ix) return t[ix + 1] end   -- l'index 0 de la table est le 1er élément du tableau
	local loaded = g (IX_NONCE) > 0
	local cc = loaded and g (IX_CC) or -1
	local nc, nh, no = g (IX_NC), g (IX_NH), g (IX_NO)
	local cnt = 1
	local function tx (time, data)
		midiout[cnt] = { time = time, data = data }
		cnt = cnt + 1
	end
	for _, ev in ipairs (midiin) do
		local d = ev.data
		local st, ch = d[1] & 0xF0, d[1] & 0x0F
		if st == 0xB0 and cc >= 0 and d[2] == cc then
			-- PÉDALE DE CHARLESTON : position = pourcentage de la course, dans le SENS déclaré ; le CC est avalé
			local span = g (IX_CLOSED) - g (IX_OPEN)
			if span == 0 then span = 1 end
			local pct = (d[3] - g (IX_OPEN)) * 100 / span
			if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
			if g (IX_POS) == 2 then
				pos = pct >= 50 and 0 or 2
			else
				pos = pct < g (IX_BA) and 2 or (pct < g (IX_BB) and 1 or 0)
			end
			cc_seen = true
		elseif st == 0x90 and d[3] > 0 and not loaded then
			tx (ev.time, d)                           -- pas de table : passthrough
		elseif st == 0x90 and d[3] > 0 then
			local nn = g (d[2])
			if nn >= 0 then
				if (nn == nc or nn == nh or nn == no) and cc >= 0 and cc_seen then
					local want = pos == 0 and nc or (pos == 1 and nh or no)
					if want < 0 then want = (pos == 1 or pos == 0) and nc or nh end
					if want >= 0 then nn = want end
				end
				active[ch * 128 + d[2] + 1] = nn + 1
				tx (ev.time, { 0x90 | OUT_CH, nn, d[3] })
			end                                        -- -1 : le kit n'a pas cet élément -> rien
		elseif st == 0x80 or (st == 0x90 and d[3] == 0) then
			local sl = active[ch * 128 + d[2] + 1]
			if sl > 0 then
				active[ch * 128 + d[2] + 1] = 0
				tx (ev.time, { 0x80 | OUT_CH, sl - 1, d[3] })
			elseif not loaded then
				tx (ev.time, d)
			end
		elseif st == 0xA0 then
			local sl = active[ch * 128 + d[2] + 1]
			if sl > 0 then tx (ev.time, { 0xA0 | OUT_CH, sl - 1, d[3] }) else tx (ev.time, d) end
		else
			tx (ev.time, d)
		end
	end
end
