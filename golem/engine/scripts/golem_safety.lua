ardour {
	["type"]    = "dsp",
	name        = "golem Safety",
	category    = "Dynamics",
	license     = "MIT",
	author      = "golem contributors",
	description = [[Zero-latency safety limiter, ceiling -1 dBFS: the last plugin of every route that goes to the card.]]
}

-- SPDX-License-Identifier: MIT
-- Le portage à l'identique de reaper/Effects/golem_safety.jsfx (golem) pour le Golem Engine (docs/ardour-plan.md §7c) :
-- AUCUNE ANTICIPATION (ReaLimit anticipait de 10 ms et ça s'entendait, 2026-10-14). Le gain tombe à l'échantillon même où
-- la crête dépasse le plafond, puis remonte en Release ms ; les canaux sont liés ; une borne dure au plafond garantit
-- qu'aucun échantillon ne sort au-dessus ; un NaN ou un infini venu de l'amont devient du silence.

function dsp_ioconfig ()
	return { { audio_in = -1, audio_out = -1 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "Ceiling", min = -12, max = 0, default = -1, unit = "dB" },
		{ ["type"] = "input", name = "Release", min = 1, max = 500, default = 15, unit = "ms" },
	}
end

local sr = 48000
local g = 1.0
local a = {}                                      -- créée UNE fois : aucune allocation dans le fil audio

function dsp_init (rate)
	sr = rate
end

function dsp_run (ins, outs, n_samples)
	local ctrl = CtrlPorts:array ()
	local ceil = 10 ^ (ctrl[1] / 20)
	local rel = math.exp (-1 / (math.max (1, ctrl[2]) * 0.001 * sr))
	local nch = #outs
	for c = 1, nch do
		if ins[c] ~= outs[c] then ARDOUR.DSP.copy_vector (outs[c], ins[c], n_samples) end
	end
	for c = 1, nch do a[c] = outs[c]:array () end   -- une fois par bloc : l'accès par échantillon coûte cher en Lua
	for s = 1, n_samples do
		local pk = 0
		for c = 1, nch do
			local v = a[c][s]
			if not (v >= -1000000 and v <= 1000000) then a[c][s] = 0; v = 0 end
			if v < 0 then v = -v end
			if v > pk then pk = v end
		end
		local t = pk > ceil and ceil / pk or 1
		if t < g then g = t else g = t + (g - t) * rel end
		for c = 1, nch do
			local v = a[c][s] * g
			if v > ceil then v = ceil elseif v < -ceil then v = -ceil end
			a[c][s] = v
		end
	end
end
