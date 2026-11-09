# alweb.themes.panel — page « Apparence » de l'administration (alweb.admin, option « appearance ») : réglages du
# thème actif produits depuis son schéma (config/theme.json du thème), aperçu en direct du site dans un cadre,
# enregistrement dans config/theme.<slug>.json, historique (20 versions) et restauration, retour aux valeurs du
# thème, export des choix, logo et images envoyés dans alweb.storage, choix du thème parmi ceux installés.
#
# Pages ({prefix}/_apparence) :
#   GET   /_apparence                 formulaire et aperçu
#   POST  /_apparence                 enregistre (seules les valeurs qui diffèrent du thème sont écrites)
#   POST  /_apparence/apercu          réglages en cours -> brouillon de la session (JSON : ok, errors, modified)
#   POST  /_apparence/abandonner      oublie le brouillon
#   POST  /_apparence/reinitialiser   revient aux valeurs du thème (la version courante part dans l'historique)
#   POST  /_apparence/restaurer       revient à une version de l'historique (champ « version »)
#   GET   /_apparence/export.json     choix du projet (fichier à versionner ou à copier sur un autre site)
#   POST  /_apparence/activer         thème actif dans alweb.lock (champ « slug ») : pris en compte au redémarrage
#
# Le brouillon ne s'applique qu'aux pages chargées dans le cadre d'aperçu de la personne qui règle (voir
# alweb.themes, « brouillon ») : les visiteurs voient les valeurs enregistrées jusqu'à « Enregistrer ».

from core use len, type, to_int, to_float
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use time as _time
use asyncio as _aio
use web.http.response as _response
use alweb.errors as _err
use alweb.auth as _auth
use alweb.forms as _forms
use alweb.storage as _storage
use alweb.i18n as _i18n
use alweb.themes as _themes
use alweb.themes.customization as _custom
use alweb.themes.registry as _registry
use alweb.themes.manifest as _manifest
use network.async_client as _ac

const PATH := "/_apparence"
const CSS_TYPES := ["color", "size", "font", "number"]
const IMAGE_TYPES := ["image/png", "image/jpeg", "image/gif", "image/webp"]
const MAX_IMAGE := 5000000
const EXTRA_LINKS := 3
const MAX_LINKS := 20
# Largeur logique (px) de chaque vue : le site du cadre est rendu à cette largeur, puis réduit à l'échelle s'il le
# faut, pour que ses media queries voient un vrai écran d'ordinateur, de tablette ou de téléphone.
const VIEWS := [["ordinateur", "Ordinateur", 1280], ["tablette", "Tablette", 768], ["mobile", "Mobile", 390]]

func routes(admin, g, h):
    g.get(PATH, (req) => page(admin, req), h)
    g.get(PATH + ".js", (req) => _script(), h)
    g.get(PATH + "/export.json", (req) => export(admin, req), h)
    g.post(PATH, (req) => save(admin, req), h)
    g.post(PATH + "/apercu", (req) => preview(admin, req), h)
    g.post(PATH + "/abandonner", (req) => discard(admin, req), h)
    g.post(PATH + "/reinitialiser", (req) => reset(admin, req), h)
    g.post(PATH + "/restaurer", (req) => restore(admin, req), h)
    g.post(PATH + "/activer", (req) => activate(admin, req), h)
    g.post(PATH + "/mises-a-jour", (req) => check_updates(admin, req), h)

# ---------------------------------------------------------------- accès

func allowed(admin, req):
    o := admin.appearance_opt
    if o == false:
        return false
    if type(o) == "list":
        mine := _auth.roles(req)
        for r in o:
            if r in mine:
                return true
        return false
    return true

# Page visible : option active, et un thème actif ou installé.
func visible(admin, req):
    if not allowed(admin, req):
        return false
    if admin.app.theme != null:
        return true
    return len(_installed(admin)) > 0

func _guard(admin, req):
    if admin.appearance_opt == false:
        _err.abort(404, _tr(req).t("pas de page « Apparence »"))
    if not allowed(admin, req):
        _err.abort(403, _tr(req).t("droits insuffisants pour l'apparence"))
    return admin.app.theme

func _need_theme(admin, req):
    th := _guard(admin, req)
    if th == null:
        _err.abort(404, _tr(req).t("aucun thème actif"))
    if th.choices_file == null:
        _err.abort(409, _tr(req).t("ce thème n'est pas installé dans le projet : réglages impossibles à enregistrer"))
    return th

func _tr(req):
    return _i18n.translator_for(req)

func _root(admin):
    th := admin.app.theme
    if th != null and th.root != null:
        return th.root
    return _themes._root({})

func _history_dir(admin, th):
    return _os.join(_root(admin), ".alweb", "themes", th.slug, "historique")

