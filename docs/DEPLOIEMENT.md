# Déployer une application alweb

Ce guide met en production un projet créé par `alweb new` (le blog du [tutoriel](TUTORIEL_BLOG.md) sert
d'exemple). L'architecture recommandée :

```
Internet ──HTTPS, HTTP/2──> Caddy ou nginx ──HTTP──> alweb (127.0.0.1:8000, un processus par cœur) ──> SQLite ou PostgreSQL
```

Le mandataire termine TLS, compresse, sert éventuellement `static/` et transmet WebSocket et SSE ; l'application
n'écoute que sur la boucle locale.

`alweb deploy` écrit les fichiers dans `deploy/` du projet, à relire et versionner :

```sh
alweb deploy systemd caddy --domaine blog.example.org            # ou nginx, docker, tout
alweb deploy tout --domaine blog.example.org --dossier /srv/blog --port 8000 --utilisateur blog --alex /usr/local/bin/alex
```

| Cible | Fichiers |
|---|---|
| `systemd` | `deploy/<nom>.service` (service durci), `deploy/env.exemple` (variables, avec une clé tirée au hasard) |
| `caddy` | `deploy/Caddyfile` (HTTPS automatique, `static/` servi par Caddy, SSE sans tampon) |
| `nginx` | `deploy/<nom>.conf` (redirection HTTP→HTTPS, HTTP/2, WebSocket, SSE, `static/`) |
| `docker` | `deploy/Dockerfile`, `deploy/compose.yaml` (application et Caddy), `.dockerignore` à la racine |

Un fichier existant n'est pas écrasé sans `--force`.

## 1. Avant de déployer

* `alweb test` et `alweb check` passent.
* **La clé secrète** signe les sessions, les jetons CSRF et les jetons JWT. En production elle vient de
  l'environnement (`ALWEB_SECRET_KEY`), jamais d'un fichier versionné. `alweb secret` en tire une. La changer
  déconnecte tout le monde.
* `config/prod.json` (créé par `alweb new`) :

  ```json
  {"journal": "json", "server": {"host": "127.0.0.1", "workers": 0, "trusted_proxies": ["127.0.0.1", "::1"]}}
  ```

  `workers: 0` lance un processus par cœur ; `trusted_proxies` dit de qui croire l'en-tête `X-Forwarded-For`
  (voir § 6). Toute clé se remplace par une variable : `ALWEB_SERVER__WORKERS=4`, `ALWEB_DATABASE__URL=...`.
* Le profil `prod` n'a pas le mode debug : une erreur 500 ne montre pas la pile au visiteur (elle est dans le
  journal).

## 2. Un serveur Linux avec systemd

Sur le serveur (Debian, Ubuntu…) :

```sh
# ALEX 1.4.0 ou plus récent (archive des versions publiées, ou de `make package` dans le dépôt d'ALEX)
tar -xzf alex-1.4.0-linux-x86_64.tar.gz && sudo sh alex-1.4.0-linux-x86_64/install.sh /usr/local
sudo apt install libsqlite3-0                       # SQLite (chargé par ALEX à l'exécution)

# un compte système et le dossier de l'application
sudo useradd --system --home-dir /srv/blog --shell /usr/sbin/nologin blog
sudo mkdir -p /srv/blog && sudo chown blog:blog /srv/blog
```

Copiez le projet (sans `alex_packages/`, `build/`, `*.db`), puis installez ses dépendances sur place :

```sh
rsync -a --exclude alex_packages --exclude build --exclude '*.db' --exclude .env ./ serveur:/srv/blog/
ssh serveur 'cd /srv/blog && sudo -u blog alex pkg install --locked'
```

`--locked` installe exactement les versions de `alex.lock` (versionnez ce fichier). Avec une dépendance alweb par
dossier local (`path = ...`), copiez aussi ce dossier sur le serveur au même chemin relatif, ou publiez alweb dans
un registre (`alexc pkg publish` depuis `alweb/`, puis `alweb = "^0.9.0"`).

Les secrets :

```sh
sudo -u blog cp /srv/blog/deploy/env.exemple /srv/blog/.env
sudo chmod 600 /srv/blog/.env                       # ALWEB_SECRET_KEY=..., éventuellement ALWEB_DATABASE__URL=...
```

Le service :

```sh
sudo cp /srv/blog/deploy/blog.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now blog
systemctl status blog
curl -s http://127.0.0.1:8000/sante                # {"statut":"ok","application":"Blog"}
journalctl -u blog -f                               # une ligne JSON par requête
```

Ce que fait l'unité générée :

* `ALWEB_ENV=prod`, `EnvironmentFile=/srv/blog/.env`, `WorkingDirectory=/srv/blog` (la base `sqlite:blog.db` y
  est créée) ;
