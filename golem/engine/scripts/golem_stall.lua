ardour {
	["type"]    = "dsp",
	name        = "golem Stall",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[A test plugin that blocks the audio thread for a moment the first time it runs. golem's plugin trial bench uses it to prove that it catches a plugin that freezes the engine. Never use it in a session.]]
}

-- SPDX-License-Identifier: MIT
-- Le plugin FAUTIF du banc du premier usage (golem bridge/plugin_trial.py, tools/check-engine-ardour.py) : à son
-- premier passage il occupe le fil audio pendant un moment, comme un plugin qui charge ses données dans le fil temps
-- réel. Le banc doit le refuser. Il laisse passer le son.

function dsp_ioconfig ()
	return { { audio_in = -1, audio_out = -1 } }
end

local first = true

function dsp_init (rate) first = true end

function dsp_run (ins, outs, n_samples)
	if first then
		first = false
		local x = 0
		for i = 1, 150000000 do x = x + i % 7 end       -- quelques centaines de millisecondes de calcul pur
	end
	for c = 1, #outs do
		if ins[c] and not ins[c]:sameinstance (outs[c]) then ARDOUR.DSP.copy_vector (outs[c], ins[c], n_samples) end
	end
end
