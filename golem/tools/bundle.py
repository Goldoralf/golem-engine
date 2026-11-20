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


# ── WINDOWS (2026-11-20) : la même forme d'arbre, des .exe et des .dll ; deps/ = les DLL de MSYS2 UCRT64 dont le moteur
# a besoin (fermeture des imports PE, par objdump), JAMAIS celles de Windows (KERNEL32, l'UCRT api-ms-win-*…) ; lib/lv2 =
# les LV2 du moteur (golem/tools/win-lv2-deps.sh → .deps/lv2 ; golem/tools/windows/README.md dit d'où vient chacun)
WIN_PROGRAMS = ("build/luasession/ardour9-lua.exe", "build/golem/golem-place.exe", "build/libs/fst/ardour-vst3-scanner.exe",
                "build/session_utils/golem-engine9-export.exe", "build/session_utils/golem-engine9-new_session.exe",
                "build/session_utils/golem-engine9-new_empty_session.exe")
# l'interface graphique d'Ardour : pas dans le paquet, sauf ce que la surface OSC tire (son panneau de réglage)
WIN_GUI_DIRS = ("libs/tk/", "libs/widgets/", "libs/waveview/", "libs/gtkmm2ext/", "libs/canvas/")


def pe_imports(path, objdump):
    out = subprocess.run([objdump, "-p", path], capture_output=True, text=True).stdout
    return [line.split(":", 1)[1].strip() for line in out.splitlines() if line.strip().startswith("DLL Name:")]


def main_windows(a):
    msys = os.environ.get("GOLEM_ENGINE_MSYS") or r"C:\msys64\ucrt64"
    objdump = os.path.join(msys, "bin", "objdump.exe")
    if not os.path.isfile(objdump):
        raise SystemExit(f"bundle: {objdump} not found (MSYS2 UCRT64, mingw-w64-ucrt-x86_64-binutils)")
    describe = subprocess.run(["git", "-C", TOP, "describe", "--tags", "--always", "--dirty"], capture_output=True,
                              text=True).stdout.strip()
    commit = subprocess.run(["git", "-C", TOP, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    version = a.version or describe
    name = f"golem-engine-{version}-windows-x86_64"
    stage = os.path.join(a.out, name)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    for p in WIN_PROGRAMS:
        if not os.path.isfile(os.path.join(TOP, p)):
            raise SystemExit(f"bundle: {p} is missing — run golem/tools/win-build.sh first")
    lv2 = os.path.join(TOP, ".deps", "lv2")
    if not os.path.isdir(lv2):
        raise SystemExit("bundle: .deps/lv2 is missing — run golem/tools/win-lv2-deps.sh first")
    # toutes les DLL construites, par nom (les anciennes renommées par un rebuild, *.dll.old-*, n'en sont pas)
    built = {}
    for d, _dirs, files in os.walk(os.path.join(TOP, "build", "libs")):
        for f in files:
            if f.endswith(".dll"):
                built.setdefault(f.lower(), os.path.relpath(os.path.join(d, f), TOP).replace(os.sep, "/"))
    start = list(WIN_PROGRAMS)
    for rel in built.values():
        if "/surfaces/" in rel and "/surfaces/osc/" not in rel:
            continue
        if rel.startswith(tuple("build/" + g for g in WIN_GUI_DIRS)):
            continue
        start.append(rel)
    # les LV2 construits avec le moteur (le synthé de la basse des standards) : leurs .ttl
    extra = [os.path.relpath(os.path.join(d, f), TOP).replace(os.sep, "/")
             for d, _dirs, files in os.walk(os.path.join(TOP, "build", "libs", "LV2")) for f in files if f.endswith(".ttl")]
    kept, deps = set(), {}
    # les DLL des LV2 livrés comptent aussi : leurs imports MSYS2 partent dans deps/
    lv2_dlls = [os.path.join(d, f) for d, _dirs, files in os.walk(lv2) for f in files if f.lower().endswith(".dll")]
    scan = [(rel, os.path.join(TOP, rel)) for rel in start] + [(None, p) for p in lv2_dlls]
    seen = set()
    while scan:
        rel, path = scan.pop()
        if path in seen:
            continue
        seen.add(path)
        if rel:
            kept.add(rel)
        for imp in pe_imports(path, objdump):
            low = imp.lower()
            if low in built:
                scan.append((built[low], os.path.join(TOP, built[low])))
            elif os.path.isfile(os.path.join(msys, "bin", imp)):
                if low not in deps:
                    deps[low] = os.path.join(msys, "bin", imp)
                    scan.append((None, deps[low]))
            # sinon : une DLL de Windows (KERNEL32, USER32, api-ms-win-crt-*…) — jamais emportée
    for rel in sorted(kept) + extra:
        dst = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(TOP, rel), dst)
    os.makedirs(os.path.join(stage, "deps"))
    for _low, src in sorted(deps.items()):
        shutil.copy2(src, os.path.join(stage, "deps", os.path.basename(src)))
    shutil.copytree(lv2, os.path.join(stage, "lib", "lv2"))
    shutil.copytree(os.path.join(TOP, "golem", "engine"), os.path.join(stage, "golem", "engine"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    for d in DATA:
        if os.path.isdir(os.path.join(TOP, d)):
            shutil.copytree(os.path.join(TOP, d), os.path.join(stage, d))
    for f in FILES + ("golem/tools/windows/README.md",):
        if os.path.isfile(os.path.join(TOP, f)):
            os.makedirs(os.path.dirname(os.path.join(stage, f)), exist_ok=True)
            shutil.copy2(os.path.join(TOP, f), os.path.join(stage, f))
    with open(os.path.join(stage, "VERSION"), "w") as f:
        f.write(version + "\n")
    with open(os.path.join(stage, "SOURCES"), "w") as f:
        f.write(f"Golem Engine {version} — built from Ardour, GPL-2.0-or-later (see COPYING).\n"
                f"Exact sources of this binary: {SOURCES_URL}/tree/{commit}\n"
                f"Bundled MSYS2 libraries (deps/) keep their own licences (https://packages.msys2.org).\n"
                f"Bundled LV2 plugins (lib/lv2): their origin, version and licence are listed in\n"
                f"golem/tools/windows/README.md; setBfree is rebuilt from its sources with the patch next to it.\n"
                f"ASIO: PortAudio built with Steinberg's ASIO SDK 2.3.4 under its GPL v3 option.\n")
    tar = os.path.join(a.out, name + ".tar.gz")
    with tarfile.open(tar, "w:gz") as t:
        t.add(stage, arcname=name)
    sha = hashlib.sha256(open(tar, "rb").read()).hexdigest()
    with open(tar + ".sha256", "w") as f:
        f.write(f"{sha}  {os.path.basename(tar)}\n")
    print(f"bundle: {tar} ({os.path.getsize(tar) / 1e6:.1f} MB) sha256 {sha}")
    print(f"bundle: {len(kept)} built files, {len(deps)} MSYS2 libraries in deps/, {len(os.listdir(lv2))} LV2 bundles")
    return 0


_LIBPATH = ""
if __name__ == "__main__":
    if sys.platform == "win32":
        _ap = argparse.ArgumentParser()
        _ap.add_argument("--out", default=os.path.join(TOP, "build", "bundle"))
        _ap.add_argument("--version", default=None)
        sys.exit(main_windows(_ap.parse_args()))
    sys.exit(main())
