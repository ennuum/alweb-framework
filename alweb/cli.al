# alweb.cli — la commande `alweb` : créer, lancer, tester, inspecter, migrer, construire et déployer un projet.
#
#   alweb new monblog                 projet depuis le modèle (modele/), dépendances installées
#   alweb run [--env prod] [--port N] lance main.al (profil dev : rechargement à chaud) ; --https : certificat
#                                     auto-signé de développement (.alweb/dev-tls/, créé en ALEX) et server.tls
#   alweb test [chemins] [--filter x] tests avec ALWEB_ENV=test
#   alweb routes [--json]             routes de l'application (méthodes, motif, nom)
#   alweb migrate [--status]          applique (ou liste) les migrations de modeles.MIGRATIONS
#   alweb jobs [--retry ID|tout] [--run]   file des tâches de fond : état, nouveaux essais, exécution
#   alweb i18n [--update] [--strict]  traductions : clés du code absentes des catalogues locales/<langue>.json
#   alweb theme <action> [cible]      thèmes (alweb.themes) : create, validate, package, install, activate,
#                                     deactivate, list, info, remove, rollback, check, preview ; marketplace :
#                                     search, install <slug>, update, publish, keygen, yank, review, reviews
#   alweb check                       analyse (alexc check) et mise en forme (alexc fmt --check)
#   alweb build [--native] [-o x]     exécutable autonome (VM embarquée) ou natif
#   alweb deploy systemd caddy ...    fichiers de déploiement dans deploy/ (systemd, caddy, nginx, docker)
#   alweb secret                      clé aléatoire pour ALWEB_SECRET_KEY
#
# Lancement : bin/alweb (sh) ou bin/alweb.cmd (Windows) du dépôt, ou `alexc run <paquet>/commande.al -- ...`.
# Conventions d'un projet (modifiables par un fichier alweb.json à la racine) :
#   {"entry": "main.al", "app": "application", "factory": "creer", "migrations": "modeles.MIGRATIONS",
#    "config": "config", "tests": "tests", "templates": "templates", "locales": "locales", "default_locale": "fr"}
# La commande s'appuie sur `alexc` (ALEX_EXE, sinon « alex » dans le PATH) : chaque action qui exécute le code du
# projet le fait dans un processus fils, depuis la racine du projet.
from core use len, type, to_int
from collections use append, keys
use os
use io as _io
use io.console as _console
use json as _json
use string as _s
use argparse
use network.security as _sec
use crypto.x509 as _x509
use time as _time
use alweb.messages as _msg
use alweb.themes.manifest as _tmanifest
use alweb.themes.validator as _tvalidator
use alweb.themes.package as _tpackage
use alweb.themes.registry as _tregistry
use alweb.themes.client as _tclient
use alweb.themes.signing as _tsigning

const VERSION := "0.9.0"
const ALEX_MIN := ">=1.3.0-beta.1"
const MARQUE := "@@ALWEB "
const CIBLES := ["systemd", "caddy", "nginx", "docker"]

# Domaines des modèles (`alweb new --domaine`, `alweb theme create --domaine`). Pour chacun : modele-theme/ puis la
# surcouche modele-theme-<domaine>/ (absente pour business) ; modele/ puis la surcouche modele-<domaine>/.
# category, description et mots-clés vont dans le manifeste du thème (alweb-theme.json).
const DOMAINS := ["business", "ecommerce", "blog", "portfolio"]
const DOMAIN_ALIASES := {"vitrine": "business", "entreprise": "business", "e-commerce": "ecommerce", "boutique": "ecommerce",
                         "commerce": "ecommerce", "shop": "ecommerce", "journal": "blog", "projets": "portfolio"}
const DOMAIN_INFO := {
    "business": ["Thème vitrine pour une entreprise : accueil, services, à propos, blog et contact.", "\"entreprise\", \"vitrine\", \"services\""],
    "ecommerce": ["Thème de boutique en ligne : catalogue, fiche produit, panier et commande.", "\"boutique\", \"e-commerce\", \"produits\", \"panier\""],
    "blog": ["Thème de blog : article à la une, catégories, barre latérale et lecture confortable.", "\"blog\", \"articles\", \"journal\""],
    "portfolio": ["Thème de portfolio : projets en grille, fiches détaillées avec galerie, contact.", "\"portfolio\", \"projets\", \"créatif\""]}

# Identifiant canonique d'un domaine (alias acceptés) ; null -> null.
func domain_of(name):
    if name == null or name == "":
        return null
    n := _s.lower(_s.trim(name))
    if n in DOMAIN_ALIASES:
        n = DOMAIN_ALIASES[n]
    if not (n in DOMAINS):
        _fail("domaine inconnu « " + name + " » : " + _s.join(", ", DOMAINS))
    return n

DEFAUTS := {"entry": "main.al", "app": "application", "factory": "creer", "migrations": "modeles.MIGRATIONS", "config": "config", "tests": "tests",
           "templates": "templates", "locales": "locales", "default_locale": "fr"}

func _fail(message):
    raise("AlwebCliError", message)

# ---------------------------------------------------------------------------------------------- chemins

# Dossier du paquet alweb (celui qui contient cli.al, modele/ et deploiement/) : ALWEB_HOME, sinon le dossier du
# programme lancé (commande.al), sinon null.
func home():
    h := os.getenv("ALWEB_HOME")
    if h != null and h != "" and os.isdir(os.join(h, "modele")):
        return os.absolute(h)
    a := os.argv()
    if len(a) > 0:
        d := os.dirname(os.absolute(a[0]))
        if os.isdir(os.join(d, "modele")):
            return d
    return null

func _slashes(p):
    return _s.replace(p, "\\", "/")

func _parts(p):
    out := []
    for x in _s.split(_slashes(os.normalize(os.absolute(p))), "/"):
        if x != "" and x != ".":
            append(out, x)
    return out

# Chemin relatif (séparateurs « / ») de from_dir vers to_dir, ou null s'il n'en existe pas (lecteurs Windows
# différents, chemins UNC distincts).
func relative_path(from_dir, to_dir):
    a := _parts(from_dir)
    b := _parts(to_dir)
    win := os.platform() == "windows"
    if len(a) == 0 or len(b) == 0:
        return null
    if win and _s.lower(a[0]) != _s.lower(b[0]):
        return null
    i := 0
    while i < len(a) and i < len(b) and (a[i] == b[i] or (win and _s.lower(a[i]) == _s.lower(b[i]))):
        i += 1
    if i == 0 and win:
        return null
    up := []
    j := i
    while j < len(a):
        append(up, "..")
        j += 1
    rest := b[i:len(b)]
    r := _s.join("/", up + rest)
    return "." if r == "" else r

# ---------------------------------------------------------------------------------------------- gabarits

# Remplace {{clé}} par sa valeur (sans espaces entre les accolades : la syntaxe {{ x }} des gabarits HTML est
# laissée intacte).
func render(text, vars):
    out := text
    for k in keys(vars):
        out = _s.replace(out, "{{" + k + "}}", str(vars[k]))
    return out

func _target_name(name, vars):
    n := render(name, vars)
    if n == "_gitignore":
        return ".gitignore"
    return n

func _skipped(name):
    return _s.ends_with(name, ".albc") or _s.ends_with(name, ".meta")

# Copie l'arborescence src dans dst : noms et contenus des fichiers « .tpl » substitués (suffixe retiré), autres
# fichiers recopiés tels quels. Un fichier « x.ajout » (surcouche d'un modèle) est ajouté à la fin de x. Un fichier
# existant n'est remplacé qu'avec force. skip : chemins relatifs à ne pas copier. Rend les chemins écrits
# (relatifs à dst, séparateurs « / »).
func generate(src, dst, vars, force=false, prefix="", skip=null):
    written := []
    os.mkdir_all(dst)
    for name in os.list_dir(src):
        if _skipped(name):
            continue
        sp := os.join(src, name)
        target := _target_name(name, vars)
        is_add := os.isfile(sp) and _s.ends_with(target, ".ajout")
        if is_add:
            target = target[0:len(target) - 6]
        is_tpl := os.isfile(sp) and _s.ends_with(target, ".tpl")
        if is_tpl:
            target = target[0:len(target) - 4]
        dp := os.join(dst, target)
        rel := target if prefix == "" else prefix + "/" + target
        if skip != null and rel in skip:
            continue
        if os.isdir(sp):
            for w in generate(sp, dp, vars, force, rel, skip):
                append(written, w)
            continue
        if is_add:
            text := render(_io.read_file(sp), vars) if is_tpl else _io.read_file(sp)
            _io.write_file(dp, (_io.read_file(dp) if os.isfile(dp) else "") + text)
            append(written, rel)
            continue
        if os.exists(dp) and not force:
            _fail(rel + " existe déjà (--force pour le remplacer)")
        if is_tpl:
            _io.write_file(dp, render(_io.read_file(sp), vars))
        else:
            _io.write_bytes(dp, _io.read_bytes(sp))
        append(written, rel)
    return written

# Modèle en couches : base, puis la surcouche (remplace ou complète). Rend les chemins écrits, sans doublon.
func generate_layers(base, overlay, dst, vars, force=false, skip=null):
    written := generate(base, dst, vars, force, "", skip)
    if overlay == null or not os.isdir(overlay):
        return written
    for w in generate(overlay, dst, vars, true, "", skip):
        if not (w in written):
            append(written, w)
    return written

func is_valid_name(n):
    if len(n) == 0 or len(n) > 64:
        return false
    first := n[0:1]
    if not (first >= "a" and first <= "z"):
        return false
    i := 0
    while i < len(n):
        c := n[i:i + 1]
        if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
            return false
        i += 1
    return true

