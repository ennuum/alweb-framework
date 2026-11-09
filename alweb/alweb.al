# alweb — framework web pour ALEX, au-dessus de web.server.
#
#   use alweb
#
#   app := alweb.App("notes")
#
#   @app.get("/")
#   func accueil(req):
#       return "<h1>Notes</h1>"
#
#   @app.get("/notes/{id:int}")
#   async func voir(req):
#       note := await trouver(req.params["id"])      # E/S async : le serveur sert les autres pendant ce temps
#       if note == null:
#           alweb.abort(404, "note introuvable")
#       return note                                   # dict -> JSON
#
#   await app.run("127.0.0.1", 8000)
#
# Temps réel : @app.websocket(chemin) (sessions async), alweb.sse(producteur), alweb.stream(producteur).
# Plusieurs cœurs : await app.run_workers(hôte, port, n) ; développement : await app.run_dev() (rechargement).
# Sans bloquer : await alweb.offload(fn, args) (calcul sur un fil), alweb.database(url) (base attendue avec await).
# Dépendances : app.provide(nom, fn, portée), {"deps": [...]}, await alweb.dep(req, nom) ; configuration :
# alweb.load_config(dossier), app.configure(cfg).
# Plusieurs langues : alweb.i18n (catalogues, langue de la requête, pluriels, dates et montants localisés).
# Temps réel et API : alweb.realtime (salons, présence, SSE avec reprise), alweb.ratelimit, alweb.openapi
# (/openapi.json et /docs), alweb.pagination.
# Modules : alweb.app (App, Group), alweb.deps, alweb.config, alweb.middleware (intergiciels async),
# alweb.testing (client de test en mémoire), alweb.errors ; alweb.cli : la commande `alweb` (new, run, test,
# routes, migrate, check, build, deploy). Exige ALEX >= 1.3 avec les gestionnaires async de web.server.

use alweb.app as _app
use alweb.errors as _err
use web.http.response as _response
use web.server.streaming as _streaming
use thread.offload as _offload
use database.async_database as _adb
use alweb.alexdb as _axdb
use alweb.config as _config
use alweb.chain as _chain
use web.server as _server
use web.server.tls_server as _tlss
use alweb.templates as _tpl
use alweb.sessions as _sessions
use alweb.forms as _forms

const VERSION := "0.9.0"

# Nouvelle application. debug : détail des exceptions dans les réponses 500 (jamais en production).
# Intergiciel synchrone (aucune tâche async) : before(req) -> null ou une réponse qui court-circuite la suite ;
# after(req, réponse) -> réponse. À préférer à un intergiciel async quand rien n'est attendu :
#   app.middleware(alweb.hook(null, (req, r) => ajoute_en_tete(r)))
func hook(before=null, after=null):
    return _chain.Hook(before, after)

# Configuration de serveur HTTPS ; HTTP/2 négocié par ALPN si http2 (les clients HTTP/1.1 restent servis).
#   await app.run("0.0.0.0", 8443, alweb.https("cert.pem", "cle.pem"))
# En clair, HTTP/2 « prior knowledge » (h2c) est accepté sur le même port que HTTP/1.1 (config.http2).
func https(cert_file, key_file, http2=true):
    c := _server.config("127.0.0.1", 8443)
    c.tls = _tlss.TlsServerConfig(cert_file, key_file, ["h2", "http/1.1"] if http2 else ["http/1.1"])
    return c

func App(name="alweb", debug=false):
    return _app.App(name, debug)

# Charge la configuration (alweb.config.load) : config/base.json, config/<profil>.json, config/local.json, puis
# variables ALWEB_* ; profil : ALWEB_ENV, sinon "dev".
func load_config(directory="config", profile=null, schema=null):
    return _config.load(directory, profile, "ALWEB", null, schema)

# Interrompt le gestionnaire avec une réponse d'erreur (404, 403...), négociée en JSON ou HTML.
func abort(status, message=null):
    _err.abort(status, message)

# Dépendance nommée pour cette requête (fournisseur déclaré par app.provide), à attendre :
#   u := await alweb.dep(req, "user")
# Résolue au plus une fois par requête (cache), utilisable dans un gestionnaire, un intergiciel ou un fournisseur.
func dep(req, name):
    app := req.state["app"]
    return app.deps.resolve(app, req, name)

# Session du visiteur (alweb.sessions.middleware requis) : get, set, pop, flash, regenerate, invalidate.
func session(req):
    return _sessions.get(req)

# Envoi de courriels de l'application (alweb.mail.Mailer : send, send_template, send_later, outbox en test).
#   await alweb.mailer(req).send_template(u["courriel"], "Bienvenue", "bienvenue", {"nom": u["nom"]})
func mailer(req):
    return req.state["app"].mail()

# Formulaire HTML de la requête (alweb.forms.Form : get, get_list, file, file_list, to_dict).
func form(req):
    return _forms.form(req)

# Valide le formulaire avec un schéma : FormResult (valid, values, data, errors par champ).
func validate_form(req, schema):
    return _forms.validate(req, schema)

# Données validées d'une route déclarée avec body= (ou query= si which == "query").
func data(req, which="body"):
    return req.state[which] if which in req.state else null

# ---------------------------------------------------------------- réponses

# Page HTML rendue avec un gabarit de l'application (app.use_templates) :
#   return alweb.render(req, "notes/liste.html", {"notes": notes})
func render(req, name, context=null, status=200):
    return req.state["app"].render(req, name, context, status)

# Texte HTML sûr (non échappé par les gabarits).
func markup(text):
    return _tpl.markup(text)

func json(value, status=200, headers=null):
    return _response.json(value, status, headers)

func html(body, status=200, headers=null):
    return _response.html(body, status, headers)

func text(body, status=200, headers=null):
    return _response.text(body, status, headers)

func redirect(location, status=302):
    return _response.redirect(location, status)

func no_content():
    return _response.no_content()

func file(path, content_type=null):
    return _response.file(path, content_type)

# ---------------------------------------------------------------- flux

# Gestionnaire de route qui sert des Server-Sent Events : producer(req, flux), avec await flux.send(données,
# événement, id) ; flux.closed quand le client part ; flux.last_event_id pour la reprise.
#   app.get("/evenements", alweb.sse(horloge))
func sse(producer, keepalive=15.0):
    return _streaming.sse(producer, keepalive)

# Gestionnaire de route qui sert un flux brut : producer(req, flux), avec await flux.write(morceau).
func stream(producer, content_type="application/octet-stream"):
    return _streaming.stream(producer, content_type)

# ---------------------------------------------------------------- travail hors de la boucle

# Exécute fn(*args) sur un fil (vrai cœur) et rend une tâche à attendre ; fn est une fonction de premier niveau
# d'un module (de préférence autre que celui qui lance le serveur), arguments et résultat sont copiés.
#   miniature := await alweb.offload(images.reduire, [chemin, 200])
func offload(fn, args=null):
    return _offload.run(fn, args)

# Base de données attendue avec await (database.async_database) : la connexion vit dans un fil dédié.
#   db := alweb.database("sqlite:notes.db")
#   notes := await db.query("SELECT * FROM notes WHERE id > ?", [0])
# alexdb+local:<dossier> : serveur ALEX DB embarqué (alweb.alexdb_local), partagé par les ouvriers.
func database(url="memory:"):
    if _axdb.is_local(url):
        return _adb.open(_axdb.resolve_local(url))
    return _adb.open(url)
