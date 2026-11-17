#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Le PAQUET AUTONOME du Golem Engine (golem docs/ardour-plan.md §1.3) : ce que l'installateur de golem télécharge et
pose dans ~/opt/golem-engine — le moteur sans compilateur, sans dépôt, sans paquets de la distribution.

    python3 golem/tools/bundle.py [--out DIR] [--version X]     (après `./waf build`)

Le paquet GARDE LA FORME DE L'ARBRE DE DEV (build/libs/…, build/luasession/luasession, golem/engine/run.sh, share/) :
golem/dev/env.sh et golem/engine/run.sh y tournent tels quels, le bridge ne voit aucune différence
(GOLEM_ENGINE_DIR). S'y ajoute `deps/` : les bibliothèques du système dont le moteur a besoin (fermeture de `ldd`),
SAUF le socle que toute distribution porte et qu'on ne doit pas doubler (glibc, ALSA, l'éditeur de liens).

Ce qui N'EST PAS pris : l'interface graphique d'Ardour (gtk2_ardour, ses bibliothèques et tout ce qui en dépend), les
surfaces de contrôle autres que celles que golem charge, les tests. golem pilote `luasession`, sans fenêtre.

Sorties : <out>/golem-engine-<version>-linux-<arch>.tar.gz, son .sha256, et dans l'archive VERSION, SOURCES (le commit
exact : obligation GPL) et COPYING."""
import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile

TOP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCES_URL = "https://github.com/Goldoralf/golem-engine"

# les exécutables que golem lance ou que le moteur lance lui-même
PROGRAMS = ("build/luasession/luasession", "build/golem/golem-place", "build/libs/vfork/ardour-exec-wrapper",
            "build/libs/fst/ardour-vst3-scanner", "build/libs/ardouralsautil/ardour-request-device",
            "build/session_utils/golem-engine9-export", "build/session_utils/golem-engine9-new_session",
            "build/session_utils/golem-engine9-new_empty_session")
# LA surface que golem pilote : l'OSC. Elle porte un panneau de réglage (osc_gui.cc) et se lie donc aux bibliothèques
# graphiques d'Ardour : celles-là, et elles seules, sont emportées avec elle (voir `forced`). Un correctif du fork qui
# rendrait ce panneau optionnel allégerait le paquet d'une trentaine de bibliothèques.
SURFACES = ("osc",)
# une bibliothèque construite qui dépend de l'une de celles-ci est de l'interface graphique : pas dans le paquet
GUI_MARKS = ("libytk", "libydk", "libgtk", "libgdk", "libgtkmm", "libgdkmm", "libcairo", "libpango", "libX11")
# le socle : présent partout, lié au noyau ou au matériel — le doubler casse plus qu'il ne répare
SYSTEM = ("linux-vdso", "ld-linux", "libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so", "libresolv.so",
          "libutil.so", "libmvec.so", "libasound.so", "libnss_", "libudev.so", "libsystemd.so", "libdbus-1.so",
          # la bibliothèque C++ du système : un plugin de l'utilisateur construit ailleurs peut en vouloir une plus
          # récente que celle du paquet — on construit sur la plus vieille distribution visée, on prend la leur
          "libstdc++.so", "libgcc_s.so")
DATA = ("share/midi_maps", "share/patchfiles", "share/export", "share/mcp", "share/scripts", "share/plugin_metadata",
        "share/templates")
FILES = ("system_config", "COPYING", "golem/README.md", "golem/dev/env.sh")


def ldd(path):
    """{nom: chemin résolu} des dépendances d'un ELF ; les « not found » lèvent : un paquet troué ne sort pas."""
    env = dict(os.environ, LD_LIBRARY_PATH=_LIBPATH)
    out = subprocess.run(["ldd", path], capture_output=True, text=True, env=env).stdout
    deps = {}
    for line in out.splitlines():
        parts = line.split()
        if "=>" in parts:
            name, target = parts[0], parts[parts.index("=>") + 1]
            if target == "not":
                raise SystemExit(f"bundle: {path} needs {name}, which is not found")
            deps[name] = target
    return deps


