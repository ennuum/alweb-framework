# alweb.app — l'application : routes (décorateurs ou appels), groupes, intergiciels async, validation des
# entrées, cycle de vie, et lancement sur web.server avec sa boucle async.
#
#   use alweb
#   app := alweb.App()
#
#   @app.get("/")
#   func accueil(req):
#       return "<h1>Bonjour</h1>"
#
#   @app.get("/notes/{id:int}")
#   async func voir(req):
#       return {"id": req.params["id"]}
#
#   app.post("/notes", creer, {"body": NOTE})       # forme par appel ; body : schéma serialization.schema
#   api := app.group("/api", [alweb.middleware.request_id()])
#   api.get("/etat", (req) => {"ok": true})
#
#   await app.run("127.0.0.1", 8000)
#
# Un gestionnaire reçoit la requête web.http.request.Request (req.params : paramètres de route, req.query_param,
# req.json(), req.state...) et rend : Response, str (HTML s'il commence par « < »), dict / list (JSON),
# (corps, statut[, en-têtes]), un statut seul, ou null (204). Une `async func` est attendue sans bloquer le serveur.
#
# Intergiciel : fonction (req, suivant) ; `await suivant(req)` donne la Response de la suite de la chaîne. Il peut
# rendre sa propre réponse sans appeler la suite (refus, cache). Le premier ajouté est le plus extérieur.

from core use len, type
from collections use append, keys
use asyncio as _aio
use web.server as _server
use web.server.request_dispatch as _rd
use web.server.workers as _workers
use web.server.tls_server as _tlss
use web.http.response as _response
use alweb.alexdb as _axdb
use alweb.acme as _acme
use alweb.mail as _mail
use os as _os
use alweb.errors as _err
use alweb.deps as _deps
use alweb.templates as _tpl
use alweb.csrf as _csrf
use alweb.middleware as _mw
use alweb.chain as _chain
use web.http.date_header as _date

const METHODS := ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