func display_name(n):
    return _s.capitalize(_s.replace(n, "_", " "))

func make_secret(nbytes=32):
    return _sec.random_hex(nbytes)

func _toml_string(s):
    return "\"" + _s.replace(_s.replace(s, "\\", "\\\\"), "\"", "\\\"") + "\""

# Exigence de version d'ALEX écrite dans les projets : celle d'alweb, pas la version qui exécute la commande (qui
# rendrait le projet inutilisable avec un compilateur un peu plus ancien mais compatible).
func _alex_requirement():
    return ALEX_MIN

# Ligne [dependencies] vers alweb : dossier local (chemin relatif depuis le projet) si possible, sinon version du
# registre.
func dependency_line(project_dir, alweb_dir=null, version=null):
    if alweb_dir != null:
        rel := relative_path(project_dir, alweb_dir)
        if rel != null:
            return "alweb = { path = " + _toml_string(rel) + " }"
    return "alweb = " + _toml_string(version if version != null else "^" + VERSION)

# Crée un projet. opts : dir (dossier, défaut ./nom), description, alweb (dossier du paquet alweb à référencer ;
# défaut : home()), registry (vrai : dépendance par version du registre), force, database (« sqlite » par défaut,
# « alexdb » : serveur ALEX DB local, ou une URL sqlite:, postgres://, alexdb://). Rend {dir, files, dependency,
# database}.
func new_project(name, opts=null):
    o := opts if opts != null else {}
    if not is_valid_name(name):
        _fail("nom de projet invalide « " + name + " » : lettres minuscules, chiffres et _, en commençant par une lettre")
    if name == "alweb":
        _fail("un projet ne peut pas s'appeler « alweb » (il dépend du paquet alweb)")
    h := o["home"] if "home" in o and o["home"] != null else home()
    if h == null:
        _fail("modèle introuvable : définissez ALWEB_HOME (dossier du paquet alweb, qui contient modele/)")
    dir := o["dir"] if "dir" in o and o["dir"] != null else name
    dir = os.absolute(dir)
    force := "force" in o and o["force"] == true
    if os.exists(dir) and len(os.list_dir(dir)) > 0 and not force:
        _fail("le dossier " + dir + " existe et n'est pas vide (--force pour écrire dedans)")
    alweb_dir := null
    if not ("registry" in o and o["registry"] == true):
        alweb_dir = o["alweb"] if "alweb" in o and o["alweb"] != null else h
    dep := dependency_line(dir, alweb_dir)
    desc := o["description"] if "description" in o and o["description"] != null else "Application web " + display_name(name) + " (alweb)"
    url := database_url(name, o["database"] if "database" in o else null)
    vars := {"nom": name, "Nom": display_name(name), "description": desc, "dependance": dep, "alex": _alex_requirement(),
             "alweb_version": VERSION, "secret_dev": make_secret(24), "secret_test": make_secret(24),
             "database_url": _s.replace(_s.replace(url, "\\", "\\\\"), "\"", "\\\""),
             "database_create": "true" if _s.starts_with(url, "alexdb://") else "false"}
    dom := domain_of(o["domaine"] if "domaine" in o else null)
    if dom == null:
        plain := generate(os.join(h, "modele"), dir, vars, force)
        return {"dir": dir, "files": plain, "dependency": dep, "database": url, "domain": null, "theme": null}
    # site complet : pas de pages dans templates/ (elles cacheraient celles du thème), surcouche du domaine, thème
    # du domaine créé puis installé (actif) dans themes/
    overlay := os.join(h, "modele-" + dom)
    if not os.isdir(overlay):
        _fail("modèle de projet « " + dom + " » introuvable : " + overlay)
    files := generate_layers(os.join(h, "modele"), overlay, dir, vars, force, MODEL_PAGES_SKIPPED)
    slug := project_theme_slug(name)
    tmp := os.join(dir, ".alweb", "theme-" + slug)
    if os.exists(tmp):
        os.rmdir(tmp, true)
    create_theme(slug, {"dir": tmp, "nom": display_name(name), "domaine": dom, "modele": os.join(h, "modele-theme"),
                        "auteur": o["auteur"] if "auteur" in o else null})
    entry := null
    try:
        entry = _tregistry.Registry(dir).install(tmp, true)
    catch e:
        os.rmdir(tmp, true)
        raise(e)
    os.rmdir(tmp, true)
    return {"dir": dir, "files": files, "dependency": dep, "database": url, "domain": dom, "theme": slug, "theme_version": entry["version"]}

# Pages du modèle minimal laissées de côté pour un site complet (le thème fournit les siennes).
const MODEL_PAGES_SKIPPED := ["templates/base.html", "templates/index.html"]

# Identifiant du thème d'un projet : son nom, tirets à la place des « _ » (« ma_boutique » -> « ma-boutique »).
func project_theme_slug(name):
    s := _s.replace(name, "_", "-")
    while _s.contains(s, "--"):
        s = _s.replace(s, "--", "-")
    while _s.ends_with(s, "-"):
        s = s[0:len(s) - 1]
    if not _tmanifest.valid_slug(s):
        s = "theme-" + s
    return s if _tmanifest.valid_slug(s) else "theme-site"

# URL de la base d'un nouveau projet : choix « sqlite » (défaut), « alexdb » (serveur ALEX DB local, base du nom
# du projet ; identifiants à remplacer), ou URL donnée telle quelle.
func database_url(name, choice=null):
    if choice == null or choice == "" or choice == "sqlite":
        return "sqlite:" + name + ".db"
    if choice == "alexdb":
        return "alexdb://admin:changez-moi@127.0.0.1:5442/" + name
    if _s.starts_with(choice, "sqlite:") or _s.starts_with(choice, "postgres://") or _s.starts_with(choice, "postgresql://") or _s.starts_with(choice, "alexdb://"):
        return choice
    _fail("base inconnue « " + choice + " » : sqlite, alexdb, ou une URL sqlite:, postgres://, alexdb://")

# ---------------------------------------------------------------------------------------------- projet

# Racine du projet : le dossier qui contient alex.toml, en remontant depuis start.
func find_project(start=null):
    p := os.absolute(start if start != null else ".")
    while true:
        if os.isfile(os.join(p, "alex.toml")):
            return p
        parent := os.dirname(p)
        if parent == p or parent == "":
            return null
        p = parent
    return null

func _manifest_value(text, key):
    section := ""
    for raw in _s.split(_s.replace(text, "\r", ""), "\n"):
        line := _s.trim(raw)
        if _s.starts_with(line, "["):
            section = line
            continue
        if section != "[package]" or not _s.starts_with(line, key):
            continue
        eq := _s.find(line, "=")
        if eq < 0 or _s.trim(line[0:eq]) != key:
            continue
        v := _s.trim(line[eq + 1:len(line)])
        if len(v) >= 2 and (v[0:1] == "\"" or v[0:1] == "'"):
            return v[1:len(v) - 1]
        return v
    return null

# Réglages du projet : DEFAUTS, puis entry et name d'alex.toml, puis alweb.json.
func settings(project):
    st := {}
    for k in keys(DEFAUTS):
        st[k] = DEFAUTS[k]
    st["name"] = os.basename(project)
    mp := os.join(project, "alex.toml")
    if os.isfile(mp):
        text := _io.read_file(mp)
        e := _manifest_value(text, "entry")
        if e != null and e != "":
            st["entry"] = e
        n := _manifest_value(text, "name")
        if n != null and n != "":
            st["name"] = n
    jp := os.join(project, "alweb.json")
    if os.isfile(jp):
        extra := _json.parse(_io.read_file(jp))
        if type(extra) != "dict":
            _fail("alweb.json : objet JSON attendu")
        for k in keys(extra):
            if not (k in DEFAUTS):
                _fail("alweb.json : clé inconnue « " + k + " » (permises : " + _s.join(", ", keys(DEFAUTS)) + ")")
            st[k] = extra[k]
    for k in ["app", "factory"]:
        if not _is_dotted(st[k]):
            _fail("réglage « " + k + " » invalide : " + str(st[k]))
    if not _is_dotted(st["migrations"]) or _s.find(st["migrations"], ".") < 0:
        _fail("réglage « migrations » invalide (module.VARIABLE attendu) : " + str(st["migrations"]))
    return st

func _is_dotted(x):
    if type(x) != "str" or x == "":
        return false
    for part in _s.split(x, "."):
        if part == "":
            return false
        i := 0
        while i < len(part):
            c := part[i:i + 1]
            ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (i > 0 and c >= "0" and c <= "9")
            if not ok:
                return false
            i += 1
    return true

func _split_last(dotted):
    i := len(dotted) - 1
    while i >= 0 and dotted[i:i + 1] != ".":
        i -= 1
    return [dotted[0:i], dotted[i + 1:len(dotted)]]

# Script d'inspection des routes (exécuté depuis la racine du projet).
func routes_script(st):
    return render("""# Généré par `alweb routes` : charge l'application sans la lancer et décrit ses routes.
from collections use append
use json as _json
use alweb as _alweb
use {{app}} as _projet

_cfg := _alweb.load_config("{{config}}")
_app := _projet.{{factory}}(_cfg, ".")
_out := []
for _r in _app.routes():
    append(_out, {"methods": _r[0], "pattern": _r[1], "name": _r[2]})
print("{{marque}}" + _json.stringify(_out))
""", {"app": st["app"], "factory": st["factory"], "config": st["config"], "marque": MARQUE})

