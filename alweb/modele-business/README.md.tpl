# {{Nom}}

{{description}}

Site vitrine [alweb](https://github.com/ennuum/alweb) créé par `alweb new --domaine business` : accueil,
services, à propos (équipe), actualités et contact. L'interface vient du
thème du projet (`themes/`), déjà installé et actif.

## Démarrer

```sh
alweb run            # http://127.0.0.1:8000/ : debug, rechargement à chaud (profil dev)
alweb test           # tests (profil test, base en mémoire)
alweb routes         # routes de l'application
```

Le contenu (services, présentation, équipe, actualités) est dans les constantes en haut de `application.al` :
remplacez-le par le vôtre, ou placez-le dans une table de `modeles.al`.

## Organisation

| Fichier | Rôle |
|---|---|
| `application.al` | routes et contenu : accueil, services, à propos, actualités, contact |
| `modeles.al` | table `contacts` (demandes envoyées par le formulaire) |
| `themes/`, `alweb.lock` | thème installé (pages, styles, réglages) |
| `config/theme.<thème>.json` | vos réglages du thème : couleurs, police, logo, menu… (ou page Apparence) |
| `templates/` | un gabarit du même nom qu'une page du thème la remplace (copiez-le depuis `themes/`) |

Pour régler le thème depuis le navigateur, ajoutez l'administration d'alweb (`alweb.admin`, voir
`docs/ADMIN.md`) : elle ajoute la page Apparence.

## Production

```sh
alweb secret                                        # une clé pour ALWEB_SECRET_KEY
ALWEB_ENV=prod ALWEB_SECRET_KEY=... alweb run
alweb deploy systemd caddy                          # ou docker, nginx : fichiers écrits dans deploy/
```