class App:
    func init(name="alweb", debug=false):
        self.name = name
        self.router = _rd.Router()
        self.router.debug = debug
        self.debug = debug
        self.middlewares = []            # intergiciels de l'application (les plus extérieurs d'abord)
        self.startup = []                # fonctions () appelées avant de servir (async permises)
        self.shutdown = []               # fonctions () appelées après l'arrêt
        self.started = false
        self.deps = _deps.Registry()      # fournisseurs de dépendances (provide)
        self.config = null               # alweb.config.Config, si chargée (app.configure)
        self.templates = null            # alweb.templates.Environment (app.use_templates)
        self.context_processors = []     # fn(req) -> dict ajouté au contexte de chaque gabarit
        self.http_server = null          # web.server.Server pendant run()
        self.meta = []                   # description des routes (alweb.openapi)
        self.dispatcher = (req) => self.router.dispatch(req)
        self.on_exception = (req, e) => self.router._error_from_exception(req, e)
        self.preflight = {}              # motif -> vrai : route OPTIONS de pré-vérification CORS déjà posée
        self.trusted_proxies = null      # mandataires de confiance (server.trusted_proxies) : IP réelle du client
        self.tls = null                  # [certificat, clé, http2] lus dans server.tls (HTTPS sans code)
        self.acme = null                 # alweb.acme.Settings (server.tls.acme : certificat Let's Encrypt automatique)
        self.acme_manager = null         # service ACME en cours (run / maître de run_workers)
        self.mailer = null               # alweb.mail.Mailer (clé « mail »), créé au premier usage (app.mail())
        self.jobs = null                 # alweb.jobs.Queue (tâches de fond), posé par jobs.Queue(app, …)
        self.theme = null                # alweb.themes.Theme (thème actif), posé par themes.setup(app)
        self.storage = null              # alweb.storage (fichiers : disque, S3), posé par storage.setup(app)
        self.i18n = null                 # alweb.i18n.I18n (traductions, langue des requêtes), posé par i18n.I18n(app, …)

    # ---------------------------------------------------------------- routes

    # Déclare une route. Formes acceptées (ALEX ne transmet pas d'arguments nommés aux méthodes : les options
    # passent par un dictionnaire) :
    #   app.route(["GET", "POST"], "/x", gestionnaire)
    #   app.route(["GET"], "/x", gestionnaire, {"name": "x"})
    #   @app.route(["POST"], "/x", {"body": SCHEMA})      # décorateur : options sans gestionnaire
    # Options : name (pour url_for), body / query (schémas serialization.schema des données JSON du corps / des
    # paramètres de requête, validées et converties dans req.state["body"] / ["query"], voir alweb.data), middleware
    # (intergiciel ou liste, propres à la route, après ceux de l'application et du groupe).
    # Documentation (alweb.openapi) : summary, description, tags, response (schéma de la réponse 2xx), status
    # (statut de succès, 200 par défaut), responses ({statut: description ou {description, schema}}), security
    # (liste de schémas d'authentification, ex. ["bearer"]), operation_id, hidden (absente de la description).
    # deprecated : vrai, ou horodatage Unix (en-tête Deprecation: @horodatage) ; sunset : horodatage Unix de retrait
    # (en-tête Sunset). cors : liste d'origines, ou dict {origins, methods, headers, credentials, max_age, expose}
    # (pré-vérification OPTIONS ajoutée pour ce motif).
    func route(methods, pattern, a=null, b=null):
        opts := _options(a, b)
        handler := a if type(a) != "dict" else null
        if handler == null:
            return (fn) => self._register(methods, pattern, fn, opts)
        return self._register(methods, pattern, handler, opts)

    func get(pattern, a=null, b=null):
        return self.route(["GET"], pattern, a, b)

    func post(pattern, a=null, b=null):
        return self.route(["POST"], pattern, a, b)

    func put(pattern, a=null, b=null):
        return self.route(["PUT"], pattern, a, b)

    func patch(pattern, a=null, b=null):
        return self.route(["PATCH"], pattern, a, b)

    func delete(pattern, a=null, b=null):
        return self.route(["DELETE"], pattern, a, b)

    func any(pattern, a=null, b=null):
        return self.route(["*"], pattern, a, b)

    func _register(methods, pattern, handler, opts):
        if handler == null:
            _err.alweb_error("App.route", "gestionnaire requis pour " + str(pattern))
        mws := _as_list(opts["middleware"]) if "middleware" in opts else []
        body := opts["body"] if "body" in opts else null
        query := opts["query"] if "query" in opts else null
        name := opts["name"] if "name" in opts else null
        deps := _as_list(opts["deps"]) if "deps" in opts else []
        for d in deps:
            if not self.deps.has(d):
                _err.alweb_error("App.route", "dépendance « " + str(d) + " » sans fournisseur (app.provide avant la route) : " + str(pattern))
        extra := []
        if "cors" in opts and opts["cors"] != null:
            c := _cors_middleware(opts["cors"])
            append(extra, c)
            if not (pattern in self.preflight):
                self.preflight[pattern] = true
                self.router.route(["OPTIONS"], pattern, _endpoint(self, _preflight_ok, null, null, [c], []), null)
        dep_mw := _deprecation_middleware(opts)
        if dep_mw != null:
            append(extra, dep_mw)
        self.router.route(methods, pattern, _endpoint(self, handler, body, query, extra + mws, deps), name)
        m := {"methods": methods, "pattern": pattern, "handler": handler}
        for k in keys(opts):
            if k != "middleware":
                m[k] = opts[k]
        append(self.meta, m)
        return handler                   # un décorateur rend la fonction d'origine, utilisable telle quelle

    # Point d'accès WebSocket (web.server.websocket) ; décorateur sans gestionnaire. Le gestionnaire reçoit
    # (requête, session) : `m := await ws.receive()`, `await ws.send_text(...)`. Options : protocols (liste),
    # max_message (octets), origins (liste d'origines permises), name.
    #   @app.websocket("/chat/{salon}")
    #   async func chat(req, ws): ...
    func websocket(pattern, a=null, b=null):
        opts := a if type(a) == "dict" else (b if b != null else {})
        for k in keys(opts):
            if not (k in WS_OPTIONS):
                _err.alweb_error("App.websocket", "option inconnue « " + str(k) + " » (permises : protocols, max_message, origins, name)")
        handler := a if type(a) != "dict" else null
        if handler == null:
            return (fn) => self._register_ws(pattern, fn, opts)
        return self._register_ws(pattern, handler, opts)

    func _register_ws(pattern, handler, opts):
        self.router.websocket(pattern, (req, ws) => _ws_call(handler, req, ws), opts["protocols"] if "protocols" in opts else null, opts["max_message"] if "max_message" in opts else 16777216, opts["origins"] if "origins" in opts else null, opts["name"] if "name" in opts else null)
        return handler

    # Groupe de routes sous un préfixe, avec ses propres intergiciels :  api := app.group("/api", [auth])
    # deps : dépendances résolues pour toutes les routes du groupe (avant celles de la route).
    # opts : options appliquées à toutes les routes du groupe : tags (ajoutés à ceux de la route), deprecated,
    # sunset, security, cors (valeurs par défaut que la route peut remplacer). Versionnage d'API par préfixe :
    #   v1 := app.group("/api/v1", null, null, {"tags": ["v1"], "deprecated": 1767225600, "sunset": 1782864000})
    #   v2 := app.group("/api/v2", null, null, {"tags": ["v2"]})
    func group(prefix, middleware=null, deps=null, opts=null):
        return Group(self, prefix, _as_list(middleware), _as_list(deps), opts)

    # Fichiers statiques (web.server.static_files : ETag, 304, plages, index).
    func static(prefix, directory, index=null, listing=false, max_age=0, fallback=null):
        self.router.static(prefix, directory, index, listing, max_age, fallback)
        return self

    # Monte le routeur d'une autre App sous un préfixe (les intergiciels d'application de celle-ci ne s'appliquent
    # pas : déclarez-les sur un groupe).
    func mount(prefix, other):
        self.router.mount(prefix, other.router if isinstance(other, App) else other)
        return self

    func url_for(name, values=null):
        return self.router.url_for(name, values)

    # Liste (méthodes, motif, nom) des routes.
    func routes():
        return self.router.describe()

    # ---------------------------------------------------------------- intergiciels, erreurs, cycle de vie

    # Ajoute un ou plusieurs intergiciels d'application : app.middleware(a) ou app.middleware([a, b]).
    func middleware(middleware):
        for m in _as_list(middleware):
            append(self.middlewares, m)
        return self

    # Gestionnaire d'erreur pour un statut (décorateur possible) : fn(req, statut, message) -> résultat.
    func error_handler(status, fn=null):
        if fn == null:
            return (f) => self._on_error(status, f)
        return self._on_error(status, fn)

    func _on_error(status, fn):
        self.router.on_error(status, fn)
        return fn

    func on_startup(fn):
        append(self.startup, fn)
        return fn

    func on_shutdown(fn):
        append(self.shutdown, fn)
        return fn

    # Lance les fonctions de démarrage (une seule fois).
    async func start():
        if self.started:
            return self
        await self.deps.start(self)
        for fn in self.startup:
            r := fn()
            if _aio.is_future(r):
                await r
        self.started = true
        return self

    async func stop():
        if not self.started:
            return self
        for fn in self.shutdown:
            r := fn()
            if _aio.is_future(r):
                await r
        await self.deps.stop()
        self.started = false
        return self

    # Configuration (alweb.config.Config) : app.config ; le mode debug suit la clé « debug » si elle existe.
    # server.trusted_proxies : IP ou préfixes des mandataires inverses (Caddy, nginx) dont les en-têtes
    # X-Forwarded-For / X-Forwarded-Proto / Forwarded sont crus (req.state["client_ip"], ["scheme"]).
    # server.tls.cert et server.tls.key (chemins PEM) : run / run_workers servent en HTTPS (HTTP/2 par ALPN sauf
    # server.tls.http2 = false), aussi dans l'exécutable natif (TLS 1.3 écrit en ALEX). Un certificat renouvelé
    # sur le disque est relu à la connexion suivante. Avec le TLS ALEX, les poignées de main avancent sans bloquer
    # la boucle et leur calcul part sur un fil (server.tls.offload = false : calcul dans la boucle).
    # server.tls.acme : certificat obtenu et renouvelé auprès de Let's Encrypt par run / run_workers (alweb.acme).
    func configure(cfg):
        self.config = cfg
        self.mailer = null
        d := cfg.get("debug")
        if d != null:
            self.debug = d == true
            self.router.debug = self.debug
        tp := cfg.get("server.trusted_proxies")
        if tp != null:
            self.trusted_proxies = tp if type(tp) == "list" else [tp]
        cert := cfg.get("server.tls.cert")
        key := cfg.get("server.tls.key")
        am := cfg.get("server.tls.acme")
        if am != null and am != false:
            self.acme = _acme.Settings(am, cert, key, _os.getenv("ALWEB_ROOT"))
            cert = self.acme.cert
            key = self.acme.key
        if cert != null or key != null:
            if cert == null or key == null or cert == "" or key == "":
                _err.alweb_error("App.configure", "server.tls : cert et key sont requis ensemble")
            h2 := cfg.get("server.tls.http2")
            off := cfg.get("server.tls.offload")
            self.tls = [cert, key, h2 != false, off != false]
        return self

    # Envoi de courriels (alweb.mail.Mailer) réglé par la clé « mail » de la configuration ; en mode debug sans
    # réglage : affichés dans la console. Créé au premier appel, puis le même.
    func mail():
        if self.mailer == null:
            self.mailer = _mail.Mailer(self.config.get("mail") if self.config != null else null, self.debug, self)
        return self.mailer

    # Configuration de serveur par défaut : HTTPS si server.tls est configuré.
    func _default_config(host, port):
        c := _server.config(host, port)
        if self.tls != null:
            c.tls = _tlss.TlsServerConfig(self.tls[0], self.tls[1], ["h2", "http/1.1"] if self.tls[2] else ["http/1.1"], 10.0, self.tls[3])
        return c

    # ---------------------------------------------------------------- gabarits (alweb.templates)

    # Dossier des gabarits ; relus quand leur fichier change si l'application est en mode debug.
    # Variables toujours disponibles : request, url_for(nom, valeurs), app_name, config, et celles des
    # processeurs de contexte (session, csrf_token, flash... quand ces fonctions sont activées).
    func use_templates(directory):
        self.templates = _tpl.Environment(directory, self.debug)
        self.templates.globals["url_for"] = (name, values=null) => self.router.url_for(name, values)
        self.templates.globals["app_name"] = self.name
        return self.templates

    # Ajoute au contexte de chaque gabarit le dict rendu par fn(req) (décorateur possible).
    func context_processor(fn):
        append(self.context_processors, fn)
        return fn

    # Page HTML rendue avec le gabarit name : Response 200 (ou status).
    func render(req, name, context=null, status=200):
        if self.templates == null:
            _err.alweb_error("render", "aucun dossier de gabarits : appeler app.use_templates(dossier)")
        ctx := {"request": req, "config": self.config}
        if "session" in req.state:
            sess := req.state["session"]
            ctx["session"] = sess
            ctx["flashes"] = () => sess.pop_flashes()        # {% for f in flashes() %}
        if "csrf" in req.state:
            ctx["csrf_token"] = () => _csrf.token(req)
            ctx["csrf_field"] = () => _csrf.field(req)
        for fn in self.context_processors:
            extra := fn(req)
            if extra != null:
                for k in keys(extra):
                    ctx[k] = extra[k]
        if context != null:
            for k in keys(context):
                ctx[k] = context[k]
        return _response.html(self.templates.render(name, ctx), status)

    # ---------------------------------------------------------------- dépendances (alweb.deps)

    # Fournisseur nommé : fn(req) (portée "request", une fois par requête) ou fn(app) (portée "app", une fois) ;
    # teardown(valeur) en fin de requête / à l'arrêt.
    func provide(name, fn, scope="request", teardown=null):
        self.deps.provide(name, fn, scope, teardown)
        return self

    # Valeur d'une dépendance de portée app déjà créée (après le démarrage), sinon null :
    #   store := rl.DatabaseStore(() => app.value("db"))
    func value(name):
        return self.deps.app_values[name] if name in self.deps.app_values else null

    # Tests : remplace un fournisseur (même portée), sans toucher au code de l'application.
    func override(name, fn):
        self.deps.override(name, fn)
        return self

    func clear_overrides():
        self.deps.clear_overrides()
        return self

    # ---------------------------------------------------------------- traitement

    # Point d'entrée d'une requête (c'est l'« application » donnée à web.server) : une Response, ou une tâche qui
    # rendra une Response. Sans intergiciel d'application, une route synchrone reste entièrement synchrone.
    func handle(req):
        req.state["app"] = self
        r := self.router.dispatch(req) if len(self.middlewares) == 0 else _chain.run(self.middlewares, 0, req, self.dispatcher, self.on_exception)
        if _aio.is_future(r) and self.deps.request_teardowns:
            return _after(r, req)
        return r

    # ---------------------------------------------------------------- service

    # web.server.Server configuré pour cette application (port 0 : choisi par le système).
    func server(host="127.0.0.1", port=8000, cfg=null):
        c := cfg if cfg != null else self._default_config(host, port)
        c.host = host
        c.port = port
        c.debug = c.debug or self.debug
        self.router.debug = c.debug
        self._server_options(c)
        return _server.Server((req) => self.handle(req), c)

    func _server_options(c):
        if self.trusted_proxies != null and c.trusted_proxies == null:
            c.trusted_proxies = self.trusted_proxies

    # Démarre l'application et sert jusqu'à Ctrl+C / TERM (arrêt propre), puis lance les fonctions d'arrêt.
    #   await app.run("0.0.0.0", 8000)
    async func run(host="127.0.0.1", port=8000, cfg=null, quiet=false):
        mgr := self._start_acme(host, port, quiet)
        srv := self.server(host, port, cfg)
        srv.config.handle_signals = true
        if cfg == null:
            srv.config.access_log = false
        await self.start()
        srv.start()
        self.http_server = srv
        if not quiet:
            print(self.name + " à l'écoute sur " + srv.url())
        task := mgr.loop() if mgr != null else null
        self._start_jobs()
        try:
            await srv.serve_forever_async()
        finally:
            self.http_server = null
            if mgr != null:
                mgr.shutdown()
                await task
                self.acme_manager = null
            await self._stop_jobs()
            await self.stop()
        return srv

    # File de tâches (alweb.jobs) : tourne dans chaque processus qui sert, après le démarrage (base ouverte) ;
    # jobs.worker = false dans la configuration pour qu'un processus ne fasse que mettre en file.
    func _start_jobs():
        if self.jobs != null and not (self.config != null and self.config.get("jobs.worker") == false):
            self.jobs.start()

    async func _stop_jobs():
        if self.jobs != null:
            await self.jobs.stop()

    # Service ACME (server.tls.acme) : certificat d'attente au besoin, port des défis ouvert ; null sans ACME.
    func _start_acme(host, port, quiet):
        if self.acme == null:
            return null
        mgr := _acme.Manager(self.acme, port, host, quiet)
        mgr.start()
        self.acme_manager = mgr
        return mgr

    # Comme run, sur count processus ouvriers partageant le port (0 : un par cœur ; voir web.server.workers).
    # Le programme est relancé dans chaque ouvrier : les fonctions de démarrage et d'arrêt s'exécutent dans
    # chaque ouvrier, jamais dans le maître. Pas d'état partagé en mémoire entre ouvriers.
    #   await app.run_workers("0.0.0.0", 8000, 4)
    # Base locale (database.url = "alexdb+local:dossier") : le maître héberge le serveur ALEX DB, les ouvriers
    # s'y connectent (alweb.alexdb_local).
    async func run_workers(host="127.0.0.1", port=8000, count=0, cfg=null, quiet=false, reload=false):
        if not _workers.is_worker():
            local := _axdb.master_setup(self.config.get("database.url") if self.config != null else null)
            services := local[0]
            mgr := self._start_acme(host, port, quiet)       # le maître écoute les défis et renouvelle
            if mgr != null:
                append(services, mgr)
            # configuration du maître : sert à l'annonce (https) et contrôle le certificat avant de lancer les ouvriers
            mc := cfg if cfg != null else self._default_config(host, port)
            return await _workers.serve(null, host, port, count, mc, quiet, reload, local[1], services)
        c := cfg if cfg != null else self._default_config(host, port)
        c.debug = c.debug or self.debug
        self.router.debug = c.debug
        self._server_options(c)
        await self.start()
        self._start_jobs()
        try:
            return await _workers.serve((req) => self.handle(req), host, port, count, c, true)
        finally:
            await self._stop_jobs()
            await self.stop()

    # Développement : un ouvrier, mode debug, rechargé à chaque modification d'un fichier .al du dossier du
    # programme (une erreur de syntaxe s'affiche, le service reprend à la correction suivante).
    #   await app.run_dev()                      # http://127.0.0.1:8000/
    async func run_dev(host="127.0.0.1", port=8000):
        self.debug = true
        return await self.run_workers(host, port, 1, null, false, true)

