# {{Nom}}

{{description}}

Blog [alweb](https://github.com/ennuum/alweb) créé par `alweb new --domaine blog` : article à la une, liste
paginée, catégories, page de lecture avec articles similaires, pages À propos et Contact. L'interface vient du
thème du projet (`themes/`), déjà installé et actif.

## Démarrer

```sh
alweb run            # http://127.0.0.1:8000/ : debug, rechargement à chaud (profil dev)
alweb test           # tests (profil test, base en mémoire)
alweb routes         # routes de l'application
```

Au premier démarrage, six articles d'exemple sont ajoutés si la table est vide (`modeles.EXEMPLES`) ;
`"exemples": false` dans `config/base.json` pour ne pas les ajouter.

## Organisation

| Fichier | Rôle |
|---|---|
| `application.al` | routes : accueil, liste, catégories, article, contact |
| `modeles.al` | tables `articles` (date `publie_le` au format AAAA-MM-JJ, `rubrique` pour les URL) et `contacts` |
| `themes/`, `alweb.lock` | thème installé (pages, styles, réglages) |
| `config/theme.<thème>.json` | vos réglages du thème : couleurs, polices, présentation, menu… (ou page Apparence) |
| `templates/` | un gabarit du même nom qu'une page du thème la remplace (copiez-le depuis `themes/`) |
| `static/articles/` | images des articles d'exemple |

Pour écrire les articles depuis une interface, ajoutez l'administration d'alweb (`alweb.admin`, voir
`docs/ADMIN.md`) : elle gère la table `articles` et ajoute la page Apparence du thème.

## Production

```sh
alweb secret                                        # une clé pour ALWEB_SECRET_KEY
ALWEB_ENV=prod ALWEB_SECRET_KEY=... alweb run
alweb deploy systemd caddy                          # ou docker, nginx : fichiers écrits dans deploy/
```
