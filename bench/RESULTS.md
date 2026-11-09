# Mesures — phases 0 et 1 (6 novembre 2026)

Machine : 2 cœurs partagés entre le serveur et le générateur de charge (`bench/load.go`), connexions
persistantes, 8 s par mesure après 1 s de chauffe. ALEX 1.3.0-beta (VM), un seul processus serveur. Les chiffres
absolus dépendent de la machine : comparer les lignes entre elles.

## Référence : web.server seul (`baseline_server.al`)

| Route | Clients | req/s | médiane | p99 |
|---|---|---|---|---|
| `/` texte | 1 | 1 131 | 0,59 ms | 7,47 ms |
| `/` texte | 8 | 1 652 | 2,90 ms | 14,22 ms |
| `/` texte | 32 | 1 616 | 18,53 ms | 33,62 ms |
| `/json` | 8 | 1 540 | 3,15 ms | 13,46 ms |

## Gestionnaire lent : synchrone contre async (`slow_handler_server.al`)

8 clients sur `/rapide` pendant que 8 autres appellent `/lent` (attente de 100 ms).

| | Synchrone (`time.sleep`) | Async (`await asyncio.sleep`) |
|---|---|---|
| `/rapide` | 9 req/s, médiane 816 ms | 1 052 à 1 092 req/s, médiane 5 ms |
| `/lent` | 10 req/s | 68 à 71 req/s (maximum théorique : 80) |
| `/` seul, 8 clients | 1 568 req/s | 1 596 req/s |

## Coût du framework (`alweb_server.al`, `inproc.al`)

| Configuration | Réseau, 8 clients | En mémoire, par requête |
|---|---|---|
| web.server seul | 1 633 req/s | — |
| alweb, sans intergiciel | 1 608 à 1 639 req/s | 180 µs |
| alweb, 1 intergiciel async vide | — | 260 µs |
| alweb, request_id + timing + security_headers | 878 req/s, p99 21 ms | 449 µs (871 µs avant optimisation) |

Historique de la ligne « 3 intergiciels » : 658 req/s (premier prototype) → 746 (security_headers sans
revalidation) → 813 avec p99 à 135 ms (boucle qui cède la main tant que des tâches avancent ; pics dus au
ramasse-miettes) → 878 avec p99 à 21 ms (correctif 0002 : fuite de la file des tâches prêtes du runtime).

À retenir : une route alweb sans intergiciel ne coûte rien de plus que web.server. Chaque intergiciel async coûte
encore de 80 à 170 µs par requête : cible de la phase 5.

## Fuite mémoire du runtime (correctif 0002, `inproc.al` / `_leak.al`)

| Mesure (objets retenus après ramasse-miettes) | Avant | Après |
|---|---|---|
| Par tâche async attendue | 5,0 | 0,04 |
| Par requête alweb avec 1 intergiciel async | 87 | 0,9 |
| Serveur, 3 intergiciels, après ~5 000 requêtes | 1 034 055 objets vivants | 109 909 (stable) |

## Plusieurs processus (`workers_server.al`, 16 clients)

| Ouvriers | req/s | médiane |
|---|---|---|
| 1 | 1 646 | 10,0 ms |
| 2 | 2 693 | 4,2 ms |

Les 2 cœurs sont partagés avec le générateur de charge : le gain réel sur une machine dédiée est plus grand.

## WebSocket (`ws_rtt.al`, écho)

| Version | Aller-retour moyen | Pire |
|---|---|---|
| Sessions qui sondent leur socket (1 à 20 ms) | 22 ms | 39 ms |
| Sessions réveillées par la boucle du serveur | 0,19 ms | 9,8 ms |

## Gabarits (phase 3)

`alexc run bench/templates.al` : page avec héritage, boucle et échappement, environ 80 µs par ligne de tableau
rendue (un seul cœur). Interprété à chaque rendu (arbre analysé mis en cache) ; la compilation des gabarits en
fonctions ALEX est prévue en phase 5.

