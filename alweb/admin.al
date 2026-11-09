# alweb.admin — interface d'administration produite depuis les tables de l'ORM : tableau de bord, listes
# paginées avec recherche, tri et filtres, création, modification, suppression avec confirmation, export CSV.
#
#   use alweb.admin as adm
#
#   admin := adm.Admin(app, {"prefix": "/admin", "roles": ["admin"], "login_url": "/connexion"})
#   admin.register(ARTICLES, {"list": ["id", "titre", "auteur_id", "cree_le"], "search": ["titre", "texte"],
#                             "filters": ["auteur_id"], "display": "titre"})
#   admin.register(UTILISATEURS, {"exclude": ["mdp"], "display": "nom", "can_create": false})
#
# Prérequis : alweb.sessions.middleware (les gardes de alweb.auth lisent la session) et un fournisseur de base
# de données (app.provide("db", ...), nom changé par l'option « db »). Le groupe d'administration ajoute lui-même
# la garde de connexion et de rôles, la vérification CSRF de chaque POST (même si l'application ne l'a pas
# activée) et les en-têtes Cache-Control: no-store et X-Frame-Options: DENY.
#
# Options de Admin(app, options) : prefix ("/admin"), title ("Administration"), db (nom de la dépendance, "db" ;
# ou la base elle-même), roles (["admin"] : l'un d'eux est exigé ; null : toute personne connectée), login_url
# ("/connexion"), on_change (fn(req, évènement), async permise : journal d'audit ; évènement = {action: "create" |
# "update" | "delete", table, id, values, user_id} ; pour les tâches : "job_retry" / "job_delete", table "jobs"),
# jobs (true : page « Tâches » si l'application a une file alweb.jobs ; false : pas de page ; liste de rôles :
# rôles exigés pour cette page en plus de ceux de l'administration).
#
# extensions (liste d'objets qui ajoutent des pages : voir « pour les extensions » ; exemple dans docs/ADMIN.md),
# appearance (true : page « Apparence » si un thème alweb.themes est actif ou installé ; false : pas de page ; liste
# de rôles : rôles exigés en plus) : réglages du thème avec aperçu en direct (alweb.themes.panel, docs/THEMES.md).
#
# Page des tâches ({prefix}/_taches) : compteurs par état, liste filtrée (en attente, en cours, abandonnées,
# faites) avec dernière erreur, fiche d'une tâche (charge JSON, dates, erreur complète), « Réessayer » (une
# tâche abandonnée ou toutes) et « Supprimer » (pas une tâche en cours).
#
# Options de register(table, options) :
#   list        colonnes de la liste (défaut : la clé et jusqu'à cinq colonnes courtes)
#   search      colonnes de la recherche (défaut : colonnes texte) ; [] : pas de recherche
#   filters     colonnes filtrables : booléen (oui / non), clé étrangère (liste des lignes liées), choices, sinon
#               égalité sur la valeur saisie
#   order       tri par défaut ("-id")          per_page   lignes par page (25)
#   display     colonne qui nomme une ligne (titre de page, clés étrangères qui pointent vers elle)
#   exclude     colonnes jamais montrées (mots de passe, jetons)
#   readonly    colonnes montrées mais non modifiables (la clé et les horodatages automatiques le sont toujours)
#   labels      {colonne: libellé}               help      {colonne: aide sous le champ}
#   choices     {colonne: [[valeur, libellé], ...]} : liste fermée (vérifiée à l'enregistrement)
#   can_create, can_edit, can_delete, can_export (vrai par défaut)
#   roles       rôles exigés pour cette table en plus de ceux de l'administration
#   name        segment d'URL (défaut : nom de la table)      label    titre (défaut : nom de la table)
#
# Champs selon le type de colonne : texte (zone de texte au-delà de 200 caractères ou sans maximum), entier, réel,
# case à cocher, date et heure (heure locale du serveur), JSON (vérifié), clé étrangère (liste déroulante si la
# table liée est enregistrée et compte au plus 500 lignes, sinon son identifiant). Les erreurs de validation de
# l'ORM (obligatoire, longueur, type) et d'unicité sont affichées au bon champ.
#
# Langue : celle de la requête si l'application a une alweb.i18n (textes de l'administration fournis en français
# et en anglais par alweb.messages ; une autre langue s'ajoute dans locales/<langue>.json, clés = texte
# français), sinon le français.

from core use len, type, to_int, to_float
from collections use append, keys
use string as _s
use json as _json
use time as _time
use asyncio as _aio
use alweb.templates as _tpl
use alweb.auth as _auth
use alweb.csrf as _csrf
use alweb.forms as _forms
use alweb.errors as _err
use alweb.chain as _chain
use alweb.i18n as _i18n
use alweb.themes.panel as _panel
use web.http.response as _response
use web.url.form_url_encoding as _form_enc

const ADMIN_OPTIONS := ["prefix", "title", "db", "roles", "login_url", "on_change", "jobs", "appearance", "extensions"]
const TABLE_OPTIONS := ["list", "search", "filters", "order", "per_page", "display", "exclude", "readonly", "labels",
    "help", "choices", "can_create", "can_edit", "can_delete", "can_export", "roles", "name", "label"]
const MAX_CHOICES := 500
const DATETIME_FORMATS := ["%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"]

# ================================================================ tables enregistrées

class ModelAdmin:
    func init(admin, table, opts):
        for k in keys(opts):
            if not (k in TABLE_OPTIONS):
                _err.alweb_error("Admin.register", "option inconnue « " + str(k) + " » (permises : " + _s.join(", ", TABLE_OPTIONS) + ")")
        self.admin = admin
        self.table = table
        self.name = _opt(opts, "name", table.name)
        self.label = _opt(opts, "label", table.name)
        self.exclude = _opt(opts, "exclude", [])
        self.readonly_cols = _opt(opts, "readonly", [])
        self.labels = _opt(opts, "labels", {})
        self.help = _opt(opts, "help", {})
        self.choices = _opt(opts, "choices", {})
        self.per_page = _opt(opts, "per_page", 25)
        self.can_create = _opt(opts, "can_create", true)
        self.can_edit = _opt(opts, "can_edit", true)
        self.can_delete = _opt(opts, "can_delete", true)
        self.can_export = _opt(opts, "can_export", true)
        self.roles = _opt(opts, "roles", null)
        for c in self.exclude + self.readonly_cols + keys(self.labels) + keys(self.help) + keys(self.choices):
            self._check(c)
        if table.pk in self.exclude:
            _err.alweb_error("Admin.register", "table " + table.name + " : la clé primaire ne peut pas être exclue")
        self.fields = [n for n in table.order if not (n in self.exclude)]
        self.list_cols = _opt(opts, "list", null)
        if self.list_cols == null:
            self.list_cols = [table.pk] + [n for n in self.fields if n != table.pk and _short(table.columns[n])][0:5]
        self.search_cols = _opt(opts, "search", null)
        if self.search_cols == null:
            self.search_cols = [n for n in self.fields if table.columns[n].kind == "text"]
        self.filters = _opt(opts, "filters", [])
        for c in self.list_cols + self.search_cols + self.filters:
            self._check(c)
            if c in self.exclude:
                _err.alweb_error("Admin.register", "table " + table.name + " : colonne exclue « " + c + " » dans list, search ou filters")
        self.display = _opt(opts, "display", null)
        if self.display == null:
            for n in self.fields:
                if self.display == null and n != table.pk and table.columns[n].kind == "text":
                    self.display = n
        if self.display != null:
            self._check(self.display)
        self.order = _opt(opts, "order", "-" + table.pk)
        self._check(self.order[1:len(self.order)] if _s.starts_with(self.order, "-") else self.order)

    func _check(col):
        if not (col in self.table.columns):
            _err.alweb_error("Admin.register", "table " + self.table.name + " : colonne inconnue « " + str(col) + " »")

    func column(n):
        return self.table.columns[n]

    func label_of(n):
        if n in self.labels:
            return self.labels[n]
        t := _s.replace(n, "_", " ")
        return _s.upper(t[0:1]) + t[1:len(t)]

    func is_readonly(n):
        c := self.column(n)
        return c.primary or c.auto or (n in self.readonly_cols)

    func editable():
        return [n for n in self.fields if not self.is_readonly(n)]

    # Nom lisible d'une ligne (colonne display, sinon « table n° id »).
    func title_of(row, tr=null):
        if row == null:
            return ""
        if self.display != null and row[self.display] != null and str(row[self.display]) != "":
            return str(row[self.display])
        return _t(tr).t("{table} n° {id}", {"table": self.label, "id": row[self.table.pk]})

    func allowed(req):
        if self.roles == null:
            return true
        mine := _auth.roles(req)
        for r in self.roles:
            if r in mine:
                return true
        return false

