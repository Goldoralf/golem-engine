/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * golem-place : pose un fichier audio (une DI) au début d'une piste d'une session existante, puis règle
 * la plage de la session sur la durée du fichier + une queue (pour entendre delay et reverb), et sauve.
 * C'est la moitié « entrée » du banc de rendu (docs/ardour-plan.md §4) : l'export est fait par
 * l'outil export de session_utils. Aucun moteur audio réel : le pilote factice.
 *
 *   golem-place <dossier de session> <nom d'état> <piste> <fichier.wav> [queue en secondes]
 */

#include <cstdlib>
#include <iostream>

#include "common.h"

#include "ardour/audio_track.h"
#include "ardour/audioregion.h"
#include "ardour/import_status.h"
#include "ardour/location.h"
#include "ardour/playlist.h"
#include "ardour/region_factory.h"
#include "ardour/session.h"
#include "ardour/source.h"

using namespace ARDOUR;
using namespace SessionUtils;

int
main (int argc, char* argv[])
{
	if (argc < 5) {
		std::cerr << "usage: " << UTILNAME << " <session-dir> <state> <track> <file.wav> [tail-seconds]\n";
		return EXIT_FAILURE;
	}
	const std::string dir = argv[1], state = argv[2], track_name = argv[3], file = argv[4];
	const double tail = argc > 5 ? atof (argv[5]) : 3.0;

	SessionUtils::init (true);
	Session* s = SessionUtils::load_session (dir, state);

	std::shared_ptr<Route> r = s->route_by_name (track_name);
	std::shared_ptr<AudioTrack> t = std::dynamic_pointer_cast<AudioTrack> (r);
	if (!t) {
		std::cerr << "no audio track named '" << track_name << "'\n";
		SessionUtils::unload_session (s);
		SessionUtils::cleanup ();
		return EXIT_FAILURE;
	}

	ImportStatus status;
	status.paths.push_back (file);
	status.total = 1;
	status.current = 1;
	status.quality = SrcBest;
	status.freeze = false;
	status.replace_existing_source = false;
	status.split_midi_channels = false;
	status.import_markers = false;
	status.done = false;
	status.cancel = false;
	status.all_done = false;
	s->import_files (status);

	if (status.cancel || status.sources.empty ()) {
		std::cerr << "import failed: " << file << "\n";
		SessionUtils::unload_session (s);
		SessionUtils::cleanup ();
		return EXIT_FAILURE;
	}

	/* une région « fichier entier », puis la région posée sur la piste */
	PBD::PropertyList plist;
	const timepos_t len = status.sources.front ()->length ();
	plist.add (Properties::start, timepos_t (Temporal::AudioTime));
	plist.add (Properties::length, len);
	plist.add (Properties::name, std::string ("di"));
	plist.add (Properties::whole_file, true);
	std::shared_ptr<Region> whole = RegionFactory::create (status.sources, plist);
	plist.remove (Properties::whole_file);
	std::shared_ptr<Region> region = RegionFactory::create (whole, plist);
	/* AUCUN FONDU : Ardour pose 64 échantillons de fondu à chaque bout d'une région ; le banc de parité doit faire
	 * entrer la DI telle quelle (REAPER : fondus d'item à 0), sinon le cas « sans bloc » ne s'annulait qu'à -42 dB */
	if (std::shared_ptr<AudioRegion> ar = std::dynamic_pointer_cast<AudioRegion> (region)) {
		ar->set_fade_in_active (false);
		ar->set_fade_out_active (false);
	}

	std::shared_ptr<Playlist> pl = t->playlist ();
	pl->clear_changes ();
	pl->add_region (region, timepos_t (0));

	const samplepos_t end = len.samples () + (samplepos_t) (tail * s->nominal_sample_rate ());
	s->maybe_update_session_range (timepos_t (0), timepos_t (end));
	if (Location* range = s->locations ()->session_range_location ()) {
		range->set (timepos_t (0), timepos_t (end));
	}

	s->save_state ("");
	std::cout << "placed " << file << " on '" << track_name << "' (" << len.samples () << " samples, tail " << tail << " s)\n";

	/* toutes nos références AVANT de fermer la session : une piste détruite après elle plantait à la sortie
	 * (IO::~IO sur un mutex libéré, mesuré 2026-11-12 sur une piste mono) */
	pl.reset ();
	region.reset ();
	whole.reset ();
	status.sources.clear ();
	t.reset ();
	r.reset ();
	SessionUtils::unload_session (s);
	SessionUtils::cleanup ();
	return EXIT_SUCCESS;
}