func _installed(admin):
    try:
        return _registry.Registry(_root(admin)).list()
    catch e:
        return []

func _url(admin, rest=""):
    return admin.prefix + PATH + rest

async func _notify(admin, req, action, slug, values):
    if admin.on_change == null:
        return
    r := admin.on_change(req, {"action": action, "table": "theme", "id": slug, "values": values, "user_id": _auth.user_id(req)})
    if _aio.is_future(r):
        await r

func _flash(req, message, category):
    if "session" in req.state:
        req.state["session"].flash(message, category)

func _back(admin):
    return _response.redirect(_url(admin), 303)

# ---------------------------------------------------------------- formulaire depuis le schéma

func _humanize(k):
    t := _s.replace(k, "_", " ")
    return _s.upper(t[0:1]) + t[1:len(t)] if len(t) > 0 else t

func _json_of(v):
    return _json.stringify(v)

func _num_text(v):
    if type(v) == "float" and v == to_float(to_int(v)):
        return str(to_int(v))
    return str(v)

func _picker(v):
    if type(v) != "str":
        return null
    if len(v) == 7:
        return _s.lower(v)
    if len(v) == 4:
        return _s.lower("#" + v[1:2] + v[1:2] + v[2:3] + v[2:3] + v[3:4] + v[3:4])
    return null

func _default_text(node, tr):
    d := node["default"]
    t := node["type"]
    if t == "bool":
        return tr.t("oui") if d == true else tr.t("non")
    if t == "links":
        return tr.n("{n} lien(s)", len(d))
    if t == "number":
        return _num_text(d)
    if d == "":
        return "—"
    return str(d)

func _field(admin, th, node, path, value, error, raw, tr):
    t := node["type"]
    key := _s.split(path, ".")
    last := key[len(key) - 1]
    f := {"name": "v." + path, "id": "c_" + _s.replace(path, ".", "_"), "path": path, "type": t,
          "label": tr.t(node["label"]) if "label" in node and type(node["label"]) == "str" else _humanize(last),
          "help": tr.t(node["help"]) if "help" in node and type(node["help"]) == "str" else null,
          "error": error, "default_text": _default_text(node, tr), "modified": _json_of(value) != _json_of(node["default"]),
          "css_var": "--" + _s.replace(_s.replace(path, ".", "-"), "_", "-") if t in CSS_TYPES else null, "value": ""}
    shown := raw if raw != null else value
    if t == "bool":
        f["checked"] = shown == true or shown == "1"
    elif t == "number":
        f["value"] = shown if type(shown) == "str" else _num_text(shown)
        f["min"] = node["min"] if "min" in node else null
        f["max"] = node["max"] if "max" in node else null
    elif t == "choice":
        f["options"] = [{"value": str(o), "label": tr.t(str(o)), "selected": str(o) == str(shown)} for o in node["options"]]
    elif t == "links":
        rows := []
        lst := shown if type(shown) == "list" else []
        i := 0
        for l in lst:
            append(rows, {"i": i, "label": l["label"] if type(l) == "dict" and "label" in l else "", "url": l["url"] if type(l) == "dict" and "url" in l else ""})
            i += 1
        n := 0
        while n < EXTRA_LINKS and i < MAX_LINKS:
            append(rows, {"i": i, "label": "", "url": ""})
            i += 1
            n += 1
        f["rows"] = rows
    else:
        f["value"] = str(shown) if shown != null else ""
        if t == "color":
            f["picker"] = _picker(shown)
        if t == "text":
            f["multiline"] = (type(node["default"]) == "str" and len(node["default"]) > 80) or ("multiline" in node and node["multiline"] == true)
        if t == "image":
            f["upload"] = admin.app.storage != null
            f["preview"] = null
            if type(value) == "str" and value != "":
                try:
                    f["preview"] = th.asset(admin.app, value, false)
                catch e:
                    f["preview"] = null
    return f

# Sections du formulaire : les feuilles du premier niveau dans « Général », puis un groupe par section.
func sections(admin, th, values, errors, raw, tr):
    out := []
    general := {"title": tr.t("Général"), "fields": []}
    for k in keys(th.schema):
        node := th.schema[k]
        if _custom.is_leaf(node):
            append(general["fields"], _field(admin, th, node, k, values[k], _get(errors, k), _get(raw, k), tr))
        else:
            sec := {"title": tr.t(_humanize(k)), "fields": []}
            _collect(admin, th, node, values[k], k + ".", sec["fields"], errors, raw, tr)
            append(out, sec)
    if len(general["fields"]) > 0:
        return [general] + out
    return out

