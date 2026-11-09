# Guide du framework alweb

Ce guide présente alweb de bout en bout, dans l'ordre où on en a besoin : installer, créer un projet, écrire des
routes, valider des données, brancher une base, rendre des pages, gérer des comptes, tester, puis mettre en
production. Chaque partie donne l'essentiel et renvoie au guide détaillé du sujet.

Pour qui : vous connaissez les bases d'ALEX (fonctions, dictionnaires, `async` / `await`) et un peu de HTML.
Pour pratiquer en construisant une vraie application, suivez ensuite le [tutoriel du blog](TUTORIEL_BLOG.md).

| Partie | Sujet |
|---|---|
| [1](#1-alweb-en-bref) | alweb en bref |
| [2](#2-installer) | Installer |
| [3](#3-un-premier-projet) | Un premier projet |
| [4](#4-routes-requêtes-réponses) | Routes, requêtes, réponses |
| [5](#5-valider-les-entrées) | Valider les entrées |
| [6](#6-erreurs) | Erreurs |
| [7](#7-groupes-et-intergiciels) | Groupes et intergiciels |
| [8](#8-dépendances-déclarées) | Dépendances déclarées |
| [9](#9-configuration-et-profils) | Configuration et profils |
| [10](#10-base-de-données-orm-et-migrations) | Base de données, ORM et migrations |
| [11](#11-gabarits) | Gabarits |
| [12](#12-thèmes--créer-installer-activer) | Thèmes : créer, installer, activer |
| [13](#13-formulaires-sessions-csrf-et-comptes) | Formulaires, sessions, CSRF et comptes |
| [14](#14-api-json) | API JSON |
| [15](#15-temps-réel) | Temps réel |
| [16](#16-tests) | Tests |
| [17](#17-les-services-intégrés) | Les services intégrés |
| [18](#18-performance-et-production) | Performance et production |
| [19](#19-aide-mémoire) | Aide-mémoire |
| [20](#20-pièges-fréquents) | Pièges fréquents |

---

## 1. alweb en bref

alweb est un framework web écrit en ALEX, au-dessus du serveur `web.server` de la bibliothèque standard. Il
apporte ce qu'on attend d'un framework complet :

* **le cœur** : routes par décorateurs, gestionnaires `async`, groupes, intergiciels, validation par schéma,
  dépendances déclarées, configuration par profils ;
* **les applications web** : gabarits à la Jinja, sessions, CSRF, formulaires, téléversements, authentification
  (mots de passe, rôles, JWT), ORM et migrations sur SQLite, PostgreSQL ou ALEX DB ;
* **le temps réel et les API** : WebSocket, Server-Sent Events, salons avec présence, OpenAPI 3.1, limitation de
  débit, pagination, versionnage ;
* **les services** : courriels, tâches de fond, stockage de fichiers et vignettes, plusieurs langues,
  administration générée, thèmes installables ;
* **la production** : plusieurs processus, HTTP/2, HTTPS sans OpenSSL (TLS 1.3 écrit en ALEX), certificats Let's
  Encrypt automatiques, exécutable natif, fichiers de déploiement générés.

Et une commande, `alweb`, qui crée, lance, teste, inspecte, migre, construit et déploie les projets.

Une application tient en quelques lignes :

```al
use alweb

app := alweb.App("bonjour")

@app.get("/")
func accueil(req):
    return "<h1>Bonjour</h1>"                 # une chaîne qui contient « < » part en HTML

@app.get("/salut/{nom}")
func salut(req):
    return {"message": "Salut " + req.params["nom"]}    # un dictionnaire part en JSON

await app.run("127.0.0.1", 8000)
```

## 2. Installer

**ALEX.** alweb 0.9.0 demande ALEX 1.4.0 ou plus récent. Installez le compilateur prêt à l'emploi des versions
publiées, ou construisez-le depuis les sources :

```sh
cd alex-lang && make alex      # environ 8 min
```

Le premier `make alex` part de la graine et demande plus de 6 Go de mémoire ; sur une machine plus juste, ajoutez
de l'espace d'échange.

**La commande `alweb`.**

| Système | Installation |
|---|---|
| Linux, macOS, WSL | `ln -s "$PWD/bin/alweb" ~/.local/bin/alweb` (depuis le dossier d'alweb) |
| Windows | ajoutez le dossier `bin` d'alweb au PATH (`bin\alweb.cmd`) |

Le lanceur cherche ALEX dans la variable `ALEX`, sinon `alex`, sinon `alexc` dans le PATH. Vérifiez avec
`alweb version`.

Pour un essai complet guidé sur votre machine (ALEX corrigé, site vitrine avec thème, page « Apparence ») :
[ESSAI_LOCAL.md](ESSAI_LOCAL.md).

## 3. Un premier projet

```sh
alweb new monsite                 # projet prêt à lancer, dépendances installées
cd monsite
alweb run                         # http://127.0.0.1:8000/  (debug, rechargement à chaud)
```

Le projet généré est un livre d'or qui fonctionne déjà : une page avec un formulaire, une petite API JSON, une
route de supervision et ses tests. Options utiles de `alweb new` : `--description "…"`, `--base alexdb`
(ALEX DB au lieu de SQLite), `--registre` (alweb depuis le registre de paquets plutôt qu'un dossier local).

| Fichier | Rôle |
|---|---|
| `main.al` | lance le serveur selon le profil `ALWEB_ENV` (`dev`, `test`, `prod`) |
| `application.al` | `creer(cfg, dossier)` : construit l'application **sans la lancer** |
| `modeles.al` | tables, migrations, schémas de validation |
| `config/` | `base.json` < `<profil>.json` < `local.json` (non versionné) < variables `ALWEB_*` |
| `templates/`, `static/` | gabarits et fichiers statiques |
| `tests/` | tests avec le client en mémoire |

**La règle d'or : construire sans lancer.** `application.creer` rend une `App` prête mais ne démarre aucun
serveur. `main.al` la lance ; les tests, `alweb routes` et `alweb migrate` l'importent. Gardez cette séparation :
c'est elle qui rend l'application testable et inspectable.

`main.al` choisit la façon de lancer selon le profil :

```al
cfg := alweb.load_config(os.join(ici, "config"))
app := application.creer(cfg, ici)
if cfg.is_dev():
    await app.run_dev(host, port)                                   # debug, relancé à chaque .al modifié
elif cfg.is_prod():
    await app.run_workers(host, port, cfg.get("server.workers", 0)) # un processus par cœur
else:
    await app.run(host, port)
```

Les clés secrètes de `config/dev.json` et `config/test.json` sont tirées au hasard à la création ; celle de
production vient de l'environnement (`ALWEB_SECRET_KEY`, obtenue par `alweb secret`).

## 4. Routes, requêtes, réponses

### Déclarer une route

```al
@app.get("/articles", {"name": "articles"})
async func liste(req):
    ...

app.post("/articles", creer_article)          # sans décorateur
```

Méthodes : `get`, `post`, `put`, `patch`, `delete`, `any`, et `route([méthodes], motif, gestionnaire)`. Le
deuxième argument est un **dictionnaire d'options** : `name`, `body`, `query`, `middleware`, `deps`, et les
options de documentation et d'API (parties 14 et 15). Une clé inconnue est refusée dès la déclaration.

> ALEX ne transmet pas d'arguments nommés aux appels de **méthodes** : les options passent toujours par un
> dictionnaire (`{"name": "x"}`), jamais par `name="x"`.

### Paramètres de chemin

```al
@app.get("/articles/{id:int}", {"name": "article"})
async func voir(req):
    id := req.params["id"]                    # déjà un entier
```

Types : `int`, `float`, `slug`, `uuid`, `path` (le reste du chemin). Un paramètre qui ne convient pas
(`/articles/abc`) répond 404 sans appeler la fonction.

### Nommer les routes

Une route nommée se retrouve par `app.url_for("article", {"id": 3})`, dans le code comme dans les gabarits : une
URL n'est écrite qu'une fois. `alweb routes` liste méthodes, motifs et noms.

### Ce que rend un gestionnaire

| Valeur rendue | Réponse |
|---|---|
| `str` | HTML s'il contient « < », texte sinon |
| `dict`, `list` | JSON |
| `(corps, statut)` ou `(corps, statut, en-têtes)` | le corps avec ce statut |
| `null` | 204 sans contenu |
| `alweb.json(...)`, `alweb.html(...)`, `alweb.text(...)`, `alweb.redirect(url, 303)`, `alweb.file(...)` | réponse explicite |
| un objet `Response` | tel quel |

Une réponse explicite permet de régler les en-têtes :

```al
r := alweb.json({"id": id}, 201)
r.headers.set("Location", app.url_for("article", {"id": id}))
return r
```

### Synchrone ou `async`

Un gestionnaire peut être une fonction ordinaire ou `async`. Dès qu'il attend quelque chose (base de données,
HTTP sortant, calcul délégué), écrivez-le `async` : pendant `await`, le serveur sert les autres requêtes.

```al
@app.get("/notes/{id:int}")
async func voir(req):
    note := await base.trouver(req.params["id"])
    if note == null:
        alweb.abort(404, "note introuvable")
    return note
```

### Fichiers statiques

```al
app.static("/static", os.join(dossier, "static"))
```

Les gros fichiers partent par morceaux sans bloquer la boucle ; un `site.css.br` ou `site.css.gz` posé à côté de
`site.css` est servi aux clients qui l'acceptent.

## 5. Valider les entrées

Les schémas viennent de `serialization.schema` :

```al
use serialization.schema as sch

ARTICLE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(1, 50000)}, ["titre", "texte"])

@app.post("/api/articles", {"body": ARTICLE})
async func publier(req):
    d := alweb.data(req)                      # données validées et converties
    ...
```

* `{"body": SCHÉMA}` valide le corps JSON **avant** l'appel ; `{"query": SCHÉMA}` les paramètres d'URL, lus par
  `alweb.data(req, "query")`.
* Une entrée refusée reçoit un **422** JSON avec le détail par champ (`details`), sans que votre fonction soit
  appelée.
* Pour les formulaires HTML, utilisez `alweb.validate_form` (partie 13), qui rend des messages lisibles par un
  visiteur et permet de réafficher la saisie.

## 6. Erreurs

```al
alweb.abort(404, "article introuvable")       # interrompt le gestionnaire avec ce statut

@app.error_handler(404)
func introuvable(req, statut, message):
    return alweb.render(req, "404.html", {"message": message}, 404)
```

Le gestionnaire reçoit la requête, le statut et le message passé à `abort`. Le mode debug (clé `debug` de la
configuration, actif en profil `dev`) est réservé au développement : ne l'activez jamais en production. Avec
`alweb.i18n`, les pages d'erreur d'alweb sont traduites dans la langue du visiteur.

## 7. Groupes et intergiciels

### Groupes

Un groupe partage un préfixe, des intergiciels, des dépendances et des options :

```al
api := app.group("/api", [rl.limit(120, 60)], ["db"])     # préfixe, intergiciels, dépendances
admin := api.group("/admin")                               # les groupes s'emboîtent

@api.get("/messages")
async func messages(req):
    ...
```

`app.group(préfixe, intergiciels, dépendances, options)` : les options `tags`, `deprecated`, `sunset`,
`security` et `cors` s'appliquent à toutes les routes du groupe.

### Intergiciels

Un intergiciel reçoit la requête et la suite de la chaîne :

```al
async func marque(req, suivant):
    rep := await suivant(req)                              # la suite de la chaîne, puis la route
    rep.headers.set("X-Application", "monsite")
    return rep

app.middleware([marque])                                   # pour toute l'application
@app.get("/x", {"middleware": [auth.login_required()]})    # pour une route
```

Quand il n'y a rien à attendre, `alweb.hook(avant, après)` fait le même travail sans créer de tâche.

Prêts à l'emploi dans `alweb.middleware` : `request_id`, `timing`, `logger("text")` / `logger("json")`,
`security_headers` (dont une CSP stricte), `cors`.

**L'ordre compte.** Dans le modèle de projet, l'identifiant de requête et les en-têtes de sécurité viennent
d'abord, puis la **session**, puis le **CSRF** (qui a besoin de la session) :

```al
app.middleware([mw.request_id(), mw.security_headers(), sessions.middleware(cfg.require("secret_key")), csrf.middleware(["/api/"])])
```

### Cycle de vie

```al
@app.on_startup
async func demarrer():
    ...

@app.on_shutdown
func arreter():
    ...
```

Les fonctions de démarrage et d'arrêt ne reçoivent pas d'argument ; `async` est permis.

Avec plusieurs processus, démarrage et arrêt ont lieu dans chaque ouvrier.

## 8. Dépendances déclarées

Plutôt que des variables globales, alweb fournit aux routes les ressources qu'elles demandent :

```al
app.provide("db", ouvrir_base, "app", fermer_base)   # portée app : une fois par processus, fermée à l'arrêt
app.provide("user", utilisateur)                     # portée requête : une fois par requête, si demandée

async func utilisateur(req):
    db := await alweb.dep(req, "db")                 # un fournisseur peut dépendre d'un autre
    u := await db.query_one("SELECT * FROM comptes WHERE jeton = ?", [req.header("x-jeton")])
    if u == null:
        alweb.abort(401, "jeton invalide")
    return u

@app.get("/moi", {"deps": ["user"]})                # résolue avant l'appel, après la validation
func moi(req):
    return req.deps["user"]
```

* Cache par requête, fournisseurs `async`, fermeture même en cas d'erreur, cycles détectés, dépendance inconnue
  refusée dès la déclaration de la route.
* Un groupe peut fournir des dépendances à toutes ses routes : `app.group("", null, ["db", "user"])`.
* `app.value("db")` rend une dépendance de portée app déjà créée (utile dans les tâches de fond).
* En test, `app.override("user", (req) => {"nom": "Test"})` remplace un fournisseur.

## 9. Configuration et profils

```al
cfg := alweb.load_config("config")       # base.json < <profil>.json < local.json < variables ALWEB_*
app.configure(cfg)
url := cfg.require("database.url")       # ConfigError si absente
par_page := cfg.get("par_page", 5)       # valeur par défaut
```

* **Profil** : `ALWEB_ENV` (`dev` par défaut, `test`, `prod`…). `cfg.is_dev()`, `cfg.is_prod()`.
* **Variables d'environnement** : `ALWEB_DATABASE__URL=…` remplace `database.url` (`__` sépare les niveaux) ; la
  valeur est convertie selon le type existant (booléen, entier, nombre, JSON).
* **Clés reconnues par `app.configure`** : `debug` (mode debug), `server.trusted_proxies` (mandataires dont
  `X-Forwarded-For` est cru), `server.tls` (HTTPS), `site_url` (liens absolus des courriels).
* **Validation** : `alweb.load_config("config", null, SCHÉMA)` ; `cfg.safe_dict()` masque les secrets pour
  l'affichage.
* Les secrets de production ne vont jamais dans le dépôt : `local.json` (non versionné) ou variables
  d'environnement.

## 10. Base de données, ORM et migrations

### Se connecter

```al
db := alweb.database("sqlite:app.db")            # ou postgres://…, alexdb://…, memory:
rows := await db.query("SELECT * FROM articles WHERE auteur_id = ?", [id])
un := await db.query_one("SELECT …", [...])
```

Les appels sont attendus avec `await` : le serveur continue de répondre pendant la requête SQL. Les trois bases
(SQLite, PostgreSQL, ALEX DB) s'utilisent avec le même code ; changer de base, c'est changer
`database.url`.

### Décrire les tables

```al
use alweb.orm as orm

UTILISATEURS := orm.table("utilisateurs", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(), "roles": orm.json(default=["auteur"]), "cree_le": orm.timestamp(auto=true)})
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(120), "texte": orm.text(), "auteur_id": orm.ref("utilisateurs"), "cree_le": orm.timestamp(auto=true)})
```

Colonnes : `pk`, `integer`, `real`, `text`, `boolean`, `timestamp`, `json`, `ref` (clé étrangère).

### Lire et écrire

```al
id := await ARTICLES.insert(db, {"titre": "Été", "texte": "…", "auteur_id": 1})
a := await ARTICLES.get(db, id)
liste := await ARTICLES.where("auteur_id", 1).order_by("-id").limit(10).all(db)
premier := await ARTICLES.where("id", id).first(db)
existe := await UTILISATEURS.where("nom", "alice").exists(db)
n := await UTILISATEURS.query().count(db)
await ARTICLES.where("id", id).update(db, {"titre": "Automne"})
p := await ARTICLES.order_by("-id").paginate(db, numero, 5)     # items, page, pages, total, has_prev, has_next
```

`with_one(UTILISATEURS, "auteur_id", "auteur")` et `with_many(...)` chargent les liaisons en **une** requête de
plus, pas une par ligne (pas de « N+1 ») :

```al
a := await ARTICLES.where("id", id).with_one(UTILISATEURS, "auteur_id", "auteur").first(db)
a["auteur"]["nom"]
```

Recherche plein texte simple : `ARTICLES.search(["titre", "texte"], "été")`.

### Migrations

```al
MIGRATIONS := [
    orm.migration(1, "tables", [UTILISATEURS, ARTICLES]),
    orm.migration(2, "index", ["CREATE INDEX articles_auteur ON articles (auteur_id)"]),
    orm.migration(3, "courriel", [orm.add_column(UTILISATEURS, "courriel")])
]

await orm.migrate(db, MIGRATIONS)       # au démarrage, si database.migrate est vrai
```

* Chaque migration s'applique **une seule fois**, dans une transaction, et est notée dans `alweb_migrations`.
* On ne modifie **jamais** une migration déjà appliquée : on en ajoute une à la fin, avec un numéro plus grand.
* `alweb migrate --status` les liste (`[x]` appliquée, `[ ]` en attente) ; `alweb migrate` applique celles qui
  manquent.

Pour ALEX DB (base créée au démarrage, base locale embarquée `alexdb+local:`, différences avec SQLite et
PostgreSQL) : [ALEXDB.md](ALEXDB.md).

## 11. Gabarits

```al
app.use_templates(os.join(dossier, "templates"))
return alweb.render(req, "index.html", {"page": p})            # statut 200
return alweb.render(req, "form.html", {"form": f}, 422)        # autre statut
```

La syntaxe suit Jinja :

```html
{% extends "base.html" %}
{% block contenu %}
{% for a in page.items %}
<article>
  <h2><a href="{{ url_for('article', {'id': a.id}) }}">{{ a.titre }}</a></h2>
  <p>{{ a.texte | truncate(220) }}</p>
</article>
{% else %}
<p>Aucun article pour l'instant.</p>
{% endfor %}
{% endblock %}
```

* Instructions : `if/elif/else`, `for/else` (avec `loop`), `set`, `extends` / `block` / `super()`, `include`,
  `macro`, `import … as`, `raw`, contrôle des espaces `{%- -%}`.
* **Échappement automatique** : tout ce qui sort de `{{ … }}` est échappé ; un titre `<script>` s'affiche au
  lieu de s'exécuter. `Markup` marque un HTML sûr.
* Disponibles dans chaque gabarit rendu par `alweb.render` : `request`, `config`, `session`, `flashes()`,
  `csrf_token()`, `csrf_field()`, `url_for(nom, valeurs)`, `app_name`, plus ce que rendent les
  `@app.context_processor` :

```al
use reflection as _refl

@app.context_processor
func utilisateur_courant(req):
    connu := _refl.has_field(req, "deps") and req.deps != null and "user" in req.deps
    return {"current_user": req.deps["user"] if connu else null}
```

* Les erreurs de gabarit donnent le nom du fichier et la ligne ; en debug, les gabarits sont relus à chaque
  requête.

## 12. Thèmes : créer, installer, activer

Un **thème** (ALWEB Templates) fournit l'interface d'un site : gabarits, composants, CSS, JavaScript pour le
navigateur, images et paramètres réglables (couleurs, polices, menu…). L'application garde ses routes, ses
modèles et ses données. Un thème ne contient **jamais de code ALEX**, et il est contrôlé avant chaque
installation.

Le parcours complet tient en trois temps : on **crée** le thème dans son propre dossier, on l'**installe** dans un
projet, puis on l'**active**.

### Créer un thème

```sh
alweb theme create modern-business --nom "Modern Business" --auteur "Ennuum Group"
cd modern-business
```

`alweb theme create <identifiant>` crée un dossier depuis le modèle « Modern Business ». L'identifiant (le
`slug`) s'écrit en minuscules, chiffres et tirets (`modern-business`). Options : `--nom` (nom affiché),
`--auteur`, `--dir` (autre dossier), `--domaine` pour partir d'un modèle adapté au site :

| `--domaine` | Pages fournies |
|---|---|
| `business` (défaut, alias `vitrine`) | accueil, services, à propos, blog, contact |
| `ecommerce` (alias `boutique`) | accueil avec rayons, catalogue filtrable, fiche produit, panier, commande |
| `blog` | article à la une, liste par catégorie, barre latérale, lecture, articles similaires |
| `portfolio` | présentation, projets en grille, filtre, fiche projet avec galerie |

Le dossier créé :

```
modern-business/
├── alweb-theme.json        manifeste : nom, slug, version, licence, versions d'ALWEB et d'ALEX acceptées
├── config/theme.json       paramètres réglables (schéma typé)
├── templates/              pages : base.html, index.html, … , errors/404.html
├── components/             navbar.html, footer.html, hero.html, cards.html (macros)
├── static/                 css/, js/, images/, icons/, fonts/
├── preview/data.json       données de démonstration pour l'aperçu
└── documentation/          dont installation.md : les données attendues par chaque page
```

### Mettre au point, valider, empaqueter

Depuis le dossier du thème :

```sh
alweb theme preview          # http://127.0.0.1:8001/_apercu : ordinateur, tablette et mobile côte à côte
alweb theme validate         # contrôles de sécurité et de structure ; code 1 si le thème est invalide
alweb theme package          # dist/modern-business-0.1.0.alwt (archive reproductible, empreinte SHA-256)
```

* L'**aperçu** sert chaque page avec les données de `preview/data.json` et relit le thème à chaque requête :
  on modifie, on recharge.
* La **validation** refuse notamment tout fichier de code ou exécutable (`.al`, `.sh`, `.py`, `.exe`…), les
  liens symboliques, les SVG qui contiennent du script, un gabarit qui ne s'analyse pas ou qui inclut un
  gabarit absent, un manifeste ou des paramètres invalides. Elle signale aussi un README, une LICENSE ou des
  captures d'écran manquants.
* Avant chaque nouvelle archive, augmentez `version` dans `alweb-theme.json` (`0.1.0` → `0.2.0`).

### Installer le thème dans un projet

Depuis la racine du projet :

```sh
cd ../monsite
alweb theme install ../modern-business/dist/modern-business-0.1.0.alwt
```

`alweb theme install` accepte une archive `.alwt`, le dossier d'un thème (pratique pendant la mise au point),
ou un identifiant de la marketplace (`alweb theme install modern-business@^1.0`). L'installation :

1. **inspecte l'archive avant d'écrire quoi que ce soit** (chemins, types et tailles des fichiers), l'extrait dans
   un dossier temporaire, la valide, puis la met en place dans `themes/modern-business/` ;
2. vérifie la **compatibilité** (versions d'ALWEB et d'ALEX du manifeste, thèmes dont il dépend) ;
3. note le thème dans **`alweb.lock`** (version, source, empreintes) ; **le premier thème installé devient
   actif** ;
4. **branche le thème dans l'application** : dans `application.al`, la ligne
   `app.use_templates(os.join(dossier, "templates"))` devient `themes.setup(app, null, {"root": dossier})`, et
   `use alweb.themes as themes` est ajouté. Les projets créés par `alweb new` sont déjà branchés. Si le fichier
   n'a pas cette forme, rien n'est modifié et la commande affiche la ligne à écrire.

Il reste à **redémarrer** l'application (`alweb run`).

Réinstaller la même version demande `--force`. Une nouvelle version garde l'ancienne dans `themes/.versions/`.
Versionnez `alweb.lock` et `themes/` avec le projet.

### Activer, changer, revenir en arrière

Un projet peut avoir plusieurs thèmes installés ; un seul est **actif** :

```sh
alweb theme list                         # thèmes installés ; « * » marque le thème actif
alweb theme activate modern-business     # rend ce thème actif (et branche l'application au besoin)
alweb theme deactivate                   # plus de thème : l'application reprend ses seuls gabarits
alweb theme info modern-business         # détail, compatibilité, contenu modifié depuis l'installation ?
alweb theme check                        # revalide le thème actif ; code 1 en cas de problème
alweb theme rollback modern-business     # revient à la version précédente
alweb theme remove modern-business       # retire le thème (refusé si un autre thème en dépend)
```

Après `activate` ou `deactivate`, redémarrez l'application. Dans le code, c'est `themes.setup` qui charge le
thème actif (clé de configuration `theme.active`, sinon `alweb.lock`) ; sans thème actif, il ne fait rien :

```al
use alweb.themes as themes

themes.setup(app, null, {"root": dossier})          # thème actif du projet
themes.setup(app, "modern-business")                # ou un thème précis
```

### Ce que l'activation change dans le site

* Les pages prennent l'en-tête, le menu, le pied et les styles du thème. Le `templates/base.html` créé par
  `alweb new`, s'il n'a pas été modifié, est renommé en `base.html.sans-theme` à l'installation (remettez-le en
  place pour revenir à la page simple).
* **Les gabarits du projet passent avant ceux du thème** : pour adapter une page, copiez-la dans `templates/` du
  projet (elle peut étendre `base.html` du thème). Il en va de même pour `components/`. Ne modifiez pas
  `themes/` directement : `alweb theme check` signale un thème modifié depuis son installation.
* Dans les gabarits : `theme` (paramètres, par exemple `{{ theme.site.nom }}`), `asset("css/theme.css")` (URL
  versionnée d'une ressource du thème), `theme_css` (variables CSS) et `theme_info` (manifeste).

### Régler le thème du projet

Les choix du projet vont dans `config/theme.<slug>.json`, seulement ce qui change :

```json
{"couleurs": {"primaire": "#1f6feb"}, "site": {"nom": "Ma société"}}
```

Ils sont vérifiés au démarrage : une couleur invalide, un paramètre inconnu ou un lien `javascript:` arrêtent
l'application avec la liste des erreurs. Avec `alweb.admin`, la page **Apparence** (`/admin/_apparence`) règle
ces paramètres avec un aperçu en direct, sans toucher aux fichiers.

### Raccourci : un site complet avec son thème

```sh
alweb new ma_boutique --domaine ecommerce
```

Avec `--domaine` (`business`, `ecommerce`, `blog`, `portfolio`), `alweb new` crée le projet du domaine
(tables, données d'exemple, tests), **crée le thème** sous l'identifiant du projet (`ma_boutique` →
`ma-boutique`), **l'installe et l'active** : le site est prêt à lancer.

Pour aller plus loin (manifeste et types de paramètres, sécurité, page Apparence, publication sur la
marketplace) : [THEMES.md](THEMES.md).

## 13. Formulaires, sessions, CSRF et comptes

### Formulaires

```al
@app.post("/messages", {"deps": ["db"]})
async func publier(req):
    f := alweb.validate_form(req, modeles.MESSAGE)
    if not f.valid:
        return alweb.render(req, "index.html", {"form": f}, 422)          # réaffiché, saisie conservée
    await modeles.MESSAGES.insert(req.deps["db"], {"auteur": f.data["auteur"], "texte": f.data["texte"]})
    alweb.session(req).flash("Message publié.", "succes")
    return alweb.redirect(app.url_for("accueil"), 303)                    # POST réussi -> redirection
```

* `f.valid`, `f.data` (valeurs converties), `f.values` (saisies brutes, pour réafficher), `f.error(champ)`.
* `alweb.form(req)` lit un formulaire urlencoded ou multipart ; `alweb.form(req).file("image")` un fichier
  envoyé, à contrôler avec `forms.check_upload(fichier, octets, types)` (type réel lu dans le contenu) et à
  nommer avec `forms.unique_name`.
* Après un `POST` réussi, redirigez en **303** : recharger la page ne renvoie pas le formulaire.

### Sessions et messages flash

```al
s := alweb.session(req)
s.set("panier", [...]); s.get("panier"); s.pop("panier")
s.flash("Article publié.", "succes")          # affiché une fois par {% for f in flashes() %}
```

Stockage : cookie signé par `secret_key` (défaut), `MemoryStore`, ou `DatabaseStore(db)` (partagé entre
processus).

### CSRF

`csrf.middleware(["/api/"])` exige un jeton sur tout `POST` d'un navigateur, sauf sous les préfixes exemptés (une
API qui s'authentifie par jeton, sans cookie). Chaque formulaire contient :

```html
<form method="post" action="{{ url_for('publier') }}">
  {{ csrf_field() }}
  ...
</form>
```

Sans ce champ (ou l'en-tête `X-CSRF-Token`), la requête reçoit **403**.

### Comptes et droits

```al
use alweb.auth as auth

app.provide("user", auth.current_user(charger_utilisateur))      # charger(req, id) -> compte

mdp := await auth.hash_password(saisie)                           # PBKDF2, calculé hors de la boucle
ok := await auth.verify_password(saisie, u["mdp"])
auth.login(req, u["id"], u["roles"])                              # nouvelle session, nouveau jeton CSRF
auth.logout(req)
nxt := auth.next_url(req, "/")                                    # n'accepte qu'un chemin local
```

* `auth.login_required("/connexion")` : un navigateur est renvoyé vers `/connexion?next=…`, un client d'API
  reçoit 401.
* `auth.roles_required(["admin"])` : 403 sans le rôle.
* Les droits fins (« l'auteur ou un administrateur ») se vérifient **côté serveur** dans la route : cacher un
  bouton dans le gabarit ne protège rien.
* Une suppression est un `POST` avec son jeton CSRF, jamais un lien `GET`.

Liens envoyés par courriel (confirmation d'adresse, mot de passe oublié) : `auth.confirm_token` /
`read_confirm_token`, `auth.reset_token` / `check_reset_token` (usage unique) — voir
[COURRIEL.md](COURRIEL.md#liens-à-usage-unique).

## 14. API JSON

```al
use alweb.ratelimit as rl

api := app.group("/api", [rl.limit(120, 60)], ["db"])           # 120 requêtes / minute / IP

@api.post("/jeton", {"body": IDENTIFIANTS})
async func jeton(req):
    d := alweb.data(req)
    u := await UTILISATEURS.where("nom", d["nom"]).first(req.deps["db"])
    if u == null or not await auth.verify_password(d["mdp"], u["mdp"]):
        return ({"erreur": "identifiants invalides"}, 401)
    return {"jeton": auth.jwt_encode({"sub": u["id"], "roles": u["roles"]}, secret, 3600), "expire_dans": 3600}

@api.post("/articles", {"body": ARTICLE, "middleware": [auth.bearer(secret)]})
async func publier(req):
    id := await ARTICLES.insert(req.deps["db"], {"titre": alweb.data(req)["titre"], "auteur_id": auth.user_id(req)})
    return ({"id": id}, 201)
```

| Besoin | Outil |
|---|---|
| Jetons | `auth.jwt_encode` / `jwt_decode` (HS256), `auth.bearer(secret)` |
| Limite de débit | `rl.limit(n, période, clé, stockage, scope, fail_open, exempt)` : fenêtre glissante, en-têtes `RateLimit-*`, 429 avec `Retry-After` ; `rl.DatabaseStore(db)` pour partager entre processus |
| Pagination | `alweb.pagination` : `params(req)`, `page(req, résultat)` (en-têtes `Link`, `X-Total-Count`), pagination par curseur |
| Documentation | `oa.setup(app, title="…", version="1.0.0")` (`alweb.openapi`) : `/openapi.json` et une page `/docs` avec « Essayer » |
| Versions | `app.group("/api/v1", null, null, {"tags": ["v1"], "deprecated": …, "sunset": …})` : en-têtes `Deprecation` et `Sunset` |
| CORS | option `cors` d'une route ou d'un groupe, ou intergiciel `mw.cors` |

Options de documentation d'une route : `summary`, `description`, `tags`, `response`, `status`, `responses`,
`security`, `operation_id`, `hidden`.

## 15. Temps réel

### WebSocket

```al
@app.websocket("/chat/{salon}")
async func chat(req, ws):
    while true:
        m := await ws.receive()               # null quand le client ferme
        if m == null:
            break
        await ws.send_text("écho : " + m.text())
```

`await ws.close(code, raison)` ferme la connexion de votre côté.

Options : `protocols`, `max_message`, `origins`, `name`.

### Server-Sent Events et flux

```al
use asyncio as aio

async func compteur(req, flux):
    i := 0
    while not flux.closed:
        await flux.send({"i": i}, "tic", i)       # données, événement, identifiant
        i += 1
        await aio.sleep(1)

app.get("/evenements", alweb.sse(compteur))
```

`flux.last_event_id` donne le dernier identifiant reçu par un client qui se reconnecte.

`alweb.stream(producteur, type)` envoie un flux brut (`await flux.write(morceau)`).

### Salons avec présence

```al
use alweb.realtime as rt

hub := rt.Hub()                                     # plusieurs processus : rt.Hub(rt.DatabaseBroker(db))
hub.attach(app)

@app.websocket("/ws/{salon}")
async func salon(req, ws):
    await hub.room(req.params["salon"]).serve(ws, {"id": pseudo})       # présence, diffusion, départ

app.get("/salons/{salon}/evenements", hub.sse((req) => req.params["salon"]))   # reprise par Last-Event-ID
```

L'exemple complet (comptes, salons, indicateur de frappe, historique, API documentée) :
`alexc run examples/chat.al`.

## 16. Tests

Le client de test appelle l'application **en mémoire**, sans ouvrir de port, et garde les cookies comme un
navigateur :

```al
use os
use alweb
use alweb.testing as at
use application
from testing use assert_eq, assert_contains

RACINE := os.dirname(os.dirname(os.absolute(os.argv()[0])))

func client():
    return at.Client(application.creer(alweb.load_config(os.join(RACINE, "config"), "test"), RACINE))

async func test_api():
    c := client()
    r := await c.post("/api/messages", {"json": {"auteur": "API", "texte": "depuis l'API"}})
    assert_eq(r.status, 201)
    r = await c.get("/api/messages")
    assert_eq(r.json_value()["messages"][0]["texte"], "depuis l'API")
```

* Chaque test crée une application neuve : avec `database.url = "memory:"` en profil test, une base vide.
* Plusieurs clients sur la même application jouent plusieurs personnes (droits, commentaires…).
* Formulaires : `c.post(chemin, {"form": champs})`, en recopiant `csrf_token` depuis la page (voir
  `tests/test_application.al` du projet généré).
* Réponse : `r.status`, `r.text()`, `r.json_value()`, `r.headers`.
* Courriels et tâches : `await at.run_jobs(app)`, puis `at.outbox(app)` et `at.links(texte)`.
* Dépendances : `app.override(nom, fournisseur)`.

```sh
alweb test                        # ALWEB_ENV=test alexc test tests
alweb test --filter api
alweb check                       # analyse du code et mise en forme, avant de livrer
```

## 17. Les services intégrés

Chaque service se branche en une ou deux lignes dans `application.al` et a son guide détaillé.

| Service | Mise en place | Guide |
|---|---|---|
| **Courriels** | clé `mail.url` (`smtp://…`, `console` en dev, `memory` en test) ; `alweb.mailer(req).send_template(à, sujet, "confirmation", valeurs)`, `send_later` | [COURRIEL.md](COURRIEL.md) |
| **Tâches de fond** | `jobs.Queue(app, jobs.DatabaseStore(() => app.value("db")))` ; `@app.jobs.task("nom")`, `enqueue(nom, données, {"delay": 86400})`, tâches planifiées `@q.every(nom, "30 3 * * *")` | [TACHES.md](TACHES.md) |
| **Fichiers et images** | `storage.setup(app)` (disque, mémoire, S3 compatible) ; URL signées ; vignettes par `alweb.images` | [FICHIERS.md](FICHIERS.md) |
| **Plusieurs langues** | `i18n.I18n(app, "locales", {"default": "fr"})` ; `_("…")` dans les gabarits ; `alweb i18n` vérifie les traductions | [I18N.md](I18N.md) |
| **Administration** | `adm.Admin(app, {"roles": ["admin"]})` puis `admin.register(TABLE, {...})` : listes, recherche, fiches, export CSV | [ADMIN.md](ADMIN.md) |
| **Thèmes** | `alweb theme create / install / activate` ([partie 12](#12-thèmes--créer-installer-activer)) ; marketplace signée | [THEMES.md](THEMES.md), [protocole](MARKETPLACE_PROTOCOLE.md) |
| **ALEX DB** | `database.url = "alexdb://…"`, ou `alweb new --base alexdb` | [ALEXDB.md](ALEXDB.md) |
| **Calcul lourd** | `await alweb.offload(module.fonction, [args])` : sur un autre cœur, sans bloquer le serveur | — |
| **HTTP sortant** | `await network.async_client.get(url)` dans un gestionnaire | — |

## 18. Performance et production

### Plusieurs cœurs, HTTP/2, HTTPS

* `await app.run_workers(hôte, port, n)` : `n` processus (0 = un par cœur). Ce qui doit être commun aux
  processus passe par la base : sessions (`DatabaseStore`), limites de débit, salons (`DatabaseBroker`), tâches.
* **HTTP/2** sans réglage : h2c par préface sur le port HTTP/1.1, `h2` par ALPN sur TLS.
* **HTTPS** sans code, par la configuration :

```json
{"server": {"tls": {"cert": "/etc/letsencrypt/live/site/fullchain.pem", "key": "/etc/letsencrypt/live/site/privkey.pem"}}}
```

* ou un certificat **Let's Encrypt automatique**, obtenu et renouvelé par alweb :

```json
{"server": {"host": "0.0.0.0", "port": 443,
            "tls": {"acme": {"domains": ["site.example.org"], "email": "admin@example.org", "agree_tos": true}}}}
```

* En développement : `alweb run --https` crée un certificat auto-signé local.

### Exécutable autonome ou natif

```sh
alweb build                       # dist/<nom> : VM embarquée, SQLite disponible
alweb build --native              # exécutable natif : sans SQLite ni OpenSSL (PostgreSQL, ALEX DB, TLS ALEX)
```

### Déployer

```sh
alweb secret                                          # clé pour ALWEB_SECRET_KEY
alweb deploy systemd caddy --domaine monsite.example.org
```

`alweb deploy` génère dans `deploy/` un service systemd durci, un `Caddyfile` (HTTPS automatique), et au choix
une configuration nginx, un `Dockerfile` et un `compose.yaml` (`tout` pour l'ensemble). Derrière un mandataire,
réglez `server.trusted_proxies` pour obtenir l'adresse réelle des clients.

Le pas à pas complet (serveur, base, sauvegardes, mises à jour, liste de vérification) :
[DEPLOIEMENT.md](DEPLOIEMENT.md).

## 19. Aide-mémoire

### La commande `alweb`

| Commande | Effet |
|---|---|
| `alweb new <nom> [--base sqlite\|alexdb\|URL]` | nouveau projet |
| `alweb run [--env P] [--port N] [--https]` | lancer (dev : debug et rechargement à chaud) |
| `alweb test [--filter X]` | tests en profil test |
| `alweb routes` | méthodes, motifs, noms |
| `alweb migrate [--status]` | migrations |
| `alweb i18n [--update]` | traductions manquantes |
| `alweb jobs [--retry ID\|tout] [--run]` | file des tâches de fond |
| `alweb theme create <slug> [--domaine D]` | nouveau thème |
| `alweb theme preview / validate / package` | mettre au point, contrôler, empaqueter (`.alwt`) |
| `alweb theme install <archive \| dossier \| slug>` | installer dans le projet (le premier devient actif) |
| `alweb theme activate <slug>` / `deactivate` | choisir le thème actif |
| `alweb theme list / info / check / rollback / remove` | gérer les thèmes installés |
| `alweb check` | analyse et mise en forme |
| `alweb build [--native]` | exécutable |
| `alweb deploy <cibles>` | fichiers de déploiement |
| `alweb secret` | clé aléatoire |

Référence complète et conventions d'un projet : [COMMANDE.md](COMMANDE.md).

### Les modules

| Module | Pour |
|---|---|
| `alweb` | `App`, réponses, `abort`, `data`, `render`, `redirect`, `session`, `database`, `load_config`, `offload`, `sse`, `stream`, `https` |
| `alweb.middleware` | intergiciels prêts à l'emploi |
| `alweb.sessions`, `alweb.csrf`, `alweb.auth`, `alweb.forms` | applications web et comptes |
| `alweb.orm`, `alweb.alexdb` | base de données |
| `alweb.templates` | gabarits |
| `alweb.realtime`, `alweb.ratelimit`, `alweb.openapi`, `alweb.pagination` | temps réel et API |
| `alweb.mail`, `alweb.jobs`, `alweb.storage`, `alweb.images`, `alweb.i18n`, `alweb.admin`, `alweb.themes` | services |
| `alweb.testing` | client de test et outils |

## 20. Pièges fréquents

| Symptôme | Cause et remède |
|---|---|
| `POST` d'un formulaire en **403** | il manque `{{ csrf_field() }}` dans le formulaire (ou l'intergiciel CSRF est placé avant la session) |
| Option de route ignorée ou refusée | les options passent par un dictionnaire (`{"name": "x"}`), pas par des arguments nommés sur une méthode |
| Le serveur ne répond plus pendant un calcul | calcul lourd dans la boucle : `await alweb.offload(...)` ; les mots de passe passent déjà par un fil |
| Base « verrouillée » ou données différentes selon le processus | avec `run_workers`, utilisez une base fichier ou un serveur, et les magasins `DatabaseStore` / `DatabaseBroker` |
| Une migration modifiée ne s'applique pas | une migration appliquée ne se rejoue jamais : ajoutez-en une nouvelle |
| Liens de courriel vers le mauvais domaine | réglez `site_url` ; alweb ne se fie jamais à l'en-tête `Host` |
| Tests lents | baissez `auth.iterations` dans `config/test.json` (par exemple 1000) |
| Formulaire renvoyé au rechargement | redirigez en 303 après un `POST` réussi |
| Tests qui ne trouvent pas `config/` | construisez les chemins depuis la racine du projet (`RACINE`), pas depuis le dossier courant |
| Le thème installé ne s'affiche pas | redémarrez l'application ; si `application.al` n'a pas pu être branché, écrivez la ligne `themes.setup(...)` affichée par `alweb theme install` ; une page de `templates/` du projet masque celle du thème |
| L'application refuse de démarrer après un réglage du thème | valeur invalide dans `config/theme.<slug>.json` : le message liste chaque erreur |
| Erreurs mystérieuses du runtime | vérifiez la version d'ALEX (`alex --version`) : il faut 1.4.0 ou plus récent |

---

**Pour aller plus loin** : le [tutoriel du blog](TUTORIEL_BLOG.md) (une heure, application complète et testée),
les exemples `examples/notes.al`, `examples/blog.al` et `examples/chat.al`, et les mesures de performance dans
`bench/RESULTS.md`.