## Salons temps réel (phase 4)

`alexc run bench/rooms.al` : 10 clients WebSocket dans un salon reçoivent 200 messages envoyés par un 11e (clients
sur des fils du même processus, 2 cœurs).

| Courtier | Messages publiés par seconde | Livraisons par seconde |
|---|---|---|
| `MemoryBroker` (un processus) | environ 975 | environ 9 700 |
| `DatabaseBroker` sur SQLite (plusieurs processus) | environ 290 | environ 2 900 |

En mode partagé, chaque message est une ligne insérée puis relue (toutes les 50 ms) : le débit est celui de la
base, et la latence ajoutée est au plus l'intervalle de relève.

## Phase 5 : chemin d'une requête, natif, statique, gabarits (7 novembre 2026)

Même machine et même générateur (8 clients, 6 s, deux passes ; plage des deux passes). Les 2 cœurs sont partagés
entre le serveur et le générateur de charge.

| Serveur | `/` texte | `/json` | p99 |
|---|---|---|---|
| web.server seul, VM — référence P0 | 1 652 | 1 540 | 14 ms |
| web.server seul, VM (correctif 0009) | 2 175 à 2 356 | 1 751 à 2 116 | 14 ms |
| web.server seul, **natif** | 2 974 à 3 350 | 3 053 à 3 472 | 6 à 7 ms |
| alweb sans intergiciel, VM | 1 988 à 2 146 | 1 811 à 1 912 | 19 ms |
| alweb sans intergiciel, **natif** | 2 548 à 2 694 | 2 193 à 2 263 | 7 à 9 ms |
| alweb, 3 intergiciels, VM (878 en phase 1) | 1 680 à 1 684 | 1 611 à 1 658 | 17 à 21 ms |
| alweb, 3 intergiciels, **natif** | 2 296 à 2 418 | 2 020 à 2 222 | 7 à 10 ms |

D'où vient le gain en VM (profil `alexc run --profile`, chemin d'une requête) :

- **validations mémorisées** (correctif 0009) : chaque valeur d'en-tête était revérifiée caractère par caractère, à
  chaque requête ;
- **noms d'en-têtes rangés en minuscules** : plus de `string.lower` par comparaison ;
- **`Headers.set` sur place** et Date recalculée une fois par seconde ;
- **intergiciels en hooks** (`alweb.hook`) : request_id, timing, security_headers, logger et cors ne créent plus de
  tâche async ; une chaîne de hooks autour d'une route synchrone reste synchrone.

Mesure du chemin profilé : 12 ms → 6,7 ms par requête (sous profileur, qui double les temps).

| Autre mesure | Avant | Après |
|---|---|---|
| Gabarit, une ligne de tableau (`bench/templates.al`, 500 lignes) | 85 µs (VM) | 50 µs (VM), 30 µs (natif) |
| Fichier de 50 Mo en local (`app.static`) | 18 Mo/s, boucle bloquée pendant l'envoi | environ 140 Mo/s, envoi en arrière-plan |
| Requête courte pendant l'envoi d'un gros fichier à un client lent | 1,2 s | moins de 0,5 s |
| Lecture de 64 Kio (`io.read_bytes` + `byte_pack` → `io.read_raw`) | 2,4 ms | 0,13 ms |
| PBKDF2-SHA256, 600 000 itérations, natif (sans OpenSSL) | plus de 10 min (repli en Alex) | 2,2 s (0,2 s en VM avec OpenSSL) |

HTTP/2 : h2spec 2.6 passe 146 tests sur 146 sur TLS (ALPN h2), 145 sur 146 en clair : sur un port partagé avec
HTTP/1.1, une « préface » qui ne commence pas par `PRI` est traitée comme une requête HTTP/1.1.

## Phase 7 : ALEX DB comme base (`bases.al`, 7 novembre 2026)

Conteneur Linux x86-64, 2 cœurs ; client alweb dans la VM, à travers `database.async_database` et l'ORM ; table de
300 lignes ; ALEX DB en `synchronous = full` (fsync du journal à chaque COMMIT) sur 127.0.0.1.

