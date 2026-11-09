# Administration générée (alweb.admin)

`alweb.admin` produit une interface d'administration à partir des tables de l'ORM : un tableau de bord, une liste
par table (recherche, filtres, tri, pages), des fiches de création et de modification, la suppression avec
confirmation et l'export CSV. Rien à écrire en HTML : les gabarits et la feuille de style sont fournis.

```al
use alweb.admin as adm

admin := adm.Admin(app, {"prefix": "/admin", "roles": ["admin"], "login_url": "/connexion"})
admin.register(UTILISATEURS, {"exclude": ["mdp"], "display": "nom", "can_create": false})
admin.register(ARTICLES, {"list": ["id", "titre", "auteur_id", "cree_le"], "search": ["titre", "texte"],
                          "filters": ["auteur_id"], "display": "titre", "labels": {"auteur_id": "Auteur"}})
```

Le blog d'exemple (`examples/blog_app.al`) s'en sert : le premier compte créé (rôle « admin ») ouvre `/admin`.

## Prérequis

- `alweb.sessions.middleware(secret)` sur l'application : la connexion et les rôles viennent de `alweb.auth`.
- Un fournisseur de base de données : `app.provide("db", ouvrir_base, "app", fermer_base)`. L'option `db` change
  le nom de la dépendance, ou reçoit directement la base.

## Sécurité

Le groupe d'administration pose lui-même ses protections, que l'application les ait ou non :

| Protection | Effet |
|---|---|
| Connexion et rôles | `auth.roles_required(roles)` : visiteur redirigé vers `login_url?next=…` (page) ou 401 (API) ; 403 sans l'un des rôles. `roles: null` : toute personne connectée |
| Rôles par table | option `roles` de `register` : la table n'apparaît pas et répond 403 sans l'un de ces rôles |
| CSRF | chaque POST (création, modification, suppression) exige le jeton de la session, même si l'application n'utilise pas `alweb.csrf` |
| Cache et cadres | `Cache-Control: no-store`, `X-Frame-Options: DENY` |
| CSP | aucun style ni script en ligne : la feuille de style est servie par `/admin/_admin.css`, permise par `default-src 'self'` (`alweb.middleware.security_headers`) |
| Colonnes | `exclude` : jamais affichées, exportées ni modifiables (mots de passe, jetons). La clé primaire, les horodatages automatiques et `readonly` ne sont pas modifiables : une valeur envoyée pour eux est ignorée |
| Export CSV | une cellule qui commence par `=`, `+`, `-`, `@` est préfixée d'une apostrophe (pas de formule exécutée par un tableur) |
| Échappement | toutes les valeurs passent par l'échappement automatique des gabarits |

Le journal d'audit se branche par `on_change` :

```al
async func audit(req, ev):              # ev : action (create, update, delete), table, id, values, user_id
    await JOURNAL.insert(await alweb.dep(req, "db"), {"action": ev["action"], "cible": ev["table"] + "/" + str(ev["id"]), "par": ev["user_id"]})

admin := adm.Admin(app, {"on_change": audit})
```

## Tâches de fond

Quand l'application a une file [`alweb.jobs`](TACHES.md), l'administration ajoute une page **Tâches** (navigation
et tableau de bord, qui signale les tâches abandonnées) : ce que `alweb jobs` montre en ligne de commande, pour
quelqu'un qui n'a pas accès au serveur. Chaque tâche abandonnée affiche sa dernière erreur ; « Réessayer » lui
redonne tous ses essais. Les actions passent par la vérification CSRF de l'administration et sont signalées à
`on_change` (`job_retry`, `job_delete`, table `jobs`). La charge des tâches est montrée telle quelle (pour un
courriel : destinataires et texte) : réservez la page aux bons rôles (`"jobs": ["exploitation"]`).

## Langue

Sans réglage, l'administration est en français. Si l'application a une [`alweb.i18n`](I18N.md),
l'administration suit la langue de chaque requête. alweb fournit l'anglais. Une autre langue s'ajoute dans
`locales/<langue>.json`, avec le texte français comme clé (`"Ajouter"`, `"Retour à la liste"`…). La liste des
clés est dans `alweb/messages.al`. Les erreurs de saisie y sont rédigées pour la personne qui saisit
(« Au plus 60 caractères. »).

## Options

`Admin(app, options)` :

| Option | Défaut | Rôle |
|---|---|---|
| `prefix` | `"/admin"` | préfixe des URL |
| `title` | `"Administration"` | titre des pages |
| `db` | `"db"` | nom de la dépendance de base (ou la base) |
| `roles` | `["admin"]` | rôles d'entrée (l'un d'eux) ; `null` : toute personne connectée |
| `login_url` | `"/connexion"` | page de connexion |
| `on_change` | — | `fn(req, évènement)`, async permise |
| `jobs` | `true` | page « Tâches » si l'application a une file `alweb.jobs` ; `false` : pas de page ; liste de rôles : exigés en plus |

`register(table, options)` :

| Option | Défaut | Rôle |
|---|---|---|
| `list` | clé + 5 colonnes courtes | colonnes de la liste (triables) |
| `search` | colonnes texte | recherche « contient », sans tenir compte de la casse, en OU sur ces colonnes ; `[]` : pas de recherche |
| `filters` | `[]` | booléen : oui / non ; clé étrangère ou `choices` : liste ; sinon égalité avec la valeur saisie |
| `order` | `"-<clé>"` | tri par défaut |
| `per_page` | 25 | lignes par page |
| `display` | 1re colonne texte | nom d'une ligne : titre de la fiche, lien dans la liste, libellé des clés étrangères qui pointent vers elle |
| `exclude` | `[]` | colonnes jamais montrées |
| `readonly` | `[]` | montrées, non modifiables |
| `labels`, `help` | — | libellé et aide par colonne |
| `choices` | — | `{colonne: [[valeur, libellé], ...]}` : liste fermée, vérifiée à l'enregistrement |
| `can_create`, `can_edit`, `can_delete`, `can_export` | vrai | actions permises (403 sinon) |
| `roles` | — | rôles exigés pour cette table |
| `name`, `label` | nom de la table | segment d'URL, titre |

