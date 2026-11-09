# alweb.themes — thèmes d'interface installables (ALWEB Templates) : un thème est un dossier indépendant
# (gabarits, composants, ressources, paramètres) décrit par alweb-theme.json, validé, empaqueté en .alwt,
# installé dans themes/<slug>/ d'un projet et activé ; l'application garde ses routes et ses données.
#
#   use alweb.themes as themes
#   themes.setup(app)                       # thème actif (config « theme.active », sinon alweb.lock) ; pose app.theme
#   alweb.render(req, "index.html", {...})  # pages du thème ; templates/ de l'application passe avant (remplacement)
#
# Dans les gabarits : {% include "components/navbar.html" %}, {{ asset("css/theme.css") }} (URL versionnée),
# {{ theme.couleurs.primaire }} (paramètres fusionnés), {{ theme_css }} (feuille des variables CSS), theme_info.
# Dans le code : themes.setting(app, "couleurs.primaire"). Choix du projet : config/theme.<slug>.json.
#
# Modules : alweb.themes.manifest (alweb-theme.json, versions), .validator (contrôles de sécurité), .package
# (archives .alwt), .registry (installation, alweb.lock, activation), .customization (paramètres typés) ;
# raccourcis ici : themes.validate(dossier), themes.build(dossier, sortie), themes.project(racine) (Registry).
# Commandes : alweb theme create | validate | package | install | activate | deactivate | list | info | remove |
# rollback | check | preview (docs/THEMES.md).

from core use len, type, to_int
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use time as _time
use network.security as _sec
use network.encoding as _enc
use web.http.response as _response
use alweb.errors as _err
use alweb.app as _app
use alweb.templates as _tpl
use alweb.i18n as _i18n
use alweb.themes.manifest as manifest
use alweb.themes.validator as validator
use alweb.themes.package as package
use alweb.themes.registry as registry
use alweb.themes.customization as customization

const STATIC_PREFIX := "/theme"
const CSS_ROUTE := "/_theme.css"

func _fail(message):
    raise("ThemeError", message)