| Opération (par appel) | SQLite (fichier) | ALEX DB 0.8.0, serveur VM | ALEX DB 0.9.0, serveur VM | ALEX DB 0.9.0, serveur natif |
|---|---|---|---|---|
| insertion (ORM) | 2,1 ms | 34,6 ms | 15,1 ms | 11,3 ms |
| lecture par clé | 0,9 ms | 22,4 ms | 3,7 ms | 2,5 ms |
| page de 20 avec total (2 requêtes) | 2,7 ms | 107,8 ms | 50,4 ms | 30,0 ms |
| transaction de 2 UPDATE (un bloc) | 2,1 ms | 25,8 ms | 8,8 ms | 6,4 ms |

La 0.8.0 attendait jusqu'à 20 ms une connexion entrante à chaque tour de boucle, puis 1 ms par client : la 0.9.0
attend sur tous les sockets à la fois (`network.socket.wait`) et sert une requête dès son arrivée. Ce qui reste
est le calcul du moteur (lecture séquentielle et tri pour la page, fsync pour les écritures) : SQLite garde 3 à
10 fois d'avance. Pour une application, servir ALEX DB en natif (`alexc build --native alexdb.al`).

## Phase 8 : HTTPS natif, TLS 1.3 en ALEX (8 novembre 2026)

Conteneur Linux x86-64, 2 cœurs. Primitives en natif (`bench` du correctif 0019) : avant = modules `crypto` en
Alex dynamique (correctifs 0017, 0018), après = calcul dans le runtime typé (`_native_tls`, `crypto.accel`).

| Primitive (natif) | Alex dynamique | Runtime | Gain |
|---|---|---|---|
| X25519 (une multiplication scalaire) | 120 ms | 2,6 ms | × 46 |
| P-256 : clé éphémère / ECDH | 135 / 162 ms | 2,4 / 2,3 ms | × 56 / × 70 |
| Signature ECDSA P-256 | 214 ms | 3,6 ms | × 59 |
| Signature RSA-2048 PSS | plus de 1 s | 34 ms | — |
| AES-128-GCM, enregistrement de 16 Kio | 84 ms (0,2 Mo/s) | 1,6 ms (10 Mo/s) | × 52 |

Poignée de main complète (client Go `crypto/tls`, exécutable natif) : 0,7 à 3,8 s → 10 à 60 ms (certificat P-256 :
10 à 40 ms ; RSA-2048 : 50 à 60 ms). `test_tls13` (54 contrôles, poignées de main en boucle locale) : 67 s en
Alex pur (`ALEX_CRYPTO_ACCEL=0`), 2,5 s en VM, 1,2 s en natif.

Application alweb native (`app.run`, un processus, `server.tls` dans la configuration, certificat P-256),
`go run bench/load.go -k` :

| Charge | Débit | p50 | p99 |
|---|---|---|---|
| HTTPS keep-alive, c = 8 | 1 856 req/s | 4,3 ms | 9,7 ms |
| HTTPS, nouvelle connexion par requête (`-new`), c = 8 | 85 req/s | 89 ms | 163 ms |

La poignée de main (≈ 12 ms de calcul) se fait dans la boucle du serveur, comme avec OpenSSL : avec `run_workers`,
chaque cœur en traite environ 85 par seconde.