# Groupe de routes : préfixe + intergiciels, appliqués aux routes déclarées par le groupe.
class Group:
    func init(app, prefix, middlewares, deps=null, opts=null):
        self.app = app
        self.prefix = _strip_slash(prefix)
        self.middlewares = middlewares
        self.deps = deps if deps != null else []
        self.opts = opts if opts != null else {}
        for k in keys(self.opts):
            if not (k in GROUP_OPTIONS):
                _err.alweb_error("App.group", "option de groupe inconnue « " + str(k) + " » (permises : tags, deprecated, sunset, security, cors)")

    func route(methods, pattern, a=null, b=null):
        opts := _options(a, b)
        merged := {}
        for k in keys(self.opts):
            merged[k] = self.opts[k]
        for k in keys(opts):
            merged[k] = opts[k]
        if "tags" in self.opts:
            merged["tags"] = _as_list(self.opts["tags"]) + (_as_list(opts["tags"]) if "tags" in opts else [])
        merged["middleware"] = self.middlewares + (_as_list(opts["middleware"]) if "middleware" in opts else [])
        merged["deps"] = self.deps + (_as_list(opts["deps"]) if "deps" in opts else [])
        if type(a) == "dict" or a == null:
            return self.app.route(methods, self.prefix + pattern, merged)
        return self.app.route(methods, self.prefix + pattern, a, merged)

    func get(pattern, a=null, b=null):
        return self.route(["GET"], pattern, a, b)

    func post(pattern, a=null, b=null):
        return self.route(["POST"], pattern, a, b)

    func put(pattern, a=null, b=null):
        return self.route(["PUT"], pattern, a, b)

    func patch(pattern, a=null, b=null):
        return self.route(["PATCH"], pattern, a, b)

    func delete(pattern, a=null, b=null):
        return self.route(["DELETE"], pattern, a, b)

    func group(prefix, middleware=null, deps=null, opts=null):
        merged := {}
        for k in keys(self.opts):
            merged[k] = self.opts[k]
        if opts != null:
            for k in keys(opts):
                merged[k] = opts[k]
            if "tags" in self.opts and "tags" in opts:
                merged["tags"] = _as_list(self.opts["tags"]) + _as_list(opts["tags"])
        return Group(self.app, self.prefix + _strip_slash(prefix), self.middlewares + _as_list(middleware), self.deps + _as_list(deps), merged)

    # Point d'accès WebSocket sous le préfixe du groupe (les intergiciels du groupe ne s'y appliquent pas).
    func websocket(pattern, a=null, b=null):
        return self.app.websocket(self.prefix + pattern, a, b)

