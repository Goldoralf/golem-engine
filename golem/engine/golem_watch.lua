-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- golem_watch (Golem Engine) : le veilleur de commandes, côté Ardour. Même contrat que reaper/Scripts/golem_watch.lua
-- dans golem (docs/ardour-plan.md §2) : le bridge pose une commande JSON dans <golem>/presets/.command.json,
-- le veilleur l'exécute et écrit {seq, t} dans .command-ack.json. La télémétrie part dans des fichiers aux schémas
-- de golem ; le chemin rapide (mute, potards, transport) passe par la surface OSC d'Ardour, activée ici.
--
-- Lancé par golem/engine/run.sh :  luasession golem_watch.lua <golem-root> <session-dir> [backend] [device]
--
-- Vocabulaire : ping, status, rig_recall, scene_apply, stomp, rig_verify, dump (A2.0). Le reste arrive avec A2/A3 ;
-- le bridge ne l'envoie pas (EngineAdapter.actions).

io.stdout:setvbuf ("no")

local ROOT, SESSION_DIR = arg[1], arg[2]
-- la stéréo des chaînes : le module partagé avec le banc de parité de golem (tools/engine-render-case.lua)
-- les DEUX séparateurs (2026-11-19, portage Windows) : le chemin du script y arrive en D:\…\golem_watch.lua, et le motif
-- sur « / » seul rendait « . » — le veilleur mourait sur « cannot open ./golem_chain.lua »
local HERE = debug.getinfo (1, "S").source:match ("^@(.*)[/\\][^/\\]*$") or "."
local CHAIN = dofile (HERE .. "/golem_chain.lua")
local BACKEND, DEVICE = arg[3] or "None (Dummy)", arg[4] or ""
local CMD = ROOT .. "/presets/.command.json"
local ACK = ROOT .. "/presets/.command-ack.json"
local LOG = ROOT .. "/presets/.watch.log"
local STATUS = ROOT .. "/presets/.engine-status.json"
local CLOCK = ROOT .. "/presets/.clock.json"            -- le témoin « le thread audio avance » (monitors._audio_alive)
local AUDIO_CFG = ROOT .. "/config/golem-engine.json"    -- le réglage audio choisi au Dashboard (buffer), état local
local TICK_US = 30000                               -- 30 ms, l'ordre d'un tick defer de REAPER