# Script des migrations : mode "status" (liste) ou "up" (applique).
func migrate_script(st, mode):
    mv := _split_last(st["migrations"])
    return render("""# Généré par `alweb migrate` : applique ou liste les migrations du projet.
use alweb as _alweb
use alweb.orm as _orm
use database.database as _dbm
use {{module}} as _m

_cfg := _alweb.load_config("{{config}}")
_url := _cfg.require("database.url")
if _url == "memory:" and "sqlite" in _dbm.backends():
    _url = "sqlite::memory:"
_db := _alweb.database(_url)
_migs := _m.{{var}}
try:
    if "{{mode}}" == "status":
        _done := await _orm.applied(_db)
        for _g in _migs:
            print(("[x] " if _g["version"] in _done else "[ ] ") + str(_g["version"]) + "  " + _g["name"])
        print("{{marque}}" + str(len(_done)) + "/" + str(len(_migs)))
    else:
        _new := await _orm.migrate(_db, _migs)
        for _v in _new:
            for _g in _migs:
                if _g["version"] == _v:
                    print("appliquée : " + str(_v) + "  " + _g["name"])
        print("{{marque}}" + str(len(_new)))
finally:
    await _db.close()
""", {"module": mv[0], "var": mv[1], "config": st["config"], "mode": mode, "marque": MARQUE})

# Script de la file de tâches (alweb jobs) : état, nouvel essai des tâches abandonnées, exécution de ce qui est dû.
func jobs_script(st, mode, arg):
    return render("""# Généré par `alweb jobs` : charge l'application, ouvre ses dépendances, agit sur app.jobs.
use json as _json
use alweb as _alweb
use {{app}} as _projet

_cfg := _alweb.load_config("{{config}}")
_app := _projet.{{factory}}(_cfg, ".")
if _app.jobs == null:
    print("{{marque}}" + _json.stringify({"erreur": "pas de file de tâches (alweb.jobs.Queue(app, …))"}))
else:
    await _app.start()
    try:
        _q := _app.jobs
        _r := {}
        if "{{mode}}" == "retry":
            _r["requeued"] = await _q.retry_failed(null if "{{arg}}" == "tout" else "{{arg}}")
        elif "{{mode}}" == "run":
            _r["executed"] = await _q.run_pending()
        _r["stats"] = await _q.stats()
        _r["failed"] = await _q.list("failed", 20)
        _r["pending"] = await _q.list("pending", 20)
        print("{{marque}}" + _json.stringify(_r))
    finally:
        await _app.stop()
""", {"app": st["app"], "factory": st["factory"], "config": st["config"], "mode": mode, "arg": arg, "marque": MARQUE})

func _write_script(project, name, text):
    d := os.join(os.join(project, "build"), "alweb")
    os.mkdir_all(d)
    p := os.join(d, name)
    _io.write_file(p, text)
    return p

# ---------------------------------------------------------------------------------------------- processus

func alex_program():
    e := os.executable()
    return e if e != null and e != "" else "alex"

# Exécute alex avec des variables d'environnement ajoutées, depuis dir ; flux hérités. Rend le code de sortie.
func run_alex(args, env=null, dir=null):
    return _with_context(env, dir, () => os.wait(os.spawn(alex_program(), args)))

# Comme run_alex, sortie capturée : {code, stdout, stderr}.
func capture_alex(args, env=null, dir=null):
    return _with_context(env, dir, () => os.run(alex_program(), args))

func _with_context(env, dir, fn):
    saved := {}
    if env != null:
        for k in keys(env):
            saved[k] = os.getenv(k)
            os.setenv(k, str(env[k]))
    here := os.cwd()
    if dir != null:
        os.chdir(dir)
    try:
        return fn()
    finally:
        if dir != null:
            os.chdir(here)
        for k in keys(saved):
            if saved[k] == null:
                os.unsetenv(k)
            else:
                os.setenv(k, saved[k])

func _marked(stdout):
    for line in _s.split(_s.replace(stdout, "\r", ""), "\n"):
        if _s.starts_with(line, MARQUE):
            return line[len(MARQUE):len(line)]
    return null

# Routes du projet : liste de {methods, pattern, name}. Lève AlwebCliError si l'application ne se charge pas.
func project_routes(project, env=null):
    st := settings(project)
    script := _write_script(project, "routes.al", routes_script(st))
    r := capture_alex(["run", script], env, project)
    m := _marked(r["stdout"])
    if r["code"] != 0 or m == null:
        _fail("l'application ne se charge pas (" + st["app"] + "." + st["factory"] + " ; autre organisation : alweb.json, voir docs/COMMANDE.md) :\n" + r["stdout"] + r["stderr"])
    return _json.parse(m)

func format_routes(routes):
    lines := []
    w := 8                                   # largeur affichée de « MÉTHODES » (len compte les octets)
    for r in routes:
        n := len(_s.join(",", r["methods"]))
        if n > w:
            w = n
    pw := 5
    for r in routes:
        if len(r["pattern"]) > pw:
            pw = len(r["pattern"])
    append(lines, "MÉTHODES" + _s.repeat(" ", w - 8) + "  " + _pad("MOTIF", pw) + "  NOM")
    for r in routes:
        append(lines, _pad(_s.join(",", r["methods"]), w) + "  " + _pad(r["pattern"], pw) + "  " + (r["name"] if r["name"] != null else ""))
    return _s.join("\n", lines)

func _pad(t, n):
    return t + _s.repeat(" ", n - len(t)) if len(t) < n else t

# ---------------------------------------------------------------------------------------------- déploiement

# Écrit les fichiers de déploiement des cibles (systemd, caddy, nginx, docker ; « tout ») dans <projet>/deploy.
# opts : domaine, dossier (sur le serveur), port, utilisateur, alex (exécutable sur le serveur), force.
func deploy(project, targets, opts=null, h=null):
    o := opts if opts != null else {}
    root := h if h != null else home()
    if root == null:
        _fail("gabarits de déploiement introuvables : définissez ALWEB_HOME")
    st := settings(project)
    wanted := []
    for t in targets:
        if t == "tout" or t == "all":
            for c in CIBLES:
                if not (c in wanted):
                    append(wanted, c)
        elif t in CIBLES:
            if not (t in wanted):
                append(wanted, t)
        else:
            _fail("cible inconnue « " + t + " » (permises : " + _s.join(", ", CIBLES) + ", tout)")
    if len(wanted) == 0:
        _fail("aucune cible (systemd, caddy, nginx, docker ou tout)")
    nom := st["name"]
    vars := {"nom": nom, "Nom": display_name(nom),
             "domaine": _opt(o, "domaine", nom + ".example.org"),
             "dossier": _opt(o, "dossier", "/srv/" + nom),
             "port": str(_opt(o, "port", 8000)),
             "utilisateur": _opt(o, "utilisateur", nom),
             "alex": _opt(o, "alex", "/usr/local/bin/alex"),
             "secret": make_secret(32)}
    force := "force" in o and o["force"] == true
    out := os.join(project, "deploy")
    written := []
    for t in wanted:
        for w in generate(os.join(os.join(root, "deploiement"), t), out, vars, force, "deploy"):
            append(written, w)
    # Docker lit .dockerignore à la racine du contexte (le projet) : déplacé là s'il n'y en a pas déjà un.
    di := os.join(out, ".dockerignore")
    if os.isfile(di):
        target := os.join(project, ".dockerignore")
        if not os.exists(target) or force:
            _io.write_file(target, _io.read_file(di))
            append(written, ".dockerignore")
        os.remove(di)
        written = [w for w in written if w != "deploy/.dockerignore"]
    return written

func _opt(o, k, default):
    return o[k] if k in o and o[k] != null else default

# ---------------------------------------------------------------------------------------------- commande