# ---------------------------------------------------------------- points d'arrivée

# Fonction appelée par le routeur pour une route : intergiciels de route, validation des entrées, dépendances,
# gestionnaire. Sans rien de cela, c'est le gestionnaire lui-même (aucun coût ajouté).
func _endpoint(app, handler, body, query, mws, deps):
    if body == null and query == null and len(mws) == 0 and len(deps) == 0:
        params_handler := (req) => _with_params(handler, req)
        return params_handler
    if len(mws) == 0:
        return (req) => _invoke(app, handler, req, body, query, deps)
    final := (req) => _route_final(app, handler, req, body, query, deps)
    return (req) => _chain.run(mws, 0, req, final, app.on_exception)

# Fin de la chaîne d'une route : une Response, ou une tâche qui en rendra une.
func _route_final(app, handler, req, body, query, deps):
    r := _invoke(app, handler, req, body, query, deps)
    if _aio.is_future(r):
        return _response_later(r, req)
    return _rd.to_response(r, req)

async func _response_later(fut, req):
    return _rd.to_response(await fut, req)


# req.params : alias de req.route_params (nom court, comme dans la plupart des frameworks).
func _with_params(handler, req):
    req.params = req.route_params
    return _call(handler, req)

# Appel du gestionnaire : un UploadError (fichier refusé par forms.check_upload, formulaire trop volumineux,
# image illisible) devient une réponse 400 avec son message, au lieu d'une erreur 500.
func _call(handler, req):
    r := null
    try:
        r = handler(req)
    catch e:
        _client_error(e)
    if _aio.is_future(r):
        return _call_later(r)
    return r

