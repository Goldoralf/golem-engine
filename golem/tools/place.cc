/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * golem-place : pose un fichier audio (une DI) au début d'une piste d'une session existante, puis règle
 * la plage de la session sur la durée du fichier + une queue (pour entendre delay et reverb), et sauve.
 * C'est la moitié « entrée » du banc de rendu (docs/ardour-plan.md §4) : l'export est fait par
 * l'outil export de session_utils. Aucun moteur audio réel : le pilote factice.
 *
 *   golem-place <dossier de session> <nom d'état> <piste> <fichier.wav> [queue en secondes] [--disk] [--to-master r1,r2…]
 *
 * Pour rendre une session MONTÉE PAR LE VEILLEUR (le banc des presets, docs/ardour-plan.md §7c) :
 *   --disk        la piste joue sa région (monitoring disque) et son entrée est débranchée — le veilleur la met en
 *                 monitoring d'ENTRÉE (la carte), un export n'entendrait rien ;
 *   --to-master   les sorties de ces routes vont au master (le veilleur les relie à la carte, l'export rend le master) :
 *                 une sortie mono sur les deux entrées du master, comme la carte ; une stéréo canal par canal.
 * LA CLÉ DES GATES À CLÉ (2026-11-13, golem docs/golem-fx-sheet.md §4) : en --disk, un sidechain que le veilleur a relié
 * à l'entrée de la carte de la piste (le DI) n'entendrait plus rien ; une piste « golem-key-di » joue la même DI depuis
 * le disque, hors master, et nourrit ces sidechains — comme la carte le fait en jeu.
 */

#include <algorithm>
#include <cstdlib>
#include <iostream>

#include "common.h"

#include <sstream>
#include <vector>

#include "ardour/audio_port.h"
#include "ardour/audio_track.h"
#include "ardour/io.h"
#include "ardour/monitor_control.h"
#include "ardour/plugin_insert.h"
#include "ardour/route_group.h"
#include "ardour/audioregion.h"
#include "ardour/import_status.h"
#include "ardour/location.h"
#include "ardour/playlist.h"
#include "ardour/region_factory.h"
#include "ardour/session.h"
#include "ardour/source.h"

using namespace ARDOUR;
using namespace SessionUtils;

/* une route par son nom tel que le veilleur l'a donné : au rechargement, Ardour rend le nom légal pour un port
 * (« GoleM:guitar-1 » devient « GoleM_guitar-1 », mesuré 2026-11-12) */
static std::shared_ptr<Route>
find_route (Session* s, std::string name)
{
	std::shared_ptr<Route> r = s->route_by_name (name);
	if (!r) {
		std::replace (name.begin (), name.end (), ':', '_');
		r = s->route_by_name (name);
	}
	return r;
}

int
main (int argc, char* argv[])
{
	if (argc < 5) {
		std::cerr << "usage: " << UTILNAME << " <session-dir> <state> <track> <file.wav> [tail-seconds]\n";
		return EXIT_FAILURE;
	}
	const std::string dir = argv[1], state = argv[2], track_name = argv[3], file = argv[4];
	double tail = 3.0;
	bool disk = false;
	std::vector<std::string> to_master;
	for (int i = 5; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--disk") {
			disk = true;
		} else if (a == "--to-master" && i + 1 < argc) {
			std::stringstream ss (argv[++i]);
			std::string n;
			while (std::getline (ss, n, ',')) {
				if (!n.empty ()) {
					to_master.push_back (n);
				}
			}
		} else {
			tail = atof (a.c_str ());
		}
	}

	SessionUtils::init (true);
	Session* s = SessionUtils::load_session (dir, state);

	std::shared_ptr<Route> r = find_route (s, track_name);
	std::shared_ptr<AudioTrack> t = std::dynamic_pointer_cast<AudioTrack> (r);
	if (!t) {
		std::cerr << "no audio track named '" << track_name << "' — routes:";
		std::shared_ptr<RouteList const> rl = s->get_routes ();
		for (auto const& ro : *rl) {
			std::cerr << " '" << ro->name () << "'";
		}
		std::cerr << "\n";
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

	std::shared_ptr<AudioTrack> key;
	if (disk) {
		/* les ports de la carte que la piste écoutait : un sidechain qui y est relié est la CLÉ d'un gate (le DI) */
		std::vector<std::string> card;
		for (uint32_t i = 0; i < t->input ()->n_ports ().n_audio (); ++i) {
			std::vector<std::string> c;
			t->input ()->audio (i)->get_connections (c);
			card.insert (card.end (), c.begin (), c.end ());
		}
		std::vector<std::shared_ptr<Port>> keys;
		std::shared_ptr<RouteList const> rl = s->get_routes ();
		for (auto const& ro : *rl) {
			for (uint32_t k = 0;; ++k) {
				std::shared_ptr<Processor> p = ro->nth_plugin (k);
				if (!p) {
					break;
				}
				std::shared_ptr<PluginInsert> pi = std::dynamic_pointer_cast<PluginInsert> (p);
				if (!pi || !pi->sidechain_input ()) {
					continue;
				}
				std::shared_ptr<IO> sc = pi->sidechain_input ();
				for (uint32_t i = 0; i < sc->n_ports ().n_audio (); ++i) {
					bool hit = false;
					for (std::string const& c : card) {
						if (sc->audio (i)->connected_to (c)) {
							hit = true;
						}
					}
					if (hit) {
						sc->audio (i)->disconnect_all ();
						keys.push_back (sc->audio (i));
					}
				}
			}
		}
		/* écrit TOUT DE SUITE : set_value passe par la file temps réel, que rien ne vide ici (aucun cycle audio) */
		t->monitoring_control ()->set_value_unchecked (MonitorDisk);
		t->input ()->disconnect ();
		if (!keys.empty ()) {
			std::list<std::shared_ptr<AudioTrack>> made = s->new_audio_track (1, 1, nullptr, 1, "golem-key-di",
				PresentationInfo::max_order, Normal, true);
			if (!made.empty ()) {
				key = made.front ();
				key->input ()->disconnect ();
				key->output ()->disconnect ();
				key->monitoring_control ()->set_value_unchecked (MonitorDisk);
				std::shared_ptr<Playlist> kpl = key->playlist ();
				kpl->add_region (RegionFactory::create (whole, plist), timepos_t (0));
				for (auto const& kp : keys) {
					key->output ()->audio (0)->connect (kp->name ());
				}
				std::cout << "key: the DI feeds " << keys.size () << " sidechain port(s)\n";
			}
		}
	}
	std::shared_ptr<Route> master = s->master_out ();
	for (std::string const& n : to_master) {
		std::shared_ptr<Route> ro = find_route (s, n);
		if (!ro || !master) {
			std::cerr << "no route named '" << n << "' (or no master)\n";
			continue;
		}
		std::shared_ptr<IO> out = ro->output ();
		std::shared_ptr<IO> min = master->input ();
		const uint32_t no = out->n_ports ().n_audio (), nm = min->n_ports ().n_audio ();
		out->disconnect ();
		for (uint32_t m = 0; m < nm; ++m) {
			/* mono : la même sortie sur chaque entrée du master ; stéréo : canal par canal */
			out->audio (no == 1 ? 0 : m % no)->connect (min->audio (m)->name ());
		}
	}

	s->save_state ("");
	std::cout << "placed " << file << " on '" << track_name << "' (" << len.samples () << " samples, tail " << tail << " s)\n";

	/* toutes nos références AVANT de fermer la session : une piste détruite après elle plantait à la sortie
	 * (IO::~IO sur un mutex libéré, mesuré 2026-11-12 sur une piste mono) */
	pl.reset ();
	region.reset ();
	whole.reset ();
	status.sources.clear ();
	master.reset ();
	key.reset ();
	t.reset ();
	r.reset ();
	SessionUtils::unload_session (s);
	SessionUtils::cleanup ();
	return EXIT_SUCCESS;
}