def built_libs():
    out = []
    for d, _dirs, files in os.walk(os.path.join(TOP, "build", "libs")):
        rel = os.path.relpath(d, TOP)
        parts = rel.split(os.sep)
        if "surfaces" in parts:
            i = parts.index("surfaces")
            if len(parts) > i + 1 and parts[i + 1] not in SURFACES:
                continue
        for f in files:
            if ".so" in f and not f.endswith((".o", ".py")):
                out.append(os.path.join(rel, f))
            elif f.endswith(".ttl") and ".lv2" in rel:    # les LV2 du moteur (le synthé de la basse des standards…)
                out.append(os.path.join(rel, f))
    return sorted(out)


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def main():
    global _LIBPATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(TOP, "build", "bundle"))
    ap.add_argument("--version", default=None)
    a = ap.parse_args()
    describe = subprocess.run(["git", "-C", TOP, "describe", "--tags", "--always", "--dirty"], capture_output=True,
                              text=True).stdout.strip()
    commit = subprocess.run(["git", "-C", TOP, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    version = a.version or describe
    arch = platform.machine()
    name = f"golem-engine-{version}-linux-{arch}"
    stage = os.path.join(a.out, name)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    libdirs = sorted({os.path.dirname(os.path.join(TOP, p)) for p in built_libs()})
    _LIBPATH = ":".join(libdirs)

    for p in PROGRAMS:
        if not os.path.isfile(os.path.join(TOP, p)):
            raise SystemExit(f"bundle: {p} is missing — run ./waf build first")
    kept, skipped, system = [], [], {}
    build = os.path.join(TOP, "build") + os.sep
    forced = set()                                         # ce dont une surface gardée a besoin, graphique ou non
    for rel in built_libs():
        if os.sep + "surfaces" + os.sep in rel:
            forced.add(os.path.realpath(os.path.join(TOP, rel)))
            forced.update(os.path.realpath(t) for t in ldd(os.path.realpath(os.path.join(TOP, rel))).values()
                          if os.path.realpath(t).startswith(build))
    for rel in list(PROGRAMS) + built_libs():
        src = os.path.join(TOP, rel)
        real = os.path.realpath(src)
        deps = ldd(real) if is_elf(real) else {}
        if rel not in PROGRAMS and real not in forced and any(n.startswith(GUI_MARKS) for n in deps):
            skipped.append(rel)
            continue
        kept.append(rel)
        for n, target in deps.items():
            if os.path.realpath(target).startswith(os.path.join(TOP, "build") + os.sep) or n.startswith(SYSTEM):
                continue
            system[n] = os.path.realpath(target)
    # une bibliothèque gardée ne doit dépendre d'aucune bibliothèque écartée
    gone = {os.path.basename(s) for s in skipped}
    for rel in kept:
        real = os.path.realpath(os.path.join(TOP, rel))
        if is_elf(real):
            bad = [n for n in ldd(real) if n in gone]
            if bad:
                raise SystemExit(f"bundle: {rel} needs {bad}, left out as GUI")
    for rel in kept:
        dst = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.path.join(TOP, rel)
        if os.path.islink(src):                           # libfoo.so -> libfoo.so.1 : le lien, tel quel
            os.symlink(os.readlink(src), dst)
        else:
            shutil.copy2(src, dst)
    os.makedirs(os.path.join(stage, "deps"))
    for n, target in sorted(system.items()):
        shutil.copy2(target, os.path.join(stage, "deps", n))
    shutil.copytree(os.path.join(TOP, "golem", "engine"), os.path.join(stage, "golem", "engine"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    for d in DATA:
        if os.path.isdir(os.path.join(TOP, d)):
            shutil.copytree(os.path.join(TOP, d), os.path.join(stage, d))
    for f in FILES:
        if os.path.isfile(os.path.join(TOP, f)):
            os.makedirs(os.path.dirname(os.path.join(stage, f)), exist_ok=True)
            shutil.copy2(os.path.join(TOP, f), os.path.join(stage, f))
    with open(os.path.join(stage, "VERSION"), "w") as f:
        f.write(version + "\n")
    with open(os.path.join(stage, "SOURCES"), "w") as f:
        f.write(f"Golem Engine {version} — built from Ardour, GPL-2.0-or-later (see COPYING).\n"
                f"Exact sources of this binary: {SOURCES_URL}/tree/{commit}\n"
                f"Bundled system libraries (deps/) keep their own licences.\n")
    tar = os.path.join(a.out, name + ".tar.gz")
    with tarfile.open(tar, "w:gz") as t:
        t.add(stage, arcname=name)
    sha = hashlib.sha256(open(tar, "rb").read()).hexdigest()
    with open(tar + ".sha256", "w") as f:
        f.write(f"{sha}  {os.path.basename(tar)}\n")
    size = os.path.getsize(tar) / 1e6
    print(f"bundle: {tar} ({size:.1f} MB) sha256 {sha}")
    print(f"bundle: {len(kept)} built files, {len(system)} system libraries in deps/, {len(skipped)} GUI libraries left out")
    return 0


_LIBPATH = ""
if __name__ == "__main__":
    sys.exit(main())