async func _call_later(fut):
    try:
        return await fut
    catch e:
        _client_error(e)

func _client_error(e):
    if e.type == "UploadError":
        _err.abort(400, e.message)
    raise(e)

# Validation (422 sans résoudre les dépendances), puis dépendances, puis gestionnaire.
func _invoke(app, handler, req, body, query, deps):
    req.params = req.route_params
    refused := _validate(req, body, query)
    if refused != null:
        return refused
    if len(deps) == 0:
        return _call(handler, req)
    return _with_deps(app, handler, req, deps)

async func _with_deps(app, handler, req, deps):
    await _deps.resolve_all(app, req, deps)
    r := _call(handler, req)
    if _aio.is_future(r):
        r = await r
    return r

# Attend la réponse puis lance le teardown des dépendances de la requête.
async func _after(pending, req):
    try:
        return await pending
    finally:
        await _deps.finish(req)

# Réponse 422 si les données ne respectent pas leur schéma, sinon null (données rangées dans req.state).
func _validate(req, body, query):
    if query != null:
        data := _coerce(query, req.query().to_dict())
        errs := query.validate(data)
        if len(errs) > 0:
            return _unprocessable("paramètres de requête invalides", errs)
        req.state["query"] = data
    if body != null:
        data := req.json()                # JSON invalide : JSONError -> 400 (routeur)
        errs := body.validate(data)
        if len(errs) > 0:
            return _unprocessable("corps de requête invalide", errs)
        req.state["body"] = _coerce(body, data)
    return null