* arrêt par `SIGTERM` : les requêtes en cours se terminent, puis les fonctions d'arrêt ferment la base
  (`TimeoutStopSec=20`) ; redémarrage automatique en cas d'échec ;
* durcissement : système de fichiers en lecture seule sauf `/srv/blog` (`ProtectSystem=strict`,
  `ReadWritePaths`), pas d'élévation de privilèges, `/tmp` privé.

## 3. Le mandataire inverse

### Caddy (le plus simple)

```sh
sudo apt install caddy
sudo cp /srv/blog/deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy obtient et renouvelle seul le certificat (ports 80 et 443 ouverts, DNS du domaine vers le serveur), parle
HTTP/2 et HTTP/3 aux navigateurs, transmet WebSocket et SSE. Le `Caddyfile` généré sert `static/` directement et
compresse les réponses.

### nginx

```sh
sudo cp /srv/blog/deploy/blog.conf /etc/nginx/sites-available/
sudo ln -s ../sites-available/blog.conf /etc/nginx/sites-enabled/
sudo certbot --nginx -d blog.example.org
sudo nginx -t && sudo systemctl reload nginx
```

La configuration générée redirige HTTP vers HTTPS, active HTTP/2, transmet `Upgrade` (WebSocket), coupe la mise en
tampon (`proxy_buffering off`, indispensable au SSE), garde des connexions ouvertes vers l'application
(`keepalive`) et sert `static/` (avec `gzip_static` : les fichiers `.gz` posés à côté sont envoyés tels quels).
Ajustez `client_max_body_size` à vos téléversements.

### Sans mandataire

alweb sait servir HTTPS et HTTP/2 lui-même, y compris l'exécutable natif (TLS 1.3 écrit en ALEX, sans OpenSSL).
Sans toucher au code, par la configuration :

```json
{"server": {"tls": {"cert": "/etc/letsencrypt/live/blog.example.org/fullchain.pem",
                    "key": "/etc/letsencrypt/live/blog.example.org/privkey.pem"}}}
```

(ou `ALWEB_SERVER__TLS__CERT=…` et `ALWEB_SERVER__TLS__KEY=…`). `run` et `run_workers` servent alors HTTPS ;
HTTP/2 est proposé par ALPN (`"http2": false` pour l'interdire). Un certificat renouvelé sur le disque (certbot)
est relu à la connexion suivante, sans redémarrage. Pour écouter sur 443 sans être root, donnez la capacité au
service : `AmbientCapabilities=CAP_NET_BIND_SERVICE` dans l'unité systemd. Le mandataire reste utile pour la
redirection HTTP → HTTPS, la compression et plusieurs sites sur une même adresse.

#### Certificat Let's Encrypt automatique (ACME)

Sans certbot : alweb obtient lui-même son certificat auprès de Let's Encrypt (protocole ACME, RFC 8555, défi
`http-01`) et le renouvelle, y compris l'exécutable natif. Le nom doit pointer (DNS) vers le serveur et le port 80
lui parvenir :

```json
{"server": {"host": "0.0.0.0", "port": 443,
            "tls": {"acme": {"domains": ["blog.example.org", "www.blog.example.org"],
                             "email": "admin@example.org", "agree_tos": true}}}}
