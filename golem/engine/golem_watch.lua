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
local HERE = debug.getinfo (1, "S").source:match ("^@(.*)/[^/]*$") or "."
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
	os.rename (tmp, path)
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

local function status ()
	return {
		engine = "golem-engine", backend = AudioEngine:current_backend_name (),
		running = AudioEngine:running (), sample_rate = Session:nominal_sample_rate (),
		buffer = Session:get_block_size (),
		dsp_load = AudioEngine:get_dsp_load (), xruns = Session:get_xrun_count (),
		tracks = Session:get_tracks ():size (), rolling = Session:transport_rolling (), at = os.time (),
		device = DEVICE_OPEN, inputs = N_IN, outputs = N_OUT, midi_in = MIDI_IN, midi_out = MIDI_OUT,
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
local RIG = { preset = nil, routes = {}, order = {}, blocks = {}, nch = {} }   -- blocks[id] = {route, proc, ssid, fx, spec}

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
				be:set_midi_device_enabled (name, true)
				local got = {}
				for p in pairs (physical_midi ()) do if not before[p] then got[#got + 1] = p end end
				MIDI_PORTS[name] = got
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
	return tostring (ARDOUR.LuaAPI.get_plugin_insert_property (b.proc:to_insert (), prop) or "") == path
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

local function set_params (b, entries)
	local proc = b.proc
	local params = plugin_params (proc:to_insert ():plugin (0))
	for _, e in ipairs (entries or {}) do
		local p = find_param (params, e.label)
		if not p then
			log ("  param " .. tostring (b.spec.id) .. "." .. tostring (e.pid) .. " : label « " .. tostring (e.label) .. " » introuvable")
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
	end
	log ("  entrées : " .. #ins .. " sur la carte, vumètres golem:in1.." .. INPUT_METERS)
end

local function clear_routes ()
	local rl = ARDOUR.RouteListPtr ()
	for r in Session:get_routes ():iter () do
		if not r:is_master () and not r:is_monitor () and not r:is_auditioner ()
		   and not r:name ():find ("^golem:in%d") then rl:push_back (r) end
	end
	-- RENOMMÉES AVANT D'ÊTRE RETIRÉES : la surface OSC garde ses strips (shared_ptr) jusqu'à son prochain recalcul de
	-- banques ; la route survit, ses PORTS aussi, et recréer une route du même nom échouait (« Port already exists »,
	-- un rebuild sur deux en éditant un patch, mesuré 2026-11-13). Un nom unique libère les noms de ports tout de suite
	-- (set_name est virtuel : une piste renomme aussi sa playlist).
	for r in rl:iter () do
		GONE = GONE + 1
		r:set_name ("golem-gone-" .. GONE)
	end
	if rl:size () > 0 then Session:remove_routes (rl) end
	-- LES RÉFÉRENCES LÂCHÉES TOUT DE SUITE : le Lua tenait encore les routes et les plugins supprimés (shared_ptr) ; ils
	-- n'étaient détruits qu'au passage du ramasse-miettes, n'importe quand plus tard (pendant le décodage d'une commande),
	-- alors que la surface OSC ou le fil audio pouvaient encore les voir. Les scripts d'Ardour font ainsi.
	rl = nil
	RIG = { preset = nil, routes = {}, order = {}, blocks = {}, nch = {} }
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
		p = ARDOUR.LuaAPI.new_plugin (Session, spec.plugin.vst3, ARDOUR.PluginType.VST3, "")
	else
		p = ARDOUR.LuaAPI.new_luaproc (Session, spec.plugin.lua)
	end
	if p:isnil () then
		log ("  bloc " .. tostring (spec.id) .. " : plugin absent " .. tostring (spec.plugin.lv2 or spec.plugin.vst3 or spec.plugin.lua))
		return nil
	end
	nch = CHAIN.add (r, p, nch or 1)                -- en fin de chaîne ; un plugin stéréo passe la route en stéréo
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
local function set_tempo (bpm)
	bpm = tonumber (bpm)
	if not bpm or bpm < 20 or bpm > 400 then return end
	local cur = Temporal.TempoMap.read ():quarters_per_minute_at (Temporal.timepos_t (0))
	if math.abs (cur - bpm) < 0.01 then return end
	local tm = Temporal.TempoMap.write_copy ()
	tm:set_tempo (Temporal.Tempo (bpm, bpm, 4), Temporal.timepos_t (0))
	Temporal.TempoMap.update (tm)
	log ("  tempo <- " .. bpm .. " BPM")
end

local function apply_state (plan)
	-- l'état d'une scène sur un rig déjà posé : enable, mute, paramètres, gains. Aucun plugin ajouté ni retiré.
	set_tempo (plan.bpm)
	local missing = 0
	for _, spec in ipairs (plan.tracks or {}) do
		local r = RIG.routes[spec.name]
		if not r then
			missing = missing + 1
		else
			r:mute_control ():set_value (spec.mute and 1 or 0, NG)
			r:gain_control ():set_value (ARDOUR.DSP.dB_to_coefficient (spec.gain_db or 0), NG)
			-- le gain du merge AVANT ses plugins (le trim d'Ardour est en tête de route ; REAPER : un Volume Adjustment en
			-- tête de chaîne), le niveau de scène sur le fader (gain_db) — golem/bridge ardour_plan.py
			r:trim_control ():set_value (ARDOUR.DSP.dB_to_coefficient (spec.trim_db or 0), NG)
			for _, bs in ipairs (spec.blocks or {}) do
				local b = RIG.blocks[bs.id]
				if b then
					b.spec = bs
					set_params (b, bs.params)
					b.proc:to_insert ():enable (bs.enabled ~= false)
				end
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
			local p = find_param (pl, k.label)
			if p then params[k.pid] = { p = p.i, pmin = p.lower, pmax = p.upper } end
		end
		blocks[id] = { track = b.ssid, fx = b.fx, type = b.spec.type, params = params }
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

local function materialize (plan)
	local t0 = now_s ()
	clear_routes ()
	RIG.preset = plan.preset
	local ins, outs = physical (true), physical (false)
	local silent = no_output ()
	log ("  carte : " .. #ins .. " entrée(s), " .. #outs .. " sortie(s) physiques" .. (silent and " — ESSAI SILENCIEUX" or ""))
	for _, spec in ipairs (build_order (plan.tracks)) do
		local r = new_route (spec)
		RIG.routes[spec.name] = r
		RIG.order[#RIG.order + 1] = spec.name
		local ssid = INPUT_METERS + #RIG.order       -- l'ordre des strips de la surface OSC : golem:in1..3 d'abord
		local k = 0
		local nch = spec.kind == "midi" and 2 or r:input ():n_ports ():n_audio ()
		if nch < 1 then nch = 1 end
		for _, bs in ipairs (spec.blocks or {}) do
			local p, n2 = add_block (r, bs, nch)
			if n2 then nch = n2 end                    -- un plugin absent ne change rien aux canaux
			if p and bs.init then set_params ({ proc = p, spec = bs }, bs.init) end   -- golem_rig FX_INIT
			-- LA CLÉ d'un gate à clé (Met, le gate de golem-fx ; golem docs/golem-fx-sheet.md §4) : le sidechain du
			-- plugin, relié à l'entrée de la carte de la lane — le DI brut, pas ce qui sort de l'ampli. Sans clé reliée,
			-- Met écoute son entrée principale.
			if p and bs.key_input then
				if not r:add_sidechain (p) then
					log ("  ⚠ " .. tostring (bs.id) .. " : sidechain refusé (prise en cours ?) — le gate écoute son entrée")
				elseif not ins[bs.key_input] then
					log ("  ⚠ " .. tostring (bs.id) .. " : pas d'entrée " .. tostring (bs.key_input) .. " sur la carte pour la clé")
				else
					local sc = p:to_insert ():sidechain_input ()
					local n = sc:n_ports ():n_audio ()
					for c = 0, n - 1 do
						local rc = sc:audio (c):connect (ins[bs.key_input])
						if rc ~= 0 then log ("  lien de clé refusé " .. tostring (bs.id) .. " (" .. tostring (rc) .. ")") end
					end
					log ("  " .. tostring (bs.id) .. " : clé <- entrée " .. tostring (bs.key_input) .. " (" .. n .. " canal/canaux)")
				end
			end
			if p and bs.drumtrans and not write_drumtrans (p, bs.drumtrans) then
				log ("  ⚠ " .. tostring (bs.id) .. " : table du traducteur non posée (notes du module telles quelles)")
			end
			if p then
				RIG.blocks[bs.id] = { route = r, proc = p, ssid = ssid, fx = k, spec = bs }
				k = k + 1
			end
		end
		RIG.nch[spec.name] = math.max (nch, r:output ():n_ports ():n_audio ())
		if RIG.nch[spec.name] > 1 then log ("  " .. spec.name .. " : stéréo (" .. RIG.nch[spec.name] .. " canaux)") end
		local function link (port, other)
			local rc = port:connect (other)
			if rc ~= 0 then log ("  lien refusé " .. port:name () .. " -> " .. tostring (other) .. " (" .. tostring (rc) .. ")") end
		end
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
		if spec.kind == "midi" then
			local dev = spec.midi and spec.midi.device
			local ports = midi_device_ports (dev)
			if #ports == 0 then log ("  " .. spec.name .. " : clavier « " .. tostring (dev) .. " » absent — piste muette") end
			for _, p in ipairs (ports) do link (r:input ():midi (0), p) end
		elseif spec.input then
			if ins[spec.input] then link (r:input ():audio (0), ins[spec.input])
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
	apply_state (plan)
	write_livemap ()
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
					expected = path:match ("[^/]+$") or path }
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
		tracks[#tracks + 1] = { ssid = INPUT_METERS + i, name = name, safety = safety, mute = r:mute_control ():get_value () > 0.5,
			gain_db = ARDOUR.DSP.accurate_coefficient_to_dB (r:gain_control ():get_value ()),
			trim_db = ARDOUR.DSP.accurate_coefficient_to_dB (r:trim_control ():get_value ()),
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
		blocks[id] = { ssid = b.ssid, fx = b.fx, enabled = pi:enabled (), params = vals, key = key }
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

local ACTIONS = {
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
		materialize (plan)
		RIG.verified_again = false
		RIG.verify_at = now_s () + 2.0             -- les plugins chargent leurs fichiers en différé (IR) : relire après
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
		end
	end,
	rig_verify = function (c) verify_files () end,
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
					procs[#procs + 1] = { name = p:display_name (), ok = ok and true or false,
						min = v and v[1] or 0, max = v and v[2] or 0, avg = v and v[3] or 0 }
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
	local ok, err = pcall (f, cmd)
	if not ok then log ("ÉCHEC " .. tostring (cmd.action) .. " : " .. tostring (err)) end
end

-- ── démarrage ────────────────────────────────────────────────────────────────────────────────────────
-- la CARTE : le nom exact, sinon un nom contenu dans l'autre (le registre de golem dit « Universal Audio Volt 276 »,
-- le backend ALSA d'Ardour « Volt 276 »). Avant la session : la fréquence et le buffer s'y choisissent.
local function pick_device (be)
	if DEVICE == "" then return nil end
	local want, found = DEVICE:lower (), nil
	for d in be:enumerate_devices ():iter () do
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
	local pick, want, fallback = nil, os.getenv ("GOLEM_ENGINE_MIDI"), nil   -- un banc peut en forcer une
	for o in be:enumerate_midi_options ():iter () do
		local l = o:lower ()
		if want and o == want then pick = o; break end
		if not want and l:find ("sequencer", 1, true) then pick = o end
		if l == "none" or l:find ("no midi", 1, true) then fallback = o end
	end
	pick = pick or fallback
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
		local dev = pick_device (be)
		if not dev then error ("carte introuvable pour « " .. DEVICE .. " »") end
		be:set_device_name (dev)
		be:set_sample_rate (48000)
		local cfg = read_json_early (AUDIO_CFG)
		if cfg and cfg.buffer then be:set_buffer_size (cfg.buffer) end
		log ("carte : " .. dev .. " (demandée : " .. DEVICE .. ")")
	end
	local cfg = ARDOUR.config ()
	cfg:set_input_auto_connect (ARDOUR.AutoConnectOption.ManualConnect)
	cfg:set_output_auto_connect (ARDOUR.AutoConnectOption.ManualConnect)
	cfg:set_monitoring_model (ARDOUR.MonitorModel.SoftwareMonitoring)   -- A0 : sans lui, une piste n'entend pas son entrée
	local name = "golem"
	local s
	local f = io.open (SESSION_DIR .. "/" .. name .. ".ardour", "r")
	if f then
		f:close ()
		s = load_session (SESSION_DIR, name)
	else
		s = create_session (SESSION_DIR, name, 48000)
	end
	assert (s, "session " .. SESSION_DIR .. " : " .. tostring (AudioEngine:get_last_backend_error ()))
end

local function activate_osc ()
	local m = ARDOUR.ControlProtocolManager.manager ()
	for p in m:control_protocol_infos ():iter () do
		if p.name:find ("OSC") then
			return m:activate (p, "") == 0
		end
	end
	return false
end

local function main ()
	open_session ()
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
	local osc = activate_osc ()
	-- une commande posée AVANT ce process n'est jamais exécutée (même règle que golem_watch REAPER) : accusée seulement
	local last, last_raw = 0, nil
	local next_beat, next_clock = 0, 0
	local s = read_file (CMD)
	if s then
		local ok, c = pcall (json_decode, s)
		if ok and type (c) == "table" and c.seq then
			last = c.seq
			write_file (ACK, json_encode ({ seq = last, t = now_s () }))
		end
	end
	-- la ligne que monitors._watch_started_since cherche : le veilleur lit ses commandes
	log ("démarré. surveille " .. CMD .. " (osc " .. tostring (osc) .. ", " .. BACKEND .. ")")
	write_file (STATUS, json_encode (status ()))
	while true do
		local raw = read_file (CMD)
		if raw and raw ~= "" and raw ~= last_raw then
			last_raw = raw                            -- un rappel emporte son plan : ne pas le redécoder à chaque tick
			local ok, c = pcall (json_decode, raw)
			if ok and type (c) == "table" and c.seq and c.seq ~= last then
				last = c.seq
				write_file (ACK, json_encode ({ seq = last, t = now_s () }))
				run (c)
			end
		end
		if now_s () >= next_beat then                -- le battement : le bridge sait que le veilleur vit (talking)
			next_beat = now_s () + 2.0
			pcall (function () write_file (STATUS, json_encode (status ())) end)
		end
		if now_s () >= next_clock then               -- le témoin du thread audio, au schéma de golem_clock.lua
			next_clock = now_s () + 1.0
			pcall (function () write_file (CLOCK, json_encode ({ ticks = AudioEngine:processed_samples (), t = now_s (), on = true })) end)
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
