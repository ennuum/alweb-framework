# alweb.themes.registry — thèmes installés dans un projet : dossier themes/<slug>/, fichier alweb.lock (versions,
# empreintes, thème actif), installation depuis un dossier ou une archive .alwt (sans connexion), activation,
# retrait, version précédente gardée pour revenir en arrière.
#
#   reg := registry.Registry(".")                       # racine du projet
#   reg.install("dist/modern-business-1.0.0.alwt")      # ou un dossier de thème ; rend l'entrée du verrou
#   reg.activate("modern-business") ; reg.deactivate() ; reg.active()
#   reg.list() ; reg.info("modern-business") ; reg.remove("modern-business") ; reg.rollback("modern-business")
#
# Rien n'est exécuté pendant l'installation : l'archive est inspectée, extraite dans un dossier temporaire,
# validée (alweb.themes.validator), puis seulement mise en place.

from core use len, type
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use time as _time
use network.security as _sec
use alweb.themes.manifest as _manifest
use alweb.themes.validator as _validator
use alweb.themes.package as _package

const LOCK := "alweb.lock"
const DIR := "themes"
const ALWEB_VERSION := "0.9.0"

func _fail(message):
    raise("ThemeError", message)

func _copy_tree(src, dst):
    lf := _validator.list_files(src)
    if len(lf[1]) > 0:
        _fail(_s.join(" ; ", lf[1]))
    for f in lf[0]:
        p := _os.join(dst, f)
        _os.mkdir_all(_os.dirname(p))
        _io.write_file(p, _io.read_raw(_os.join(src, f)))

# Compatibilité d'un manifeste avec cet ALWEB et cet ALEX : liste d'erreurs.
func compatibility(m):
    errs := []
    if not _manifest.satisfies(ALWEB_VERSION, m["framework_version"]):
        append(errs, "le thème demande ALWEB " + m["framework_version"] + " (installé : " + ALWEB_VERSION + ")")
    if m["alex_version"] != null:
        ok := false
        try:
            ok = _os.alex_satisfies(m["alex_version"])
        catch e:
            ok = false
        if not ok:
            append(errs, "le thème demande ALEX " + m["alex_version"] + " (installé : " + str(_os.alex_version()) + ")")
    return errs