func _short(c):
    if c.kind == "json":
        return false
    if c.kind == "text":
        return c.max != null and c.max <= 200
    return true

func _opt(d, k, default):
    return d[k] if d != null and k in d and d[k] != null else default

# ================================================================ administration

class Admin:
    func init(app, opts=null):
        o := opts if opts != null else {}
        for k in keys(o):
            if not (k in ADMIN_OPTIONS):
                _err.alweb_error("Admin", "option inconnue « " + str(k) + " » (permises : " + _s.join(", ", ADMIN_OPTIONS) + ")")
        self.app = app
        p := _opt(o, "prefix", "/admin")
        self.prefix = p[0:len(p) - 1] if _s.ends_with(p, "/") else p
        self.title = _opt(o, "title", null)            # null : « Administration », traduit
        self.db = _opt(o, "db", "db")
        self.on_change = _opt(o, "on_change", null)
        self.models = {}                 # segment d'URL -> ModelAdmin
        self.order = []                  # segments dans l'ordre d'enregistrement
        roles := o["roles"] if "roles" in o else ["admin"]
        login := _opt(o, "login_url", "/connexion")
        garde := _auth.login_required(login) if roles == null else _auth.roles_required(roles, login)
        self.env = _templates(self)
        self.jobs_opt = o["jobs"] if "jobs" in o else true
        self.appearance_opt = o["appearance"] if "appearance" in o else true
        self.market_transport = null      # tests de la page « Apparence » (mises à jour)
        g := app.group(self.prefix, [_chain.Hook(null, _no_store), garde, _csrf.middleware()])
        h := {"hidden": true}
        g.get("/_admin.css", (req) => _css(), h)           # feuille de style servie ici : permise par une CSP 'self'
        g.get("", (req) => self._index(req), {"hidden": true, "name": "admin"})
        self.group = g
        self.extensions = o["extensions"] if "extensions" in o and o["extensions"] != null else []
        for x in self.extensions:
            x.install(self, g, h)                         # avant /{table} : le premier motif qui correspond gagne
        if self.appearance_opt != false:
            _panel.routes(self, g, h)
        if self.jobs_opt != false:
            g.get("/_taches", (req) => self._jobs(req), h)
            g.post("/_taches/reessayer", (req) => self._jobs_retry_all(req), h)
            g.get("/_taches/{id}", (req) => self._job(req), h)
            g.post("/_taches/{id}/reessayer", (req) => self._job_retry(req), h)
            g.post("/_taches/{id}/supprimer", (req) => self._job_delete(req), h)
        g.get("/{table}", (req) => self._list(req), h)
        g.get("/{table}/export.csv", (req) => self._export(req), h)
        g.get("/{table}/nouveau", (req) => self._new(req), h)
        g.post("/{table}/nouveau", (req) => self._create(req), h)
        g.get("/{table}/{id:int}", (req) => self._edit(req), h)
        g.post("/{table}/{id:int}", (req) => self._update(req), h)
        g.get("/{table}/{id:int}/supprimer", (req) => self._confirm(req), h)
        g.post("/{table}/{id:int}/supprimer", (req) => self._delete(req), h)

    # Enregistre une table de l'ORM ; rend son ModelAdmin.
    func register(table, opts=null):
        m := ModelAdmin(self, table, opts if opts != null else {})
        if m.name in self.models:
            _err.alweb_error("Admin.register", "table déjà enregistrée : " + m.name)
        self.models[m.name] = m
        append(self.order, m.name)
        return m

    # ModelAdmin d'une table de l'ORM (par son nom SQL), ou null.
    func model_for_table(table_name):
        for n in self.order:
            if self.models[n].table.name == table_name:
                return self.models[n]
        return null

    func url(m=null, rest=""):
        if m == null:
            return self.prefix
        return self.prefix + "/" + m.name + rest

    # ------------------------------------------------------------ outils

    async func _db(req):
        if type(self.db) != "str":
            return self.db
        d := self.app.deps.resolve(self.app, req, self.db)
        if _aio.is_future(d):
            d = await d
        return d

    func _model(req):
        n := req.params["table"]
        if not (n in self.models):
            _err.abort(404, _tr(req).t("table inconnue : {nom}", {"nom": n}))
        m := self.models[n]
        if not m.allowed(req):
            _err.abort(403, _tr(req).t("droits insuffisants pour {table}", {"table": m.label}))
        return m

    func _title(tr):
        return self.title if self.title != null else tr.t("Administration")

    func _render(req, name, ctx, status=200):
        tr := _tr(req)
        nav := [{"label": self.models[n].label, "href": self.url(self.models[n]), "current": "table" in req.params and req.params["table"] == n}
                for n in self.order if self.models[n].allowed(req)]
        if self._jobs_allowed(req):
            append(nav, {"label": tr.t("Tâches"), "href": self.prefix + "/_taches", "current": _s.starts_with(req.path(), self.prefix + "/_taches")})
        for x in self.extensions:
            for n in x.nav(self, req):
                append(nav, n)
        if _panel.visible(self, req):
            append(nav, {"label": tr.t("Apparence"), "href": self.prefix + _panel.PATH, "current": _s.starts_with(req.path(), self.prefix + _panel.PATH)})
        c := {"admin_title": self._title(tr), "home": self.url(), "css": self.prefix + "/_admin.css", "user_id": _auth.user_id(req),
              "nav": nav, "csrf_field": () => _csrf.field(req), "flashes": _flashes(req)}
        lang := tr.owner.context(tr)
        for k in keys(lang):
            c[k] = lang[k]
        for k in keys(ctx):
            c[k] = ctx[k]
        return _response.html(self.env.render(name, c), status)

    # ------------------------------------------------------------ pour les extensions
    # Une extension (option « extensions ») est un objet avec install(admin, groupe, options_de_route) (routes et
    # gabarits : admin.env.add), nav(admin, req) -> [{label, href, current}] et cards(admin, req) -> [carte]
    # (async permise). Elle rend ses pages avec admin.render (mise en page, menu, langue, jeton CSRF).

    func render(req, name, ctx, status=200):
        return self._render(req, name, ctx, status)

    func flash(req, message, category="info"):
        _flash(req, message, category)

    async func notify(req, event):
        if self.on_change == null:
            return
        e := {}
        for k in keys(event):
            e[k] = event[k]
        e["user_id"] = _auth.user_id(req)
        r := self.on_change(req, e)
        if _aio.is_future(r):
            await r

    async func db_for(req):
        return await self._db(req)

    async func _notify(req, action, m, id, values):
        if self.on_change == null:
            return
        r := self.on_change(req, {"action": action, "table": m.table.name, "id": id, "values": values, "user_id": _auth.user_id(req)})
        if _aio.is_future(r):
            await r

    # ------------------------------------------------------------ pages

    async func _index(req):
        tr := _tr(req)
        db := await self._db(req) if len(self.order) > 0 else null
        cartes := []
        for n in self.order:
            m := self.models[n]
            if m.allowed(req):
                append(cartes, {"label": m.label, "href": self.url(m), "count": await m.table.query().count(db),
                                "new": self.url(m, "/nouveau") if m.can_create else null})
        if self._jobs_allowed(req):
            st := await self.app.jobs.stats()
            append(cartes, {"label": tr.t("Tâches"), "href": self.prefix + "/_taches" + ("?etat=failed" if st["failed"] > 0 else ""),
                            "count": st["pending"] + st["running"], "new": null,
                            "note": tr.n("{n} abandonnée(s)", st["failed"]) if st["failed"] > 0 else tr.t("en attente ou en cours")})
        for x in self.extensions:
            cs := x.cards(self, req)
            if _aio.is_future(cs):
                cs = await cs
            for c in cs:
                append(cartes, c)
        if _panel.visible(self, req):
            th := self.app.theme
            append(cartes, {"label": tr.t("Apparence"), "href": self.prefix + _panel.PATH, "count": th.manifest["name"] if th != null else "—", "new": null,
                            "note": tr.n("{n} réglage(s) modifié(s)", len(_panel.leaf_paths(th.schema, th.choices))) if th != null else tr.t("aucun thème actif")})
        return self._render(req, "index.html", {"cards": cartes, "page_title": self._title(tr)})

    # ------------------------------------------------------------ tâches de fond (alweb.jobs)

    func _jobs_allowed(req):
        if self.jobs_opt == false or self.app.jobs == null:
            return false
        if type(self.jobs_opt) == "list":
            mine := _auth.roles(req)
            for r in self.jobs_opt:
                if r in mine:
                    return true
            return false
        return true

    func _jobs_guard(req):
        if self.jobs_opt == false or self.app.jobs == null:
            _err.abort(404, _tr(req).t("pas de file de tâches"))
        if not self._jobs_allowed(req):
            _err.abort(403, _tr(req).t("droits insuffisants pour les tâches"))
        return self.app.jobs

    func _job_url(id):
        return self.prefix + "/_taches/" + _quote(id)

    async func _jobs(req):
        tr := _tr(req)
        q := self._jobs_guard(req)
        etat := req.query_param("etat", "")
        if not (etat in ["", "pending", "running", "failed", "done"]):
            etat = ""
        st := await q.stats()
        rows := []
        statuts := [etat] if etat != "" else ["running", "pending", "failed"]
        for s in statuts:
            for r in await q.list(s, 200):
                append(rows, {"id": r["id"], "href": self._job_url(r["id"]), "name": r["name"], "status": _job_status(r["status"], tr), "kind": r["status"],
                              "attempts": str(r["attempts"]) + "/" + str(r["max_attempts"]), "when": _job_when(r, tr), "error": _short_text(r["last_error"], 120)})
        onglets := []
        for o in [["", "Actives", st["pending"] + st["running"] + st["failed"]], ["pending", "En attente", st["pending"]], ["running", "En cours", st["running"]], ["failed", "Abandonnées", st["failed"]], ["done", "Faites", st["done"]]]:
            append(onglets, {"label": tr.t(o[1]), "count": o[2], "href": self.prefix + "/_taches" + ("?etat=" + o[0] if o[0] != "" else ""), "current": o[0] == etat})
        return self._render(req, "jobs.html", {"page_title": tr.t("Tâches"), "tabs": onglets, "rows": rows, "stats": st, "retry_all": self.prefix + "/_taches/reessayer" if st["failed"] > 0 else null, "keep_done": _duration(q.keep_done, tr), "keep_failed": _duration(q.keep_failed, tr)})

    async func _job(req):
        tr := _tr(req)
        q := self._jobs_guard(req)
        r := await q.get(req.params["id"])
        if r == null:
            _err.abort(404, tr.t("tâche inconnue"))
        payload := r["payload"]
        try:
            payload = _json.pretty(_json.parse(r["payload"]))
        catch e:
            ignored := e
        fiche := [[tr.t("Identifiant"), r["id"]], [tr.t("Tâche"), r["name"]], [tr.t("État"), _job_status(r["status"], tr)], [tr.t("Essais"), tr.t("{a} sur {b}", {"a": r["attempts"], "b": r["max_attempts"]})],
                  [tr.t("Créée"), _job_time(r["created_at"])], [tr.t("Prévue"), _job_time(r["run_at"])], [tr.t("Réservée par"), r["locked_by"] if r["locked_by"] != null else "—"],
                  [tr.t("Terminée"), _job_time(r["finished_at"])]]
        base := self._job_url(r["id"])
        return self._render(req, "job.html", {"page_title": tr.t("Tâche {nom}", {"nom": r["name"]}), "back": self.prefix + "/_taches", "facts": fiche, "payload": payload, "error": r["last_error"],
                                               "retry": base + "/reessayer" if r["status"] == "failed" else null, "delete": base + "/supprimer" if r["status"] != "running" else null})

    async func _job_retry(req):
        q := self._jobs_guard(req)
        id := req.params["id"]
        n := await q.retry_failed(id)
        if n > 0:
            await self._notify_job(req, "job_retry", id)
            _flash(req, _tr(req).t("Tâche remise en file : nouvel essai dès que possible."), "succes")
        else:
            _flash(req, _tr(req).t("Cette tâche n'est pas abandonnée : rien à réessayer."), "erreur")
        return _response.redirect(self._job_url(id), 303)

    async func _jobs_retry_all(req):
        q := self._jobs_guard(req)
        n := await q.retry_failed(null)
        if n > 0:
            await self._notify_job(req, "job_retry", null)
        _flash(req, _tr(req).n("{n} tâche(s) remise(s) en file.", n), "succes" if n > 0 else "info")
        return _response.redirect(self.prefix + "/_taches", 303)

    async func _job_delete(req):
        q := self._jobs_guard(req)
        id := req.params["id"]
        if await q.delete(id):
            await self._notify_job(req, "job_delete", id)
            _flash(req, _tr(req).t("Tâche supprimée."), "succes")
            return _response.redirect(self.prefix + "/_taches", 303)
        _flash(req, _tr(req).t("Suppression impossible : tâche en cours d'exécution (ou déjà supprimée)."), "erreur")
        return _response.redirect(self._job_url(id), 303)

    async func _notify_job(req, action, id):
        if self.on_change == null:
            return
        r := self.on_change(req, {"action": action, "table": "jobs", "id": id, "values": null, "user_id": _auth.user_id(req)})
        if _aio.is_future(r):
            await r

    # Requête de la liste : recherche (q), filtres (f_<colonne>), tri (tri).
    func _query(req, m):
        q := m.table.query()
        terme := _s.trim(req.query_param("q", ""))
        if terme != "" and len(m.search_cols) > 0:
            q = q.search(m.search_cols, terme)
        actifs := {}
        for f in m.filters:
            v := req.query_param("f_" + f, "")
            if v != "":
                conv := _filter_value(m, f, v)
                if conv[0]:
                    q = q.where(f, conv[1])
                    actifs[f] = v
        tri := req.query_param("tri", "")
        nom := tri[1:len(tri)] if _s.starts_with(tri, "-") else tri
        if tri == "" or not (nom in m.list_cols):
            tri = m.order
        q = q.order_by(tri)
        if tri != m.order:
            q = q.order_by(m.order)          # ordre stable entre deux pages
        return [q, terme, actifs, tri]

    async func _list(req):
        tr := _tr(req)
        m := self._model(req)
        db := await self._db(req)
        r := self._query(req, m)
        q := r[0]
        refs := self._refs(m, m.list_cols)
        for ref in refs:
            q = q.with_one(ref[1].table, ref[0], "__ref_" + ref[0])
        page := 1
        try:
            page = to_int(req.query_param("page", "1"))
        catch e:
            page = 1
        p := await q.paginate(db, page, m.per_page)
        lignes := []
        for row in p["items"]:
            cells := []
            for c in m.list_cols:
                append(cells, self._cell(m, row, c, tr))
            append(lignes, {"href": self.url(m, "/" + str(row[m.table.pk])), "cells": cells, "title": m.title_of(row, tr)})
        base := {}
        if r[1] != "":
            base["q"] = r[1]
        for f in keys(r[2]):
            base["f_" + f] = r[2][f]
        colonnes := []
        for c in m.list_cols:
            sens := c if r[3] != c else "-" + c
            etat := "asc" if r[3] == c else ("desc" if r[3] == "-" + c else "")
            append(colonnes, {"label": m.label_of(c), "href": self.url(m) + "?" + _form_enc.encode(_with(base, "tri", sens)), "sort": etat})
        tri_actuel := {} if r[3] == m.order else {"tri": r[3]}
        avec_tri := _merge(base, tri_actuel)
        nav := {"page": p["page"], "pages": p["pages"], "total": p["total"],
                "prev": self.url(m) + "?" + _form_enc.encode(_with(avec_tri, "page", str(p["page"] - 1))) if p["has_prev"] else null,
                "next": self.url(m) + "?" + _form_enc.encode(_with(avec_tri, "page", str(p["page"] + 1))) if p["has_next"] else null}
        filtres := []
        for f in m.filters:
            append(filtres, await self._filter_widget(db, m, f, r[2][f] if f in r[2] else "", tr))
        export := _if(m.can_export, self.url(m, "/export.csv") + ("?" + _form_enc.encode(avec_tri) if len(avec_tri) > 0 else ""))
        return self._render(req, "list.html", {"page_title": m.label, "model": {"label": m.label, "href": self.url(m)},
            "columns": colonnes, "rows": lignes, "pager": nav, "search": r[1] if len(m.search_cols) > 0 else null,
            "searchable": len(m.search_cols) > 0, "filters": filtres, "new": self.url(m, "/nouveau") if m.can_create else null,
            "export": export, "filtered": r[1] != "" or len(r[2]) > 0})

    async func _export(req):
        m := self._model(req)
        if not m.can_export:
            _err.abort(403, _tr(req).t("export désactivé pour {table}", {"table": m.label}))
        db := await self._db(req)
        q := self._query(req, m)[0]
        cols := m.fields
        lignes := [_csv_line([m.label_of(c) for c in cols])]
        for row in await q.all(db):
            append(lignes, _csv_line([_csv_value(m.column(c), row[c]) for c in cols]))
        r := _response.text(_s.join("\r\n", lignes) + "\r\n")
        r.headers.set("Content-Type", "text/csv; charset=utf-8")
        r.headers.set("Content-Disposition", "attachment; filename=\"" + m.name + ".csv\"")
        return r

    async func _new(req):
        m := self._model(req)
        if not m.can_create:
            _err.abort(403, _tr(req).t("création désactivée pour {table}", {"table": m.label}))
        db := await self._db(req)
        valeurs := {}
        for n in m.editable():
            c := m.column(n)
            if c.has_default:
                valeurs[n] = c.default
        return self._render(req, "form.html", await self._form_ctx(db, m, null, valeurs, {}, _tr(req)))

    async func _create(req):
        m := self._model(req)
        if not m.can_create:
            _err.abort(403, _tr(req).t("création désactivée pour {table}", {"table": m.label}))
        db := await self._db(req)
        tr := _tr(req)
        lu := self._read_form(req, m, true, tr)
        if len(lu[1]) == 0:
            try:
                id := await m.table.insert(db, lu[0])
                await self._notify(req, "create", m, id, lu[0])
                _flash(req, tr.t("{table} : « {titre} » créé.", {"table": m.label, "titre": m.title_of(_merge(lu[0], {m.table.pk: id}), tr)}), "succes")
                suite := self.url(m, "/nouveau") if _forms.form(req).has("_encore") else self.url(m, "/" + str(id))
                return _response.redirect(suite, 303)
            catch e:
                lu = [lu[0], _db_errors(m, e, tr), lu[2]]
        return self._render(req, "form.html", await self._form_ctx(db, m, null, lu[2], lu[1], tr), 422)

    async func _row(req, m, db):
        row := await m.table.get(db, req.params["id"])
        if row == null:
            _err.abort(404, _tr(req).t("{table} n° {id} introuvable", {"table": m.label, "id": req.params["id"]}))
        return row

    async func _edit(req):
        m := self._model(req)
        db := await self._db(req)
        row := await self._row(req, m, db)
        return self._render(req, "form.html", await self._form_ctx(db, m, row, row, {}, _tr(req)))

    async func _update(req):
        m := self._model(req)
        if not m.can_edit:
            _err.abort(403, _tr(req).t("modification désactivée pour {table}", {"table": m.label}))
        db := await self._db(req)
        row := await self._row(req, m, db)
        tr := _tr(req)
        lu := self._read_form(req, m, false, tr)
        if len(lu[1]) == 0:
            try:
                await m.table.where(m.table.pk, row[m.table.pk]).update(db, lu[0])
                await self._notify(req, "update", m, row[m.table.pk], lu[0])
                _flash(req, tr.t("{table} : « {titre} » enregistré.", {"table": m.label, "titre": m.title_of(_merge(row, lu[0]), tr)}), "succes")
                return _response.redirect(self.url(m, "/" + str(row[m.table.pk])), 303)
            catch e:
                lu = [lu[0], _db_errors(m, e, tr), lu[2]]
        return self._render(req, "form.html", await self._form_ctx(db, m, row, _merge(row, lu[2]), lu[1], tr), 422)

    async func _confirm(req):
        m := self._model(req)
        if not m.can_delete:
            _err.abort(403, _tr(req).t("suppression désactivée pour {table}", {"table": m.label}))
        db := await self._db(req)
        row := await self._row(req, m, db)
        tr := _tr(req)
        return self._render(req, "confirm.html", {"page_title": tr.t("Supprimer"), "model": {"label": m.label, "href": self.url(m)},
            "title": m.title_of(row, tr), "back": self.url(m, "/" + str(row[m.table.pk])), "action": self.url(m, "/" + str(row[m.table.pk]) + "/supprimer")})

    async func _delete(req):
        m := self._model(req)
        if not m.can_delete:
            _err.abort(403, _tr(req).t("suppression désactivée pour {table}", {"table": m.label}))
        db := await self._db(req)
        row := await self._row(req, m, db)
        try:
            await m.table.where(m.table.pk, row[m.table.pk]).delete(db)
        catch e:
            if e.type != "IntegrityError":
                raise(e.type, e.message)
            _flash(req, _tr(req).t("Suppression impossible : d'autres lignes font référence à « {titre} ».", {"titre": m.title_of(row, _tr(req))}), "erreur")
            return _response.redirect(self.url(m, "/" + str(row[m.table.pk])), 303)
        await self._notify(req, "delete", m, row[m.table.pk], row)
        _flash(req, _tr(req).t("{table} : « {titre} » supprimé.", {"table": m.label, "titre": m.title_of(row, _tr(req))}), "succes")
        return _response.redirect(self.url(m), 303)

    # ------------------------------------------------------------ cellules, champs, formulaires

    # Clés étrangères de cols dont la table liée est enregistrée : [[colonne, ModelAdmin lié], ...].
    func _refs(m, cols):
        out := []
        for c in cols:
            rt := m.column(c).ref_table
            if rt != null:
                cible := self.model_for_table(rt)
                if cible != null:
                    append(out, [c, cible])
        return out

    func _cell(m, row, c, tr=null):
        col := m.column(c)
        v := row[c]
        cell := {"text": _display(col, v, tr), "kind": col.kind if col.ref_table == null else "ref", "href": null, "null": v == null,
                 "main": c == m.table.pk or c == m.display}
        if c in m.choices:
            cell["text"] = _choice_label(m.choices[c], v)
        if col.ref_table != null and v != null:
            cible := self.model_for_table(col.ref_table)
            lie := row["__ref_" + c] if ("__ref_" + c) in row else null
            if cible != null:
                cell["href"] = self.url(cible, "/" + str(v))
                cell["text"] = cible.title_of(lie, tr) if lie != null else _t(tr).t("n° {id} (introuvable)", {"id": v})
        if col.kind == "boolean":
            cell["text"] = _t(tr).t("oui") if v == true else (_t(tr).t("non") if v == false else "")
        return cell

    async func _choices_of(db, m, c, tr=null):
        if c in m.choices:
            return [{"value": str(x[0]), "label": str(x[1])} for x in m.choices[c]]
        rt := m.column(c).ref_table
        if rt == null:
            return null
        cible := self.model_for_table(rt)
        if cible == null or (await cible.table.query().count(db)) > MAX_CHOICES:
            return null
        q := cible.table.query()
        if cible.display != null:
            q = q.order_by(cible.display)
        return [{"value": str(r[cible.table.pk]), "label": cible.title_of(r, tr)} for r in await q.order_by(cible.table.pk).all(db)]

    async func _filter_widget(db, m, f, actuel, tr=null):
        col := m.column(f)
        w := {"name": "f_" + f, "label": m.label_of(f), "value": actuel, "options": null}
        if col.kind == "boolean":
            w["options"] = [{"value": "1", "label": _t(tr).t("oui")}, {"value": "0", "label": _t(tr).t("non")}]
        else:
            w["options"] = await self._choices_of(db, m, f, tr)
        if w["options"] != null:
            for o in w["options"]:
                o["selected"] = o["value"] == actuel
        return w

    async func _form_ctx(db, m, row, valeurs, erreurs, tr=null):
        champs := []
        for n in m.fields:
            if row == null and m.is_readonly(n):
                continue
            col := m.column(n)
            v := valeurs[n] if n in valeurs else null
            f := {"name": n, "label": m.label_of(n), "help": m.help[n] if n in m.help else null,
                  "error": erreurs[n] if n in erreurs else null, "readonly": m.is_readonly(n) or (row != null and not m.can_edit),
                  "required": not col.null_ok and not col.primary and col.kind != "boolean", "maxlength": col.max,
                  "widget": _widget(col), "value": _form_value(col, v), "checked": v == true, "options": null,
                  "display": _display(col, v, tr)}
            opts := await self._choices_of(db, m, n, tr)
            if opts != null and not f["readonly"]:
                f["widget"] = "select"
                courant := _form_value(col, v)
                for o in opts:
                    o["selected"] = o["value"] == courant
                f["options"] = opts
            if f["readonly"] and col.ref_table != null and v != null:
                cible := self.model_for_table(col.ref_table)
                if cible != null:
                    lie := await cible.table.get(db, v)
                    f["display"] = cible.title_of(lie, tr) if lie != null else _t(tr).t("n° {id}", {"id": v})
                    f["href"] = self.url(cible, "/" + str(v))
            if f["readonly"] and n in m.choices:
                f["display"] = _choice_label(m.choices[n], v)
            append(champs, f)
        id := row[m.table.pk] if row != null else null
        general := erreurs[""] if "" in erreurs else null
        return {"page_title": (m.title_of(row, tr) if row != null else _t(tr).t("Nouveau : {table}", {"table": m.label})),
                "model": {"label": m.label, "href": m.admin.url(m)}, "fields": champs, "error": general,
                "action": m.admin.url(m, "/" + str(id)) if row != null else m.admin.url(m, "/nouveau"),
                "editing": row != null, "can_save": (row == null and m.can_create) or (row != null and m.can_edit),
                "can_create": row == null, "delete": m.admin.url(m, "/" + str(id) + "/supprimer") if row != null and m.can_delete else null}

    # Valeurs du formulaire converties : [valeurs pour l'ORM, erreurs par champ, valeurs à réafficher].
    func _read_form(req, m, creation, tr=null):
        form := _forms.form(req)
        out := {}
        errs := {}
        saisies := {}
        if not creation and not m.can_edit:
            return [out, errs, saisies]
        for n in m.editable():
            col := m.column(n)
            if col.kind == "boolean":
                out[n] = form.has(n)
                saisies[n] = out[n]
                continue
            brut := form.get(n)
            if brut == null:
                if creation and not col.null_ok and not col.has_default:
                    errs[n] = _t(tr).t("valeur requise")
                continue
            saisies[n] = brut
            r := _parse_value(col, brut, tr)
            if r[0] != null:
                errs[n] = r[0]
                continue
            if r[1] != null and n in m.choices and not (_form_value(col, r[1]) in [str(x[0]) for x in m.choices[n]]):
                errs[n] = _t(tr).t("valeur hors de la liste")
                continue
            if r[1] == null and not col.null_ok:
                errs[n] = _t(tr).t("valeur requise")
                continue
            out[n] = r[1]
        return [out, errs, saisies]

