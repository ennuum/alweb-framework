# alweb.deps — dépendances déclarées : des fournisseurs nommés, résolus avant l'appel du gestionnaire.
#
#   async func ouvrir_base(app):
#       db := alweb.database(app.config.get("database.url"))
#       await db.script(SCHEMA)
#       return db
#
#   async func utilisateur(req):
#       db := await alweb.dep(req, "db")           # un fournisseur peut dépendre d'un autre
#       u := await db.query_one("SELECT * FROM comptes WHERE jeton = ?", [req.header("x-jeton")])
#       if u == null:
#           alweb.abort(401, "jeton invalide")
#       return u
#
#   app.provide("db", ouvrir_base, "app", (db) => db.close())   # une fois, au démarrage ; fermé à l'arrêt
#   app.provide("user", utilisateur)                           # une fois par requête, si demandé
#
#   @app.get("/moi", {"deps": ["user"]})
#   func moi(req):
#       return req.deps["user"]
#
# Portées : "request" (défaut) : fn(req), au plus une fois par requête, à la demande ; "app" : fn(app), une fois au
# démarrage de l'application (ou au premier besoin). Un fournisseur peut être async. teardown(valeur) : appelé en
# fin de requête (portée request) ou à l'arrêt (portée app), même si le gestionnaire a échoué.
# Les dépendances d'une route (option "deps", et celles de son groupe) sont résolues avant l'appel, dans l'ordre ;
# une erreur (abort 401...) donne la réponse d'erreur sans appeler le gestionnaire. Ailleurs (intergiciel,
# fournisseur) : await alweb.dep(req, nom). Cycle de dépendances : erreur explicite.
# Tests : app.override(nom, fn) remplace un fournisseur (même portée) ; app.clear_overrides().

from core use len, type
from collections use append, keys
use asyncio as _aio
use alweb.errors as _err

class Registry:
    func init():
        self.providers = {}              # nom -> [fn, portée, teardown]
        self.overrides = {}              # nom -> fn
        self.app_values = {}             # nom -> valeur (portée app)
        self.app_order = []              # noms de portée app dans l'ordre de création (arrêt en sens inverse)
        self.request_teardowns = false   # au moins un fournisseur de portée request a un teardown

    func provide(name, fn, scope="request", teardown=null):
        if scope != "request" and scope != "app":
            _err.alweb_error("App.provide", "portée inconnue « " + str(scope) + " » (request ou app)")
        if name in self.app_values:
            _err.alweb_error("App.provide", "« " + name + " » est déjà créé : déclarer les fournisseurs avant le démarrage")
        self.providers[name] = [fn, scope, teardown]
        if scope == "request" and teardown != null:
            self.request_teardowns = true

    func override(name, fn):
        if not (name in self.providers):
            _err.alweb_error("App.override", "aucun fournisseur « " + str(name) + " »")
        self.overrides[name] = fn
        if name in self.app_values:
            self.app_values = _without(self.app_values, name)

    func clear_overrides():
        for name in keys(self.overrides):
            if name in self.app_values:
                self.app_values = _without(self.app_values, name)
        self.overrides = {}

    func has(name):
        return name in self.providers

    func _fn(name):
        return self.overrides[name] if name in self.overrides else self.providers[name][0]

    # Crée les dépendances de portée app (démarrage de l'application).
    async func start(app):
        for name in keys(self.providers):
            if self.providers[name][1] == "app":
                await self.app_value(app, name, [])

    async func app_value(app, name, chain):
        if name in self.app_values:
            return self.app_values[name]
        if name in chain:
            _err.alweb_error("dépendances", "cycle : " + _join(chain + [name]))
        v := self._fn(name)(app)
        if _aio.is_future(v):
            v = await v
        self.app_values[name] = v
        append(self.app_order, name)
        return v

    # Arrêt : teardown des dépendances de portée app, dans l'ordre inverse de création.
    async func stop():
        i := len(self.app_order) - 1
        while i >= 0:
            name := self.app_order[i]
            td := self.providers[name][2] if name in self.providers else null
            if td != null and name in self.app_values and not (name in self.overrides):
                r := td(self.app_values[name])
                if _aio.is_future(r):
                    await r
            i -= 1
        self.app_values = {}
        self.app_order = []

    # Valeur d'une dépendance pour une requête (mise en cache dans req.state["deps"]).
    async func resolve(app, req, name):
        if not (name in self.providers):
            _err.alweb_error("dépendances", "aucun fournisseur « " + str(name) + " » (app.provide)")
        p := self.providers[name]
        if p[1] == "app":
            return await self.app_value(app, name, [])
        cache := _cache(req)
        if name in cache:
            return cache[name]
        chain := req.state["deps_chain"] if "deps_chain" in req.state else []
        if name in chain:
            _err.alweb_error("dépendances", "cycle : " + _join(chain + [name]))
        req.state["deps_chain"] = chain + [name]
        v := null
        try:
            v = self._fn(name)(req)
            if _aio.is_future(v):
                v = await v
        finally:
            req.state["deps_chain"] = chain
        cache[name] = v
        if p[2] != null and not (name in self.overrides):
            append(_teardowns(req), [p[2], v])
        return v

# Résout les noms d'une route avant l'appel ; req.deps reçoit le dictionnaire.
async func resolve_all(app, req, names):
    cache := _cache(req)
    for n in names:
        cache[n] = await app.deps.resolve(app, req, n)    # portée app comprise : tout est dans req.deps
    req.deps = cache

# Teardown des dépendances de la requête (ordre inverse), erreurs ignorées : la réponse est déjà décidée.
async func finish(req):
    if not ("deps_teardown" in req.state):
        return
    tds := req.state["deps_teardown"]
    req.state["deps_teardown"] = []
    i := len(tds) - 1
    while i >= 0:
        try:
            r := tds[i][0](tds[i][1])
            if _aio.is_future(r):
                await r
        catch e:
            ignored := e
        i -= 1

func _cache(req):
    if not ("deps" in req.state):
        req.state["deps"] = {}
    return req.state["deps"]

func _teardowns(req):
    if not ("deps_teardown" in req.state):
        req.state["deps_teardown"] = []
    return req.state["deps_teardown"]

func _without(d, key):
    out := {}
    for k in keys(d):
        if k != key:
            out[k] = d[k]
    return out

func _join(names):
    out := ""
    for n in names:
        out = out + (" -> " if out != "" else "") + str(n)
    return out