func _collect(admin, th, schema, values, prefix, fields, errors, raw, tr):
    for k in keys(schema):
        node := schema[k]
        p := prefix + k
        if _custom.is_leaf(node):
            append(fields, _field(admin, th, node, p, values[k], _get(errors, p), _get(raw, p), tr))
        else:
            _collect(admin, th, node, values[k], p + ".", fields, errors, raw, tr)

func _get(d, k):
    return d[k] if d != null and k in d else null

# ---------------------------------------------------------------- lecture du formulaire

func _trim(v):
    return _s.trim(v) if type(v) == "str" else v

# [présent, valeur] d'une feuille dans le formulaire.
func _read_leaf(node, form, p):
    t := node["type"]
    n := "v." + p
    if t == "bool":
        if not form.has("b." + p):
            return [false, null]
        return [true, form.has(n) and form.get(n) != "" and form.get(n) != "0"]
    if t == "links":
        if not form.has(n + ".0.label"):
            return [false, null]
        out := []
        i := 0
        while i < MAX_LINKS + EXTRA_LINKS:
            l := _trim(form.get(n + "." + str(i) + ".label", ""))
            u := _trim(form.get(n + "." + str(i) + ".url", ""))
            if l != "" or u != "":
                append(out, {"label": l, "url": u})
            i += 1
        return [true, out]
    if not form.has(n):
        return [false, null]
    v := _trim(form.get(n, ""))
    if t == "number":
        if v == "":
            return [true, node["default"]]
        try:
            if _s.contains(v, ".") or _s.contains(v, "e") or _s.contains(v, "E"):
                return [true, to_float(v)]
            return [true, to_int(v)]
        catch e:
            return [true, v]
    if t == "choice":
        for o in node["options"]:
            if str(o) == v:
                return [true, o]
        return [true, v]
    if v == "" and t != "text":
        return [true, node["default"]]
    return [true, v]

# Choix lus dans le formulaire : [choix (seulement ce qui diffère du thème), erreurs {chemin: message},
# valeurs saisies {chemin: valeur} (pour réafficher le formulaire)].
func read_choices(th, form):
    errors := {}
    raw := {}
    c := _read(th.schema, form, "", errors, raw, th.choices)
    return [c, errors, raw]

func _read(schema, form, prefix, errors, raw, current):
    out := {}
    for k in keys(schema):
        node := schema[k]
        p := prefix + k
        cur := current[k] if type(current) == "dict" and k in current else null
        if _custom.is_leaf(node):
            r := _read_leaf(node, form, p)
            v := r[1] if r[0] else (cur if cur != null else node["default"])     # absent du formulaire : gardé
            raw[p] = v
            m := _custom.check_value(node, v)
            if m != null:
                errors[p] = m
            elif _json_of(v) != _json_of(node["default"]):
                out[k] = v
        elif type(node) == "dict":
            sub := _read(node, form, p + ".", errors, raw, cur)
            if len(sub) > 0:
                out[k] = sub
    return out

func _set_path(d, path, v):
    parts := _s.split(path, ".")
    cur := d
    i := 0
    while i < len(parts) - 1:
        if not (parts[i] in cur) or type(cur[parts[i]]) != "dict":
            cur[parts[i]] = {}
        cur = cur[parts[i]]
        i += 1
    cur[parts[len(parts) - 1]] = v

func _image_paths(schema, prefix="", out=null):
    lst := out if out != null else []
    for k in keys(schema):
        node := schema[k]
        if _custom.is_leaf(node):
            if node["type"] == "image":
                append(lst, prefix + k)
        elif type(node) == "dict":
            _image_paths(node, prefix + k + ".", lst)
    return lst

# Chemins des feuilles d'un dict de choix (« couleurs.primaire »).
func leaf_paths(schema, choices, prefix="", out=null):
    lst := out if out != null else []
    if type(choices) != "dict":
        return lst
    for k in keys(choices):
        if k in schema:
            if _custom.is_leaf(schema[k]):
                append(lst, prefix + k)
            else:
                leaf_paths(schema[k], choices[k], prefix + k + ".", lst)
    return lst

# ---------------------------------------------------------------- pages

func _pages(admin):
    out := ["/"]
    try:
        for r in admin.app.routes():
            p := r[1]
            if "GET" in r[0] and not _s.contains(p, "{") and not _s.starts_with(p, admin.prefix) and not _s.starts_with(p, "/_") and not (p in out) and not _s.contains(p, ".") and len(out) < 40:
                append(out, p)
    catch e:
        ignored := e
    return out