func parser():
    p := argparse.parser(prog="alweb", description="Outils des projets alweb : créer, lancer, tester, inspecter, migrer, construire, déployer.", version="%(prog)s " + VERSION)
    sp := p.add_subparsers({"dest": "cmd", "metavar": "commande"})

    n := sp.add_parser("new", {"help": "crée un projet depuis le modèle", "aliases": ["nouveau"]})
    n.add_argument("nom", {"help": "nom du projet (identifiant : minuscules, chiffres, _)"})
    n.add_argument("--dir", {"dest": "dir", "help": "dossier du projet (défaut : ./nom)"})
    n.add_argument("--description", {"dest": "description", "help": "description (alex.toml, README)"})
    n.add_argument("--alweb", {"dest": "alweb", "help": "dossier du paquet alweb à référencer (défaut : celui de cette commande)"})
    n.add_argument("--registre", {"dest": "registre", "action": "store_true", "help": "dépendre de la version du registre plutôt que d'un dossier"})
    n.add_argument("--sans-installation", {"dest": "sans_installation", "action": "store_true", "help": "ne lance pas alexc pkg install"})
    n.add_argument("--force", {"dest": "force", "action": "store_true", "help": "écrit dans un dossier non vide, remplace les fichiers"})
    n.add_argument("--base", {"dest": "base", "help": "base de données : sqlite (défaut), alexdb (serveur ALEX DB local), ou une URL"})
    n.add_argument("--domaine", {"dest": "domaine", "help": "site complet avec thème installé : business, ecommerce, blog, portfolio (sans : modèle minimal)"})

    r := sp.add_parser("run", {"help": "lance l'application (main.al)", "aliases": ["lancer"]})
    r.add_argument("--env", {"dest": "env", "help": "profil (dev, test, prod) ; défaut : ALWEB_ENV ou dev"})
    r.add_argument("--port", {"dest": "port", "type": "int", "help": "port (server.port)"})
    r.add_argument("--host", {"dest": "host", "help": "adresse d'écoute (server.host)"})
    r.add_argument("--https", {"dest": "https", "action": "store_true", "help": "HTTPS de développement (certificat auto-signé localhost dans .alweb/dev-tls/)"})

    t := sp.add_parser("test", {"help": "lance les tests avec ALWEB_ENV=test"})
    t.add_argument("chemins", {"nargs": "*", "help": "fichiers ou dossiers (défaut : tests)"})
    t.add_argument("--filter", {"dest": "filter", "help": "seulement les tests dont le nom contient ce texte"})
    t.add_argument("-j", {"dest": "jobs", "type": "int", "help": "fichiers en parallèle"})
    t.add_argument("--json", {"dest": "json", "action": "store_true", "help": "résultats en JSON Lines"})

    ro := sp.add_parser("routes", {"help": "liste les routes de l'application"})
    ro.add_argument("--json", {"dest": "json", "action": "store_true", "help": "sortie JSON"})

    m := sp.add_parser("migrate", {"help": "applique les migrations (modeles.MIGRATIONS)", "aliases": ["migrer"]})
    m.add_argument("--status", {"dest": "status", "action": "store_true", "help": "liste les migrations sans rien appliquer"})
    m.add_argument("--env", {"dest": "env", "help": "profil de configuration (défaut : ALWEB_ENV ou dev)"})

    jb := sp.add_parser("jobs", {"help": "file des tâches de fond (alweb.jobs) : état, nouveaux essais", "aliases": ["taches"]})
    jb.add_argument("--retry", {"dest": "retry", "help": "remet en file la tâche abandonnée ID (« tout » : toutes)"})
    jb.add_argument("--run", {"dest": "run", "action": "store_true", "help": "exécute maintenant ce qui est dû, puis s'arrête"})
    jb.add_argument("--env", {"dest": "env", "help": "profil de configuration (défaut : ALWEB_ENV ou dev)"})

    tr := sp.add_parser("i18n", {"help": "traductions : clés utilisées par le code et les gabarits, absentes des catalogues", "aliases": ["traductions"]})
    tr.add_argument("--update", {"dest": "update", "action": "store_true", "help": "ajoute les clés manquantes (vides) aux catalogues"})
    tr.add_argument("--strict", {"dest": "strict", "action": "store_true", "help": "code de sortie 1 s'il manque des traductions (intégration continue)"})
    tr.add_argument("--default", {"dest": "default", "help": "langue par défaut (réglage default_locale, « fr »)"})

    th := sp.add_parser("theme", {"help": "thèmes d'interface (alweb.themes) : create, validate, package, preview, install, activate, deactivate, list, info, remove, rollback, check ; marketplace : search, update, publish, keygen, yank, review, reviews", "aliases": ["themes"]})
    th.add_argument("action", {"help": "create (creer), validate (valider), package (empaqueter), preview (apercu), install (installer), activate (activer), deactivate (desactiver), list (lister), info, remove (supprimer), rollback (retour), check (verifier), search (chercher), update (mettre-a-jour), publish (publier), keygen (cle), yank (retirer), review (avis), reviews (lire-avis)"})
    th.add_argument("cible", {"nargs": "?", "help": "identifiant (slug[@contrainte] pour la marketplace), dossier du thème, archive .alwt ou texte cherché selon l'action"})
    th.add_argument("--dir", {"dest": "dir", "help": "create : dossier du nouveau thème (défaut : ./<identifiant>)"})
    th.add_argument("--nom", {"dest": "nom", "help": "create : nom affiché du thème"})
    th.add_argument("--auteur", {"dest": "auteur", "help": "create : auteur (défaut : utilisateur du système)"})
    th.add_argument("--domaine", {"dest": "domaine", "help": "create : business (défaut), ecommerce, blog, portfolio"})
    th.add_argument("--out", {"dest": "out", "help": "package : dossier de l'archive (défaut : dist)"})
    th.add_argument("--port", {"dest": "port", "type": "int", "help": "preview : port (défaut : 8001)"})
    th.add_argument("--force", {"dest": "force", "action": "store_true", "help": "create : écrire dans un dossier non vide ; install : réinstaller la même version"})
    th.add_argument("--json", {"dest": "json", "action": "store_true", "help": "sortie JSON (validate, list, info, search, update)"})
    th.add_argument("--registre", {"dest": "registre", "help": "marketplace : adresse (défaut : ALWEB_MARKETPLACE)"})
    th.add_argument("--jeton", {"dest": "jeton", "help": "publish, yank : jeton d'éditeur (défaut : ALWEB_MARKETPLACE_TOKEN)"})
    th.add_argument("--cle", {"dest": "cle", "help": "publish, keygen : fichier de la clé d'éditeur (défaut : ALWEB_PUBLISHER_KEY ou ~/.alweb/editeur.json)"})
    th.add_argument("--categorie", {"dest": "categorie", "help": "search : catégorie"})
    th.add_argument("--verifier", {"dest": "verifier", "action": "store_true", "help": "update : lister les mises à jour sans les installer"})
    th.add_argument("--nouvelle-cle", {"dest": "nouvelle_cle", "action": "store_true", "help": "install, update : accepter une clé d'éditeur différente de celle épinglée"})
    th.add_argument("--annuler", {"dest": "annuler", "action": "store_true", "help": "yank : remettre la version"})
    th.add_argument("--tri", {"dest": "tri", "help": "search : popular (défaut), recent, rating, downloads, name"})
    th.add_argument("--note", {"dest": "note", "type": "int", "help": "review : note de 1 à 5"})
    th.add_argument("--titre", {"dest": "titre", "help": "review : titre de l'avis"})
    th.add_argument("--texte", {"dest": "texte", "help": "review : texte de l'avis"})
    th.add_argument("--pseudo", {"dest": "pseudo", "help": "review : nom affiché (défaut : Anonyme)"})
    th.add_argument("--supprimer", {"dest": "supprimer", "action": "store_true", "help": "review : supprimer son avis"})

    sp.add_parser("check", {"help": "analyse le code (alexc check) et sa mise en forme (alexc fmt --check)", "aliases": ["verifier"]})

    b := sp.add_parser("build", {"help": "construit un exécutable", "aliases": ["construire"]})
    b.add_argument("--native", {"dest": "native", "action": "store_true", "help": "binaire natif (sans SQLite : ALEX DB ou PostgreSQL ; HTTPS par server.tls, TLS 1.3 en ALEX)"})
    b.add_argument("-o", {"dest": "output", "help": "fichier produit (défaut : dist/<nom>)"})

    d := sp.add_parser("deploy", {"help": "écrit les fichiers de déploiement dans deploy/", "aliases": ["deployer"]})
    d.add_argument("cibles", {"nargs": "+", "help": "systemd, caddy, nginx, docker ou tout"})
    d.add_argument("--domaine", {"dest": "domaine", "help": "nom de domaine (défaut : <nom>.example.org)"})
    d.add_argument("--dossier", {"dest": "dossier", "help": "dossier de l'application sur le serveur (défaut : /srv/<nom>)"})
    d.add_argument("--port", {"dest": "port", "type": "int", "help": "port local de l'application (défaut : 8000)"})
    d.add_argument("--utilisateur", {"dest": "utilisateur", "help": "compte système du service (défaut : <nom>)"})
    d.add_argument("--alex", {"dest": "alex", "help": "exécutable alex sur le serveur (défaut : /usr/local/bin/alex)"})
    d.add_argument("--force", {"dest": "force", "action": "store_true", "help": "remplace les fichiers existants"})

    s := sp.add_parser("secret", {"help": "affiche une clé aléatoire (ALWEB_SECRET_KEY)"})
    s.add_argument("--octets", {"dest": "octets", "type": "int", "default": 32, "help": "octets d'aléa (défaut : 32)"})

    sp.add_parser("version", {"help": "affiche la version"})
    return p

func _project_or_fail():
    p := find_project()
    if p == null:
        _fail("pas de projet ici (aucun alex.toml dans ce dossier ni au-dessus) ; `alweb new <nom>` en crée un")
    return p

func _val(a, k):
    return a[k] if k in a else null

# Exécute la commande ; rend le code de sortie. Les erreurs AlwebCliError deviennent « alweb: erreur: … ».
func main(argv=null):
    p := parser()
    a := p.parse_args(argv if argv != null else os.args())
    cmd := _val(a, "cmd")
    if cmd == null:
        print(p.format_help())
        return 2
    try:
        return _dispatch(cmd, a)
    catch e:
        if e.type in ["AlwebCliError", "ThemeError", "StorageError"]:
            _console.error("alweb: erreur: " + e.message + "\n")
            return 1
        raise(e.type, e.message)

func _dispatch(cmd, a):
    if cmd == "new" or cmd == "nouveau":
        return _cmd_new(a)
    if cmd == "run" or cmd == "lancer":
        return _cmd_run(a)
    if cmd == "test":
        return _cmd_test(a)
    if cmd == "routes":
        return _cmd_routes(a)
    if cmd == "migrate" or cmd == "migrer":
        return _cmd_migrate(a)
    if cmd == "jobs" or cmd == "taches":
        return _cmd_jobs(a)
    if cmd == "i18n" or cmd == "traductions":
        return _cmd_i18n(a)
    if cmd == "theme" or cmd == "themes":
        return _cmd_theme(a)
    if cmd == "check" or cmd == "verifier":
        return _cmd_check()
    if cmd == "build" or cmd == "construire":
        return _cmd_build(a)
    if cmd == "deploy" or cmd == "deployer":
        return _cmd_deploy(a)
    if cmd == "secret":
        print(make_secret(_val(a, "octets") if _val(a, "octets") != null else 32))
        return 0
    if cmd == "version":
        print("alweb " + VERSION)
        return 0
    _fail("commande inconnue : " + cmd)