# ================================================================ conversions

# [erreur ou null, valeur] depuis le texte d'un champ.
func _parse_value(col, brut, tr=null):
    t := _s.trim(brut) if col.kind != "text" else brut
    if t == "":
        return [null, null]
    if col.kind == "integer" or col.kind == "pk":
        try:
            return [null, to_int(t)]
        catch e:
            return [_t(tr).t("entier attendu"), null]
    if col.kind == "real":
        try:
            return [null, to_float(_s.replace(t, ",", "."))]
        catch e:
            return [_t(tr).t("nombre attendu"), null]
    if col.kind == "timestamp":
        for fmt in DATETIME_FORMATS:
            try:
                return [null, to_float(_time.mktime(_time.strptime(t, fmt)))]
            catch e:
                pass
        return [_t(tr).t("date attendue (AAAA-MM-JJ HH:MM)"), null]
    if col.kind == "json":
        try:
            return [null, _json.parse(t)]
        catch e:
            return [_t(tr).t("JSON invalide : {erreur}", {"erreur": e.message}), null]
    return [null, t]

# Valeur d'un filtre de liste : [vrai, valeur] ou [faux, null] si elle ne se convertit pas.
func _filter_value(m, f, v):
    col := m.column(f)
    if col.kind == "boolean":
        if v == "1" or v == "0":
            return [true, v == "1"]
        return [false, null]
    r := _parse_value(col, v)
    if r[0] != null or r[1] == null:
        return [false, null]
    return [true, r[1]]