-- ── JSON : juste ce qu'il faut pour lire une commande et écrire un témoin ──────────────────────────────
local function json_decode (s)
	local i = 1
	local function ws () i = s:find ("[^ \t\r\n]", i) or #s + 1 end
	local val
	local function str ()
		local out, j = {}, i + 1
		while true do
			local c = s:sub (j, j)
			if c == "" then error ("unterminated string") end
			if c == '"' then break end
			if c == "\\" then
				local e = s:sub (j + 1, j + 1)
				local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				if e == "u" then
					local cp = tonumber (s:sub (j + 2, j + 5), 16)
					out[#out + 1] = utf8 and utf8.char (cp) or "?"
					j = j + 6
				else
					out[#out + 1] = map[e] or e
					j = j + 2
				end
			else
				out[#out + 1] = c
				j = j + 1
			end
		end
		i = j + 1
		return table.concat (out)
	end
	function val ()
		ws ()
		local c = s:sub (i, i)
		if c == "{" then
			local t = {}
			i = i + 1; ws ()
			if s:sub (i, i) == "}" then i = i + 1; return t end
			while true do
				ws (); local k = str (); ws ()
				assert (s:sub (i, i) == ":", "':' expected"); i = i + 1
				t[k] = val (); ws ()
				local d = s:sub (i, i); i = i + 1
				if d == "}" then return t end
				assert (d == ",", "',' expected")
			end
		elseif c == "[" then
			local t = {}
			i = i + 1; ws ()
			if s:sub (i, i) == "]" then i = i + 1; return t end
			while true do
				t[#t + 1] = val (); ws ()
				local d = s:sub (i, i); i = i + 1
				if d == "]" then return t end
				assert (d == ",", "',' expected")
			end
		elseif c == '"' then return str ()
		elseif s:sub (i, i + 3) == "true" then i = i + 4; return true
		elseif s:sub (i, i + 4) == "false" then i = i + 5; return false
		elseif s:sub (i, i + 3) == "null" then i = i + 4; return nil
		else
			local num = s:match ("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
			assert (num and #num > 0, "bad value at " .. i)
			i = i + #num
			return tonumber (num)
		end
	end
	return val ()
end

local ARRAY = {}                                   -- métatable : une table VIDE marquée ainsi s'écrit [] (sinon {})
local function array (t) return setmetatable (t or {}, ARRAY) end

local function json_encode (v)
	local t = type (v)
	if t == "table" then
		if #v > 0 or getmetatable (v) == ARRAY then
			local out = {}
			for _, x in ipairs (v) do out[#out + 1] = json_encode (x) end
			return "[" .. table.concat (out, ",") .. "]"
		end
		local out = {}
		for k, x in pairs (v) do out[#out + 1] = string.format ("%q", tostring (k)) .. ":" .. json_encode (x) end
		return "{" .. table.concat (out, ",") .. "}"
	elseif t == "string" then return string.format ("%q", v)
	elseif t == "number" then return (v == math.floor (v) and math.abs (v) < 2^53) and string.format ("%d", v) or tostring (v)
	elseif t == "boolean" then return tostring (v)
	end
	return "null"
end

-- ── fichiers : écriture atomique (rename), comme le reste de golem ─────────────────────────────────────
local function write_file (path, text)
	local tmp = path .. ".tmp"
	local f = assert (io.open (tmp, "w"))
	f:write (text); f:close ()
	-- WINDOWS (2026-11-19, portage) : os.rename n'y REMPLACE pas un fichier existant. Ôter la cible puis renommer
	-- (2026-11-19) laissait une fenêtre où le fichier MANQUAIT — un lecteur lisait « rien » (le banc : backing à 0,00 s
	-- juste après un seek, 2 passages sur 5, 2026-11-20) — et l'ôter échouait quand un lecteur le tenait ouvert : la mise
	-- à jour était perdue. LuaAPI.replace_file (fork) remplace d'un coup (MoveFileExW REPLACE_EXISTING) : un lecteur
	-- voit l'ancien ou le nouveau, jamais rien. Tenu ouvert par un lecteur, le remplacement échoue : on réessaie.
	local replace = ARDOUR.LuaAPI.replace_file
	if replace then
		for i = 1, 3 do
			if replace (tmp, path) then return end
			ARDOUR.LuaAPI.usleep (2000)
		end
		os.remove (tmp)
		return
	end
	if os.rename (tmp, path) then return end
	os.remove (path)                             -- un moteur sans replace_file : l'ancienne façon
	if not os.rename (tmp, path) then
		os.remove (tmp)
	end
end

local function read_file (path)
	local f = io.open (path, "r")
	if not f then return nil end
	local s = f:read ("*a"); f:close ()
	return s
end

local function read_json_early (path)
	local f = io.open (path, "r")
	if not f then return nil end
	local txt = f:read ("*a"); f:close ()
	local ok, v = pcall (json_decode, txt)
	return ok and v or nil
end

local function log (msg)
	local f = io.open (LOG, "a")
	if f then f:write (os.date ("%Y-%m-%d %H:%M:%S ") .. "[golem-engine] " .. msg .. "\n"); f:close () end
	print (msg)
end

local function now_s () return ARDOUR.LuaAPI.monotonic_time () / 1e6 end

-- ── les commandes ────────────────────────────────────────────────────────────────────────────────────
local DEVICE_OPEN, N_IN, N_OUT, MIDI_IN, MIDI_OUT = nil, 0, 0, {}, {}

-- LES DÉCROCHAGES QU'ON COMPTE : ceux du JEU. Poser un rig (routes créées, plugins chargés) en fait toujours quelques-uns
-- — le son est de toute façon coupé à ce moment-là —, et démarrer le moteur en fait une trentaine : comptés, ils
-- allumaient « Audio dropouts » en rouge à chaque démarrage (37 au rack le 2026-11-17, aucun en jouant). Pendant le
-- démarrage et un rappel, et 0,7 s après, ce que le moteur compte n'entre pas dans le total publié.
local XR = { skip = 0, base = 0, until_s = math.huge }
local function xruns_now ()
	-- pendant un montage et son délai de grâce : le total d'AVANT, figé — publié brut puis corrigé, il redescendait, et
	-- le bridge prend une baisse pour un redémarrage du moteur : il recomptait tout (164 « décrochages » pour les 72
	-- rappels d'une calibration, rack, 2026-11-17)
	if XR.until_s ~= 0 then return XR.base end
	local ok, n = pcall (function () return Session:get_xrun_count () end)
	return ok and math.max (0, n - XR.skip) or 0
end
local function xr_hold ()                                                      -- avant un montage
	if XR.until_s == 0 then XR.base = xruns_now () end
	XR.until_s = math.huge
end
local function xr_release () XR.until_s = now_s () + 0.7 end                   -- après : encore un instant
local function xr_tick ()
	if XR.until_s == 0 then return end
	local ok, n = pcall (function () return Session:get_xrun_count () end)
	if ok then XR.skip = n - XR.base end
	if now_s () >= XR.until_s then XR.until_s = 0 end
end

local function status ()
	return {
		engine = "golem-engine", backend = AudioEngine:current_backend_name (),
		running = AudioEngine:running (), sample_rate = Session:nominal_sample_rate (),
		buffer = Session:get_block_size (),
		dsp_load = AudioEngine:get_dsp_load (), xruns = xruns_now (), xruns_all = Session:get_xrun_count (),
		tracks = Session:get_tracks ():size (), rolling = Session:transport_rolling (), at = os.time (),
		device = DEVICE_OPEN, inputs = N_IN, outputs = N_OUT, midi_in = MIDI_IN, midi_out = MIDI_OUT,
		midi_clock = (function () local ok, v = pcall (function () return MIDICLOCK.state () end); return ok and v or nil end) (),
	}
end


-- ── le rig (lot A2.0) : le plan MOTEUR écrit par le bridge (bridge/engine/ardour_plan.py) ────────────────────────
-- Le bridge a déjà tout résolu (plugin, fichiers, label et valeur de chaque paramètre, topologie) : ici on exécute.
-- Tout est MONO jusqu'aux sorties de la carte (1 entrée / 1 sortie par route, le port de sortie relié à chaque
-- sortie demandée) : pas de panoramique, donc pas de loi de pan, gain unité comme REAPER ; le stéréo vient en A3.
local LIVEMAP = ROOT .. "/presets/.livemap.json"
local RIGCHECK = ROOT .. "/presets/.rig-check.json"
local DUMP = ROOT .. "/presets/.engine-dump.json"
local SNAPSHOT = ROOT .. "/presets/.engine-snapshot.json"   -- la commande `snapshot` (le banc des presets)
local NG = PBD.GroupControlDisposition.NoGroup
local BACKEND_PTR = nil                -- le backend (open_session) : les claviers s'y ouvrent à la demande
local MIDI_PORTS = {}                  -- appareil MIDI ouvert -> ses ports de capture (system:midi_capture_…)
local GONE = 0                         -- compteur des routes retirées (clear_routes : un nom unique avant le retrait)
local RIG = { preset = nil, routes = {}, order = {}, blocks = {}, nch = {}, asleep = {}, specs = {}, mixer = {}, rec_before = 0 }
-- UN SAMPLER RETIRÉ N'EST PAS DÉTRUIT TOUT DE SUITE (Windows 11, 2026-11-23). sfizz dit son fichier lu (« Number of
-- regions ») dès que le .sfz est analysé, puis précharge ses échantillons dans SES fils pendant des secondes (le piano
-- Salamander, cache disque froid : jusqu'à 13 s). Le détruire pendant ce temps faisait tomber le moteur — un preset
-- avec le piano, un autre 4 s après : 0xC0000005 dans sfizz.dll, ou 0xC0000374 (tas corrompu) ; reproduit à chaque
-- essai à froid. Garder sa bibliothèque chargée ne suffit pas (essayé : la faute passe dans sfizz.dll même). On garde
-- donc ici la référence du plugin retiré — hors de toute route, il ne joue plus — et on ne la lâche que GRAVE.secs
-- secondes plus tard, quand ses fils ont fini (rappels rapprochés à cache chaud : aucun plantage en 26 rappels).
-- (une table GLOBALE : le fichier est à la limite des 200 variables locales de Lua)
GRAVE = { held = {}, secs = 60 }
GRAVE.keep = function (proc)
	if proc then GRAVE.held[#GRAVE.held + 1] = { proc = proc, at = now_s () + GRAVE.secs } end
end
GRAVE.sweep = function ()
	local t, kept, freed = now_s (), {}, 0
	for _, g in ipairs (GRAVE.held) do
		if g.at > t then kept[#kept + 1] = g else g.proc = nil; freed = freed + 1 end
	end
	GRAVE.held = kept
	if freed > 0 then collectgarbage () end
end
-- L'HORLOGE MIDI (sa section plus bas) : une table GLOBALE — le fichier est à la limite des 200 locales de Lua.
-- `ports[appareil]` = ses ports de SORTIE, relevés quand midi_device_ports ouvre un clavier.
-- ⚠ SON NOM N'EST PAS « CLOCK » : `local CLOCK` (plus haut) est le chemin du TÉMOIN du fil audio (presets/.clock.json).
-- La table de l'horloge MIDI s'appelait ainsi et l'écrasait : plus de témoin, donc plus de détection ni de réparation
-- d'un son coupé — le rack est resté muet une nuit (2026-11-18) sans que golem le voie.
MIDICLOCK = { route = nil, proc = nil, bpm = 120, ports = {}, linked = "" }
local INPUT_METERS_N                        -- défini avec les vumètres d'entrée, plus bas
local REC_COUNT = function () return 0 end   -- le nombre de pistes de prise TEMPORAIRES vivantes (défini avec le service de prise)
local REC_POOLED = function (name) return false end   -- cette route est-elle une piste de prise PERMANENTE ?
local REC, rec_link                          -- l'état de la prise et le lien de ses pistes : définis plus bas, lus par le rig
-- le numéro de strip (surface OSC) de la i-ème route du rig : les vumètres d'entrée d'abord, puis les pistes d'une
-- prise commencée AVANT ce rig, puis les routes dans l'ordre de leur création
local function ssid_of (i) return (RIG.base or INPUT_METERS_N ()) + (RIG.rec_before or 0) + i end   -- blocks[id] = {route, proc, ssid, fx, spec}

local function read_json (path)
	local s = read_file (path)
	if not s or s == "" then return nil end
	local ok, v = pcall (json_decode, s)
	return ok and v or nil
end

local function physical (want_capture)
	local out = {}
	local _, t = AudioEngine:get_backend_ports ("", ARDOUR.DataType ("audio"),
		ARDOUR.PortFlags.IsPhysical | (want_capture and ARDOUR.PortFlags.IsOutput or ARDOUR.PortFlags.IsInput),
		C.StringVector ())
	for p in t[4]:iter () do out[#out + 1] = p end
	return out
end

local function physical_midi ()
	local out = {}
	local _, t = AudioEngine:get_backend_ports ("", ARDOUR.DataType ("midi"),
		ARDOUR.PortFlags.IsPhysical | ARDOUR.PortFlags.IsOutput, C.StringVector ())
	for p in t[4]:iter () do out[p] = true end
	return out
end

-- LES PORTS D'UN CLAVIER (lane MIDI) : l'appareil dont le nom commence par `want` (le nom court de la carte ALSA, résolu
-- par le bridge : « MPK Mini Mk II »), ouvert À CHAUD s'il ne l'est pas (un clavier branché après le démarrage : la
-- liste est relue). Ses ports = ceux apparus à l'ouverture. Jamais un appareil en sortie seule (« (O) »).
local function midi_device_ports (want)
	local be = BACKEND_PTR
	if not be or not want or want == "" then return {} end
	local w, out = want:lower (), {}
	if want:sub (1, 5) == "port:" then               -- un port nommé tel quel (un banc, sur la carte factice)
		local p = want:sub (6)
		local all = physical_midi ()
		if not all[p] then
			local names = {}
			for n in pairs (all) do names[#names + 1] = n end
			table.sort (names)
			log ("  MIDI : pas de port « " .. p .. " » (ports : " .. table.concat (names, ", ") .. ")")
		end
		return all[p] and { p } or {}
	end
	for d in be:enumerate_midi_devices ():iter () do
		local name = d.name
		if name:lower ():sub (1, #w) == w and not name:find ("%(O%)$") and d.available then
			-- un clavier débranché puis rebranché est un NOUVEL appareil pour le backend (fermé, ports neufs) : le cache
			-- ne vaut que si ses ports existent encore
			local cached = MIDI_PORTS[name]
			if cached then
				local now = physical_midi ()
				for _, p in ipairs (cached) do if not now[p] then cached = nil; break end end
			end
			if not cached or not be:midi_device_enabled (name) then
				local before = physical_midi ()
				local before_out = MIDICLOCK.phys and MIDICLOCK.phys () or {}
				be:set_midi_device_enabled (name, true)
				local got = {}
				for p in pairs (physical_midi ()) do if not before[p] then got[#got + 1] = p end end
				MIDI_PORTS[name] = got
				if MIDICLOCK.phys then                           -- ses sorties : là où l'horloge MIDI ira (MIDICLOCK.link)
					local outs = {}
					for p in pairs (MIDICLOCK.phys ()) do if not before_out[p] then outs[#outs + 1] = p end end
					table.sort (outs)
					MIDICLOCK.ports[name] = outs
				end
				log ("  MIDI : " .. name .. " ouvert (" .. #got .. " port(s))")
			end
			for _, p in ipairs (MIDI_PORTS[name]) do out[#out + 1] = p end
		end
	end
	return out
end

-- le premier port d'un IO, audio ou MIDI (une piste MIDI n'a pas d'entrée audio)
local function port0 (io)
	local p = io:audio (0)
	if p:isnil () then p = io:midi (0) end
	return p
end

local function plugin_params (pl)
	-- [{i, port, label, lower, upper}] des paramètres d'entrée de contrôle ; i = l'index de nth_parameter (= `p` du
	-- livemap = paramètre 1-based - 1 de la surface OSC, set_processor_param)
	-- ⚠ `i` est le RANG du paramètre de contrôle (nth_parameter), pas le numéro de port : c'est ce qu'attendent
	-- set/get_processor_param et la surface OSC. Indexer par port écrivait sur le mauvais paramètre (mesuré 2026-11-10).
	local out = {}
	for i = 0, pl:parameter_count () - 1 do
		local port, r = pl:nth_parameter (i, true)
		if not r[2] then break end
		if pl:parameter_is_input (port) and pl:parameter_is_control (port) then
			local _, t = pl:get_parameter_descriptor (port, ARDOUR.ParameterDescriptor ())
			out[#out + 1] = { i = i, port = port, label = pl:parameter_label (port), lower = t[2].lower, upper = t[2].upper }
		end
	end
	return out
end

local function find_param (params, label)
	-- la règle de golem_rig.resolve_param : label exact, puis sous-chaîne sans casse
	for _, p in ipairs (params) do if p.label == label then return p end end
	local l = label:lower ()
	for _, p in ipairs (params) do if p.label:lower ():find (l, 1, true) then return p end end
	return nil
end

-- LE FICHIER D'UN BLOC EST-IL LU ? La propriété relue (NAM, zeroconvolv la renvoient) ; sinon le témoin de sortie du
-- plugin (`loaded_output`, > 0 : sfizz ne renvoie jamais son .sfz, son « Number of regions » monte au chargement)
-- UN MÊME FICHIER, DEUX ÉCRITURES (2026-11-19, portage Windows) : sous Windows un plugin peut rendre D:\a\b.nam quand le
-- bridge a envoyé D:/a/b.nam, et la casse n'y distingue pas deux fichiers — ailleurs, l'égalité stricte comme avant
local WINDOWS = package.config:sub (1, 1) == "\\"
local function same_path (a, b)
	if not WINDOWS then return a == b end
	return a:gsub ("\\", "/"):lower () == b:gsub ("\\", "/"):lower ()
end

local function file_loaded (b, prop, path)
	local w = b.spec.loaded_output
	if w then
		local pl = b.proc:to_insert ():plugin (0)
		for i = 0, pl:parameter_count () - 1 do
			if pl:parameter_is_output (i) and pl:parameter_is_control (i) and pl:parameter_label (i) == w then
				return (pl:get_parameter (i) or 0) > 0
			end
		end
		return false
	end
	return same_path (tostring (ARDOUR.LuaAPI.get_plugin_insert_property (b.proc:to_insert (), prop) or ""), path)
end

-- LE LIMITEUR DE SÉCURITÉ compilé : gfx-limiter (classe GoleMFxLimiter01), réglé comme golem_safety.jsfx
local SAFETY_VST3 = "476F6C654D46784C696D697465723031"
local SAFETY_PARAMS = {
	{ pid = "lookahead", label = "Lookahead", value = 0 },        -- aucune anticipation : latence 0
	{ pid = "threshold", label = "Threshold", value = -1 },       -- plafond −1 dBFS
	{ pid = "release", label = "Release", value = 15 },
	{ pid = "style", label = "Style", value = 0 },                -- clean
	{ pid = "auto_release", label = "Auto Release", value = 0 },
	{ pid = "gain", label = "Input Gain", value = 0 },
}
-- l'index du dernier plugin d'une route (le limiteur de sécurité est posé en dernier)
local function r_last_plugin (r)
	local i = 0
	while not r:nth_plugin (i):isnil () do i = i + 1 end
	return i - 1
end

-- ── LE VST HOST (golem docs/platforms.md §6.1 ; sous REAPER : golem_rig.lua, actions vst_*) ──────────────────────────
-- Un bloc qui porte N'IMPORTE QUEL plugin VST3 installé, choisi par son nom (« VST3: Nom (Éditeur) », la forme que
-- REAPER donne : un patch fait sous REAPER retrouve son plugin ici). Ses potards sont les paramètres que le musicien a
-- choisis (`knobs`), adressés par leur NOM d'abord, par leur rang sinon, en valeur normalisée.
local HOST = { ids = nil, info = {} }
HOST.bare = function (name)
	local n = tostring (name or ""):gsub ("^%s*%w+:%s*", "")
	while true do
		local m = n:gsub ("%s*%b()%s*$", "")
		if m == n then break end
		n = m
	end
	return n:lower ()
end
HOST.scan = function ()
	local ids, rows = {}, {}
	for p in ARDOUR.LuaAPI.list_plugins ():iter () do
		if p.type == ARDOUR.PluginType.VST3 then
			local who = tostring (p.creator or "")
			ids[HOST.bare (p.name)] = p.unique_id
			HOST.info[p.unique_id] = { vendor = who, pname = p.name }
			-- `vendor` et `pname` tels que le moteur les connaît : le dossier de ses presets en découle (l'état d'un plugin)
			rows[#rows + 1] = { name = (p:is_instrument () and "VST3i: " or "VST3: ") .. p.name .. (who ~= "" and (" (" .. who .. ")") or ""),
				ident = p.unique_id, vendor = who, pname = p.name }
		end
	end
	HOST.ids = ids
	return rows
end
HOST.id_of = function (name)
	if not HOST.ids then HOST.scan () end
	return HOST.ids[HOST.bare (name)]
end
HOST.param = function (params, e)                 -- le paramètre d'un potard : son nom exact, sinon son rang
	if (e.name or "") ~= "" then
		for _, p in ipairs (params) do if p.label == e.name then return p end end
	end
	for _, p in ipairs (params) do if p.i == e.index then return p end end
	return nil
end

local function set_params (b, entries)
	local proc = b.proc
	local params = plugin_params (proc:to_insert ():plugin (0))
	for _, e in ipairs (entries or {}) do
		local p = e.index ~= nil and HOST.param (params, e) or find_param (params, e.label)
		if not p then
			log ("  param " .. tostring (b.spec.id) .. "." .. tostring (e.pid) .. " : label « " .. tostring (e.label or e.name) .. " » introuvable")
		else
			local v = e.value
			if v == nil and e.norm ~= nil then v = p.lower + e.norm * (p.upper - p.lower) end
			if v < p.lower then v = p.lower elseif v > p.upper then v = p.upper end
			ARDOUR.LuaAPI.set_processor_param (proc, p.i, v)
		end
	end
end

-- LES ENTRÉES DE LA CARTE (lot A2.3) : trois pistes permanentes golem:in1..3, chacune sur une entrée physique, vumètre à
-- l'ENTRÉE, aucune sortie. Créées en premier, ce sont les strips 1..3 de la surface OSC — comme les « Sandbox #Input 1/2/3 »
-- de REAPER : leur /strip/meter devient /track/1..3/vu côté bridge (bridge/engine/ardour.py), les vumètres d'entrée de
-- golem (Soundcard, /live, écrêtage) marchent sans changement. Les lanes commencent au strip 4.
local INPUT_METERS = 3
-- les routes PERMANENTES créées avant tout rig prennent les premiers strips de la surface OSC : les vumètres d'entrée,
-- puis le métronome (golem:click)
local SERVICE_ROUTES = 0
INPUT_METERS_N = function () return INPUT_METERS + SERVICE_ROUTES end
-- aucune sortie reliée à la carte : un banc (GOLEM_ENGINE_NO_OUTPUT=1), ou un essai silencieux sur le rack lui-même
-- (config/golem-engine.json « no_output »: true, relu à chaque reconstruction)
local function no_output ()
	if os.getenv ("GOLEM_ENGINE_NO_OUTPUT") == "1" then return true end
	local cfg = read_json_early (AUDIO_CFG)
	return cfg and cfg.no_output == true
end

-- LE PREMIER ÉLÉMENT d'une liste rendue par Ardour, COPIÉ. Jamais `:front ()` : LuaBridge le lie en `T& front ()`, une
-- RÉFÉRENCE dans la liste temporaire ; dès que le ramasse-miettes libère la liste, la route gardée dans RIG pointe dans
-- de la mémoire rendue -> segfault au premier appel (2026-11-11 14:11 et 2026-11-12 09:00, core : r:mute_control () sur
-- une route libérée, adresse = des octets de texte) ou « shared_ptr is nil ». `:iter ()` pousse une copie du shared_ptr.
local function first (list)
	for x in list:iter () do return x end
	return nil
end

local TUNERS = {}                       -- entrée -> le processeur d'accordeur de sa piste golem:inN
local function ensure_input_meters ()
	local ins = physical (true)
	for n = 1, INPUT_METERS do
		local name = "golem:in" .. n
		local r = Session:route_by_name (name)
		if r:isnil () then
			r = first (Session:new_audio_track (1, 1, ARDOUR.RouteGroup (), 1, name, ARDOUR.PresentationInfo.max_order,
				ARDOUR.TrackMode.Normal, true))
		end
		r:input ():disconnect_all ()
		r:output ():disconnect_all ()
		r:set_meter_point (ARDOUR.MeterPoint.MeterInput)
		r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
		if ins[n] then r:input ():audio (0):connect (ins[n]) end
		-- L'ACCORDEUR de cette entrée (« golem Tuner », DSP Lua) : posé une fois, ENDORMI — armer ne refait pas le
		-- graphe en plein jeu, et il ne coûte rien tant qu'on n'accorde pas
		local tp = r:nth_plugin (0)
		if tp:isnil () then
			tp = ARDOUR.LuaAPI.new_luaproc (Session, "golem Tuner")
			if not tp:isnil () then CHAIN.pre (r, tp) end
		end
		if not tp:isnil () then tp:deactivate (); TUNERS[n] = tp end
	end
	log ("  entrées : " .. #ins .. " sur la carte, vumètres golem:in1.." .. INPUT_METERS)
end

local function clear_routes ()
	for _, b in pairs (RIG.blocks) do
		if b.spec and b.spec.loaded_output then GRAVE.keep (b.proc) end
	end
	local rl = ARDOUR.RouteListPtr ()
	for r in Session:get_routes ():iter () do
		-- les pistes d'une PRISE en cours (golem:rec:…) survivent à un rappel : la prise continue, sur le nouveau son
		if not r:is_master () and not r:is_monitor () and not r:is_auditioner ()
		   and not r:name ():find ("^golem:in%d") and not r:name ():find ("^golem:rec:")
		   and r:name () ~= "golem:click" and r:name () ~= "golem:drums" and not r:name ():find ("^golem:std")
		   and not r:name ():find ("^golem:backing") and r:name () ~= "golem:sample" and r:name () ~= "golem:looper" and r:name () ~= "golem:clock" then rl:push_back (r) end
	end
	-- RENOMMÉES AVANT D'ÊTRE RETIRÉES : la surface OSC garde ses strips (shared_ptr) jusqu'à son prochain recalcul de
	-- banques ; la route survit, ses PORTS aussi, et recréer une route du même nom échouait (« Port already exists »,
	-- un rebuild sur deux en éditant un patch, mesuré 2026-11-13). Un nom unique libère les noms de ports tout de suite
	-- (set_name est virtuel : une piste renomme aussi sa playlist).
	-- TOUT DÉBRANCHER D'ABORD, puis laisser le moteur vider sa file de connexions (2026-11-16, core du banc : plantage
	-- dans IO::connection_change <- PortManager::connect_callback, fil audio — une déconnexion notifiée à une route
	-- déjà détruite). Les pistes d'une prise en cours lâchent aussi les sorties qu'elles écoutaient (rec_link les
	-- reprend après le rappel).
	if rl:size () > 0 then
		for _, t in pairs (REC and REC.tracks or {}) do
			if not t.di then t.route:input ():disconnect_all () end
		end
		for r in rl:iter () do
			r:input ():disconnect_all ()
			r:output ():disconnect_all ()
		end
		ARDOUR.LuaAPI.usleep (120000)
	end
	for r in rl:iter () do
		GONE = GONE + 1
		r:set_name ("golem-gone-" .. GONE)
	end
	if rl:size () > 0 then Session:remove_routes (rl) end
	-- LES RÉFÉRENCES LÂCHÉES TOUT DE SUITE : le Lua tenait encore les routes et les plugins supprimés (shared_ptr) ; ils
	-- n'étaient détruits qu'au passage du ramasse-miettes, n'importe quand plus tard (pendant le décodage d'une commande),
	-- alors que la surface OSC ou le fil audio pouvaient encore les voir. Les scripts d'Ardour font ainsi.
	rl = nil
	-- CE QUI PRÉCÈDE LE RIG sur la surface OSC : toutes les routes qui restent (vumètres d'entrée, services, stems d'une
	-- backing créés à la demande…), comptées ici plutôt que supposées ; les pistes d'une prise en cours à part
	local base = 0
	for r in Session:get_routes ():iter () do
		-- les pistes de prise PERMANENTES (créées au démarrage) précèdent le rig comme les services ; les temporaires non
		if not r:is_master () and not r:is_monitor () and not r:is_auditioner ()
		   and (not r:name ():find ("^golem:rec:") or REC_POOLED (r:name ())) then base = base + 1 end
	end
	RIG = { preset = nil, routes = {}, order = {}, blocks = {}, nch = {}, asleep = {}, specs = {}, mixer = RIG.mixer or {},   -- les trims sont du rig, pas du preset
		base = base, rec_before = REC_COUNT () }   -- les pistes d'une prise en cours précèdent les routes qu'on va créer
	collectgarbage ()
	collectgarbage ()
end

local function new_route (spec)
	local r
	if spec.kind == "midi" then
		-- une PISTE MIDI : entrée MIDI, deux sorties audio (l'instrument est stéréo) ; l'instrument est un bloc comme un
		-- autre (add_block), monitoring à l'ENTRÉE comme les pistes audio
		r = first (Session:new_midi_track (ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1),
			ARDOUR.ChanCount (ARDOUR.DataType ("audio"), 2), false, ARDOUR.PluginInfo (), nil, ARDOUR.RouteGroup (), 1,
			spec.name, ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, false))
		local t = r:to_track ()
		t:monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
		if spec.midi and spec.midi.channel then
			t:to_midi_track ():set_capture_channel_mode (ARDOUR.ChannelMode.FilterChannels, 1 << (spec.midi.channel - 1))
		end
	elseif spec.kind == "track" then
		r = first (Session:new_audio_track (1, 1, ARDOUR.RouteGroup (), 1, spec.name, ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true))
		r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
	else
		-- un BUS a les canaux de sa source la plus large : une branche stéréo rend un merge stéréo (A3, stéréo)
		local nin = 1
		for _, src in ipairs (spec.from or {}) do nin = math.max (nin, RIG.nch[src] or 1) end
		r = first (Session:new_audio_route (nin, nin, ARDOUR.RouteGroup (), 1, spec.name, ARDOUR.PresentationInfo.Flag.AudioBus,
			ARDOUR.PresentationInfo.max_order))
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	return r
end

local function add_block (r, spec, nch)
	local p
	if spec.plugin.lv2 then
		p = ARDOUR.LuaAPI.new_plugin (Session, spec.plugin.lv2, ARDOUR.PluginType.LV2, "")
	elseif spec.plugin.vst3 then
		local okn, errn = pcall (function () p = ARDOUR.LuaAPI.new_plugin (Session, spec.plugin.vst3, ARDOUR.PluginType.VST3, "") end)
		if not okn then error ("création du plugin VST3 " .. tostring (spec.plugin.vst3) .. " : " .. tostring (errn), 0) end
	elseif spec.plugin.host then                    -- le VST Host : un plugin installé, retrouvé par son nom
		local id = HOST.id_of (spec.plugin.host)
		if not id then
			log ("  bloc " .. tostring (spec.id) .. " : plugin absent " .. tostring (spec.plugin.host))
			return nil
		end
		p = ARDOUR.LuaAPI.new_plugin (Session, id, ARDOUR.PluginType.VST3, "")
	else
		p = ARDOUR.LuaAPI.new_luaproc (Session, spec.plugin.lua)
	end
	if p:isnil () then
		log ("  bloc " .. tostring (spec.id) .. " : plugin absent " .. tostring (spec.plugin.lv2 or spec.plugin.vst3 or spec.plugin.host or spec.plugin.lua))
		return nil
	end
	local okc, errc = pcall (function () nch = CHAIN.add (r, p, nch or 1) end)   -- en fin de chaîne ; un plugin stéréo passe la route en stéréo
	if not okc then error ("insertion de " .. tostring (spec.id) .. " dans " .. r:name () .. " : " .. tostring (errc), 0) end
	for prop, path in pairs (spec.files or {}) do
		ARDOUR.LuaAPI.set_plugin_insert_property (p:to_insert (), prop, path)
	end
	return p, nch
end

-- LA TABLE DU TRADUCTEUR DE BATTERIE (golem Drumtrans, scripts/golem_drumtrans.lua) : dans la mémoire partagée de son
-- instance, comme gmem golem_drumtrans sous REAPER — note du kit par note du module, la charleston, puis le nonce (posé
-- en DERNIER : le DSP passe tout tel quel tant qu'il vaut 0)
local function write_drumtrans (proc, dt)
	local lp = proc:to_insert ():plugin (0):to_luaproc ()
	if lp:isnil () then return false end
	local shm = lp:shmem ()
	local a = shm:to_int (0):array ()
	local map, hh = dt.map or {}, dt.hh or {}
	for n = 0, 127 do a[n + 1] = math.floor (tonumber (map[n + 1]) or -1) end
	local function put (ix, v, dflt) a[ix + 1] = math.floor (tonumber (v) or dflt) end
	put (128, hh.cc, -1); put (129, hh.open_value, 0); put (130, hh.closed_value, 127); put (131, hh.band_a, 33)
	put (132, hh.band_b, 66); put (133, hh.positions, 3); put (134, hh.closed, -1); put (135, hh.half, -1)
	put (136, hh.open, -1); put (138, dt.chan, 10)
	shm:atomic_set_int (137, shm:atomic_get_int (137) + 1)
	return true
end

-- le TEMPO du morceau (le plan le porte : la ligne de setlist, sinon le preset — golem/bridge ardour.py _bpm), comme
-- golem_rig.lua le pose sur REAPER : les delays et trémolos synchronisés lisent le tempo de l'hôte (golem-fx)
local CLICK_TEMPO                         -- défini avec le métronome, plus bas
local CLICK_ROUTE                         -- idem : la route du métronome
local DRUMS_TEMPO, DRUMS_ROUTE            -- la boîte à rythmes, définie plus bas
local STD_TEMPO, STD_PARTS                -- le lecteur de standards, idem
local BACKING_BUS, BACKING_TAKE           -- la backing : son bus, et ce qu'une prise lui demande
local SAMPLE = { route = nil, proc = nil, blocks = {}, order = {}, gen = 0, queue = {}, last = nil }   -- le lanceur de samples
-- le looper : sa route, le câblage de ses boucles sur les lanes du rig (`wire`), sa boucle (`tick`) — le fichier est à
-- la limite des 200 variables locales de Lua : un service = UNE table, sa section dans un bloc `do`
local LOOPER = { route = nil, proc = nil, ssid = 0, loops = nil, seq = nil, pub = "", at = 0 }
local function set_tempo (bpm)
	bpm = tonumber (bpm)
	if not bpm or bpm < 20 or bpm > 400 then return end
	local cur = Temporal.TempoMap.read ():quarters_per_minute_at (Temporal.timepos_t (0))
	if math.abs (cur - bpm) < 0.01 then return end
	local tm = Temporal.TempoMap.write_copy ()
	tm:set_tempo (Temporal.Tempo (bpm, bpm, 4), Temporal.timepos_t (0))
	Temporal.TempoMap.update (tm)
	log ("  tempo <- " .. bpm .. " BPM")
	if CLICK_TEMPO then CLICK_TEMPO (bpm) end        -- le métronome compte au tempo du morceau
	if MIDICLOCK.tempo then MIDICLOCK.tempo (bpm) end        -- l'horloge MIDI aussi : l'arpégiateur du clavier suit le preset
	if DRUMS_TEMPO then DRUMS_TEMPO (bpm) end        -- la boîte à rythmes aussi
	if STD_TEMPO then STD_TEMPO (bpm) end            -- et la grille d'un standard
end

-- LA BRANCHE QUE LA SCÈNE COUPE, ENDORMIE (2026-11-13, golem docs/ardour-plan.md) : un mute laisse Ardour calculer
-- ses plugins — l'ampli NAM d'une branche muette coûtait autant que celui qui joue. Endormie = ses plugins désactivés
-- APRÈS le mute ; réveillée = réactivés AVANT le dé-mute. Le prix possible : un trou ou un claquement au retour (NAM et
-- queues de reverb repartent à froid) — d'où l'interrupteur, ÉTEINT tant que le banc des trous de scène n'a pas tranché :
-- config/golem-engine.json « sleep_muted_branches »: true (relu à chaque scène).
local function sleep_muted ()
	local cfg = read_json_early (AUDIO_CFG)
	return cfg and cfg.sleep_muted_branches == true
end
local function route_plugins (r, on)
	local i = 0
	while true do
		local p = r:nth_plugin (i)
		if p:isnil () then break end
		if on then p:activate () else p:deactivate () end
		i = i + 1
	end
	return i
end

-- DU MIDI ÉCRIT DANS UN PLUGIN (golem bridge/engine/keys_midi.py) : la registration de l'orgue (setBfree n'a aucun port
-- de contrôle : des Control Change), la voix du DX7 (un SysEx de 163 octets). Chaque message passe par le lecteur MIDI
-- d'Ardour, qui le valide et rend le tableau d'octets que `write_immediate_event` attend (1024 octets au plus).
local function midi_write (proc, msgs)
	local ins = proc:to_insert ()
	local parser = ARDOUR.RawMidiParser ()
	local n = 0
	for _, m in ipairs (msgs or {}) do
		parser:reset ()
		for _, byte in ipairs (m) do
			if parser:process_byte (byte) then
				if ins:write_immediate_event (Evoral.EventType.MIDI_EVENT, parser:buffer_size (), parser:midi_buffer ()) then n = n + 1 end
			end
		end
	end
	return n
end

-- le MIDI d'un bloc, seulement ce qui a CHANGÉ depuis le dernier envoi (`again` : tout, un plugin tout juste posé)
local function send_midi (b, msgs, again)
	b.midi_sent = (not again and b.midi_sent) or {}
	local todo = {}
	for i, m in ipairs (msgs or {}) do
		local key = table.concat (m, ",")
		if b.midi_sent[i] ~= key then todo[#todo + 1] = m; b.midi_sent[i] = key end
	end
	if #todo > 0 then
		local n = midi_write (b.proc, todo)
		log ("  " .. tostring (b.spec.id) .. " : " .. n .. "/" .. #todo .. " message(s) MIDI")
	end
end

-- L'ÉTAT D'UN SYNTHÉ (le son de Vital) : un preset VST3 que le bridge a écrit dans le dossier de presets du plugin
-- (bridge/engine/ardour.py) ; le fichier est relu à chaque chargement, son empreinte dit s'il a changé.
local function load_preset (b, pr)
	if b.preset_sig == pr.sig then return end
	local pl = b.proc:to_insert ():plugin (0)
	local rec = pl:preset_by_uri (pr.uri)
	if not rec then
		log ("  ⚠ " .. tostring (b.spec.id) .. " : preset introuvable (" .. tostring (pr.uri) .. ")")
		return
	end
	local ok = pl:load_preset (rec)
	if ok then b.preset_sig = pr.sig end
	log ("  " .. tostring (b.spec.id) .. " : état du plugin " .. (ok and "chargé" or "REFUSÉ") .. " (" .. tostring (pr.sig) .. ")")
end

-- LE MIXER DE SORTIES (golem docs/mixer.md, bridge/mixer.py) : le trim d'une source — atténuation seule, -60 dB =
-- silence — et son mute, autorité du RIG (config/mixer.json), posés APRÈS le niveau de scène. REAPER les porte sur le
-- send matériel de la piste ; une route d'Ardour n'a pas de niveau par sortie : les deux étages s'additionnent sur le
-- fader (deux gains après les plugins, l'ordre ne change rien) et les deux mutes se combinent. `spec.mixer` = l'id de
-- la source (« in2 »), donné par le plan aux seules routes qui sortent vers la carte.
local function apply_out (r, spec)
	local lv = spec.mixer and RIG.mixer[spec.mixer] or nil
	local db = tonumber (lv and lv.db) or 0
	if db > 0 then db = 0 end
	local cut = db <= -60
	local mute = spec.mute == true or (lv and lv.mute == true) or cut
	r:mute_control ():set_value (mute and 1 or 0, NG)
	r:gain_control ():set_value (ARDOUR.DSP.dB_to_coefficient ((spec.gain_db or 0) + (cut and 0 or db)), NG)
end

-- les tranches de SERVICE du mixer (« drums », « click ») : leur trim sur le fader de leur route permanente
local SERVICE_MIX = {}                    -- id de source -> fonction qui rend la route (remplie par chaque service)
local function service_mix ()
	for src, get in pairs (SERVICE_MIX) do
		local r = get ()
		if r then apply_out (r, { mixer = src, gain_db = 0, mute = false }) end
	end
	-- les parties d'un standard : une tranche chacune (« std-keys »…), leur niveau propre, et muettes si la grille en
	-- cours ne les joue pas
	for id, part in pairs (STD_PARTS and STD_PARTS () or {}) do
		apply_out (part.route, { mixer = "std-" .. id, gain_db = part.gain or 0, mute = not part.on })
	end
end

local function apply_state (plan)
	-- l'état d'une scène sur un rig déjà posé : enable, mute, paramètres, gains. Aucun plugin ajouté ni retiré.
	set_tempo (plan.bpm)
	if type (plan.mixer) == "table" then RIG.mixer = plan.mixer; service_mix () end
	local missing = 0
	local sleep = sleep_muted ()
	for _, spec in ipairs (plan.tracks or {}) do
		local r = RIG.routes[spec.name]
		if not r then
			missing = missing + 1
		else
			local asleep = sleep and spec.role == "branch" and spec.mute == true
			if not asleep and RIG.asleep[spec.name] then          -- réveillée AVANT d'être rendue audible
				route_plugins (r, true)
				RIG.asleep[spec.name] = nil
				log ("  " .. spec.name .. " : branche réveillée")
			end
			RIG.specs[spec.name] = spec
			apply_out (r, spec)
			-- le gain du merge AVANT ses plugins (le trim d'Ardour est en tête de route ; REAPER : un Volume Adjustment en
			-- tête de chaîne), le niveau de scène sur le fader (gain_db) — golem/bridge ardour_plan.py
			r:trim_control ():set_value (ARDOUR.DSP.dB_to_coefficient (spec.trim_db or 0), NG)
			for _, bs in ipairs (spec.blocks or {}) do
				local b = RIG.blocks[bs.id]
				if b then
					b.spec = bs
					if bs.preset then load_preset (b, bs.preset) end   -- l'état AVANT les potards, qui le retouchent
					set_params (b, bs.params)
					-- le tempo du morceau, pour un plugin qui joue en mesure sans lire le transport (l'arpégiateur)
					if bs.bpm and plan.bpm then set_params (b, { { pid = "bpm", label = bs.bpm, value = plan.bpm } }) end
					b.proc:to_insert ():enable (bs.enabled ~= false)
					if bs.midi then send_midi (b, bs.midi, false) end
				end
			end
			if asleep then                                      -- APRÈS le mute et les enable (un enable réactive)
				local n = route_plugins (r, false)
				if not RIG.asleep[spec.name] then log ("  " .. spec.name .. " : branche muette endormie (" .. n .. " plugin(s))") end
				RIG.asleep[spec.name] = true
			end
		end
	end
	return missing
end

local function write_livemap ()
	local blocks = {}
	for id, b in pairs (RIG.blocks) do
		local params = {}
		local pl = plugin_params (b.proc:to_insert ():plugin (0))
		for _, k in ipairs (b.spec.known or {}) do
			local p = k.index ~= nil and HOST.param (pl, k) or find_param (pl, k.label)
			if p then params[k.pid] = { p = p.i, pmin = p.lower, pmax = p.upper } end
		end
		-- `shadow` : un plugin que le moteur ajoute pour un bloc (le baffle par défaut d'une tête) — pas un bloc du patch
		if not b.spec.shadow then blocks[id] = { track = b.ssid, fx = b.fx, type = b.spec.type, params = params } end
	end
	write_file (LIVEMAP, json_encode ({ preset = RIG.preset or "", engine = "golem-engine", blocks = blocks }))
end

-- l'ORDRE DE CONSTRUCTION : une route après ses sources (`from`) — le plan liste le merge avant ses branches, et un bus
-- prend les canaux de sa source la plus large (une branche stéréo -> un merge stéréo). Les strips de la surface OSC
-- suivent l'ordre de CRÉATION (routes ajoutées en fin) : RIG.order le suit, et le livemap porte ce numéro au bridge.
local function build_order (tracks)
	local done, out, left = {}, {}, {}
	for _, t in ipairs (tracks or {}) do left[#left + 1] = t end
	while #left > 0 do
		local rest, moved = {}, false
		for _, t in ipairs (left) do
			local ready = true
			for _, src in ipairs (t.from or {}) do if not done[src] then ready = false end end
			if ready then out[#out + 1] = t; done[t.name] = true; moved = true else rest[#rest + 1] = t end
		end
		if not moved then for _, t in ipairs (rest) do out[#out + 1] = t end; break end   -- boucle : l'ordre du plan
		left = rest
	end
	return out
end

-- LA CLÉ d'un gate à clé : le sidechain du plugin, relié à l'entrée de la carte de la lane. Ardour REFUSE d'ajouter un
-- sidechain pendant une prise (un rappel de preset en pleine prise) : le gate écoute alors son entrée principale, et
-- la clé est posée à la FIN de la prise (`rekey`). Un sidechain qui existe déjà (refus à moitié fait) est relié quand
-- même : un sidechain sans rien dessus tient le gate FERMÉ — le rig muet. Rend true si la clé est reliée.
local function key_block (r, p, bs, ins)
	local pi = p:to_insert ()
	if not pi:has_sidechain () and not r:add_sidechain (p) and not pi:has_sidechain () then
		log ("  ⚠ " .. tostring (bs.id) .. " : sidechain refusé (prise en cours ?) — le gate écoute son entrée")
		return false
	end
	if not ins[bs.key_input] then
		log ("  ⚠ " .. tostring (bs.id) .. " : pas d'entrée " .. tostring (bs.key_input) .. " sur la carte pour la clé")
		return false
	end
	local sc = pi:sidechain_input ()
	local n = sc:n_ports ():n_audio ()
	local ok = n > 0
	for c = 0, n - 1 do
		if not sc:audio (c):connected_to (ins[bs.key_input]) then
			local rc = sc:audio (c):connect (ins[bs.key_input])
			if rc ~= 0 then ok = false; log ("  lien de clé refusé " .. tostring (bs.id) .. " (" .. tostring (rc) .. ")") end
		end
	end
	log ("  " .. tostring (bs.id) .. " : clé <- entrée " .. tostring (bs.key_input) .. " (" .. n .. " canal/canaux)")
	return ok
end

-- les clés qu'une prise a empêché de poser (ou de relier), reprises une fois la prise finie
local function rekey ()
	local ins = physical (true)
	for _, b in pairs (RIG.blocks) do
		if b.spec.key_input and not b.keyed then b.keyed = key_block (b.route, b.proc, b.spec, ins) end
	end
end

local function materialize (plan)
	local t0 = now_s ()
	xr_hold ()
	clear_routes ()
	RIG.preset = plan.preset
	local ins, outs = physical (true), physical (false)
	local silent = no_output ()
	local inputs = {}                              -- {port de la route, port de la carte} : reliés une fois la scène posée
	log ("  carte : " .. #ins .. " entrée(s), " .. #outs .. " sortie(s) physiques" .. (silent and " — ESSAI SILENCIEUX" or ""))
	for _, spec in ipairs (build_order (plan.tracks)) do
		MAT_STEP = "route " .. tostring (spec.name)   -- l'étape du montage, dite par un échec (une exception C++ n'a pas de pile)
		local r = new_route (spec)
		RIG.routes[spec.name] = r
		RIG.order[#RIG.order + 1] = spec.name
		local ssid = ssid_of (#RIG.order)            -- l'ordre des strips de la surface OSC : golem:in1..3 d'abord
		local k = 0
		local nch = spec.kind == "midi" and 2 or r:input ():n_ports ():n_audio ()
		if nch < 1 then nch = 1 end
		for _, bs in ipairs (spec.blocks or {}) do
			MAT_STEP = "route " .. tostring (spec.name) .. ", bloc " .. tostring (bs.id)
			local p, n2 = add_block (r, bs, nch)
			if n2 then nch = n2 end                    -- un plugin absent ne change rien aux canaux
			MAT_STEP = "route " .. tostring (spec.name) .. ", bloc " .. tostring (bs.id) .. " (réglages initiaux)"
			if p and bs.init then set_params ({ proc = p, spec = bs }, bs.init) end   -- golem_rig FX_INIT
			MAT_STEP = "route " .. tostring (spec.name) .. ", bloc " .. tostring (bs.id) .. " (clé, traducteur)"
			-- LA CLÉ d'un gate à clé (Met, le gate de golem-fx ; golem docs/golem-fx-sheet.md §4) : le sidechain du
			-- plugin, relié à l'entrée de la carte de la lane — le DI brut, pas ce qui sort de l'ampli. Sans clé reliée,
			-- Met écoute son entrée principale.
			local keyed = nil
			if p and bs.key_input then keyed = key_block (r, p, bs, ins) end
			if p and bs.drumtrans and not write_drumtrans (p, bs.drumtrans) then
				log ("  ⚠ " .. tostring (bs.id) .. " : table du traducteur non posée (notes du module telles quelles)")
			end
			if p then
				RIG.blocks[bs.id] = { route = r, proc = p, ssid = ssid, fx = k, spec = bs, keyed = keyed }
				k = k + 1
			end
		end
		RIG.nch[spec.name] = math.max (nch, r:output ():n_ports ():n_audio ())
		if RIG.nch[spec.name] > 1 then log ("  " .. spec.name .. " : stéréo (" .. RIG.nch[spec.name] .. " canaux)") end
		local function link (port, other)
			local rc = port:connect (other)
			if rc ~= 0 then log ("  lien refusé " .. port:name () .. " -> " .. tostring (other) .. " (" .. tostring (rc) .. ")") end
		end
		MAT_STEP = "route " .. tostring (spec.name) .. ", sorties"
		if spec.out and #spec.out > 0 then
			-- le LIMITEUR DE SÉCURITÉ en dernier plugin de toute route qui sort vers la carte (golem_safety.jsfx sous
			-- REAPER, porté à l'identique : -1 dBFS, aucune anticipation) — après les blocs : il ne décale aucun index
			-- COMPILÉ d'abord (2026-11-13) : le DSP Lua coûtait 323 µs par cycle de 4 ms (dspstats, golem
			-- docs/ardour-plan.md). gfx-limiter de golem-fx, en mode SANS anticipation (latence 0, aucun échantillon
			-- au-dessus du plafond, transparent en dessous), réglé comme golem_safety : −1 dBFS, relâchement 15 ms, style
			-- clean, relâchement fixe. Le Lua reste le repli si le plugin manque.
			local sp = ARDOUR.LuaAPI.new_plugin (Session, SAFETY_VST3, ARDOUR.PluginType.VST3, "")
			if not sp:isnil () then
				r:add_processor_by_index (sp, -1, nil, true)
				set_params ({ proc = sp, spec = { id = "safety" } }, SAFETY_PARAMS)
			else
				log ("  ⚠ " .. spec.name .. " : gfx-limiter absent — limiteur de sécurité en Lua (plus coûteux)")
				sp = ARDOUR.LuaAPI.new_luaproc (Session, "golem Safety")
				if sp:isnil () then log ("  ⚠ " .. spec.name .. " : limiteur golem Safety introuvable (ARDOUR_DATA_PATH)")
				else r:add_processor_by_index (sp, -1, nil, true) end
			end
		end
		-- L'ENTRÉE EST RELIÉE EN DERNIER, la scène posée (`inputs`, plus bas) : reliée ici, le signal traversait le rig
		-- le temps du montage — toutes branches ouvertes, tous blocs allumés — et un delay en gardait l'écho (mesuré
		-- 2026-11-17 : -46 dBFS d'écho fantôme sur un bus dont les deux branches sont mutées)
		if spec.kind == "midi" then
			local dev = spec.midi and spec.midi.device
			local ports = midi_device_ports (dev)
			if #ports == 0 then log ("  " .. spec.name .. " : clavier « " .. tostring (dev) .. " » absent — piste muette") end
			for _, p in ipairs (ports) do inputs[#inputs + 1] = { r:input ():midi (0), p } end
		elseif spec.input then
			if ins[spec.input] then inputs[#inputs + 1] = { r:input ():audio (0), ins[spec.input] }
			else log ("  " .. spec.name .. " : pas d'entrée " .. tostring (spec.input) .. " sur la carte") end
		end
		local nout = r:output ():n_ports ():n_audio ()
		for k, o in ipairs (spec.out or {}) do
			-- piste stéréo (MIDI) : gauche -> 1re sortie, droite -> 2e ; une seule sortie reçoit les deux (somme)
			local ch = (nout > 1 and #spec.out > 1) and math.min (k, nout) - 1 or 0
			if silent then log ("  " .. spec.name .. " : sortie " .. tostring (o) .. " NON reliée (essai silencieux)")
			elseif outs[o] then
				link (r:output ():audio (ch), outs[o])
				if nout > 1 and #spec.out == 1 then link (r:output ():audio (1), outs[o]) end
			else log ("  " .. spec.name .. " : pas de sortie " .. tostring (o) .. " sur la carte") end
		end
	end
	MAT_STEP = "liens entre routes"
	for _, spec in ipairs (plan.tracks or {}) do     -- les liens entre routes, une fois toutes créées
		local dst = RIG.routes[spec.name]
		for _, src in ipairs (spec.from or {}) do
			local s = RIG.routes[src]
			if s then
				-- canal par canal : une source mono nourrit les deux entrées d'un bus stéréo (le mono sur les deux, comme
				-- REAPER) ; une source stéréo vers un bus stéréo, gauche sur gauche, droite sur droite
				local sn, dn = s:output ():n_ports ():n_audio (), dst:input ():n_ports ():n_audio ()
				for ch = 0, dn - 1 do
					local rc = dst:input ():audio (ch):connect (s:output ():audio (math.min (ch, sn - 1)):name ())
					if rc ~= 0 then log ("  lien refusé " .. src .. " -> " .. spec.name .. " (" .. tostring (rc) .. ")") end
				end
				if dn == 1 and sn > 1 then                 -- jamais rencontré (un bus a les canaux de sa source) : somme
					for ch = 1, sn - 1 do dst:input ():audio (0):connect (s:output ():audio (ch):name ()) end
				end
			end
		end
	end
	-- LES FICHIERS D'ABORD, plugins actifs : un LV2 désactivé ne tourne pas, son chargement différé (worker) n'aboutit
	-- pas — la première scène qui l'allumait aurait chargé le modèle EN JOUANT (mesuré 2026-11-10 : NAM en bypass,
	-- modèle jamais lu). Comme l'union de REAPER : tout est chargé avant la première scène.
	local tf, pending = now_s (), 1
	while pending > 0 and now_s () - tf < 5.0 do
		pending = 0
		for _, b in pairs (RIG.blocks) do
			for prop, path in pairs (b.spec.files or {}) do
				if not file_loaded (b, prop, path) then pending = pending + 1 end
			end
		end
		if pending > 0 then ARDOUR.LuaAPI.usleep (20000) end
	end
	log (string.format ("  fichiers lus en %.0f ms%s", (now_s () - tf) * 1000, pending > 0 and (", " .. pending .. " en retard") or ""))
	MAT_STEP = "scène (apply_state)"
	apply_state (plan)
	MAT_STEP = "entrées de la carte"
	for _, l in ipairs (inputs) do                    -- la scène est posée : le signal peut entrer
		local rc = l[1]:connect (l[2])
		if rc ~= 0 then log ("  lien d'entrée refusé " .. l[1]:name () .. " <- " .. tostring (l[2]) .. " (" .. tostring (rc) .. ")") end
	end
	write_livemap ()
	if LOOPER.wire then LOOPER.wire (plan.looper) end -- les boucles écoutent les lanes du nouveau rig (ou se taisent)
	if REC.on then rec_link () end                    -- une prise en cours suit le nouveau son
	xr_release ()
	log (string.format ("rig %s : %d route(s), %d bloc(s) en %.0f ms", tostring (plan.preset), #RIG.order,
		(function () local n = 0; for _ in pairs (RIG.blocks) do n = n + 1 end; return n end) (), (now_s () - t0) * 1000))
end

local function verify_files ()
	local issues, checked = array (), 0
	for id, b in pairs (RIG.blocks) do
		for prop, path in pairs (b.spec.files or {}) do
			checked = checked + 1
			if not file_loaded (b, prop, path) then
				local kind = prop:find ("#ir", 1, true) and "ir" or "model"
				issues[#issues + 1] = { track = b.route:name (), fx = b.fx, uri = prop, kind = kind,
					expected = path:match ("[^/\\]+$") or path }
			end
		end
	end
	if #issues > 0 and not RIG.verified_again then
		RIG.verified_again = true                    -- comme golem_rig : un fichier pas encore lu a droit à une 2e lecture
		RIG.verify_at = now_s () + 2.0
		log ("  vérif : " .. #issues .. " fichier(s) pas encore lu(s) par le plugin -> seconde lecture dans 2 s")
		return
	end
	write_file (RIGCHECK, json_encode ({ t = os.time (), ok = #issues == 0, checked = checked, issues = issues }))
end

-- LES CRÊTES (la chasse au silence de golem, bridge/silence.py) : le niveau de chaque route AU MOMENT de la sonde, dans
-- la forme que REAPER écrit (presets/.peaks.json), avec deux marques que le bridge lit au lieu des noms de pistes :
-- `root` = une ENTRÉE de la carte qu'une lane écoute (les pistes golem:inN, vumètre à l'entrée), `rig` = une route du
-- rig. `hw_sends` = le nombre de sorties de la carte auxquelles la route est RÉELLEMENT reliée.
local PEAKS = ROOT .. "/presets/.peaks.json"
local function peaks (clear)
	local rows = array ()
	-- `inst` : le vumètre (il retombe lentement, comme à l'écran) ; `max` : la crête la plus haute depuis la dernière
	-- remise à zéro (`clear`, le protocole de REAPER : vider, jouer, relire)
	local function level (r, kind)
		local m = r:peak_meter ()
		local best = -150
		for ch = 0, 1 do
			local ok, v = pcall (function () return m:meter_level (ch, kind) end)
			if ok and v and v > best then best = v end
		end
		if best < -150 then best = -150 end
		return best
	end
	local function row (r, t)
		local v = level (r, ARDOUR.MeterType.MeterPeak)
		t.instL, t.instR, t.max = v, v, level (r, ARDOUR.MeterType.MeterMaxPeak)
		if clear then r:peak_meter ():reset_max () end
		rows[#rows + 1] = t
	end
	local used = {}
	for _, spec in pairs (RIG.specs) do if spec.input then used[spec.input] = true end end
	for n = 1, INPUT_METERS do
		local r = Session:route_by_name ("golem:in" .. n)
		if not r:isnil () and used[n] then
			row (r, { track = n .. " golem:in" .. n, root = true, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
		end
	end
	if LOOPER.loops and LOOPER.route then
		row (LOOPER.route, { track = "0 golem:looper", root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	if SAMPLE.route then
		row (SAMPLE.route, { track = "0 golem:sample", root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	if BACKING_BUS and BACKING_BUS () then
		row (BACKING_BUS (), { track = "0 golem:backing", root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	for id, part in pairs (STD_PARTS and STD_PARTS () or {}) do   -- les parties d'un standard (lues par le banc)
		row (part.route, { track = "0 golem:std:" .. id, root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	if DRUMS_ROUTE and DRUMS_ROUTE () then
		row (DRUMS_ROUTE (), { track = (INPUT_METERS + 2) .. " golem:drums", root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	if CLICK_ROUTE and CLICK_ROUTE () then            -- le métronome : ni entrée ni route du rig, lu par le banc
		row (CLICK_ROUTE (), { track = (INPUT_METERS + 1) .. " golem:click", root = false, rig = false, vol_db = 0, mute = false, hw_sends = 0, sends = 0 })
	end
	local outs = physical (false)
	for i, name in ipairs (RIG.order) do
		local r = RIG.routes[name]
		local hw = 0
		for k = 0, r:output ():n_ports ():n_audio () - 1 do
			for _, o in ipairs (outs) do if r:output ():audio (k):connected_to (o) then hw = hw + 1 end end
		end
		row (r, { track = ssid_of (i) .. " " .. name, root = false, rig = true,
			vol_db = ARDOUR.DSP.accurate_coefficient_to_dB (r:gain_control ():get_value ()),
			mute = r:mute_control ():get_value () > 0.5, hw_sends = hw, sends = #((RIG.specs[name] or {}).from or {}) })
	end
	write_file (PEAKS, json_encode (rows))
end

local function dump ()
	local tracks = {}
	local candidates = {}
	for _, p in ipairs (physical (true)) do candidates[#candidates + 1] = p end
	for _, p in ipairs (physical (false)) do candidates[#candidates + 1] = p end
	for _, n in ipairs (RIG.order) do
		local r = RIG.routes[n]
		for k = 0, r:input ():n_ports ():n_total () - 1 do candidates[#candidates + 1] = r:input ():nth (k):name () end
		for k = 0, r:output ():n_ports ():n_audio () - 1 do candidates[#candidates + 1] = r:output ():audio (k):name () end
	end
	for i, name in ipairs (RIG.order) do
		local r = RIG.routes[name]
		local function conns (port)
			-- les liens réels, testés un à un contre chaque port connu (la carte et les routes du rig)
			local out = array ()
			for _, other in ipairs (candidates) do
				if port:connected_to (other) then out[#out + 1] = other end
			end
			return out
		end
		local conn_in, conn_out = array (), array ()
		local io_in, io_out = r:input (), r:output ()
		for k = 0, io_in:n_ports ():n_total () - 1 do
			for _, c in ipairs (conns (io_in:nth (k))) do conn_in[#conn_in + 1] = c end
		end
		for k = 0, io_out:n_ports ():n_audio () - 1 do
			for _, c in ipairs (conns (io_out:audio (k))) do conn_out[#conn_out + 1] = c end
		end
		local safety = false
		local i2 = 0
		while true do
			local pr = r:nth_plugin (i2)
			if pr:isnil () then break end
			local dn = pr:display_name ()
			if dn == "golem Safety" then safety = "lua"
			elseif dn:find ("Limiter", 1, true) and i2 == r_last_plugin (r) then safety = "gfx-limiter" end
			i2 = i2 + 1
		end
		tracks[#tracks + 1] = { ssid = ssid_of (i), name = name, safety = safety, mute = r:mute_control ():get_value () > 0.5,
			gain_db = ARDOUR.DSP.accurate_coefficient_to_dB (r:gain_control ():get_value ()),
			trim_db = ARDOUR.DSP.accurate_coefficient_to_dB (r:trim_control ():get_value ()),
			asleep = RIG.asleep[name] == true,
			mixer = (RIG.specs[name] or {}).mixer, level_db = (RIG.specs[name] or {}).gain_db,
			midi_mask = (function ()                       -- les canaux MIDI qu'une piste MIDI écoute (bit 0 = canal 1)
				local t = r:to_track ()
				if t:isnil () then return nil end
				local mt = t:to_midi_track ()
				if mt:isnil () then return nil end
				return mt:get_capture_channel_mask ()
			end) (),
			input = conn_in, output = conn_out }
	end
	local blocks = {}
	for id, b in pairs (RIG.blocks) do
		local vals = {}
		for _, p in ipairs (plugin_params (b.proc:to_insert ():plugin (0))) do
			vals[p.label] = ARDOUR.LuaAPI.get_processor_param (b.proc, p.i, true)
		end
		-- la clé d'un gate à clé : à quoi son sidechain est relié (les entrées de la carte)
		local key = array ()
		local pi = b.proc:to_insert ()
		if pi:has_sidechain () then
			local sc = pi:sidechain_input ()
			for c = 0, sc:n_ports ():n_audio () - 1 do
				for _, other in ipairs (physical (true)) do
					if sc:audio (c):connected_to (other) then key[#key + 1] = other end
				end
			end
		end
		blocks[id] = { ssid = b.ssid, fx = b.fx, enabled = pi:enabled (), active = b.proc:active (), params = vals, key = key,
			preset = b.preset_sig, midi = b.midi_sent and #b.midi_sent or nil, plugin = b.proc:display_name () }
	end
	write_file (DUMP, json_encode ({ preset = RIG.preset or "", tracks = tracks, blocks = blocks, at = os.time () }))
end

-- ── le réglage audio (lot A2.2) : le buffer change À CHAUD — moteur arrêté puis relancé, la session reste (26 ms
-- mesurés, REAPER se relance en ~10 s) ──────────────────────────────────────────────────────────────────────────
local function set_buffer (n)
	n = tonumber (n)
	if not n or n == Session:get_block_size () then return true end
	local t0 = now_s ()
	AudioEngine:stop (false)
	AudioEngine:set_buffer_size (n)
	local rc = AudioEngine:start (false)
	log (string.format ("buffer -> %d (moteur relancé en %.0f ms, rc %s, bloc %d)", n, (now_s () - t0) * 1000,
		tostring (rc), Session:get_block_size ()))
	return rc == 0
end

-- LA CARTE ROUVERTE (golem Health ▸ Fix « Reopen the sound card », et la récupération automatique du bridge quand le fil
-- audio s'est arrêté carte branchée) : le backend arrêté puis relancé, la session et ses liens gardés — le geste de
-- `set_buffer` sans changer la taille.
local function audio_reset ()
	local t0 = now_s ()
	AudioEngine:stop (false)
	local rc = AudioEngine:start (false)
	log (string.format ("carte rouverte en %.0f ms (rc %s, en marche : %s)", (now_s () - t0) * 1000, tostring (rc),
		tostring (AudioEngine:running ())))
	return rc == 0
end

-- LES CLAVIERS ROUVERTS (golem « Reopen MIDI devices ») : chaque lane MIDI du rig relit son appareil — fermé puis
-- rouvert, ses ports relus, la piste reliée. Le pédalier n'est pas ici : c'est le bridge qui le lit (ALSA, hors moteur).
local function midi_reinit ()
	local be, n = BACKEND_PTR, 0
	for name, spec in pairs (RIG.specs) do
		local r = RIG.routes[name]
		local dev = spec.kind == "midi" and spec.midi and spec.midi.device
		if r and dev and dev ~= "" and be then
			local w = dev:lower ()
			for d in be:enumerate_midi_devices ():iter () do
				if d.name:lower ():sub (1, #w) == w and not d.name:find ("%(O%)$") then
					if be:midi_device_enabled (d.name) then be:set_midi_device_enabled (d.name, false) end
					MIDI_PORTS[d.name] = nil
				end
			end
			r:input ():disconnect_all ()
			local ports = midi_device_ports (dev)
			for _, p in ipairs (ports) do
				local rc = r:input ():midi (0):connect (p)
				if rc ~= 0 then log ("  lien refusé " .. name .. " <- " .. tostring (p) .. " (" .. tostring (rc) .. ")") end
			end
			log ("  " .. name .. " : clavier « " .. dev .. " » rouvert (" .. #ports .. " port(s))")
			n = n + 1
		end
	end
	log ("MIDI rouvert : " .. n .. " lane(s)")
end

local function apply_audio_cfg ()
	local cfg = read_json (AUDIO_CFG)
	if cfg and cfg.buffer then set_buffer (cfg.buffer) end
end

-- ── l'inventaire (lot A2.4) : quels plugins de la table du bridge sont installés ICI — un bloc dont le plugin manque
-- est « plugin not installed » dans golem, comme sous REAPER ────────────────────────────────────────────────────────
local PLUGINS = ROOT .. "/presets/.engine-plugins.json"

local function inventory (want)
	local found, n = {}, 0
	for _, w in ipairs (want or {}) do
		local ok = false
		if w.lv2 then
			ok = not ARDOUR.LuaAPI.new_plugin_info (w.lv2, ARDOUR.PluginType.LV2):isnil ()
		elseif w.vst3 then
			ok = not ARDOUR.LuaAPI.new_plugin_info (w.vst3, ARDOUR.PluginType.VST3):isnil ()
		elseif w.lua then
			ok = not ARDOUR.LuaAPI.new_plugin_info (w.lua, ARDOUR.PluginType.Lua):isnil ()
		end
		found[w.type] = ok
		n = n + (ok and 1 or 0)
	end
	write_file (PLUGINS, json_encode ({ at = os.time (), found = found, n = n, total = #(want or {}) }))
	log ("  plugins : " .. n .. "/" .. #(want or {}) .. " de la table présents")
end

-- ── LA SONDE DE TROUS (golem tools/check-scene-gap.py, docs/ardour-plan.md A2) : GoleM FX Gapmeter (golem-fx), le pendant
-- de golem_gapmeter.jsfx. Une instance GÉNÉRATRICE (ton de test, il REMPLACE l'entrée) en queue de la piste d'entrée de
-- la lane, des DÉTECTRICES (slot = rang) en queue du merge et des branches ; chacune envoie ses mesures en OSC/UDP au
-- port de l'outil (127.0.0.1). Une piste stéréo reçoit UNE instance stéréo (Ardour en doublerait une mono : deux
-- instances au même slot). `on = false` les retire toutes ; une reconstruction du rig les emporte avec ses routes.
local GAPMETER = "476F6C654D46784761706D6574657231"
local GAPS = {}
local function gapmeter (c)
	for _, g in ipairs (GAPS) do pcall (function () g.route:remove_processor (g.proc, nil, true) end) end
	GAPS = {}
	if not c.on then log ("gapmeter : sondes retirées"); return end
	local AUDIO = ARDOUR.DataType ("audio")
	local function add (name, entries)
		local r = RIG.routes[name]
		if not r then log ("  ⚠ gapmeter : route absente « " .. tostring (name) .. " »"); return end
		local p = ARDOUR.LuaAPI.new_plugin (Session, GAPMETER, ARDOUR.PluginType.VST3, "")
		if p:isnil () then log ("  ⚠ gapmeter : GoleM FX Gapmeter n'est pas installé"); return end
		r:add_processor_by_index (p, -1, nil, true)
		if r:output ():n_ports ():n_audio () >= 2 then
			r:customize_plugin_insert (p, 1, ARDOUR.ChanCount (AUDIO, 2), ARDOUR.ChanCount (AUDIO, 0))
		end
		set_params ({ proc = p, spec = { id = "gapmeter" } }, entries)
		GAPS[#GAPS + 1] = { route = r, proc = p }
	end
	local port = tonumber (c.port) or 9071
	if c.tone and c.tone ~= "" then
		add (c.tone, { { label = "Port", value = port }, { label = "Slot", value = 7 }, { label = "Test Tone", value = 1 },
			{ label = "Tone Freq", value = tonumber (c.hz) or 196 }, { label = "Tone Level", value = tonumber (c.db) or -20 } })
	end
	for i, nm in ipairs (c.tracks or {}) do
		add (nm, { { label = "Port", value = port }, { label = "Slot", value = i - 1 },
			{ label = "Silence Threshold", value = tonumber ((c.thrs or {})[i]) or tonumber (c.thr) or -45 },
			{ label = "Min Gap", value = tonumber (c.min_ms) or 10 } })
	end
	log ("gapmeter : " .. #GAPS .. " sonde(s), port " .. port)
end

-- ── LE MÉTRONOME (golem « Click », bridge : action click ; sous REAPER : golem_click.lua + golem_click.jsfx) ───────────
-- Une route PERMANENTE « golem:click », créée au démarrage (jamais retirée par un rappel), sans entrée, un seul
-- processeur : « golem Click » (DSP Lua, golem/engine/scripts/golem_click.lua), qui compte et sonne transport arrêté.
-- Sa sortie va à la paire (ou au canal) de la carte que la commande nomme : "1-2", "3-4", "3". Un champ absent d'une
-- commande garde sa valeur. L'état est publié dans presets/.click.json, avec les témoins du fil audio (pas émis, tempo).
local CLICK_JSON = ROOT .. "/presets/.click.json"
local CLICK = { route = nil, proc = nil, linked = nil, bpm = 120,
	st = { on = false, level = -12, beats = 4, den = 4, div = 1, groups = nil, clock = false, sync = true, out = "1-2", song = false, anchor = -1 } }

local function groups_mask (groups, num)
	-- {3,2,2} -> les pulsations qui DÉMARRENT un groupe (0, 3, 5 -> 41) ; absent ou incohérent : le « 1 » seul
	if type (groups) ~= "table" or #groups == 0 then return 1 end
	local sum, mask, pos = 0, 0, 0
	for _, g in ipairs (groups) do
		g = math.floor (tonumber (g) or 0)
		if g < 1 then return 1 end
		if pos < 32 then mask = mask | (1 << pos) end
		pos, sum = pos + g, sum + g
	end
	if sum ~= num then return 1 end
	return mask
end

local function ensure_click ()
	local r = Session:route_by_name ("golem:click")
	if r:isnil () then
		-- une piste MIDI : le click reçoit les temps d'une grille (canal 16) du séquenceur des standards
		r = first (Session:new_midi_track (ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1),
			ARDOUR.ChanCount (ARDOUR.DataType ("audio"), 2), false, ARDOUR.PluginInfo (), nil, ARDOUR.RouteGroup (), 1,
			"golem:click", ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, false))
		r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	local p = r:nth_plugin (0)
	if p:isnil () then
		p = ARDOUR.LuaAPI.new_luaproc (Session, "golem Click")
		if p:isnil () then error ("golem Click introuvable (ARDOUR_DATA_PATH)") end
		CHAIN.pre (r, p)                               -- avant le fader : le trim du mixer agit sur le click
	end
	CLICK.route, CLICK.proc, CLICK.linked = r, p, nil
	SERVICE_ROUTES = math.max (SERVICE_ROUTES, 1)
end

local function click_apply ()
	if not CLICK.proc then return end
	local st = CLICK.st
	set_params ({ proc = CLICK.proc, spec = { id = "click" } }, {
		{ pid = "on", label = "On", value = st.on and 1 or 0 }, { pid = "level", label = "Level", value = st.level },
		{ pid = "beats", label = "Beats", value = st.beats }, { pid = "div", label = "Div", value = st.div },
		{ pid = "den", label = "Den", value = st.den }, { pid = "groups", label = "Groups", value = groups_mask (st.groups, st.beats) },
		{ pid = "clock", label = "Clock", value = st.clock and 1 or 0 }, { pid = "bpm", label = "BPM", value = CLICK.bpm },
		{ pid = "grid", label = "Grid", value = CLICK.grid and 1 or 0 } })
	if CLICK.linked ~= st.out then                   -- la sortie n'est refaite que si elle change
		local outs = physical (false)
		local a, b = tostring (st.out):match ("^(%d+)%-(%d+)$")
		a, b = tonumber (a or st.out), tonumber (b)
		CLICK.route:output ():disconnect_all ()
		if no_output () then log ("  click : sortie " .. tostring (st.out) .. " NON reliée (essai silencieux)")
		elseif a and outs[a] then
			CLICK.route:output ():audio (0):connect (outs[a])
			CLICK.route:output ():audio (1):connect (outs[b or a] or outs[a])
		else log ("  click : pas de sortie " .. tostring (st.out) .. " sur la carte") end
		CLICK.linked = st.out
	end
end
CLICK_TEMPO = function (bpm) CLICK.bpm = bpm; pcall (click_apply) end
CLICK_ROUTE = function () return CLICK.route end
SERVICE_MIX.click = CLICK_ROUTE

local function click_cmd (c)
	local st = CLICK.st
	if (c.op or "set") ~= "set" then log ("click : op inconnue " .. tostring (c.op)); return end
	local function num (v, cur, lo, hi) v = tonumber (v); if not v then return cur end; return math.max (lo, math.min (hi, v)) end
	if c.on ~= nil then st.on = c.on == true end
	if c.sync ~= nil then st.sync = c.sync == true end
	if c.clock ~= nil then st.clock = c.clock == true end
	if c.song ~= nil then st.song = c.song == true end
	st.level = num (c.level, st.level, -60, 6)
	st.beats = math.floor (num (c.beats, st.beats, 1, 32) + 0.5)
	st.div = math.floor (num (c.div, st.div, 1, 4) + 0.5)
	st.den = math.floor (num (c.den, st.den, 1, 16) + 0.5)
	st.anchor = num (c.anchor, st.anchor, -1, 100000)
	if type (c.groups) == "table" then st.groups = #c.groups > 0 and c.groups or nil end
	if type (c.out) == "string" and c.out ~= "" then st.out = c.out end
	click_apply ()
	log (string.format ("click %s : %.1f dB, %d/%d, div %d, accents 0x%X, out %s", st.on and "ON" or "OFF", st.level, st.beats,
		st.den, st.div, groups_mask (st.groups, st.beats), st.out))
end

local function click_publish ()
	local st, ticks, tempo, present = CLICK.st, 0, 0, false
	if CLICK.proc then
		local lp = CLICK.proc:to_insert ():plugin (0):to_luaproc ()
		if not lp:isnil () then
			present = true
			ticks, tempo = lp:shmem ():atomic_get_int (0), lp:shmem ():atomic_get_int (1) / 100
		end
	end
	write_file (CLICK_JSON, json_encode ({ present = present, on = st.on, level = st.level, beats = st.beats, den = st.den, div = st.div,
		clock = st.clock, sync = st.sync, out = st.out, ticks = ticks, tempo = tempo }))
end

-- ── LA BOÎTE À RYTHMES (golem « Drum machine », bridge : action drums ; sous REAPER : golem_drums.lua + drumseq) ───────
-- Une piste MIDI PERMANENTE « golem:drums », créée au démarrage après le métronome : [golem Drumseq] puis le plugin du
-- KIT, sortie 1/2. Le bridge joint à chaque `play` la banque déjà dépliée (bridge/engine/drum_bank.py : les grooves puis
-- les fills, en événements) et le plugin du kit ; le veilleur écrit la banque dans la mémoire partagée du séquenceur et
-- pose la commande (op, slot, puis le nonce EN DERNIER). Un seul séquenceur : le dernier `play` prend la main.
-- État publié : presets/.drums.json {present, blocks: {<bloc>: {playing, idx, mode, step}}}.
local DRUMS_JSON = ROOT .. "/presets/.drums.json"
local DRUMS = { route = nil, seq = nil, kit = nil, kit_sig = nil, block = nil, patterns = 0, bpm = 120, idx = 0 }
local DS_SLOT_BASE, DS_SLOT_STRIDE, DS_SLOTS = 256, 8192, 14

local function drums_shm ()
	if not DRUMS.seq then return nil end
	local lp = DRUMS.seq:to_insert ():plugin (0):to_luaproc ()
	if lp:isnil () then return nil end
	return lp:shmem ()
end

local function ensure_drums ()
	local r = Session:route_by_name ("golem:drums")
	if r:isnil () then
		r = first (Session:new_midi_track (ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1),
			ARDOUR.ChanCount (ARDOUR.DataType ("audio"), 2), false, ARDOUR.PluginInfo (), nil, ARDOUR.RouteGroup (), 1,
			"golem:drums", ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, false))
		r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	local i = 0                                      -- une session rouverte : on repart d'une piste nue
	while true do
		local p = r:nth_plugin (0)
		if p:isnil () or i > 8 then break end
		r:remove_processor (p, nil, true)
		i = i + 1
	end
	local seq = ARDOUR.LuaAPI.new_luaproc (Session, "golem Drumseq")
	if seq:isnil () then error ("golem Drumseq introuvable (ARDOUR_DATA_PATH)") end
	CHAIN.pre (r, seq)
	local outs = physical (false)
	if not no_output () and outs[1] then
		r:output ():audio (0):connect (outs[1])
		r:output ():audio (1):connect (outs[2] or outs[1])
	end
	DRUMS.route, DRUMS.seq, DRUMS.kit, DRUMS.kit_sig = r, seq, nil, nil
	SERVICE_ROUTES = 2
end

local function drums_bpm ()
	if DRUMS.seq then set_params ({ proc = DRUMS.seq, spec = { id = "drums" } }, { { pid = "bpm", label = "BPM", value = DRUMS.bpm } }) end
end
DRUMS_TEMPO = function (bpm) DRUMS.bpm = bpm; pcall (drums_bpm) end
DRUMS_ROUTE = function () return DRUMS.route end
SERVICE_MIX.drums = DRUMS_ROUTE
SERVICE_MIX.backing = function () return BACKING_BUS and BACKING_BUS () end
SERVICE_MIX.sample = function () return SAMPLE.route end
SERVICE_MIX.looper = function () return LOOPER.loops and LOOPER.route or nil end   -- seulement quand le preset a un looper

local function drums_op (op, slot, ret)
	local shm = drums_shm ()
	if not shm then return end
	local a = shm:to_int (0):array ()
	a[2], a[3], a[7] = op, slot or 0, ret or 0           -- [6] le retour d'un fill (slot + 1, 0 = le groove courant)
	shm:atomic_set_int (0, shm:atomic_get_int (0) + 1)   -- le nonce EN DERNIER
end

-- le plugin du kit, refait seulement quand le kit change (un kit qui charge ses samples ne se recharge pas à chaque play)
local function drums_kit (kp)
	local sig, keys = tostring (kp and kp.lv2 or ""), {}
	for prop in pairs (kp and kp.files or {}) do keys[#keys + 1] = prop end
	table.sort (keys)
	for _, prop in ipairs (keys) do sig = sig .. "|" .. prop .. "=" .. tostring (kp.files[prop]) end
	if sig == DRUMS.kit_sig and DRUMS.kit then return true end
	if DRUMS.kit then
		GRAVE.keep (DRUMS.kit)                          -- un kit SFZ est un sfizz : pas détruit pendant qu'il charge
		DRUMS.route:remove_processor (DRUMS.kit, nil, true)
		DRUMS.kit = nil
		collectgarbage ()
	end
	DRUMS.kit_sig = nil
	if not kp or not kp.lv2 then return false end
	local p = ARDOUR.LuaAPI.new_plugin (Session, kp.lv2, ARDOUR.PluginType.LV2, "")
	if p:isnil () then log ("  boîte à rythmes : plugin de kit absent " .. tostring (kp.lv2)); return false end
	CHAIN.pre (DRUMS.route, p)                       -- avant le fader : le trim du mixer agit sur le kit
	for prop, path in pairs (kp.files or {}) do ARDOUR.LuaAPI.set_plugin_insert_property (p:to_insert (), prop, path) end
	DRUMS.kit, DRUMS.kit_sig = p, sig
	return true
end

local function drums_bank (bank)
	local shm = drums_shm ()
	if not shm or type (bank) ~= "table" then return 0 end
	local a = shm:to_int (0):array ()
	a[4] = math.floor (tonumber (bank.ppq) or 960)
	local n = 0
	for s, slot in ipairs (bank.slots or {}) do
		if s > DS_SLOTS then break end
		local ba = DS_SLOT_BASE + (s - 1) * DS_SLOT_STRIDE
		local evs = slot.events or {}
		local nev = math.min (#evs, (DS_SLOT_STRIDE - 8) // 4)
		a[ba + 1], a[ba + 2], a[ba + 3] = nev, math.floor (slot.len or 3840), math.floor (slot.bar or 3840)
		for k = 1, nev do
			local e, ea = evs[k], ba + 8 + (k - 1) * 4
			a[ea + 1], a[ea + 2], a[ea + 3], a[ea + 4] = math.floor (e[1]), math.floor (e[2]), math.floor (e[3]), 0
		end
		n = n + 1
	end
	return n
end

local function drums_cmd (c)
	if not DRUMS.route then error ("boîte à rythmes : pas de piste") end
	local op = c.op or ""
	if op == "play" then
		DRUMS.block = c.block or "drums"
		if c.kit_error then log ("  boîte à rythmes : " .. tostring (c.kit_error)) end
		local kit_ok = drums_kit (c.kit_plugin)
		drums_op (0, 0)                              -- silence pendant qu'on réécrit la banque
		local n = drums_bank (c.bank)
		DRUMS.patterns = math.floor (tonumber ((c.bank or {}).patterns) or n)
		drums_bpm ()
		local seq = type (c.sequence) == "table" and c.sequence or {}
		local shm = drums_shm ()
		local a = shm:to_int (0):array ()
		if #seq > 0 then
			local steps = math.min (#seq, 64)
			a[17], a[18] = steps, (c.seq_mode == "once") and 1 or 0
			for k = 1, steps do
				a[19 + (k - 1) * 2], a[20 + (k - 1) * 2] = math.floor (tonumber (seq[k].i) or 0), math.floor (tonumber (seq[k].times) or 0)
			end
			drums_op (4, 0)
		else
			a[17] = 0
			DRUMS.idx = math.max (0, math.min (math.max (0, DRUMS.patterns - 1), math.floor (tonumber (c.idx) or 0)))
			drums_op (1, DRUMS.idx)
		end
		log (string.format ("boîte à rythmes : play %s — %d groove(s) dont %d de base, kit %s%s", tostring (DRUMS.block), n,
			DRUMS.patterns, kit_ok and "posé" or "ABSENT", #seq > 0 and (", morceau de " .. #seq .. " étape(s)") or ""))
	elseif op == "variation" then
		DRUMS.idx = math.max (0, math.min (math.max (0, DRUMS.patterns - 1), math.floor (tonumber (c.idx) or 0)))
		drums_op (2, DRUMS.idx)
	elseif op == "fill" then
		-- `then_idx` (2026-11-20) : le fill MÈNE à cette variation — le séquenceur y repart au lieu du groove courant
		local nxt = tonumber (c.then_idx)
		if nxt then
			nxt = math.max (0, math.min (math.max (0, DRUMS.patterns - 1), math.floor (nxt)))
			DRUMS.idx = nxt
		end
		drums_op (3, DRUMS.patterns + math.floor (tonumber (c.fill_idx) or 0), nxt and nxt + 1 or 0)
	elseif op == "load" then                         -- le kit posé, rien ne joue (le rendu d'un bloc, d'un kit)
		if c.kit_error then log ("  boîte à rythmes : " .. tostring (c.kit_error)) end
		drums_kit (c.kit_plugin)
		log ("boîte à rythmes : kit posé, rien ne joue")
	elseif op == "stop" then
		drums_op (0, 0)
	else
		log ("boîte à rythmes : op inconnue " .. tostring (op))
	end
end

local function drums_publish ()
	local shm = drums_shm ()
	local blocks = {}
	if shm and DRUMS.block then
		local slot = shm:atomic_get_int (9)
		blocks[DRUMS.block] = { playing = shm:atomic_get_int (8) == 1,
			idx = (slot >= 0 and slot < DRUMS.patterns) and slot or DRUMS.idx,
			mode = shm:atomic_get_int (10) == 1 and "fill" or "groove", step = shm:atomic_get_int (13) }
	end
	local s = json_encode ({ present = shm ~= nil, blocks = blocks })
	if next (blocks) == nil then s = s:gsub ('"blocks":%[%]', '"blocks":{}') end   -- une table vide est un objet, pas une liste
	write_file (DRUMS_JSON, s)
end

-- ── LES STANDARDS (golem « Standard », bridge : action standard ; sous REAPER : golem_chordseq.lua + .jsfx) ───────────
-- Le bridge rend la grille (bridge/standards.py) dans un fichier texte (presets/.standard.seq) ; ici on la JOUE.
-- CINQ pistes PERMANENTES, créées au démarrage après la boîte à rythmes :
--   golem:std          le séquenceur seul (« golem Chordseq »), dont la sortie MIDI nourrit les quatre autres ET le click
--   golem:std:keys     canal 1  : sfizz + le piano (Salamander)       golem:std:bass    canal 2  : un synthé (ACE Reasonable Synth)
--   golem:std:drums    canal 10 : le kit AVL de la commande           golem:std:guitar  canal 4  : sfizz + la pompe (Shinyguitar)
-- Une seule horloge : les parties ne peuvent pas se décaler. Les instruments ne sont posés qu'à la première grille qui
-- les demande (le piano charge un giga de samples), et restent. Une partie non demandée est MUTÉE, pas laissée sur son
-- dernier accord. Le click d'une grille est JOUÉ par elle (lane 3 -> canal 16 -> golem Click en mode Grid).
local STD_JSON = ROOT .. "/presets/.standard.json"
local STD_SEQ = ROOT .. "/presets/.standard.seq"
local STD = { root = nil, seq = nil, parts = {}, bpm = 120, slug = nil, nev = 0, bars = 0, kit = nil }
local STD_DEF = { { id = "keys", ch = 1, file = "Standard-Keys" }, { id = "bass", ch = 2, file = "Standard-Bass" },
	{ id = "drums", ch = 10, file = "Standard-Drums" }, { id = "guitar", ch = 4, file = "Standard-Guitar" } }
local SFIZZ_URI, SFIZZ_FILE = "http://sfztools.github.io/sfizz", "http://sfztools.github.io/sfizz:sfzfile"
local SYNTH_URI = "https://community.ardour.org/node/7596"
local PIANO_SFZ = ROOT .. "/library/sfz/SalamanderGrandPiano-SFZ+FLAC-V3+20200602/SalamanderGrandPiano-V3+20200602.sfz"
local GUITAR_SFZ = ROOT .. "/library/sfz/golem-pompe.sfz"
local AVL = { ["black-pearl"] = "http://gareus.org/oss/lv2/avldrums#BlackPearl", ["red-zeppelin"] = "http://gareus.org/oss/lv2/avldrums#RedZeppelin",
	["blonde-bop"] = "http://gareus.org/oss/lv2/avldrums#BlondeBop" }

local function midi_track (name, midi_out)
	local r = Session:route_by_name (name)
	if r:isnil () then
		local out = midi_out and ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1) or ARDOUR.ChanCount (ARDOUR.DataType ("audio"), 2)
		r = first (Session:new_midi_track (ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1), out, false, ARDOUR.PluginInfo (), nil,
			ARDOUR.RouteGroup (), 1, name, ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, false))
		r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorInput, NG)
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	local i = 0
	while true do                                   -- une session rouverte : on repart d'une piste nue
		local p = r:nth_plugin (0)
		if p:isnil () or i > 8 then break end
		r:remove_processor (p, nil, true)
		i = i + 1
	end
	return r
end

local function std_shm ()
	if not STD.seq then return nil end
	local lp = STD.seq:to_insert ():plugin (0):to_luaproc ()
	if lp:isnil () then return nil end
	return lp:shmem ()
end

local function ensure_std ()
	local root = midi_track ("golem:std", true)
	local seq = ARDOUR.LuaAPI.new_luaproc (Session, "golem Chordseq")
	if seq:isnil () then error ("golem Chordseq introuvable (ARDOUR_DATA_PATH)") end
	CHAIN.pre (root, seq)
	STD.root, STD.seq, STD.parts = root, seq, {}
	local outs = physical (false)
	local src = root:output ():midi (0):name ()
	for _, d in ipairs (STD_DEF) do
		local r = midi_track ("golem:std:" .. d.id, false)
		r:to_track ():to_midi_track ():set_capture_channel_mode (ARDOUR.ChannelMode.FilterChannels, 1 << (d.ch - 1))
		local rc = r:input ():midi (0):connect (src)
		if rc ~= 0 then log ("  standard : lien MIDI refusé vers " .. d.id .. " (" .. tostring (rc) .. ")") end
		if not no_output () and outs[1] then
			r:output ():audio (0):connect (outs[1])
			r:output ():audio (1):connect (outs[2] or outs[1])
		end
		r:mute_control ():set_value (1, NG)
		STD.parts[d.id] = { route = r, proc = nil, sig = nil, file = d.file, on = false }
	end
	if CLICK_ROUTE and CLICK_ROUTE () then            -- le click reçoit les temps de la grille
		CLICK_ROUTE ():input ():midi (0):connect (src)
	end
	SERVICE_ROUTES = 2 + 1 + #STD_DEF
end
STD_PARTS = function () return STD.parts end
STD_TEMPO = function (bpm)
	STD.bpm = bpm
	if STD.seq then pcall (set_params, { proc = STD.seq, spec = { id = "standard" } }, { { pid = "bpm", label = "BPM", value = bpm } }) end
end

-- l'instrument d'une partie, posé à la demande, refait seulement s'il change (le kit)
local function std_instrument (id, uri, files)
	local part = STD.parts[id]
	local sig = uri
	for prop, path in pairs (files or {}) do sig = sig .. "|" .. prop .. "=" .. path end
	if part.proc and part.sig == sig then return true end
	if part.proc then GRAVE.keep (part.proc); part.route:remove_processor (part.proc, nil, true); part.proc = nil; collectgarbage () end
	local p = ARDOUR.LuaAPI.new_plugin (Session, uri, ARDOUR.PluginType.LV2, "")
	if p:isnil () then log ("  standard : instrument absent pour " .. id .. " (" .. uri .. ")"); return false end
	CHAIN.pre (part.route, p)
	for prop, path in pairs (files or {}) do ARDOUR.LuaAPI.set_plugin_insert_property (p:to_insert (), prop, path) end
	part.proc, part.sig = p, sig
	log ("  standard : " .. id .. " posé")
	return true
end

local function std_parts (c, play)
	local want = { keys = c.keys ~= false, bass = c.bass ~= false, drums = c.drums == true, guitar = c.guitar == true }
	-- les fichiers des instruments : ceux que le bridge nomme (`instruments`), sinon ceux du dépôt où tourne ce veilleur
	local inst = type (c.instruments) == "table" and c.instruments or {}
	local piano, guitar = inst.piano or PIANO_SFZ, inst.guitar or GUITAR_SFZ
	-- un .sfz dont les fichiers MANQUENT n'est jamais donné à sfizz (Shinyguitar et le piano sont des téléchargements
	-- facultatifs de l'installateur) : son échec de chargement abîme le tas — 0xC0000374, le moteur tué juste après
	-- « [sfizz] Loading failed » (banc Windows, 2026-11-20). golem_chordseq.lua (REAPER) fait déjà ce garde
	local function exists (p) local f = io.open (p, "r"); if f then f:close () return true end return false end
	if want.keys and not exists (piano) then
		log ("⚠ standard : piano absent (" .. piano .. ") — partie non posée"); want.keys = false
	end
	-- la pompe INCLUT Shinyguitar, rangé à côté d'elle (le bridge donne toujours le chemin de golem-pompe.sfz)
	local shiny = (guitar:match ("^(.*)[/\\]") or ".") .. "/Shinyguitar/Programs/acoustic_two.sfz"
	if want.guitar and not exists (shiny) then
		log ("⚠ standard : Shinyguitar absent (" .. shiny .. ") — pompe non posée"); want.guitar = false
	end
	if want.keys then std_instrument ("keys", SFIZZ_URI, { [SFIZZ_FILE] = piano }) end
	if want.bass then
		std_instrument ("bass", SYNTH_URI, nil)
		-- la basse sous le piano (golem_chordseq.lua : -10 dB en combo, -4 dB quand elle n'accompagne que la pompe)
		STD.parts.bass.gain = (want.guitar and not want.keys) and -4 or -10
	end
	if want.drums then std_instrument ("drums", AVL[c.kit or "black-pearl"] or AVL["black-pearl"], nil) end
	if want.guitar then
		local f = io.open (guitar, "r")
		if f then f:close ()
		else
			pcall (write_file, guitar, table.concat ({ "// golem — la pompe (écrit par golem ; ne pas éditer à la main)", "<control>",
				"default_path=Shinyguitar/Samples/", "set_cc100=127", "set_cc107=38", "set_cc108=70",
				'#include "Shinyguitar/Programs/acoustic_two.sfz"', "" }, "\n"))
		end
		std_instrument ("guitar", SFIZZ_URI, { [SFIZZ_FILE] = guitar })
	end
	if play then
		-- une partie non demandée se TAIT, et son instrument DORT (il ne calcule rien) ; demandée, il est réveillé
		for id, part in pairs (STD.parts) do
			part.on = want[id] == true
			if part.proc then
				if part.on then part.proc:activate () else part.proc:deactivate () end
			end
		end
		service_mix ()
	end
end

local function std_load_seq (path)
	local body = read_file (path)
	if not body then log ("⚠ standard : séquence introuvable " .. tostring (path)); return nil end
	local len = tonumber (body:match ("\nlen%s+(%d+)")) or tonumber (body:match ("^len%s+(%d+)"))
	local bar = tonumber (body:match ("\nbar%s+(%d+)"))
	local cin = tonumber (body:match ("\ncin%s+(%d+)")) or 0
	if not (len and bar) then log ("⚠ standard : séquence sans en-tête len/bar"); return nil end
	local shm = std_shm ()
	local a = shm:to_int (0):array ()
	local n, max = 0, 16384
	for tk, note, vel, lane in body:gmatch ("\n(%d+) (%d+) (%d+) (%d+)") do
		if n >= max then log ("⚠ standard : séquence TRONQUÉE à " .. max .. " événements"); break end
		local ea = 64 + n * 4
		a[ea + 1], a[ea + 2], a[ea + 3], a[ea + 4] = tonumber (tk), tonumber (note), tonumber (vel), tonumber (lane)
		n = n + 1
	end
	a[4], a[17], a[18], a[19], a[20], a[21] = 960, n, len, bar, 1, cin
	return { nev = n, len = len, bar = bar }
end

local function std_op (op, loop)
	local shm = std_shm ()
	if not shm then return end
	local a = shm:to_int (0):array ()
	a[2], a[3] = op, loop and 1 or 0
	shm:atomic_set_int (0, shm:atomic_get_int (0) + 1)
end

local function std_cmd (c)
	if not STD.seq then error ("standard : pas de piste") end
	local op = c.op or ""
	if op == "play" then
		std_op (0, false)                             -- silence pendant qu'on recharge la grille
		local info = std_load_seq (c.file or STD_SEQ)
		if not info then return end
		std_parts (c, true)
		-- ARMÉE (la prise d'un standard) : au tempo de la prise, elle attend le transport et part avec lui
		if c.arm and tonumber (c.bpm) and tonumber (c.bpm) >= 20 and tonumber (c.bpm) <= 400 then
			STD.prev_bpm = STD.prev_bpm or Temporal.TempoMap.read ():quarters_per_minute_at (Temporal.timepos_t (0))
			set_tempo (tonumber (c.bpm))
		end
		STD_TEMPO (STD.bpm)
		CLICK.grid = true                             -- le click ne compte plus : la grille le joue
		click_apply ()
		if c.arm then                                 -- ce que le départ armé doit rattraper : la latence de chaque partie
			local d = {}
			for id, part in pairs (STD.parts) do
				if part.on then d[#d + 1] = id .. " " .. part.route:signal_latency () .. "/" .. part.route:playback_latency (false) end
			end
			log ("  standard : latences (signal/lecture, échantillons) " .. table.concat (d, ", ") .. " · preroll " .. Session:worst_latency_preroll ()
				.. " · sortie " .. Session:worst_output_latency ())
		end
		std_op (c.arm and 2 or 1, c.loop ~= false)
		STD.slug, STD.nev, STD.bars = c.standard, info.nev, info.len // info.bar
		log (string.format ("standard : play %s — %d événements, %d mesures%s%s", tostring (c.standard), info.nev, STD.bars,
			c.loop ~= false and " (boucle)" or "", c.arm and " — ARMÉE : elle partira avec le transport" or ""))
	elseif op == "load" then
		std_parts (c, false)
		log ("standard : instruments posés, rien ne joue")
	elseif op == "stop" then
		std_op (0, false)
		CLICK.grid = false
		click_apply ()
		if STD.prev_bpm then set_tempo (STD.prev_bpm); STD.prev_bpm = nil end   -- le tempo du preset revient après la prise
		log ("standard : stop")
	else
		log ("standard : op inconnue " .. tostring (op))
	end
end

local function std_publish ()
	local shm = std_shm ()
	local playing = shm ~= nil and shm:atomic_get_int (8) == 1
	if shm and CLICK.grid and not playing and STD.was_playing then   -- une grille jouée une fois s'est finie seule
		CLICK.grid = false
		pcall (click_apply)
	end
	STD.was_playing = playing
	local armed = shm ~= nil and shm:atomic_get_int (12) == 1
	local rate = Session:nominal_sample_rate ()
	write_file (STD_JSON, json_encode ({ present = shm ~= nil, playing = playing, armed = armed, standard = STD.slug or false,
		t0 = shm and shm:atomic_get_int (14) >= 0 and shm:atomic_get_int (14) / rate or -1, first = shm and shm:atomic_get_int (15) or -1,
		bar = shm and shm:atomic_get_int (9) or -1, bars = STD.bars, events = STD.nev, hb = shm and shm:atomic_get_int (11) or 0,
		tempo = STD.bpm, beat = shm and shm:atomic_get_int (10) or -1 }))
end

-- ── L'ACCORDEUR (golem « Tuner », bridge : actions tuner et extstate tuner_in ; sous REAPER : golem_tuner.lua) ─────────
-- Il écoute le DI de l'entrée que le bridge nomme (`tuner_in`, défaut 1) : son processeur dort sur la piste golem:inN
-- et n'est réveillé que le temps d'accorder. La lecture est publiée dans presets/.tuner.json, dix fois par seconde au
-- plus — sauf le passage note <-> silence, publié tout de suite.
local TUNER_JSON = ROOT .. "/presets/.tuner.json"
local TUNER = { on = false, input = 1, seq = -1, at = 0, active = nil, off_written = false }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

local function tuner_arm ()
	for n, p in pairs (TUNERS) do
		if TUNER.on and n == TUNER.input then p:activate () else p:deactivate () end
	end
	if TUNER.on and not TUNERS[TUNER.input] then log ("accordeur : pas d'entrée " .. tostring (TUNER.input) .. " à écouter") end
end

local function tuner_cmd (c)
	TUNER.on = c.on == true
	TUNER.seq, TUNER.active = -1, nil
	tuner_arm ()
	log ("accordeur " .. (TUNER.on and ("ARMÉ sur l'entrée " .. TUNER.input) or "coupé"))
end

local function tuner_publish ()
	if not TUNER.on then
		if not TUNER.off_written then
			write_file (TUNER_JSON, json_encode ({ on = false, active = false, seq = 0 }))
			TUNER.off_written = true
		end
		return
	end
	TUNER.off_written = false
	local p = TUNERS[TUNER.input]
	if not p then return end
	local lp = p:to_insert ():plugin (0):to_luaproc ()
	if lp:isnil () then return end
	local shm = lp:shmem ()
	local seq, conf = shm:atomic_get_int (3), shm:atomic_get_int (2) / 1000
	local active = conf > 0
	if seq == TUNER.seq or (active == TUNER.active and now_s () - TUNER.at < 0.1) then return end
	TUNER.seq, TUNER.at, TUNER.active = seq, now_s (), active
	if active then
		local midi = shm:atomic_get_int (1) / 1000
		local m = math.floor (midi + 0.5)
		write_file (TUNER_JSON, json_encode ({ on = true, active = true, seq = seq, note = NOTE_NAMES[(m % 12) + 1],
			octave = m // 12 - 1, midi = m, cents = 100 * (midi - m), freq = shm:atomic_get_int (0) / 1000, conf = conf }))
	else
		write_file (TUNER_JSON, json_encode ({ on = true, active = false, seq = seq }))
	end
end

-- ── LA BACKING (golem « Backing track », bridge : action backing + transport ; sous REAPER : golem_backing.lua) ───────
-- Les stems d'une chanson (golem.fm : vocals, drums, bass, guitar, piano, other — et, pour un original, un stem par
-- instrument) joués par le TRANSPORT : un bus permanent « golem:backing » qui sort sur 1/2, une piste par stem qui le
-- nourrit. Un stem est POSÉ, pas importé (LuaAPI.place_audio_file, ajoutée au fork : le fichier reste où il est, mp3
-- compris, rééchantillonné à la volée) — une chanson se charge en quelques dizaines de millisecondes par stem.
-- Le transport (lecture, pause, arrêt, retour au début) est piloté par le bridge en OSC ; ici : charger, mixer, se
-- placer, boucler, sauter d'une section à l'autre, et dire où on en est (presets/.backing.json).
local BACKING_JSON = ROOT .. "/presets/.backing.json"
local SIX = { "vocals", "drums", "bass", "guitar", "piano", "other" }
local BACKING = { bus = nil, stems = {}, order = {}, slug = nil, len = 0, mix = {}, ends = 0, loop = nil,
	jump_lift = false, jump_fwd = nil, was_rolling = false, last_pos = nil, last_fp = nil, last_pub = 0, wrote_off = false }
local function rate () return Session:nominal_sample_rate () end
local function pos_s () return Session:transport_sample () / rate () end

local function backing_stem (name)
	local st = BACKING.stems[name]
	if st then return st end
	local r = Session:route_by_name ("golem:backing:" .. name)
	if r:isnil () then
		r = first (Session:new_audio_track (2, 2, ARDOUR.RouteGroup (), 1, "golem:backing:" .. name, ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true))
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	for ch = 0, 1 do r:output ():audio (ch):connect (BACKING.bus:input ():audio (ch):name ()) end
	st = { route = r }
	BACKING.stems[name] = st
	BACKING.order[#BACKING.order + 1] = name
	return st
end

local function ensure_backing ()
	local bus = Session:route_by_name ("golem:backing")
	if bus:isnil () then
		bus = first (Session:new_audio_route (2, 2, ARDOUR.RouteGroup (), 1, "golem:backing", ARDOUR.PresentationInfo.Flag.AudioBus,
			ARDOUR.PresentationInfo.max_order))
	end
	bus:input ():disconnect_all ()
	bus:output ():disconnect_all ()
	local outs = physical (false)
	if not no_output () and outs[1] then
		bus:output ():audio (0):connect (outs[1])
		bus:output ():audio (1):connect (outs[2] or outs[1])
	end
	BACKING.bus, BACKING.stems, BACKING.order = bus, {}, {}
	for _, name in ipairs (SIX) do backing_stem (name) end
	ARDOUR.config ():set_loop_is_mode (true)        -- une boucle armée à l'arrêt ne lance pas le transport
	SERVICE_ROUTES = SERVICE_ROUTES + 1 + #SIX
end
BACKING_BUS = function () return BACKING.slug and BACKING.bus or nil end

local function stem_clear (st)
	local pl = st.route:to_track ():playlist ()
	local regs = {}
	for reg in pl:region_list ():iter () do regs[#regs + 1] = reg end
	for _, reg in ipairs (regs) do pl:remove_region (reg) end
end

local function backing_mix (name, mute, vol)
	local st = BACKING.stems[name]
	if not st then return end
	local m = BACKING.mix[name] or { mute = 0, vol = 1 }
	if mute ~= nil then m.mute = (mute == 1 or mute == true) and 1 or 0 end
	if vol ~= nil then m.vol = math.max (0, math.min (2, tonumber (vol) or 1)) end
	BACKING.mix[name] = m
	st.route:mute_control ():set_value (m.mute, NG)
	st.route:gain_control ():set_value (m.vol, NG)
end

local function loop_loc ()
	local loc = Session:locations ():auto_loop_location ()
	if not loc then
		loc = Session:locations ():add_range (Temporal.timepos_t (0), Temporal.timepos_t (rate ()))
		Session:set_auto_loop_location (loc)
		loc = Session:locations ():auto_loop_location ()
	end
	return loc
end

local function loop_set (a, b)                     -- nil : boucle levée (le transport continue s'il tournait)
	if a and b and b > a then
		loop_loc ():set (Temporal.timepos_t (math.floor (a * rate ())), Temporal.timepos_t (math.floor (b * rate ())))
		if not Session:get_play_loop () then Session:request_play_loop (true, true) end
	elseif Session:get_play_loop () then
		Session:request_play_loop (false, true)
	end
end

local function locate (sec)
	Session:request_locate (math.floor (math.max (0, sec) * rate ()), false, ARDOUR.LocateTransportDisposition.RollIfAppropriate,
		ARDOUR.TransportRequestSource.TRS_UI)
end

local function clear_jump (why)
	if BACKING.jump_lift then loop_set (nil) end
	if BACKING.jump_lift or BACKING.jump_fwd then log ("backing : saut armé levé (" .. why .. ")") end
	BACKING.jump_lift, BACKING.jump_fwd = false, nil
end

local function backing_load (c)
	if not c.slug or not (c.dir or c.files) then log ("backing : load sans slug ni dossier"); return end
	clear_jump ("chargement")
	local files = type (c.files) == "table" and c.files or nil
	if files then for name in pairs (files) do backing_stem (name) end end   -- un stem hors des six : sa piste, à la demande
	BACKING.len = 0
	local n = 0
	for _, name in ipairs (BACKING.order) do
		local st = BACKING.stems[name]
		stem_clear (st)
		local six = false
		for _, x in ipairs (SIX) do if x == name then six = true end end
		local path
		if files then path = files[name] elseif six then path = c.dir .. "/" .. name .. ".mp3" end
		local placed = false
		if path then
			local f = io.open (path, "rb")
			if f then
				f:close ()
				local reg = ARDOUR.LuaAPI.place_audio_file (Session, st.route, path, 0)
				if not reg:isnil () then
					placed = true
					n = n + 1
					BACKING.len = math.max (BACKING.len, reg:length ():samples () / rate ())
				else log ("  backing : stem illisible " .. path) end
			end
		end
		-- l'état par défaut AVANT le mix de la commande (elle ne nomme que les stems touchés) : jouant à 0 dB ; un stem
		-- hors des six sans fichier, muet
		BACKING.mix[name] = nil
		backing_mix (name, (placed or six) and 0 or 1, 1)
	end
	for name, m in pairs (type (c.mix) == "table" and c.mix or {}) do
		if type (m) == "table" then backing_mix (name, m.mute, m.vol) end
	end
	BACKING.bus:mute_control ():set_value (0, NG)
	loop_set (nil)
	BACKING.loop = nil
	locate (0)
	BACKING.slug = (n > 0) and c.slug or nil
	BACKING.last_fp = nil
	service_mix ()
	log (string.format ("backing : load %s — %d stem(s), %.1f s%s", tostring (c.slug), n, BACKING.len,
		c.ticks and " (le click du morceau n'est pas encore joué ici)" or ""))
end

local function backing_cmd (c)
	if not BACKING.bus then error ("backing : pas de bus") end
	local op = c.op or ""
	if op == "load" then backing_load (c)
	elseif op == "unload" then
		clear_jump ("déchargement")
		if Session:transport_rolling () then Session:request_stop (false, false, ARDOUR.TransportRequestSource.TRS_UI) end
		for _, name in ipairs (BACKING.order) do stem_clear (BACKING.stems[name]) end
		BACKING.bus:mute_control ():set_value (1, NG)
		loop_set (nil)
		BACKING.slug, BACKING.len, BACKING.loop = nil, 0, nil
		log ("backing : unload")
	elseif op == "seek" then
		clear_jump ("seek")
		locate (tonumber (c.pos) or 0)
	elseif op == "jump" then
		-- LE SAUT DE SECTION (page Répète) : vers l'arrière, une boucle [to, at] levée au premier rebouclage (le saut tombe
		-- à l'échantillon) ; vers l'avant, un seek quand le transport atteint `at`
		local at, to = tonumber (c.at), tonumber (c.to)
		if at and to then
			local p0 = Session:transport_rolling () and pos_s () or nil
			if p0 and p0 >= at - 0.005 then
				locate (to + (p0 - at))
				BACKING.jump_lift, BACKING.jump_fwd = false, nil
				log (string.format ("backing : saut armé trop tard (%.2f > %.2f s), seek immédiat", p0, at))
			elseif to < at then
				loop_set (to, at)
				BACKING.jump_lift, BACKING.jump_fwd = true, nil
				log (string.format ("backing : saut armé, boucle %.2f -> %.2f s", to, at))
			else
				loop_set (nil)
				BACKING.jump_lift, BACKING.jump_fwd = false, { at = at, to = to }
				log (string.format ("backing : saut armé, à %.2f s vers %.2f s", at, to))
			end
			BACKING.last_fp = nil
		end
	elseif op == "loop" then
		BACKING.jump_lift, BACKING.jump_fwd = false, nil
		local a, b = tonumber (c.a), tonumber (c.b)
		if c.off or not (a and b and b > a) then
			loop_set (nil)
			BACKING.loop = nil
			log ("backing : boucle levée")
		else
			loop_set (a, b)
			BACKING.loop = { a = a, b = b }
			local p = pos_s ()
			if p < a or p >= b then locate (a) end
			log (string.format ("backing : boucle A/B %.2f -> %.2f s", a, b))
		end
	elseif op == "mix" then
		if type (c.stem) == "string" then backing_mix (c.stem, c.mute, c.vol) end
	elseif op == "mute" then
		BACKING.bus:mute_control ():set_value (c.on == true and 1 or 0, NG)
	else
		log ("backing : op inconnue " .. tostring (op))
	end
end

local function backing_tick ()
	local B = BACKING
	if not (B.slug and B.len > 0) then
		if not B.wrote_off then
			write_file (BACKING_JSON, json_encode ({ present = false, ends = B.ends }))
			B.wrote_off, B.last_fp = true, nil
		end
		return
	end
	B.wrote_off = false
	local rolling = Session:transport_rolling ()
	local pos = pos_s ()
	local looping = B.loop ~= nil and Session:get_play_loop ()
	-- FIN DE CHANSON : arrêt et retour au début, comptée (golem.fm enchaîne sa playlist sur la FIN, jamais sur un stop
	-- demandé). Pas pendant une boucle, ni pendant une prise : arrêter le transport la fermerait.
	if rolling and not Session:get_play_loop () and not REC.on and pos >= B.len - 0.02 then
		Session:request_stop (false, false, ARDOUR.TransportRequestSource.TRS_UI)
		-- le retour au début APRÈS l'arrêt : le transport d'Ardour refuse un déplacement pendant qu'il s'arrête
		-- (« bad transition … DeclickToStop … Locate », mesuré 2026-11-17)
		B.rewind_at = now_s () + 0.3
		rolling, pos = false, 0
		B.ends = B.ends + 1
		log ("backing : fin de chanson — arrêt et retour au début")
	end
	if B.rewind_at then
		if now_s () < B.rewind_at or Session:transport_rolling () then
			rolling, pos = false, 0                   -- la fin est dite tout de suite ; le transport, lui, finit de s'arrêter
		else
			B.rewind_at = nil
			Session:request_locate (0, false, ARDOUR.LocateTransportDisposition.MustStop, ARDOUR.TransportRequestSource.TRS_UI)
			pos = 0
		end
	end
	if not rolling and B.was_rolling and pos < 0.02 then clear_jump ("transport arrêté") end
	B.was_rolling = rolling
	local jumped = false
	if rolling then
		if B.jump_fwd and pos >= B.jump_fwd.at - 0.035 then
			locate (B.jump_fwd.to)
			log (string.format ("backing : saut %.2f -> %.2f s", pos, B.jump_fwd.to))
			pos, B.jump_fwd, jumped = B.jump_fwd.to, nil, true
		elseif B.jump_lift and B.last_pos and pos < B.last_pos - 0.05 then
			loop_set (nil)                              -- rebouclé : la boucle de SAUT a fait son travail
			B.jump_lift, jumped = false, true
			log (string.format ("backing : saut fait (rebouclage à %.2f s), boucle levée", pos))
		end
	end
	if jumped or (B.last_pos and (pos < B.last_pos - 0.05 or pos > B.last_pos + 0.5)) then B.last_pub, B.last_fp = 0, nil end
	B.last_pos = pos
	local paused = (not rolling) and pos > 0.02
	local fp = table.concat ({ B.slug, tostring (rolling), tostring (paused), math.floor (pos * 4), tostring (looping), B.ends }, "|")
	local stems = {}
	for _, name in ipairs (B.order) do
		local m = B.mix[name] or { mute = 0, vol = 1 }
		stems[name] = { mute = m.mute, vol = m.vol }
		fp = fp .. "|" .. m.mute .. "," .. m.vol
	end
	if fp ~= B.last_fp and (not rolling or now_s () - B.last_pub >= 0.2) then
		B.last_fp, B.last_pub = fp, now_s ()
		write_file (BACKING_JSON, json_encode ({ present = true, slug = B.slug, playing = rolling, paused = paused, pos = pos, len = B.len,
			loop = { on = looping, a = B.loop and B.loop.a or 0, b = B.loop and B.loop.b or 0 }, stems = stems, ends = B.ends, songclick = 0 }))
	end
end

-- une PRISE et la backing partagent le transport : la prise le fait tourner. Une backing chargée que la prise n'a pas
-- demandée (et qui ne jouait pas déjà) est COUPÉE le temps de la prise, puis rétablie (golem_perfrec, 2026-07-26).
BACKING_TAKE = function (starting, wanted)
	if not (BACKING.bus and BACKING.slug) then return end
	if starting then
		if not wanted and not Session:transport_rolling () then
			BACKING.bus:mute_control ():set_value (1, NG)
			BACKING.muted_by_take = true
			log ("backing : coupée le temps de la prise (elle ne jouait pas)")
		end
	elseif BACKING.muted_by_take then
		BACKING.bus:mute_control ():set_value (0, NG)
		BACKING.muted_by_take = false
		log ("backing : rétablie après la prise")
	end
end

-- ── LES SAMPLES (golem « Sample », bridge : actions sample et sample_preview ; sous REAPER : golem_sample.lua) ───────
-- Des sons lancés au pied ou par un morceau : une piste MIDI PERMANENTE « golem:sample » avec sfizz, sortie 1/2. Sous
-- REAPER, un sampler par son ; ici UN fichier SFZ que le veilleur écrit — une région par son, chacune sur sa note —
-- refait quand la liste d'un bloc change. Lancer = un note-on écrit dans sfizz ; le son va au bout tant que la note
-- est tenue, un note-off (stop, ou un autre son du même bloc) le coupe. Le bridge donne les fichiers en chemins absolus
-- et leurs durées (c'est elle qui dit quand un son a fini).
-- État publié : presets/.sample.json {present, blocks: {<bloc>: {playing, idx}}}.
do
local SAMPLE_JSON = ROOT .. "/presets/.sample.json"
local SFIZZ_UNITY_DB = 4.1

SAMPLE.ensure = function ()
	SAMPLE.route = midi_track ("golem:sample", false)
	SAMPLE.proc, SAMPLE.blocks, SAMPLE.order = nil, {}, {}
	local outs = physical (false)
	if not no_output () and outs[1] then
		SAMPLE.route:output ():audio (0):connect (outs[1])
		SAMPLE.route:output ():audio (1):connect (outs[2] or outs[1])
	end
	SERVICE_ROUTES = SERVICE_ROUTES + 1
end

-- le kit de TOUS les blocs : une note par son (un bloc après l'autre), refait seulement si une liste a changé
local function sample_kit ()
	local lines, note = { "// golem samples — written by golem's engine watcher", "<group> ampeg_release=0.03 amp_veltrack=0" }, 0
	for _, bid in ipairs (SAMPLE.order) do
		local b = SAMPLE.blocks[bid]
		b.base = note
		for i, f in ipairs (b.files) do
			if note > 127 then break end
			-- sfizz rend un son 4,1 dB sous son fichier (mesuré dans une prise, mono comme stéréo : 3 dB de loi de
			-- panoramique au centre, 1,1 dB de plus) : un sample lancé sort à SON niveau, comme sous REAPER
			lines[#lines + 1] = string.format ("<region> sample=%s key=%d volume=%g", f, note, (b.db or 0) + SFIZZ_UNITY_DB)
			note = note + 1
		end
	end
	if not SAMPLE.proc then
		SAMPLE.proc = ARDOUR.LuaAPI.new_plugin (Session, "http://sfztools.github.io/sfizz", ARDOUR.PluginType.LV2, "")
		if SAMPLE.proc:isnil () then SAMPLE.proc = nil; error ("sfizz introuvable") end
		CHAIN.pre (SAMPLE.route, SAMPLE.proc)
	end
	SAMPLE.gen = SAMPLE.gen + 1
	local path = ROOT .. "/presets/.engine-samples-" .. SAMPLE.gen .. ".sfz"
	write_file (path, table.concat (lines, "\n") .. "\n")
	ARDOUR.LuaAPI.set_plugin_insert_property (SAMPLE.proc:to_insert (), "http://sfztools.github.io/sfizz:sfzfile", path)
	if SAMPLE.last then os.remove (SAMPLE.last) end
	SAMPLE.last = path
	SAMPLE.ready_at = now_s () + 0.25              -- le temps que sfizz lise ses fichiers
end

local function sample_block (bid, files, durs, db)
	local b = SAMPLE.blocks[bid]
	local sig = table.concat (files or {}, "|") .. "@" .. tostring (db or 0)
	if not b then
		b = { files = {}, durs = {}, idx = -1, cur = nil, until_s = 0 }
		SAMPLE.blocks[bid] = b
		SAMPLE.order[#SAMPLE.order + 1] = bid
	end
	if b.sig ~= sig then
		b.files, b.durs, b.db, b.sig = files or {}, durs or {}, db, sig
		sample_kit ()
	end
	return b
end

local function sample_stop (bid)
	local b = SAMPLE.blocks[bid]
	if b and b.cur and SAMPLE.proc then midi_write (SAMPLE.proc, { { 0x80, b.cur, 0 } }) end
	if b then b.cur, b.until_s = nil, 0 end
end

local function sample_fire (bid, idx)
	local b = SAMPLE.blocks[bid]
	if not (b and SAMPLE.proc) then return end
	if b.cur then midi_write (SAMPLE.proc, { { 0x80, b.cur, 0 } }) end
	local note = (b.base or 0) + idx
	if not b.files[idx + 1] or note > 127 then log ("sample : pas de son " .. tostring (idx) .. " dans " .. tostring (bid)); return end
	midi_write (SAMPLE.proc, { { 0x90, note, 127 } })
	SAMPLE.fired_at = now_s ()
	b.cur, b.idx = note, idx
	b.until_s = now_s () + (tonumber (b.durs[idx + 1]) or 2.0)
end

SAMPLE.cmd = function (c)
	if not SAMPLE.route then error ("sample : pas de piste") end
	local bid = c.block or "sample"
	if c.op == "play" then
		sample_block (bid, type (c.files) == "table" and c.files or {}, type (c.durs) == "table" and c.durs or {}, nil)
		local idx = math.floor (tonumber (c.idx) or 0)
		-- différé : `in_ms` (un morceau le cale sur son temps), et le chargement d'un kit qu'on vient de refaire
		local at = math.max (now_s () + (tonumber (c.in_ms) or 0) / 1000, SAMPLE.ready_at or 0)
		SAMPLE.queue[#SAMPLE.queue + 1] = { at = at, bid = bid, idx = idx }
	elseif c.op == "stop" then
		for i = #SAMPLE.queue, 1, -1 do if SAMPLE.queue[i].bid == bid then table.remove (SAMPLE.queue, i) end end
		sample_stop (bid)
	else
		log ("sample : op inconnue " .. tostring (c.op))
	end
end

-- l'écoute d'un son depuis la Library : un bloc à part, un seul fichier ; `file` vide = couper
SAMPLE.preview_cmd = function (c)
	if not SAMPLE.route then error ("sample : pas de piste") end
	local f = tostring (c.file or "")
	sample_stop ("~preview")
	if f == "" then return end
	sample_block ("~preview", { f }, { tonumber (c.dur) or 30 }, tonumber (c.db) or 0)
	SAMPLE.queue[#SAMPLE.queue + 1] = { at = math.max (now_s (), SAMPLE.ready_at or 0), bid = "~preview", idx = 0 }
end

SAMPLE.tick = function ()
	for i = #SAMPLE.queue, 1, -1 do
		local q = SAMPLE.queue[i]
		if now_s () >= q.at then
			table.remove (SAMPLE.queue, i)
			sample_fire (q.bid, q.idx)
		end
	end
	local blocks = {}
	for bid, b in pairs (SAMPLE.blocks) do
		if b.cur and now_s () >= b.until_s then          -- le son est allé au bout : la note est relâchée
			if SAMPLE.proc then midi_write (SAMPLE.proc, { { 0x80, b.cur, 0 } }) end
			b.cur = nil
		end
		if bid ~= "~preview" then blocks[bid] = { playing = b.cur ~= nil, idx = b.idx } end
	end
	local s = json_encode ({ present = SAMPLE.route ~= nil, blocks = blocks })
	if s ~= SAMPLE.pub then SAMPLE.pub = s; write_file (SAMPLE_JSON, s) end
end
end

-- ── LE LOOPER (golem « Looper », docs/looper.md ; sous REAPER : golem_super8 + golem_looper.lua) ────────────────────
-- Un bus PERMANENT « golem:looper » à 8 entrées (4 paires) et « golem Looper » dessus, sortie 1/2 : les boucles
-- survivent aux rappels. La table de boucles du preset (plan.looper.loops, une ligne = une paire) dit quelle lane
-- nourrit quelle paire : la SORTIE de la lane (post-fader : le son tel qu'il s'entend) est reliée aux entrées de la
-- paire. Un preset sans looper : rien de relié, le bus muet (les boucles restent en mémoire).
-- Le bridge pilote le plugin en OSC par son adresse, publiée dans presets/.looper.json (strip, plugin, paramètre
-- « GoleM Cmd ») avec l'état des boucles ; secours : presets/.looper-cmd.json {seq, notes, cfg}.
do
local LOOPER_JSON, LOOPER_CMD = ROOT .. "/presets/.looper.json", ROOT .. "/presets/.looper-cmd.json"

LOOPER.ensure = function ()
	local r = Session:route_by_name ("golem:looper")
	if r:isnil () then
		r = first (Session:new_audio_route (8, 2, ARDOUR.RouteGroup (), 1, "golem:looper", ARDOUR.PresentationInfo.Flag.AudioBus,
			ARDOUR.PresentationInfo.max_order))
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	local p = ARDOUR.LuaAPI.new_luaproc (Session, "golem Looper")
	if p:isnil () then error ("golem Looper introuvable") end
	r:add_processor_by_index (p, 0, nil, true)
	local outs = physical (false)
	if not no_output () and outs[1] then
		r:output ():audio (0):connect (outs[1])
		r:output ():audio (1):connect (outs[2] or outs[1])
	end
	r:mute_control ():set_value (1, NG)
	SERVICE_ROUTES = SERVICE_ROUTES + 1
	LOOPER.route, LOOPER.proc, LOOPER.ssid = r, p, INPUT_METERS + SERVICE_ROUTES
	local f = read_file (LOOPER_CMD)                -- une commande d'AVANT le démarrage n'est pas rejouée
	LOOPER.seq = f and (json_decode (f) or {}).seq or nil
	log (string.format ("looper : bus à %d entrée(s) et %d sortie(s), strip %d", r:input ():n_ports ():n_audio (),
		r:output ():n_ports ():n_audio (), LOOPER.ssid))
end
LOOPER.wire = function (lp)
	local r = LOOPER.route
	if not r then return end
	if lp ~= nil then LOOPER.loops = (type (lp) == "table" and type (lp.loops) == "table") and lp.loops or false end
	r:input ():disconnect_all ()
	local loops = LOOPER.loops
	r:mute_control ():set_value (loops and 0 or 1, NG)
	LOOPER.pub = ""                                  -- l'adresse est republiée APRÈS chaque rappel (le bridge l'attend)
	if not loops then return end
	for li, row in ipairs (loops) do
		local fed = 0
		if li <= 4 and row.input then
			for name, spec in pairs (RIG.specs) do
				local src = RIG.routes[name]
				if src and spec.out and spec.mixer == "in" .. tostring (row.input) then
					local sn = src:output ():n_ports ():n_audio ()
					for c = 0, 1 do
						r:input ():audio ((li - 1) * 2 + c):connect (src:output ():audio (math.min (c, sn - 1)):name ())
					end
					fed = fed + 1
				end
			end
		end
		if fed == 0 then log ("looper : boucle " .. li .. " MUETTE (sa lane n'est pas dans le preset)") end
	end
end

LOOPER.tick = function ()
	if not LOOPER.proc then return end
	local shm = LOOPER.proc:to_insert ():plugin (0):to_luaproc ():shmem ()
	local a = shm:to_int (0):array ()
	-- le secours par fichier : le calage d'abord (paramètres), puis les notes dans l'anneau du plugin
	local body = read_file (LOOPER_CMD)
	local c = body and json_decode (body)
	if type (c) == "table" and c.seq ~= LOOPER.seq then
		LOOPER.seq = c.seq
		if type (c.cfg) == "table" then
			ARDOUR.LuaAPI.set_processor_param (LOOPER.proc, 1, tonumber (c.cfg.tempo) or 0)
			ARDOUR.LuaAPI.set_processor_param (LOOPER.proc, 2, tonumber (c.cfg.mode) or 0)
			ARDOUR.LuaAPI.usleep (12000)                  -- un cycle : le calage est lu avant la commande
		end
		for _, n in ipairs (type (c.notes) == "table" and c.notes or {}) do
			local w = a[101]
			a[103 + w % 16] = math.floor (tonumber (n) or 0)
			shm:atomic_set_int (100, w + 1)
		end
	end
	local rate = math.max (1, a[7])
	local slots = {}
	for p = 0, 3 do slots[p + 1] = { st = a[9 + p * 4], has = a[10 + p * 4] == 1, peak = a[11 + p * 4] / 1000 } end
	local doc = { present = true, track = LOOPER.ssid, fx = 0, cmd_param = 0, seq = LOOPER.seq or 0,
		len = a[1] / rate, pos = 0, firstrec = a[3], countin = a[5], countin_slot = a[6], slots = slots }
	local sig = json_encode (doc)
	local active = a[1] > 0 or a[3] ~= 0 or a[5] > 0
	-- publié quand quelque chose change, et quatre fois par seconde tant que ça tourne (la position ; le bridge l'extrapole)
	if sig ~= LOOPER.pub or (active and now_s () - LOOPER.at > 0.25) then
		LOOPER.pub, LOOPER.at = sig, now_s ()
		doc.pos = a[2] / rate
		write_file (LOOPER_JSON, json_encode (doc))
	end
end
end

-- ── LA PRISE (golem « Rec », bridge : action perf_rec ; sous REAPER : reaper/Scripts/golem_perfrec.lua) ──────────────
-- Une piste d'Ardour enregistre son ENTRÉE. Pour graver ce que le musicien entend, chaque piste de prise est reliée
-- aux PORTS DE SORTIE des routes qui vont à la carte (après les plugins, le niveau de scène et le trim du mixer) :
--   « Mix »                 la somme de toutes ces routes, stéréo — le mix entendu ;
--   « Input-N »             la route de la lane de l'entrée N seule (modes tracks et tracks_di) ;
--   « DI-Sandbox-Input-N »  l'entrée N de la carte, brute, mono (mode tracks_di).
-- Les noms sont ceux des fichiers que REAPER range (recordings/perf-<date>/…) : le reste de golem les lit par leur nom.
-- Ce qui se prend vient de presets/.perfsrc.json, figé au départ (cases IN 1 / IN 2 / USB, mode, « Song mix »).
-- Ardour écrit un fichier MONO PAR CANAL : à l'arrêt, le veilleur dit ce qu'il a écrit (.engine-take.json) et lance
-- l'assembleur de golem (bridge/engine/take_finalize.py, hors du veilleur : une longue répète ne fige pas les scènes),
-- qui range les fichiers et dit la prise finie dans presets/.perf.json. Pendant ce temps la prise est dite « en cours ».
local PERF = ROOT .. "/presets/.perf.json"
local PERFSRC = ROOT .. "/presets/.perfsrc.json"
local TAKE = ROOT .. "/presets/.engine-take.json"
REC = { on = false, stopping = nil, tracks = {}, file = nil, started = nil, error = "", pos = nil, pos_at = nil }
REC_COUNT = function () local n = 0; for _, t in pairs (REC.tracks) do if not t.pooled then n = n + 1 end end; return n end
-- ── LES PISTES DE PRISE PERMANENTES (2026-11-17, mesuré sur la vraie carte à 192 échantillons) ───────────────────────
-- Créer puis retirer les pistes d'une prise refait le graphe du moteur : 5 décrochages à chaque prise, en plein jeu.
-- Elles sont donc créées UNE fois, au démarrage, sans entrée ni sortie, et servent à toutes les prises : une prise ne
-- fait plus que les relier, les armer, puis vider leur playlist. Une piste que la réserve n'a pas (une quatrième
-- entrée, un second clavier) est encore créée à la demande, comme avant.
REC.pool = {}
local REC_POOL = { { "Mix", 2 }, { "Input-1", 2 }, { "Input-2", 2 }, { "Input-3", 2 }, { "DI-Sandbox-Input-1", 1 },
	{ "DI-Sandbox-Input-2", 1 }, { "DI-Sandbox-Input-3", 1 }, { "Drums", 2 }, { "Backing-Track", 2 }, { "Sample", 2 },
	{ "Looper", 2 }, { "Standard-Keys", 2 }, { "Standard-Bass", 2 }, { "Standard-Drums", 2 }, { "Standard-Guitar", 2 },
	{ "Preview", 2 }, { "MIDI-Input-3", "midi" } }
REC_POOLED = function (name)
	for _, r in pairs (REC.pool) do if r:name () == name then return true end end
	return false
end

local PREVIEW_JSON = ROOT .. "/presets/.preview.json"
local preview_restore                       -- défini avec l'écoute sans jouer, plus bas
local function perf_publish (recording)
	if REC.preview then                              -- un rendu d'écoute n'est pas une prise : il a son propre état
		if not recording then
			write_file (PREVIEW_JSON, json_encode ({ seq = REC.preview.seq or 0, scene = REC.preview.scene or "", done = true,
				error = (REC.error ~= "" and REC.error) or "nothing was rendered" }))
		end
		return
	end
	write_file (PERF, json_encode ({ recording = recording, file = REC.file or "", started_at = REC.started or "", error = REC.error or "" }))
end

local function rec_new (name, nch, label)
	local r
	if nch == "midi" then
		r = first (Session:new_midi_track (ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1), ARDOUR.ChanCount (ARDOUR.DataType ("midi"), 1),
			false, ARDOUR.PluginInfo (), nil, ARDOUR.RouteGroup (), 1, label, ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true))
	else
		r = first (Session:new_audio_track (nch, nch, ARDOUR.RouteGroup (), 1, label, ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true))
	end
	r:input ():disconnect_all ()
	r:output ():disconnect_all ()
	r:to_track ():monitoring_control ():set_value (ARDOUR.MonitorChoice.MonitorDisk, NG)   -- jamais réentendue
	return r
end

-- ── L'HORLOGE MIDI (golem : la piste « MIDI Clock » de golem_clock.lua sous REAPER) ──────────────────────────────────
-- Une piste MIDI permanente « golem:clock », son script « golem Clock » (24 tics par noire au tempo du preset,
-- transport arrêté), reliée aux SORTIES des claviers que le rig a ouverts : l'arpégiateur d'un clavier se cale sur le
-- BPM du preset. Sous REAPER la sortie est cherchée par nom (« MPK », « akai ») ; ici c'est le clavier de chaque lane
-- MIDI, quel qu'il soit. Créée APRÈS les services et les pistes de prise : le rig compte ce qui le précède (RIG.base).
do
MIDICLOCK.phys = function ()                            -- les ports MIDI physiques où le moteur ÉCRIT (vers un appareil)
	local out = {}
	local _, t = AudioEngine:get_backend_ports ("", ARDOUR.DataType ("midi"),
		ARDOUR.PortFlags.IsPhysical | ARDOUR.PortFlags.IsInput, C.StringVector ())
	for p in t[4]:iter () do out[p] = true end
	return out
end

MIDICLOCK.ensure = function ()
	local r = midi_track ("golem:clock", true)
	local p = ARDOUR.LuaAPI.new_luaproc (Session, "golem Clock")
	if p:isnil () then error ("golem Clock introuvable (ARDOUR_DATA_PATH)") end
	CHAIN.pre (r, p)
	MIDICLOCK.route, MIDICLOCK.proc, MIDICLOCK.linked = r, p, ""
	MIDICLOCK.tempo (Temporal.TempoMap.read ():quarters_per_minute_at (Temporal.timepos_t (0)))
	log ("horloge MIDI : piste prête (24 tics par noire, transport arrêté)")
end

MIDICLOCK.tempo = function (bpm)
	MIDICLOCK.bpm = tonumber (bpm) or MIDICLOCK.bpm
	if MIDICLOCK.proc then
		set_params ({ proc = MIDICLOCK.proc, spec = { id = "clock" } }, { { pid = "bpm", label = "BPM", value = MIDICLOCK.bpm } })
	end
end

-- relie la piste aux sorties des claviers ouverts ; refait seulement quand la liste change (un clavier branché,
-- débranché, rouvert). Appelée par la boucle : rien à savoir du moment où un rappel ouvre un appareil.
MIDICLOCK.link = function ()
	if not MIDICLOCK.route then return end
	local now, want = MIDICLOCK.phys (), {}
	for _, ports in pairs (MIDICLOCK.ports) do
		for _, p in ipairs (ports) do if now[p] then want[#want + 1] = p end end
	end
	table.sort (want)
	local sig = table.concat (want, "|")
	if sig == MIDICLOCK.linked then return end
	MIDICLOCK.route:output ():disconnect_all ()
	local ok = 0
	for _, p in ipairs (want) do
		if MIDICLOCK.route:output ():midi (0):connect (p) == 0 then ok = ok + 1 else log ("  horloge MIDI : lien refusé -> " .. p) end
	end
	MIDICLOCK.linked = sig
	log ("horloge MIDI : " .. ok .. " sortie(s) de clavier reliée(s)" .. (ok > 0 and " (" .. sig .. ")" or ""))
end

MIDICLOCK.state = function ()                           -- pour le battement : {ticks, bpm, ports}
	if not MIDICLOCK.proc then return nil end
	local lp = MIDICLOCK.proc:to_insert ():plugin (0):to_luaproc ()
	if lp:isnil () then return nil end
	local t = lp:shmem ():to_int (0):array ()
	local n = 0
	if MIDICLOCK.linked ~= "" then for _ in MIDICLOCK.linked:gmatch ("[^|]+") do n = n + 1 end end
	return { ticks = t[1], bpm = t[2] / 100, ports = n }
end
end

local function ensure_rec_pool ()
	for _, d in ipairs (REC_POOL) do
		local key = d[1] .. ":" .. tostring (d[2])
		if not REC.pool[key] then REC.pool[key] = rec_new (d[1], d[2], "golem:rec:pool:" .. d[1]) end
	end
	log ("prise : " .. #REC_POOL .. " piste(s) permanente(s) prêtes")
end

-- la piste d'une prise : celle de la réserve si elle existe (rendue à la fin), sinon créée pour cette prise.
-- Rend la route et `pooled`.
local function rec_track (name, nch)
	local key = name .. ":" .. tostring (nch)
	local r = REC.pool[key]
	if r then
		for _, t in pairs (REC.tracks) do if t.pool_key == key then r = nil; break end end   -- déjà prise dans cette prise
	end
	if r then
		-- JAMAIS RENOMMÉE : une piste permanente renommée au départ de la prise ne rendait plus aucune région dès qu'un
		-- rappel passait pendant la prise, ni aux prises suivantes (mesuré 2026-11-17). Ardour numérote lui-même les
		-- fichiers d'une piste qui enregistre plusieurs fois.
		return r, true
	end
	return rec_new (name, nch, "golem:rec:" .. REC.stamp .. ":" .. name), false
end

-- LE MIDI JOUÉ (« MIDI-Input-N.mid », comme golem_perfrec) : une piste MIDI de prise, ouverte sur le clavier de la lane
-- — ce que le musicien a joué, avant la zone, l'arpégiateur et l'instrument. Elle n'a pas de sortie.
local function rec_entry (name, nch, t)
	t.route, t.pooled = rec_track (name, nch)
	if t.pooled then t.pool_key, t.pool_name = name .. ":" .. tostring (nch), name end
	return t
end

-- relie (ou relie de nouveau, après un rappel pendant la prise) chaque piste de prise à ses sources
rec_link = function ()
	local ins = physical (true)
	for tname, t in pairs (REC.tracks) do
		t.route:input ():disconnect_all ()
		local n_ok, n_bad = 0, 0
		local function link (port, other)
			if port:connect (other) == 0 then n_ok = n_ok + 1 else n_bad = n_bad + 1 end
		end
		if t.midi then
			for _, p in ipairs (midi_device_ports (t.midi)) do link (t.route:input ():midi (0), p) end
		elseif t.di then
			if ins[t.di] then link (t.route:input ():audio (0), ins[t.di]) end
		else
			local function from (r)
				local n = r:output ():n_ports ():n_audio ()
				for ch = 0, 1 do link (t.route:input ():audio (ch), r:output ():audio (math.min (ch, n - 1)):name ()) end
			end
			for name, spec in pairs (RIG.specs) do
				local r = RIG.routes[name]
				if r and spec.out and (t.all and REC.allowed (spec) or (t.src and spec.mixer == t.src)) then from (r) end
			end
			for _, r in ipairs (t.routes or {}) do from (r) end          -- des routes nommées (le rendu d'un bloc)
			-- la boîte à rythmes fait partie du jeu : dans le mix, et sur sa piste. Le métronome, JAMAIS.
			local dr = DRUMS_ROUTE and DRUMS_ROUTE ()
			if dr and (t.all or t.service == "drums") then from (dr) end
			for id, part in pairs (STD_PARTS and STD_PARTS () or {}) do    -- les parties du standard qui joue
				if part.on and (t.all or t.service == "std-" .. id) then from (part.route) end
			end
			local bb = BACKING_BUS and BACKING_BUS ()                      -- la backing chargée
			if bb and (t.all or t.service == "backing") then from (bb) end
			local sr = SAMPLE.route                                        -- les samples lancés font partie du jeu
			if sr and (t.all or t.service == "sample") then from (sr) end
			local lr = LOOPER.loops and LOOPER.route                      -- les boucles qui tournent aussi
			if lr and (t.all or t.service == "looper") then from (lr) end
		end
		log ("  prise : " .. tname .. " <- " .. n_ok .. " lien(s)" .. (n_bad > 0 and (", " .. n_bad .. " REFUSÉ(S)") or ""))
	end
end

local function perf_start (c)
	if REC.on or REC.stopping then log ("prise : départ ignoré (déjà en cours)"); return end
	local src = read_json (PERFSRC) or {}
	local mode = src.mode or "mix"
	local keep_mix = src.mix ~= false
	-- une entrée se prend sauf si sa case dit non : `in<N>` d'abord, sinon le triplet d'avant (1, 2, puis usb)
	REC.allowed = function (spec)
		local n = tonumber (tostring (spec.mixer or ""):match ("^in(%d+)$"))
		if not n then return true end
		local per = src["in" .. n]
		if per ~= nil then return per ~= false end
		return src[(n == 1 and "in1") or (n == 2 and "in2") or "usb"] ~= false
	end
	local ts = os.date ("%Y%m%d-%H%M%S")
	REC.stamp = ts
	REC.file = (mode == "mix") and ("recordings/perf-" .. ts .. ".wav") or ("recordings/perf-" .. ts)
	REC.started, REC.error, REC.mode, REC.tracks = os.date ("%Y-%m-%dT%H:%M:%S"), "", mode, {}
	REC.finalizer = type (c.finalizer) == "table" and c.finalizer or nil   -- [python, script] : l'assembleur du bridge
	local t0 = now_s ()
	if mode == "mix" or keep_mix then REC.tracks["Mix"] = rec_entry ("Mix", 2, { all = true }) end
	if mode ~= "mix" then
		local seen = {}
		for name, spec in pairs (RIG.specs) do
			local n = tonumber (tostring (spec.mixer or ""):match ("^in(%d+)$"))
			if spec.out and n and REC.allowed (spec) and not seen[n] then
				seen[n] = true
				REC.tracks["Input-" .. n] = rec_entry ("Input-" .. n, 2, { src = spec.mixer })
			end
			-- une lane MIDI : son clavier aussi (une piste par entrée, tous canaux — la lane dépliée a plusieurs pistes)
			if spec.kind == "midi" and spec.midi and spec.midi.device then
				local mn = n
				if not mn then
					for _, o in pairs (RIG.specs) do
						for _, f in ipairs (o.from or {}) do
							if f == name then mn = tonumber (tostring (o.mixer or ""):match ("^in(%d+)$")) end
						end
					end
				end
				local owner = mn and { mixer = "in" .. mn } or nil
				if mn and REC.allowed (owner) and not REC.tracks["MIDI-Input-" .. mn] then
					REC.tracks["MIDI-Input-" .. mn] = rec_entry ("MIDI-Input-" .. mn, "midi", { midi = spec.midi.device })
				end
			end
		end
		if DRUMS_ROUTE and DRUMS_ROUTE () then REC.tracks["Drums"] = rec_entry ("Drums", 2, { service = "drums" }) end
		for id, part in pairs (STD_PARTS and STD_PARTS () or {}) do
			if part.on then REC.tracks[part.file] = rec_entry (part.file, 2, { service = "std-" .. id }) end
		end
		if BACKING_BUS and BACKING_BUS () then REC.tracks["Backing-Track"] = rec_entry ("Backing-Track", 2, { service = "backing" }) end
		-- la piste des samples est TOUJOURS prise (une cue du morceau peut lancer son premier son en pleine prise) ; elle
		-- n'est gardée que si un sample a sonné pendant la prise
		if SAMPLE.route then
			local ringing = false
			for _, b in pairs (SAMPLE.blocks) do if b.cur then ringing = true end end
			REC.tracks["Sample"] = rec_entry ("Sample", 2, { service = "sample", keep_if_fired = true })
			REC.sample_from = ringing and 0 or now_s ()
		end
		if LOOPER.loops and LOOPER.route then REC.tracks["Looper"] = rec_entry ("Looper", 2, { service = "looper" }) end
		if mode == "tracks_di" then
			for name, spec in pairs (RIG.specs) do
				if spec.input and spec.kind ~= "midi" and REC.allowed ({ mixer = "in" .. spec.input }) then
					REC.tracks["DI-Sandbox-Input-" .. spec.input] = rec_entry ("DI-Sandbox-Input-" .. spec.input, 1, { di = spec.input })
				end
			end
		end
		-- UNE DI À LA DEMANDE (golem bridge/di_record.py, `di_record` dans presets/.perfsrc.json) : l'entrée demandée
		-- est prise BRUTE même si aucune lane du rig ne la joue — c'est le signal du musicien qu'on veut, pas un patch
		if src.di_record == true then
			for k, v in pairs (src) do
				local n = tonumber (tostring (k):match ("^in(%d+)$"))
				if n and v == true and n <= N_IN and not REC.tracks["DI-Sandbox-Input-" .. n] then
					REC.tracks["DI-Sandbox-Input-" .. n] = rec_entry ("DI-Sandbox-Input-" .. n, 1, { di = n })
				end
			end
		end
	end
	rec_link ()
	for _, t in pairs (REC.tracks) do t.route:rec_enable_control ():set_value (1, NG) end
	if BACKING_TAKE then BACKING_TAKE (true, c.backing == true) end
	if Session:transport_rolling () then
		-- le transport TOURNE déjà (une backing joue) : la prise s'y greffe, sans le ramener au début
		ARDOUR.LuaAPI.usleep (150000)
		Session:maybe_enable_record (false)
	else
		Session:request_locate (0, false, ARDOUR.LocateTransportDisposition.MustStop, ARDOUR.TransportRequestSource.TRS_UI)
		ARDOUR.LuaAPI.usleep (150000)                -- les pistes armées et le transport à zéro avant d'engager la prise
		Session:maybe_enable_record (false)
		Session:request_roll (ARDOUR.TransportRequestSource.TRS_UI)
	end
	REC.on, REC.pos, REC.pos_at = true, -1, now_s ()
	perf_publish (true)
	log (string.format ("prise : départ (%s, %d piste(s), prête en %.0f ms) -> %s", mode, REC_COUNT (), (now_s () - t0) * 1000, REC.file))
end

local function perf_stop ()
	if not REC.on then
		perf_publish (false)                         -- un arrêt sans prise : l'état dit simplement « pas de prise »
		return
	end
	Session:request_stop (false, false, ARDOUR.TransportRequestSource.TRS_UI)
	REC.on, REC.stopping = false, now_s () + 0.6     -- le temps que le disque rende ses derniers tampons
	log ("prise : arrêt demandé")
end

-- des sources que le veilleur écarte LUI-MÊME (la piste Sample sans son joué) : rendues 3 s plus tard, pas à l'arrêt.
-- Juste après l'arrêt Ardour travaille encore sur une capture neuve (le butler la ferme, un fil construit ses pics) :
-- retirée à ce moment, elle restait ouverte (mesuré 2026-11-20 : « encore là » à chaque fois, quand celles que rend
-- l'assembleur une seconde plus tard se ferment toutes), et retirer une source qu'un autre fil tient est risqué.
REC.discard_later = function (files)
	if #files == 0 then return end
	REC.later = REC.later or {}
	for _, f in ipairs (files) do REC.later[#REC.later + 1] = f end
	REC.later_at = now_s () + 3.0
end

-- RENDRE des sources de prise à la session : retirées (Ardour ferme leurs fichiers), puis les fichiers effacés. Sous
-- Windows un fichier ouvert ne s'efface pas — une répète laissait chaque prise en double sur le disque ; sous Linux un
-- fichier déplacé garde sa place tant qu'il est ouvert. Seules les sources gardées dans REC.held (par perf_finalize).
REC.release = function (files, why)
	local list, gone = ARDOUR.SourceList (), {}
	for _, f in ipairs (files) do
		local src = REC.held and REC.held[f]
		if src then list:push_back (src); REC.held[f] = nil; gone[#gone + 1] = f end
	end
	if #gone == 0 then return end
	local n = ARDOUR.LuaAPI.release_sources (Session, list)
	-- une source tenue par Lua (ses objets ne meurent qu'au ramasse-miettes) garde son fichier ouvert : mesuré
	-- 2026-11-20, sans ce ramassage AUCUN fichier ne s'effaçait
	list = nil
	collectgarbage ("collect")
	local kept = 0
	for _, f in ipairs (gone) do
		if not os.remove (f) then                    -- déjà déplacé par l'assembleur, ou encore tenu
			local h = io.open (f, "r")
			if h then h:close (); kept = kept + 1 end
		end
	end
	log (string.format ("prise : %d source(s) rendue(s) %s, fermée(s)%s", n, why,
		kept > 0 and string.format (" — %d fichier(s) encore là", kept) or ""))
end

-- la prise ARRÊTÉE : ce que chaque piste a écrit, les pistes retirées, l'assembleur lancé
local function perf_finalize ()
	REC.stopping = nil
	Session:disable_record (false, true)
	local tracks, rl, discard = array (), ARDOUR.RouteListPtr (), {}
	for name, t in pairs (REC.tracks) do
		t.route:rec_enable_control ():set_value (0, NG)
		-- CHAQUE segment de la piste, à sa place : une prise mise en pause par un rappel (ou coupée par un décrochage)
		-- porte plusieurs régions ; l'assembleur les recolle sur une seule ligne de temps
		local segs = array ()
		for reg in t.route:to_track ():playlist ():region_list ():iter () do
			local files = array ()
			-- chaque source GARDÉE par son chemin : l'assembleur dira quand il en a fini (RELEASE ci-dessous)
			REC.held = REC.held or {}
			for ch = 0, (t.midi and 0 or reg:to_audioregion ():n_channels () - 1) do
				local src = reg:source (ch)
				files[#files + 1] = src:to_filesource ():path ()
				REC.held[files[#files]] = src
			end
			segs[#segs + 1] = { pos = reg:position ():samples (), len = reg:length ():samples (), files = files }
		end
		if t.keep_if_fired and (SAMPLE.fired_at or -1) < (REC.sample_from or 0) then   -- aucun sample : pas de fichier
			for _, sg in ipairs (segs) do for _, f in ipairs (sg.files) do discard[#discard + 1] = f end end
			segs = array ()
		end
		if #segs > 0 then
			tracks[#tracks + 1] = { name = name, segments = segs, midi = t.midi and true or nil,
				bpm = t.midi and Temporal.TempoMap.read ():quarters_per_minute_at (Temporal.timepos_t (0)) or nil }
		end
		do
			local d = {}
			for _, sg in ipairs (segs) do d[#d + 1] = sg.pos .. "+" .. sg.len end
			log ("  prise : " .. name .. " = " .. #segs .. " segment(s) [" .. table.concat (d, ", ") .. "]")
		end
		if t.pooled then
			-- une piste permanente est RENDUE : débranchée, sa playlist vidée (rien ne rejouera), son nom de réserve
			t.route:input ():disconnect_all ()
			local pl, regs = t.route:to_track ():playlist (), {}
			for reg in pl:region_list ():iter () do regs[#regs + 1] = reg end
			for _, reg in ipairs (regs) do pl:remove_region (reg) end
		else
			rl:push_back (t.route)
		end
	end
	for r in rl:iter () do GONE = GONE + 1; r:set_name ("golem-gone-" .. GONE) end
	if rl:size () > 0 then Session:remove_routes (rl) end
	rl = nil
	REC.tracks = {}
	collectgarbage (); collectgarbage ()
	local preview = REC.preview
	if preview and preview.bench then                -- LE BANC CPU : ce que les plugins de la lane ont coûté pendant le rendu
		-- TROIS PASSES (le rendu coupé en tiers), comme les trois rendus de REAPER : la moyenne par buffer de chacune ;
		-- `avg` = leur médiane, `worst` = la plus lente. PAS le pire cycle isolé : en temps réel, un seul cycle retardé
		-- par l'ordonnanceur (152 µs pour un gate qui en coûte 19) passait pour le coût du bloc, et l'estimation d'un
		-- patch sortait à 130-200 % d'un budget dont le moteur n'utilisait que 20 % (rack, 2026-11-17)
		local off = nil
		if preview.bench_was then                       -- la passe éteinte : lue, puis chaque bloc rallumé
			off = 0
			for _, ins in ipairs (preview.bench) do
				local ok, v = ins:get_stats (0, 0, 0, 0)
				if ok and v then off = off + (v[3] or 0) end
			end
			for _, ins in ipairs (preview.bench_was) do ins:enable (true) end
			preview.bench_was = nil
		else
			bench_pass (preview)                           -- rendu trop court pour la passe éteinte : une passe de plus
		end
		local runs = preview.bench_runs
		table.sort (runs)
		preview.extra = { avg_us = runs[(#runs + 1) // 2] or 0, worst_us = runs[#runs] or 0, nfx = #preview.bench, off_us = off,
			srate = Session:nominal_sample_rate (), bsize = Session:get_block_size (), len = preview.len or 0, runs = #runs }
	end
	if preview then pcall (preview_restore) end      -- la lane retrouve la carte, les pistes du rendu s'en vont
	pcall (rekey)                                   -- les clés de gate qu'un rappel pendant la prise n'a pas pu poser
	if BACKING_TAKE then BACKING_TAKE (false) end
	if (RIG.rec_before or 0) > 0 then                -- le rig a été reconstruit pendant la prise : ses strips redescendent
		RIG.rec_before = 0
		for i, name in ipairs (RIG.order) do
			for _, b in pairs (RIG.blocks) do if b.route == RIG.routes[name] then b.ssid = ssid_of (i) end end
		end
		write_livemap ()
	end
	if REC.error ~= "" or #tracks == 0 then
		if REC.error == "" then REC.error = "nothing was recorded" end
		log ("⚠ prise abandonnée : " .. REC.error)
		REC.file = ""
		perf_publish (false)
		REC.preview = nil
		REC.discard_later (discard)                      -- les fichiers bruts d'une prise en erreur, eux, restent
		return
	end
	write_file (TAKE, json_encode ({ root = ROOT, file = REC.file, mode = REC.mode, started_at = REC.started,
		sample_rate = Session:nominal_sample_rate (), tracks = tracks,
		preview = preview and { out = preview.out, seq = preview.seq or 0, scene = preview.scene or "", extra = preview.extra } or nil }))
	REC.preview = nil
	-- l'assembleur : celui que le bridge a nommé au départ de la prise (son Python, son fichier) ; à défaut, celui du
	-- dépôt golem où tourne ce veilleur
	local WINDOWS = package.config:sub (1, 1) == "\\"
	local py, script = ROOT .. (WINDOWS and "/.venv/Scripts/python.exe" or "/.venv/bin/python"), ROOT .. "/bridge/engine/take_finalize.py"
	if REC.finalizer and REC.finalizer[1] and REC.finalizer[2] then py, script = REC.finalizer[1], REC.finalizer[2]
	else
		local f = io.open (py, "r")
		if f then f:close () else py = WINDOWS and "python" or "python3" end
	end
	local function q (x) return "'" .. tostring (x):gsub ("'", "'\\''") .. "'" end
	-- l'assembleur (python, ffmpeg) est un programme DU SYSTÈME : il retrouve le chemin de bibliothèques d'avant le
	-- moteur (golem/dev/env.sh GOLEM_ENGINE_HOST_LD), jamais celles du moteur
	if WINDOWS then
		-- pas de nohup ni de « & » : `start /b` détache ; les guillemets doubles de cmd.exe (un chemin n'en contient pas)
		local function dq (x) return '"' .. tostring (x) .. '"' end
		os.execute (string.format ('start "" /b %s %s %s >> %s 2>&1', dq (py), dq (script), dq (TAKE), dq (ROOT .. "/presets/.engine-take.log")))
	else
		os.execute (string.format ("LD_LIBRARY_PATH=%s nohup %s %s %s >> %s 2>&1 &", q (os.getenv ("GOLEM_ENGINE_HOST_LD") or ""),
			q (py), q (script), q (TAKE), q (ROOT .. "/presets/.engine-take.log")))
	end
	log ("prise : " .. #tracks .. " piste(s) écrite(s), assembleur lancé")
	REC.discard_later (discard)                          -- la piste Sample sans son : rien à garder
end

-- à chaque tour : la fin d'une prise arrêtée, et le chien de garde d'une prise qui n'avance pas (carte perdue : le
-- transport dit « j'enregistre » et sa position ne bouge plus — golem_perfrec, 2026-07-25)
-- une passe du banc CPU : la somme des moyennes par buffer des plugins de la lane depuis la passe d'avant, puis remise
-- à zéro des compteurs
function bench_pass (P)
	local sum, any = 0, false
	for _, ins in ipairs (P.bench) do
		local ok, v = ins:get_stats (0, 0, 0, 0)
		if ok and v then sum, any = sum + (v[3] or 0), true end
		ins:clear_stats ()
	end
	P.bench_runs = P.bench_runs or {}
	if any then P.bench_runs[#P.bench_runs + 1] = sum end
end

-- LA PASSE ÉTEINTE : sous ce moteur, « éteindre » un plugin qui porte son propre bypass (VST3) le laisse TOURNER — il
-- garde ses queues. Mesuré au rack (2026-11-17, Eight-String Nu scène C) : Shimmer éteint 127 µs, Delay 45, Kill Switch
-- 41, quand Chorus et Pitch éteints coûtent 0. On ne le devine pas : chaque bloc est mesuré éteint, le dernier quart.
function bench_off (P)
	P.bench_was = {}
	for _, ins in ipairs (P.bench) do
		if ins:enabled () then
			ins:enable (false)
			P.bench_was[#P.bench_was + 1] = ins
		end
		ins:clear_stats ()
	end
end

local function perf_tick ()
	-- LES SOURCES D'UNE PRISE ASSEMBLÉE, RENDUES : l'assembleur liste les fichiers de capture qu'il a copiés, déplacés ou
	-- assemblés (presets/.engine-take-released.json) ; on les rend (REC.release, plus haut). Jamais avant l'assembleur :
	-- une source « jetable » retirée efface son fichier, et une piste en erreur garde ses fichiers bruts (jamais listés).
	if REC.held and next (REC.held) and now_s () >= (REC.release_at or 0) then
		REC.release_at = now_s () + 0.5
		local path = ROOT .. "/presets/.engine-take-released.json"
		local doc = read_json (path)
		if doc then
			os.remove (path)
			REC.release (doc.files or {}, "par l'assembleur")
		end
	end
	if REC.later and now_s () >= (REC.later_at or 0) then
		local files = REC.later
		REC.later = nil
		REC.release (files, "sans sample joué")
	end
	if REC.preview and REC.on and REC.preview.bench and REC.preview.bench_at and now_s () >= REC.preview.bench_at
	   and #(REC.preview.bench_runs or {}) < 3 then
		bench_pass (REC.preview)
		REC.preview.bench_at = now_s () + REC.preview.bench_step
		if #(REC.preview.bench_runs or {}) >= 3 then bench_off (REC.preview) end
	end
	if REC.preview and REC.on and now_s () >= REC.preview.until_s then   -- la phrase et sa queue sont passées
		Session:request_stop (false, false, ARDOUR.TransportRequestSource.TRS_UI)
		REC.on, REC.stopping = false, now_s () + 0.6
	end
	if REC.start_at and now_s () >= REC.start_at then
		local c = REC.start_cmd
		REC.start_at, REC.start_cmd = nil, nil
		local ok, err = pcall (perf_start, c)
		if not ok then
			log ("ÉCHEC départ de prise : " .. tostring (err))
			REC.error, REC.on = "the take could not start", false
			perf_publish (false)
		end
	end
	if REC.stopping and now_s () >= REC.stopping then
		-- PAS UN DÉLAI FIXE : à l'arrêt, Ardour ferme les fichiers de prise et pose les régions piste après piste. Sous
		-- Windows c'est ~200 ms par piste (mesuré 2026-11-19 : Drums prête à 0,6 s, Sample, Mix puis Backing-Track à
		-- 0,8, 1,0 et 1,2 s — elles manquaient à la prise). On attend que le transport soit arrêté et que chaque piste
		-- AUDIO armée ait sa région ; une piste MIDI sans note n'en a jamais. Borné : 10 s après l'arrêt demandé.
		REC.stop_deadline = REC.stop_deadline or (now_s () + 9.4)
		local ready = not Session:transport_rolling ()
		if ready then
			for _, t in pairs (REC.tracks) do
				if not t.midi then
					local any = false
					for _ in t.route:to_track ():playlist ():region_list ():iter () do any = true; break end
					if not any then ready = false; break end
				end
			end
		end
		if not ready and now_s () < REC.stop_deadline then return end
		if not ready then log ("prise : des pistes sans région 10 s après l'arrêt — la prise est close avec ce qu'elle a") end
		REC.stop_deadline = nil
		local ok, err = pcall (perf_finalize)
		if not ok then
			log ("ÉCHEC fin de prise : " .. tostring (err))
			REC.error, REC.file, REC.tracks, REC.stopping = "the take could not be closed", "", {}, nil
			perf_publish (false)
		end
	elseif REC.on then
		local p = Session:transport_sample ()
		if p ~= REC.pos then REC.pos, REC.pos_at = p, now_s ()
		elseif now_s () - REC.pos_at > 3.0 then
			REC.error = "the audio engine stopped while recording — check the sound card"
			log ("⚠ prise : le transport n'avance plus")
			perf_stop ()
		end
	end
end

-- ── L'ÉCOUTE SANS JOUER (golem « Listen », bridge : action preview ; sous REAPER : golem_preview.lua) ─────────────────
-- Une phrase de référence jouée dans la lane, et ce qui en sort, enregistré : la démo d'une scène. REAPER clone la
-- chaîne et la rend hors ligne ; un rendu hors ligne d'Ardour arrêterait le son de tout le rack. Ici le rendu se fait
-- EN TEMPS RÉEL, dans la lane elle-même, le temps de la phrase :
--   - une DI (lane audio) : une piste « golem:preview:di » la joue à la place de l'entrée de la carte — la lane et les
--     clés de ses gates l'écoutent ;
--   - une phrase MIDI (clavier, batterie) : « golem Midiplay » posé en tête de chaque piste MIDI de la lane la joue ;
--   - la sortie de la lane est DÉBRANCHÉE de la carte (la salle n'entend rien) et reliée à une piste de prise ; le trim
--     du mixer est levé le temps du rendu (une démo ne dépend pas du mix du rack) ;
--   - la mécanique est celle d'une prise (transport, arrêt, assembleur) ; l'assembleur écrit le WAV demandé et le dit
--     dans presets/.preview.json. Tout est remis en place ensuite.
-- Le bridge a déjà posé la scène ; il ne rappelle pas de preset pendant un rendu.
local function preview_fail (c, why)
	log ("écoute : refusée — " .. why)
	write_file (PREVIEW_JSON, json_encode ({ seq = c.seq or 0, scene = c.scene or "", done = true, error = why }))
end

preview_restore = function ()
	local P = REC.preview
	if not P then return end
	local ins, outs = physical (true), physical (false)
	for _, pl in ipairs (P.players or {}) do pcall (function () pl.route:remove_processor (pl.proc, nil, true) end) end
	if P.in_route then
		P.in_route:input ():disconnect_all ()
		if ins[P.input] then P.in_route:input ():audio (0):connect (ins[P.input]) end
	end
	for _, k in ipairs (P.keys or {}) do              -- les clés des gates retrouvent l'entrée de la carte
		local sc = k.proc:to_insert ():sidechain_input ()
		for c = 0, sc:n_ports ():n_audio () - 1 do
			sc:audio (c):disconnect_all ()
			if ins[P.input] then sc:audio (c):connect (ins[P.input]) end
		end
	end
	for _, r in ipairs (P.service or {}) do           -- une piste de service retrouve la carte (1/2) et sa tranche
		if not no_output () and outs[1] then
			r:output ():audio (0):connect (outs[1])
			r:output ():audio (1):connect (outs[2] or outs[1])
		end
	end
	if P.service then service_mix () end
	for _, o in ipairs (P.outs or {}) do              -- la sortie retrouve la carte, et son trim de mixer
		local r, spec = o.route, o.spec
		local nout = r:output ():n_ports ():n_audio ()
		if not no_output () then
			for k, port in ipairs (spec.out or {}) do
				local ch = (nout > 1 and #spec.out > 1) and math.min (k, nout) - 1 or 0
				if outs[port] then
					r:output ():audio (ch):connect (outs[port])
					if nout > 1 and #spec.out == 1 then r:output ():audio (1):connect (outs[port]) end
				end
			end
		end
		apply_out (r, spec)
	end
	if P.di then
		local rl = ARDOUR.RouteListPtr ()
		P.di:input ():disconnect_all (); P.di:output ():disconnect_all ()
		ARDOUR.LuaAPI.usleep (60000)
		GONE = GONE + 1
		P.di:set_name ("golem-gone-" .. GONE)
		rl:push_back (P.di)
		Session:remove_routes (rl)
		P.di = nil
	end
	if LOOPER.wire then LOOPER.wire () end
	collectgarbage (); collectgarbage ()
	log ("écoute : la lane a retrouvé la carte")
end

-- le DÉPART d'un rendu, commun : la piste de prise, la salle coupée, le transport depuis zéro, les lecteurs lancés
-- LES DÉCROCHAGES DU DÉPART NE SONT PAS CEUX DU JEU (2026-11-24) : débrancher la salle, armer la piste de prise et
-- lancer le transport en fait un à chaque rendu — la salle est coupée, personne ne l'entend. Non retenus, le banc CPU
-- au repos en publiait un par bloc mesuré (54 pour 71 blocs, personne ne jouant) et Health affichait « Audio dropouts ».
-- Retenus comme pour un montage (xr_hold / xr_release), relâchés même si le départ échoue. Une fonction anonyme et
-- non une locale de plus : le bloc principal du veilleur est à la limite des 200 locales de Lua.
local function preview_go (c, P, len, src)
	xr_hold ()
	local ok, err = pcall (function ()
	REC.stamp = os.date ("%Y%m%d-%H%M%S")
	REC.tracks = { ["Preview"] = rec_entry ("Preview", 2, { src = src, routes = P.service }) }
	REC.allowed = function () return true end
	P.len = len
	for _, r in ipairs (P.service or {}) do r:output ():disconnect_all () end
	if c.bench then                                    -- le banc CPU : les compteurs des plugins de la lane repartent de zéro
		P.bench = {}
		for name, spec in pairs (RIG.specs) do
			local r = RIG.routes[name]
			local i = 0
			while r do
				local p = r:nth_processor (i)
				if p:isnil () then break end
				local ins = p:to_insert ()
				if not ins:isnil () then ins:clear_stats (); P.bench[#P.bench + 1] = ins end
				i = i + 1
			end
		end
	end
	for _, o in ipairs (P.outs) do                     -- la salle n'entend rien ; le niveau est celui de la scène, sans mixer
		o.route:output ():disconnect_all ()
		o.route:mute_control ():set_value (o.spec.mute and 1 or 0, NG)
		o.route:gain_control ():set_value (ARDOUR.DSP.dB_to_coefficient (o.spec.gain_db or 0), NG)
	end
	REC.preview, REC.file, REC.started, REC.error, REC.mode = P, "", os.date ("%Y-%m-%dT%H:%M:%S"), "", "preview"
	REC.finalizer = type (c.finalizer) == "table" and c.finalizer or nil
	rec_link ()
	for _, t in pairs (REC.tracks) do t.route:rec_enable_control ():set_value (1, NG) end
	if BACKING_TAKE then BACKING_TAKE (true, false) end
	if Session:transport_rolling () then
		Session:request_stop (false, false, ARDOUR.TransportRequestSource.TRS_UI)
		ARDOUR.LuaAPI.usleep (400000)
	end
	Session:request_locate (0, false, ARDOUR.LocateTransportDisposition.MustStop, ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep (math.floor ((tonumber (c.settle) or 0.15) * 1000000))
	Session:maybe_enable_record (false)
	Session:request_roll (ARDOUR.TransportRequestSource.TRS_UI)
	for _, pl in ipairs (P.players) do                 -- les lecteurs MIDI partent avec le transport
		-- LA MÉMOIRE DE L'INSTANCE D'AUJOURD'HUI (2026-11-19, plantage 0xC0000005 sous Windows) : armer la piste peut faire
		-- REMPLACER l'instance du lecteur par Ardour (sa configuration d'E/S) ; la mémoire partagée gardée au montage était
		-- alors libérée, et y écrire au départ du transport tuait le moteur (Linux survivait par chance). On la relit ici, et
		-- on y réécrit la phrase : celle de l'ancienne instance est perdue avec elle. Comme drums_shm/std_shm, jamais gardée.
		local shm = pl.proc:to_insert ():plugin (0):to_luaproc ():shmem ()
		local a = shm:to_int (0):array ()
		local nev = math.min (#pl.ev, 32768)
		for k = 1, nev do
			local ea = 64 + (k - 1) * 4
			a[ea + 1], a[ea + 2], a[ea + 3], a[ea + 4] = pl.ev[k][1], pl.ev[k][2], pl.ev[k][3], pl.ev[k][4]
		end
		a[17] = nev
		a[2] = 1
		shm:atomic_set_int (0, shm:atomic_get_int (0) + 1)
	end
	P.until_s = now_s () + len + (tonumber (c.tail) or 5.0)
	if P.bench then
		for _, ins in ipairs (P.bench) do ins:clear_stats () end   -- le compte part du départ du transport
		-- le rendu en QUARTS : trois passes allumées, puis une passe ÉTEINTE (bench_off) — ce que le bloc coûte en bypass
		P.bench_step, P.bench_runs = len / 4, {}
		P.bench_at = now_s () + P.bench_step
	end
	REC.on, REC.pos, REC.pos_at = true, -1, now_s ()
	log (string.format ("écoute : scène %s, %.1f s + %.1f s de queue, %s%s", tostring (c.scene), len, tonumber (c.tail) or 5.0,
		src and ("entrée " .. src) or (#P.service .. " piste(s) de service"),
		(c.midi or c.midis) and " (phrase MIDI)" or ""))
	end)
	xr_release ()
	if not ok then error (err, 0) end
end

-- LE RENDU D'UN BLOC DE SERVICE (golem « Listen » sur une boîte à rythmes, un standard, un kit) : des phrases MIDI
-- jouées dans les pistes VIVANTES des services — `chains` « Drums|Standard Keys… », `midis` leurs fichiers, dans le même
-- ordre. Le bridge a posé les instruments (op load) et vérifié que rien ne joue. Le lecteur de phrase est posé en tête
-- de chaque piste ; leurs sorties sont débranchées de la carte et enregistrées.
local function preview_service (c)
	local names, files = {}, {}
	for n in tostring (c.chains):gmatch ("[^|]+") do names[#names + 1] = n end
	for f in tostring (c.midis or ""):gmatch ("[^|]+") do files[#files + 1] = f end
	local P = { seq = c.seq, scene = c.scene, out = c.out, outs = {}, keys = {}, players = {}, service = {} }
	local parts = STD_PARTS and STD_PARTS () or {}
	local len, rate = 0, Session:nominal_sample_rate ()
	local function give_up (why)
		for _, pl in ipairs (P.players) do pcall (function () pl.route:remove_processor (pl.proc, nil, true) end) end
		return preview_fail (c, why)
	end
	for k, name in ipairs (names) do
		local r
		if name == "Drums" then r = DRUMS_ROUTE and DRUMS_ROUTE ()
		else
			local id = name:match ("^Standard (%a+)$")
			r = id and parts[id:lower ()] and parts[id:lower ()].route
		end
		local body = files[k] and read_file (files[k])
		if not r or not body then return give_up ("no instrument for " .. name .. " on this engine") end
		len = math.max (len, tonumber (body:match ("len%s+([%d%.]+)")) or 0)
		local ev = {}
		for a, b, ch, note, vel in body:gmatch ("\nn ([%d%.]+) ([%d%.]+) (%d+) (%d+) (%d+)") do
			ev[#ev + 1] = { math.floor (tonumber (a) * rate), 0x90 | (tonumber (ch) & 15), tonumber (note), tonumber (vel) }
			ev[#ev + 1] = { math.floor (tonumber (b) * rate), 0x80 | (tonumber (ch) & 15), tonumber (note), 0 }
		end
		table.sort (ev, function (x, y) if x[1] ~= y[1] then return x[1] < y[1] end return (x[2] & 0xF0) < (y[2] & 0xF0) end)
		local p = ARDOUR.LuaAPI.new_luaproc (Session, "golem Midiplay")
		if p:isnil () then return give_up ("golem Midiplay not found") end
		r:add_processor_by_index (p, 0, nil, true)
		local shm = p:to_insert ():plugin (0):to_luaproc ():shmem ()
		local a = shm:to_int (0):array ()
		local nev = math.min (#ev, 32768)
		for i = 1, nev do
			local ea = 64 + (i - 1) * 4
			a[ea + 1], a[ea + 2], a[ea + 3], a[ea + 4] = ev[i][1], ev[i][2], ev[i][3], ev[i][4]
		end
		a[17] = nev
		P.players[#P.players + 1] = { route = r, proc = p, ev = ev }
		P.service[#P.service + 1] = r
	end
	if #P.service == 0 then return give_up ("nothing to play") end
	return preview_go (c, P, len, nil)
end

local function preview_start (c)
	if REC.on or REC.stopping or REC.preview then return preview_fail (c, "a take or another render is running") end
	if (c.op or "render") ~= "render" then return preview_fail (c, "unknown preview op") end
	if c.tracks or not c.out then
		return preview_fail (c, "this kind of render is not on the Golem Engine yet")
	end
	if c.chains then return preview_service (c) end
	if not c.di and not c.midi then return preview_fail (c, "nothing to play") end
	local n = tonumber (tostring (c.chain or ""):match ("Input (%d+)")) or 1
	local src = "in" .. n
	local P = { seq = c.seq, scene = c.scene, out = c.out, input = n, outs = {}, keys = {}, players = {} }
	for name, spec in pairs (RIG.specs) do
		local r = RIG.routes[name]
		if r and spec.out and spec.mixer == src then P.outs[#P.outs + 1] = { route = r, spec = spec } end
	end
	if #P.outs == 0 then return preview_fail (c, "this lane is not on the rig") end
	local len
	if c.midi then
		-- LA PHRASE MIDI : `len <s>`, `n début fin canal note vélocité`, `c temps statut canal d1 d2` (secondes)
		local body = read_file (c.midi)
		if not body then return preview_fail (c, "MIDI reference not readable") end
		len = tonumber (body:match ("len%s+([%d%.]+)")) or 0
		local rate, ev = Session:nominal_sample_rate (), {}
		for a, b, ch, note, vel in body:gmatch ("\nn ([%d%.]+) ([%d%.]+) (%d+) (%d+) (%d+)") do
			ev[#ev + 1] = { math.floor (tonumber (a) * rate), 0x90 | (tonumber (ch) & 15), tonumber (note), tonumber (vel) }
			ev[#ev + 1] = { math.floor (tonumber (b) * rate), 0x80 | (tonumber (ch) & 15), tonumber (note), 0 }
		end
		for a, st, ch, d1, d2 in body:gmatch ("\nc ([%d%.]+) (%d+) (%d+) (%d+) (%d+)") do
			ev[#ev + 1] = { math.floor (tonumber (a) * rate), (tonumber (st) & 0xF0) | (tonumber (ch) & 15), tonumber (d1), tonumber (d2) }
		end
		table.sort (ev, function (x, y) if x[1] ~= y[1] then return x[1] < y[1] end return (x[2] & 0xF0) < (y[2] & 0xF0) end)
		if #ev == 0 then return preview_fail (c, "MIDI reference is empty") end
		local tracks = {}                              -- les pistes MIDI de la lane : la sienne, ou celles de ses instruments
		for name, spec in pairs (RIG.specs) do
			local r = RIG.routes[name]
			if r and spec.kind == "midi" then
				local mine = spec.mixer == src
				for _, o in ipairs (P.outs) do
					for _, f in ipairs (o.spec.from or {}) do if f == name then mine = true end end
				end
				if mine then tracks[#tracks + 1] = { route = r, spec = spec } end
			end
		end
		if #tracks == 0 then return preview_fail (c, "this lane has no MIDI track") end
		for _, tk in ipairs (tracks) do
			local p = ARDOUR.LuaAPI.new_luaproc (Session, "golem Midiplay")
			if p:isnil () then return preview_fail (c, "golem Midiplay not found") end
			tk.route:add_processor_by_index (p, 0, nil, true)   -- EN TÊTE : devant la zone, l'arpégiateur et l'instrument
			local shm = p:to_insert ():plugin (0):to_luaproc ():shmem ()
			local a = shm:to_int (0):array ()
			local nev = math.min (#ev, 32768)
			for k = 1, nev do
				local ea = 64 + (k - 1) * 4
				a[ea + 1], a[ea + 2], a[ea + 3], a[ea + 4] = ev[k][1], ev[k][2], ev[k][3], ev[k][4]
			end
			a[17] = nev
			set_params ({ proc = p, spec = { id = "preview" } }, { { pid = "ch", label = "Channel", value = (tk.spec.midi and tk.spec.midi.channel) or 0 } })
			P.players[#P.players + 1] = { route = tk.route, proc = p, ev = ev }
		end
	else
		local f = io.open (c.di, "rb")
		if not f then return preview_fail (c, "reference DI not readable") end
		f:close ()
		for name, spec in pairs (RIG.specs) do          -- la piste d'entrée de la lane
			if spec.input == n and spec.kind ~= "midi" and RIG.routes[name] then P.in_route = RIG.routes[name] end
		end
		if not P.in_route then return preview_fail (c, "this lane has no audio input") end
		P.di = first (Session:new_audio_track (1, 1, ARDOUR.RouteGroup (), 1, "golem:preview:di", ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true))
		P.di:input ():disconnect_all (); P.di:output ():disconnect_all ()
		local reg = ARDOUR.LuaAPI.place_audio_file (Session, P.di, c.di, 0)
		if reg:isnil () then
			REC.preview = P; pcall (preview_restore); REC.preview = nil
			return preview_fail (c, "reference DI could not be placed")
		end
		len = reg:length ():samples () / Session:nominal_sample_rate ()
		local di_out = P.di:output ():audio (0):name ()
		P.in_route:input ():disconnect_all ()
		P.in_route:input ():audio (0):connect (di_out)
		for _, b in pairs (RIG.blocks) do               -- la clé d'un gate écoute la DI jouée, pas la carte
			if b.spec.key_input == n and b.proc:to_insert ():has_sidechain () then
				local sc = b.proc:to_insert ():sidechain_input ()
				for ch = 0, sc:n_ports ():n_audio () - 1 do sc:audio (ch):disconnect_all (); sc:audio (ch):connect (di_out) end
				P.keys[#P.keys + 1] = { proc = b.proc }
			end
		end
	end
	return preview_go (c, P, len, src)
end

-- l'inventaire des plugins qu'on peut héberger, les vrais paramètres d'une instance, son état natif (pas ici)
HOST.list = function (c)
	write_file (ROOT .. "/presets/.vst-host-list.json", json_encode ({ seq = c.seq or "", plugins = HOST.scan () }))
end
HOST.params = function (c)
	local b = RIG.blocks[tostring (c.block or "")]
	local rows = {}
	if b then
		local pl = b.proc:to_insert ():plugin (0)
		for _, p in ipairs (plugin_params (pl)) do
			local _, t = pl:get_parameter_descriptor (p.port, ARDOUR.ParameterDescriptor ())
			local d = t[2]
			local v = ARDOUR.LuaAPI.get_processor_param (b.proc, p.i, true)
			local span = (p.upper - p.lower) ~= 0 and (p.upper - p.lower) or 1
			rows[#rows + 1] = { i = p.i, name = p.label, value = (v - p.lower) / span, display = string.format ("%.3g", v),
				step = (d.toggled and 1) or ((d.integer_step or d.enumeration) and 1 / span) or 0, toggle = d.toggled == true }
		end
	end
	write_file (ROOT .. "/presets/.vst-host-params.json", json_encode ({ seq = c.seq or "", found = b ~= nil, params = rows }))
end
-- L'ÉTAT NATIF d'un plugin hébergé : le moteur l'écrit comme un preset VST3 (« golem-state-<seq> », dans le dossier de
-- presets du plugin) et dit où ; le bridge le lit, le range au format du patch et retire le fichier.
HOST.state = function (c)
	local b = RIG.blocks[tostring (c.block or "")]
	local out = { seq = c.seq or "", found = b ~= nil }
	if b then
		local id = b.spec.plugin and b.spec.plugin.host and HOST.id_of (b.spec.plugin.host) or (b.spec.plugin and b.spec.plugin.vst3)
		local label = "golem-state-" .. tostring (c.seq or os.time ())
		local rec = id and b.proc:to_insert ():plugin (0):save_preset (label)
		if rec and (rec.uri or "") ~= "" then
			local info = HOST.info[id] or {}
			out.preset_label, out.uid, out.vendor, out.pname = label, id, info.vendor or "", info.pname or ""
		else
			out.error = "This plugin did not give its state (only VST3 plugins do on the Golem Engine)"
		end
	end
	write_file (ROOT .. "/presets/.vst-host-state.json", json_encode (out))
end

-- LE BANC DU PREMIER USAGE (golem bridge/plugin_trial.py) : sur un moteur À PART (carte factice), le plugin est posé
-- sur une piste, puis éteint et rallumé plusieurs fois. À chaque geste on mesure le temps que l'horloge audio a PERDU :
-- le temps écoulé moins les échantillons traités. Un plugin qui fige le moteur à l'allumage y laisse sa trace ; un
-- plugin qui le tue ne rend jamais de résultat — le bridge voit le processus mort.
HOST.trial = function (c)
	local out = tostring (c.out or "")
	local function say (t) write_file (out, json_encode (t)) end
	-- `lua` : un DSP Lua à la place d'un VST3 — le banc du banc y pose « golem Stall », qui fige le fil audio exprès
	local id = not c.lua and HOST.id_of (c.plugin)
	if not c.lua and not id then return say ({ error = "plugin not found" }) end
	local rate = Session:nominal_sample_rate ()
	local function lost (op)
		local t0, s0 = now_s (), AudioEngine:processed_samples ()
		op ()
		ARDOUR.LuaAPI.usleep (300000)
		return math.max (0, ((now_s () - t0) - (AudioEngine:processed_samples () - s0) / rate) * 1000)
	end
	local noise = math.max (lost (function () end), lost (function () end))
	if AudioEngine:processed_samples () == 0 then return say ({ error = "the test engine processed no audio" }) end
	local r = first (Session:new_audio_track (2, 2, ARDOUR.RouteGroup (), 1, "golem:trial", ARDOUR.PresentationInfo.max_order,
		ARDOUR.TrackMode.Normal, true))
	local p, worst, steps = nil, 0, {}
	local function step (name, op)
		say ({ step = name })                          -- la trace AVANT le geste : si le moteur meurt, on sait où
		local ms = lost (op)
		steps[#steps + 1] = { step = name, ms = math.floor (ms + 0.5) }
		if ms > worst then worst = ms end
	end
	step ("load", function ()
		if c.lua then p = ARDOUR.LuaAPI.new_luaproc (Session, tostring (c.lua))
		else p = ARDOUR.LuaAPI.new_plugin (Session, id, ARDOUR.PluginType.VST3, "") end
		if not p:isnil () then CHAIN.pre (r, p) end
	end)
	if not p or p:isnil () then return say ({ error = "plugin could not be loaded" }) end
	for i = 1, tonumber (c.cycles) or 4 do
		step ("off " .. i, function () p:to_insert ():enable (false) end)
		step ("on " .. i, function () p:to_insert ():enable (true) end)
	end
	step ("remove", function () r:remove_processor (p, nil, true) end)
	say ({ done = true, stall_ms = math.floor (worst + 0.5), noise_ms = math.floor (noise + 0.5), steps = steps })
end

-- les potards d'une CAPTURE PILOTABLE (golem docs/capture-module.md) : {block, values: {emplacement: 0..1}} — écrits
-- sur les contrôles « Control NN » du lecteur, sans rien recharger
HOST.capture_params = function (c)
	local b = RIG.blocks[tostring (c.block or "")]
	if not b or type (c.values) ~= "table" then return end
	local entries = {}
	for slot, v in pairs (c.values) do
		local i = tonumber (slot)
		if i and i >= 0 and i < 32 and type (v) == "number" and v >= 0 and v <= 1 then
			entries[#entries + 1] = { pid = "c" .. i, label = string.format ("Control %02d", i + 1), value = v }
		end
	end
	set_params (b, entries)
end

local ACTIONS = {
	capture_params = function (c) HOST.capture_params (c) end,
	plugin_trial = function (c) HOST.trial (c) end,
	vst_list = function (c) HOST.list (c) end,
	vst_params = function (c) HOST.params (c) end,
	vst_state = function (c) HOST.state (c) end,
	preview = function (c) preview_start (c) end,
	click = function (c) click_cmd (c) end,
	backing = function (c) backing_cmd (c) end,
	sample = function (c) SAMPLE.cmd (c) end,
	sample_preview = function (c) SAMPLE.preview_cmd (c) end,
	tuner = function (c) tuner_cmd (c) end,
	-- un réglage que le bridge pose pour un service (sous REAPER : un ExtState) — ici, l'entrée de l'accordeur
	extstate = function (c)
		if c.key == "tuner_in" then
			TUNER.input = math.floor (tonumber (c.value) or 1)
			tuner_arm ()
		else log ("extstate ignoré : " .. tostring (c.key)) end
	end,
	standard = function (c) std_cmd (c) end,
	drums = function (c) drums_cmd (c) end,
	-- `in_ms` : le DÉPART DIFFÉRÉ (le décompte du bloc Rec, ou le premier temps d'un morceau) — compté ici, pas dans le
	-- chemin de commande ; un arrêt pendant le décompte l'annule
	perf_rec = function (c)
		if c.on then
			local ms = tonumber (c.in_ms) or 0
			if ms > 0 and not REC.on and not REC.stopping then
				REC.start_at, REC.start_cmd = now_s () + ms / 1000, c
				log (string.format ("prise : départ dans %.0f ms", ms))
			else perf_start (c) end
		elseif REC.start_at then
			REC.start_at, REC.start_cmd = nil, nil
			log ("prise : départ différé annulé")
			perf_publish (false)
		else perf_stop () end
	end,
	plugins = function (c) inventory (c.want) end,
	audio_set = function (c) if c.buffer then set_buffer (c.buffer) end; write_file (STATUS, json_encode (status ())) end,
	ping = function (c) end,
	status = function (c) write_file (STATUS, json_encode (status ())) end,
	rig_recall = function (c)
		local plan = type (c.plan) == "table" and c.plan or nil
		if not plan then
			write_file (LIVEMAP, json_encode ({ preset = "", engine = "golem-engine", blocks = {} }))
			error ("plan moteur illisible : " .. tostring (c.plan))
		end
		-- UN RAPPEL PENDANT UNE PRISE : Ardour ne laisse pas refaire des routes en enregistrant (sidechain refusé, et le
		-- plantage ci-dessus). La prise se met en PAUSE — l'enregistrement coupé, le transport continue —, le rig est
		-- refait, la prise reprend : ses pistes portent alors plusieurs segments, à leur place dans le temps, que
		-- l'assembleur recolle. Le trou est celui pendant lequel le rig ne sonnait de toute façon pas.
		local paused = REC.on and Session:actively_recording ()
		if paused then
			Session:disable_record (false, true)
			local t0 = now_s ()
			while Session:actively_recording () and now_s () - t0 < 1.0 do ARDOUR.LuaAPI.usleep (20000) end
			log ("prise : en pause pour le rappel")
		end
		local okm, errm = xpcall (materialize, function (e)   -- la pile du montage, et le texte d'une exception C++
			local s = tostring (e)
			if type (e) == "userdata" then
				local okw, w = pcall (function () return e:what () end)
				if okw and w then s = "exception C++ : " .. tostring (w) end
			end
			return debug.traceback (s, 2)
		end, plan)
		xr_release ()                               -- même si le montage a échoué : le compteur ne reste jamais retenu
		if paused then
			Session:maybe_enable_record (false)
			log ("prise : reprise après le rappel")
		end
		if not okm then error (tostring (errm) .. " — montage : " .. tostring (MAT_STEP)) end
		RIG.verified_again = false
		RIG.verify_at = now_s () + 2.0             -- les plugins chargent leurs fichiers en différé (IR) : relire après
		RIG.midi_at = now_s () + 1.0               -- un synthé tout juste posé peut manquer son premier MIDI : renvoi
	end,
	scene_apply = function (c)
		local plan = type (c.plan) == "table" and c.plan or nil
		if not plan then error ("plan moteur illisible : " .. tostring (c.plan)) end
		if plan.preset ~= RIG.preset then error ("scène pour " .. tostring (plan.preset) .. ", rig = " .. tostring (RIG.preset)) end
		local missing = apply_state (plan)
		log ("scène appliquée SANS rebuild (" .. tostring (c.scene) .. (missing > 0 and (", " .. missing .. " route(s) absente(s)") or "") .. ")")
	end,
	stomp = function (c)
		for _, id in ipairs (c.ids or {}) do
			local b = RIG.blocks[id]
			if b then b.proc:to_insert ():enable (c.on and true or false) end
			local ir = RIG.blocks[id .. "~ir"]          -- le baffle par défaut d'une tête la suit au pied
			if ir then ir.proc:to_insert ():enable (c.on and true or false) end
		end
	end,
	-- les trims du mixer À CHAUD (un fader qu'on tire) : tous les niveaux à chaque fois, aucune route touchée d'autre
	mixer_apply = function (c)
		RIG.mixer = type (c.levels) == "table" and c.levels or {}
		local n = 0
		for name, spec in pairs (RIG.specs) do
			local r = RIG.routes[name]
			if r and spec.mixer then apply_out (r, spec); n = n + 1 end
		end
		service_mix ()
		log ("mixer : " .. n .. " route(s) de sortie")
	end,
	rig_verify = function (c) verify_files () end,
	peaks = function (c) peaks (c.clear == true) end,
	-- des messages MIDI écrits dans le plugin d'un bloc (une note pour l'entendre sans clavier : le banc, l'écoute)
	-- `route` : à l'ENTRÉE d'une piste MIDI (le chemin d'un clavier : zone, puis instrument) au lieu d'un plugin
	midi_send = function (c)
		if c.route then
			local r = RIG.routes[c.route]
			if not r then error ("midi_send : route inconnue " .. tostring (c.route)) end
			local mt = r:to_track ():to_midi_track ()
			local parser = ARDOUR.RawMidiParser ()
			for _, m in ipairs (c.msgs or {}) do
				parser:reset ()
				for _, byte in ipairs (m) do
					if parser:process_byte (byte) then
						mt:write_immediate_event (Evoral.EventType.MIDI_EVENT, parser:buffer_size (), parser:midi_buffer ())
					end
				end
			end
			return
		end
		local b = RIG.blocks[c.id or ""]
		if not b then error ("midi_send : bloc inconnu " .. tostring (c.id)) end
		midi_write (b.proc, c.msgs)
	end,
	audio_reset = function (c) audio_reset (); write_file (STATUS, json_encode (status ())) end,
	midi_reinit = function (c) midi_reinit () end,
	dump = function (c) dump () end,
	gapmeter = function (c) gapmeter (c) end,
	-- le banc des presets (golem tools/check-rig-materialize.py --render) : la session TELLE QUE LA SCÈNE L'A MONTÉE,
	-- sauvée sous un nom d'état (la session vivante n'en change pas) ; le banc la copie, y pose la DI (golem-place
	-- --disk --to-master) et l'exporte hors ligne. Le dump d'abord : il dit quelles routes lire et lesquelles sortent.
	snapshot = function (c)
		local name = tostring (c.name or "golem-snapshot"):gsub ("[^%w%-_]", "_")
		dump ()
		Session:save_state (name, false, false, false, false, false)
		write_file (SNAPSHOT, json_encode ({ name = name, dir = Session:path (), preset = RIG.preset or "", at = os.time () }))
		log ("  état « " .. name .. " » sauvé pour le banc")
	end,
	-- QUI COÛTE (diagnostic, 2026-11-13 : 92 % de charge DSP à 192 échantillons, des décrochages que REAPER n'a pas) :
	-- le temps de calcul de CHAQUE plugin, mesuré par Ardour (PluginInsert:get_stats, µs par cycle), route par route.
	dspstats = function (c)
		local out = { at = os.time (), buffer = Session:get_block_size (), routes = {} }
		for r in Session:get_routes ():iter () do
			local procs = {}
			local i = 0
			while true do
				local p = r:nth_processor (i)
				if p:isnil () then break end
				local ins = p:to_insert ()
				if not ins:isnil () then
					local ok, v = ins:get_stats (0, 0, 0, 0)
					procs[#procs + 1] = { name = p:display_name (), ok = ok and true or false, active = ins:enabled (),
						min = v and v[1] or 0, max = v and v[2] or 0, avg = v and v[3] or 0 }
					-- `clear` : les compteurs repartent de zéro — ils cumulent depuis leur dernière remise à zéro, et un
					-- plugin éteint garde sa vieille moyenne : pour mesurer UNE scène, vider, attendre, relire
					if c.clear then ins:clear_stats () end
				end
				i = i + 1
			end
			out.routes[#out.routes + 1] = { name = r:name (), active = r:active (), procs = procs }
		end
		write_file (ROOT .. "/presets/.engine-dspstats.json", json_encode (out))
		log ("  dspstats : " .. #out.routes .. " route(s)")
	end,
}

local function run (cmd)
	local f = ACTIONS[cmd.action or ""]
	if not f then
		log ("action inconnue ignorée : " .. tostring (cmd.action))
		return
	end
	-- la PILE avec l'erreur (2026-11-20, premier rappel sur une vraie carte sous Windows : « ÉCHEC rig_recall :
	-- userdata: 0000… » — une exception C++ que tostring ne lit pas, et aucune ligne pour la situer)
	local ok, err = xpcall (f, function (e)
		local s = tostring (e)
		if type (e) == "userdata" then
			local okw, w = pcall (function () return e:what () end)
			if okw and w then s = "exception C++ : " .. tostring (w) end
		end
		return debug.traceback (s, 2)
	end, cmd)
	if not ok then log ("ÉCHEC " .. tostring (cmd.action) .. " : " .. tostring (err)) end
end

-- ── démarrage ────────────────────────────────────────────────────────────────────────────────────────
-- la CARTE : le nom exact, sinon un nom contenu dans l'autre (le registre de golem dit « Universal Audio Volt 276 »,
-- le backend ALSA d'Ardour « Volt 276 »). Avant la session : la fréquence et le buffer s'y choisissent.
-- `list` : la liste où chercher (PortAudio sépare l'entrée et la sortie : enumerate_devices y est vide, 2026-11-20)
local function pick_device (be, list)
	if DEVICE == "" then return nil end
	local want, found = DEVICE:lower (), nil
	for d in (list or be:enumerate_devices ()):iter () do
		local n = d.name:lower ()
		if n == want then return d.name end
		if not found and (want:find (n, 1, true) or n:find (want, 1, true)) then found = d.name end
	end
	return found
end

local function open_session ()
	local be = AudioEngine:set_backend (BACKEND, "golem", "")
	assert (be and not be:isnil (), "backend " .. BACKEND)
	-- LE MIDI MATÉRIEL : le SÉQUENCEUR ALSA (partagé : le bridge garde ses ports), et AUCUN appareil ouvert au départ.
	-- Par défaut Ardour ouvre tout : la prise DIN de la carte (le pédalier, au bridge), les ports virtuels du bridge
	-- (« whammy », « input »). Seuls les claviers d'une lane MIDI s'ouvrent ensuite, un par un (midi_device_ports).
	local pick, want, fallback, first_real = nil, os.getenv ("GOLEM_ENGINE_MIDI"), nil, nil   -- un banc peut en forcer une
	for o in be:enumerate_midi_options ():iter () do
		local l = o:lower ()
		if want and o == want then pick = o; break end
		if not want and l:find ("sequencer", 1, true) then pick = o end
		if l == "none" or l:find ("no midi", 1, true) then fallback = o
		elseif not first_real then first_real = o end     -- hors ALSA (PortAudio, CoreAudio) : le MIDI du système
	end
	pick = pick or first_real or fallback
	if pick then
		be:set_midi_option (pick)
		local n = 0
		for d in be:enumerate_midi_devices ():iter () do
			be:set_midi_device_enabled (d.name, false); n = n + 1
		end
		log ("MIDI matériel du moteur : " .. pick .. " (" .. n .. " appareil(s), tous fermés au départ)")
	end
	BACKEND_PTR = be
	if DEVICE ~= "" then
		-- LE PILOTE (Windows, 2026-11-20) : PortAudio range les cartes par API hôte (ASIO, WASAPI, WDM-KS…) ; la carte
		-- n'est cherchée que parmi celles du pilote choisi. GOLEM_ENGINE_DRIVER s'il est donné, sinon ASIO (le pilote de
		-- la carte que golem règle pour REAPER), sinon le premier. ALSA n'a qu'un pilote : rien à choisir.
		if BACKEND:find ("PortAudio", 1, true) then
			local drivers, pickd, wantd = {}, nil, os.getenv ("GOLEM_ENGINE_DRIVER")
			for d in be:enumerate_drivers ():iter () do drivers[#drivers + 1] = d end
			for _, d in ipairs (drivers) do if wantd and d == wantd then pickd = d end end
			if not pickd then for _, d in ipairs (drivers) do if d == "ASIO" then pickd = d end end end
			pickd = pickd or drivers[1]
			if pickd then
				be:set_driver (pickd)
				log ("pilote audio : " .. pickd .. " (" .. table.concat (drivers, ", ") .. ")")
			end
		end
		local split = be:use_separate_input_and_output_devices ()
		local list = split and be:enumerate_input_devices () or nil
		local dev = pick_device (be, list)
		local out = split and pick_device (be, be:enumerate_output_devices ()) or dev
		if not dev or not out then
			local names = {}                         -- ce que le pilote propose : sans ça, rien ne disait quoi choisir
			for d in (list or be:enumerate_devices ()):iter () do names[#names + 1] = d.name end
			error ("carte introuvable pour « " .. DEVICE .. " » (ce pilote propose : " .. table.concat (names, ", ") .. ")")
		end
		if split then                                -- PortAudio : l'entrée et la sortie, la même carte (ASIO)
			be:set_input_device_name (dev)
			be:set_output_device_name (out)
		else
			be:set_device_name (dev)
		end
		be:set_sample_rate (48000)
		local cfg = read_json_early (AUDIO_CFG)
		-- le réglage du moteur (Dashboard) d'abord ; sinon celui que golem demande à la carte (Windows : Settings ▸ Audio,
		-- passé par l'adaptateur) — sans rien, PortAudio ouvrait l'ASIO à 1024 échantillons (2026-11-20)
		local buf = (cfg and cfg.buffer) or tonumber (os.getenv ("GOLEM_ENGINE_BUFFER"))
		if buf then be:set_buffer_size (buf) end
		log ("carte : " .. dev .. " (demandée : " .. DEVICE .. ")" .. (buf and (", buffer " .. buf) or ""))
	end
	local cfg = ARDOUR.config ()
	cfg:set_input_auto_connect (ARDOUR.AutoConnectOption.ManualConnect)
	cfg:set_output_auto_connect (ARDOUR.AutoConnectOption.ManualConnect)
	cfg:set_monitoring_model (ARDOUR.MonitorModel.SoftwareMonitoring)   -- A0 : sans lui, une piste n'entend pas son entrée
	local name = "golem"
	local s
	-- LA CARTE PEUT ÊTRE ENCORE TENUE : à la bascule depuis REAPER (System ▸ Audio Engine), il met quelques secondes à la
	-- rendre — « Failed to open audio device », deux arrêts du moteur avant le bon départ, et une alerte dans Health
	-- (mesuré au rack le 2026-11-17). On réessaie pendant 12 s avant de renoncer.
	local t_open = ARDOUR.LuaAPI.monotonic_time ()
	while true do
		local f = io.open (SESSION_DIR .. "/" .. name .. ".ardour", "r")
		if f then
			f:close ()
			s = load_session (SESSION_DIR, name)
		else
			s = create_session (SESSION_DIR, name, 48000)
		end
		if s or DEVICE == "" or (ARDOUR.LuaAPI.monotonic_time () - t_open) / 1e6 > 12 then break end
		log ("  carte pas encore libre (" .. tostring (AudioEngine:get_last_backend_error ()) .. ") — nouvel essai")
		ARDOUR.LuaAPI.usleep (1000000)
	end
	assert (s, "session " .. SESSION_DIR .. " : " .. tostring (AudioEngine:get_last_backend_error ()))
	-- LA SESSION PEUT S'OUVRIR SANS QUE LE MOTEUR TOURNE : relancé pendant que l'ancien tenait encore la carte, il rendait
	-- une session, mais aucune piste ne pouvait y être créée — plus de vumètres, de métronome, de looper ni de pistes
	-- de prise jusqu'au redémarrage suivant (rack, 2026-11-17 16:00 : huit « ÉCHEC » d'affilée). On attend qu'il tourne,
	-- en le relançant ; au bout de 12 s on s'arrête net : le bridge relance un moteur entier.
	local t_run = ARDOUR.LuaAPI.monotonic_time ()
	while not AudioEngine:running () do
		if (ARDOUR.LuaAPI.monotonic_time () - t_run) / 1e6 > 12 then
			error ("le moteur audio ne démarre pas : " .. tostring (AudioEngine:get_last_backend_error ()))
		end
		log ("  moteur audio pas encore lancé — nouvel essai")
		ARDOUR.LuaAPI.usleep (1000000)
		pcall (function () AudioEngine:start (false) end)
	end
end

local function activate_osc ()
	-- un moteur de BANC lancé à côté de celui qui joue (l'essai d'un plugin) n'ouvre pas de surface OSC : il prendrait
	-- le port suivant, et le moteur du rack, relancé pendant l'essai, ne retrouverait pas le sien
	if os.getenv ("GOLEM_ENGINE_NO_OSC") == "1" then return false end
	local m = ARDOUR.ControlProtocolManager.manager ()
	for p in m:control_protocol_infos ():iter () do
		if p.name:find ("OSC") then
			return m:activate (p, "") == 0
		end
	end
	return false
end

-- UNE SESSION RELUE PEUT PORTER LES ROUTES DE LA FOIS D'AVANT : arrêté proprement, le moteur enregistre sa session — ses
-- pistes de service et de prise avec. Au démarrage suivant leurs ports existent déjà (« Port already exists ») et
-- AUCUNE piste de service ne se crée : plus de vumètres, de métronome, de looper ni de pistes de prise (rack,
-- 2026-11-17, 16:00 et 20:33 — huit « ÉCHEC » d'affilée). Tout ce que la session contient est donc retiré avant de
-- poser quoi que ce soit : le moteur repart d'une session vide, à chaque fois.
local function purge_routes ()
	local rl, n = ARDOUR.RouteListPtr (), 0
	for r in Session:get_routes ():iter () do
		if not r:is_master () and not r:is_monitor () and not r:is_auditioner () then rl:push_back (r) end
	end
	for r in rl:iter () do
		r:input ():disconnect_all ()
		r:output ():disconnect_all ()
	end
	if rl:size () > 0 then ARDOUR.LuaAPI.usleep (120000) end
	for r in rl:iter () do
		GONE = GONE + 1
		n = n + 1
		r:set_name ("golem-gone-" .. GONE)                -- un nom unique libère les noms de ports tout de suite
	end
	if n > 0 then
		Session:remove_routes (rl)
		log ("session relue : " .. n .. " route(s) de la fois d'avant retirée(s)")
	end
	rl = nil
	collectgarbage (); collectgarbage ()
end

local function main ()
	open_session ()
	local okp, errp = pcall (purge_routes)
	if not okp then log ("ÉCHEC nettoyage de la session : " .. tostring (errp)) end
	pcall (apply_audio_cfg)
	pcall (function ()
		-- ce que la carte offre, vu par le moteur : le battement le publie (Soundcard, lot A2.3)
		N_IN, N_OUT = #physical (true), #physical (false)
		local function mports (flag)
			local out = array ()
			local _, t = AudioEngine:get_backend_ports ("", ARDOUR.DataType ("midi"), ARDOUR.PortFlags.IsPhysical | flag, C.StringVector ())
			for p in t[4]:iter () do out[#out + 1] = AudioEngine:get_pretty_name_by_name (p) ~= "" and AudioEngine:get_pretty_name_by_name (p) or p end
			return out
		end
		MIDI_IN, MIDI_OUT = mports (ARDOUR.PortFlags.IsOutput), mports (ARDOUR.PortFlags.IsInput)
		DEVICE_OPEN = AudioEngine:current_backend_name () .. (DEVICE ~= "" and (" · " .. DEVICE) or "")
	end)
	local okm, errm = pcall (ensure_input_meters)
	if not okm then log ("ÉCHEC vumètres d'entrée : " .. tostring (errm)) end
	local okc, errc = pcall (function () ensure_click (); click_apply () end)
	if not okc then log ("ÉCHEC métronome : " .. tostring (errc)) end
	local okd, errd = pcall (ensure_drums)
	if not okd then log ("ÉCHEC boîte à rythmes : " .. tostring (errd)) end
	local oks, errs = pcall (ensure_std)
	if not oks then log ("ÉCHEC standards : " .. tostring (errs)) end
	local okb, errb = pcall (ensure_backing)
	if not okb then log ("ÉCHEC backing : " .. tostring (errb)) end
	local oksa, errsa = pcall (SAMPLE.ensure)
	if not oksa then log ("ÉCHEC samples : " .. tostring (errsa)) end
	pcall (HOST.list, { seq = "boot" })
	local oklo, errlo = pcall (LOOPER.ensure)
	if not oklo then log ("ÉCHEC looper : " .. tostring (errlo)) end
	local okrp, errrp = pcall (ensure_rec_pool)       -- EN DERNIER : les strips des services gardent leur rang
	if not okrp then log ("ÉCHEC pistes de prise : " .. tostring (errrp)) end
	local okck, errck = pcall (MIDICLOCK.ensure)          -- après tout le reste : elle ne déplace le strip de personne
	if not okck then log ("ÉCHEC horloge MIDI : " .. tostring (errck)) end
	local osc = activate_osc ()
	-- une commande posée AVANT ce process n'est jamais exécutée (même règle que golem_watch REAPER) : accusée seulement
	local last, last_raw = 0, nil
	local next_beat, next_clock, next_click = 0, 0, 0
	local s = read_file (CMD)
	if s then
		local ok, c = pcall (json_decode, s)
		if ok and type (c) == "table" and c.seq then
			last = c.seq
			write_file (ACK, json_encode ({ seq = last, t = now_s () }))
			-- Windows : AUSSI l'accusé PAR SÉQUENCE que la file du bridge y lit (bridge/commands._ack_path) — voir la boucle
			if package.config:sub (1, 1) == "\\" then
				write_file (ACK .. "." .. string.format ("%.0f", last), json_encode ({ seq = last, t = now_s () }))
			end
		end
	end
	-- la ligne que monitors._watch_started_since cherche : le veilleur lit ses commandes
	log ("démarré. surveille " .. CMD .. " (osc " .. tostring (osc) .. ", " .. BACKEND .. ")")
	XR.base = 0
	xr_release ()                                    -- le démarrage est fini : ses décrochages ne sont pas ceux du jeu
	xr_tick ()
	write_file (STATUS, json_encode (status ()))
	while true do
		xr_tick ()
		local raw = read_file (CMD)
		if raw and raw ~= "" and raw ~= last_raw then
			last_raw = raw                            -- un rappel emporte son plan : ne pas le redécoder à chaque tick
			local ok, c = pcall (json_decode, raw)
			if ok and type (c) == "table" and c.seq and c.seq ~= last then
				last = c.seq
				write_file (ACK, json_encode ({ seq = last, t = now_s () }))
				-- WINDOWS (2026-11-19, portage) : la file de commandes du bridge y lit un accusé PAR SÉQUENCE
				-- (.command-ack.json.<seq>, bridge/commands._ack_path — le protocole du veilleur REAPER, né de ce que
				-- rename() n'y remplace pas un fichier). Sans lui, chaque commande paraissait jamais lue : la file
				-- attendait _HUNG_S (30 s) avant d'envoyer la suivante.
				if package.config:sub (1, 1) == "\\" then
					write_file (ACK .. "." .. string.format ("%.0f", last), json_encode ({ seq = last, t = now_s () }))
				end
				run (c)
			end
		end
		if now_s () >= next_beat then                -- le battement : le bridge sait que le veilleur vit (talking)
			next_beat = now_s () + 2.0
			pcall (MIDICLOCK.link)                        -- un clavier ouvert ou rouvert depuis : l'horloge le rejoint
			pcall (GRAVE.sweep)                           -- les samplers retirés depuis plus de GRAVE.secs secondes
			pcall (function () write_file (STATUS, json_encode (status ())) end)
		end
		if now_s () >= next_clock then               -- le témoin du thread audio, au schéma de golem_clock.lua
			next_clock = now_s () + 1.0
			pcall (function () write_file (CLOCK, json_encode ({ ticks = AudioEngine:processed_samples (), t = now_s (), on = true })) end)
		end
		do
			local ok, err = pcall (perf_tick)
			if not ok then log ("ÉCHEC prise : " .. tostring (err)) end
		end
		if now_s () >= next_click then               -- l'état du métronome et ses témoins, deux fois par seconde
			next_click = now_s () + 0.5
			pcall (click_publish)
			pcall (drums_publish)
			pcall (std_publish)
		end
		pcall (tuner_publish)
		do
			local ok, err = pcall (backing_tick)
			if not ok then log ("ÉCHEC backing : " .. tostring (err)) end
			ok, err = pcall (SAMPLE.tick)
			if not ok then log ("ÉCHEC samples : " .. tostring (err)) end
			ok, err = pcall (LOOPER.tick)
			if not ok then log ("ÉCHEC looper : " .. tostring (err)) end
		end
		if RIG.midi_at and now_s () >= RIG.midi_at then
			RIG.midi_at = nil
			pcall (function ()
				for _, bk in pairs (RIG.blocks) do
					if bk.spec.midi then send_midi (bk, bk.spec.midi, true) end
				end
			end)
		end
		if RIG.verify_at and now_s () >= RIG.verify_at then
			RIG.verify_at = nil
			local ok, err = pcall (verify_files)
			if not ok then log ("ÉCHEC vérif fichiers : " .. tostring (err)) end
		end
		ARDOUR.LuaAPI.usleep (TICK_US)
	end
end

local ok, err = xpcall (main, debug.traceback)
if not ok then
	log ("ARRÊT : " .. tostring (err))
	if quit then quit () end                       -- luasession : pas d'os.exit, quit() ferme le process
end
