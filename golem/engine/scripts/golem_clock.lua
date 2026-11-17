ardour {
	["type"]    = "dsp",
	name        = "golem Clock",
	category    = "Utility",
	license     = "MIT",
	author      = "golem contributors",
	description = [[golem's MIDI clock: 24 ticks per quarter note at the song's BPM, running with the transport stopped, so that a keyboard's arpeggiator follows the preset's tempo.]]
}

-- SPDX-License-Identifier: MIT
-- L'horloge MIDI de golem pour le Golem Engine (golem docs/ardour-plan.md §7d), portage de reaper/Effects/midi-clock.jsfx :
-- 0xF8 à 24 par noire, au `BPM` posé par le veilleur (le tempo du preset), TRANSPORT ARRÊTÉ — golem se joue transport
-- à l'arrêt, et l'horloge native d'un séquenceur ne sort qu'en lecture. Un accumulateur fractionnaire d'échantillons :
-- aucune dérive. Ni Start ni Stop : une horloge libre, comme sous REAPER. Ce qui arrive en entrée ne passe pas.
-- TÉMOINS, dans la mémoire partagée de l'instance (2 entiers) : [0] le nombre de tics émis, [1] le tempo vu × 100.

function dsp_ioconfig ()
	return { { midi_in = 1, midi_out = 1, audio_in = 0, audio_out = 0 } }
end

function dsp_params ()
	return {
		{ ["type"] = "input", name = "On", min = 0, max = 1, default = 1, toggled = true },
		{ ["type"] = "input", name = "BPM", min = 20, max = 400, default = 120 },
	}
end

local rate, acc, ticks = 48000, 0, 0     -- acc : échantillons avant le prochain tic (fractionnaire)

function dsp_init (r)
	rate = r
	self:shmem ():allocate (2)
	self:shmem ():clear ()
end

function dsp_run (_, _, n_samples)
	local ctrl = CtrlPorts:array ()
	local on, bpm = ctrl[1] > 0.5, ctrl[2]
	local shm = self:shmem ()
	if not on or bpm < 20 then
		acc = 0
		shm:atomic_set_int (1, 0)
		return
	end
	local step = rate * 60 / (bpm * 24)
	local cnt = 1
	while acc < n_samples do
		midiout[cnt] = { time = math.floor (acc) + 1, data = { 0xF8 } }
		cnt = cnt + 1
		ticks = ticks + 1
		acc = acc + step
	end
	acc = acc - n_samples
	shm:atomic_set_int (0, ticks & 0x7FFFFFFF)
	shm:atomic_set_int (1, math.floor (bpm * 100 + 0.5))
end
