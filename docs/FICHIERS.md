# Fichiers et images avec alweb

`alweb.storage` range les fichiers de l'application : photos, pièces jointes, exports. Ils peuvent aller sur le
disque du serveur, ou dans un stockage compatible S3 (Amazon S3, MinIO, Scaleway, Backblaze B2, Cloudflare R2,
OVH, Wasabi…). Les fichiers privés sont donnés par des **URL signées qui expirent**. `alweb.images` fait les
**vignettes** et les autres tailles d'une image. Le client S3, avec sa signature AWS V4, est écrit en ALEX.

## Mise en place

```al
use alweb.storage as storage

func creer(cfg, dossier="."):
    app := alweb.App("Galerie")
    app.configure(cfg)
    storage.setup(app)                  # clé « storage » de la configuration ; pose app.storage
```

| `storage.url` | Stockage |
|---|---|
| `file:media` | dossier du serveur ; **défaut en mode debug** |
| `memory:` | en mémoire : pour les tests (profil test du modèle de projet) |
| `s3://CLÉ:SECRET@s3.fr-par.scw.cloud/seau?region=fr-par` | Scaleway |
| `s3://CLÉ:SECRET@s3.eu-west-3.amazonaws.com/seau?region=eu-west-3` | Amazon S3 (adresses « seau.hôte » automatiques) |
| `s3://CLÉ:SECRET@s3.us-west-004.backblazeb2.com/seau?region=us-west-004` | Backblaze B2 |
| `s3://CLÉ:SECRET@<compte>.r2.cloudflarestorage.com/seau?region=auto` | Cloudflare R2 |
| `s3://CLÉ:SECRET@127.0.0.1:9000/seau?secure=false` | MinIO local, en HTTP |

Les options de `s3://` sont `region`, `secure` (`false` pour HTTP), `style` (`path` ou `virtual`), `verify`,
`ca_file` et `timeout`. Dans la clé et le secret, les caractères spéciaux s'écrivent en `%XX` : `/` devient
`%2F`, `+` devient `%2B`. En production, gardez les identifiants hors du dépôt :
`ALWEB_STORAGE__URL=s3://…` dans `.env`.

Autres clés de `storage` :

- `public_url` : adresse publique des fichiers (CDN, seau public). `st.public(clé)` donne alors un lien
  permanent.
- `secret` : signature des URL locales. Par défaut, c'est la `secret_key` de l'application.

## Lire et écrire

```al
st := app.storage
cle := await st.put("factures/2026/f-12.pdf", octets, {"content_type": "application/pdf"})
octets := await st.get(cle)                         # null si absent
infos := await st.head(cle)                         # {key, size, content_type, modified} ou null
await st.list("factures/2026/")                     # [{key, size, modified}, …] triés
await st.delete(cle)
```

Les clés sont des chemins relatifs : `photos/2026/a.jpg`. Une clé absolue, ou contenant `..`, `\` ou un
caractère de contrôle, est refusée (`StorageError`), donc un nom choisi par un visiteur ne peut pas sortir du
stockage. Les méthodes sont asynchrones (`await`). Les erreurs S3 arrivent lisibles, par exemple
`StorageError : AccessDenied : …` ou `NoSuchBucket : …`.

## Donner un fichier : URL signées

```al
@app.get("/factures/{id:int}")
async func facture(req):
    f := await charger_facture(req)                 # vérifier d'abord que la personne y a droit
    return alweb.redirect(app.storage.url(f["cle"], 300, "facture-" + str(f["id"]) + ".pdf"))
```

`st.url(clé, secondes, nom)` donne un lien valable pendant la durée indiquée. Avec `nom`, le fichier est
téléchargé sous ce nom.

- **Avec S3**, c'est une URL présignée : le navigateur télécharge directement chez le fournisseur, sans passer
  par votre serveur. La durée maximale est de 7 jours.
- **Avec le disque ou la mémoire**, le lien passe par une route posée par `setup` (`/_fichiers/…`). Cette
  route vérifie la signature et l'expiration, puis sert le fichier (avec les plages, l'ETag et `nosniff`).

Un lien expiré, modifié ou recopié pour une autre clé est refusé (403).

**Images publiques d'une page.** Un lien d'une heure ou plus reste **le même pendant toute l'heure**, ce qui
permet au navigateur de garder l'image en cache :

- **disque** : l'expiration est arrondie à l'heure suivante ;
- **S3** : le lien est signé au début de l'heure et reste valable une heure de plus.

On peut donc écrire `<img src="{{ media(cle) }}">` avec
`app.context_processor((req) => {"media": (k) => st.url(k, 86400)})`, sans perdre le cache.

## Fichiers téléversés

```al
@app.post("/documents")
async func deposer(req):
    cle := await storage.save_upload(app.storage, alweb.form(req).file("doc"),
                                     {"prefix": "docs/", "max_bytes": 10000000, "allowed": ["application/pdf"]})
    ...
```

Le type est vérifié **dans le contenu**, pas dans le nom envoyé ni dans l'en-tête. Le fichier reçoit un nom
aléatoire avec l'extension de son type réel. Un fichier refusé lève `UploadError`. Dans un gestionnaire,
alweb en fait une réponse **400** avec le message (`type de fichier refusé`, `fichier trop volumineux`) au
lieu d'une erreur 500.

## Images et vignettes

```al
use alweb.images as images

