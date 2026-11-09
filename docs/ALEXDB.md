# ALEX DB comme base d'une application alweb

[ALEX DB](../../AlexDB/README.md) est le SGBD relationnel écrit en ALEX (langage AQL, transactions ACID, index B+,
serveur réseau). Depuis alweb 0.9.0, une application alweb l'utilise comme SQLite ou PostgreSQL : même
`alweb.database(url)`, même ORM, mêmes migrations, sessions, limites de débit et salons temps réel.

Pourquoi le choisir :

* **Tout en ALEX.** Le pilote (`database._aqlp`) et le serveur sont écrits en ALEX : rien à
  installer en dehors de la chaîne ALEX.
* **Exécutable natif.** `alweb build --native` produit un exécutable sans bibliothèque C, donc sans SQLite. Le
  pilote ALEX DB y fonctionne (protocole AQLP sur TCP), comme le pilote PostgreSQL.
* **Plusieurs processus.** Le serveur ALEX DB est partagé par tous les ouvriers (`run_workers`) : sessions,
  limites et salons communs, comme avec PostgreSQL.

## Démarrage

```sh
cd AlexDB
alexdb init --data /var/lib/alexdb --user admin --password '…'     # une fois
alexdb start --data /var/lib/alexdb                                # 127.0.0.1:5442

alweb new monsite --base alexdb          # config/base.json : alexdb://admin:changez-moi@127.0.0.1:5442/monsite
cd monsite
ALWEB_DATABASE__URL='alexdb://admin:…@127.0.0.1:5442/monsite' alweb run
```

Avec `"database": {"create": true}` (posé par `--base alexdb`), l'application crée sa base au démarrage si elle
manque, puis applique ses migrations.

## Base locale embarquée (`alexdb+local:`)

Sans serveur à installer : l'application lance elle-même un serveur ALEX DB, ses données dans un dossier.

```al
use alweb
use alweb.alexdb_local                              # active alexdb+local: (importe le projet AlexDB)

db := alweb.database("alexdb+local:donnees")        # base « app » ; alexdb+local:donnees?base=blog pour une autre
```

```toml
# alex.toml du projet : le module importe le moteur et le serveur d'AlexDB
[package]
sources = ["../AlexDB"]
```

| Lancement | Où tourne le serveur |
|---|---|
| `app.run`, `run_dev`, tests (`alweb.testing`) | dans le processus, servi par une tâche de la boucle async |
| `app.run_workers` (`database.url` = `alexdb+local:…` dans la configuration) | dans le **maître**, pendant qu'il surveille les ouvriers ; les ouvriers s'y connectent par 127.0.0.1 (adresse transmise par `ALWEB_ALEXDB_LOCAL`) |

* **Natif** : tout est écrit en ALEX ; l'exécutable emporte la base avec lui, sans SQLite ni service.
* **Plusieurs processus** : une seule base pour tous les ouvriers (sessions, limites de débit, salons). Un ouvrier
  relancé, ou rechargé en développement, la retrouve telle quelle. `orm.migrate` lancé par tous les ouvriers en
  même temps applique chaque migration une fois.
* **Arrêt** : à INT / TERM, le maître laisse les ouvriers finir leurs requêtes (le serveur leur répond encore),
  puis arrête le serveur proprement (journal WAL, fichier pid retiré).
* **Premier lancement** : le dossier est créé avec un super-utilisateur `alweb` et un mot de passe tiré au hasard,
  gardé dans `<dossier>/alweb-local.json` (droits 0600). Le serveur n'écoute que sur 127.0.0.1, sur un port libre,
  et toute connexion s'authentifie. Journal : `<dossier>/alexdb.log`.
* **Administration** : le dossier est un dossier de données ALEX DB ordinaire ; arrêtez l'application avant d'y
  lancer `alexdb start`, puis connectez-vous avec les identifiants de `alweb-local.json`.
* **Limites** : un seul maître par dossier (deux applications sur le même dossier : utiliser un serveur
  `alexdb start` et des URL `alexdb://`) ; la base suit la machine (pas de réplication).

## URL

```
alexdb://utilisateur:motdepasse@hôte:5442/base?connect_timeout=10&lock_timeout=5
```

| Partie | Défaut | Rôle |
|---|---|---|
| utilisateur, mot de passe | `admin`, vide | compte ALEX DB (caractères spéciaux en `%XX`) |
| hôte, port | `127.0.0.1`, `5442` | serveur |
| base | `alexdb` (administration) | base de l'application |
| `connect_timeout` | 10 s | connexion et réponses |
| `lock_timeout` | 5 s | attente d'un verrou tenu par une autre connexion (voir plus bas) |

## Ce que fait le pilote

