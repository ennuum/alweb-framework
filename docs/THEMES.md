# Thèmes (ALWEB Templates)

Un thème est un dossier indépendant — gabarits, composants, ressources statiques, paramètres — décrit par
`alweb-theme.json`. On le crée, on le valide, on l'empaquette en archive `.alwt`, puis on l'installe dans un
projet et on l'active. L'application garde ses routes, ses modèles et ses données : le thème ne fournit que
l'interface. **Un thème ne contient jamais de code ALEX** : il n'est fait que de gabarits, de CSS, de JavaScript
pour le navigateur et d'images, et il est contrôlé avant chaque installation.

Phase 1 : création, validation, archives et installation, sans connexion. Phase 2 : la page « Apparence » de
l'administration, qui règle le thème avec un aperçu en direct ([plus bas](#la-page-apparence-de-ladministration)).
Phase 3 : la marketplace, un registre de thèmes avec publication signée, recherche, installation vérifiée et
mises à jour ([plus bas](#la-marketplace) ; [protocole](MARKETPLACE_PROTOCOLE.md)).

## En cinq commandes

```sh
alweb theme create modern-business --auteur "Ennuum Group"   # dossier modern-business/ (24 fichiers)
cd modern-business
alweb theme preview                    # http://127.0.0.1:8001/_apercu : ordinateur, tablette, mobile côte à côte
alweb theme validate                   # contrôles de sécurité et de structure
alweb theme package                    # dist/modern-business-0.1.0.alwt (reproductible)

cd ../mon-site
alweb theme install ../modern-business/dist/modern-business-0.1.0.alwt   # themes/modern-business/, alweb.lock
```

`alweb theme install` (et `alweb theme activate`) branchent le thème dans l'application : dans
`application.al` (réglage « app »), la ligne `app.use_templates(os.join(dossier, "templates"))` devient
`themes.setup(app, null, {"root": dossier})`, et `use alweb.themes as themes` est ajouté. C'est fait une seule
fois ; les projets créés par `alweb new` sont déjà branchés. Si le fichier n'a pas cette forme, rien n'est
modifié et la commande indique la ligne à écrire. Il reste à redémarrer l'application.

Les gabarits de `templates/` du projet passent avant ceux du thème. Le `templates/base.html` créé par
`alweb new`, s'il n'a pas été modifié, est donc renommé en `base.html.sans-theme` à l'installation : les pages
prennent l'en-tête, le menu, le pied et les styles du thème (remettez-le en place pour revenir à la page simple).

Ce qui revient à écrire, dans l'application :

```al
use alweb
use alweb.themes as themes

app := alweb.App("Vitrine")
themes.setup(app)                         # thème actif ; app.theme

@app.get("/")
func accueil(req):
    return alweb.render(req, "index.html", {"services": services_en_base()})
```

## Domaines : boutique, blog, portfolio, vitrine

Un thème et un projet peuvent partir d'un modèle adapté au domaine du site :

```sh
alweb theme create mon-theme --nom "Mon thème" --domaine ecommerce --auteur "Ennuum Group"
alweb new ma_boutique --domaine ecommerce          # projet complet, thème déjà installé et actif
```

| Domaine | Pages du thème | Projet (`alweb new --domaine`) |
|---|---|---|
| `business` (défaut ; alias `vitrine`) | accueil, services, à propos, blog, contact | contenu en constantes, contacts enregistrés |
| `ecommerce` (alias `e-commerce`, `boutique`) | accueil avec rayons, catalogue filtrable, fiche produit, panier, commande | tables produits, commandes, lignes ; panier en session ; stock mis à jour ; 6 produits d'exemple |
| `blog` | article à la une, liste paginée par catégorie, barre latérale, lecture, articles similaires | table articles, catégories, pagination ; 6 articles d'exemple |
| `portfolio` | présentation, projets en grille, filtre, fiche projet avec galerie | table projets (vedette, ordre, galerie) ; 6 projets d'exemple |

Chaque domaine part du modèle « Modern Business » (`modele-theme/`) complété par sa surcouche
(`modele-theme-<domaine>/`) : pages et composants ajoutés ou remplacés, réglages propres (devise et bandeau d'une
boutique, police de lecture d'un blog, mention « disponible » d'un portfolio), feuille de style complétée (un
fichier `x.ajout` d'une surcouche est ajouté à la fin de `x`), logo, données d'aperçu et capture d'écran. La
catégorie du manifeste (`category`) vaut le domaine. Les données attendues par chaque page sont décrites dans
`documentation/installation.md` du thème créé.

Avec `--domaine`, `alweb new` part de `modele/` complété par `modele-<domaine>/` (application, tables, données
d'exemple, tests), sans `templates/base.html` ni `templates/index.html` (le thème fournit les pages), puis crée
le thème du domaine sous l'identifiant du projet (`ma_boutique` → `ma-boutique`) et l'installe. Les données
d'exemple sont ajoutées au premier démarrage si la table est vide (`"exemples": false` dans la configuration
pour ne pas les ajouter). Sans `--domaine`, le projet reste le modèle minimal (livre d'or, sans thème).

## Structure d'un thème

```
modern-business/
├── alweb-theme.json        manifeste
├── README.md, LICENSE
├── config/theme.json       paramètres personnalisables (schéma typé)
├── templates/              pages : base.html, index.html, services.html, about.html, contact.html,
│                           blog/index.html, blog/detail.html, errors/404.html
├── components/             navbar.html, footer.html, sidebar.html, hero.html, cards.html (macros)
├── static/                 css/, js/, images/, icons/, fonts/
├── preview/data.json       données de démonstration pour l'aperçu (et captures d'écran)
└── documentation/
```

## Le manifeste `alweb-theme.json`

```json
{
  "name": "Modern Business",
  "slug": "modern-business",
  "version": "1.0.0",
  "description": "Thème vitrine pour une entreprise.",
  "author": "Ennuum Group",
  "framework": "ALWEB",
  "framework_version": ">=0.9.0",
  "alex_version": ">=0.9.0",
  "category": "business",
  "license": "MIT",
  "entry": "templates/index.html",
  "responsive": true,
  "languages": ["fr"],
  "dependencies": [{"slug": "base-ui", "version": "^1.0.0"}],
  "screenshots": ["preview/accueil.png"],
  "keywords": ["entreprise", "vitrine"]
}
```

| Champ | Règle |
|---|---|
| `name`, `license` | requis, non vides |
| `slug` | requis : minuscules, chiffres et tirets simples, 2 à 60 caractères (`modern-business`) |
| `version` | requise : version sémantique `1.2.3`, pré-version permise (`1.0.0-beta.2`) |
| `framework` | requis, vaut `"ALWEB"` |
| `framework_version` | requise : contrainte (`>=0.9.0`, `^0.9.0`, `~0.9.1`, `>=0.9.0, <2.0.0`, `*`) |
| `entry` | requis : gabarit d'entrée, dans le dossier des gabarits |
| `alex_version` | facultative : contrainte sur la version d'ALEX |
| `category` | `business`, `ecommerce`, `education`, `dashboard`, `portfolio`, `blog`, `real-estate`, `health`, `finance`, `saas`, `landing`, `webapp`, `community`, `organization`, `other` (défaut) |
| `templates`, `components`, `assets`, `settings` | dossiers (défauts `templates`, `components`, `static`) et fichier des paramètres (`config/theme.json`) |
| `dependencies` | `[{slug, version}]` : thèmes à installer d'abord |
| `screenshots` | chemins relatifs, fichiers présents |

Une clé inconnue est une erreur (une faute de frappe ne passe pas inaperçue). Tous les chemins sont relatifs,
sans `..`, sans chemin absolu ni caractère de contrôle.

## Paramètres personnalisables

`config/theme.json` décrit chaque paramètre, regroupés par section :

```json
{
  "couleurs": {
    "primaire": {"type": "color", "default": "#e87524", "label": "Couleur principale"}
  },
  "typographie": {
    "taille": {"type": "size", "default": "17px"}
  },
  "menu": {"type": "links", "default": [{"label": "Accueil", "url": "/"}]}
}
```

| Type | Valeurs permises |
|---|---|
| `color` | `#rgb`, `#rrggbb`, `#rrggbbaa` |
| `size` | nombre et unité : `px`, `rem`, `em`, `%`, `vh`, `vw`, `ch` |
| `font` | familles séparées par des virgules (lettres, chiffres, espaces, tirets, guillemets) |
| `text` | texte court, 500 caractères au plus, sans `< > { } ; \ " `` ` `` |
| `bool`, `number` | booléen ; nombre (`min`, `max` facultatifs) |
| `choice` | une des `options` |
| `url` | `https://…`, `http://…` ou chemin `/…` |
| `image` | chemin dans `static/` du thème, `media:clé` (dans `alweb.storage`) ou `https://…` |
| `links` | liste de `{label, url}` (URL comme ci-dessus) |

Le projet fait ses choix dans `config/theme.<slug>.json` (seulement ce qui change) :

```json
{"couleurs": {"primaire": "#1f6feb"}, "site": {"nom": "Ma société"}}
```

Les valeurs sont vérifiées au démarrage : une couleur invalide, un paramètre inconnu ou un lien
`javascript:` arrêtent l'application avec la liste de toutes les erreurs (`ThemeError`). Les types `color`,
`size`, `font` et `number` deviennent des variables CSS servies par `/_theme.css` :

```css
:root { --couleurs-primaire: #1f6feb; --typographie-taille: 17px; --mise-en-page-largeur: 1120px; }
```

La feuille est un fichier à part (et non un `<style>` dans la page) pour respecter la politique de sécurité du
contenu d'alweb (`default-src 'self'`).

## Dans les gabarits

| Variable | Contenu |
|---|---|
| `theme` | paramètres fusionnés : `{{ theme.couleurs.primaire }}`, `{% for l in theme.menu %}` |
| `asset(chemin)` | URL versionnée d'une ressource du thème : `{{ asset("css/theme.css") }}` → `/theme/css/theme.css?v=3f9a…` (mise en cache un an) ; `media:…` → lien du stockage, `https://…` tel quel |
| `theme_css` | URL de `/_theme.css` (variables CSS), versionnée |
| `theme_info` | manifeste : `{{ theme_info.name }}`, `{{ theme_info.version }}` |
| `_()`, `_n()` | traductions (`alweb.i18n`) ; sans `I18n`, le texte tel quel |

Composants : `{% include "components/navbar.html" %}`, `{% import "components/cards.html" as c %}` puis
`{{ c.carte(titre, texte, lien) }}`. Le moteur de gabarits accepte maintenant les tranches :
`{{ articles[0:3] }}`, `{{ nom[0:1] }}`, `{{ l[-2:] }}`.

**Remplacer une page du thème** : un gabarit du même nom dans `templates/` de l'application passe avant
celui du thème, et peut étendre `base.html` du thème. De même `components/` de l'application passe avant les
composants du thème.

Dans le code : `themes.setting(app, "couleurs.primaire")`, `app.theme.manifest`, `app.theme.asset(app, "…")`.

## Options de `setup`

```al
themes.setup(app)                                   # thème actif : config « theme.active », sinon alweb.lock
themes.setup(app, "modern-business")                # thème choisi
themes.setup(app, null, {"root": "…", "templates": "templates", "static_prefix": "/theme"})
themes.setup(app, null, {"directory": "chemin/du/theme"})   # thème hors du projet (développement)
```

Sans thème installé ni actif, `setup` ne fait rien et l'application utilise ses gabarits seuls.

## Sécurité

Le validateur (`alweb theme validate`, et à chaque installation) refuse :

* les fichiers de code ou exécutables : `.al`, `.albc`, `.sh`, `.py`, `.php`, `.exe`, `.so`, `.wasm`, `.jar`,
  `.htaccess`… ; et toute extension hors de la liste permise (HTML, CSS, JS, JSON, Markdown, images, polices,
  audio, vidéo, PDF) ;
* les liens symboliques et les noms de fichiers non sûrs ;
* les SVG qui contiennent `<script>`, `javascript:` ou un gestionnaire d'évènement (`onload=`…) ;
* plus de 2 000 fichiers, plus de 20 Mo par fichier ou plus de 50 Mo au total ;
* un gabarit qui ne s'analyse pas, ou dont un `extends` / `include` / `import` vise un gabarit absent ;
* un manifeste ou des paramètres invalides.

Il signale aussi (sans refuser) l'absence de README, de LICENSE ou de captures d'écran.

L'archive `.alwt` est inspectée **avant d'écrire quoi que ce soit** : chemins (`../`, absolus, `\`), types de
fichiers, nombre et taille décompressée bornés, entrées chiffrées refusées, taille réelle de chaque entrée
vérifiée à l'extraction. L'installation se fait dans un dossier temporaire, validé, puis seulement mis en
place. Les gabarits n'exécutent que les fonctions que l'application met dans leur contexte, et leur sortie est
échappée par défaut.

## Installation dans un projet : `alweb.lock`

```json
{
  "lock_version": 1,
  "active": "modern-business",
  "themes": {
    "modern-business": {
      "version": "1.1.0", "name": "Modern Business", "source": "archive:modern-business-1.1.0.alwt",
      "archive_sha256": "…", "tree_sha256": "…", "framework_version": ">=0.9.0",
      "installed_at": 1794000000, "previous": "1.0.0"
    }
  }
}
```

* Le premier thème installé devient actif.
* Réinstaller la même version demande `--force`.
* Une nouvelle version garde l'ancienne dans `themes/.versions/` ; `alweb theme rollback` y revient.
* `alweb theme info` dit si le contenu a été modifié depuis l'installation (empreinte `tree_sha256`).
* Un thème incompatible (version d'ALWEB ou d'ALEX) ou dont une dépendance manque est refusé ; un thème dont
  un autre dépend ne peut pas être retiré.

Pensez à versionner `alweb.lock` et `themes/` avec le projet.

## La page « Apparence » de l'administration

Avec `alweb.admin`, un thème actif ajoute la page **Apparence** (`/admin/_apparence`) au menu et au tableau de
bord. Elle est produite depuis le schéma du thème (`config/theme.json`) : rien à écrire.

```al
app.middleware([mw.security_headers(), sessions.middleware(SECRET)])
themes.setup(app)
storage.setup(app)                         # facultatif : envoi du logo et des images
adm.Admin(app, {"appearance": true})       # défaut ; false : pas de page ; ["design"] : rôle exigé en plus
```

* **Formulaire** : une section par groupe du schéma (les paramètres du premier niveau dans « Général »), un
  champ adapté à chaque type (sélecteur de couleur et code, case à cocher, liste de choix, nombre avec bornes,
  lignes libellé / adresse pour les liens, envoi d'image), la valeur du thème sous chaque champ, un point devant
  les réglages modifiés. Libellés : `label` et `help` de chaque paramètre (traduits par `alweb.i18n`).
* **Aperçu en direct** : le site s'affiche à droite dans un cadre, en ordinateur, tablette ou mobile, sur la page
  choisie. Une couleur, une taille ou une police change tout de suite (variables CSS). Les autres réglages
  rechargent la page d'aperçu. Une valeur invalide est signalée sous son champ.
* **Les visiteurs ne voient rien avant « Enregistrer »** : les réglages en cours forment un brouillon gardé dans
  la session de la personne qui règle. Il ne s'applique qu'aux pages chargées dans son cadre d'aperçu (en-tête
  `Sec-Fetch-Dest: iframe`, ou `?_apercu_theme=1`). Ces pages seules peuvent s'afficher dans un cadre de même
  origine (`X-Frame-Options: SAMEORIGIN`, `frame-ancestors 'self'`) ; toutes les autres gardent `DENY`.
* **Enregistrer** écrit dans `config/theme.<slug>.json` les seules valeurs qui diffèrent du thème (écriture
  atomique). C'est appliqué tout de suite, et les autres processus relisent le fichier au plus une seconde après.
  Un fichier modifié à la main est pris en compte de la même façon (s'il devient invalide, les valeurs
  précédentes sont gardées et un message est écrit dans le journal).
* **Historique** : chaque enregistrement garde la version précédente dans
  `.alweb/themes/<slug>/historique/` (20 versions) ; « Restaurer » y revient, « Tout rétablir » revient aux
  valeurs du thème, « Télécharger les réglages » donne le fichier de choix (à versionner ou à copier sur un
  autre site).
* **Images** : avec `alweb.storage`, une image envoyée (PNG, JPEG, GIF, WebP ; 5 Mo au plus ; type réel vérifié,
  pas de SVG) est rangée sous `theme/<slug>/` et le paramètre vaut `media:<clé>`. `asset()` en donne un lien.
* **Thèmes installés** : la liste, et « Activer » pour un autre thème (`alweb.lock`), pris en compte au
  prochain démarrage de l'application.

Chaque action passe par `on_change` de l'administration (journal d'audit) : `theme_update`, `theme_reset`,
`theme_restore`, `theme_activate` (table `"theme"`, identifiant = slug, valeurs = choix). Comme toute
l'administration : connexion et rôle exigés, jeton CSRF sur chaque envoi, `Cache-Control: no-store`.

Le script de la page est un fichier servi par l'administration (`/admin/_apparence.js`) : il respecte une
politique `script-src 'self'`.

## La marketplace

Une marketplace est un registre de thèmes en ligne : on y publie des thèmes signés, et les sites les cherchent,
les installent et les mettent à jour avec la commande `alweb theme`. alweb contient le **client**
(`alweb.themes.client`, `alweb.themes.signing`, ces commandes, et la vérification des mises à jour dans la page
Apparence). Le **serveur** ne fait pas partie d'alweb : toute marketplace qui suit le
[protocole ouvert](MARKETPLACE_PROTOCOLE.md) convient.

L'adresse de la marketplace vient de `--registre URL` ou de `ALWEB_MARKETPLACE`.

### Côté développeur de thèmes

```sh
export ALWEB_MARKETPLACE=https://themes.exemple.org ALWEB_MARKETPLACE_TOKEN=alwt_…   # jeton donné par la marketplace
alweb theme keygen                     # clé d'éditeur ECDSA P-256 : ~/.alweb/editeur.json (0600) ; empreinte affichée
alweb theme publish                    # valide, empaquette, signe et envoie le thème du dossier courant
alweb theme publish dist/x-1.2.0.alwt  # ou une archive déjà construite
alweb theme yank modern-business@1.2.0 [--annuler]   # retirer une version (ou la remettre)
```

* La signature porte sur l'identifiant, la version et le SHA-256 de l'archive (`alweb-theme/1`) : elle ne peut
  pas resservir pour une autre version ni pour un autre thème.
* À la première publication, la marketplace enregistre la clé publique de l'éditeur ; ensuite elle exige des
  signatures faites avec cette clé. Seul l'administrateur de la marketplace peut la remplacer (clé perdue :
  dans son administration).
* Un identifiant appartient à son premier éditeur. Une version publiée ne se remplace jamais (code 409) : on
  publie une nouvelle version, et on peut retirer l'ancienne.
* La marketplace valide chaque archive exactement comme une installation : pas de code ni d'exécutable,
  chemins sûrs, tailles bornées, gabarits analysés, manifeste complet (code 422 avec la liste des erreurs).
* Gardez la clé d'éditeur secrète et sauvegardée. `--cle FICHIER` ou `ALWEB_PUBLISHER_KEY` pour en choisir une
  autre ; `--jeton` et `--registre` remplacent les variables d'environnement.

### Côté site

```sh
alweb theme search business            # identifiant, dernière version compatible, catégorie, éditeur
alweb theme install modern-business    # dernière version compatible avec cet ALWEB
alweb theme install modern-business@~1.2.0
alweb theme update --verifier          # mises à jour disponibles
alweb theme update                     # les installe (l'ancienne version reste pour rollback)
```

À l'installation, la commande vérifie dans l'ordre :

1. la taille et le **SHA-256** de l'archive reçue, comparés à ceux de la fiche ;
2. la **signature** de l'éditeur ;
3. la **clé de l'éditeur**. Elle est épinglée dans `alweb.lock` (`publisher_key`) à la première installation.
   Si la marketplace en annonce une autre plus tard, l'installation et la mise à jour sont refusées : vérifiez
   auprès de l'éditeur, puis relancez avec `--nouvelle-cle` ;
4. le contenu, comme une installation locale : validation, compatibilité, dépendances.

Le verrou garde la provenance (`source: "marketplace:https://…"`), l'éditeur, sa clé et la signature. Une
version retirée n'est plus proposée, mais reste installable si on la demande exactement
(`alweb theme install x@1.2.0`). Les réglages du projet (`config/theme.<slug>.json`) ne sont pas touchés par
une mise à jour.

La page **Apparence** de l'administration propose « Vérifier » les mises à jour pour un thème venu d'une
marketplace (requête asynchrone : le serveur continue de servir pendant ce temps). Pour installer la nouvelle
version, elle indique la commande à lancer, suivie d'un redémarrage.

### Avis et notes

Quand la marketplace les ouvre, chaque téléchargement porte un **reçu d'installation** signé par le serveur.
`alweb theme install` et `update` le gardent dans `alweb.lock` (`review_token`). Ce reçu donne droit à **un
avis** par installation, que seul son détenteur peut remplacer ou supprimer. Il n'y a pas de compte à créer,
et on ne peut pas noter un thème qu'on n'a pas téléchargé.

```sh
alweb theme review modern-business --note 4 --titre "Très bien" --texte "Il manque une page tarifs." --pseudo "Awa D."
alweb theme review modern-business --supprimer
alweb theme reviews modern-business          # note moyenne et avis visibles (sans projet)
alweb theme search --tri rating              # aussi : popular (défaut), recent, downloads, name
```

Note entière de 1 à 5, titre (100 caractères), texte (2 000), nom affiché (40 ; « Anonyme » par défaut). Si la
marketplace limite les téléchargements (code 429), la commande indique le délai : « réessayez dans N s ».

### Captures d'écran

Les images listées dans `screenshots` du manifeste (PNG, JPEG, WebP ou GIF ; le validateur refuse un autre
format) sont montrées par la marketplace sur la carte et la fiche du thème. Le modèle « Modern Business » en
contient une (`preview/accueil.jpg`) ; pour la vôtre, lancez `alweb theme preview` et faites une capture de la
page.

## Commandes

| Commande | Effet |
|---|---|
| `alweb theme create <slug> [--dir D] [--nom N] [--auteur A] [--domaine D]` | nouveau thème depuis le modèle « Modern Business », complété pour le domaine : `business` (défaut), `ecommerce`, `blog`, `portfolio` |
| `alweb theme validate [dossier] [--json]` | contrôles ; code 1 si le thème est invalide |
| `alweb theme package [dossier] [--out dist]` | archive `<slug>-<version>.alwt`, empreinte SHA-256 |
| `alweb theme preview [dossier] [--port 8001]` | serveur d'aperçu avec les données de `preview/data.json` ; `/_apercu` montre une page en trois tailles |
| `alweb theme install <archive.alwt \| dossier> [--force]` | installe dans le projet courant |
| `alweb theme activate <slug>`, `deactivate` | thème actif |
| `alweb theme list [--json]`, `info <slug> [--json]` | thèmes installés ; détail, compatibilité, modifications |
| `alweb theme remove <slug>`, `rollback <slug>` | retrait ; retour à la version précédente |
| `alweb theme check [slug]` | revalide le thème actif (ou celui nommé) : compatibilité, sécurité, contenu modifié depuis l'installation ; code 1 sinon |
| `alweb theme search [texte] [--categorie C] [--json]` | marketplace : thèmes compatibles avec cet ALWEB |
| `alweb theme install <slug>[@contrainte] [--force] [--nouvelle-cle]` | marketplace : téléchargement vérifié (SHA-256, signature, clé épinglée) puis installation |
| `alweb theme update [slug] [--verifier] [--json]` | marketplace : mises à jour disponibles, installées sauf avec `--verifier` |
| `alweb theme keygen [--cle F] [--force]` | clé d'éditeur (ECDSA P-256) |
| `alweb theme publish [dossier \| archive.alwt] [--cle F] [--jeton J] [--out D]` | marketplace : validation, archive, signature, envoi |
| `alweb theme yank <slug>@<version> [--annuler]` | marketplace : retirer une version (ou la remettre) |
| `alweb theme review <slug> --note 1..5 [--titre T] [--texte X] [--pseudo NOM] [--supprimer]` | avis sur un thème installé depuis la marketplace (reçu d'installation du verrou) |
| `alweb theme reviews <slug> [--json]` | note et avis visibles |

Options de la marketplace : `--registre URL` (sinon `ALWEB_MARKETPLACE`), `--jeton` (sinon
`ALWEB_MARKETPLACE_TOKEN`), `--cle` (sinon `ALWEB_PUBLISHER_KEY`, puis `~/.alweb/editeur.json`).

Alias français : `creer`, `valider`, `empaqueter`, `apercu`, `installer`, `activer`, `desactiver`, `lister`,
`supprimer`, `retour`, `verifier`, `chercher`, `mettre-a-jour`, `publier`, `cle`, `retirer`, `avis`, `lire-avis` ; `alweb themes` vaut
`alweb theme`.

## Aperçu et données de démonstration

`preview/data.json` contient une clé `commun` (données de toutes les pages) et une clé par page
(`index`, `services`, `blog/index`…). L'aperçu sert chaque page à son URL (`/`, `/services`, `/blog`,
`/blog/detail`) et `/_apercu?page=…` l'affiche en ordinateur (1 280 px), tablette (768 px) et mobile
(390 px). Relu à chaque requête : on modifie le thème et on recharge.

## API

| Module | Contenu |
|---|---|
| `alweb.themes` | `setup`, `setting`, `load`, `Theme` (`refresh`, `save_choices`, `values_for`), `history`, `draft`, `set_draft`, `clear_draft`, `validate`, `build`, `project`, `preview_app`, `pages` |
| `alweb.themes.panel` | page « Apparence » de `alweb.admin` : `read_choices(th, formulaire)`, `sections`, `leaf_paths` |
| `alweb.themes.manifest` | `check`, `load`, `parse_version`, `compare`, `satisfies`, `valid_slug`, `safe_path` |
| `alweb.themes.customization` | `check_schema`, `check_value`, `merge`, `get`, `css` |
| `alweb.themes.validator` | `validate` (rapport), `check` (lève `ThemeError`), `list_files`, `references` |
| `alweb.themes.package` | `build`, `inspect`, `extract`, `tree_sha256`, `file_sha256` |
| `alweb.themes.registry` | `Registry(racine)` : `install`, `activate`, `deactivate`, `active`, `list`, `info`, `remove`, `rollback` |
| `alweb.themes.signing` | `generate`, `sign`, `verify`, `fingerprint`, `save_key`, `load_key`, `public_of`, `valid_public` |
| `alweb.themes.client` | `Client(url, {token, transport})` : `search`, `theme`, `download`, `publish`, `yank`, `reviews`, `review`, `delete_review` ; `install(reg, client, slug, contrainte)`, `updates`, `choose`, `parse_spec`, `review_token_for` |