```

`agree_tos: true` vaut acceptation des [conditions de Let's Encrypt](https://letsencrypt.org/repository/) (requis).
Au premier démarrage, un certificat d'attente auto-signé permet au serveur de démarrer ; le vrai le remplace
quelques secondes plus tard, sans redémarrage. alweb écoute sur le port 80 : il y sert les jetons de défi
(`/.well-known/acme-challenge/…`) et redirige tout le reste vers HTTPS (`"redirect": false` pour ne servir que les
défis). Avec `run_workers`, c'est le processus maître qui écoute sur 80 et renouvelle ; les ouvriers relisent le
certificat sur le disque. Vérification au démarrage puis toutes les 12 heures ; renouvellement à 30 jours de
l'expiration (`renew_days`), ou au dernier tiers de la durée de vie pour un certificat court ; après un échec,
nouvel essai 5 min, 15 min, 1 h, puis toutes les 6 h. Le journal du service le dit (`alweb acme : …`).

| Clé de `server.tls.acme` | Défaut | Rôle |
|---|---|---|
| `domains` | — | noms couverts (pas de joker : il faudrait le défi DNS) |
| `agree_tos` | — | `true` requis |
| `email` | aucun | contact pour les avis d'expiration |
| `directory` | `letsencrypt` | `staging` pour les essais (limites de débit larges, certificat non reconnu), ou l'URL d'un autre annuaire ACME |
| `dir` | `acme` | clé de compte (`account.key`), certificats (`<nom>/cert.pem`, `key.pem`, droits 600), défis |
| `http_port`, `http_host` | 80, adresse du serveur | écoute des défis et de la redirection |
| `renew_days` | 30 | marge de renouvellement |
| `ca_file` | système | autorité pour joindre l'annuaire (bancs de test) |

`server.tls.cert` / `key` peuvent fixer les chemins des fichiers. Pour les ports 80 et 443 sans root :
`AmbientCapabilities=CAP_NET_BIND_SERVICE`. Essayez d'abord avec `"directory": "staging"` : les limites de
Let's Encrypt en production sont strictes (5 échecs de validation par heure et par nom). Un banc local complet
(Pebble, l'autorité de test de Let's Encrypt) sert aux tests : `tools/banc_acme.sh`.

Implémentation ALEX (choisie d'office quand OpenSSL manque, ou avec `ALEX_TLS=alex`) : TLS 1.3 seulement (les
clients TLS 1.2 reçoivent l'alerte `protocol_version` : tous les navigateurs actuels parlent 1.3), clés EC P-256 /
P-384 ou RSA de 2048 bits au moins (pas d'Ed25519). Les poignées de main n'arrêtent
pas le serveur : la boucle les fait avancer sans attendre le client, et leur calcul (environ 4 ms avec une clé
P-256, 40 ms en RSA) part sur un fil (`thread.offload`, un par cœur). Un client qui revient reprend sa session par ticket, sans signature : les tickets sont chiffrés sous une clé
tirée de la clé privée, donc valables pour tous les ouvriers et après un redémarrage (`ALEX_TLS_TICKET_KEY` pour
la fixer à part ; un nouveau certificat avec une nouvelle clé les invalide). Une clé EC reste trois fois moins chère
(`certbot --key-type ecdsa`).

## 4. Docker

```sh
alweb deploy docker --domaine blog.example.org
alexc pkg install                                   # alex_packages/ entre dans l'image
docker build -f deploy/Dockerfile --build-arg ALEX_DIST_URL=https://.../alex-1.3.0-linux-x86_64.tar.gz -t blog .
docker run -d -p 8000:8000 -e ALWEB_SECRET_KEY=$(alweb secret) -v blog-donnees:/donnees --name blog blog
```

L'image (Debian slim) installe ALEX depuis l'archive donnée par `ALEX_DIST_URL`, tourne sous un compte sans
privilèges, vérifie le code à la construction (`alex check`), range la base SQLite dans le volume `/donnees` et
déclare un `HEALTHCHECK` sur `/sante`. Le `.dockerignore` écarte bases locales, `.env` et caches.

Avec Caddy devant (HTTPS automatique) :

```sh
ALEX_DIST_URL=https://.../alex-1.3.0-linux-x86_64.tar.gz ALWEB_SECRET_KEY=$(alweb secret) \
  docker compose -f deploy/compose.yaml up -d --build
```

Dans Compose, l'application n'est joignable que par Caddy, sur le réseau interne ; elle croit les en-têtes
`X-Forwarded-For` venant des adresses `172.*` et `10.*` (`ALWEB_SERVER__TRUSTED_PROXIES`).

## 5. La base de données

**SQLite** convient à un site modeste : un fichier, rien à administrer, plusieurs processus qui lisent en même
temps (les écritures attendent leur tour jusqu'à 5 s). Sauvegarde à chaud :

```sh
sqlite3 /srv/blog/blog.db ".backup '/sauvegardes/blog-$(date +%F).db'"
```

**PostgreSQL** dès qu'il y a beaucoup d'écritures, plusieurs serveurs, ou un exécutable natif :

```sh
sudo -u postgres createuser --pwprompt blog && sudo -u postgres createdb -O blog blog
echo 'ALWEB_DATABASE__URL=postgres://blog:motdepasse@127.0.0.1:5432/blog' | sudo tee -a /srv/blog/.env
sudo systemctl restart blog
```

Le pilote parle SCRAM-SHA-256 et TLS (`?sslmode=require`). Sauvegarde : `pg_dump -Fc blog > blog.dump`.

**Migrations.** Elles s'appliquent au démarrage de chaque processus (une seule fois grâce à la table
`alweb_migrations`, chacune dans une transaction). Pour les contrôler pendant une mise à jour, mettez
`ALWEB_DATABASE__MIGRATE=false` dans `.env` et lancez-les vous-même :

```sh
cd /srv/blog
sudo -u blog sh -c 'set -a; . ./.env; ALWEB_ENV=prod alex run alex_packages/alweb/commande.al -- migrate --status'
sudo -u blog sh -c 'set -a; . ./.env; ALWEB_ENV=prod alex run alex_packages/alweb/commande.al -- migrate'
```

Sur le serveur, la commande `alweb` est celle du paquet installé (`alex_packages/alweb/commande.al`) : inutile d'y
copier le dépôt d'alweb.

## 6. Adresse réelle des clients

Derrière un mandataire, chaque connexion vient de `127.0.0.1`. alweb lit alors l'adresse d'origine dans
`X-Forwarded-For` (et le schéma dans `X-Forwarded-Proto`), **mais seulement** si le pair direct figure dans
`server.trusted_proxies` : sinon n'importe quel client pourrait se faire passer pour un autre. C'est cette
adresse qu'utilisent les journaux (`"ip"`) et les limites de débit (`ratelimit.by_ip()`).

| Situation | `server.trusted_proxies` |
|---|---|
| mandataire sur la même machine (systemd + Caddy / nginx) | `["127.0.0.1", "::1"]` (défaut de `config/prod.json`) |
| Docker Compose, Kubernetes | préfixes du réseau interne : `["172.", "10."]` |
| répartiteur de charge d'un hébergeur | ses adresses, ou ses préfixes documentés |
| aucun mandataire | ne pas définir la clé |

Les préfixes s'écrivent comme dans `web.server` : une IP exacte, un préfixe terminé par un point (`"10."`), ou
`"*"` (tout pair : seulement si l'application n'est joignable que par le mandataire).

## 7. Plusieurs processus et plusieurs serveurs

* `server.workers` règle le nombre de processus (0 : un par cœur). Ils partagent le port ; rien n'est partagé en
  mémoire entre eux.
* Ce qui doit être commun passe par la base : sessions (`sessions.DatabaseStore(db)`, ou le cookie signé par
  défaut, qui n'a besoin de rien), limites de débit (`rl.DatabaseStore(db)`), salons temps réel
  (`rt.Hub(rt.DatabaseBroker(db))`).
* Sur plusieurs serveurs : PostgreSQL, la même `ALWEB_SECRET_KEY` partout, et un répartiteur devant. Les
  fichiers téléversés vont alors dans un stockage commun : S3 (`ALWEB_STORAGE__URL=s3://…`), pas le disque d'un
  seul serveur ([guide](FICHIERS.md)).