func _form_value(col, v):
    if v == null:
        return ""
    if type(v) == "str" and col.kind != "text" and col.kind != "json":
        return v                          # saisie à réafficher telle quelle
    if col.kind == "timestamp":
        return _time.strftime("%Y-%m-%dT%H:%M", _time.localtime(v))
    if col.kind == "json":
        return v if type(v) == "str" else _json.stringify(v)
    if col.kind == "boolean":
        return "1" if v else ""
    return str(v)

func _display(col, v, tr=null):
    if v == null:
        return ""
    if col.kind == "timestamp":
        return _time.strftime("%Y-%m-%d %H:%M", _time.localtime(v))
    if col.kind == "json":
        t := _json.stringify(v)
        return t if len(t) <= 80 else t[0:79] + "…"
    if col.kind == "boolean":
        return _t(tr).t("oui") if v else _t(tr).t("non")
    t := str(v)
    return t if len(t) <= 80 else t[0:79] + "…"

func _widget(col):
    if col.kind == "boolean":
        return "checkbox"
    if col.kind == "timestamp":
        return "datetime"
    if col.kind == "json":
        return "textarea"
    if col.kind == "integer" or col.kind == "pk":
        return "integer"
    if col.kind == "real":
        return "real"
    if col.max == null or col.max > 200:
        return "textarea"
    return "text"