**Latence TLS (tous moteurs).** `web.server` ne posait pas `TCP_NODELAY` : une réponse écrite en deux fois
(tickets de session d'OpenSSL puis réponse ; trames HTTP/2) attendait l'accusé de réception retardé du client.
Requête HTTPS isolée (`curl`, VM) : OpenSSL 45 ms → 5 ms ; TLS ALEX h2 50 ms → 13 ms (HTTP en clair : < 1 ms,
inchangé).

### Poignées de main hors de la boucle (correctif 0020)

Même application native (`app.run`, un processus, 2 cœurs), `bench/load.go -k`. « Mêlé » : 4 clients ouvrent
une connexion par requête (`-new`) pendant que 2 clients keep-alive interrogent le serveur.

| Mesure | Clé | Calcul dans la boucle | Calcul sur un fil (`thread.offload`) |
|---|---|---|---|
| Poignées de main seules, c = 4 | RSA-2048 | 22/s, p50 180 ms | 40/s, p50 97 ms |
| Keep-alive mêlé, c = 2 | RSA-2048 | 20 req/s, p50 105 ms | 746 req/s, p50 1,3 ms |
| Poignées de main seules, c = 4 | P-256 | 79/s, p50 49 ms | 135/s, p50 29 ms |
| Keep-alive mêlé, c = 2 | P-256 | 74 req/s, p50 27 ms | 819 req/s, p50 1,7 ms |

Dans le mélange RSA, les nouvelles connexions gardent une queue longue (p99 1,9 s) : les deux cœurs sont saturés
(générateur de charge compris) et le trafic établi passe d'abord. Un client qui envoie le début d'un ClientHello
puis se tait faisait attendre toutes les autres connexions jusqu'à sa sortie (3,6 s dans le test) ; il n'en
retarde plus aucune.

Correctif 0021 : même comportement avec OpenSSL (VM). Le test `test_client_muet_ne_bloque_pas` mesure 3,5 s
d'attente pour une requête quand OpenSSL mène la poignée de main d'un client muet de façon bloquante, et la sert
aussitôt en mode pas à pas.

### Calcul de la poignée de main (correctif 0022)

| Mesure (natif) | Avant | Après |
|---|---|---|
| X25519 (base 2^25,5, forme de ref10) | 2,6 ms | 0,21 ms |
| Multiplication de points P-256 (Montgomery déroulé) | 2,05 ms | 0,82 ms |
| Signature ECDSA P-256 (`ecdsa_sign`) | 2,3 ms | 1,4 ms |
| `server_flight` (transcript en `str`) | 4,8 ms | 3,5 ms |
| Poignées de main P-256 / s, calcul dans la boucle | 79 | 185 |
| Poignées de main P-256 / s, calcul sur un fil | 135 | 235 |

Keep-alive mêlé (c = 2, avec 4 clients `-new`) : 538 req/s, p50 3,1 ms (le serveur traite 75 % de poignées de main
de plus qu'avant sur les mêmes deux cœurs). Ce qui reste en Alex dans une poignée de main : le nonce de la RFC 6979
(≈ 0,6 ms) et la mécanique des messages.

### Reprise de session (correctif 0023)

Application alweb native, un processus, calcul sur un fil, `bench/load.go -k -new` (une connexion par requête),
avec ou sans `-resume` (cache de sessions de Go : chaque connexion reprend par ticket).

| Clé | Poignées de main complètes | Reprises |
|---|---|---|
| RSA-2048 | 39 req/s, p50 100 ms | 263 req/s, p50 14 ms |
| P-256 | 206 req/s, p50 19 ms | 279 req/s, p50 14 ms |

Python `ssl` (VM, clé RSA) : poignée de main complète 101 ms, reprise 3 à 6 ms.

### OpenSSL : contexte partagé (correctif 0024)

VM, moteur OpenSSL, application alweb (`app.run`, un processus), clé RSA-2048, `bench/load.go -k -new`
(une connexion par requête), c = 4 :

| Chemin | Poignées de main complètes | Avec `-resume` |
|---|---|---|
| Un `SSL_CTX` par connexion (avant) | 355 req/s, p50 9,9 ms | 356 req/s (aucune reprise) |
| `SSL_CTX` partagé (après) | 585 req/s, p50 5,7 ms | 745 req/s, p50 4,2 ms |

Avec deux ouvriers (`run_workers`), 19 connexions sur 20 reprennent (clés de tickets communes), avec OpenSSL
comme avec le TLS ALEX ; un certificat remplacé sur le disque est servi dès la connexion suivante.
