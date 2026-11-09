# {{Nom}}

{{description}}

Portfolio [alweb](https://github.com/ennuum/alweb) créé par `alweb new --domaine portfolio` : présentation, projets
en grille avec filtre par catégorie, fiche projet avec galerie, pages À propos et Contact. L'interface vient du
thème du projet (`themes/`), déjà installé et actif.

## Démarrer

```sh
alweb run            # http://127.0.0.1:8000/ : debug, rechargement à chaud (profil dev)
alweb test           # tests (profil test, base en mémoire)
alweb routes         # routes de l'application
```

Au premier démarrage, six projets d'exemple sont ajoutés si la table est vide (`modeles.EXEMPLES`) ;
`"exemples": false` dans `config/base.json` pour ne pas les ajouter.

## Organisation

| Fichier | Rôle |
|---|---|
| `application.al` | routes : accueil, projets, catégories, fiche projet, contact ; `COMPETENCES` et `PRESENTATION` à adapter |
| `modeles.al` | tables `projets` (`rubrique` pour les URL, `images` pour la galerie, `ordre`, `vedette`) et `contacts` |
| `themes/`, `alweb.lock` | thème installé (pages, styles, réglages) |
| `config/theme.<thème>.json` | vos réglages du thème : couleurs, polices, mention « disponible », adresse e-mail, menu… (ou page Apparence) |
| `templates/` | un gabarit du même nom qu'une page du thème la remplace (copiez-le depuis `themes/`) |
| `static/projets/` | images des projets d'exemple |

Pour gérer les projets depuis une interface, ajoutez l'administration d'alweb (`alweb.admin`, voir
`docs/ADMIN.md`) : elle gère la table `projets` et ajoute la page Apparence du thème.

## Production

```sh
alweb secret                                        # une clé pour ALWEB_SECRET_KEY
ALWEB_ENV=prod ALWEB_SECRET_KEY=... alweb run
alweb deploy systemd caddy                          # ou docker, nginx : fichiers écrits dans deploy/
```
