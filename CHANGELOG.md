# Journal des versions d'alweb

## Non publié

### Ajouts

* **Modèles par domaine** : `alweb theme create <slug> --domaine ecommerce|blog|portfolio|business` crée un thème
  adapté (pages, composants, réglages, styles, logo, données d'aperçu, capture) ; `alweb new <nom> --domaine …`
  crée un site complet : application, tables, données d'exemple et tests du domaine, thème créé et installé
  (actif). Boutique : catalogue et rayons, fiche produit, panier en session, commande avec mise à jour du stock.
  Blog : article à la une, catégories, pagination, articles similaires. Portfolio : projets en vedette, filtre,
  fiche avec galerie. Modèles en couches (`modele-theme-<domaine>/`, `modele-<domaine>/`) ; un fichier `x.ajout`
  d'une surcouche complète `x`. Le manifeste prend la catégorie du domaine.
* **Thème branché automatiquement** : `alweb theme install` (archive, dossier ou marketplace) et
  `alweb theme activate` remplacent, une seule fois, `app.use_templates(os.join(dossier, "templates"))` par
  `themes.setup(app, null, {"root": dossier})` dans le module de l'application et ajoutent
  `use alweb.themes as themes` (`cli.wire_theme`). Si la forme n'est pas reconnue, rien n'est modifié et la
  commande dit quoi faire. Les projets créés par `alweb new` appellent `themes.setup` d'office (sans thème
  actif : gabarits de `templates/` seuls). `templates/base.html` resté identique à celui du modèle (il cacherait
  la mise en page du thème) est renommé en `base.html.sans-theme` ; un fichier modifié n'est pas touché. La page
  d'accueil du modèle prend le bandeau et la mise en page du thème quand il y en a un.
* Page « Apparence » : l'aperçu rend le site à la largeur de l'appareil (ordinateur 1 280 px, tablette 768 px,
  mobile 390 px) puis le réduit pour tenir dans le cadre ; la vue « Ordinateur » n'affiche plus la mise en
  page mobile. Modèle de thème : bouton de menu à trois traits (croix quand le menu est ouvert).

* **Essai local** (docs/ESSAI_LOCAL.md) : `sh tools/essai_local.sh` vérifie ALEX et ses correctifs, lance
  les tests rapides (`--complet` : toute la suite), puis un parcours complet dans un dossier temporaire (projet,
  thème : création, validation, archive, installation) et donne un récapitulatif. Nouvel exemple `examples/vitrine.al` : site avec le thème « Modern Business » installé au
  premier lancement, contact, et page « Apparence » de l'administration.

* **Client de marketplace de thèmes, phase 3 d'ALWEB Templates** (`alweb.themes.client`,
  `alweb.themes.signing`, docs/THEMES.md#la-marketplace). Commandes `alweb theme search [--tri]`,
  `install <slug>[@contrainte]`, `update [--verifier]`, `publish`, `keygen`, `yank`, `review`, `reviews`.
  Téléchargement vérifié : taille et SHA-256 annoncés, signature ECDSA P-256 de l'éditeur (sur l'identifiant,
  la version et l'empreinte), clé de l'éditeur épinglée dans `alweb.lock` (une clé changée est refusée sans
  `--nouvelle-cle`), manifeste cohérent avec la version demandée ; reçu d'installation gardé pour donner un
  avis ; délai indiqué quand le serveur limite le débit (429). La page Apparence vérifie les mises à jour d'un
  thème venu d'une marketplace, sans bloquer le serveur. Le serveur n'est pas fourni : le **protocole** qu'il
  doit suivre est décrit dans docs/MARKETPLACE_PROTOCOLE.md (tests du client avec une marketplace simulée).
* **Captures d'écran des thèmes** : le validateur exige des images PNG, JPEG, WebP ou GIF dans `screenshots` ;
  le modèle « Modern Business » fournit `preview/accueil.jpg`.
* `alweb.admin` : option `extensions` (pages, menu et cartes ajoutés par d'autres modules, exemple dans
  docs/ADMIN.md), méthodes `render`, `flash`, `notify`, `db_for`. Cartes du tableau de bord alignées.
* `alweb.i18n.register_messages(catalogues)` : un paquet apporte ses traductions, consultées après celles de
  l'application et avant celles d'alweb.
* `alweb theme list` affiche la provenance de chaque thème.

* **Page « Apparence » de l'administration, phase 2 d'ALWEB Templates** (`alweb.themes.panel`, option
  `appearance` d'`alweb.admin`, docs/THEMES.md). Formulaire produit depuis le schéma du thème (sections, champ
  par type, valeur du thème, réglages modifiés signalés), aperçu en direct du site dans un cadre (ordinateur,
  tablette, mobile ; variables CSS changées tout de suite, page rechargée pour le reste ; erreurs par champ).
  Brouillon gardé dans la session de la personne qui règle et appliqué à son seul cadre d'aperçu, jusqu'à
  « Enregistrer ». Enregistrement des seules valeurs changées dans `config/theme.<slug>.json` (atomique),
  historique de 20 versions avec restauration, retour aux valeurs du thème, export, logo et images envoyés
  dans `alweb.storage` (`media:`), activation d'un autre thème installé, évènements `on_change`. En anglais
  aussi.