func _context(admin, req, th, values, errors, raw, error=null):
    tr := _tr(req)
    installed := _installed(admin)
    themes := []
    for i in installed:
        append(themes, {"slug": i["slug"], "name": i["name"], "version": i["version"], "active": i["active"],
                        "current": th != null and th.slug == i["slug"], "present": i["present"]})
    c := {"page_title": tr.t("Apparence"), "wide": true, "themes": themes, "activate": _url(admin, "/activer"), "js": _url(admin, ".js"),
          "theme_info": null}
    if th == null:
        return c
    hist := []
    for h in _themes.history(_history_dir(admin, th)):
        append(hist, {"name": h["name"], "label": _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(h["time"]))})
    d := _themes.draft(req, th)
    m := th.manifest
    c["theme_info"] = {"name": m["name"], "version": m["version"], "author": m["author"], "slug": th.slug}
    c["sections"] = sections(admin, th, values, errors, raw, tr)
    c["modified"] = len(leaf_paths(th.schema, th.choices))
    c["error"] = error
    c["action"] = _url(admin)
    c["preview_action"] = _url(admin, "/apercu")
    c["discard"] = _url(admin, "/abandonner")
    c["reset"] = _url(admin, "/reinitialiser") if len(th.choices) > 0 else null
    c["restore"] = _url(admin, "/restaurer")
    c["export"] = _url(admin, "/export.json")
    src := _source(admin, th)
    c["market"] = src[len("marketplace:"):len(src)] if src != null and _s.starts_with(src, "marketplace:") else null
    c["check_updates"] = _url(admin, "/mises-a-jour")
    c["history"] = hist
    c["has_draft"] = d != null and not ("base" in d and d["base"] == true)
    c["views"] = [{"id": v[0], "label": tr.t(v[1]), "width": v[2], "current": v[0] == "ordinateur"} for v in VIEWS]
    c["pages"] = _pages(admin)
    c["frame_src"] = "/?" + _themes.PREVIEW_PARAM + "=1"
    c["multipart"] = admin.app.storage != null
    c["choices_file"] = _os.join("config", "theme." + th.slug + ".json")
    c["texts"] = {"pending": tr.t("Aperçu…"), "ok": tr.t("Aperçu à jour (non enregistré)"), "errors": tr.t("Valeurs à corriger"), "fail": tr.t("Aperçu indisponible")}
    return c

func page(admin, req):
    th := _guard(admin, req)
    if th == null and len(_installed(admin)) == 0:
        _err.abort(404, _tr(req).t("aucun thème installé"))
    if th == null:
        return admin._render(req, "appearance.html", _context(admin, req, null, null, null, null))
    th.refresh()
    d := _themes.draft(req, th)
    values := th.settings
    raw := null
    if d != null:
        try:
            values = _themes.draft_values(th, d)                # reprend les réglages non enregistrés
        catch e:
            d = null
    if d == null:
        _themes.set_draft(req, th, th.choices, true)           # le cadre d'aperçu peut afficher le site
    return admin._render(req, "appearance.html", _context(admin, req, th, values, {}, raw))

async func save(admin, req):
    th := _need_theme(admin, req)
    tr := _tr(req)
    form := _forms.form(req)
    r := read_choices(th, form)
    choices := r[0]
    errors := r[1]
    if admin.app.storage != null:
        for p in _image_paths(th.schema):
            f := form.file("f." + p)
            if f != null:
                try:
                    k := await _storage.save_upload(admin.app.storage, f, {"prefix": "theme/" + th.slug + "/", "max_bytes": MAX_IMAGE, "allowed": IMAGE_TYPES})
                    _set_path(choices, p, "media:" + k)
                    r[2][p] = "media:" + k
                catch e:
                    errors[p] = _forms_text(tr, e)
    if len(errors) > 0:
        return admin._render(req, "appearance.html", _context(admin, req, th, _safe_values(th, choices), errors, r[2], tr.n("{n} valeur(s) à corriger.", len(errors))), 422)
    try:
        th.save_choices(choices, _history_dir(admin, th))
    catch e:
        return admin._render(req, "appearance.html", _context(admin, req, th, _safe_values(th, choices), {}, r[2], tr.t("Enregistrement impossible : {erreur}", {"erreur": str(e.message)})), 500)
    _themes.clear_draft(req)
    await _notify(admin, req, "theme_update", th.slug, choices)
    _flash(req, tr.t("Apparence enregistrée : les visiteurs voient maintenant ces réglages."), "succes")
    return _back(admin)

func _forms_text(tr, e):
    m := str(e.message)
    if _s.contains(m, "trop volumineux"):
        return tr.t("Image trop volumineuse (5 Mo au plus).")
    if _s.contains(m, "type") or _s.contains(m, "format"):
        return tr.t("Image PNG, JPEG, GIF ou WebP attendue.")
    return m

func _safe_values(th, choices):
    try:
        return th.values_for(choices)
    catch e:
        return th.settings