func _coerce(schema, data):
    try:
        return schema.coerce(data)
    catch e:
        return data

func _unprocessable(message, errs):
    return _response.json({"error": "Unprocessable Content", "status": 422, "message": message, "details": errs}, 422)

# ---------------------------------------------------------------- utilitaires

const ROUTE_OPTIONS := ["name", "body", "query", "middleware", "deps", "summary", "description", "tags", "response", "status", "responses", "security", "operation_id", "hidden", "deprecated", "sunset", "cors"]
const GROUP_OPTIONS := ["tags", "deprecated", "sunset", "security", "cors"]

func _preflight_ok(req):
    return _response.no_content()

# Intergiciel CORS d'une route : liste d'origines ou dict d'options (alweb.middleware.cors).
func _cors_middleware(c):
    if type(c) == "list" or type(c) == "str":
        return _mw.cors(_as_list(c))
    if type(c) != "dict":
        _err.alweb_error("App.route", "option cors : liste d'origines ou dictionnaire attendu")
    g := (k, d) => c[k] if k in c else d
    return _mw.cors(g("origins", null), g("methods", null), g("headers", null), g("credentials", false), g("max_age", 600), g("expose", null))

# En-têtes Deprecation (RFC 9745) et Sunset (RFC 8594) d'une route ou d'une version d'API retirée.
func _deprecation_middleware(opts):
    d := opts["deprecated"] if "deprecated" in opts else null
    sun := opts["sunset"] if "sunset" in opts else null
    dep_value := ("@" + str(d)) if (d != null and type(d) == "int") else null
    sun_value := _date.format(sun) if sun != null else null
    if dep_value == null and sun_value == null:
        return null
    return (req, nxt) => _deprecation(req, nxt, dep_value, sun_value)

