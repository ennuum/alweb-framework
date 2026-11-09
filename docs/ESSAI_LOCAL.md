# Essayer alweb sur votre machine

Ce guide vous mène d'un ALEX fraîchement construit à un projet, à un thème et à un site avec sa page
« Apparence », en une demi-heure environ (dont l'essentiel pour construire ALEX). Rien n'est
publié ni envoyé en ligne.

Système : Linux ou macOS. Sous Windows, utilisez WSL (Ubuntu) : les commandes sont les mêmes.

## 1. ALEX 1.4.0

alweb a besoin d'ALEX 1.4.0 ou plus récent (serveur asynchrone, HTTP/2, TLS 1.3 en ALEX, PostgreSQL,
Let's Encrypt, images…). Prenez le compilateur prêt à l'emploi des versions publiées, ou construisez-le dans
votre dépôt d'ALEX (le dossier qui contient `Makefile`, `src/`, `stdlib/`) :

```sh
git checkout main && git pull                # ALEX à jour (1.4.0 ou plus récent)
make alex                                    # construit ./alexc (plusieurs minutes)
export PATH="$PWD:$PATH"                     # à mettre aussi dans ~/.bashrc
alexc --version
```

* **Mémoire** : `make alex` compile le compilateur en natif, ce qui demande beaucoup de mémoire. Fermez les
  applications lourdes et vérifiez qu'un fichier d'échange existe (`swapon --show` ; sinon :
  `sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`).
  Il en va de même pour `alweb build --native`.
* SQLite : `sudo apt install libsqlite3-0` (Debian, Ubuntu) ; il est déjà présent sur macOS.

## 2. L'essai automatique

Depuis la racine du dépôt alweb :

```sh
sh tools/essai_local.sh
```

Le script ne touche à rien en dehors d'un dossier temporaire (effacé à la fin si tout va bien) et vérifie :

| Étape | Ce qui est essayé |
|---|---|
| 1. ALEX | `alexc` trouvé, version 1.4.0 ou plus récente, SQLite disponible |
| 2. Tests | application, gabarits, formulaires et CSRF, thèmes, Apparence, client de marketplace, exemple vitrine (moins d'une minute) ; `--complet` : toute la suite (environ 220 tests, une dizaine de minutes) |
| 3. Projet | `alweb new`, puis `alweb test`, `alweb routes`, `alweb check` dans le projet |
| 4. Thème | `alweb theme create`, `validate`, `package`, `install` dans le projet, `check`, `list` |

Résultat attendu : `14 réussi(s), 0 échec(s)`. Options : `--garder` (garder le dossier d'essai pour le
regarder), `ALEXC=/chemin/vers/alexc` (si `alexc` n'est pas dans le `PATH`).

## 3. À la main, dans le navigateur

Chaque serveur s'arrête avec Ctrl+C. Un seul processus en mode développement : rien de lourd pour la machine.

### Le site vitrine et sa page « Apparence »

```sh
alexc run examples/vitrine.al
```

* <http://127.0.0.1:8000/> : le site avec le thème « Modern Business » (accueil, services, à propos, blog,
  contact). Le thème est installé au premier lancement dans `examples/vitrine-site/` (dossier non versionné).
* <http://127.0.0.1:8000/admin/_apparence> : mot de passe `vitrine-locale`. Changez la couleur principale :
  l'aperçu, à droite, suit immédiatement. Essayez les vues tablette et mobile, envoyez un logo, puis
  « Enregistrer » et rechargez le site dans un autre onglet. L'historique permet de revenir en arrière.
* Pour repartir de zéro : supprimez `examples/vitrine-site/`.

### Avec une marketplace de thèmes

alweb contient le client : si vous avez accès à une marketplace (son adresse et, pour publier, un jeton
d'éditeur), depuis le dossier alweb :

```sh
export ALWEB_MARKETPLACE=https://themes.exemple.org
bin/alweb theme search
bin/alweb new monsite && cd monsite && ../bin/alweb theme install <identifiant>
```

Le serveur d'une marketplace ne fait pas partie d'alweb : le protocole qu'il doit suivre est décrit dans
[MARKETPLACE_PROTOCOLE.md](MARKETPLACE_PROTOCOLE.md).

### Votre propre projet

```sh
bin/alweb new monsite && cd monsite
../bin/alweb run                 # http://127.0.0.1:8000/, rechargé à chaque modification
../bin/alweb test
```

Pour avoir `alweb` partout : `ln -s "$PWD/bin/alweb" ~/.local/bin/alweb` (avec `~/.local/bin` dans le `PATH`).
Le [tutoriel du blog](TUTORIEL_BLOG.md) construit ensuite une vraie application pas à pas.

## En cas de problème

| Symptôme | Cause et remède |
|---|---|
| `alexc introuvable`, ou `alweb: command not found` | ajoutez le dossier d'ALEX (`export PATH=…`), ou appelez `bin/alweb` par son chemin |
| `ALEX trop ancien (1.4.0 ou plus récent requis)` | étape 1 : mettez ALEX à jour, puis `make alex` |
| `make alex` ou `alweb build --native` s'interrompt, ou la machine se fige | mémoire insuffisante : fichier d'échange (étape 1), applications fermées |
| `port occupé` | un autre serveur écoute déjà : `alexc run examples/vitrine.al -- 8001` |
| `SQLite indisponible` | `sudo apt install libsqlite3-0` |
| la marketplace refuse la publication (401) | jeton absent ou faux : `ALWEB_MARKETPLACE_TOKEN` |
| `la clé de l'éditeur a changé` | vous avez refait `keygen` : republier avec l'ancienne clé, ou `--nouvelle-cle` à l'installation |
| un test échoue | relancez-le seul pour voir le détail : `alexc test tests/test_themes.al` ; les journaux de l'essai sont gardés dans le dossier temporaire indiqué |

En production, le profil `prod` lance un processus par cœur (`server.workers: 0`). Sur un portable, restez en
`alweb run` (profil `dev`, un seul processus), ou fixez `ALWEB_SERVER__WORKERS=2`.
