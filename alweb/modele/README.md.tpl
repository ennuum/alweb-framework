# {{Nom}}

{{description}}

Application [alweb](https://github.com/ennuum/alweb) créée par `alweb new` : un livre d'or (page HTML avec
formulaire protégé par CSRF, API JSON à débit limité, base SQLite migrée au démarrage) à transformer en votre
application.

## Démarrer

```sh
alweb run            # http://127.0.0.1:8000/ : debug, rechargement à chaud (profil dev)
alweb test           # tests (profil test, base en mémoire)
alweb routes         # routes de l'application
alweb migrate        # applique les migrations (aussi faites au démarrage)
```

Sans la commande `alweb` : `alexc run`, `ALWEB_ENV=test alexc test tests`.

## Organisation

| Fichier | Rôle |
|---|---|
| `main.al` | lance le serveur selon le profil (`ALWEB_ENV` : `dev`, `test`, `prod`) |
| `application.al` | `creer(cfg, dossier)` : routes, intergiciels, dépendances |
| `modeles.al` | tables, migrations, schémas de validation |
| `config/` | `base.json` < `<profil>.json` < `local.json` (non versionné) < variables `ALWEB_*` |
| `templates/`, `static/` | gabarits et fichiers statiques |
| `tests/` | tests avec le client en mémoire |

## Production

```sh
alweb secret                                        # une clé pour ALWEB_SECRET_KEY
ALWEB_ENV=prod ALWEB_SECRET_KEY=... alweb run
alweb deploy systemd caddy                          # ou docker, nginx : fichiers écrits dans deploy/
```

Voir le guide de déploiement d'alweb (`docs/DEPLOIEMENT.md`).