func _choice_label(choices, v):
    for x in choices:
        if x[0] == v or str(x[0]) == str(v):
            return str(x[1])
    return "" if v == null else str(v)

# Erreurs de l'ORM ou de la base, rangées par champ ("" : erreur générale).
func _db_errors(m, e, tr=null):
    if e.type == "ValidationError":
        out := {}
        msg := e.message
        prefixe := "table " + m.table.name + " : "
        if _s.starts_with(msg, prefixe):
            msg = msg[len(prefixe):len(msg)]
        for part in _s.split(msg, " ; "):
            i := _s.find(part, " : ")
            if i > 0 and part[0:i] in m.table.columns:
                out[part[0:i]] = _forms_message(tr, part)
            else:
                out[""] = part
        return out
    if e.type == "IntegrityError":
        bas := _s.lower(e.message)
        for n in m.fields:
            if m.column(n).unique and _s.contains(bas, _s.lower(n)):
                return {n: _t(tr).t("valeur déjà utilisée")}
        return {"": _t(tr).t("enregistrement refusé par la base : {erreur}", {"erreur": e.message})}
    raise(e.type, e.message)

# ================================================================ CSV

# Une cellule qui commence par = + - @ (ou tabulation, retour) serait lue comme une formule par un tableur :
# préfixée d'une apostrophe.
func _csv_value(col, v):
    if v == null:
        return ""
    t := ""
    if col.kind == "boolean":
        t = "1" if v else "0"
    elif col.kind == "timestamp":
        t = _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(v))
    elif col.kind == "json":
        t = _json.stringify(v)
    else:
        t = str(v)
    if type(v) == "str" and len(t) > 0 and (t[0:1] in ["=", "+", "-", "@", "\t", "\r"]):
        t = "'" + t
    return t