Une option ou une colonne inconnue est refusée à la déclaration (`AlwebError`).

## Extensions

D'autres modules peuvent ajouter des pages à l'administration (option `extensions`). Une extension est un objet
qui fournit :

* `install(admin, groupe, options)` : déclare ses routes sur le groupe de l'administration (garde de connexion
  et de rôles, CSRF, `no-store` compris), avant les routes `/{table}`, et ses gabarits avec
  `admin.env.add(nom, source)` (ils peuvent étendre `base.html`) ;
* `nav(admin, req)` : entrées du menu, `[{"label", "href", "current"}]` ;
* `cards(admin, req)` : cartes du tableau de bord, `[{"label", "href", "count", "note", "new"}]` (async permise).

Ses pages utilisent `admin.render(req, gabarit, contexte)`, `admin.flash(req, message, catégorie)`,
`admin.notify(req, {"action", "table", "id", "values"})` (journal `on_change`) et `await admin.db_for(req)`.

```al
COMPTEUR := [0]

class Annonce:
    func init():
        self.admin = null

    func install(admin, g, h):
        self.admin = admin
        g.get("/_annonce", (req) => self.page(req), h)
        g.post("/_annonce", (req) => self.publier(req), h)
        admin.env.add("annonce.html", """{% extends "base.html" %}{% block contenu %}<h1>{{ page_title }}</h1>
<form class="fiche" method="post">{{ csrf_field() }}<input name="texte" value="{{ texte }}">
<div class="actions"><button class="principal">Publier</button></div></form>{% endblock %}""")

    func nav(admin, req):
        return [{"label": "Annonce", "href": admin.prefix + "/_annonce", "current": req.path() == admin.prefix + "/_annonce"}]

    func cards(admin, req):
        return [{"label": "Annonce", "href": admin.prefix + "/_annonce", "count": COMPTEUR[0], "note": "publications", "new": null}]

    func page(req):
        return self.admin.render(req, "annonce.html", {"page_title": "Annonce", "texte": ""})

    async func publier(req):
        COMPTEUR[0] = COMPTEUR[0] + 1
        await self.admin.notify(req, {"action": "annonce", "table": "annonces", "id": COMPTEUR[0], "values": null})
        self.admin.flash(req, "Annonce publiée.", "succes")
        return alweb.redirect(self.admin.prefix + "/_annonce", 303)

adm.Admin(app, {"extensions": [Annonce()]})
```

## Champs

| Colonne | Champ |
|---|---|
| `text(n)` (n ≤ 200) | ligne de texte, `maxlength` |
| `text()` ou n > 200, `json()` | zone de texte (JSON vérifié) |
| `integer`, `real` | nombre (`12,5` accepté) |
| `boolean` | case à cocher (décochée : faux) |
| `timestamp` | date et heure, heure locale du serveur (`AAAA-MM-JJ HH:MM` ou `AAAA-MM-JJ`) |
| `ref("table")` | liste des lignes de la table liée si elle est enregistrée et compte au plus 500 lignes ; sinon son identifiant |

Les erreurs s'affichent au champ concerné, la saisie est réaffichée : valeur requise, type, JSON, liste fermée,
longueur (validation de l'ORM) et unicité (`valeur déjà utilisée`). Une suppression refusée par la base (clé étrangère
imposée, `IntegrityError`) revient à la fiche avec un message.

## URL

| Méthode | Chemin | Page |
|---|---|---|
| GET | `/admin` | tableau de bord : tables et nombre de lignes |
| GET | `/admin/<table>?q=&f_<col>=&tri=&page=` | liste |
| GET | `/admin/<table>/export.csv?…` | export (mêmes filtres et tri, toutes les pages) |
| GET, POST | `/admin/<table>/nouveau` | création (« Enregistrer et ajouter un autre » : `_encore`) |
| GET, POST | `/admin/<table>/<id>` | fiche, modification |
| GET, POST | `/admin/<table>/<id>/supprimer` | confirmation, suppression |
| GET | `/admin/_taches?etat=` | tâches de fond : compteurs, liste (actives, en attente, en cours, abandonnées, faites) |
| POST | `/admin/_taches/reessayer` | nouvel essai de toutes les tâches abandonnées |
| GET | `/admin/_taches/<id>` | fiche d'une tâche : charge JSON, dates, erreur complète |
| POST | `/admin/_taches/<id>/reessayer`, `/supprimer` | nouvel essai d'une tâche abandonnée ; suppression (pas d'une tâche en cours) |

Les routes sont cachées de la description OpenAPI.

## Recherche de l'ORM

La recherche repose sur `Query.search(colonnes, terme)`, utilisable partout :

```al
trouves := await ARTICLES.search(["titre", "texte"], "été").where("publie", true).all(db)
```

`LOWER(col) LIKE ?` en OU sur les colonnes ; `%` et `_` gardent leur sens de LIKE. SQLite ne met en minuscules
que les lettres ASCII : « Été » n'y est pas trouvé par « été ».