* **Thèmes** : le fichier des choix est relu à chaud (au plus une fois par seconde) ; `Theme.save_choices`,
  `refresh`, `themes.history` ; variables `theme` et `theme_css` fournies à chaque rendu.
* `security_headers` : une page d'aperçu de thème peut s'afficher dans un cadre de même origine
  (`SAMEORIGIN`, `frame-ancestors 'self'`), les autres pages gardent `DENY`.
* Administration : le tableau de bord n'exige plus de base de données quand aucune table n'est enregistrée.

* **Thèmes installables, phase 1 d'ALWEB Templates** (`alweb.themes`, docs/THEMES.md). Un thème est un dossier
  indépendant (gabarits, composants, ressources, paramètres) décrit par `alweb-theme.json` : champs requis,
  clés inconnues refusées, versions sémantiques et contraintes (`>=`, `^`, `~`, listes). Paramètres typés
  (`config/theme.json` : couleur, taille, police, texte, booléen, nombre, choix, URL, image, liens), choix du
  projet dans `config/theme.<slug>.json` vérifiés au démarrage, variables CSS servies par `/_theme.css`.
  Validation de sécurité : aucun code ALEX ni exécutable, extensions permises seulement, liens symboliques et
  SVG avec script refusés, tailles bornées, gabarits analysés et cibles des `extends` / `include` / `import`
  présentes. Archives `.alwt` reproductibles, inspectées avant toute écriture (chemins `..`, types, tailles).
  Installation hors ligne dans `themes/<slug>/` avec `alweb.lock` (versions, empreintes, thème actif),
  dépendances et compatibilité ALWEB / ALEX vérifiées, ancienne version gardée pour `rollback`.
  `themes.setup(app)` : pages du thème, `templates/` et `components/` de l'application prioritaires,
  `asset()` (URL versionnée, cache d'un an), `theme`, `theme_css`, `theme_info`. Commande `alweb theme`
  (create, validate, package, preview, install, activate, deactivate, list, info, remove, rollback, check).
  Thème de démonstration « Modern Business » (8 pages, 5 composants, responsive, menu mobile) et aperçu en
  trois tailles (`/_apercu`) avec données de démonstration.
* **Moteur de gabarits** : plusieurs dossiers, avec préfixe (`Environment(["templates", "themes/x/templates",
  ["components/", "themes/x/components"]])`, `add_directory`, `exists`, `path_of`) ; tranches
  (`{{ articles[0:3] }}`, `{{ nom[:1] }}`, `{{ l[-2:] }}`).
* La commande `alweb` affiche les erreurs de thème et de stockage sans trace (`alweb: erreur: …`).

* **Fichiers** (`alweb.storage`, docs/FICHIERS.md). `storage.setup(app)` d'après la clé `storage.url` : dossier
  local (`file:`, défaut en debug), mémoire (`memory:`, tests), stockage compatible S3 (`s3://CLÉ:SECRET@hôte/seau
  ?region=…` : Amazon S3, MinIO, Scaleway, Backblaze B2, Cloudflare R2… ; style « path » ou « virtual » ; client
  et signature AWS V4 écrits en ALEX, vérifiés sur les exemples de la documentation d'Amazon, aussi en natif).
  `put`, `get`, `head`, `list` (pages S3 suivies), `delete` ; URL signées qui expirent (`st.url(clé, secondes,
  nom)` : présignées chez S3, route `/_fichiers/…` de l'application pour le disque) ; `public_url` ; clés
  vérifiées (pas de `..`, de chemin absolu) ; `storage.save_upload(st, fichier, {prefix, max_bytes, allowed})`.
* **Images** (`alweb.images`). `thumbnail(octets, l, h, {mode: fit | cover, format: auto | jpeg | png,
  quality})`, `info`, `store(st, fichier, {sizes: {nom: [l, h, mode]}})` : original et tailles enregistrés (retirés
  si une étape échoue), `remove`. JPEG (aussi progressif), PNG, GIF, WebP, BMP en entrée, orientation Exif
  appliquée, jamais d'agrandissement. Calcul par un programme natif écrit en ALEX (`alweb/outils/vignette.al`,
  correctif ALEX 0027 `image.encode`) lancé dans un processus à part depuis un fil : le serveur continue de
  servir, une image piégée ne le fait pas tomber, 30 s au plus par appel ; compilé au premier usage dans
  `.alweb/outils/`, produit par `alweb build` à côté de l'exécutable (`alweb-vignette`). Photo de 6 Mpx : ~1 s.
* **Blog d'exemple en vitrine des fichiers** (`examples/blog_app.al`) : photo d'article réduite en vignette
  16:9 (liste) et en grande image (article) par `alweb.images`, pièce jointe PDF réservée aux lecteurs connectés
  (lien signé de 5 minutes, nom d'origine), fichiers retirés avec l'article ou remplacés, migration
  `orm.add_column` des bases existantes ; `storage.url` dans sa configuration (`memory:` en test). Essayé de bout
  en bout dans Chromium (inscription, publication avec photo et PDF, téléchargement), bureau et mobile.
* **Liens signés stables** : d'une heure ou plus, le même lien pendant toute l'heure (disque : expiration
  arrondie ; S3 : signé au début de l'heure, valable une heure de plus), donc gardé en cache par le navigateur.
  `S3Storage.presign(clé, durée, nom, instant)` : lien présigné brut.
* `ALWEB_TEST_S3=s3://…` : `test_vrai_s3` contre un vrai stockage (MinIO, Scaleway…) ; essayé contre un serveur
  S3 lancé dans un processus à part.
* Modèle de projet : `storage.url` (`file:media` en dev, `memory:` en test), `ALWEB_STORAGE__URL` dans l'exemple
  de `.env`.
* **Textes d'alweb traduits** (`alweb.messages`). Catalogues intégrés, sous ceux de l'application (une clé de
  `locales/<langue>.json` les remplace) : erreurs de formulaire et pages d'erreur en français, anglais, espagnol,
  allemand, italien, portugais et néerlandais ; administration en français et en anglais (autre langue : clés =
  texte français). `validate_form` rédige ses messages pour le visiteur (« Au moins 3 caractères. » au lieu de
  « longueur 2 < 3 »), dans sa langue avec `alweb.i18n` (sinon en français) ; `f.codes` (code et paramètres),
  `f.details` (message du schéma) ; messages de l'ORM reconnus aussi (administration) ; `sch.custom(…, message)`
  traduit comme une clé. Avec `I18n`, pages d'erreur HTML dans la langue du visiteur (titre, explication, message
  d'`abort`, lien vers l'accueil, sans détail d'exception hors debug ; JSON inchangé pour les API), remplaçables
  par `templates/errors/<statut>.html` ou `errors/error.html` ; un `app.error_handler` passe avant.
  L'administration suit la langue de la requête (`lang`, pluriels : « 1 abandonnée », « 3 jours »).
  `i18n.translator_for(req)` : traducteur de la requête, ou français d'alweb sans `I18n`. `alweb i18n` ne
  compte pas comme manquantes les clés fournies par alweb.
* **Plusieurs langues** (`alweb.i18n`, docs/I18N.md). Catalogues `locales/<langue>.json` (les clés sont le texte
  de la langue par défaut, objets imbriqués pour les clés d'identifiant ; repli fr-CA → fr → langue par défaut
  → clé ; relus en debug, traductions manquantes signalées). Langue de chaque requête : préfixe d'URL
  (`/en/articles`, `url_for` le garde), `?lang=` (retenu en session et dans le cookie `alweb_lang`),
  préférence du compte, session, cookie, `Accept-Language` avec poids ; seules les langues proposées sont
  retenues, `Content-Language` et `Vary: Accept-Language` posés. Pluriels selon les règles CLDR (français,
  anglais, langues slaves, arabe…). Nombres, montants (symbole, position, décimales : XOF, EUR, USD, CHF…),
  pourcentages, dates (`short` à `full`, motifs, fuseau), temps relatif et listes dans la langue. Gabarits :
  `_()`, `_n()`, filtre `t`, `date`, `datetime`, `time`, `reltime`, `number`, `currency`, `percent`, `list`,
  variables `lang`, `lang_dir` (rtl) et `locales` (sélecteur de langue). Courriels : option `locale` de
  `send_template` (traductions, formats, `emails/<nom>.<langue>.txt`, `Content-Language`). `alweb i18n` :
  clés du code et des gabarits absentes des catalogues, `--update`, `--strict`. Moteur de gabarits : filtres
  propres à un rendu (clé `_filters` du contexte). Le blog du tutoriel est bilingue (français, anglais).
* **Tâches dans l'administration** (`alweb.admin`). Avec une file `alweb.jobs`, page « Tâches »
  (`/admin/_taches`) : compteurs par état (aussi sur le tableau de bord, qui signale les abandonnées), liste
  filtrée avec la dernière erreur, fiche d'une tâche (charge JSON, dates, erreur complète), « Réessayer » (une
  tâche ou toutes les abandonnées, avec de nouveaux essais) et « Supprimer » (pas une tâche en cours). CSRF et
  journal `on_change` (`job_retry`, `job_delete`) ; option `jobs` (`false`, ou rôles exigés). `queue.delete(id)`.
  Le blog du tutoriel a maintenant son administration (comptes sans mot de passe, articles, commentaires, tâches).
* **Tâches de fond** (`alweb.jobs`, docs/TACHES.md). File persistante en base (`DatabaseStore` : SQLite,
  PostgreSQL, ALEX DB ; `MemoryStore` pour les tests), partagée entre processus et serveurs : réservation
  atomique (chaque tâche n'est faite que par un processus), `@q.task(nom)`, `enqueue(nom, données, {delay, at,
  attempts, key})`, `concurrency` tâches à la fois, délai d'exécution (`timeout`), nouveaux essais espacés (30 s,
  60 s, 120 s… au plus 6 h) puis abandon gardé 7 jours avec l'erreur, reprise des tâches d'un processus mort.
  Tâches planifiées : `@q.every(nom, "30 3 * * *")` (cron à 5 champs, heure locale ou UTC) ou `every(nom, 300)`,
  une seule exécution par créneau tous processus confondus. `run` et `run_workers` font tourner la file dans
  chaque processus qui sert (`jobs.worker = false` pour ne faire que mettre en file). Avec une file,
  `mailer.send_later` / `send_template_later` y passent (tâche `alweb.mail`, pièces jointes comprises) : un
  courriel en échec est réessayé au lieu d'être perdu (`mail.queue = false` pour envoyer directement).
  `alweb jobs` : état de la file, `--retry ID|tout`, `--run`. Tests : `at.run_jobs(app)`, horloge réglable
  (`q.clock`). Vérifié avec deux ouvriers sur une même base SQLite (aucune tâche faite deux fois, une tâche
  planifiée par créneau). Blog du tutoriel : courriels par la file, rappel de confirmation le lendemain.
  `mail.site_link(app, chemin)` pour les liens écrits hors requête.
* **Courriels** (`alweb.mail`, docs/COURRIEL.md). `app.mail()` / `alweb.mailer(req)` réglé par la clé `mail` :
  SMTP par `network.smtp` (`smtp://` avec STARTTLS dès qu'il est proposé, `smtps://`, identifiants dans l'URL,
  jamais d'authentification en clair, conversation SMTP sur un fil), `console` (défaut en mode debug), `memory`
  (tests), `file:dossier` (`.eml`). `send`, `send_template` (gabarits `emails/<nom>.txt` sans échappement et
  `.html`), `send_later` (erreur journalisée, pas levée), Cc / Cci, Reply-To, en-têtes, pièces jointes ; adresses
  vérifiées (pas d'injection de destinataire ni d'en-tête), `mail.valid_address`. `mail.absolute_url(req, chemin)`
  bâtit les liens sur `site_url`, jamais sur l'en-tête `Host` en production (lien de réinitialisation détourné).
  Tests : `at.outbox(app)`, `at.links(texte)`. Vérifié contre un serveur SMTP de test (STARTTLS, AUTH PLAIN,
  transparence des points), avec OpenSSL et avec le TLS ALEX.
* **Liens à usage unique** (`alweb.auth`) : `reset_token` / `reset_token_user` / `check_reset_token` (1 h, lié à
  l'empreinte du mot de passe : ne sert qu'une fois), `confirm_token` / `read_confirm_token` (3 jours, lié à
  l'adresse), `signed_token` / `read_token` (HMAC-SHA256, usage et date dans le jeton, rien en base).
* Certificat automatique : une demande ACME en échec journalise maintenant l'erreur réelle (avant : « le futur
  n'est pas terminé avec succès »). Test : `test_echec_puis_nouvel_essai`.
* **`orm.add_column`** : colonne ajoutée par migration (`ALTER TABLE … ADD COLUMN`), sautée si elle existe déjà
  (base neuve créée avec la définition à jour).
* **Tutoriel, étape 9 : les courriels.** Le blog demande l'adresse à l'inscription et la fait confirmer par lien
  (rappel et renvoi tant qu'elle ne l'est pas), propose « mot de passe oublié » (même réponse que l'adresse soit
  connue ou non, 5 demandes par quart d'heure, lien d'une heure à usage unique) ; refuse de démarrer en production
  sans `site_url` ni `mail.url`. Modèle de projet : `mail.from`, `console` en dev, `memory` en test ;
  `deploy/env.exemple` cite `ALWEB_MAIL__URL` et `ALWEB_SITE_URL`.
* **Certificat Let's Encrypt automatique** (correctif ALEX 0026, `network.acme`, `alweb.acme`). Client ACME
  (RFC 8555) écrit en ALEX : compte (clé P-256, JWS ES256, empreinte RFC 7638), commande, défi `http-01`,
  attente polie (`Retry-After`), `badNonce` rejoué, CSR PKCS#10 (`crypto.x509.csr`), téléchargement de la
  chaîne ; `acme.issue(...)` tout en un, `acme.needs_renewal(...)`. Dans alweb, `server.tls.acme` (`domains`,
  `email`, `agree_tos`, `directory` : `letsencrypt` / `staging` / URL) suffit : certificat d'attente auto-signé
  au premier démarrage, écoute du port 80 (jetons de défi, redirection 301 vers HTTPS), demande sur un fil
  (`thread.offload`) pendant que le service continue, nouveau certificat servi sans redémarrage, vérification
  toutes les 12 heures, renouvellement à 30 jours (au dernier tiers pour un certificat court), nouvel essai
  5 min / 15 min / 1 h / 6 h après un échec. `run` le fait tourner en tâche de fond, `run_workers` dans le
  maître (service de `web.server.workers`). Rotation sûre : tant que la clé et le certificat sur le disque ne
  vont pas ensemble (remplacement en cours), l'ancien contexte TLS continue de servir, avec le TLS ALEX comme
  avec OpenSSL. Vérifié contre Pebble (l'autorité de test de Let's Encrypt) : certificat délivré en moins d'une
  seconde, en VM, dans l'exécutable natif et avec plusieurs ouvriers. Tests : `tests/test_acme.al` (de bout en
  bout avec `ALWEB_TEST_ACME`), `tests/stdlib2/test_acme.al` côté ALEX ; banc : `tools/banc_acme.sh`.
* **HTTPS dans l'exécutable natif : TLS 1.3 écrit en ALEX** (correctif ALEX 0019, `network.tls13`). Serveur et
  client TLS 1.3 (RFC 8446) : AES-128/256-GCM, ChaCha20-Poly1305, x25519 / P-256 / P-384 avec HelloRetryRequest,
  signatures ECDSA et RSA-PSS, ALPN (h2), SNI, KeyUpdate, alertes ; TLS 1.2 refusé. Choisi d'office quand
  OpenSSL manque (natif), ou avec `ALEX_TLS=alex`. `crypto.x509` (PEM, DER, clés PKCS#8 / SEC1 / PKCS#1,
  chaînes vérifiées jusqu'à une autorité, noms et jokers, dates, RSA-PSS). Le calcul lourd passe par le runtime
  typé (`_native_tls.x25519 / ec_mul / modpow / mulmod / aes_gcm`, `crypto.accel`) : X25519 120 → 2,6 ms,
  ECDSA P-256 214 → 3,6 ms, AES-GCM 0,2 → 10 Mo/s ; une poignée de main native passe de 0,7–3,8 s à 10–60 ms ;
  aussi utilisé dans la VM. Vérifié contre la RFC 8448 et en interopérabilité avec OpenSSL (`s_client`,
  `s_server`), Python `ssl`, Go `crypto/tls` et curl (HTTP/1.1 et HTTP/2).
* **Poignées de main TLS sans attente** (correctif ALEX 0020). Avec le TLS ALEX, `web.server` fait avancer chaque
  poignée de main dans sa boucle (`TlsSocket13.server_step`) au lieu de l'attendre, et le calcul (échange de
  clés, signature, premier vol chiffré : `tls13.server_flight`) part sur un fil de `thread.offload`. Un client
  muet ou lent ne fige plus le serveur (avant : jusqu'au délai de 10 s) ; pendant des poignées de main RSA, le
  trafic établi passe de 20 à 746 req/s (p50 105 → 1,3 ms) et les poignées de main elles-mêmes de 22 à 40/s sur
  2 cœurs (P-256 : 79 → 135/s). `server.tls.offload = false` garde le calcul dans la boucle.
* **Poignées de main OpenSSL sans attente aussi** (correctif ALEX 0021). Le runtime de la VM sépare
  `_native_tls.server_start` (contexte et session) et `accept_step` (un seul essai de `SSL_accept`, qui dit
  s'il faut attendre lecture ou écriture) ; `network.tls.start_server` rend une poignée de main à mener pas à
  pas, avec OpenSSL (`OpenSslAccept`) comme avec le TLS ALEX, et `web.server` s'en sert pour les deux. Un client
  muet ne fige donc plus le serveur avec OpenSSL non plus (3,5 s de blocage dans le test, 0 maintenant). Le calcul
  d'OpenSSL, déjà rapide (≈ 1 ms), reste dans la boucle. Test : `test_client_muet_ne_bloque_pas`, pour les deux
  moteurs.
* **Reprise de session TLS 1.3** (correctif ALEX 0023). Le serveur ALEX envoie un ticket (`NewSessionTicket`)
  après chaque poignée de main complète ; un client qui le redonne reprend en mode `psk_dhe_ke` (ECDHE
  conservé, donc confidentialité persistante) sans certificat ni signature. Tickets sans état, chiffrés en
  AES-256-GCM sous une clé tirée de la clé privée : valables pour tous les ouvriers et après un redémarrage,
  invalidés par un changement de clé ; `ALEX_TLS_TICKET_KEY` pour la fixer, options `tickets` et
  `ticket_lifetime` (1 jour). Binder vérifié, aussi après HelloRetryRequest ; 0-RTT toujours refusé. Côté
  client : `tls.connect(..., session=ts.session)` et `ts.resumed`. Exécutable natif, une connexion par requête :
  RSA-2048 39 → 263 req/s, P-256 206 → 279 req/s. Vérifié avec Python `ssl`, `openssl s_client -sess_in`,
  Go `crypto/tls` (cache de sessions) et contre `openssl s_server` pour le client. Test :
  `test_reprise_de_session`, pour les deux moteurs.
* **`alweb run --https`** et certificats auto-signés en ALEX (correctif ALEX 0025). `crypto.x509.self_signed`
  produit un certificat X.509 v3 de développement (clé P-256 neuve, ECDSA-SHA256, noms DNS et adresses IPv4 /
  IPv6, basicConstraints, keyUsage, extendedKeyUsage) et sa clé PKCS#8, sans outil externe ; 
  `network.certificates.generate_self_signed` s'en sert pour les clés EC (l'outil `openssl` ne reste utile que
  pour `key="rsa"`), donc aussi `web.server.tls_server.development_certificate`. `alweb run --https` crée au
  besoin `.alweb/dev-tls/localhost.pem` (et `.key`, mode 0600 ; renouvelé à moins de 30 jours de
  l'expiration) et sert le projet en HTTPS et HTTP/2. Accepté par OpenSSL (`x509 -text`, `verify`,
  `-checkhost`), Python `ssl`, Go et curl ; les suites gRPC, mail / FTP (STARTTLS) et serveur HTTP d'ALEX
  tournent désormais sur ces certificats. Test : `test_certificat_de_developpement`.
* `bin/alweb` est exécutable dans l'archive (il ne l'était pas ; `bin/alweb.cmd` l'était à tort).
* **OpenSSL : contexte partagé et reprise de session** (correctif ALEX 0024). Le runtime de la VM garde un
  `SSL_CTX` par (certificat, clé, ALPN) au lieu d'en créer un par connexion ; il est recréé quand les fichiers
  changent (certificat renouvelé servi sans redémarrage). Ses clés de tickets sont tirées de la clé privée (ou
  de `ALEX_TLS_TICKET_KEY`), donc communes à tous les ouvriers : la reprise de session fonctionne aussi avec
  OpenSSL. VM, clé RSA-2048, une connexion par requête : 355 → 585 req/s sans reprise, 745 req/s avec.
* **Poignées de main TLS ALEX 1,5 à 2 fois plus rapides** (correctif ALEX 0022). Dans le runtime : X25519 en
  base 2^25,5 (forme de ref10 : produits déroulés, carré dédié, inversion en 254 carrés et 11 produits) :
  2,6 → 0,21 ms ; produit, addition et soustraction de Montgomery déroulés pour P-256 et P-384 : multiplication
  de points 2,05 → 0,82 ms ; `_native_tls.ecdsa_sign` (r et s en un appel) : signature P-256 2,3 → 1,4 ms.
  `server_flight` tient le transcript en `str` et construit le message Certificate une fois par contexte
  (4,8 → 3,5 ms). Poignées de main P-256 sur 2 cœurs : 79 → 185/s dans la boucle, 135 → 235/s avec le fil de
  calcul. Vérifié contre OpenSSL (200 échanges X25519 aléatoires), la RFC 7748 (1 000 itérations) et la
  RFC 6979 (A.2.5).
* **HTTPS par la configuration** : `server.tls.cert` / `server.tls.key` (et `server.tls.http2`) suffisent pour que
  `app.run` et `app.run_workers` servent HTTPS et h2, sans `alweb.https` dans le code ; certificat renouvelé relu
  à la connexion suivante. `alweb build --native` ne renvoie plus vers un mandataire pour HTTPS.
* Tests : `tests/test_https.al` (3 tests) ; `test_http2` teste h2 sur TLS aussi en natif ; dans ALEX,
  `tests/stdlib2/test_tls13.al` (54 contrôles). `bench/load.go` : `-k` (HTTPS auto-signé) et `-new` (une
  poignée de main par requête). Mesures : `bench/RESULTS.md`, phase 8.

* **Base locale embarquée `alexdb+local:<dossier>`** (`alweb.alexdb_local`, docs/ALEXDB.md) : l'application lance
  son propre serveur ALEX DB. Un processus : servi par une tâche de la boucle async. `run_workers` : hébergé par le
  maître, partagé par les ouvriers. Une base commune sans service à installer, y compris dans l'exécutable natif.
  Super-utilisateur `alweb` et mot de passe aléatoire gardé dans le dossier (0600), écoute sur 127.0.0.1
  seulement, arrêt propre après les ouvriers. Demande le correctif ALEX 0016 et AlexDB avec
  `Server.create_database`.
* **Administration générée** (`alweb.admin`, `docs/ADMIN.md`) : `Admin(app, options)` et `register(table, options)`.
  Tableau de bord ; listes paginées avec recherche (OU, sans casse), filtres (booléen, clé étrangère, liste
  fermée, égalité), tri par colonne et lien vers la fiche ; création, modification, suppression confirmée ; export
  CSV des lignes filtrées. Champs selon le type de colonne, clés étrangères en listes déroulantes (table liée
  enregistrée, 500 lignes au plus) et affichées par leur nom, erreurs de l'ORM et d'unicité au champ, messages
  flash, journal d'audit `on_change`. Sécurité posée par le groupe : rôles (et rôles par table), CSRF sur chaque
  POST même sans `alweb.csrf` dans l'application, `Cache-Control: no-store`, `X-Frame-Options: DENY`, feuille de
  style servie par une route (aucun style en ligne : compatible avec la CSP de `security_headers`), colonnes
  `exclude` jamais montrées ni exportées, clé et horodatages automatiques non modifiables, cellules CSV commençant
  par `= + - @` neutralisées.
* **`Query.search(colonnes, terme)`** et `Table.search` dans l'ORM : `LOWER(col) LIKE ?` en OU.
* Le blog d'exemple a son `/admin` (comptes sans empreintes de mot de passe, articles, commentaires).
* Tests : `tests/test_admin.al` (8 tests : accès, liste, création et CSRF, modification, suppression et journal,
  export, déclarations refusées, recherche de l'ORM), `test_administration` dans le test du blog.

### Corrections

* `alweb.images` trouve le programme des vignettes depuis un sous-dossier (dossier courant et ses parents :
  `examples/` lancé directement donnait une erreur 500) ; `S3Storage.list(préfixe, limite)` ne rend jamais plus
  de `limite` clés.
* **`UploadError` -> 400** : un fichier refusé par `forms.check_upload` (type, taille) ou un formulaire trop
  volumineux donnait une erreur 500 ; c'est maintenant une réponse 400 avec le message, comme l'annonçait
  `alweb.forms`.
* **Administration** : « 1 abandonnée » au lieu de « 1 abandonnée(s) », « Au plus 60 caractères. » au lieu de
  « 60 caractères au plus » (message de l'ORM).
* **`test_chat_workers` fiable.** Il échouait parfois (« présence incohérente entre ouvriers : [2, 1] ») : chaque
  ouvrier refait la présence à partir des événements de l'autre, relus dans la base toutes les 50 ms, et le test
  prenait pour l'arrivée de bob le `join` d'une connexion de bob refusée (tombée sur l'ouvrier d'ana), puis
  regardait la présence avant que cet ouvrier ait lu le `join` de l'autre. Le test attend maintenant les
  événements du bon membre et que tous les ouvriers répondent la même présence (au plus 10 s) ; il vérifie aussi
  la présence après le départ d'ana. Reproduit puis vérifié avec un relevé ralenti à 0,4 s : l'ancien test échoue
  dès qu'une connexion est refusée, le nouveau passe 12 fois sur 12 (dont 7 avec refus).
* **Latence HTTPS** : `web.server` pose `TCP_NODELAY` sur chaque connexion acceptée. Une réponse écrite en
  plusieurs fois (tickets d'OpenSSL puis réponse, trames HTTP/2) attendait l'accusé retardé du client : 45 ms par
  requête HTTPS isolée avec OpenSSL, 5 ms maintenant.
* **`orm.migrate` sur plusieurs processus** : des ouvriers qui migrent ensemble au démarrage n'échouent plus (« clé
  primaire … déjà présente dans alweb_migrations ») ; une version appliquée entre-temps par un autre est sautée.
* **ORM sur le moteur embarqué** (correctif ALEX 0014) : les migrations échouaient sur `memory:` et
  `alexdb:fichier.json` (« attendu ')' près de 'KEY' ») parce que le moteur ne lisait pas `FOREIGN KEY`, puis pas
  `ALTER TABLE`, et `offset()` sans `limit()` rendait zéro ligne. C'est le seul moteur SQL local de l'exécutable
  natif (pas de FFI, donc pas de libsqlite3) : en natif, `test_orm` et le blog échouaient (7 tests).
* **Cache de compilation** (correctif ALEX 0015) : un module compilé avec une autre bibliothèque standard
  (`ALEX_STDLIB`, autre SDK) n'est plus repris.
* `test_partage_par_la_base` (limites) et `test_deux_processus_par_la_base` (salons) sont **ignorés** (SkipTest)
  quand SQLite manque, au lieu d'échouer : deux connexions au moteur embarqué ne voient pas la même base.
* `tools/test_native.al` compte les tests ignorés (`○`) à part : ils ne sont plus des échecs.

## 0.9.0 — phase 7 : ALEX DB comme base de données

### Ajouts

* **Pilote `alexdb://`** (correctif ALEX 0013, `database._aqlp`) : serveur ALEX DB, le SGBD écrit en ALEX, par son
  protocole AQLP. Paramètres `?` / `:nom` transmis au serveur, identifiant de la ligne insérée, erreurs typées
  (`IntegrityError`, `TransactionError`, `QueryError`, `ConnectionError`), `LockError` réessayé hors transaction
  jusqu'à `lock_timeout` (5 s). `db.transaction([...])` part en une seule requête `BEGIN … COMMIT` : atomique et sans
  verrou croisé (le serveur traite les requêtes une à une). Écrit en ALEX : disponible dans l'exécutable natif,
  qui n'a pas SQLite.
* **ORM, dialecte « alexdb »** : `orm.dialect(db)`, types `INT PRIMARY KEY` (clé attribuée par le serveur, jamais
  réattribuée), `INT`, `FLOAT`, `VARCHAR(n)`, booléens en 0 / 1 ; `orm.float_type(db)` ; **`orm.index(nom, table,
  colonnes, unique)`** dans les migrations (CREATE INDEX du dialecte ; sur ALEX DB, la première colonne) ; la
  messagerie d'exemple s'en sert.
* **Magasins partagés sur ALEX DB** : `sessions.DatabaseStore`, `ratelimit.DatabaseStore` (sans clé composite ni
  `ON CONFLICT` : insertion conditionnelle et incrément en une transaction d'un bloc), `realtime.DatabaseBroker`.
* **`alweb.alexdb`** : `ensure_database`, `with_database`, `parse`, `redact`, `check`, `is_url`, et `Server(home)`,
  serveur ALEX DB jetable (dossier temporaire, port libre) pour les tests et les démonstrations.
* **`alweb new --base alexdb`** (ou `--base <URL>`) : `config/base.json` pointe sur ALEX DB avec `database.create` ;
  le modèle crée la base au démarrage si elle manque. `alweb build --native` le signale comme base possible.
* **Tests** : `tests/test_alexdb.al` (11 tests : pilote, identifiants, erreurs, verrous, transactions d'un bloc,
  ORM et migrations, sessions, limites et salons partagés) ; `at.alexdb_database(nom)` et `ALWEB_TEST_ALEXDB` ;
  `tools/test_alexdb.sh` lance toute la suite sur un serveur ALEX DB jetable : ORM, limites, salons, blog,
  messagerie et ouvriers multiples y tournent aussi. `tests/test_cli.al` : `--base`.
* `bench/bases.al` : coût des opérations de l'ORM par base.
* Documentation : `docs/ALEXDB.md`.

### Demande

* ALEX DB **0.9.0** (clés INT automatiques, `last_insert_id`, résumé par instruction des requêtes groupées,
  `DOUBLE PRECISION`, correction de `LIMIT` maximal avec `OFFSET`).

## 0.8.0 — phase 6 : outillage et documentation

### Ajouts

* **Paquet installable.** `alweb/` a son propre `alex.toml` : un projet en dépend par `alweb = { path = "…" }` ou
  par version du registre, et `alexc pkg install` le recopie dans `alex_packages/alweb/`, où `use alweb` le trouve.
  Auparavant, le manifeste était à la racine du dépôt et le paquet installé n'était pas importable.
* **Commande `alweb`** (`alweb.cli`, `alweb/commande.al`, lanceurs `bin/alweb` et `bin/alweb.cmd`) : `new`, `run`,
  `test`, `routes`, `migrate`, `check`, `build`, `deploy`, `secret`, `version` ; alias français ; réglages du
  projet par `alweb.json`. Référence : `docs/COMMANDE.md`.
* **Modèle de projet** (`alweb/modele/`) : lancement par profil, `application.creer(cfg, dossier)`, modèle et
  migrations, configuration dev / test / prod (clés tirées au hasard à la création), sessions, CSRF, API JSON à
  débit limité, point de santé `/sante`, cinq tests, README, `.gitignore`.
* **Gabarits de déploiement** (`alweb/deploiement/`, `alweb deploy`) : service systemd durci et fichier
  d'environnement, Caddyfile, configuration nginx (HTTP/2, WebSocket, SSE), Dockerfile, `compose.yaml` avec Caddy.
* **`server.trusted_proxies`** : clé de configuration lue par `app.configure`, transmise au serveur (un processus
  ou plusieurs ouvriers). Derrière un mandataire, journaux et limites de débit voient l'adresse réelle du client.
* **Documentation** : tutoriel du blog (`docs/TUTORIEL_BLOG.md`, projet complet et testé dans
  `docs/tutoriel/blog/`), guide de déploiement (`docs/DEPLOIEMENT.md`).
* Tests : `tests/test_cli.al` (modèle, réglages, déploiement, parcours complet sur un projet généré, projet du
  tutoriel), `test_mandataires_de_confiance` ; le blog du tutoriel a ses six tests.

### Corrections

* Le commentaire d'en-tête d'`alweb.testing` montrait `r.json()`, qui n'existe pas : c'est `r.json_value()`.

## 0.7.0 et avant

Phases 1 à 5 : framework (routes, async, intergiciels, validation, WebSocket, SSE, processus multiples,
rechargement, dépendances, configuration, tests), applications web (gabarits, sessions, CSRF, formulaires,
authentification, ORM et migrations), temps réel et API (salons, OpenAPI, limites de débit, pagination),
performance, HTTP/2 et exécutable natif. Voir le README.