## 8. Exécutable autonome ou natif

```sh
alweb build                 # dist/blog : la VM et le bytecode en un fichier (environ 5 Mo), SQLite disponible
alweb build --native        # binaire natif (environ 15 Mo) : plus rapide, sans SQLite, HTTPS par server.tls
```

L'exécutable se lance depuis la racine du projet (il y lit `config/`, `templates/`, `static/`) ou avec
`ALWEB_ROOT=/srv/blog`. L'autonome n'a besoin ni d'ALEX ni d'`alex_packages/` sur le serveur (seulement de
`libsqlite3` pour SQLite) : dans l'unité systemd, remplacez `ExecStart` par `ExecStart=/srv/blog/dist/blog`. Il
doit être construit sur la même plateforme que le serveur (Linux x86-64 pour Linux x86-64). Le natif exige ALEX DB
ou PostgreSQL (`ALWEB_DATABASE__URL=…`) ; il sert HTTPS lui-même (`server.tls`, ci-dessus) ou derrière un mandataire.
Si l'application fait des vignettes (`alweb.images`), `alweb build` produit aussi `dist/alweb-vignette` :
copiez-le à côté de l'exécutable.

## 9. Mettre à jour

```sh
rsync -a --exclude alex_packages --exclude build --exclude '*.db' --exclude .env ./ serveur:/srv/blog/
ssh serveur 'cd /srv/blog && sudo -u blog alex pkg install --locked && sudo systemctl restart blog'
```

Le redémarrage coupe le service une ou deux secondes (les requêtes en cours se terminent d'abord). Avec Docker :
`docker compose -f deploy/compose.yaml up -d --build`.

## Liste de vérification

- [ ] `ALWEB_SECRET_KEY` dans `.env` (droits 600) ou dans l'environnement du conteneur, jamais dans le dépôt
- [ ] `ALWEB_ENV=prod` (pas de mode debug, journal JSON)
- [ ] courriels : `ALWEB_MAIL__URL` (SMTP) et `ALWEB_SITE_URL` (liens), SPF et DKIM publiés pour le domaine de l'expéditeur ([guide](COURRIEL.md))
- [ ] fichiers téléversés : `ALWEB_STORAGE__URL` (dossier sauvegardé, ou S3 ; le seau n'est pas public si les fichiers sont privés)
- [ ] l'application n'écoute que sur `127.0.0.1` (ou le réseau interne des conteneurs)
- [ ] `server.trusted_proxies` correspond au mandataire réel
- [ ] HTTPS par le mandataire, HTTP redirigé (ou `server.tls.acme` : certificat et redirection par alweb)
- [ ] `/sante` surveillé ; `journalctl -u <nom>` ou `docker logs` consultés
- [ ] sauvegardes de la base programmées et **restaurées** au moins une fois
- [ ] `alex.lock` versionné, `alex pkg install --locked` sur le serveur
