# alweb

Framework web pour [ALEX](https://github.com/ennuum/alex-lang), au-dessus de `web.server` : routes par
décorateurs, gestionnaires `async`, groupes, intergiciels async, validation des entrées par schéma, WebSocket,
Server-Sent Events, plusieurs processus, rechargement à chaud, calcul délégué à des fils, base de données attendue
avec await, dépendances déclarées, configuration par profils, client de test en mémoire, gabarits, sessions,
CSRF, formulaires et téléversements, authentification (mots de passe, rôles, JWT), courriels (SMTP, gabarits,
confirmation d'adresse, mot de passe oublié), tâches de fond persistantes et planifiées, ORM léger et migrations sur
SQLite, PostgreSQL ou ALEX DB, salons temps réel avec présence, description OpenAPI 3.1, limitation de débit partagée
entre processus, versionnage d'API et pagination, HTTP/2, HTTPS sans OpenSSL (TLS 1.3 écrit en ALEX), et
compilation en exécutable natif ; avec la commande
`alweb` (modèle de projet, lancement, tests, routes, migrations, construction, déploiement). Version 0.9.0
(phases 1 à 7 de la feuille de route terminées).

## Démarrage rapide

```sh
ln -s "$PWD/bin/alweb" ~/.local/bin/alweb      # Windows : ajoutez le dossier bin au PATH (bin\alweb.cmd)
alweb new monsite                               # projet prêt à lancer, dépendances installées
cd monsite
alweb run                                       # http://127.0.0.1:8000/ (debug, rechargement à chaud)
alweb run --https                               # https://127.0.0.1:8000/ (certificat de développement, h2)
alweb test
```

Pour un premier essai complet sur votre machine (ALEX 1.4.0, `sh tools/essai_local.sh`, site
vitrine avec thème) : [docs/ESSAI_LOCAL.md](docs/ESSAI_LOCAL.md).
Pour découvrir tout le framework : le [guide d'alweb](docs/GUIDE.md) ; pour apprendre en pratique : le
[tutoriel du blog](docs/TUTORIEL_BLOG.md) ; pour la commande : [docs/COMMANDE.md](docs/COMMANDE.md) ;
pour la production : [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md).

```al
use alweb
use serialization.schema as sch

app := alweb.App("notes")
NOTE := sch.object({"titre": sch.string(1, 120)}, ["titre"])

@app.get("/")
func accueil(req):
    return "<h1>Notes</h1>"

@app.get("/notes/{id:int}", {"name": "note"})
async func voir(req):
    note := await base.trouver(req.params["id"])     # le serveur sert les autres requêtes pendant l'attente
    if note == null:
        alweb.abort(404, "note introuvable")
    return note                                       # dict -> JSON

@app.post("/notes", {"body": NOTE})
async func creer(req):
    return (await base.creer(alweb.data(req)), 201)

await app.run("127.0.0.1", 8000)
```

## Prérequis

ALEX **1.4.0** ou plus récent : le compilateur prêt à l'emploi des
[versions publiées](https://github.com/ennuum/alex-lang/releases), ou construit depuis les sources :

```sh
cd alex-lang && make alex      # environ 8 min
```

Le premier `make alex` part de la graine et demande plus de 6 Go de mémoire : sur une machine plus juste, ajoutez
de l'espace d'échange (`fallocate -l 8G /swapfile && mkswap /swapfile && swapon /swapfile`).

Pour ALEX DB (facultatif) : le projet AlexDB **0.9.0** (clés automatiques, `last_insert_id`, résumé par
instruction des requêtes groupées), voir [docs/ALEXDB.md](docs/ALEXDB.md).

## Utilisation

| Besoin | Écriture |
|---|---|
| Route | `@app.get("/x")`, `app.post("/x", gestionnaire)` ; aussi `put`, `patch`, `delete`, `any`, `route([méthodes], ...)` |
| Options d'une route | dictionnaire : `{"name": "x", "body": SCHEMA, "query": SCHEMA, "middleware": [m]}` (clé inconnue refusée) |
| Paramètres | `req.params["id"]` (types `int`, `float`, `slug`, `uuid`, `path` dans le motif) |
| Données validées | `alweb.data(req)` (corps), `alweb.data(req, "query")` ; refus : 422 JSON avec `details` |
| Réponses | `Response`, `str` (HTML si « < »), `dict` / `list` (JSON), `(corps, statut[, en-têtes])`, `null` (204), `alweb.json/html/text/redirect/file` |
| Erreurs | `alweb.abort(404, "message")` ; `@app.error_handler(404)` |
| Groupes | `api := app.group("/api", [garde])` ; `api.group("/admin")` |
| Intergiciels | `app.middleware([...])` ; `async func m(req, suivant)` avec `await suivant(req)` ; sans attente : `alweb.hook(avant, après)` (aucune tâche créée) |
| Prêts à l'emploi | `alweb.middleware` : `request_id`, `timing`, `logger("text"/"json")`, `security_headers`, `cors` |
| Cycle de vie | `@app.on_startup`, `@app.on_shutdown` (async permis) |
| Statique | `app.static("/static", "public")` |
| WebSocket | `@app.websocket("/chat/{salon}")` puis `async func chat(req, ws)` : `await ws.receive()`, `await ws.send_text(...)` ; options `protocols`, `max_message`, `origins`, `name` |
| SSE, flux | `app.get("/evts", alweb.sse(producteur))` : `await flux.send(données, événement, id)` ; `alweb.stream(producteur, type)` : `await flux.write(morceau)` ; `flux.closed`, `flux.last_event_id` |
| Lancement | `await app.run(hôte, port)` ; `app.server(hôte, port)` rend le `web.server.Server` ; HTTPS et HTTP/2 : `app.run(hôte, 8443, alweb.https("cert.pem", "cle.pem"))` |
| Plusieurs cœurs | `await app.run_workers(hôte, port, n)` (0 : un par cœur ; démarrage et arrêt dans chaque ouvrier) |
| Développement | `await app.run_dev()` : mode debug, relancé à chaque modification d'un `.al` du projet |
| Calcul lourd | `await alweb.offload(module.fonction, [args])` : sur un autre cœur, sans bloquer le serveur |
| Base de données | `db := alweb.database("sqlite:app.db")` (ou `postgres://…`, `alexdb://…`) puis `await db.query(...)`, `insert`, `transaction`... |
| HTTP sortant | `await network.async_client.get(url)` dans un gestionnaire |

ALEX ne transmet pas d'arguments nommés aux appels de méthodes : les options passent par un dictionnaire.

## Dépendances déclarées

```al
app.provide("db", ouvrir_base, "app", fermer_base)    # une fois au démarrage : fn(app) ; fermé à l'arrêt
app.provide("user", utilisateur)                      # une fois par requête, si demandé : fn(req)

async func utilisateur(req):
    db := await alweb.dep(req, "db")                  # un fournisseur peut dépendre d'un autre
    u := await db.query_one("SELECT * FROM comptes WHERE jeton = ?", [req.header("x-jeton")])
    if u == null:
        alweb.abort(401, "jeton invalide")
    return u

@app.get("/moi", {"deps": ["user"]})                 # résolu avant l'appel, après la validation
func moi(req):
    return req.deps["user"]

api := app.group("/api", null, ["user"])             # dépendances communes à un groupe
app.override("user", (req) => {"nom": "Test"})       # en test
```

Cache par requête, fournisseurs async, teardown même en cas d'erreur, cycles détectés, dépendance inconnue
refusée dès la déclaration de la route.

## Applications web (phase 3)

```al
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.auth as auth
use alweb.orm as orm

ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(120), "auteur_id": orm.ref("comptes")})

app.middleware([sessions.middleware(SECRET), csrf.middleware(["/api/"])])   # session signée, puis CSRF
app.use_templates("templates")                                              # {% extends %}, {% block %}...
app.provide("user", auth.current_user(charger))                             # charger(req, id) -> compte

@app.post("/ecrire", {"middleware": [auth.login_required()], "deps": ["db", "user"]})
async func ecrire(req):
    f := alweb.validate_form(req, ARTICLE)                                  # erreurs par champ
    if not f.valid:
        return alweb.render(req, "article_form.html", {"form": f}, 422)
    id := await ARTICLES.insert(req.deps["db"], {"titre": f.data["titre"], "auteur_id": req.deps["user"]["id"]})
    alweb.session(req).flash("Article publié.", "succes")
    return alweb.redirect(app.url_for("article", {"id": id}), 303)
```

| Module | Contenu |
|---|---|
| `alweb.templates` | syntaxe à la Jinja : `{{ x | filtre }}`, `if/elif/else`, `for/else` (avec `loop`), `set`, `extends`/`block`/`super()`, `include`, `macro`, `import … as`, `raw`, `{%- -%}` ; échappement automatique, `Markup` ; erreurs avec nom et ligne ; gabarits relus en debug |
| `alweb.sessions` | `middleware(secret, store)` : cookie signé (défaut), `MemoryStore`, `DatabaseStore(db)` ; `get/set/pop`, `flash`, `regenerate`, `invalidate` |
| `alweb.csrf` | jeton par session, champ `csrf_token` ou en-tête `X-CSRF-Token` ; exemptions par préfixe et pour les appels `Authorization` sans cookie ; `{{ csrf_field() }}` |
| `alweb.forms` | `alweb.form(req)` (urlencoded, multipart), `validate_form(req, schéma)` (messages rédigés pour le visiteur, dans sa langue ; `f.codes`, `f.details`), `check_upload(fichier, octets, types)` (type réel lu dans le contenu), `unique_name` |
| `alweb.auth` | `hash_password`/`verify_password` (PBKDF2 hors de la boucle), `login` (nouvelle session et nouveau jeton CSRF), `logout`, `login_required`, `roles_required`, `current_user`, `next_url` (sûr), `jwt_encode`/`jwt_decode` (HS256), `bearer(secret)` ; liens par courriel : `reset_token` / `check_reset_token` (usage unique), `confirm_token` / `read_confirm_token`, `signed_token` / `read_token` |
| `alweb.jobs` | `Queue(app, DatabaseStore(() => app.value("db")))` : tâches en base (SQLite, PostgreSQL, ALEX DB) partagées entre processus, `@q.task(nom)`, `enqueue(nom, données, {delay, at, attempts, key})`, nouveaux essais espacés puis abandon, délai d'exécution, reprise des tâches interrompues ; `@q.every(nom, "30 3 * * *")` ou `every(nom, 300)` : une exécution par créneau tous processus confondus ; `send_later` des courriels y passe ; `alweb jobs` (état, `--retry`) et page « Tâches » de l'administration ; tests : `at.run_jobs(app)` ([guide](docs/TACHES.md)) |
| `alweb.i18n` | `i18n.I18n(app, "locales", {"default": "fr"})` : catalogues `locales/<langue>.json` (clés = texte de la langue par défaut, repli fr-CA → fr → défaut), langue de chaque requête (préfixe `/en/…`, `?lang=`, compte, session, cookie, `Accept-Language`), pluriels CLDR, dates, nombres, montants (XOF, EUR…), temps relatif ; gabarits : `_()`, `_n()`, `\| date`, `\| currency`, `locales` (sélecteur) ; courriels dans la langue du destinataire ; erreurs de formulaire, pages d'erreur (fr, en, es, de, it, pt, nl) et administration (fr, en) traduites par alweb ; `alweb i18n` (traductions manquantes) ([guide](docs/I18N.md)) |
| `alweb.storage` | `storage.setup(app)` (clé `storage.url`) : disque (`file:media`), mémoire (tests), compatible S3 (`s3://CLÉ:SECRET@hôte/seau?region=…` : S3, MinIO, Scaleway, B2, R2 ; signature AWS V4 en ALEX) ; `put`, `get`, `head`, `list`, `delete`, URL signées qui expirent (`st.url(clé, secondes, nom)` : présignée S3, ou route de l'application), `save_upload` (type réel vérifié) ([guide](docs/FICHIERS.md)) |
| `alweb.images` | vignettes et tailles d'une image (`fit`, `cover` ; JPEG, PNG, GIF, WebP en entrée ; orientation Exif) par un programme natif écrit en ALEX dans un processus à part ; `images.store(st, fichier, {"sizes": {...}})` enregistre l'original et ses tailles |
| `alweb.themes` | thèmes installables (ALWEB Templates) : `alweb-theme.json` (manifeste, versions et contraintes), paramètres typés (`config/theme.json`, choix du projet dans `config/theme.<slug>.json`, variables CSS), validation de sécurité (pas de code ni d'exécutable, liens symboliques, SVG piégés, tailles, gabarits et références), archives `.alwt` reproductibles, installation hors ligne dans `themes/` avec `alweb.lock`, activation, retour arrière ; `themes.setup(app)` : pages du thème, `templates/` de l'application prioritaire, `asset()` versionné ; `alweb theme` (create, validate, package, preview, install…) ; page « Apparence » de l'administration : réglages avec aperçu en direct, historique, logo envoyé ; client de marketplace (`alweb.themes.client`, [protocole ouvert](docs/MARKETPLACE_PROTOCOLE.md) que tout serveur peut suivre) : publication signée ECDSA P-256, recherche, installation vérifiée avec clé de l'éditeur épinglée, mises à jour, retrait de version, avis ([guide](docs/THEMES.md)) |
| `alweb.mail` | `alweb.mailer(req)` / `app.mail()` réglé par la clé `mail` : SMTP (`smtp://`, `smtps://`, STARTTLS, jamais d'authentification en clair, envoi sur un fil), `console` (défaut en debug), `memory` (tests : `at.outbox(app)`, `at.links(texte)`), `file:dossier` ; `send`, `send_template` (`emails/<nom>.txt` / `.html`), `send_later`, pièces jointes, Cc / Cci ; `absolute_url(req, chemin)` par `site_url` ([guide](docs/COURRIEL.md)) |
| `alweb.orm` | `table`, colonnes `pk/integer/real/text/boolean/timestamp/json/ref`, `where/order_by/limit/offset`, `with_one/with_many` (sans N+1), `paginate`, `update`, `delete`, validation, `migration`, `index`, `add_column` (colonne ajoutée à une table existante) et `migrate` (une transaction par migration) ; dialectes SQLite, PostgreSQL et ALEX DB |

Dans les gabarits rendus par `alweb.render` : `request`, `config`, `session`, `flashes()`, `csrf_token()`,
`csrf_field()`, `url_for(nom, valeurs)`, `app_name`, et ce que rendent les `@app.context_processor`.

## Temps réel et API (phase 4)

```al
use alweb.realtime as rt
use alweb.ratelimit as rl
use alweb.openapi as oa
use alweb.pagination as pg

hub := rt.Hub()                                          # un processus ; plusieurs : rt.Hub(rt.DatabaseBroker(db))
hub.attach(app)

@app.websocket("/ws/{salon}")
async func salon(req, ws):
    await hub.room(req.params["salon"]).serve(ws, {"id": pseudo})   # présence, diffusion, départ
app.get("/salons/{salon}/evenements", hub.sse((req) => req.params["salon"]))   # SSE, reprise Last-Event-ID

app.middleware(rl.limit(600, 60))                        # par IP ; rl.DatabaseStore(db) : commun aux processus
v1 := app.group("/api/v1", null, null, {"tags": ["v1"], "deprecated": 1767225600, "sunset": 1782864000})
v1.get("/messages", liste, {"summary": "Messages", "response": PAGE, "cors": ["https://lecteur.example"]})
oa.setup(app, title="Messagerie", version="1.0.0")      # GET /openapi.json et GET /docs
```

| Module | Contenu |
|---|---|
| `alweb.realtime` | `Hub(courtier)`, `hub.room(nom)` : `join`, `leave`, `broadcast`, `members`, `count`, `serve(ws, membre, on_message)` ; `hub.publish`, `hub.history`, `hub.sse(salon)` ; `MemoryBroker(historique)`, `DatabaseBroker(db)` (SQLite sur fichier, PostgreSQL ou ALEX DB : événements, présence et historique communs à tous les processus, livrés dans le même ordre partout) |
| `alweb.ratelimit` | `limit(n, période, clé, stockage, scope, fail_open, exempt)` : fenêtre glissante, en-têtes `RateLimit-*`, 429 avec `Retry-After` ; clés `by_ip()`, `by_header(nom)` ; `MemoryStore`, `DatabaseStore(db)` |
| `alweb.openapi` | `spec(app, …)` (dict OpenAPI 3.1, filtrable par préfixe de version), `setup(app, …)` (`/openapi.json` et page `/docs` autonome avec « Essayer »), `component(nom, schéma)` (`$ref`), `json_schema(schéma)` |
| `alweb.pagination` | `params(req)`, `page(req, résultat)` (`Link`, `X-Total-Count`), `cursor(req)`, `cursor_page(req, items, suivant)`, `encode_cursor`/`decode_cursor` |

Options de route ajoutées : `summary`, `description`, `tags`, `response`, `status`, `responses`, `security`,
`operation_id`, `hidden` (documentation) ; `deprecated` et `sunset` (en-têtes `Deprecation` et `Sunset`) ;
`cors` (origines permises et pré-vérification OPTIONS pour ce seul motif). `app.group(préfixe, intergiciels,
dépendances, options)` applique `tags`, `deprecated`, `sunset`, `security` et `cors` à toutes ses routes.
`app.value(nom)` rend une dépendance de portée app déjà créée.

## Performance, HTTP/2 et natif (phase 5)

**HTTP/2.** Sans réglage, un client qui commence par la préface HTTP/2 (`curl --http2-prior-knowledge`, mandataire
inverse en h2c) est servi en HTTP/2 sur le port HTTP/1.1. Sur TLS, `alweb.https(cert, clé)` propose `h2` par ALPN
(navigateurs). Même application, mêmes intergiciels : `req.version` vaut `"HTTP/2"`. Flux multiplexés,
gestionnaires async en parallèle, fichiers, SSE ; pas de push serveur ni de WebSocket sur HTTP/2 (les navigateurs
ouvrent alors une connexion HTTP/1.1). Conformité : h2spec 146/146 sur TLS.

**Fichiers statiques.** Un gros fichier ne bloque plus la boucle : il part par morceaux quand le client lit. Posez
`site.css.br` ou `site.css.gz` à côté de `site.css` : ils sont servis aux clients qui les acceptent.

**Gabarits.** Compilés en fermetures au chargement : environ 40 % plus rapides (50 µs par ligne de tableau en VM,
30 µs en natif, contre 85 µs).

**Exécutable natif.**

```sh
alexc build examples/chat.al --native -o messagerie      # un exécutable autonome (environ 15 Mo)
ALWEB_ENV=prod ALWEB_DATABASE__URL=postgres://… ./messagerie
```

Le natif ne charge pas de bibliothèque C : pas de SQLite (FFI) ni d'OpenSSL. ALEX DB et PostgreSQL fonctionnent
(pilotes écrits en ALEX), et HTTPS aussi : TLS 1.3 écrit en ALEX (voir « HTTPS natif » plus bas).
Les mots de passe (PBKDF2) sont calculés par le runtime natif. Débit mesuré : web.server natif environ 2 fois la référence de la phase 0, alweb avec
trois intergiciels 2 300 à 2 400 req/s contre 1 680 en VM et 878 en phase 1 (`bench/RESULTS.md`).

## Outillage et documentation (phase 6)

| Élément | Contenu |
|---|---|
| Paquet | `alweb/` est le paquet installable (son propre `alex.toml`) : `alweb = { path = "…/alweb/alweb" }` ou `alweb = "^0.9.0"` après `alexc pkg publish` ; `alexc pkg install` le recopie dans `alex_packages/alweb/` |
| Commande | `bin/alweb`, `bin/alweb.cmd` : `new`, `run`, `test`, `routes`, `migrate`, `i18n`, `jobs`, `theme`, `check`, `build`, `deploy`, `secret` ([référence](docs/COMMANDE.md)) |
| Modèle de projet | `alweb/modele/` : `main.al` par profil, `application.al` (`creer(cfg, dossier)`), `modeles.al`, `config/` dev / test / prod avec clés tirées au hasard, gabarits, tests |
| Tutoriel | [docs/TUTORIEL_BLOG.md](docs/TUTORIEL_BLOG.md), résultat complet et testé dans `docs/tutoriel/blog/` |
| Déploiement | [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md) ; `alweb deploy systemd caddy nginx docker` génère service systemd durci, Caddyfile, configuration nginx, Dockerfile et `compose.yaml` |
| Mandataires | `server.trusted_proxies` dans la configuration : adresse réelle du client derrière Caddy / nginx (journaux, limites de débit) |

```sh
alweb routes                     # MÉTHODES  MOTIF  NOM
alweb migrate --status           # [x] 1  messages
alweb build                      # dist/<nom> : exécutable autonome (VM embarquée, SQLite)
alweb deploy systemd caddy --domaine monsite.example.org
```

## ALEX DB (phase 7)

[ALEX DB](docs/ALEXDB.md), le SGBD écrit en ALEX, est la troisième base d'alweb, à côté de SQLite et PostgreSQL :

```al
use alweb.alexdb as axdb

url := "alexdb://admin:mdp@127.0.0.1:5442/blog"
await axdb.ensure_database(url)                    # CREATE DATABASE IF NOT EXISTS (super-utilisateur)
db := alweb.database(url)
await orm.migrate(db, MIGRATIONS)                  # dialecte « alexdb » : INT PRIMARY KEY attribuée par le serveur
id := await ARTICLES.insert(db, {"titre": "Été"})  # identifiant rendu, jamais réattribué
await db.transaction([...])                        # une seule requête BEGIN … COMMIT : atomique, sans verrou croisé
```

| Élément | Contenu |
|---|---|
| Pilote | `alexdb://utilisateur:mdp@hôte:5442/base?connect_timeout=10&lock_timeout=5` : paramètres `?` / `:nom`, identifiants, transactions d'un bloc, `LockError` réessayé hors transaction, erreurs `IntegrityError` / `QueryError` / `ConnectionError` ; écrit en ALEX, donc disponible dans l'exécutable natif (sans SQLite) |
| ORM | `orm.dialect(db)` vaut `"alexdb"` : types `INT` / `FLOAT` / `VARCHAR(n)` / `TEXT`, booléens en 0 / 1 ; `orm.index(nom, table, colonnes)` (sur ALEX DB, la première colonne) ; migrations dans une transaction (DDL transactionnel) |
| Magasins | `sessions.DatabaseStore`, `ratelimit.DatabaseStore` (sans clé composite ni `ON CONFLICT` : transaction d'un bloc), `realtime.DatabaseBroker` : partagés entre ouvriers par le serveur |
| `alweb.alexdb` | `ensure_database`, `with_database`, `parse`, `redact`, `check`, `Server(home)` : serveur jetable pour les tests et les démonstrations |
| Commande | `alweb new monsite --base alexdb` (ou `--base alexdb://…`) : `config/base.json` pointe sur ALEX DB, base créée au démarrage |
| Tests | `ALWEB_TEST_ALEXDB=alexdb://…` ou `ALWEB_ALEXDB_HOME=…/AlexDB` : `tests/test_alexdb.al` ; `tools/test_alexdb.sh` : toute la suite sur un serveur jetable (ORM, limites, salons, blog, messagerie, ouvriers) ; `at.alexdb_database(nom)` dans les tests d'une application |

## HTTPS natif (TLS 1.3 en ALEX)

Sans OpenSSL (exécutable natif), `web.server` termine TLS lui-même avec `network.tls13`, une implémentation de
TLS 1.3 écrite en ALEX ; le calcul lourd (X25519, P-256 / P-384, RSA, AES-GCM, SHA-256) passe par le runtime typé
(`crypto.accel`), 30 à 70 fois plus vite que le même calcul en Alex dynamique. HTTPS se configure sans code :

```json
{"server": {"tls": {"cert": "/etc/letsencrypt/live/site/fullchain.pem", "key": "/etc/letsencrypt/live/site/privkey.pem"}}}
```

`app.run` / `app.run_workers` servent alors HTTPS, HTTP/2 par ALPN (`"http2": false` pour l'interdire) ; un
certificat renouvelé est relu à la connexion suivante. `alweb.https(cert, clé)` reste disponible dans le code.

Ou bien, sans certbot ni mandataire, alweb obtient et renouvelle lui-même un certificat Let's Encrypt (ACME,
défi `http-01` sur le port 80, qui redirige aussi vers HTTPS) — voir [DEPLOIEMENT](docs/DEPLOIEMENT.md) :

```json
{"server": {"host": "0.0.0.0", "port": 443,
            "tls": {"acme": {"domains": ["site.example.org"], "email": "admin@example.org", "agree_tos": true}}}}
```

| Élément | Contenu |
|---|---|
| Protocole | TLS 1.3 (RFC 8446) : AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305 ; x25519, P-256, P-384 (HelloRetryRequest) ; ALPN, SNI, KeyUpdate ; TLS 1.2 refusé (`protocol_version`) |
| Certificats | chaîne PEM ; clés PKCS#8, SEC1, PKCS#1 ; EC P-256 / P-384 ou RSA ≥ 2048 bits ; clé contrôlée contre le certificat au démarrage |
| Reprise | avec le TLS ALEX comme avec OpenSSL ; tickets sans état (clé tirée de la clé privée, communs aux ouvriers ; `ALEX_TLS_TICKET_KEY`) : un client qui revient évite certificat et signature (RSA-2048 : 39 → 263 connexions/s) ; 0-RTT refusé |
| Client | `network.tls.connect` sans OpenSSL (`session=` pour reprendre) : chaîne vérifiée jusqu'à `ca_file` ou au magasin du système (noms, jokers, dates, RSA-PSS), pas de révocation |
| Choix | OpenSSL s'il est là, sinon ALEX ; `ALEX_TLS=alex` / `openssl` pour forcer ; `tls.backend()` |
| Boucle | la poignée de main n'arrête pas le serveur, avec OpenSSL comme avec le TLS ALEX : la boucle lit et écrit sans attendre (un client lent ou muet ne gêne personne) ; avec le TLS ALEX, le calcul (≈ 4 ms en P-256, 40 ms en RSA-2048) part sur un fil de `thread.offload` ; `server.tls.offload = false` le garde dans la boucle |
| Certificat | fichiers PEM (`cert`, `key`) ou automatique (`acme` : Let's Encrypt, renouvelé en tâche de fond, servi sans redémarrage) |
| Coût | 1 856 req/s en keep-alive sur un cœur ; poignées de main P-256 : 235 par seconde sur 2 cœurs (`bench/RESULTS.md`) |

## Administration générée

[alweb.admin](docs/ADMIN.md) : tableau de bord, listes (recherche, filtres, tri, pages), fiches de création et de
modification, suppression confirmée et export CSV, produits depuis les tables de l'ORM.

```al
use alweb.admin as adm

admin := adm.Admin(app, {"roles": ["admin"], "login_url": "/connexion", "on_change": audit})
admin.register(UTILISATEURS, {"exclude": ["mdp"], "display": "nom"})
admin.register(ARTICLES, {"search": ["titre", "texte"], "filters": ["auteur_id"], "display": "titre"})
```

Rôles exigés (aussi par table), CSRF imposé sur chaque POST, `no-store`, aucun style en ligne (compatible avec la
CSP de `security_headers`), colonnes exclues jamais montrées, cellules CSV neutralisées contre les formules.
Champs selon le type de colonne, clés étrangères en listes déroulantes, erreurs de l'ORM et d'unicité au champ.
Recherche de l'ORM : `ARTICLES.search(["titre", "texte"], "été")`. Le blog d'exemple a son `/admin`.
Pages ajoutées : « Tâches » (`alweb.jobs`), « Apparence » (thème actif, aperçu en direct) et toute
**extension** (option `extensions`, [exemple](docs/ADMIN.md#extensions)).

## Configuration

```al
cfg := alweb.load_config("config")       # base.json < <profil>.json < local.json < variables ALWEB_*
app.configure(cfg)                       # app.config ; « debug » pilote le mode debug, server.trusted_proxies
                                         # les mandataires dont X-Forwarded-For est cru, server.tls HTTPS
url := cfg.require("database.url")       # ConfigError si absent
```

Profil : `ALWEB_ENV` (`dev` par défaut, `test`, `prod`…). Variables : `ALWEB_DATABASE__URL=…` remplace
`database.url` (`__` sépare les niveaux), converties selon le type existant (bool, entier, nombre, JSON).
Validation par schéma : `alweb.load_config("config", null, SCHEMA)`. `cfg.safe_dict()` masque les secrets.

## Tests

```al
use alweb.testing as at
from testing use assert_eq

async func test_voir():
    c := at.Client(app)
    r := await c.get("/notes/1")
    assert_eq(r.status, 200)
    r = await c.post("/notes", {"json": {"titre": "Été"}})
    assert_eq(r.status, 201)
```

`alexc test tests docs/tutoriel/blog/tests` : 213 tests (`tests/` et le blog du tutoriel), dont six de bout en bout sur un vrai port, deux sur
plusieurs processus, et un parcours complet de la commande `alweb` sur un projet généré (`build/test_cli/`).
`ALEX_TLS=alex alexc test …` : la même suite avec le TLS écrit en ALEX au lieu d'OpenSSL.
`alexc run tools/test_native.al` : la même suite compilée en natif (avec `ALWEB_TEST_ALEXDB` ou `ALWEB_TEST_POSTGRES`,
puisque le natif n'a pas SQLite) ; HTTPS et h2 sur TLS y sont testés (serveur et client TLS 1.3 en ALEX).
Les fichiers servis (`alweb.file`, `app.static`) arrivent dans `r.body` comme les autres réponses.
`ALWEB_TEST_POSTGRES=postgres://…` : les tests de l'ORM, des salons, des limites, du blog et de la messagerie
tournent aussi sur PostgreSQL ; `ALWEB_TEST_ALEXDB=alexdb://…` (ou `ALWEB_ALEXDB_HOME=…/AlexDB tools/test_alexdb.sh`,
qui lance un serveur jetable) : sur ALEX DB.

## Exemple

`alexc run examples/notes.al` : API CRUD « notes » et une page HTML (`examples/notes_app.al`), configurées par
`examples/config`. Profil `dev` (défaut) : debug et rechargement à chaud ; `ALWEB_ENV=prod` : un processus par
cœur, journal JSON ; stockage SQLite (`notes.db`) fourni comme dépendance.

`alexc run examples/blog.al` : blog multi-utilisateur (`examples/blog_app.al`, gabarits et configuration dans
`examples/blog/`) : inscription et connexion, articles avec illustration, commentaires, droits (le premier
compte est administrateur, les autres ne modifient que leurs articles), pagination, API JSON avec jeton Bearer
(`POST /api/jeton`, `POST /api/articles`). SQLite par défaut ; PostgreSQL :
`ALWEB_DATABASE__URL=postgres://utilisateur:mdp@hôte/blog alexc run examples/blog.al`.

`alexc run examples/chat.al` : messagerie temps réel (`examples/chat_app.al`, page et configuration dans
`examples/chat/`) : comptes et jetons JWT, salons WebSocket avec présence et indicateur de frappe, historique
paginé par curseur, flux SSE en lecture seule, API `/api/v1` documentée sur `/docs`, limites de débit. Avec
`ALWEB_ENV=prod`, un processus par cœur : salons et limites passent par la base (SQLite, PostgreSQL ou ALEX DB).

## Mesures

Voir `bench/RESULTS.md` ; générateur de charge : `go run bench/load.go -url ... -c 8 -d 8s`.

## Licence

Copyright 2026 Ennuum Group. alweb est distribué sous la [licence Apache, version 2.0](LICENSE) (voir aussi
[NOTICE](NOTICE)) : vous pouvez l'utiliser, le modifier et le redistribuer, y compris dans des applications
propriétaires, en gardant les mentions de licence. Le paquet installable (`alweb/`) contient les mêmes
fichiers. Les thèmes créés avec `alweb theme create` reçoivent la licence MIT au nom de leur auteur (fichier
`LICENSE` du modèle), qu'il peut changer.