async func preview(admin, req):
    th := _need_theme(admin, req)
    form := _forms.form(req)
    r := read_choices(th, form)
    if len(r[1]) > 0:
        return _response.json({"ok": false, "errors": r[1], "modified": leaf_paths(th.schema, r[0])})
    h := _themes.set_draft(req, th, r[0])
    return _response.json({"ok": true, "errors": {}, "hash": h, "modified": leaf_paths(th.schema, r[0])})

func discard(admin, req):
    _guard(admin, req)
    _themes.clear_draft(req)
    _flash(req, _tr(req).t("Changements non enregistrés abandonnés."), "info")
    return _back(admin)

async func reset(admin, req):
    th := _need_theme(admin, req)
    th.save_choices({}, _history_dir(admin, th))
    _themes.clear_draft(req)
    await _notify(admin, req, "theme_reset", th.slug, {})
    _flash(req, _tr(req).t("Valeurs du thème rétablies (la version précédente est dans l'historique)."), "succes")
    return _back(admin)

async func restore(admin, req):
    th := _need_theme(admin, req)
    tr := _tr(req)
    name := _forms.form(req).get("version", "")
    found := null
    for h in _themes.history(_history_dir(admin, th)):
        if h["name"] == name:
            found = h
    if found == null:
        _flash(req, tr.t("Version introuvable dans l'historique."), "erreur")
        return _back(admin)
    try:
        c := _json.parse(_io.read_file(found["path"]))
        th.save_choices(c, _history_dir(admin, th))
    catch e:
        _flash(req, tr.t("Restauration impossible : {erreur}", {"erreur": str(e.message)}), "erreur")
        return _back(admin)
    _themes.clear_draft(req)
    await _notify(admin, req, "theme_restore", th.slug, th.choices)
    _flash(req, tr.t("Version du {date} restaurée.", {"date": _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(found["time"]))}), "succes")
    return _back(admin)

func _source(admin, th):
    try:
        e := _registry.Registry(_root(admin)).lock()["themes"]
        return e[th.slug]["source"] if th.slug in e and "source" in e[th.slug] else null
    catch e:
        return null

# Fiche du thème sur sa marketplace (client asynchrone : le serveur continue de servir pendant l'attente).
async func _remote(url, slug, transport=null):
    target := url + "/api/v1/themes/" + slug
    if transport != null:
        return await transport(target)
    r := await _ac.request("GET", target, null, null, {"Accept": "application/json"}, 15.0)
    if r.status != 200:
        raise("ThemeError", "statut " + str(r.status))
    return _json.parse(r.text())

# Tests : admin.market_transport (async fn(url) -> fiche) remplace l'appel réseau.
async func check_updates(admin, req):
    th := _need_theme(admin, req)
    tr := _tr(req)
    src := _source(admin, th)
    if src == null or not _s.starts_with(src, "marketplace:"):
        _flash(req, tr.t("Ce thème n'a pas été installé depuis une marketplace."), "info")
        return _back(admin)
    url := src[len("marketplace:"):len(src)]
    try:
        d := await _remote(url, th.slug, admin.market_transport)
        best := null
        for v in d["versions"]:
            if v["yanked"]:
                continue
            if not _manifest.satisfies(_registry.ALWEB_VERSION, v["framework_version"]):
                continue
            if best == null or _manifest.compare(v["version"], best) > 0:
                best = v["version"]
        cur := th.manifest["version"]
        if best != null and _manifest.compare(best, cur) > 0:
            _flash(req, tr.t("Version {v} disponible (installée : {cur}). Pour l'installer : alweb theme update {slug}, puis redémarrez l'application ; vos réglages sont gardés.", {"v": best, "cur": cur, "slug": th.slug}), "succes")
        else:
            _flash(req, tr.t("« {nom} » {cur} est à jour.", {"nom": th.manifest["name"], "cur": cur}), "info")
    catch e:
        _flash(req, tr.t("Marketplace injoignable ({url}) : {erreur}", {"url": url, "erreur": str(e.message)}), "erreur")
    return _back(admin)

func export(admin, req):
    th := _need_theme(admin, req)
    r := _response.text(_json.pretty(th.choices) + "\n")
    r.headers.set("Content-Type", "application/json; charset=utf-8")
    r.headers.set("Content-Disposition", "attachment; filename=\"theme." + th.slug + ".json\"")
    return r

async func activate(admin, req):
    _guard(admin, req)
    tr := _tr(req)
    slug := _forms.form(req).get("slug", "")
    try:
        _registry.Registry(_root(admin)).activate(slug)
    catch e:
        _flash(req, tr.t("Activation impossible : {erreur}", {"erreur": str(e.message)}), "erreur")
        return _back(admin)
    await _notify(admin, req, "theme_activate", slug, null)
    th := admin.app.theme
    if th != null and th.slug == slug:
        _flash(req, tr.t("« {slug} » est le thème actif.", {"slug": slug}), "succes")
    else:
        _flash(req, tr.t("« {slug} » sera utilisé au prochain démarrage de l'application.", {"slug": slug}), "succes")
    return _back(admin)