| Sujet | Comportement |
|---|---|
| Paramètres | `?` (liste) et `:nom` (dict) passés au serveur, jamais insérés dans le texte |
| Identifiants | une clé `INT PRIMARY KEY` omise reçoit la plus grande valeur jamais insérée + 1 (jamais réattribuée, comme `AUTOINCREMENT`) ; `db.insert` la rend |
| Transactions | `await db.transaction([...])` part en **une seule requête** `BEGIN; …; COMMIT` : atomique, et elle ne croise aucune autre connexion (le serveur traite une requête à la fois) |
| Verrous | le serveur ne fait pas attendre : hors transaction, une instruction refusée (`LockError`) est réessayée jusqu'à `lock_timeout` |
| Erreurs | `IntegrityError` (NOT NULL, UNIQUE, clé étrangère, CHECK), `TransactionError`, `ConnectionError` (réseau, authentification), `QueryError` (le reste) ; le type d'origine est entre crochets dans le message |

## Différences avec SQLite et PostgreSQL

| Sujet | ALEX DB | Que faire |
|---|---|---|
| DDL (`CREATE TABLE`, `CREATE INDEX`, `ALTER`) | réservé aux super-utilisateurs | migrations avec un compte super-utilisateur (`alweb migrate` avec une URL d'administration, puis l'application avec un compte ordinaire et `database.migrate: false`) |
| Index et clés | une colonne par index, par clé primaire et par clé étrangère | `orm.index(nom, table, [colonnes])` : sur ALEX DB, l'index porte sur la première colonne |
| `ON CONFLICT`, `RETURNING`, séquences | absents | l'ORM et les magasins d'alweb s'en passent (clés automatiques, transactions d'un bloc) |
| Booléens de l'ORM | rangés en `INT` 0 / 1, comme avec SQLite | rien : l'ORM convertit ; en SQL brut, comparer à 1 / 0 |
| Dates | pas de type date | `orm.timestamp()` : secondes depuis 1970 en `FLOAT` |
| `LIKE` | sensible à la casse (comme PostgreSQL) | `LOWER(col) LIKE ?` |
| `NULL` en ordre décroissant | en dernier (comme SQLite) | `NULLS FIRST` si besoin |
| Chiffrement | pas de TLS | serveur sur 127.0.0.1, ou derrière un tunnel chiffré (WireGuard, SSH) |

Le reste du SQL de l'ORM (`WHERE`, `IN`, `LIKE`, `ORDER BY`, `LIMIT` / `OFFSET`, `COUNT`, clés étrangères,
`ALTER TABLE ADD COLUMN`) est le même sur les trois bases ; le DDL est transactionnel, donc une migration ratée
ne laisse rien derrière elle.

## Module `alweb.alexdb`

```al
use alweb.alexdb as axdb

axdb.is_url(url)                      # vrai pour alexdb://
axdb.parse(url)                       # {host, port, user, password, database, timeout, lock_timeout}
axdb.redact(url)                      # sans le mot de passe (journaux)
axdb.with_database(url, "autre")      # même serveur et mêmes identifiants, autre base
await axdb.ensure_database(url)       # CREATE DATABASE IF NOT EXISTS (super-utilisateur)
axdb.check(url)                       # null si le serveur répond, sinon le message d'erreur

srv := axdb.Server("/chemin/AlexDB")  # serveur jetable (tests, démonstrations) : dossier temporaire, port libre
url := srv.start("monsite_test")      # URL d'une base créée pour l'occasion
srv.reset_database("monsite_test")    # vide
srv.stop()                            # arrêt et suppression du dossier
```

## Tests

`alweb.testing.alexdb_database(nom)` rend l'URL d'une base vide sur le serveur des tests (`ALWEB_TEST_ALEXDB`, URL
d'un super-utilisateur), ou `null` sans cette variable : un test peut ainsi tourner sur SQLite par défaut et sur
ALEX DB à la demande.

```sh
ALWEB_ALEXDB_HOME=../AlexDB tools/test_alexdb.sh          # toute la suite d'alweb sur un serveur ALEX DB jetable
ALWEB_ALEXDB_HOME=../AlexDB alexc test tests/test_alexdb.al
```

`tests/test_alexdb.al` couvre le pilote (URL, identifiants, erreurs, verrous, transactions d'un bloc), l'ORM et
les migrations, les sessions, les limites et les salons partagés ; avec `tools/test_alexdb.sh`, l'ORM, les
limites, les salons, le blog, la messagerie et les ouvriers multiples tournent aussi sur ALEX DB.

## Production

* Un seul serveur ALEX DB par application (le moteur est mono-fil : il sert les requêtes une à une). Il est plus
  lent que SQLite (3 à 10 fois selon l'opération, `bench/RESULTS.md`) : servez-le compilé en natif
  (`alexc build --native alexdb.al -o alexdb`), qui gagne encore 30 à 40 %.
* `alexdb backup create` pour les sauvegardes cohérentes, `alexdb diagnostics` pour l'état.
* ALEX DB n'est pas encore validé pour des données critiques (voir sa matrice de couverture) : sauvegardez.