# Thème branché sur une application.
class Theme:
    func init(directory, m, schema, values, choices=null, choices_file=null):
        self.directory = directory
        self.manifest = m
        self.slug = m["slug"]
        self.schema = schema
        self.choices = choices if choices != null else {}     # choix du projet (seulement ce qui change)
        self.choices_file = choices_file                       # config/theme.<slug>.json (null : pas de fichier)
        self.choices_mtime = _mtime_of(choices_file)
        self.checked_at = _time.time()
        self.env = null
        self.root = null                  # racine du projet (themes.setup)
        self.hashes = {}                  # chemin -> [mtime, taille, empreinte]
        self._apply(values)

    func _apply(values):
        self.settings = values
        self.css = customization.css(self.schema, values)
        self.css_hash = package.sha256_hex(self.css)[0:10]
        if self.env != null:
            self.env.globals["theme"] = values
            self.env.globals["theme_css"] = CSS_ROUTE + "?v=" + self.css_hash

    # Valeurs fusionnées pour des choix (ThemeError si l'un est invalide).
    func values_for(choices):
        return customization.merge(self.schema, choices)

    # Relit le fichier des choix s'il a changé (au plus une fois par seconde) : une modification faite par un
    # autre processus ou à la main est prise en compte sans redémarrer. Un fichier devenu invalide est signalé
    # et les valeurs précédentes sont gardées.
    func refresh(force=false):
        now := _time.time()
        if not force and now - self.checked_at < 1:
            return false
        self.checked_at = now
        mt := _mtime_of(self.choices_file)
        if mt == self.choices_mtime:
            return false
        self.choices_mtime = mt
        try:
            c := {} if mt == null else _json.parse(_io.read_file(self.choices_file))
            self._apply(self.values_for(c))
            self.choices = c
            return true
        catch e:
            print("alweb theme : " + str(self.choices_file) + " ignoré (valeurs précédentes gardées) : " + str(e.message))
            return false

    # Enregistre de nouveaux choix (vérifiés) dans config/theme.<slug>.json, de façon atomique ; la version
    # précédente part dans l'historique (history_dir, 20 versions). Rend les valeurs fusionnées.
    func save_choices(choices, history_dir=null):
        if self.choices_file == null:
            _fail("thème « " + self.slug + " » : pas de fichier de choix (thème hors projet)")
        values := self.values_for(choices)
        if history_dir != null and _os.isfile(self.choices_file):
            _os.mkdir_all(history_dir)
            stamp := _time.strftime("%Y%m%d-%H%M%S", _time.localtime(_time.time()))
            dest := _os.join(history_dir, stamp + ".json")
            n := 1
            while _os.exists(dest):
                n += 1
                dest = _os.join(history_dir, stamp + "-" + str(n) + ".json")
            _io.write_file(dest, _io.read_file(self.choices_file))
            _prune(history_dir, 20)
        _os.mkdir_all(_os.dirname(self.choices_file))
        tmp := self.choices_file + ".tmp"
        _io.write_file(tmp, _json.pretty(choices) + "\n")
        _os.move(tmp, self.choices_file)
        self.choices = choices
        self.choices_mtime = _mtime_of(self.choices_file)
        self._apply(values)
        return values

    func static_dir():
        return _os.join(self.directory, self.manifest["assets"])

    # URL d'une ressource : chemin dans static/ (versionné par son empreinte), « media:clé » (stockage de
    # l'application, lien signé stable), « https://… » (tel quel).
    func asset(app, path, strict=true):
        if type(path) != "str" or path == "":
            _fail("asset : chemin attendu")
        if _s.starts_with(path, "media:"):
            if app.storage == null:
                _fail("asset(\"" + path + "\") : pas de stockage (alweb.storage.setup)")
            return app.storage.url(path[6:len(path)], 86400)
        if _s.starts_with(path, "https://") or _s.starts_with(path, "http://"):
            return path
        p := path[1:len(path)] if _s.starts_with(path, "/") else path
        if not manifest.safe_path(p):
            _fail("asset : chemin refusé : " + path)
        f := _os.join(self.static_dir(), p)
        if not _os.isfile(f):
            if strict:
                _fail("asset : " + p + " absent de " + self.manifest["assets"] + "/ du thème « " + self.slug + " »")
            return STATIC_PREFIX + "/" + _uri(p)
        mt := _os.mtime(f)
        sz := _os.size(f)
        h := self.hashes[p] if p in self.hashes else null
        if h == null or h[0] != mt or h[1] != sz:
            h = [mt, sz, package.file_sha256(f)[0:10]]
            self.hashes[p] = h
        return STATIC_PREFIX + "/" + _uri(p) + "?v=" + h[2]

func _mtime_of(path):
    if path == null or not _os.isfile(path):
        return null
    return [_os.mtime(path), _os.size(path)]

# Garde les keep fichiers les plus récents du dossier (noms horodatés : l'ordre alphabétique est chronologique).
func _prune(directory, keep):
    names := validator._sort([n for n in _os.list_dir(directory) if _s.ends_with(n, ".json")])
    i := 0
    while i < len(names) - keep:
        _os.remove(_os.join(directory, names[i]))
        i += 1

# Versions gardées des choix (les plus récentes d'abord) : [{name, path, time}].
func history(directory):
    if directory == null or not _os.isdir(directory):
        return []
    names := validator._sort([n for n in _os.list_dir(directory) if _s.ends_with(n, ".json")])
    out := []
    i := len(names) - 1
    while i >= 0:
        append(out, {"name": names[i], "path": _os.join(directory, names[i]), "time": _os.mtime(_os.join(directory, names[i]))})
        i -= 1
    return out