func _script():
    r := _response.text(SCRIPT)
    r.headers.set("Content-Type", "text/javascript; charset=utf-8")
    return r

# ---------------------------------------------------------------- gabarit et script

const TEMPLATE := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › {{ _("Apparence") }}</p>
<h1>{{ _("Apparence") }}</h1>
{% if theme_info == null %}<p>{{ _("Aucun thème actif : l'application utilise ses propres gabarits.") }}</p>
{% else %}<p class="fil">{{ _("Thème « {nom} » {version}", {"nom": theme_info.name, "version": theme_info.version}) }}{% if theme_info.author %} · {{ theme_info.author }}{% endif %} · {{ _n("{n} réglage(s) modifié(s)", modified) }} · <code>{{ choices_file }}</code></p>
<div class="apparence">
<form id="apparence" class="reglages" method="post" action="{{ action }}"{% if multipart %} enctype="multipart/form-data"{% endif %} data-apercu="{{ preview_action }}" data-t-pending="{{ texts.pending }}" data-t-ok="{{ texts.ok }}" data-t-errors="{{ texts.errors }}" data-t-fail="{{ texts.fail }}">{{ csrf_field() }}
{% if error %}<p class="erreur-generale">{{ error }}</p>{% endif %}
{% for s in sections %}<fieldset><legend>{{ s.title }}</legend>
{% for f in s.fields %}<div class="champ{% if f.error %} erreur{% endif %}{% if f.modified %} modifie{% endif %}" data-path="{{ f.path }}">
{% if f.type == "bool" %}<input type="hidden" name="b.{{ f.path }}" value="1"><label><input type="checkbox" id="{{ f.id }}" name="{{ f.name }}" value="1"{% if f.checked %} checked{% endif %}> <span class="lib lib-inline">{{ f.label }}</span></label>
{% else %}<label class="lib" for="{{ f.id }}">{{ f.label }}</label>
{% if f.type == "color" %}<div class="couleur"><input type="color" id="{{ f.id }}_p" value="{{ f.picker if f.picker else '#000000' }}" data-pour="{{ f.id }}" aria-label="{{ f.label }}"{% if not f.picker %} disabled{% endif %}><input id="{{ f.id }}" name="{{ f.name }}" value="{{ f.value }}" data-css="{{ f.css_var }}" size="10" spellcheck="false"></div>
{% elif f.type == "choice" %}<select id="{{ f.id }}" name="{{ f.name }}">{% for o in f.options %}<option value="{{ o.value }}"{% if o.selected %} selected{% endif %}>{{ o.label }}</option>{% endfor %}</select>
{% elif f.type == "number" %}<input id="{{ f.id }}" name="{{ f.name }}" type="number" step="any" value="{{ f.value }}"{% if f.min != null %} min="{{ f.min }}"{% endif %}{% if f.max != null %} max="{{ f.max }}"{% endif %} data-css="{{ f.css_var }}">
{% elif f.type == "links" %}<div class="liens" id="{{ f.id }}">{% for l in f.rows %}<div class="ligne"><input name="{{ f.name }}.{{ l.i }}.label" value="{{ l.label }}" placeholder="{{ _('Libellé') }}" aria-label="{{ _('Libellé') }} {{ l.i + 1 }}"><input name="{{ f.name }}.{{ l.i }}.url" value="{{ l.url }}" placeholder="/page ou https://…" aria-label="{{ _('Adresse') }} {{ l.i + 1 }}" spellcheck="false"></div>{% endfor %}</div>
{% elif f.type == "image" %}<input id="{{ f.id }}" name="{{ f.name }}" value="{{ f.value }}" spellcheck="false">{% if f.upload %}<input type="file" name="f.{{ f.path }}" accept="image/png,image/jpeg,image/gif,image/webp" aria-label="{{ _('Envoyer une image') }}">{% endif %}{% if f.preview %}<img class="vignette" src="{{ f.preview }}" alt="">{% endif %}
{% elif f.type == "text" and f.multiline %}<textarea id="{{ f.id }}" name="{{ f.name }}" maxlength="500">{{ f.value }}</textarea>
{% else %}<input id="{{ f.id }}" name="{{ f.name }}" value="{{ f.value }}"{% if f.css_var %} data-css="{{ f.css_var }}"{% endif %}{% if f.type == "text" %} maxlength="500"{% else %} spellcheck="false"{% endif %}>{% endif %}
{% endif %}{% if f.help %}<div class="aide">{{ f.help }}</div>{% endif %}<div class="aide defaut">{{ _("Valeur du thème : {valeur}", {"valeur": f.default_text}) }}</div><div class="err" data-err="{{ f.path }}">{{ f.error if f.error else "" }}</div>
</div>{% endfor %}</fieldset>{% endfor %}
<div class="actions collantes"><button class="principal" type="submit">{{ _("Enregistrer") }}</button><button type="submit" id="abandonner" formaction="{{ discard }}" formnovalidate{% if not has_draft %} hidden{% endif %}>{{ _("Abandonner les changements") }}</button><span class="etat" id="etat-apercu" role="status">{% if has_draft %}{{ texts.ok }}{% endif %}</span></div>
</form>
<section class="apercu" aria-label="{{ _('Aperçu du site') }}">
<div class="barre"><div class="vues" role="group" aria-label="{{ _('Taille de l’aperçu') }}">{% for v in views %}<button type="button" data-vue="{{ v.id }}" data-largeur="{{ v.width }}"{% if v.current %} class="principal" aria-pressed="true"{% else %} aria-pressed="false"{% endif %}>{{ v.label }}</button>{% endfor %}</div><span class="pousse"></span>
<label class="f" for="page-apercu">{{ _("Page") }}</label><input id="page-apercu" list="pages-apercu" value="/" size="18" spellcheck="false"><datalist id="pages-apercu">{% for p in pages %}<option value="{{ p }}">{% endfor %}</datalist></div>
<div class="cadre ordinateur" id="cadre" data-largeur="{% for v in views %}{% if v.current %}{{ v.width }}{% endif %}{% endfor %}"><iframe id="apercu" src="{{ frame_src }}" title="{{ _('Aperçu du site') }}"></iframe></div>
<p class="fil">{{ _("L'aperçu montre vos réglages avant leur enregistrement ; les visiteurs voient les valeurs enregistrées.") }}</p>
</section></div>
<div class="cartes outils">
<div class="carte"><div class="titre">{{ _("Historique") }}</div>{% if history %}<form method="post" action="{{ restore }}">{{ csrf_field() }}<select name="version" aria-label="{{ _('Version') }}">{% for h in history %}<option value="{{ h.name }}">{{ h.label }}</option>{% endfor %}</select> <button type="submit">{{ _("Restaurer") }}</button></form>{% else %}<p class="note">{{ _("Aucune version précédente.") }}</p>{% endif %}</div>
<div class="carte"><div class="titre">{{ _("Valeurs du thème") }}</div>{% if reset %}<form method="post" action="{{ reset }}">{{ csrf_field() }}<button class="danger" type="submit">{{ _("Tout rétablir") }}</button></form>{% else %}<p class="note">{{ _("Aucun réglage modifié.") }}</p>{% endif %}</div>
<div class="carte"><div class="titre">{{ _("Export") }}</div><a class="bouton" href="{{ export }}">{{ _("Télécharger les réglages") }}</a></div>
{% if market %}<div class="carte"><div class="titre">{{ _("Mises à jour") }}</div><form method="post" action="{{ check_updates }}">{{ csrf_field() }}<button type="submit">{{ _("Vérifier") }}</button></form><p class="note">{{ market }}</p></div>{% endif %}
</div>{% endif %}
{% if themes %}<h2>{{ _("Thèmes installés") }}</h2><div class="tableau"><table><thead><tr><th>{{ _("Thème") }}</th><th>{{ _("Version") }}</th><th>{{ _("État") }}</th><th></th></tr></thead><tbody>
{% for t in themes %}<tr><td>{{ t.name }}<div class="aide">{{ t.slug }}</div></td><td>{{ t.version }}</td><td>{% if t.current %}{{ _("utilisé") }}{% elif t.active %}{{ _("actif au prochain démarrage") }}{% elif not t.present %}{{ _("dossier absent") }}{% else %}—{% endif %}</td>
<td>{% if not t.active and t.present %}<form method="post" action="{{ activate }}">{{ csrf_field() }}<input type="hidden" name="slug" value="{{ t.slug }}"><button type="submit">{{ _("Activer") }}</button></form>{% endif %}</td></tr>{% endfor %}</tbody></table></div>{% endif %}
<script src="{{ js }}"></script>
{% endblock %}"""

# Script de la page (fichier servi par l'administration : permis par une CSP « script-src 'self' »). Les variables
# CSS changent tout de suite dans le cadre (même origine) ; le reste recharge la page d'aperçu une fois le
# brouillon enregistré dans la session.
const SCRIPT := """(function () {
  var form = document.getElementById('apparence');
  if (!form) return;
  var frame = document.getElementById('apercu'), cadre = document.getElementById('cadre');
  var etat = document.getElementById('etat-apercu');
  var tokenField = form.querySelector('input[name=csrf_token]');
  var token = tokenField ? tokenField.value : '';
  var timer = null, reload = false, seq = 0;
  function say(k) { etat.textContent = form.getAttribute('data-t-' + k) || ''; }
  function root() { try { return frame.contentDocument && frame.contentDocument.documentElement; } catch (e) { return null; } }
  function css(el) {
    var v = el.getAttribute('data-css'), r = root();
    if (v && r && el.value !== '') r.style.setProperty(v, el.value);
  }
  function sync(el) {
    if (el.type === 'color') {
      var t = document.getElementById(el.getAttribute('data-pour'));
      t.value = el.value;
      return t;
    }
    var p = el.id ? document.getElementById(el.id + '_p') : null;
    if (p) {
      var v = el.value;
      if (/^#[0-9a-fA-F]{6}$/.test(v)) { p.value = v.toLowerCase(); p.disabled = false; }
      else if (/^#[0-9a-fA-F]{3}$/.test(v)) { p.value = ('#' + v[1] + v[1] + v[2] + v[2] + v[3] + v[3]).toLowerCase(); p.disabled = false; }
    }
    return el;
  }
  function show(errors) {
    var list = form.querySelectorAll('[data-err]');
    for (var i = 0; i < list.length; i++) {
      var path = list[i].getAttribute('data-err'), m = errors[path] || '';
      list[i].textContent = m;
      list[i].parentNode.classList.toggle('erreur', m !== '');
    }
  }
  function mark(paths) {
    var list = form.querySelectorAll('.champ[data-path]');
    for (var i = 0; i < list.length; i++) list[i].classList.toggle('modifie', paths.indexOf(list[i].getAttribute('data-path')) >= 0);
  }
  function send() {
    var all = new FormData(form), data = new FormData(), n = ++seq;
    all.forEach(function (v, k) { if (typeof v === 'string') data.append(k, v); });
    fetch(form.getAttribute('data-apercu'), {method: 'POST', body: data, credentials: 'same-origin',
      headers: {'X-CSRF-Token': token, 'Accept': 'application/json'}})
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (n !== seq) return;
        show(d.errors || {});
        mark(d.modified || []);
        if (!d.ok) { say('errors'); return; }
        say('ok');
        var ab = document.getElementById('abandonner');
        if (ab) ab.hidden = false;
        if (reload) { reload = false; try { frame.contentWindow.location.reload(); } catch (e) { frame.src = frame.src; } }
      })
      .catch(function () { say('fail'); });
  }
  function schedule() { clearTimeout(timer); say('pending'); timer = setTimeout(send, 350); }
  form.addEventListener('input', function (ev) {
    var el = ev.target;
    if (el.type === 'file' || el.type === 'checkbox' || el.tagName === 'SELECT') return;
    el = sync(el);
    if (el.getAttribute('data-css')) css(el); else reload = true;
    schedule();
  });
  form.addEventListener('change', function (ev) {
    var el = ev.target;
    if (el.type === 'checkbox' || el.tagName === 'SELECT') { reload = true; schedule(); }
  });
  var vues = document.querySelectorAll('[data-vue]');
  for (var i = 0; i < vues.length; i++) vues[i].addEventListener('click', function () {
    for (var j = 0; j < vues.length; j++) { vues[j].classList.remove('principal'); vues[j].setAttribute('aria-pressed', 'false'); }
    this.classList.add('principal');
    this.setAttribute('aria-pressed', 'true');
    cadre.className = 'cadre ' + this.getAttribute('data-vue');
    cadre.setAttribute('data-largeur', this.getAttribute('data-largeur'));
    ajuste();
  });
  // Le site est rendu à la largeur de l'appareil choisi, puis réduit pour tenir dans le cadre.
  function ajuste() {
    var w = parseInt(cadre.getAttribute('data-largeur'), 10) || 1280;
    var dispo = cadre.clientWidth, haut = cadre.clientHeight;
    if (!dispo || !haut) return;
    var e = Math.min(1, dispo / w);
    frame.style.width = w + 'px';
    frame.style.height = Math.round(haut / e) + 'px';
    frame.style.transform = e < 1 ? 'scale(' + e + ')' : '';
  }
  if (window.ResizeObserver) new ResizeObserver(ajuste).observe(cadre);
  else window.addEventListener('resize', ajuste);
  ajuste();
  var page = document.getElementById('page-apercu');
  function go() {
    var p = page.value.trim();
    if (p.charAt(0) !== '/' || p.charAt(1) === '/') return;
    frame.src = p + (p.indexOf('?') < 0 ? '?' : '&') + '_apercu_theme=1';
  }
  page.addEventListener('change', go);
  page.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); go(); } });
})();
"""