func _cmd_new(a):
    res := new_project(a["nom"], {"dir": _val(a, "dir"), "description": _val(a, "description"), "alweb": _val(a, "alweb"),
                                  "registry": _val(a, "registre") == true, "force": _val(a, "force") == true,
                                  "database": _val(a, "base"), "domaine": _val(a, "domaine")})
    print("Projet créé dans " + res["dir"] + " (" + str(len(res["files"])) + " fichiers)")
    if res["domain"] != null:
        print("  domaine    : " + res["domain"] + " ; thème « " + res["theme"] + " » " + res["theme_version"] + " installé et actif (themes/" + res["theme"] + ", réglages : page Apparence ou config/theme." + res["theme"] + ".json)")
    print("  dépendance : " + res["dependency"])
    if _s.starts_with(res["database"], "alexdb://"):
        print("  base       : " + res["database"] + " (config/base.json ; ou ALWEB_DATABASE__URL)")
    if _val(a, "sans_installation") != true:
        code := run_alex(["pkg", "install"], null, res["dir"])
        if code != 0:
            _console.error("alweb: l'installation des dépendances a échoué (code " + str(code) + ") ; relancez `alexc pkg install` dans le projet\n")
            return code
    print("")
    print("Ensuite :")
    print("  cd " + relative_or_abs(res["dir"]))
    print("  alweb run        # http://127.0.0.1:8000/")
    print("  alweb test")
    return 0

func relative_or_abs(d):
    r := relative_path(os.cwd(), d)
    return r if r != null and not _s.starts_with(r, "../..") else d

func _cmd_run(a):
    project := _project_or_fail()
    st := settings(project)
    env := {}
    if _val(a, "env") != null:
        env["ALWEB_ENV"] = a["env"]
    if _val(a, "port") != null:
        env["ALWEB_SERVER__PORT"] = a["port"]
    if _val(a, "host") != null:
        env["ALWEB_SERVER__HOST"] = a["host"]
    if _val(a, "https") == true:
        f := dev_certificate(project)
        env["ALWEB_SERVER__TLS__CERT"] = f[0]
        env["ALWEB_SERVER__TLS__KEY"] = f[1]
        print("alweb: HTTPS de développement, certificat auto-signé " + relative_or_abs(f[0]))
        print("       (localhost, 127.0.0.1, ::1 ; curl --cacert " + relative_or_abs(f[0]) + ", ou l'accepter dans le navigateur)")
    return run_alex(["run", st["entry"]], env, project)

# Certificat de développement du projet : .alweb/dev-tls/localhost.pem et .key, créés en ALEX (clé P-256, un an)
# s'ils manquent ou expirent dans moins de 30 jours. Rend [certificat, clé] (chemins absolus).
func dev_certificate(project):
    d := os.join(project, ".alweb", "dev-tls")
    cert := os.join(d, "localhost.pem")
    key := os.join(d, "localhost.key")
    neuf := not os.exists(cert) or not os.exists(key)
    if not neuf:
        try:
            c := _x509.load_certificates(_io.read_raw(cert))[0]
            neuf = c.not_after < _x509.utc_text(_x509_now() + 30 * 86400)
        catch e:
            neuf = true
    if neuf:
        os.mkdir_all(d)
        pem := _x509.self_signed("localhost", ["localhost", "127.0.0.1", "::1"], 365)
        _io.write_file(key, pem[1])
        try:
            os.chmod(key, 384)
        catch e:
            ignored := e
        _io.write_file(cert, pem[0])
    return [os.absolute(cert), os.absolute(key)]

func _x509_now():
    return to_int(_time.time())

func _cmd_test(a):
    project := _project_or_fail()
    st := settings(project)
    args := ["test"]
    ch := _val(a, "chemins")
    if ch == null or len(ch) == 0:
        args = args + [st["tests"]]
    else:
        args = args + [os.absolute(c) for c in ch]
    if _val(a, "filter") != null:
        args = args + ["--filter", a["filter"]]
    if _val(a, "jobs") != null:
        args = args + ["-j", str(a["jobs"])]
    if _val(a, "json") == true:
        args = args + ["--json"]
    return run_alex(args, {"ALWEB_ENV": "test"}, project)

func _cmd_routes(a):
    project := _project_or_fail()
    routes := project_routes(project)
    if _val(a, "json") == true:
        print(_json.pretty(routes))
    else:
        print(format_routes(routes))
    return 0

func _cmd_migrate(a):
    project := _project_or_fail()
    st := settings(project)
    mode := "status" if _val(a, "status") == true else "up"
    script := _write_script(project, "migrate.al", migrate_script(st, mode))
    env := {"ALWEB_ENV": a["env"]} if _val(a, "env") != null else null
    r := capture_alex(["run", script], env, project)
    out := _s.replace(r["stdout"], "\r", "")
    for line in _s.split(out, "\n"):
        if line != "" and not _s.starts_with(line, MARQUE):
            print(line)
    m := _marked(out)
    if r["code"] != 0 or m == null:
        _console.error(r["stderr"])
        _fail("migrations en échec")
    if mode == "status":
        print(m + " migration(s) appliquée(s)")
    elif m == "0":
        print("base à jour")
    return 0

func _cmd_jobs(a):
    project := _project_or_fail()
    mode := "retry" if _val(a, "retry") != null else ("run" if _val(a, "run") == true else "status")
    d := project_jobs(project, mode, _val(a, "retry") if mode == "retry" else "", a["env"] if _val(a, "env") != null else null)
    print(format_jobs(d))
    return 0

# File de tâches du projet : {stats, failed, pending[, requeued | executed]}. mode : "status", "retry" (arg : id
# ou « tout »), "run". Lève AlwebCliError si l'application ne se charge pas ou n'a pas de file.
func project_jobs(project, mode="status", arg="", profile=null):
    st := settings(project)
    if _s.contains(arg, "\"") or _s.contains(arg, "\\"):
        _fail("identifiant de tâche invalide")
    script := _write_script(project, "file_de_taches.al", jobs_script(st, mode, arg))
    env := {"ALWEB_ENV": profile} if profile != null else null
    r := capture_alex(["run", script], env, project)
    m := _marked(_s.replace(r["stdout"], "\r", ""))
    if r["code"] != 0 or m == null:
        _console.error(r["stderr"])
        _fail("file de tâches illisible")
    d := _json.parse(m)
    if "erreur" in d:
        _fail(d["erreur"])
    return d

# Rapport lisible de `alweb jobs`.
func format_jobs(d):
    st := d["stats"]
    lines := []
    if "requeued" in d:
        append(lines, str(d["requeued"]) + " tâche(s) remise(s) en file")
    if "executed" in d:
        append(lines, str(d["executed"]) + " tâche(s) exécutée(s)")
    append(lines, "en attente " + str(st["pending"]) + " · en cours " + str(st["running"]) + " · faites " + str(st["done"]) + " · abandonnées " + str(st["failed"]))
    for kind in [["failed", "abandonnées"], ["pending", "en attente"]]:
        rows := d[kind[0]]
        if len(rows) > 0:
            append(lines, "")
            append(lines, kind[1] + " :")
            for r in rows:
                err := r["last_error"] if r["last_error"] != null else ""
                append(lines, "  " + r["id"] + "  " + r["name"] + "  essais " + str(r["attempts"]) + "/" + str(r["max_attempts"]) + ("  " + err if err != "" else ""))
    return _s.join("\n", lines)

# ---------------------------------------------------------------- thèmes (alweb theme)

THEME_ACTIONS := {"create": "create", "creer": "create", "validate": "validate", "valider": "validate",
                  "package": "package", "empaqueter": "package", "install": "install", "installer": "install",
                  "activate": "activate", "activer": "activate", "deactivate": "deactivate", "desactiver": "deactivate",
                  "list": "list", "lister": "list", "info": "info", "remove": "remove", "supprimer": "remove",
                  "rollback": "rollback", "retour": "rollback", "check": "check", "verifier": "check",
                  "preview": "preview", "apercu": "preview", "update": "update", "mettre-a-jour": "update", "publish": "publish", "publier": "publish",
                  "search": "search", "chercher": "search", "keygen": "keygen", "cle": "keygen", "yank": "yank", "retirer": "yank",
                  "review": "review", "avis": "review", "reviews": "reviews", "lire-avis": "reviews"}

# Fichier de la clé d'éditeur : --cle, ALWEB_PUBLISHER_KEY, ~/.alweb/editeur.json.
func publisher_key_path(opt=null):
    if opt != null and opt != "":
        return opt
    e := os.getenv("ALWEB_PUBLISHER_KEY")
    if e != null and e != "":
        return e
    h := os.home()
    if h == null or h == "":
        _fail("dossier personnel inconnu : --cle FICHIER")
    return os.join(h, ".alweb", "editeur.json")

func _market(a):
    return _tclient.Client(_val(a, "registre"), {"token": _val(a, "jeton")})

func format_search(items):
    if len(items) == 0:
        return "aucun thème trouvé"
    lines := []
    for i in items:
        note := ("  " + str(i["rating"]) + "/5 (" + str(i["reviews"]) + " avis)") if "rating" in i and i["rating"] != null else ""
        append(lines, i["slug"] + "  " + str(i["latest"]) + "  " + i["name"] + "  [" + i["category"] + "]  " + str(i["publisher"]) + "  " + str(i["downloads"]) + " téléchargement(s)" + note)
        if i["description"] != null and i["description"] != "":
            append(lines, "    " + i["description"])
    return _s.join("\n", lines)