r := await images.store(app.storage, alweb.form(req).file("photo"), {
    "prefix": "photos/",
    "sizes": {"vignette": [200, 200, "cover"], "grande": [1600, 1600]},
    "max_bytes": 15000000})
# r = {"key": "photos/9f3c….jpg", "width": 4032, "height": 3024, "content_type": "image/jpeg",
#      "variants": {"vignette": "photos/9f3c…-vignette.jpg", "grande": "photos/9f3c…-grande.jpg"}}
await PHOTOS.insert(db, {"cle": r["key"], "vignette": r["variants"]["vignette"], "largeur": r["width"]})
```

```html
<img src="{{ vignette_url }}" width="200" height="200" alt="">
```

`store` enregistre l'original et chaque taille. Une taille s'écrit `[largeur, hauteur, mode, format]` :

- **mode** : `fit` (défaut) tient dans le cadre en gardant les proportions ; `cover` remplit le cadre et
  recadre au centre (vignettes carrées).
- **format** : `auto` (défaut) donne du PNG s'il reste de la transparence, sinon du JPEG ; ou `jpeg`, `png`.

`quality` (82 par défaut) règle la qualité JPEG, et `keep_original: false` n'enregistre que les tailles. Une
image illisible est refusée (`UploadError`, donc une réponse 400) avant que rien ne soit écrit. Si une étape
échoue, ce qui a déjà été écrit est retiré. `images.remove(st, r)` supprime l'original et les tailles.

```al
v := await images.thumbnail(octets, 400, 400, {"mode": "fit"})   # {data, width, height, format, content_type,
                                                                 #  source_width, source_height}
d := await images.info(octets)                                   # {width, height}
```

Ce qui est pris en charge :

- **Entrée** : JPEG (de base et progressif), PNG, GIF (première image), WebP, BMP.
- **Sortie** : JPEG ou PNG.
- **Orientation Exif** appliquée : les photos de téléphone tenues en portrait ne sont pas couchées.
- **Jamais d'agrandissement**, et 50 mégapixels au plus.

**Comment c'est fait.** Le travail est confié à un petit programme natif écrit en ALEX
(`alweb/outils/vignette.al`, module `image.encode` d'ALEX). Il est lancé dans un processus à part, depuis un fil
d'exécution :

- le serveur continue de servir pendant le calcul ;
- une image piégée ne peut pas le faire tomber ;
- chaque appel est arrêté au bout de 30 s ;
- une photo de 6 Mpx devient une vignette en environ 1 s.

Le programme est compilé au premier usage dans `.alweb/outils/`, ce qui prend quelques secondes une seule fois.
`alweb build` le produit à côté de l'exécutable (`dist/alweb-vignette`) : copiez-le avec l'application sur le
serveur. Si vous l'avez déjà construit ailleurs, indiquez son chemin dans `ALWEB_IMAGES_HELPER=/chemin/vers/vignette`.

Il faut ALEX 1.4.0 ou plus récent (encodeurs JPEG et PNG de `image.encode`).

## L'exemple complet : le blog

`examples/blog_app.al` (lancement : `alexc run examples/blog.al`) montre l'ensemble :

- la photo de chaque article réduite en vignette 16:9 recadrée pour la liste, et en grande image pour l'article
  (`images.store`, sans garder l'original) ;
- une pièce jointe PDF réservée aux lecteurs connectés : la route `/articles/{id}/piece` vérifie la connexion,
  puis renvoie vers un lien signé de 5 minutes, sous le nom d'origine ;
- les fichiers retirés quand l'article est supprimé ou que sa photo est remplacée ;
- la migration `orm.add_column` des bases existantes.

En développement, tout va dans `media/`. En production, mettez `ALWEB_STORAGE__URL=s3://…`.

## Essai contre un vrai S3 (MinIO)

```sh
# MinIO sur la machine (https://min.io/download : un seul exécutable)
MINIO_ROOT_USER=alweb MINIO_ROOT_PASSWORD=motdepasse-minio ./minio server /tmp/minio --address 127.0.0.1:9000 &
./mc alias set local http://127.0.0.1:9000 alweb motdepasse-minio && ./mc mb local/essai
# ou avec Docker : docker run -p 9000:9000 -e MINIO_ROOT_USER=alweb -e MINIO_ROOT_PASSWORD=motdepasse-minio minio/minio server /data

ALWEB_TEST_S3="s3://alweb:motdepasse-minio@127.0.0.1:9000/essai?secure=false" alexc test tests/test_storage.al
```

`test_vrai_s3` travaille sous un préfixe aléatoire qu'il efface à la fin. Il couvre :

- l'écriture et la relecture d'octets quelconques, avec des clés accentuées ;
- `head` et `list` (limite comprise) ;
- un lien présigné nommé téléchargé, et un lien falsifié refusé ;
- des images avec leurs tailles.

Le même test marche avec Scaleway, B2 ou Amazon : il suffit de mettre leur adresse dans la variable.

## Tests

Avec `"storage": {"url": "memory:"}` (profil test du modèle de projet), rien ne touche le disque :

```al
r := await c.post("/photos", {"body": corps_multipart, "headers": {"Content-Type": "multipart/form-data; boundary=X"}})
assert_eq(len(await c.app.storage.list("photos/")), 3)                 # original + 2 tailles
assert_eq((await c.get(c.app.storage.url(cle, 60))).status, 200)       # lien signé servi par l'application
```

`st.clock = () => time.time() + 3600` simule le passage du temps (liens expirés).