async func _deprecation(req, nxt, dep_value, sun_value):
    r := await nxt(req)
    if dep_value != null:
        r.headers.set("Deprecation", dep_value)
    if sun_value != null:
        r.headers.set("Sunset", sun_value)
    return r
const WS_OPTIONS := ["protocols", "max_message", "origins", "name"]

func _ws_call(handler, req, ws):
    req.params = req.route_params
    return handler(req, ws)

# Options d'une route : le dictionnaire passé en 3e ou 4e argument (vérifié : une clé inconnue est une erreur).
func _options(a, b):
    opts := a if type(a) == "dict" else b
    if opts == null:
        return {}
    if type(opts) != "dict":
        _err.alweb_error("App.route", "options attendues sous forme de dictionnaire, obtenu " + type(opts))
    for k in keys(opts):
        if not (k in ROUTE_OPTIONS):
            _err.alweb_error("App.route", "option de route inconnue « " + str(k) + " » (permises : " + _join(ROUTE_OPTIONS) + ")")
    return opts

func _as_list(x):
    if x == null:
        return []
    if type(x) == "list":
        return x
    if type(x) == "tuple":
        out := []
        for v in x:
            append(out, v)
        return out
    return [x]

func _strip_slash(p):
    s := p
    while len(s) > 0 and s[len(s) - 1:len(s)] == "/":
        s = s[0:len(s) - 1]
    return s

func _join(xs):
    out := ""
    for x in xs:
        out = out + (", " if out != "" else "") + x
    return out