func _csv_line(cells):
    out := []
    for c in cells:
        if _s.contains(c, ",") or _s.contains(c, "\"") or _s.contains(c, "\n") or _s.contains(c, "\r"):
            append(out, "\"" + _s.replace(c, "\"", "\"\"") + "\"")
        else:
            append(out, c)
    return _s.join(",", out)

# ================================================================ divers

func _no_store(req, r):
    r.headers.set("Cache-Control", "no-store")
    if r.headers.get("X-Frame-Options") == null:
        r.headers.set("X-Frame-Options", "DENY")
    return r

func _css():
    r := _response.text(CSS)
    r.headers.set("Content-Type", "text/css; charset=utf-8")
    return r

# Traducteur de la requête (langue de l'application, sinon français) ; _t(null) : français.
func _tr(req):
    return _i18n.translator_for(req)

func _t(tr):
    return tr if tr != null else _i18n.default_translator()

# Erreur de l'ORM « colonne : message du schéma » -> message pour la personne qui saisit.
func _forms_message(tr, part):
    d := _forms.describe(part)
    return _forms.message(tr, d[1], d[2])

func _flash(req, message, category):
    if "session" in req.state:
        req.state["session"].flash(message, category)

func _flashes(req):
    if "session" in req.state:
        return req.state["session"].pop_flashes()
    return []

func _with(d, k, v):
    out := {}
    for x in keys(d):
        out[x] = d[x]
    out[k] = v
    return out

func _merge(a, b):
    out := {}
    for x in keys(a):
        out[x] = a[x]
    for x in keys(b):
        out[x] = b[x]
    return out

func _if(cond, v):
    return v if cond else null

func _job_status(s, tr=null):
    return _t(tr).t({"pending": "en attente", "running": "en cours", "failed": "abandonnée", "done": "faite"}[s]) if s in ["pending", "running", "failed", "done"] else str(s)

func _duration(s, tr=null):
    if s >= 86400 and s % 86400 == 0:
        return _t(tr).n("{n} jour(s)", to_int(s / 86400))
    if s >= 3600:
        return str(to_int(s / 3600)) + " h"
    return str(to_int(s / 60)) + " min"

func _job_time(t):
    if t == null:
        return "—"
    return _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(t))

# Moment utile d'une tâche : prochain essai (en attente), début (en cours), fin (faite, abandonnée).
func _job_when(r, tr=null):
    if r["status"] == "pending":
        return _t(tr).t("prévue {date}", {"date": _job_time(r["run_at"])})
    if r["status"] == "running":
        return _t(tr).t("depuis {date}", {"date": _job_time(r["locked_at"])})
    return _job_time(r["finished_at"])

func _short_text(t, n):
    if t == null:
        return ""
    return t if len(t) <= n else t[0:n - 1] + "…"