class Registry:
    func init(root="."):
        self.root = root
        self.dir = _os.join(root, DIR)
        self.lock_path = _os.join(root, LOCK)

    func lock():
        if not _os.isfile(self.lock_path):
            return {"lock_version": 1, "active": null, "themes": {}}
        d := _json.parse(_io.read_file(self.lock_path))
        if type(d) != "dict" or not ("themes" in d):
            _fail(LOCK + " : contenu invalide")
        if not ("active" in d):
            d["active"] = null
        return d

    func save(d):
        tmp := self.lock_path + ".tmp"
        _io.write_file(tmp, _json.pretty(d) + "\n")
        _os.move(tmp, self.lock_path)

    func path(slug):
        if not _manifest.valid_slug(slug):
            _fail("identifiant de thème invalide : " + str(slug))
        return _os.join(self.dir, slug)

    func installed(slug):
        return slug in self.lock()["themes"] and _os.isdir(self.path(slug))

    # Installe depuis un dossier de thème ou une archive .alwt ; rend l'entrée du verrou. Une version déjà
    # installée est gardée dans themes/.versions/ (rollback). force : réinstaller la même version.
    func install(source, force=false):
        if not _os.exists(source):
            _fail("source introuvable : " + source + " (dossier de thème ou archive .alwt ; la marketplace viendra ensuite)")
        _os.mkdir_all(self.dir)
        tmp := _os.join(self.dir, ".installation-" + _sec.random_hex(6))
        try:
            origin := "local"
            digest := null
            if _os.isdir(source):
                _copy_tree(source, tmp)
                origin = "dossier:" + _os.absolute(source)
            else:
                r := _package.extract(source, tmp)
                digest = r["sha256"]
                origin = "archive:" + _os.basename(source)
            rep := _validator.check(tmp)
            m := rep["manifest"]
            errs := compatibility(m)
            if len(errs) > 0:
                _fail("thème incompatible : " + _s.join(" ; ", errs))
            d := self.lock()
            for dep in m["dependencies"]:
                if not (dep["slug"] in d["themes"]):
                    _fail("dépendance absente : thème « " + dep["slug"] + " » (à installer d'abord)")
                if "version" in dep and not _manifest.satisfies(d["themes"][dep["slug"]]["version"], dep["version"]):
                    _fail("dépendance : « " + dep["slug"] + " » " + dep["version"] + " demandé, " + d["themes"][dep["slug"]]["version"] + " installé")
            slug := m["slug"]
            target := self.path(slug)
            previous := d["themes"][slug] if slug in d["themes"] else null
            if previous != null and previous["version"] == m["version"] and not force and _os.isdir(target):
                _fail("« " + slug + " » " + m["version"] + " est déjà installé (--force pour réinstaller)")
            if _os.isdir(target):
                if previous != null and previous["version"] != m["version"]:
                    keep := _os.join(self.dir, ".versions", slug + "-" + previous["version"])
                    if _os.exists(keep):
                        _os.rmdir(keep, true)
                    _os.mkdir_all(_os.dirname(keep))
                    _os.move(target, keep)
                else:
                    _os.rmdir(target, true)
            _os.move(tmp, target)
            entry := {"version": m["version"], "name": m["name"], "source": origin, "tree_sha256": _package.tree_sha256(target),
                      "framework_version": m["framework_version"], "installed_at": _time.time()}
            if digest != null:
                entry["archive_sha256"] = digest
            if previous != null and previous["version"] != m["version"]:
                entry["previous"] = previous["version"]
            d["themes"][slug] = entry
            if d["active"] == null:
                d["active"] = slug                  # le premier thème installé est activé
            self.save(d)
            return entry
        catch e:
            if _os.exists(tmp):
                _os.rmdir(tmp, true)
            raise(e)

    func activate(slug):
        d := self.lock()
        if not (slug in d["themes"]) or not _os.isdir(self.path(slug)):
            _fail("thème non installé : " + str(slug))
        m := _manifest.load(self.path(slug))
        errs := compatibility(m)
        if len(errs) > 0:
            _fail("thème incompatible : " + _s.join(" ; ", errs))
        d["active"] = slug
        self.save(d)
        return slug

    func deactivate():
        d := self.lock()
        before := d["active"]
        d["active"] = null
        self.save(d)
        return before

    func active():
        return self.lock()["active"]

    # [{slug, name, version, active, source}] triés par identifiant.
    func list():
        d := self.lock()
        out := []
        for slug in _validator._sort(keys(d["themes"])):
            e := d["themes"][slug]
            append(out, {"slug": slug, "name": e["name"], "version": e["version"], "active": slug == d["active"], "source": e["source"],
                         "present": _os.isdir(self.path(slug))})
        return out

    # Manifeste, entrée du verrou, état (contenu modifié depuis l'installation ?).
    func info(slug):
        d := self.lock()
        if not (slug in d["themes"]):
            _fail("thème non installé : " + str(slug))
        p := self.path(slug)
        m := _manifest.load(p)
        e := d["themes"][slug]
        return {"slug": slug, "manifest": m, "lock": e, "active": d["active"] == slug, "path": p,
                "modified": _package.tree_sha256(p) != e["tree_sha256"], "compatibility": compatibility(m)}

    func remove(slug):
        d := self.lock()
        if not (slug in d["themes"]):
            _fail("thème non installé : " + str(slug))
        for other in keys(d["themes"]):
            if other != slug:
                om := null
                try:
                    om = _manifest.load(self.path(other))
                catch e:
                    om = null
                if om != null:
                    for dep in om["dependencies"]:
                        if dep["slug"] == slug:
                            _fail("« " + other + " » dépend de « " + slug + " »")
        p := self.path(slug)
        if _os.isdir(p):
            _os.rmdir(p, true)
        rest := {}
        for k in keys(d["themes"]):
            if k != slug:
                rest[k] = d["themes"][k]
        d["themes"] = rest
        if d["active"] == slug:
            d["active"] = null
        self.save(d)
        return true

    # Revient à la version gardée lors de la dernière mise à jour (themes/.versions/<slug>-<version>).
    func rollback(slug):
        d := self.lock()
        if not (slug in d["themes"]) or not ("previous" in d["themes"][slug]):
            _fail("aucune version précédente gardée pour « " + str(slug) + " »")
        prev := d["themes"][slug]["previous"]
        keep := _os.join(self.dir, ".versions", slug + "-" + prev)
        if not _os.isdir(keep):
            _fail("version précédente introuvable : " + keep)
        cur := d["themes"][slug]["version"]
        p := self.path(slug)
        stash := _os.join(self.dir, ".versions", slug + "-" + cur)
        if _os.exists(stash):
            _os.rmdir(stash, true)
        _os.move(p, stash)
        _os.move(keep, p)
        m := _manifest.load(p)
        d["themes"][slug]["version"] = m["version"]
        d["themes"][slug]["previous"] = cur
        d["themes"][slug]["tree_sha256"] = _package.tree_sha256(p)
        self.save(d)
        return m["version"]