func _theme_market(act, a, cible, js):
    if act == "keygen":
        p := publisher_key_path(_val(a, "cle"))
        if os.exists(p) and _val(a, "force") != true:
            _fail(p + " existe déjà (--force pour la remplacer : les thèmes déjà publiés restent liés à l'ancienne clé)")
        k := _tsigning.generate()
        _tsigning.save_key(p, k)
        print("clé d'éditeur : " + p + " (à garder secrète, et à sauvegarder)\nempreinte     : " + k["fingerprint"] + "\nclé publique  : " + k["public"])
        return 0
    if act == "search":
        items := _market(a).search(cible if cible != null else "", _val(a, "categorie"), _tregistry.ALWEB_VERSION, _val(a, "tri"))
        print(_json.stringify(items) if js else format_search(items))
        return 0
    if act == "publish":
        c := _market(a)
        k := _tsigning.load_key(publisher_key_path(_val(a, "cle")))
        src := cible if cible != null else "."
        archive := src
        if not (os.isfile(src) and _s.ends_with(src, ".alwt")):
            archive = _tpackage.build(src, _val(a, "out") if _val(a, "out") != null else "dist")["path"]
        r := c.publish(archive, k)
        print("publié : " + r["slug"] + " " + r["version"] + " sur " + c.url + "\n  sha256    : " + r["sha256"] + "\n  empreinte : " + r["fingerprint"] + "\n  page      : " + c.url + r["url"])
        return 0
    if act == "yank":
        spec := _tclient.parse_spec(_need(cible, "yank <identifiant>@<version>"))
        if spec[1] == null:
            _fail("alweb theme yank <identifiant>@<version>")
        r := _market(a).yank(spec[0], spec[1], _val(a, "annuler") == true)
        print(r["slug"] + " " + r["version"] + (" retirée (encore installable en la demandant exactement)" if r["yanked"] else " remise en service"))
        return 0
    if act == "reviews":
        slug := _need(cible, "reviews <identifiant>")
        d := _market(a).reviews(slug)
        if js:
            print(_json.stringify(d))
            return 0
        print(slug + " : " + (str(d["rating"]) + "/5, " + str(d["count"]) + " avis" if d["rating"] != null else "aucun avis"))
        for r in d["items"]:
            print("  " + _s.repeat("*", r["rating"]) + _s.repeat(".", 5 - r["rating"]) + "  " + (r["title"] + " — " if r["title"] != null else "") + r["author"] + (" (" + r["version"] + ")" if r["version"] != null else ""))
            if r["body"] != null:
                print("    " + _s.replace(r["body"], "\n", "\n    "))
        return 0
    reg := _tregistry.Registry(_project_or_fail())
    c := _market(a)
    if act == "review":
        slug := _need(cible, "review <identifiant> --note 1..5 [--titre T] [--texte X] [--pseudo NOM]")
        rt := _tclient.review_token_for(reg, c, slug)
        if _val(a, "supprimer") == true:
            r := c.delete_review(slug, rt[0])
            print("avis supprimé" if r["deleted"] else "aucun avis à supprimer")
            return 0
        if _val(a, "note") == null:
            _fail("alweb theme review " + slug + " --note 1..5 [--titre T] [--texte X] [--pseudo NOM]")
        r := c.review(slug, rt[0], {"rating": _val(a, "note"), "title": _val(a, "titre"), "body": _val(a, "texte"), "author": _val(a, "pseudo")}, rt[1])
        print(("avis publié" if r["status"] == "visible" else "avis enregistré, en attente de modération" if r["status"] == "pending" else "avis enregistré (masqué par la modération)") +
              (" (il remplace le précédent)" if not r["created"] else ""))
        return 0
    if act == "install":
        spec := _tclient.parse_spec(cible)
        e := _tclient.install(reg, c, spec[0], spec[1], _val(a, "force") == true, _val(a, "nouvelle_cle") == true)
        print("installé depuis " + c.url + " : " + e["name"] + " " + e["version"] + (" (remplace " + e["previous"] + ")" if "previous" in e else "") +
              "\n  éditeur : " + e["publisher"] + " (clé " + _tsigning.fingerprint(e["publisher_key"]) + ", signature vérifiée)\nthème actif : " + str(reg.active()) +
              (wire_message(_project_or_fail()) if reg.active() != null else ""))
        return 0
    if act == "update":
        ups := _tclient.updates(reg, c, cible)
        if _val(a, "verifier") == true or len(ups) == 0:
            if js:
                print(_json.stringify(ups))
            elif len(ups) == 0:
                print("tous les thèmes de " + c.url + " sont à jour")
            else:
                for u in ups:
                    print(u["slug"] + "  " + u["installed"] + " -> " + u["available"])
            return 0
        for u in ups:
            e := _tclient.install(reg, c, u["slug"], u["available"], false, _val(a, "nouvelle_cle") == true)
            print("mis à jour : " + u["slug"] + " " + u["installed"] + " -> " + e["version"] + " (alweb theme rollback " + u["slug"] + " pour revenir en arrière)")
        return 0
    _fail("action non prise en charge : " + act)

# ---------------------------------------------------------------------------------------------- branchement

const THEME_USE := "use alweb.themes as themes"

# Branche les thèmes dans l'application du projet, une seule fois, après `alweb theme install` ou `activate` :
# dans le module de l'application (réglage « app », défaut application.al), la ligne
#     app.use_templates(os.join(dossier, "templates"))
# devient
#     themes.setup(app, null, {"root": dossier})
# et `use alweb.themes as themes` s'ajoute après le dernier import. themes.setup charge le thème actif (alweb.lock)
# et garde templates/ de l'application en priorité ; sans thème actif, il ne charge que templates/.
# Rend [état, fichier] ; état : "branche" (fichier modifié), "deja" (themes.setup déjà présent), "manuel" (forme
# non reconnue : rien n'est modifié, à faire à la main).
func wire_theme(project):
    st := settings(project)
    p := os.join(project, _s.replace(st["app"], ".", "/") + ".al")
    if not os.isfile(p):
        return ["manuel", p]
    text := _io.read_file(p)
    if _s.contains(text, "themes.setup("):
        return ["deja", p]
    if _s.contains(text, "alweb.themes"):
        return ["manuel", p]
    nl := "\r\n" if _s.contains(text, "\r\n") else "\n"
    lines := _s.split(_s.replace(text, "\r\n", "\n"), "\n")
    debut := "app.use_templates(os.join("
    fin := ", \"" + st["templates"] + "\"))"
    last_use := -1
    found := -1
    i := 0
    for raw in lines:
        line := _s.trim(raw)
        if len(raw) > 0 and raw[0:1] != " " and raw[0:1] != "\t" and (_s.starts_with(line, "use ") or _s.starts_with(line, "from ")):
            last_use = i
        if found < 0 and _s.starts_with(line, debut) and _s.ends_with(line, fin) and len(line) > len(debut) + len(fin):
            found = i
        i += 1
    if found < 0 or last_use < 0:
        return ["manuel", p]
    out := []
    i = 0
    for raw in lines:
        if i == found:
            line := _s.trim(raw)
            root := line[len(debut):len(line) - len(fin)]
            opts := "{\"root\": " + root + "}" if st["templates"] == "templates" else "{\"root\": " + root + ", \"templates\": \"" + st["templates"] + "\"}"
            append(out, raw[0:_s.find(raw, "app.")] + "themes.setup(app, null, " + opts + ")     # thème actif (alweb.lock) ; sinon " + st["templates"] + "/ seul")
        else:
            append(out, raw)
        if i == last_use:
            append(out, THEME_USE)
        i += 1
    _io.write_file(p, _s.join(nl, out))
    return ["branche", p]

# Gabarits du modèle de projet (`alweb new`) restés tels quels : ils passeraient avant ceux du thème (templates/ de
# l'application est prioritaire) et cacheraient sa mise en page. base.html identique à celui du modèle est renommé
# en base.html.sans-theme (remettez-le en place pour revenir à la page simple). Un fichier modifié n'est jamais
# touché. Rend les fichiers mis de côté.
const MODEL_PAGES := ["base.html"]

func set_aside_model_templates(project):
    h := home()
    out := []
    if h == null:
        return out
    st := settings(project)
    for n in MODEL_PAGES:
        p := os.join(project, st["templates"], n)
        m := os.join(h, "modele", "templates", n)
        if os.isfile(p) and os.isfile(m) and not os.exists(p + ".sans-theme") and _io.read_file(p) == _io.read_file(m):
            os.move(p, p + ".sans-theme")
            append(out, st["templates"] + "/" + n)
    return out

# Message affiché après une installation ou une activation.
func wire_message(project):
    r := null
    aside := []
    try:
        r = wire_theme(project)
        aside = set_aside_model_templates(project)
    catch e:
        return "\nà faire : branchez le thème dans l'application (" + str(e.message) + ") ; voir docs/THEMES.md"
    if len(aside) > 0:
        return _wire_text(project, r) + "\nmis de côté (page du modèle qui cachait le thème) : " + _s.join(", ", aside) + " -> .sans-theme"
    return _wire_text(project, r)

