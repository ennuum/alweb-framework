# La commande `alweb`

`alweb` crée, lance, teste, inspecte, migre, construit et déploie les projets alweb. C'est un programme ALEX
(`alweb/cli.al`, point d'entrée `alweb/commande.al`) qui pilote `alexc` dans des processus fils.

## Installation

| Système | Lanceur |
|---|---|
| Linux, macOS, WSL | `bin/alweb` : `ln -s "$PWD/bin/alweb" ~/.local/bin/alweb` |
| Windows | `bin\alweb.cmd` : ajoutez le dossier `bin` au PATH |
| sans lanceur | `alexc run <paquet alweb>/commande.al -- <commande>` (par exemple depuis un projet : `alexc run alex_packages/alweb/commande.al -- routes`) |

Le lanceur cherche ALEX dans la variable `ALEX`, sinon `alex`, sinon `alexc` dans le PATH. `ALWEB_HOME` désigne
le paquet alweb (dossier qui contient `modele/` et `deploiement/`) ; les lanceurs la posent eux-mêmes.

## Commandes

| Commande | Effet |
|---|---|
| `alweb new <nom> [--dir D] [--description T] [--alweb DOSSIER \| --registre] [--base sqlite \| alexdb \| URL] [--sans-installation] [--force]` | projet depuis le modèle ; dépendance vers alweb par chemin relatif (ou version du registre), base choisie, puis `alexc pkg install` |
| `alweb run [--env P] [--port N] [--host H] [--https]` | lance le point d'entrée (`main.al`) ; `--env` pose `ALWEB_ENV`, `--port` et `--host` posent `ALWEB_SERVER__PORT` / `__HOST` ; `--https` crée au besoin un certificat auto-signé de développement (localhost, 127.0.0.1, ::1 ; clé P-256, un an, créé en ALEX sans outil `openssl`) dans `.alweb/dev-tls/` et sert en HTTPS et HTTP/2 par `server.tls` |
| `alweb test [chemins] [--filter X] [-j N] [--json]` | `alexc test` avec `ALWEB_ENV=test` (défaut : `tests`) |
| `alweb routes [--json]` | méthodes, motif et nom de chaque route, en chargeant l'application sans la lancer |
| `alweb migrate [--status] [--env P]` | applique les migrations manquantes, ou les liste (`[x]` appliquée, `[ ]` en attente) |
| `alweb i18n [--update] [--strict]` | traductions : clés utilisées dans le code et les gabarits, absentes de `locales/<langue>.json` ; `--update` les ajoute (vides) ([guide](I18N.md)) |
| `alweb jobs [--retry ID\|tout] [--run] [--env P]` | file des tâches de fond (`alweb.jobs`) : état, tâches en attente et abandonnées avec leur erreur ; `--retry` remet en file, `--run` exécute ce qui est dû ([guide](TACHES.md)) |
| `alweb theme <action> [cible] [--dir D] [--nom N] [--auteur A] [--out D] [--port N] [--force] [--json]` | thèmes : `create`, `validate`, `package`, `preview`, `install`, `activate`, `deactivate`, `list`, `info`, `remove`, `rollback`, `check` (alias français : `creer`, `valider`, `empaqueter`, `apercu`, `installer`…) ([guide](THEMES.md)) |
| `alweb theme search \| install <slug>[@contrainte] \| update \| publish \| keygen \| yank \| review \| reviews [--registre URL] [--jeton J] [--cle F] [--categorie C] [--tri T] [--verifier] [--nouvelle-cle] [--annuler] [--note N] [--titre T] [--texte X] [--pseudo P] [--supprimer]` | marketplace de thèmes : recherche (tri par popularité récente, note…), installation vérifiée (SHA-256, signature, clé de l'éditeur épinglée), mises à jour, publication signée, retrait d'une version, avis des sites qui ont installé le thème ; `ALWEB_MARKETPLACE`, `ALWEB_MARKETPLACE_TOKEN`, `ALWEB_PUBLISHER_KEY` ([guide](THEMES.md#la-marketplace)) |
| `alweb check` | `alexc check` du point d'entrée puis `alexc fmt --check` des fichiers du projet |
| `alweb build [--native] [-o FICHIER]` | exécutable autonome (VM et bytecode, défaut `dist/<nom>`) ou natif ; avec `alweb.images`, aussi `alweb-vignette` à côté (programme des vignettes, [guide](FICHIERS.md)) |
| `alweb deploy <cibles> [--domaine D] [--dossier /srv/nom] [--port N] [--utilisateur U] [--alex CHEMIN] [--force]` | fichiers de déploiement dans `deploy/` : `systemd`, `caddy`, `nginx`, `docker`, `tout` ([guide](DEPLOIEMENT.md)) |
| `alweb secret [--octets N]` | clé aléatoire en hexadécimal (32 octets par défaut) pour `ALWEB_SECRET_KEY` |
| `alweb version`, `alweb --help`, `alweb <commande> --help` | version, aide |

Alias français : `nouveau`, `lancer`, `migrer`, `verifier`, `construire`, `deployer`. Code de sortie : celui
d'`alexc` pour `run`, `test`, `check`, `build` ; 1 pour une erreur de la commande (`alweb: erreur: …`), 2 pour des
arguments invalides.

Toutes les commandes sauf `new`, `secret` et `version` agissent sur le projet du dossier courant (le premier
`alex.toml` en remontant) et s'exécutent depuis sa racine.

## Conventions d'un projet

`routes` et `migrate` doivent trouver l'application et ses migrations. Par défaut :

| Réglage | Défaut | Sens |
|---|---|---|
| `entry` | `entry` d'`alex.toml`, sinon `main.al` | point d'entrée (`run`, `check`, `build`) |
| `app` | `application` | module qui construit l'application |
| `factory` | `creer` | fonction `(cfg, dossier) -> App` de ce module, qui ne lance pas le serveur |
| `migrations` | `modeles.MIGRATIONS` | liste de migrations (`module.VARIABLE`) |
| `config` | `config` | dossier de configuration |
| `tests` | `tests` | dossier des tests |
| `templates` | `templates` | dossier des gabarits (`alweb i18n`) |
| `locales` | `locales` | dossier des catalogues de traductions (`alweb i18n`) |
| `default_locale` | `fr` | langue par défaut (`alweb i18n`) |

Un fichier `alweb.json` à la racine les change :

```json
{"app": "site.appli", "factory": "construire", "migrations": "site.schema.MIGRATIONS"}
```

Une clé inconnue ou un nom de module invalide est refusé. `routes`, `migrate` et `jobs` écrivent un petit programme dans
`build/alweb/` et l'exécutent avec `alexc run` depuis la racine du projet : la configuration y est chargée avec
le profil courant (`ALWEB_ENV`, `dev` par défaut) et les variables `ALWEB_*`.

## Le modèle de projet

`alweb new` recopie `alweb/modele/` : les fichiers `*.tpl` voient `{{nom}}`, `{{Nom}}`, `{{description}}`,
`{{dependance}}`, `{{alex}}`, `{{secret_dev}}`, `{{secret_test}}`, `{{database_url}}` et `{{database_create}}` remplacés (et perdent leur suffixe) ; les
autres, dont les gabarits HTML et leur syntaxe `{{ … }}`, sont copiés tels quels ; `_gitignore` devient
`.gitignore`. Les clés de `config/dev.json` et `config/test.json` sont tirées au hasard à chaque création.

Le projet obtenu : `main.al` (lancement par profil), `application.al` (`creer(cfg, dossier)` : sessions, CSRF,
gabarits, statique, base migrée au démarrage — SQLite, ou celle de `--base` : `alweb new monsite --base alexdb`
pointe sur un serveur ALEX DB local et crée la base au démarrage (`database.create`), `--base postgres://…` ou
`--base alexdb://…` prend l'URL telle quelle, voir [ALEXDB.md](ALEXDB.md) — page avec formulaire, API JSON à débit limité, `/sante`),
`modeles.al`, `config/` (`base`, `dev`, `test`, `prod`), `templates/`, `static/`, `tests/` (cinq tests),
`README.md`, `.gitignore`.

## Dépendance vers alweb

Le dossier `alweb/` du dépôt est le paquet (il a son propre `alex.toml`) : `use alweb` y trouve `alweb.al`, et
`alexc pkg install` le recopie dans `alex_packages/alweb/` avec la commande, le modèle et les gabarits de
déploiement. Deux façons d'en dépendre :

```toml
[dependencies]
alweb = { path = "../alweb/alweb" }        # dossier local (chemin relatif depuis le projet) : défaut d'alweb new
alweb = "^0.9.0"                           # registre (alweb new --registre), après `alexc pkg publish` dans alweb/
```

Sous Windows, un dossier sur un autre lecteur que le projet ne peut pas être désigné par un chemin relatif :
`alweb new` choisit alors la version du registre.