# Identifiant de tâche dans un chemin : tout sauf lettres, chiffres, « - _ . : » encodé.
func _quote(t):
    out := ""
    for ch in t:
        c := str(ch)
        if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_" or c == "." or c == ":":
            out = out + c
        else:
            for b in _s.byte_unpack(c):
                h := "0123456789ABCDEF"
                out = out + "%" + h[b // 16:b // 16 + 1] + h[b % 16:b % 16 + 1]
    return out

# ================================================================ gabarits

func _templates(admin):
    env := _tpl.Environment()
    env.add("base.html", BASE)
    env.add("index.html", INDEX)
    env.add("list.html", LIST)
    env.add("form.html", FORM)
    env.add("confirm.html", CONFIRM)
    env.add("jobs.html", JOBS)
    env.add("job.html", JOB)
    env.add("appearance.html", _panel.TEMPLATE)
    return env

const BASE := """<!doctype html>
<html lang="{{ lang }}" dir="{{ lang_dir }}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{{ page_title }} · {{ admin_title }}</title>
<link rel="stylesheet" href="{{ css }}">
</head>
<body>
<header><a class="marque" href="{{ home }}">{{ admin_title }}</a><nav>{% for n in nav %}<a href="{{ n.href }}"{% if n.current %} class="actif"{% endif %}>{{ n.label }}</a>{% endfor %}</nav>{% if user_id != null %}<span class="qui">{{ _("connecté : n° {id}", {"id": user_id}) }}</span>{% endif %}</header>
<main{% if wide %} class="large"{% endif %}>
{% for f in flashes %}<p class="flash {{ f.category }}">{{ f.message }}</p>{% endfor %}
{% block contenu %}{% endblock %}
</main>
</body>
</html>
"""

const INDEX := """{% extends "base.html" %}{% block contenu %}<h1>{{ admin_title }}</h1>
{% if cards %}<div class="cartes">{% for c in cards %}<div class="carte"><a class="titre" href="{{ c.href }}">{{ c.label }}</a><div class="n">{{ c.count }}</div>{% if c.note %}<div class="note">{{ c.note }}</div>{% endif %}{% if c.new %}<a href="{{ c.new }}">{{ _("Ajouter") }}</a>{% endif %}</div>{% endfor %}</div>
{% else %}<p>{{ _("Aucune table accessible.") }}</p>{% endif %}{% endblock %}"""

const LIST := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › {{ model.label }}</p>
<h1>{{ model.label }} <small class="fil">({{ pager.total }})</small></h1>
<form class="barre" method="get" action="{{ model.href }}">
{% if searchable %}<div><label class="f" for="q">{{ _("Recherche") }}</label><input id="q" name="q" type="search" value="{{ search }}"></div>{% endif %}
{% for f in filters %}<div><label class="f" for="{{ f.name }}">{{ f.label }}</label>{% if f.options != null %}<select id="{{ f.name }}" name="{{ f.name }}"><option value="">{{ _("tous") }}</option>{% for o in f.options %}<option value="{{ o.value }}"{% if o.selected %} selected{% endif %}>{{ o.label }}</option>{% endfor %}</select>{% else %}<input id="{{ f.name }}" name="{{ f.name }}" value="{{ f.value }}" size="10">{% endif %}</div>{% endfor %}
{% if searchable or filters %}<button type="submit">{{ _("Filtrer") }}</button>{% if filtered %}<a class="bouton" href="{{ model.href }}">{{ _("Effacer") }}</a>{% endif %}{% endif %}
<span class="pousse"></span>{% if export %}<a class="bouton" href="{{ export }}">{{ _("Export CSV") }}</a>{% endif %}{% if new %}<a class="bouton principal" href="{{ new }}">{{ _("Ajouter") }}</a>{% endif %}
</form>
<div class="tableau"><table><thead><tr>{% for c in columns %}<th class="{{ c.sort }}"><a href="{{ c.href }}">{{ c.label }}</a></th>{% endfor %}</tr></thead>
<tbody>{% for r in rows %}<tr>{% for c in r.cells %}<td class="{{ c.kind }}{% if c.null %} vide{% endif %}">{% if c.main %}<a href="{{ r.href }}">{{ c.text if c.text != "" else "—" }}</a>{% elif c.href %}<a href="{{ c.href }}">{{ c.text }}</a>{% else %}{{ c.text if not c.null else "—" }}{% endif %}</td>{% endfor %}</tr>
{% else %}<tr><td colspan="{{ columns | length }}" class="vide">{% if filtered %}{{ _("Aucune ligne ne correspond.") }}{% else %}{{ _("Aucune ligne.") }}{% endif %}</td></tr>{% endfor %}</tbody></table></div>
{% if pager.pages > 1 %}<div class="pages">{% if pager.prev %}<a class="bouton" href="{{ pager.prev }}">{{ _("Précédente") }}</a>{% endif %}<span>{{ _("page {page} sur {pages}", {"page": pager.page, "pages": pager.pages}) }}</span>{% if pager.next %}<a class="bouton" href="{{ pager.next }}">{{ _("Suivante") }}</a>{% endif %}</div>{% endif %}
{% endblock %}"""

const FORM := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › <a href="{{ model.href }}">{{ model.label }}</a></p>
<h1>{{ page_title }}</h1>
<form class="fiche" method="post" action="{{ action }}">{{ csrf_field() }}
{% if error %}<p class="erreur-generale">{{ error }}</p>{% endif %}
{% for f in fields %}<div class="champ{% if f.error %} erreur{% endif %}">
{% if f.widget == "checkbox" and not f.readonly %}<label><input type="checkbox" name="{{ f.name }}" value="1"{% if f.checked %} checked{% endif %}> <span class="lib lib-inline">{{ f.label }}</span></label>
{% else %}<label class="lib" for="c_{{ f.name }}">{{ f.label }}{% if f.required and not f.readonly %} *{% endif %}</label>
{% if f.readonly %}<div class="lecture" id="c_{{ f.name }}">{% if f.href %}<a href="{{ f.href }}">{{ f.display }}</a>{% else %}{{ f.display if f.display != "" else "—" }}{% endif %}</div>
{% elif f.widget == "select" %}<select id="c_{{ f.name }}" name="{{ f.name }}">{% if not f.required %}<option value="">—</option>{% endif %}{% for o in f.options %}<option value="{{ o.value }}"{% if o.selected %} selected{% endif %}>{{ o.label }}</option>{% endfor %}</select>
{% elif f.widget == "textarea" %}<textarea id="c_{{ f.name }}" name="{{ f.name }}"{% if f.maxlength %} maxlength="{{ f.maxlength }}"{% endif %}{% if f.required %} required{% endif %}>{{ f.value }}</textarea>
{% elif f.widget == "integer" %}<input id="c_{{ f.name }}" name="{{ f.name }}" type="number" step="1" value="{{ f.value }}"{% if f.required %} required{% endif %}>
{% elif f.widget == "real" %}<input id="c_{{ f.name }}" name="{{ f.name }}" type="number" step="any" value="{{ f.value }}"{% if f.required %} required{% endif %}>
{% elif f.widget == "datetime" %}<input id="c_{{ f.name }}" name="{{ f.name }}" type="datetime-local" value="{{ f.value }}"{% if f.required %} required{% endif %}>
{% else %}<input id="c_{{ f.name }}" name="{{ f.name }}" value="{{ f.value }}"{% if f.maxlength %} maxlength="{{ f.maxlength }}"{% endif %}{% if f.required %} required{% endif %}>{% endif %}
{% endif %}{% if f.help %}<div class="aide">{{ f.help }}</div>{% endif %}{% if f.error %}<div class="err">{{ f.error }}</div>{% endif %}
</div>{% endfor %}
<div class="actions">{% if can_save %}<button class="principal" type="submit">{{ _("Enregistrer") }}</button>{% if can_create %}<button type="submit" name="_encore" value="1">{{ _("Enregistrer et ajouter un autre") }}</button>{% endif %}{% endif %}
<a class="bouton" href="{{ model.href }}">{{ _("Retour à la liste") }}</a>{% if delete %}<span class="pousse"></span><a class="bouton danger" href="{{ delete }}">{{ _("Supprimer") }}</a>{% endif %}</div>
</form>{% endblock %}"""

const CONFIRM := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › <a href="{{ model.href }}">{{ model.label }}</a></p>
<h1>{{ _("Supprimer « {titre} » ?", {"titre": title}) }}</h1>
<form class="fiche" method="post" action="{{ action }}">{{ csrf_field() }}<p>{{ _("Cette suppression est définitive.") }}</p>
<div class="actions"><button class="danger" type="submit">{{ _("Supprimer") }}</button><a class="bouton" href="{{ back }}">{{ _("Annuler") }}</a></div></form>{% endblock %}"""

const JOBS := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › {{ _("Tâches") }}</p>
<h1>{{ _("Tâches de fond") }}</h1>
<div class="barre">{% for t in tabs %}<a class="bouton{% if t.current %} principal{% endif %}" href="{{ t.href }}">{{ t.label }} ({{ t.count }})</a>{% endfor %}<span class="pousse"></span>
{% if retry_all %}<form method="post" action="{{ retry_all }}">{{ csrf_field() }}<button type="submit">{{ _n("Réessayer les {n} abandonnée(s)", stats.failed) }}</button></form>{% endif %}</div>
<div class="tableau"><table><thead><tr><th>{{ _("Tâche") }}</th><th>{{ _("État") }}</th><th>{{ _("Essais") }}</th><th>{{ _("Quand") }}</th><th>{{ _("Dernière erreur") }}</th></tr></thead>
<tbody>{% for r in rows %}<tr><td><a href="{{ r.href }}">{{ r.name }}</a><div class="aide">{{ r.id }}</div></td><td class="etat-{{ r.kind }}">{{ r.status }}</td><td class="integer">{{ r.attempts }}</td><td>{{ r.when }}</td><td>{{ r.error }}</td></tr>
{% else %}<tr><td colspan="5" class="vide">{{ _("Aucune tâche.") }}</td></tr>{% endfor %}</tbody></table></div>
<p class="fil">{{ _("Les tâches faites sont gardées {done}, les abandonnées {failed}. Au plus 200 tâches par état sont montrées (les plus anciennes d'abord).", {"done": keep_done, "failed": keep_failed}) }}</p>
{% endblock %}"""

const JOB := """{% extends "base.html" %}{% block contenu %}<p class="fil"><a href="{{ home }}">{{ admin_title }}</a> › <a href="{{ back }}">{{ _("Tâches") }}</a></p>
<h1>{{ page_title }}</h1>
<div class="fiche"><table>{% for f in facts %}<tr><th>{{ f[0] }}</th><td>{{ f[1] }}</td></tr>{% endfor %}</table>
{% if error %}<div><div class="lib">{{ _("Dernière erreur") }}</div><pre class="erreur-generale">{{ error }}</pre></div>{% endif %}
<div><div class="lib">{{ _("Charge") }}</div><pre>{{ payload }}</pre></div>
<div class="actions">{% if retry %}<form method="post" action="{{ retry }}">{{ csrf_field() }}<button class="principal" type="submit">{{ _("Réessayer") }}</button></form>{% endif %}
<a class="bouton" href="{{ back }}">{{ _("Retour à la liste") }}</a><span class="pousse"></span>
{% if delete %}<form method="post" action="{{ delete }}">{{ csrf_field() }}<button class="danger" type="submit">{{ _("Supprimer") }}</button></form>{% endif %}</div></div>
{% endblock %}"""

const CSS := """:root{--fond:#f6f7f9;--carte:#fff;--texte:#1d2330;--doux:#5b6475;--ligne:#dde1e8;--accent:#2f5bd3;--accent-texte:#fff;--danger:#b42318;--succes:#1a7f45;--champ:#fff}
@media (prefers-color-scheme:dark){:root{--fond:#14171c;--carte:#1c2027;--texte:#e6e9ef;--doux:#9aa3b2;--ligne:#2e343e;--accent:#7b9cff;--accent-texte:#0d1220;--danger:#ff8a80;--succes:#6fd39a;--champ:#14171c}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--fond);color:var(--texte)}
a{color:var(--accent)}header{display:flex;flex-wrap:wrap;gap:4px 18px;align-items:center;padding:10px 20px;background:var(--carte);border-bottom:1px solid var(--ligne)}
header .marque{font-weight:600;color:var(--texte);text-decoration:none;margin-right:8px}header nav a{color:var(--doux);text-decoration:none;padding:4px 0}
header nav a.actif{color:var(--texte);border-bottom:2px solid var(--accent)}header nav{display:flex;flex-wrap:wrap;gap:4px 14px;flex:1}
header .qui{color:var(--doux);font-size:13px}main{max-width:1100px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:22px;margin:4px 0 16px}.fil{font-size:13px;color:var(--doux)}.fil a{color:var(--doux)}
.flash{padding:10px 14px;border-radius:6px;margin:0 0 14px;background:var(--carte);border:1px solid var(--ligne)}.flash.succes{border-color:var(--succes);color:var(--succes)}.flash.erreur{border-color:var(--danger);color:var(--danger)}
.cartes{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}.carte{background:var(--carte);border:1px solid var(--ligne);border-radius:8px;padding:14px 16px}
.carte .n{font-size:26px;font-weight:600}.carte a.titre{font-weight:600;text-decoration:none}
.barre{display:flex;flex-wrap:wrap;gap:8px;align-items:end;margin:0 0 12px}.pousse{flex:1}
input,select,textarea{font:inherit;color:var(--texte);background:var(--champ);border:1px solid var(--ligne);border-radius:6px;padding:6px 9px;max-width:100%}
textarea{width:100%;min-height:110px}label.f{display:block;font-size:12px;color:var(--doux)}
.bouton,button{font:inherit;display:inline-block;border:1px solid var(--ligne);background:var(--carte);color:var(--texte);border-radius:6px;padding:6px 12px;text-decoration:none;cursor:pointer}
.bouton.principal,button.principal{background:var(--accent);border-color:var(--accent);color:var(--accent-texte)}.bouton.danger,button.danger{color:var(--danger);border-color:var(--danger)}
.tableau{overflow-x:auto;background:var(--carte);border:1px solid var(--ligne);border-radius:8px}table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--ligne);vertical-align:top}th{font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--doux);white-space:nowrap}
th a{color:inherit;text-decoration:none}th.asc a::after{content:" ▲"}th.desc a::after{content:" ▼"}tr:last-child td{border-bottom:0}td.vide{color:var(--doux)}
td.integer,td.real,td.pk{font-variant-numeric:tabular-nums}.pages{display:flex;gap:10px;align-items:center;margin-top:12px;color:var(--doux)}
form.fiche{background:var(--carte);border:1px solid var(--ligne);border-radius:8px;padding:18px;display:grid;gap:14px;max-width:760px}
.champ .lib{font-weight:600;display:block;margin-bottom:4px}.champ .aide{font-size:13px;color:var(--doux)}.champ .err{color:var(--danger);font-size:13px}
.champ.erreur input,.champ.erreur textarea,.champ.erreur select{border-color:var(--danger)}.champ .lecture{color:var(--doux)}.actions{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.erreur-generale{color:var(--danger)}
.lib-inline,.champ .lib.lib-inline{display:inline}
div.fiche{background:var(--carte);border:1px solid var(--ligne);border-radius:8px;padding:18px;display:grid;gap:14px;max-width:900px}
pre{white-space:pre-wrap;word-break:break-word;background:var(--fond);border:1px solid var(--ligne);border-radius:6px;padding:10px;margin:4px 0 0;font-size:13px}
[hidden]{display:none!important}.graphe{display:block;width:100%;height:auto;max-height:160px}.graphe rect{fill:var(--accent)}.graphe .axe{stroke:var(--ligne);stroke-width:1}
.graphe-legende{display:flex;justify-content:space-between;font-size:12px;color:var(--doux)}.fiche.jeton{border-color:var(--succes)}
#jeton{user-select:all;font-size:14px}code.long{overflow-wrap:anywhere;word-break:break-all}td.etat-blocked{color:var(--danger)}td.etat-hidden{color:var(--doux)}
.fiche table th{white-space:nowrap;width:1%}.avis-admin{margin-bottom:12px}.ligne-avis{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}.etoiles{color:#d99000;letter-spacing:.06em}
.texte-avis{margin:0;white-space:pre-line;overflow-wrap:anywhere}.etat-avis{font-size:13px;color:var(--doux)}.etat-avis.etat-pending{color:var(--accent)}.etat-avis.etat-hidden{color:var(--danger)}form.fiche input[maxlength="500"],form.fiche input[maxlength="200"]{width:100%}main.large{max-width:1500px}h2{font-size:18px;margin:24px 0 10px}code{font-size:12px}
.apparence{display:grid;grid-template-columns:minmax(300px,420px) minmax(0,1fr);gap:16px;align-items:start}
@media (max-width:900px){.apparence{grid-template-columns:minmax(0,1fr)}}
form.reglages{display:grid;gap:12px;min-width:0}form.reglages fieldset{background:var(--carte);border:1px solid var(--ligne);border-radius:8px;padding:12px 14px 14px;display:grid;gap:12px;margin:0;min-width:0}
form.reglages legend{font-weight:600;padding:0 4px}.champ.modifie>.lib::after,.champ.modifie .lib-inline::after{content:" •";color:var(--accent)}
.reglages .champ input:not([type=checkbox]):not([type=color]):not([type=file]),.reglages .champ select,.reglages .champ textarea{width:100%}
.couleur{display:flex;gap:6px;align-items:center}.couleur input[type=color]{width:44px;height:34px;padding:2px;flex:none}
.liens{display:grid;gap:6px}.liens .ligne{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.4fr);gap:6px}
.champ .defaut{font-size:12px}.champ input[type=file]{margin-top:6px;font-size:13px}
.vignette{display:block;max-width:180px;max-height:64px;margin-top:6px;border:1px solid var(--ligne);border-radius:4px}
.actions.collantes{position:sticky;bottom:0;background:var(--fond);padding:10px 0;border-top:1px solid var(--ligne)}.etat{color:var(--doux);font-size:13px}
.apercu{position:sticky;top:12px;min-width:0}.apercu .barre{align-items:center}.vues{display:flex;gap:4px}
.cadre{background:var(--fond);border:1px solid var(--ligne);border-radius:8px;overflow:hidden;height:calc(100vh - 150px);min-height:440px}
.cadre iframe{display:block;border:0;width:1280px;height:100%;margin:0 auto;background:#fff;transform-origin:0 0}.cadre.tablette iframe{width:768px}.cadre.mobile iframe{width:390px}
.cartes.outils{margin-top:18px}.carte .titre{display:block;font-weight:600;margin-bottom:6px}
td.etat-failed{color:var(--danger)}td.etat-running{color:var(--accent)}td.etat-done{color:var(--succes)}.carte .note{color:var(--doux);font-size:13px}
"""