func _wire_text(project, r):
    f := r[1][len(project) + 1:len(r[1])] if _s.starts_with(r[1], project) and len(r[1]) > len(project) else r[1]
    if r[0] == "branche":
        return "\napplication : thème branché dans " + f + " (themes.setup) ; redémarrez l'application"
    if r[0] == "deja":
        return "\nredémarrez l'application pour l'utiliser"
    return "\nà faire : dans " + f + ", ajoutez « " + THEME_USE + " » et appelez themes.setup(app, null, {\"root\": dossier}) à la place de app.use_templates(…) ; voir docs/THEMES.md"

# Nom affiché d'un identifiant : « modern-business » -> « Modern Business ».
func theme_display_name(slug):
    out := []
    for w in _s.split(slug, "-"):
        if w != "":
            append(out, _s.upper(w[0:1]) + w[1:len(w)])
    return _s.join(" ", out)

# Crée un thème depuis le modèle (modele-theme/ du paquet alweb) ; rend les fichiers écrits.
func create_theme(slug, opts=null):
    o := opts if opts != null else {}
    if not _tmanifest.valid_slug(slug):
        _fail("identifiant de thème invalide : « " + str(slug) + " » (minuscules, chiffres et tirets, ex. modern-business)")
    src := o["modele"] if "modele" in o and o["modele"] != null else (os.join(home(), "modele-theme") if home() != null else null)
    if src == null or not os.isdir(src):
        _fail("modèle de thème introuvable (modele-theme/ du paquet alweb ; ALWEB_HOME)")
    d := o["dir"] if "dir" in o and o["dir"] != null else slug
    if os.isdir(d) and len(os.list_dir(d)) > 0 and not ("force" in o and o["force"] == true):
        _fail(d + " existe et n'est pas vide (--force pour écrire quand même)")
    u := "auteur"
    try:
        u = os.username()
    catch e:
        u = "auteur"
    dom := domain_of(o["domaine"] if "domaine" in o else null)
    if dom == null:
        dom = "business"
    vars := {"nom": o["nom"] if "nom" in o and o["nom"] != null else theme_display_name(slug), "slug": slug,
             "auteur": o["auteur"] if "auteur" in o and o["auteur"] != null else u,
             "annee": str(_time.gmtime()["year"]), "alweb_version": VERSION,
             "categorie": dom, "description": DOMAIN_INFO[dom][0], "mots_cles": DOMAIN_INFO[dom][1]}
    for k in ["nom", "auteur"]:
        if _s.contains(vars[k], "\"") or _s.contains(vars[k], "\\"):
            _fail(k + " : guillemets et barres obliques inverses refusés")
    overlay := os.join(os.dirname(src), "modele-theme-" + dom) if dom != "business" else null
    if overlay != null and not os.isdir(overlay):
        _fail("modèle de thème « " + dom + " » introuvable : " + overlay)
    return generate_layers(src, overlay, d, vars, "force" in o and o["force"] == true)

func format_validation(r):
    lines := []
    m := r["manifest"]
    if m != null:
        append(lines, m["name"] + " " + m["version"] + " (" + m["slug"] + ") : " + str(len(r["files"])) + " fichiers, " + str(r["size"]) + " octets")
    for e in r["errors"]:
        append(lines, "  erreur : " + e)
    for w in r["warnings"]:
        append(lines, "  remarque : " + w)
    append(lines, "thème valide" if len(r["errors"]) == 0 else str(len(r["errors"])) + " erreur(s)")
    return _s.join("\n", lines)

func _cmd_theme(a):
    act := _val(a, "action")
    if not (act in THEME_ACTIONS):
        _fail("action inconnue : " + str(act) + " (create, validate, package, preview, install, activate, deactivate, list, info, remove, rollback, check, search, update, publish, keygen, yank, review, reviews)")
    act = THEME_ACTIONS[act]
    cible := _val(a, "cible")
    js := _val(a, "json") == true
    if act in ["search", "publish", "keygen", "yank", "update", "review", "reviews"]:
        return _theme_market(act, a, cible, js)
    if act == "install" and cible != null and not os.exists(cible) and _tmanifest.valid_slug(_tclient.parse_spec(cible)[0]):
        return _theme_market(act, a, cible, js)                 # identifiant : depuis la marketplace
    if act == "create":
        if cible == null:
            _fail("alweb theme create <identifiant>")
        dom := domain_of(_val(a, "domaine"))
        w := create_theme(cible, {"dir": _val(a, "dir"), "nom": _val(a, "nom"), "auteur": _val(a, "auteur"), "force": _val(a, "force"), "domaine": dom})
        d := _val(a, "dir") if _val(a, "dir") != null else cible
        print("Thème « " + (dom if dom != null else "business") + " » créé dans " + d + " (" + str(len(w)) + " fichiers)\n\nEnsuite :\n  cd " + d + "\n  alweb theme validate\n  alweb theme preview\n  alweb theme package")
        return 0
    if act == "validate":
        r := _tvalidator.validate(cible if cible != null else ".")
        print(_json.stringify({"errors": r["errors"], "warnings": r["warnings"], "files": len(r["files"]), "size": r["size"]}) if js else format_validation(r))
        return 0 if len(r["errors"]) == 0 else 1
    if act == "package":
        r := _tpackage.build(cible if cible != null else ".", _val(a, "out") if _val(a, "out") != null else "dist")
        print("archive : " + r["path"] + " (" + str(r["size"]) + " octets, " + str(r["files"]) + " fichiers)\nsha256  : " + r["sha256"])
        return 0
    if act == "preview":
        d := cible if cible != null else "."
        _tvalidator.check(d)
        h := home()
        if h == null:
            _fail("paquet alweb introuvable (ALWEB_HOME)")
        port := _val(a, "port") if _val(a, "port") != null else 8001
        return run_alex(["run", os.join(h, "outils", "apercu.al"), "--", os.absolute(d), str(port)])
    reg := _tregistry.Registry(_project_or_fail())
    if act == "install":
        if cible == null:
            _fail("alweb theme install <identifiant[@contrainte] | archive.alwt | dossier du thème>")
        e := reg.install(cible, _val(a, "force") == true)
        print("installé : " + e["name"] + " " + e["version"] + (" (remplace " + e["previous"] + ")" if "previous" in e else "") + "\nthème actif : " + str(reg.active()) +
              (wire_message(_project_or_fail()) if reg.active() != null else ""))
        return 0
    if act == "activate":
        print("thème actif : " + reg.activate(_need(cible, "activate <identifiant>")) + wire_message(_project_or_fail()))
        return 0
    if act == "deactivate":
        b := reg.deactivate()
        print("aucun thème actif" + (" (était : " + b + ")" if b != null else ""))
        return 0
    if act == "list":
        l := reg.list()
        if js:
            print(_json.stringify(l))
        elif len(l) == 0:
            print("aucun thème installé (alweb theme install <archive.alwt>)")
        else:
            for t in l:
                print(("* " if t["active"] else "  ") + t["slug"] + "  " + t["version"] + "  " + t["name"] + "  " + t["source"] + ("" if t["present"] else "  (dossier absent)"))
        return 0
    if act == "info":
        i := reg.info(_need(cible, "info <identifiant>"))
        if js:
            print(_json.stringify(i))
        else:
            m := i["manifest"]
            print(m["name"] + " " + m["version"] + (" — actif" if i["active"] else "") + "\n  " + m["description"] + "\n  auteur : " + m["author"] + " · licence : " + m["license"] + " · catégorie : " + m["category"] +
                  "\n  ALWEB " + m["framework_version"] + (" · ALEX " + m["alex_version"] if m["alex_version"] != null else "") + "\n  source : " + i["lock"]["source"] + "\n  dossier : " + i["path"] +
                  ("\n  attention : contenu modifié depuis l'installation" if i["modified"] else "") + ("\n  incompatible : " + _s.join(" ; ", i["compatibility"]) if len(i["compatibility"]) > 0 else ""))
        return 0
    if act == "remove":
        reg.remove(_need(cible, "remove <identifiant>"))
        print("supprimé : " + cible)
        return 0
    if act == "rollback":
        print(cible + " revenu à la version " + reg.rollback(_need(cible, "rollback <identifiant>")))
        return 0
    if act == "check":
        s := cible if cible != null else reg.active()
        if s == null:
            _fail("aucun thème actif (alweb theme activate <identifiant>)")
        i := reg.info(s)
        r := _tvalidator.validate(i["path"])
        errs := i["compatibility"] + r["errors"]
        if i["modified"]:
            append(errs, "contenu modifié depuis l'installation (copiez les pages à adapter dans templates/ du projet)")
        print(s + " " + i["manifest"]["version"] + " : " + ("compatible et valide" if len(errs) == 0 else _s.join(" ; ", errs)))
        return 0 if len(errs) == 0 else 1
    _fail("action non prise en charge : " + act)

func _need(v, usage):
    if v == null:
        _fail("alweb theme " + usage)
    return v

# ---------------------------------------------------------------- traductions (alweb i18n)

func _cmd_i18n(a):
    project := _project_or_fail()
    d := project_i18n(project, _val(a, "update") == true, _val(a, "default"))
    print(format_i18n(d))
    if _val(a, "strict") == true and d["total_missing"] > 0:
        return 1
    return 0

func _is_ident_char(c):
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "."

# Littéral de chaîne qui commence en text[i] (guillemet simple ou double) : [valeur, position après] ou null.
func _string_at(text, i):
    q := text[i:i + 1]
    if q != "\"" and q != "'":
        return null
    out := ""
    j := i + 1
    n := len(text)
    while j < n:
        c := text[j:j + 1]
        if c == "\\" and j + 1 < n:
            nx := text[j + 1:j + 2]
            out = out + ("\n" if nx == "n" else ("\t" if nx == "t" else nx))
            j += 2
            continue
        if c == q:
            return [out, j + 1]
        if c == "\n":
            return null
        out = out + c
        j += 1
    return null

