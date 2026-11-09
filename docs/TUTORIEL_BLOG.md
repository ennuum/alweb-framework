# Tutoriel : un blog avec alweb

Ce tutoriel construit pas à pas un blog multi-utilisateur : inscription et connexion, articles avec droits
(l'auteur et les administrateurs les modifient), commentaires, pagination, API JSON protégée par jeton, courriels
(confirmation d'adresse, mot de passe oublié), tests, puis mise en production. Le résultat complet est dans [`docs/tutoriel/blog/`](tutoriel/blog/) : chaque extrait ci-dessous
en vient, et ce projet passe ses tests (`alexc test docs/tutoriel/blog/tests`) à chaque exécution de la suite
d'alweb.

Durée : une heure environ. Il faut connaître les bases d'ALEX (fonctions, dictionnaires, `async` / `await`) et de
HTML.

## 0. Prérequis

* ALEX 1.4.0 ou plus récent (voir le [README](../README.md#prérequis)).
* La commande `alweb` dans le PATH :

  ```sh
  ln -s "$PWD/bin/alweb" ~/.local/bin/alweb          # Linux, macOS, WSL (depuis le dossier d'alweb)
  ```

  Sous Windows, ajoutez le dossier `bin` d'alweb au PATH (`bin\alweb.cmd`). Sans PATH, remplacez `alweb` par
  `chemin/vers/alweb/bin/alweb` dans la suite. Vérifiez : `alweb version`.

## 1. Créer le projet

```sh
alweb new blog --description "Blog multi-utilisateur"
cd blog
alweb run
```

`alweb new` recopie le modèle de projet, écrit dans `alex.toml` une dépendance vers le paquet alweb (un dossier
local, ou `--registre` pour une version publiée) et installe les dépendances dans `alex_packages/`. Ouvrez
http://127.0.0.1:8000/ : c'est un livre d'or qui fonctionne déjà. Le profil `dev` (par défaut) active le mode
debug et le rechargement à chaud : modifiez un `.al`, le serveur redémarre.

| Fichier | Rôle |
|---|---|
| `main.al` | lance le serveur selon le profil `ALWEB_ENV` (`dev`, `test`, `prod`) |
| `application.al` | `creer(cfg, dossier)` : construit l'application **sans la lancer** (les tests et `alweb routes` l'importent) |
| `modeles.al` | tables, migrations, schémas de validation |
| `config/` | `base.json` < `<profil>.json` < `local.json` (non versionné) < variables `ALWEB_*` |
| `templates/`, `static/` | gabarits et fichiers statiques |
| `tests/` | tests avec le client en mémoire |

Les clés secrètes de `config/dev.json` et `config/test.json` ont été tirées au hasard à la création ; celle de
production viendra de l'environnement (étape 9).

Le livre d'or va disparaître : supprimez `tests/test_application.al`, nous écrirons nos propres tests.

## 2. Le modèle de données

Un blog a des utilisateurs, des articles et des commentaires. Remplacez `modeles.al` :

```al
use alweb.orm as orm
use serialization.schema as sch

UTILISATEURS := orm.table("utilisateurs", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(), "roles": orm.json(default=["auteur"]), "cree_le": orm.timestamp(auto=true)})
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(120), "texte": orm.text(), "auteur_id": orm.ref("utilisateurs"), "cree_le": orm.timestamp(auto=true)})
COMMENTAIRES := orm.table("commentaires", {"id": orm.pk(), "article_id": orm.ref("articles"), "auteur_id": orm.ref("utilisateurs"), "texte": orm.text(2000), "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "tables", [UTILISATEURS, ARTICLES, COMMENTAIRES]),
    orm.migration(2, "index", ["CREATE INDEX articles_auteur ON articles (auteur_id)", "CREATE INDEX commentaires_article ON commentaires (article_id)"])
]
```

* `orm.table` décrit une table ; `create_sql` en tire le `CREATE TABLE` pour SQLite ou PostgreSQL.
* `orm.json` stocke une valeur JSON (ici la liste des rôles), `orm.ref` une clé étrangère,
  `orm.timestamp(auto=true)` l'heure d'insertion.
* Une **migration** est appliquée une seule fois, dans une transaction, et notée dans la table `alweb_migrations`.
  On n'en modifie jamais une déjà appliquée : on en ajoute une nouvelle à la fin de la liste.

Ajoutez les schémas qui valideront les formulaires et l'API, et la règle des droits :

```al
COMPTE := sch.object({"nom": sch.string(3, 40), "mdp": sch.string(8, 200)}, ["nom", "mdp"])
IDENTIFIANTS := sch.object({"nom": sch.string(1, 40), "mdp": sch.string(1, 200)}, ["nom", "mdp"])
ARTICLE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(1, 50000)}, ["titre", "texte"])
COMMENTAIRE := sch.object({"texte": sch.string(1, 2000)}, ["texte"])

# L'auteur de l'article et les administrateurs peuvent le modifier.
func peut_modifier(user, article):
    return user != null and article != null and (user["id"] == article["auteur_id"] or "admin" in user["roles"])
```

Les migrations s'appliquent au démarrage (clé `database.migrate` de la configuration). Vous pouvez aussi les
piloter à la main :

```sh
alweb migrate --status      # [ ] 1  tables   [ ] 2  index
alweb migrate               # appliquée : 1  tables ...
```

Ajoutez à `config/base.json` les réglages du blog (`"par_page": 5`, `"auth": {"iterations": 600000}`) et à
`config/test.json` `"auth": {"iterations": 1000}` : le hachage des mots de passe est volontairement lent, les
tests n'ont pas besoin de cette protection.

## 3. L'application et ses dépendances

`application.al` assemble tout. Deux **dépendances** sont fournies aux routes qui les demandent
(`{"deps": ["db", "user"]}`) :

```al
async func ouvrir_base(app):
    url := app.config.require("database.url")
    if url == "memory:" and "sqlite" in dbm.backends():
        url = "sqlite::memory:"
    db := alweb.database(url)
    if app.config.get("database.migrate", true):
        await orm.migrate(db, modeles.MIGRATIONS)
    return db

# Utilisateur de la session (auth.current_user) : rechargé depuis la base à chaque requête qui le demande.
async func charger_utilisateur(req, id):
    db := await alweb.dep(req, "db")
    return await modeles.UTILISATEURS.get(db, id)
```

```al
func creer(cfg, dossier="."):
    app := alweb.App(cfg.get("nom", "Blog"))
    app.configure(cfg)
    app.provide("db", ouvrir_base, "app", fermer_base)                 # une fois par processus
    app.provide("user", auth.current_user(charger_utilisateur))       # une fois par requête

    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", "") != "":
        mws = mws + [mw.logger(cfg.get("journal"))]
    app.middleware(mws + [sessions.middleware(cfg.require("secret_key")), csrf.middleware(["/api/"])])
    app.use_templates(os.join(dossier, "templates"))
    app.static("/static", os.join(dossier, "static"))

    # current_user dans tous les gabarits (null pour un visiteur).
    @app.context_processor
    func utilisateur_courant(req):
        connu := _refl.has_field(req, "deps") and req.deps != null and "user" in req.deps
        return {"current_user": req.deps["user"] if connu else null}

    comptes.installer(app, cfg)
    articles.installer(app, cfg)
    api.installer(app, cfg)
    ...
    return app
```

* L'ordre des intergiciels compte : la **session** (cookie signé par `secret_key`) précède le **CSRF**, qui
  exige un jeton sur tout `POST` d'un navigateur, sauf sous `/api/` (l'API s'authentifie par jeton, sans cookie).
* Les routes sont rangées par thème dans trois modules ; chacun expose `installer(app, cfg)`. L'application
  grandit sans que `application.al` enfle.

Le fichier complet : [`application.al`](tutoriel/blog/application.al).

## 4. Lire les articles

`articles.al` commence par la page d'accueil et la page d'un article :

```al
func installer(app, cfg):
    par_page := cfg.get("par_page", 5)
    site := app.group("", null, ["db", "user"])
    connecte := [auth.login_required("/connexion")]

    @site.get("/", {"name": "accueil"})
    async func accueil(req):
        p := await m.ARTICLES.order_by("-id").with_one(m.UTILISATEURS, "auteur_id", "auteur").paginate(req.deps["db"], numero_de_page(req), par_page)
        return alweb.render(req, "index.html", {"page": p})

    @site.get("/articles/{id:int}", {"name": "article"})
    async func voir(req):
        db := req.deps["db"]
        a := await m.ARTICLES.where("id", req.params["id"]).with_one(m.UTILISATEURS, "auteur_id", "auteur").first(db)
        if a == null:
            alweb.abort(404, "article introuvable")
        coms := await m.COMMENTAIRES.where("article_id", a["id"]).order_by("id").with_one(m.UTILISATEURS, "auteur_id", "auteur").all(db)
        return alweb.render(req, "article.html", {"article": a, "commentaires": coms, "peut_modifier": m.peut_modifier(req.deps["user"], a)})
```

* Le groupe `site` donne `db` et `user` à toutes ses routes.
* `with_one(UTILISATEURS, "auteur_id", "auteur")` charge les auteurs en **une** requête de plus (pas une par
  article) et les range sous `a["auteur"]`.
* `paginate` rend `items`, `page`, `pages`, `total`, `has_prev`, `has_next`.
* `{id:int}` convertit le paramètre ; `/articles/abc` répond 404 sans appeler la fonction.
* `{"name": "article"}` permet `url_for('article', {'id': 3})` dans le code et les gabarits : les URL ne sont
  écrites qu'une fois.

Les gabarits suivent une syntaxe à la Jinja. `templates/base.html` porte la mise en page et la navigation :

```html
<nav>
{% if current_user %}
  {{ current_user.nom }} · <a href="{{ url_for('ecrire') }}">Écrire</a>
  <form method="post" action="{{ url_for('deconnexion') }}">{{ csrf_field() }}<button>Se déconnecter</button></form>
{% else %}
  <a href="{{ url_for('connexion') }}">Connexion</a> · <a href="{{ url_for('inscription') }}">Inscription</a>
{% endif %}
</nav>
{% for f in flashes() %}
<p class="flash {{ f.category }}">{{ f.message }}</p>
{% endfor %}
<main>{% block contenu %}{% endblock %}</main>
```

`templates/index.html` l'étend :

```html
{% extends "base.html" %}
{% block contenu %}
{% for a in page.items %}
<article class="carte">
  <h2><a href="{{ url_for('article', {'id': a.id}) }}">{{ a.titre }}</a></h2>
  <p class="meta">par {{ a.auteur.nom }}</p>
  <p>{{ a.texte | truncate(220) }}</p>
</article>
{% else %}
<p>Aucun article pour l'instant.</p>
{% endfor %}
<nav class="pagination">
  {% if page.has_prev %}<a href="/?page={{ page.page - 1 }}">← plus récents</a>{% endif %}
  {% if page.has_next %}<a href="/?page={{ page.page + 1 }}">plus anciens →</a>{% endif %}
</nav>
{% endblock %}
```

Tout ce qui est affiché par `{{ … }}` est **échappé** : un titre `<script>` s'affiche tel quel au lieu de
s'exécuter. Le gabarit de l'article ([`article.html`](tutoriel/blog/templates/article.html)) utilise `nl2br` pour
garder les retours à la ligne et `super()` pour compléter le titre de la page.

## 5. Les comptes

`comptes.al` gère l'inscription, la connexion et la déconnexion. L'inscription montre le schéma complet d'un
formulaire :

```al
    @site.post("/inscription")
    async func inscription(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, m.COMPTE)
        if not f.valid:
            return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", f, "/"), 422)
        if await m.UTILISATEURS.where("nom", f.data["nom"]).exists(db):
            f = erreur_formulaire(f.values, "ce nom est déjà pris", "nom")
            return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", f, "/"), 422)
        premier := (await m.UTILISATEURS.query().count(db)) == 0
        roles := ["admin", "auteur"] if premier else ["auteur"]
        mdp := await auth.hash_password(f.data["mdp"], iterations)
        id := await m.UTILISATEURS.insert(db, {"nom": f.data["nom"], "mdp": mdp, "roles": roles})
        auth.login(req, id, roles)
        alweb.session(req).flash("Bienvenue, " + f.data["nom"] + " !", "succes")
        return alweb.redirect("/", 303)
```

* `validate_form` lit le formulaire et le valide avec le schéma : `f.valid`, `f.data` (valeurs converties),
  `f.values` (saisies, pour réafficher), `f.error(champ)`.
* Un formulaire refusé est **réaffiché** avec le statut 422 et ses messages, sans perdre la saisie.
* `hash_password` (PBKDF2) est calculé hors de la boucle d'événements : le serveur continue de répondre aux
  autres pendant ce calcul volontairement coûteux.
* `auth.login` crée une **nouvelle** session (et un nouveau jeton CSRF) : un identifiant de session connu avant
  la connexion ne vaut plus rien après.
* Après un `POST` réussi, on **redirige** (303) : recharger la page ne renvoie pas le formulaire.

La connexion vérifie le mot de passe et renvoie là où l'utilisateur voulait aller :

```al
    @site.post("/connexion")
    async func connexion(req):
        f := alweb.validate_form(req, m.IDENTIFIANTS)
        nxt := auth.next_url(req, "/")
        if f.valid:
            u := await m.UTILISATEURS.where("nom", f.data["nom"]).first(req.deps["db"])
            if u != null and await auth.verify_password(f.data["mdp"], u["mdp"]):
                auth.login(req, u["id"], u["roles"])
                alweb.session(req).flash("Vous êtes connecté.", "succes")
                return alweb.redirect(nxt, 303)
        f = erreur_formulaire(f.values, "nom ou mot de passe incorrect")
        return alweb.render(req, "compte.html", page_compte("Connexion", "Se connecter", f, nxt), 401)
```

`next_url` n'accepte qu'un chemin local (`/articles/3`), jamais `https://ailleurs.example` : pas de redirection
ouverte. Le message d'erreur ne dit pas si c'est le nom ou le mot de passe qui est faux.

Le gabarit [`compte.html`](tutoriel/blog/templates/compte.html) sert aux deux pages ; il importe une macro de
champ depuis `_champs.html` :

```html
{% macro texte(form, nom, libelle, type="text") %}
<label for="{{ nom }}">{{ libelle }}</label>
<input type="{{ type }}" id="{{ nom }}" name="{{ nom }}" value="{{ form.values[nom] if type != 'password' and nom in form.values else '' }}">
{% if form.error(nom) %}<p class="erreur">{{ form.error(nom) }}</p>{% endif %}
{% endmacro %}
```

Chaque formulaire `POST` contient `{{ csrf_field() }}` : sans ce champ, l'intergiciel CSRF répond 403.

## 6. Écrire, modifier, supprimer

Les routes d'écriture exigent une connexion (`"middleware": connecte`) :

```al
    @site.post("/ecrire", {"middleware": connecte})
    async func ecrire(req):
        f := alweb.validate_form(req, m.ARTICLE)
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": null}, 422)
        id := await m.ARTICLES.insert(req.deps["db"], {"titre": f.data["titre"], "texte": f.data["texte"], "auteur_id": req.deps["user"]["id"]})
        alweb.session(req).flash("Article publié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": id}), 303)
```

`login_required` renvoie un navigateur (en-tête `Accept: text/html`) vers `/connexion?next=/ecrire`, et répond 401
à un client d'API.

Modifier et supprimer passent par une seule fonction qui vérifie l'existence (404) puis les droits (403) :

```al
async func article_modifiable(req):
    a := await m.ARTICLES.get(req.deps["db"], req.params["id"])
    if a == null:
        alweb.abort(404, "article introuvable")
    if not m.peut_modifier(req.deps["user"], a):
        alweb.abort(403, "cet article ne vous appartient pas")
    return a
```

```al
    @site.post("/articles/{id:int}/modifier", {"middleware": connecte})
    async func modifier(req):
        a := await article_modifiable(req)
        f := alweb.validate_form(req, m.ARTICLE)
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": a}, 422)
        await m.ARTICLES.where("id", a["id"]).update(req.deps["db"], {"titre": f.data["titre"], "texte": f.data["texte"]})
        alweb.session(req).flash("Article modifié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)
```

La suppression est un `POST` (jamais un lien `GET` : un robot qui suit les liens effacerait tout), avec son jeton
CSRF. Cacher le bouton « Modifier » dans le gabarit ne suffit pas : c'est `article_modifiable` qui protège, côté
serveur.

## 7. Les commentaires

```al
    @site.post("/articles/{id:int}/commentaires", {"name": "commenter", "middleware": connecte})
    async func commenter(req):
        db := req.deps["db"]
        a := await m.ARTICLES.get(db, req.params["id"])
        if a == null:
            alweb.abort(404, "article introuvable")
        f := alweb.validate_form(req, m.COMMENTAIRE)
        if f.valid:
            await m.COMMENTAIRES.insert(db, {"article_id": a["id"], "auteur_id": req.deps["user"]["id"], "texte": f.data["texte"]})
            alweb.session(req).flash("Commentaire publié.", "succes")
        else:
            alweb.session(req).flash("Commentaire vide ou trop long.", "erreur")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)
```

Ici l'erreur passe par un message flash plutôt que par le réaffichage du formulaire : c'est un choix d'interface,
les deux sont possibles.

Vérifiez où en est l'application :

```sh
alweb routes
```

```
MÉTHODES  MOTIF                            NOM
GET       /inscription                     inscription
POST      /inscription
GET       /connexion                       connexion
POST      /connexion
POST      /deconnexion                     deconnexion
GET       /                                accueil
GET       /articles/{id:int}               article
GET       /ecrire                          ecrire
POST      /ecrire
GET       /articles/{id:int}/modifier      modifier
POST      /articles/{id:int}/modifier
POST      /articles/{id:int}/supprimer     supprimer
POST      /articles/{id:int}/commentaires  commenter
```

(L'API de l'étape suivante ajoutera `/api/jeton` et `/api/articles`.)

## 8. Une API JSON

`api.al` ouvre le blog aux programmes : un jeton contre des identifiants, puis la publication avec
`Authorization: Bearer <jeton>`.

```al
func installer(app, cfg):
    secret := cfg.require("secret_key")
    par_page := cfg.get("par_page", 5)
    api := app.group("/api", [rl.limit(cfg.get("api.limite", 120), 60)], ["db"])

    @api.post("/jeton", {"body": m.IDENTIFIANTS})
    async func jeton(req):
        d := alweb.data(req)
        u := await m.UTILISATEURS.where("nom", d["nom"]).first(req.deps["db"])
        if u == null or not await auth.verify_password(d["mdp"], u["mdp"]):
            return ({"erreur": "identifiants invalides"}, 401)
        return {"jeton": auth.jwt_encode({"sub": u["id"], "roles": u["roles"]}, secret, 3600), "expire_dans": 3600}

    @api.post("/articles", {"body": m.ARTICLE, "middleware": [auth.bearer(secret)]})
    async func publier(req):
        d := alweb.data(req)
        id := await m.ARTICLES.insert(req.deps["db"], {"titre": d["titre"], "texte": d["texte"], "auteur_id": auth.user_id(req)})
        r := alweb.json({"id": id}, 201)
        r.headers.set("Location", app.url_for("article", {"id": id}))
        return r
```

* `{"body": SCHÉMA}` valide le corps JSON **avant** l'appel : un corps invalide reçoit 422 avec le détail par
  champ ; `alweb.data(req)` rend les données validées.
* Rendre un dictionnaire produit du JSON ; un tuple `(corps, statut)` choisit le statut.
* `rl.limit(120, 60)` : 120 requêtes par minute et par adresse IP sur tout `/api`, avec les en-têtes
  `RateLimit-*` et un 429 au-delà.
* Le jeton JWT est signé par `secret_key` et expire au bout d'une heure.

```sh
curl -X POST localhost:8000/api/jeton -H 'Content-Type: application/json' -d '{"nom": "alice", "mdp": "motdepasse"}'
curl -X POST localhost:8000/api/articles -H 'Authorization: Bearer <jeton>' -H 'Content-Type: application/json' \
     -d '{"titre": "Depuis l API", "texte": "Bonjour"}'
```

## 9. Les courriels

Un vrai site écrit à ses membres : confirmer l'adresse donnée à l'inscription, envoyer un lien quand le mot de
passe est oublié. Trois morceaux : une colonne de plus, des gabarits de courriel, quelques routes.

**La base.** Ajoutez deux colonnes à `UTILISATEURS` et une migration ; une base déjà créée les reçoit
(`ALTER TABLE`), une base neuve les a dès la migration 1 et `orm.add_column` le voit :

```al
UTILISATEURS := orm.table("utilisateurs", {…, "courriel": orm.text(254, true), "confirme": orm.boolean(false)})

    orm.migration(3, "courriel", [orm.add_column(UTILISATEURS, "courriel"), orm.add_column(UTILISATEURS, "confirme"), orm.index("utilisateurs_courriel", "utilisateurs", ["courriel"], true)])
```

**La configuration.** En développement les courriels s'affichent dans le terminal, en test ils restent en mémoire :

```json
config/base.json  "mail": {"from": "Blog <noreply@blog.example.org>"}
config/dev.json   "mail": {"url": "console"}, "site_url": "http://127.0.0.1:8000"
config/test.json  "mail": {"url": "memory"},  "site_url": "https://blog.test"
```

En production : `ALWEB_MAIL__URL=smtp://identifiant:mot-de-passe@smtp.example.org:587` et
`ALWEB_SITE_URL=https://blog.example.org` (l'application refuse de démarrer sans eux). `site_url` fait les liens
des courriels : jamais l'en-tête `Host` de la requête, qu'un attaquant choisit.

**Les gabarits.** `templates/emails/confirmation.txt` (et `.html`, facultatif) :

```
Bonjour {{ nom }},

Pour confirmer l'adresse de votre compte sur {{ app_name }}, ouvrez ce lien :

{{ lien }}
```

**La file de tâches.** Les courriels ne doivent ni retarder ni faire échouer une page : ils partent par une file
de tâches rangée dans la base (`application.al`), qui les réessaie si le serveur de courrier est en panne et qui
sert aussi aux tâches différées ([guide des tâches](TACHES.md)) :

```al
    jobs.Queue(app, jobs.DatabaseStore(() => app.value("db")))
```

**L'inscription** demande l'adresse et envoie le lien par la file (`send_template_later`), puis programme un
rappel pour le lendemain si l'adresse n'est toujours pas confirmée :

```al
    func envoyer_confirmation(req, u):
        lien := mail.absolute_url(req, "/confirmation/" + auth.confirm_token(secret, u["id"], u["courriel"]))
        alweb.mailer(req).send_template_later(u["courriel"], "Confirmez votre adresse", "confirmation", {"nom": u["nom"], "lien": lien})

    @app.jobs.task("rappel_confirmation")
    async func rappel_confirmation(p, job):
        u := await m.UTILISATEURS.get(job.app.value("db"), p["id"])
        if u == null or u["confirme"] or u["courriel"] == null:
            return null
        lien := mail.site_link(job.app, "/confirmation/" + auth.confirm_token(secret, u["id"], u["courriel"]))
        await job.app.mail().send_template(u["courriel"], "Rappel : confirmez votre adresse", "confirmation", {"nom": u["nom"], "lien": lien})

        # dans inscription, après l'envoi du lien :
        await app.jobs.enqueue("rappel_confirmation", {"id": id}, {"delay": 86400, "key": "rappel-" + str(id)})

    @site.get("/confirmation/{jeton}", {"name": "confirmation"})
    async func confirmation(req):
        db := req.deps["db"]
        c := auth.read_confirm_token(secret, req.params["jeton"])
        …
        if u == null or u["courriel"] != c["email"]:
            alweb.session(req).flash("Ce lien de confirmation n'est pas valable (ou a expiré).", "erreur")
            return alweb.redirect("/", 303)
        await m.UTILISATEURS.where("id", u["id"]).update(db, {"confirme": true})
```

Le jeton est signé avec la clé secrète, daté (3 jours) et porte l'adresse : rien à ranger en base. Tant que
l'adresse n'est pas confirmée, `base.html` affiche un rappel avec un bouton « Renvoyer le lien ».

**Mot de passe oublié.** La page répond la même chose que l'adresse soit connue ou non (on ne révèle pas qui a un
compte), et la route est limitée à 5 demandes par quart d'heure :

```al
    @site.post("/mot-de-passe-oublie", {"middleware": [rl.limit(5, 900, null, null, "oubli")]})
    async func oubli(req):
        …
        if u != null:
            lien := mail.absolute_url(req, "/reinitialisation/" + auth.reset_token(secret, u["id"], u["mdp"]))
            alweb.mailer(req).send_template_later(u["courriel"], "Réinitialiser votre mot de passe", "reinitialisation", {"nom": u["nom"], "lien": lien})
        return alweb.render(req, "oubli.html", {"form": formulaire_vide(), "envoye": true})
```

Le jeton de réinitialisation porte une empreinte du mot de passe haché du moment : dès que le nouveau mot de
passe est enregistré, le lien ne vaut plus. Il expire aussi au bout d'une heure. La page
`/reinitialisation/{jeton}` vérifie le jeton (`auth.reset_token_user`, puis `auth.check_reset_token` avec le
mot de passe en base), demande le nouveau mot de passe, l'enregistre haché et renvoie vers la connexion.

Essayez : `alweb run`, inscrivez-vous, et copiez le lien affiché dans le terminal. Le détail de `alweb.mail`
(SMTP, pièces jointes, fichiers `.eml`, fournisseurs) est dans le [guide des courriels](COURRIEL.md).

## 10. Les tests

Le client de test appelle l'application en mémoire, sans réseau, et garde les cookies comme un navigateur.
`tests/test_blog.al` :

```al
use os
use string as s
use alweb
use alweb.testing as at
use application
from testing use assert_eq, assert_true, assert_contains

# Racine du projet (le dossier parent de tests/) : les tests passent quel que soit le dossier courant.
RACINE := os.dirname(os.dirname(os.absolute(os.argv()[0])))

func nouvelle_app():
    return application.creer(alweb.load_config(os.join(RACINE, "config"), "test"), RACINE)

# Jeton CSRF du premier formulaire de la page.
func jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

async func envoyer(c, page, chemin, champs):
    p := await c.get(page)
    champs["csrf_token"] = jeton(p.text())
    return await c.post(chemin, {"form": champs})
```

Chaque test crée une application neuve, donc une base SQLite en mémoire vide. Plusieurs clients sur la même
application jouent plusieurs personnes :

```al
async func test_articles_droits_et_commentaires():
    app := nouvelle_app()
    alice := at.Client(app)
    bob := at.Client(app)
    visiteur := at.Client(app)
    await inscrire(alice, "alice")                        # premier compte : administrateur
    await inscrire(bob, "bob")
    ...
    r = await carole.get("/articles/1/modifier")
    assert_eq(r.status, 403)
```

```sh
alweb test                       # ALWEB_ENV=test alexc test tests
alweb test --filter api
```

Les courriels se lisent dans la boîte du profil test, après avoir fait avancer la file de tâches :

```al
async func test_confirmation_par_courriel():
    c := at.Client(nouvelle_app())
    await inscrire(c, "alice")
    await at.run_jobs(c.app)                              # la file ne tourne pas seule pendant les tests
    boite := at.outbox(c.app)
    assert_eq(boite[0].to, ["alice@blog.test"])
    lien := at.links(boite[0].text)[0]                    # https://blog.test/confirmation/…
    r := await c.get(chemin(lien))
```

Le fichier complet : [`tests/test_blog.al`](tutoriel/blog/tests/test_blog.al) (huit tests : visiteur, comptes,
CSRF, droits et commentaires, pagination, API, confirmation d'adresse, mot de passe oublié). Avant de livrer : `alweb check` (analyse du code et mise en forme).

## 11. En production

1. Une clé secrète, hors du dépôt : `alweb secret` ; l'envoi des courriels et l'adresse publique :
   `ALWEB_MAIL__URL=smtp://…`, `ALWEB_SITE_URL=https://blog.example.org` (dans `.env`).
2. Le profil `prod` (`config/prod.json`) : journal JSON, un processus par cœur, confiance dans le mandataire local
   pour l'adresse réelle des clients.
3. Les fichiers de déploiement :

   ```sh
   alweb deploy systemd caddy --domaine blog.example.org
   ```

   `deploy/blog.service` (service systemd durci), `deploy/env.exemple` (à copier en `.env`), `deploy/Caddyfile`
   (HTTPS automatique). Variantes : `nginx`, `docker` (image et `compose.yaml`), ou `tout`.

La suite — serveur, base PostgreSQL, sauvegardes, mises à jour — est dans le
[guide de déploiement](DEPLOIEMENT.md).

## Pour aller plus loin

* **Plusieurs langues** : le blog complet est bilingue. `application.al` crée `i18n.I18n(app, …, {"default":
  "fr", "locales": ["fr", "en"]})`, les gabarits `base.html`, `index.html` et `article.html` passent leurs
  textes par `_("…")` et datent les articles avec `i18n.date(a.cree_le, "long")`, et `locales/en.json` donne
  l'anglais. Le pied de page propose les deux langues ; un visiteur dont le navigateur est en anglais lit le
  blog en anglais. `alweb i18n` vérifie qu'aucune traduction ne manque. Voir [I18N.md](I18N.md).

* **Administration** : le blog complet déclare `alweb.admin` dans `application.al` (comptes, articles,
  commentaires) ; le premier compte, administrateur, y accède par `/admin`, y compris la page des tâches de fond
  (courriels en attente, rappels, abandons avec leur erreur, « Réessayer »). Voir [ADMIN.md](ADMIN.md).

* **Images** : l'exemple [`examples/blog_app.al`](../examples/blog_app.al) ajoute une illustration par article
  (`alweb.form(req).file("image")`, `forms.check_upload` qui contrôle le type réel dans le contenu,
  `forms.unique_name`, `app.static("/media", ...)`).
* **PostgreSQL** : `ALWEB_DATABASE__URL=postgres://utilisateur:mdp@hôte/blog alweb run`, sans changer le code.
* **Temps réel** : `alweb.realtime` (salons WebSocket, présence, SSE) ; voir `examples/chat_app.al`.
* **Documentation de l'API** : `oa.setup(app, ...)` de `alweb.openapi` publie `/openapi.json` et `/docs`.