func _uri(p):
    out := ""
    h := "0123456789ABCDEF"
    i := 0
    n := _s.byte_len(p)
    while i < n:
        b := _s.byte_at(p, i)
        i += 1
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 95 or b == 46 or b == 126 or b == 47:
            out = out + _s.byte_char(b)
        else:
            out = out + "%" + h[b // 16:b // 16 + 1] + h[b % 16:b % 16 + 1]
    return out

func _root(options):
    if "root" in options:
        return options["root"]
    r := _os.getenv("ALWEB_ROOT")
    return r if r != null and r != "" else "."

# Charge le thème d'un dossier : manifeste, schéma des paramètres, choix du projet (fichier choices, s'il existe).
func load(directory, choices_file=null):
    m := manifest.load(directory)
    sp := _os.join(directory, m["settings"])
    schema := {}
    if _os.isfile(sp):
        schema = _json.parse(_io.read_file(sp))
        errs := customization.check_schema(schema)
        if len(errs) > 0:
            _fail(m["settings"] + " : " + _s.join(" ; ", errs))
    choices := null
    if choices_file != null and _os.isfile(choices_file):
        try:
            choices = _json.parse(_io.read_file(choices_file))
        catch e:
            _fail(choices_file + " : JSON invalide : " + str(e.message))
    return Theme(directory, m, schema, customization.merge(schema, choices), choices, choices_file)

# Branche le thème actif sur l'application ; rend le Theme (ou null sans thème actif : gabarits de l'application
# seuls). slug : thème à utiliser (sinon config « theme.active », sinon alweb.lock). options : root (racine du
# projet ; défaut ALWEB_ROOT ou « . »), directory (dossier d'un thème non installé : aperçu, développement),
# templates (gabarits de l'application, défaut « templates »), static_prefix.
func setup(app, slug=null, options=null):
    o := options if options != null else {}
    root := _root(o)
    app_tpl := _os.join(root, o["templates"] if "templates" in o else "templates")
    directory := o["directory"] if "directory" in o else null
    if directory == null:
        reg := registry.Registry(root)
        s := slug
        if s == null and app.config != null:
            s = app.config.get("theme.active", null)
        if s == null:
            s = reg.active()
        if s == null:
            if _os.isdir(app_tpl):
                app.use_templates(app_tpl)
            app.theme = null
            return null
        if not reg.installed(s):
            _fail("thème « " + s + " » non installé (alweb theme install …)")
        directory = reg.path(s)
    th := load(directory, _os.join(root, "config", "theme." + manifest.load(directory)["slug"] + ".json"))
    errs := registry.compatibility(th.manifest)
    if len(errs) > 0:
        _fail("thème « " + th.slug + " » incompatible : " + _s.join(" ; ", errs))
    m := th.manifest
    env := app.use_templates(_os.join(directory, m["templates"]))
    if _os.isdir(app_tpl) and _os.absolute(app_tpl) != _os.absolute(_os.join(directory, m["templates"])):
        env.add_directory(app_tpl, "", true)                   # l'application remplace une page du thème
    comp := _os.join(directory, m["components"])
    if _os.isdir(comp):
        env.add_directory(comp, m["components"] + "/")
    if _os.isdir(th.static_dir()):
        app.static(o["static_prefix"] if "static_prefix" in o else STATIC_PREFIX, th.static_dir(), null, false, 0 if app.debug else 31536000)
    app.get(CSS_ROUTE, (req) => _css_for(req, th), {"hidden": true, "name": "alweb_theme_css"})
    env.globals["asset"] = (p) => th.asset(app, p, app.debug)
    th.env = env
    th.root = root
    th._apply(th.settings)
    app.context_processor((req) => _context(req, th))
    env.globals["theme_info"] = {"name": m["name"], "slug": m["slug"], "version": m["version"], "author": m["author"]}
    if not ("_" in env.globals):
        # sans alweb.i18n : textes du thème tels quels (avec {variables}) ; avec, le processeur de contexte les traduit
        env.globals["_"] = (key, vars=null) => _i18n.default_translator().markup(key, vars)
        env.globals["_n"] = (key, n, vars=null) => _i18n.default_translator().markup_n(key, n, vars)
    app.theme = th
    return th

func _css_response(th):
    r := _response.text(th.css)
    r.headers.set("Content-Type", "text/css; charset=utf-8")
    r.headers.set("Cache-Control", "public, max-age=31536000, immutable")
    return r

# ---------------------------------------------------------------- brouillon (aperçu de l'administration)
#
# Le panneau « Apparence » de l'administration garde les réglages en cours dans la session de la personne qui
# les fait (clé DRAFT_KEY). Ils ne s'appliquent qu'à ses requêtes d'aperçu : pages chargées dans un cadre
# (en-tête Sec-Fetch-Dest: iframe, ou paramètre ?_apercu_theme=1) et feuille /_theme.css?apercu=… ; les autres
# visiteurs, et la même personne hors du cadre, voient les valeurs enregistrées. Ces pages d'aperçu peuvent
# être affichées dans un cadre de même origine (alweb.middleware.security_headers : SAMEORIGIN,
# frame-ancestors 'self').

const DRAFT_KEY := "_alweb_theme_draft"
const PREVIEW_PARAM := "_apercu_theme"

func _session(req):
    return req.state["session"] if "session" in req.state else null

# Brouillon de la requête pour ce thème ({slug, choices, hash}), ou null.
func draft(req, th):
    s := _session(req)
    if s == null:
        return null
    d := s.get(DRAFT_KEY, null)
    if d == null or type(d) != "dict" or not ("slug" in d) or d["slug"] != th.slug:
        return null
    return d

# Garde des choix vérifiés comme brouillon de la session ; rend son empreinte. base : brouillon « vide » posé à
# l'ouverture du panneau (aperçu permis dans le cadre, valeurs enregistrées affichées, même si elles changent).
func set_draft(req, th, choices, base=false):
    s := _session(req)
    if s == null:
        _fail("aperçu du thème : alweb.sessions.middleware est nécessaire")
    values := th.values_for(choices)
    h := package.sha256_hex(customization.css(th.schema, values) + _json.stringify(choices))[0:12]
    s.set(DRAFT_KEY, {"slug": th.slug, "choices": choices, "hash": h, "base": base})
    return h

# Valeurs d'un brouillon (celles du thème enregistré pour un brouillon de base).
func draft_values(th, d):
    if "base" in d and d["base"] == true:
        return th.settings
    return th.values_for(d["choices"])

func clear_draft(req):
    s := _session(req)
    if s != null and s.has(DRAFT_KEY):
        s.pop(DRAFT_KEY)

func previewing(req, th):
    if draft(req, th) == null:
        return false
    return _s.lower(req.header("sec-fetch-dest", "")) == "iframe" or req.query_param(PREVIEW_PARAM, null) != null

func _context(req, th):
    th.refresh()
    if previewing(req, th):
        d := draft(req, th)
        try:
            vals := draft_values(th, d)
            req.state["alweb_frame"] = "self"
            tag := th.css_hash if "base" in d and d["base"] == true else d["hash"]
            return {"theme": vals, "theme_css": CSS_ROUTE + "?apercu=" + tag, "theme_preview": true}
        catch e:
            ignored := e
    return {"theme": th.settings, "theme_css": CSS_ROUTE + "?v=" + th.css_hash, "theme_preview": false}

func _css_for(req, th):
    th.refresh()
    if req.query_param("apercu", null) != null:
        d := draft(req, th)
        if d != null:
            try:
                r := _response.text(customization.css(th.schema, draft_values(th, d)))
                r.headers.set("Content-Type", "text/css; charset=utf-8")
                r.headers.set("Cache-Control", "no-store")
                return r
            catch e:
                ignored := e
    return _css_response(th)

# Paramètre du thème actif (« couleurs.primaire ») ; null sans thème ou si absent.
func setting(app, path):
    if app.theme == null:
        return null
    return customization.get(app.theme.settings, path)

# Raccourcis vers les sous-modules (un alias importé n'est pas exporté : use alweb.themes.registry pour le reste).
func validate(directory):
    return validator.validate(directory)

func build(directory, out_dir=null):
    return package.build(directory, out_dir)

func project(root="."):
    return registry.Registry(root)

# ---------------------------------------------------------------- aperçu

const PREVIEW := """<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aperçu — {{ info.name }}</title><link rel="stylesheet" href="/_apercu.css"></head>
<body><header><strong>{{ info.name }}</strong> <span>{{ info.version }} · {{ info.slug }}</span>
<nav>{% for p in pages %}<a href="/_apercu?page={{ p | urlencode }}"{% if p == page %} class="actif"{% endif %}>{{ p }}</a>{% endfor %}</nav></header>
<main>{% for v in vues %}<figure><figcaption>{{ v[0] }} · {{ v[1] }} px</figcaption>
<div class="cadre" style="width: {{ v[1] * v[3] }}px; height: {{ v[2] * v[3] }}px"><iframe src="{{ url }}" width="{{ v[1] }}" height="{{ v[2] }}" style="transform: scale({{ v[3] }})" title="{{ v[0] }}"></iframe></div></figure>{% endfor %}</main></body></html>"""

const PREVIEW_CSS := """body{margin:0;font:14px/1.4 system-ui,sans-serif;background:#eceef2;color:#1d2330}
header{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;padding:10px 16px;background:#fff;border-bottom:1px solid #d8dce3}
header span{color:#5b6475}nav{display:flex;flex-wrap:wrap;gap:6px}nav a{padding:3px 8px;border-radius:5px;color:#2f5bd3;text-decoration:none}
nav a.actif{background:#2f5bd3;color:#fff}main{display:flex;gap:18px;align-items:flex-start;padding:16px;overflow-x:auto}
figure{margin:0;flex:none}figcaption{color:#5b6475;margin-bottom:6px}.cadre{overflow:hidden;border:1px solid #c9ced8;border-radius:8px;background:#fff}
iframe{border:0;transform-origin:0 0;display:block}"""

# [nom, largeur, hauteur, échelle d'affichage] : les trois vues tiennent côte à côte sur un écran ordinaire
const VIEWS := [["Ordinateur", 1280, 800, 0.5], ["Tablette", 768, 1024, 0.5], ["Mobile", 390, 844, 0.7]]

# Pages d'un thème (gabarits de templates/ sauf base, layouts et erreurs) : ["index", "about", "blog/index", …].
func pages(th):
    tdir := _os.join(th.directory, th.manifest["templates"])
    out := []
    for f in validator.list_files(tdir)[0]:
        if not _s.ends_with(f, ".html"):
            continue
        n := f[0:len(f) - 5]
        b := _os.basename(n)
        if b == "base" or _s.starts_with(b, "_") or _s.starts_with(n, "layouts/") or _s.starts_with(n, "errors/") or _s.starts_with(n, "partials/"):
            continue
        append(out, n)
    return out

# Application d'aperçu d'un dossier de thème : chaque page servie avec les données de preview/data.json (dict
# « commun » pour toutes les pages, puis une clé par page), et /_apercu : ordinateur, tablette et mobile côte à côte.
func preview_app(directory):
    app := _app.App("Aperçu du thème")
    app.debug = true
    th := setup(app, null, {"directory": directory, "root": directory, "templates": "__aucun__"})
    data := {}
    dp := _os.join(directory, "preview", "data.json")
    if _os.isfile(dp):
        data = _json.parse(_io.read_file(dp))
    env := _tpl.Environment()
    env.add("apercu.html", PREVIEW)
    liste := pages(th)

    func page_ctx(name):
        ctx := {}
        if "commun" in data:
            for k in keys(data["commun"]):
                ctx[k] = data["commun"][k]
        if name in data:
            for k in keys(data[name]):
                ctx[k] = data[name][k]
        return ctx

    func rendre(req, name):
        return app.render(req, name + ".html", page_ctx(name))

    app.get("/_apercu.css", (req) => _css_text(PREVIEW_CSS), {"hidden": true})
    app.get("/_apercu", (req) => _apercu(env, th, liste, req), {"hidden": true})
    app.get("/", (req) => rendre(req, _entry_page(th)))

    @app.get("/{page:path}")
    func page(req):
        p := req.params["page"]
        if _s.ends_with(p, "/"):
            p = p[0:len(p) - 1]
        for cand in [p, p + "/index"]:
            if cand in liste:
                return rendre(req, cand)
        _err.abort(404, "page absente du thème : " + p)
    return app

func _entry_page(th):
    e := th.manifest["entry"][len(th.manifest["templates"]) + 1:len(th.manifest["entry"])]
    return e[0:len(e) - 5] if _s.ends_with(e, ".html") else e

func _apercu(env, th, liste, req):
    page := req.query_param("page", _entry_page(th))
    if not (page in liste):
        page = _entry_page(th)
    url := "/" if page == _entry_page(th) else "/" + page
    return _response.html(env.render("apercu.html", {"info": th.manifest, "pages": liste, "page": page, "url": url, "vues": VIEWS}))

func _css_text(css):
    r := _response.text(css)
    r.headers.set("Content-Type", "text/css; charset=utf-8")
    return r
