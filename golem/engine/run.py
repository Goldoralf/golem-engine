#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Lance le Golem Engine pour golem : luasession + le veilleur (golem_watch.lua), sans interface — sur les TROIS
systèmes (Linux aujourd'hui ; Windows et macOS : golem docs/install-v2.md, le portage). Bibliothèque standard seule.

    run.py <golem-root> [session-dir] [backend] [device]

C'est le lanceur ; `run.sh` ne fait plus que l'appeler. Il pose l'environnement du moteur (ce que golem/dev/env.sh
pose pour les outils de dev), remplit le cache VST3, écrit le PID dans <golem-root>/presets/.engine.pid — le bridge
lit ce PID pour savoir si le moteur tourne et pour l'arrêter (bridge/engine/ardour.py) — puis :
  · POSIX   se REMPLACE par luasession (exec) : le PID écrit est celui du moteur ;
  · Windows lance luasession, écrit SON PID, attend sa fin et rend son code (pas d'exec sous Windows).

Arbre de dev ou paquet installé (golem/tools/bundle.py), même forme : build/libs/…, build/luasession/…, share/,
et `deps/` dans le paquet."""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(os.path.dirname(HERE))
WIN, MAC = sys.platform == "win32", sys.platform == "darwin"
LIB_EXT = (".dll",) if WIN else ((".dylib", ".so") if MAC else (".so",))
LIB_VAR = "PATH" if WIN else ("DYLD_FALLBACK_LIBRARY_PATH" if MAC else "LD_LIBRARY_PATH")


def lib_dirs(libs):
    """Les dossiers de build/libs qui portent une bibliothèque (l'éditeur de liens les veut tous)."""
    out = set()
    for d, _dirs, files in os.walk(libs):
        if any(f.endswith(LIB_EXT) or ".so." in f for f in files):
            out.add(d)
    return sorted(out)


def linux_deps(top, home):
    """Le dossier des bibliothèques du paquet que LA MACHINE N'A PAS (des liens, dans le cache de l'utilisateur) : une
    bibliothèque du système de même nom est au moins aussi récente que la nôtre et gagne — tout `deps/` devant le
    système faisait mourir un ffmpeg du système sur un symbole absent de notre glib (mesuré 2026-11-18). Refait quand le
    cache de l'éditeur de liens ou le paquet change. None hors d'un paquet."""
    deps = os.path.join(top, "deps")
    if not os.path.isdir(deps):
        return None
    try:
        version = open(os.path.join(top, "VERSION"), encoding="utf-8").read().strip() or "dev"
    except OSError:
        version = "dev"
    act = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache"), "golem-engine", "deps-" + version)

    def mtime(p):
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0
    if not os.path.isdir(act) or mtime("/etc/ld.so.cache") > mtime(act) or mtime(deps) > mtime(act):
        have = set()
        for exe in ("/sbin/ldconfig", "ldconfig"):
            try:
                out = subprocess.run([exe, "-p"], capture_output=True, text=True, timeout=20).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            have = {line.split()[0] for line in out.splitlines() if line.strip() and "=>" in line}
            if have:
                break
        tmp = act + "." + str(os.getpid())
        os.makedirs(tmp, exist_ok=True)
        for n in os.listdir(deps):
            if n not in have:
                link = os.path.join(tmp, n)
                if not os.path.lexists(link):
                    os.symlink(os.path.join(deps, n), link)
        import shutil
        shutil.rmtree(act, ignore_errors=True)
        try:
            os.rename(tmp, act)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)             # un autre lancement l'a posé entre-temps
    return act


def engine_env(top, environ=None, home=None):
    """L'environnement du moteur, à partir de celui de l'appelant. Pur (sauf le cache de linux_deps)."""
    env = dict(os.environ if environ is None else environ)
    home = home or os.path.expanduser("~")
    P = os.pathsep
    libs = os.path.join(top, "build", "libs")
    j = os.path.join
    host = env.get(LIB_VAR, "")
    env["GOLEM_ENGINE_HOST_LD"] = "" if WIN else host           # ce qu'un programme lancé par le moteur retrouve
    dirs = lib_dirs(libs)
    if WIN or MAC:
        if os.path.isdir(j(top, "deps")):
            dirs.append(j(top, "deps"))
        elif WIN:
            # un ARBRE DE DEV Windows (golem/tools/win-build.sh) : ses bibliothèques (glib, lilv, libsndfile…) sont celles
            # de MSYS2 UCRT64 qui l'a construit — un paquet les emporte dans deps/ (2026-11-19, portage Windows)
            msys = j(env.get("GOLEM_ENGINE_MSYS") or r"C:\msys64\ucrt64", "bin")
            if os.path.isdir(msys):
                dirs.append(msys)
    else:
        d = linux_deps(top, home)
        if d:
            dirs.append(d)
    env[LIB_VAR] = P.join(dirs + ([host] if host else []))
    surf = j(libs, "surfaces")
    env["ARDOUR_SURFACES_PATH"] = P.join(j(surf, s) for s in ("osc", "mcp_http", "websockets", "generic_midi"))
    env["ARDOUR_PANNER_PATH"] = j(libs, "panners")
    env["ARDOUR_DATA_PATH"] = P.join([j(top, "golem", "engine"), j(top, "share"), j(top, "build"), j(top, "gtk2_ardour"),
                                      j(top, "build", "gtk2_ardour")])
    env["ARDOUR_MIDIMAPS_PATH"] = j(top, "share", "midi_maps")
    env["ARDOUR_MIDI_PATCH_PATH"] = j(top, "share", "patchfiles")
    env["ARDOUR_EXPORT_FORMATS_PATH"] = j(top, "share", "export")
    # tous les backends construits pour ce système (ALSA et factice sous Linux ; PortAudio, CoreAudio ailleurs)
    back = j(libs, "backends")
    env["ARDOUR_BACKEND_PATH"] = P.join(sorted(j(back, d) for d in os.listdir(back) if os.path.isdir(j(back, d)))) \
        if os.path.isdir(back) else ""
    env["ARDOUR_CONFIG_PATH"] = P.join([top, j(top, "gtk2_ardour"), j(top, "build"), j(top, "build", "gtk2_ardour")])
    env["ARDOUR_DLL_PATH"] = libs
    env["ARDOUR_MCP_PATH"] = j(top, "share", "mcp")
    env["VAMP_PATH"] = j(libs, "vamp-plugins")
    # la config du moteur : dans l'arbre de dev par défaut ; un paquet installé (fichier VERSION) n'écrit JAMAIS dans
    # son dossier d'installation — celle de l'utilisateur, comme tout programme
    if env.get("GOLEM_ENGINE_CONFIG"):
        env["XDG_CONFIG_HOME"] = env["GOLEM_ENGINE_CONFIG"]
    elif not os.path.isfile(j(top, "VERSION")):
        env["XDG_CONFIG_HOME"] = j(top, "golem", "dev", "config")
    # la surface OSC n'a qu'un client, le bridge local : pas d'annonce de son port sur le réseau
    env["ARDOUR_OSC_NO_ZEROCONF"] = "1"
    # le port de la surface OSC : 3819 par défaut ; un banc lancé à côté du moteur qui joue en nomme un autre
    if env.get("GOLEM_ENGINE_OSC"):
        env["ARDOUR_OSC_PORT"] = env["GOLEM_ENGINE_OSC"]
    # un appareil MIDI branché après le démarrage reste FERMÉ : le veilleur n'ouvre que le clavier d'une lane
    env["ARDOUR_ALSA_MIDI_NO_HOTPLUG_OPEN"] = "1"
    # l'arrêt ou le déplacement du transport ne relâche pas les notes tenues (patch du moteur, golem/README.md)
    env["ARDOUR_MIDI_KEEP_NOTES_ON_TRANSPORT"] = "1"
    if not WIN:
        # les NOMS DE PARAMÈTRES en anglais quelle que soit la langue du système : golem retrouve un potard par son nom
        env["LANG"] = env["LC_ALL"] = "C.UTF-8"
    else:
        # LES VST3 DE GOLEM (2026-11-19) : Ardour ne parcourt sous Windows que Program Files\Common Files\VST3 ;
        # golem-fx est posé dans %LOCALAPPDATA%\Programs\Common\VST3\GoleM — VST3_PATH (lu à sa première configuration)
        env.setdefault("VST3_PATH", P.join(vst3_dirs(env, home)))
    return env


def find_program(top, names):
    """Le premier exécutable trouvé parmi `names` (motifs), dans les dossiers où la construction ou le paquet le pose."""
    for d in (os.path.join(top, "build", "luasession"), os.path.join(top, "build", "libs", "fst"), os.path.join(top, "bin")):
        for n in names:
            for p in sorted(glob.glob(os.path.join(d, n))):
                if os.path.isfile(p) and (WIN or os.access(p, os.X_OK)):
                    return p
    return None


def vst3_dirs(environ=None, home=None):
    env = os.environ if environ is None else environ
    home = home or os.path.expanduser("~")
    if WIN:
        out = [os.path.join(env.get("CommonProgramFiles") or r"C:\Program Files\Common Files", "VST3")]
        if env.get("LOCALAPPDATA"):
            out.append(os.path.join(env["LOCALAPPDATA"], "Programs", "Common", "VST3"))
        return out
    if MAC:
        return [os.path.join(home, "Library", "Audio", "Plug-Ins", "VST3"), "/Library/Audio/Plug-Ins/VST3"]
    return [os.path.join(home, ".vst3"), "/usr/lib/vst3", "/usr/local/lib/vst3"]


def vst3_bundles(dirs):
    """Les bundles .vst3 d'un dossier et de ses sous-dossiers directs (golem-fx sous Windows : …/VST3/GoleM/)."""
    out = []
    for d in dirs:
        for pat in ("*.vst3", os.path.join("*", "*.vst3")):
            out += sorted(glob.glob(os.path.join(d, pat)))
    return out


def _scanned_file(env, home):
    base = env.get("XDG_CONFIG_HOME") or os.path.join(env.get("LOCALAPPDATA") or home, "golem-engine")
    return os.path.join(base, "golem-vst3-scanned.json")


def scan_vst3(top, env, home=None):
    """Ardour sans interface ne lit que son CACHE VST3, que rien ne remplit : le scanner d'Ardour (un process séparé —
    un plugin qui plante ne tue pas le moteur), avant chaque démarrage ; il saute ce qui est déjà en cache.
    WINDOWS (2026-11-19) : un process PAR bundle même déjà en cache — 159 bundles sur la machine du mainteneur, plus de
    30 s avant chaque démarrage, et le bridge déclarait le moteur absent. Un bundle déjà scanné et inchangé (sa date) n'y
    est plus relancé ; un neuf ou un mis à jour l'est. Linux garde le passage complet (non mesuré là-bas)."""
    import json
    scan = find_program(top, ("ardour-vst3-scanner", "ardour-vst3-scanner.exe"))
    if not scan:
        return 0
    home = home or os.path.expanduser("~")
    path, done = _scanned_file(env, home), {}
    if WIN:
        try:
            with open(path, encoding="utf-8") as f:
                done = json.load(f) or {}
        except (OSError, ValueError):
            done = {}
    n = 0
    for b in vst3_bundles(vst3_dirs(env)):
        try:
            stamp = os.stat(b).st_mtime
        except OSError:
            continue
        if WIN and done.get(b) == stamp:
            continue
        try:
            subprocess.run([scan, "-q", b], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            n += 1
            done[b] = stamp
        except subprocess.TimeoutExpired:
            # UN PLUGIN QUI BLOQUE LE SCANNER (2026-11-19 : Neural DSP Parallax, sa licence) coûtait 30 s à CHAQUE
            # démarrage : il est noté aussi, et retenté seulement quand il change (une mise à jour). Il ne se chargerait
            # pas plus dans le moteur, dont le scanner est justement le garde-fou.
            n += 1
            done[b] = stamp
        except (OSError, subprocess.SubprocessError):
            pass
    if WIN and n:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(done, f, indent=0)
        except OSError:
            pass
    return n


# un fichier MIDI SANS ÉVÉNEMENT tel qu'Ardour le crée : l'en-tête, puis une seule piste qui ne contient que sa fin
_EMPTY_SMF_TRACK = b"MTrk\x00\x00\x00\x04\x00\xff\x2f\x00"


def sweep_empty_midi(session):
    """Efface les fichiers MIDI VIDES que la session précédente a laissés. Après chaque prise, Ardour donne une source
    d'écriture neuve à CHAQUE piste MIDI, armée ou non (le nom de prise change) ; le fichier est créé tout de suite et
    ne s'efface qu'à la fermeture de la session — or le moteur est arrêté net (TerminateProcess sous Windows, SIGTERM
    sous Linux) : ~10 fichiers de 26 octets par prise, pour toujours (mesuré 2026-11-20). Un fichier sans événement ne
    porte rien et la session ne garde pas de source vide : rien ne le lit. Rend le nombre de fichiers effacés."""
    n = 0
    base = os.path.join(session, "interchange")
    if not os.path.isdir(base):
        return 0
    for name in os.listdir(base):
        d = os.path.join(base, name, "midifiles")
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            p = os.path.join(d, f)
            try:
                if not f.lower().endswith(".mid") or os.path.getsize(p) != 26:
                    continue
                with open(p, "rb") as h:
                    data = h.read()
                if data[:4] == b"MThd" and data[4:8] == b"\x00\x00\x00\x06" and data[14:] == _EMPTY_SMF_TRACK:
                    os.remove(p)
                    n += 1
            except OSError:
                pass
    return n


def no_power_throttling(pid):
    """Windows 11 BRIDE un processus sans fenêtre visible (« power throttling ») : il ignore sa demande de résolution du
    minuteur (timeBeginPeriod, posée par le backend) et peut le reléguer, EcoQoS, sur des cœurs lents à basse fréquence.
    Mesuré 2026-11-19 : la surface OSC dort `Glib::usleep (1)` après CHAQUE message (osc.cc) — bridé, c'est un tic de
    15,6 ms, 64 messages/s ; le premier envoi des strips (~700 messages) retenait les commandes 11 s, et le looper, le
    transport, les niveaux arrivaient en retard ou jamais. Le moteur audio n'est jamais bridé : les deux bits sont
    contrôlés, état 0. Rend False si Windows refuse — le moteur marche, en retard."""
    try:
        import ctypes
        from ctypes import wintypes

        class _State(ctypes.Structure):
            _fields_ = [("Version", wintypes.ULONG), ("ControlMask", wintypes.ULONG), ("StateMask", wintypes.ULONG)]

        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.OpenProcess.restype = wintypes.HANDLE
        h = k.OpenProcess(0x0200, False, int(pid))                 # PROCESS_SET_INFORMATION
        if not h:
            return False
        try:
            # ProcessPowerThrottling (4) ; EXECUTION_SPEED (1) | IGNORE_TIMER_RESOLUTION (4) contrôlés, état 0 = jamais
            st = _State(1, 0x1 | 0x4, 0)
            return bool(k.SetProcessInformation(h, 4, ctypes.byref(st), ctypes.sizeof(st)))
        finally:
            k.CloseHandle(h)
    except (OSError, AttributeError, ValueError):
        return False


def main(argv):
    if not argv:
        print("usage: run.py <golem-root> [session-dir] [backend] [device]", file=sys.stderr)
        return 2
    root = argv[0]
    session = argv[1] if len(argv) > 1 and argv[1] else os.path.join(root, "sets", "golem-engine")
    backend = argv[2] if len(argv) > 2 and argv[2] else "None (Dummy)"
    device = argv[3] if len(argv) > 3 else ""
    # pas `session` lui-même : create_session refuse un dossier existant
    os.makedirs(os.path.dirname(session) or ".", exist_ok=True)
    os.makedirs(os.path.join(root, "presets"), exist_ok=True)
    env = engine_env(TOP)
    lua = find_program(TOP, ("luasession", "luasession.exe", "*-lua.exe"))
    if not lua:
        print("golem engine: luasession not found under " + TOP, file=sys.stderr)
        return 1
    scan_vst3(TOP, env)
    swept = sweep_empty_midi(session)
    if swept:
        print(f"golem engine: {swept} empty MIDI file(s) left by the previous session removed", file=sys.stderr, flush=True)
    cmd = [lua, os.path.join(HERE, "golem_watch.lua"), root, session, backend, device]
    pid_file = os.path.join(root, "presets", ".engine.pid")
    # DÉVELOPPEMENT : GOLEM_ENGINE_GDB=<fichier> lance le moteur SOUS gdb (2026-11-19 : sous Windows un moteur qui meurt
    # ne laisse qu'un code de sortie ; attacher gdb après coup figeait le banc). Au plantage, la pile de chaque fil va dans
    # le fichier. Le PID écrit est alors celui de gdb : le bridge ne reconnaît pas le moteur (outil de diagnostic seul).
    gdb_log = env.get("GOLEM_ENGINE_GDB")
    if gdb_log:
        gdb = env.get("GOLEM_ENGINE_GDB_BIN") or "gdb"
        cmd = [gdb, "-batch", "-ex", "set pagination off", "-ex", "set logging file " + gdb_log.replace("\\", "/"),
               "-ex", "set logging overwrite on", "-ex", "set logging enabled on",
               "-ex", "handle SIGSEGV stop print nopass", "-ex", "run", "-ex", "bt 60", "-ex", "info registers rip",
               "-ex", "thread apply all bt 20", "--args", *cmd]
    if WIN:
        p = subprocess.Popen(cmd, env=env)
        if not no_power_throttling(p.pid):
            print("golem engine: Windows power throttling could not be lifted (OSC and timers may lag)",
                  file=sys.stderr, flush=True)
        with open(pid_file, "w") as f:
            f.write(str(p.pid) + "\n")
        rc = p.wait()
        # le CODE DE SORTIE dans le journal du moteur (2026-11-19) : sous Windows un moteur qui meurt ne laisse rien d'autre
        # (0xC0000005 = accès mémoire, 0xC0000409 = abort / pile corrompue, 3 = abort du CRT)
        print(f"golem engine: luasession exited with code {rc} (0x{rc & 0xFFFFFFFF:08X})", file=sys.stderr, flush=True)
        return rc
    try:                                                       # un plantage laisse un core : la pile se lit avec gdb
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
    except (ImportError, ValueError, OSError):
        pass
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()) + "\n")
    os.execvpe(cmd[0], cmd, env)                               # ne revient pas (cmd[0] : luasession, ou gdb en diagnostic)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