func _skip_spaces(text, i):
    while i < len(text) and (text[i:i + 1] == " " or text[i:i + 1] == "\t"):
        i += 1
    return i

# Clés de traduction d'un texte (gabarit ou code ALEX) : _("…"), _n("…", n), x.t("…"), x.n("…", n),
# x.markup("…") et "…" | t. Rend des paires [clé, pluriel].
func extract_i18n_keys(text):
    out := []
    n := len(text)
    i := 0
    while i < n:
        c := text[i:i + 1]
        if c == "(":
            # nom de fonction juste avant la parenthèse
            k := i - 1
            while k >= 0 and _is_ident_char(text[k:k + 1]):
                k -= 1
            name := text[k + 1:i]
            plural := false
            hit := false
            if name == "_" or name == "_n":
                hit = true
                plural = name == "_n"
            else:
                for suf in [".t", ".n", ".markup", ".markup_n"]:
                    if _s.ends_with(name, suf):
                        hit = true
                        plural = suf == ".n" or suf == ".markup_n"
            if hit:
                s := _string_at(text, _skip_spaces(text, i + 1))
                if s != null:
                    append(out, [s[0], plural])
        elif c == "\"" or c == "'":
            s := _string_at(text, i)
            if s != null:
                j := _skip_spaces(text, s[1])
                if text[j:j + 1] == "|":
                    j = _skip_spaces(text, j + 1)
                    if text[j:j + 1] == "t" and (j + 1 >= n or not _is_ident_char(text[j + 1:j + 2])):
                        append(out, [s[0], false])
                i = s[1]
                continue
        i += 1
    return out

func _project_files(project, rel, exts):
    out := []
    d := project if rel == "" else os.join(project, rel)
    if not os.isdir(d):
        return out
    for n in os.list_dir(d):
        r := n if rel == "" else rel + "/" + n
        p := os.join(d, n)
        if os.isdir(p):
            if n == "build" or n == "dist" or n == "alex_packages" or n == "deploy" or n == "node_modules" or n[0:1] == ".":
                continue
            out = out + _project_files(project, r, exts)
        else:
            for e in exts:
                if _s.ends_with(n, e):
                    append(out, r)
    return out

# Clé qui ressemble à un identifiant (« compte.titre ») plutôt qu'à un texte de la langue par défaut.
func _looks_like_id(key):
    return not _s.contains(key, " ") and (_s.contains(key, ".") or _s.contains(key, "_")) and not _s.contains(key, "{")

func _flat_keys(d, prefix, out):
    for k in keys(d):
        v := d[k]
        if type(v) == "dict":
            plural := "other" in v
            for kk in keys(v):
                if not (kk in ["zero", "one", "two", "few", "many", "other"]):
                    plural = false
            if not plural:
                _flat_keys(v, prefix + k + ".", out)
                continue
        out[prefix + k] = v
    return out

# Rapport des traductions du projet : {default, keys (nombre), locales: {code: {missing, unused}}, total_missing,
# updated}. update : clés manquantes ajoutées (texte vide, ou {"one": "", "other": ""} pour un pluriel) ; une
# valeur vide compte toujours comme manquante et l'application retombe sur la langue par défaut.
func project_i18n(project, update=false, default=null):
    st := settings(project)
    dflt := default if default != null else st["default_locale"]
    used := {}
    order := []
    for f in _project_files(project, "", [".al"]) + _project_files(project, st["templates"], [".html", ".txt", ".xml", ".md"]):
        for kp in extract_i18n_keys(_io.read_file(os.join(project, f))):
            if not (kp[0] in used):
                append(order, kp[0])
                used[kp[0]] = kp[1]
            elif kp[1]:
                used[kp[0]] = true
    ldir := os.join(project, st["locales"])
    report := {"default": dflt, "keys": len(order), "locales": {}, "total_missing": 0, "updated": []}
    if not os.isdir(ldir):
        if update:
            os.mkdir_all(ldir)
        else:
            return report
    files := []
    for n in os.list_dir(ldir):
        if _s.ends_with(n, ".json"):
            append(files, n)
    for n in files:
        code := n[0:len(n) - 5]
        path := os.join(ldir, n)
        raw := _json.parse(_io.read_file(path))
        if type(raw) != "dict":
            _fail(path + " : objet JSON attendu")
        flat := _flat_keys(raw, "", {})
        missing := []
        for k in order:
            need := code != dflt or used[k] or _looks_like_id(k)
            v := flat[k] if k in flat else null
            empty := v == null or v == "" or (type(v) == "dict" and ("other" in v) and (v["other"] == null or v["other"] == ""))
            b := _s.split(code, "-")[0]
            builtin := (code in _msg.CATALOGS and k in _msg.CATALOGS[code]) or (b in _msg.CATALOGS and k in _msg.CATALOGS[b])
            if need and empty and not builtin:
                append(missing, k)
                if update and not (k in flat):
                    raw[k] = {"one": "", "other": ""} if used[k] else ""
        unused := []
        for k in keys(flat):
            if not (k in used):
                append(unused, k)
        report["locales"][code] = {"missing": missing, "unused": unused}
        report["total_missing"] = report["total_missing"] + len(missing)
        if update and len(missing) > 0:
            _json.save(path, raw)
            append(report["updated"], st["locales"] + "/" + n)
    return report

func format_i18n(d):
    lines := [str(d["keys"]) + " clé(s) de traduction dans le code et les gabarits (langue par défaut : " + d["default"] + ")"]
    codes := keys(d["locales"])
    if len(codes) == 0:
        append(lines, "aucun catalogue (locales/<langue>.json)")
    for code in codes:
        r := d["locales"][code]
        append(lines, "")
        append(lines, code + " : " + str(len(r["missing"])) + " manquante(s)" + (", " + str(len(r["unused"])) + " non trouvée(s) dans le code" if len(r["unused"]) > 0 else ""))
        for k in r["missing"]:
            append(lines, "  - " + k)
        for k in r["unused"]:
            append(lines, "  ? " + k)
    for f in d["updated"]:
        append(lines, "mis à jour : " + f)
    return _s.join("\n", lines)

func _cmd_check():
    project := _project_or_fail()
    st := settings(project)
    code := run_alex(["check", st["entry"]], null, project)
    if code != 0:
        return code
    files := []
    for f in [st["entry"]] + _project_al_files(project):
        if not (f in files):
            append(files, f)
    code = run_alex(["fmt", "--check"] + files, null, project)
    if code == 0:
        print("alweb: code et mise en forme corrects")
    return code

# Fichiers .al du projet (relatifs), hors build/, dist/, alex_packages/ et dossiers cachés.
func _project_al_files(project, rel=""):
    out := []
    d := project if rel == "" else os.join(project, rel)
    for n in os.list_dir(d):
        r := n if rel == "" else rel + "/" + n
        p := os.join(d, n)
        if os.isdir(p):
            if n == "build" or n == "dist" or n == "alex_packages" or n == "deploy" or n[0:1] == ".":
                continue
            out = out + _project_al_files(project, r)
        elif _s.ends_with(n, ".al"):
            append(out, r)
    return out

func _cmd_build(a):
    project := _project_or_fail()
    st := settings(project)
    output := _val(a, "output")
    if output == null:
        os.mkdir_all(os.join(project, "dist"))
        output = os.join("dist", st["name"])
    else:
        output = os.absolute(output)
    mode := "--native" if _val(a, "native") == true else "--standalone"
    if mode == "--native":
        print("alweb: binaire natif : pas de SQLite (base ALEX DB ou PostgreSQL) ; HTTPS : server.tls (TLS 1.3 en ALEX) ou mandataire")
    code := run_alex(["build", st["entry"], mode, "-o", output], null, project)
    if code == 0:
        print("alweb: " + output + " construit ; lancez-le depuis la racine du projet (config/, templates/, static/)")
        code = build_image_helper(project, os.join(os.dirname(output), "alweb-vignette"))
    return code

# Programme natif des vignettes (alweb.images), à côté de l'exécutable : l'application le trouve là sans avoir à
# le compiler sur le serveur. Seulement si le projet se sert d'alweb.images.
func build_image_helper(project, target):
    uses := false
    for f in _project_al_files(project):
        if _s.contains(_io.read_file(os.join(project, f)), "alweb.images"):
            uses = true
    if not uses:
        return 0
    src := null
    for c in [os.join(project, "alex_packages", "alweb", "outils", "vignette.al"), os.join(home() if home() != null else "", "alweb", "outils", "vignette.al")]:
        if os.isfile(c):
            src = c
    if src == null:
        _console.error("alweb: source du programme des vignettes introuvable (alweb/outils/vignette.al)\n")
        return 1
    code := run_alex(["build", "--native", src, "-o", target], null, project)
    if code == 0:
        print("alweb: " + target + " construit (vignettes d'alweb.images ; à déployer à côté de l'exécutable)")
    return code

func _cmd_deploy(a):
    project := _project_or_fail()
    w := deploy(project, a["cibles"], {"domaine": _val(a, "domaine"), "dossier": _val(a, "dossier"), "port": _val(a, "port"),
                                        "utilisateur": _val(a, "utilisateur"), "alex": _val(a, "alex"), "force": _val(a, "force") == true})
    for f in w:
        print("  écrit " + f)
    print("Voir docs/DEPLOIEMENT.md d'alweb ; les secrets vont dans .env (jamais versionné).")
    return 0
