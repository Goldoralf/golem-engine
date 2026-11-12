-- construit une session : une piste mono "gtr" -> [NAM] -> [IR] -> master ; arg: dir chain nam ir
io.stdout:setvbuf("no")
local dir, chain, NAM, IR = arg[1], arg[2], arg[3], arg[4]
local function main()
  AudioEngine:set_backend("None (Dummy)", "golem-bench", "")
  assert(create_session(dir, "bench", 48000), "no session")
  local tr
  for t in Session:new_audio_track(1, 2, ARDOUR.RouteGroup(), 1, "gtr", ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true):iter() do tr = t; break end  -- copie : front() = référence dans la liste temporaire
  tr:pan_azimuth_control():set_value(0, PBD.GroupControlDisposition.NoGroup)   -- tout à gauche : gain 1 sur L
  local function add(uri)
    local p = ARDOUR.LuaAPI.new_plugin(Session, uri, ARDOUR.PluginType.LV2, "")
    assert(not p:isnil(), uri); tr:add_processor_by_index(p, -1, nil, true); return p
  end
  if chain == "amp" or chain == "dual" then
    local p = add("http://github.com/mikeoliphant/neural-amp-modeler-lv2")
    assert(ARDOUR.LuaAPI.set_plugin_insert_property(p:to_insert(), "http://github.com/mikeoliphant/neural-amp-modeler-lv2#model", NAM))
  end
  if chain == "ir" or chain == "dual" then
    local p = add("http://gareus.org/oss/lv2/zeroconvolv#CfgMono")
    assert(ARDOUR.LuaAPI.set_plugin_insert_property(p:to_insert(), "http://gareus.org/oss/lv2/zeroconvolv#ir", IR))
  end
  if chain == "safety" then                -- le limiteur de sécurité du Golem Engine (golem/engine/scripts/golem_safety.lua)
    local p = ARDOUR.LuaAPI.new_luaproc(Session, "golem Safety")
    assert(not p:isnil(), "golem Safety introuvable (ARDOUR_DATA_PATH)"); tr:add_processor_by_index(p, -1, nil, true)
  end
  sleep(2)   -- chargements par le worker LV2
  Session:save_state("", false, false, false, false, false)
  close_session()
  print("built", chain)
end
local ok, err = xpcall(main, debug.traceback); if not ok then print("LUA ERROR: " .. tostring(err)) end
