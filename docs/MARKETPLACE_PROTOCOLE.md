# Protocole des marketplaces de thèmes (version 1)

alweb contient le **client** d'une marketplace de thèmes : les commandes `alweb theme search`, `install`,
`update`, `publish`, `yank`, `review` et `reviews` (module `alweb.themes.client`), et la vérification des mises
à jour dans la page « Apparence ». Ce document décrit ce que le client attend d'un serveur, pour que n'importe
qui puisse en écrire un compatible. La sécurité ne repose pas sur la confiance dans le serveur : le client
vérifie lui-même l'empreinte, la signature de l'éditeur et la clé épinglée.

## Généralités

* Adresse de base : `https://themes.exemple.org` (option `--registre` ou variable `ALWEB_MARKETPLACE`). Toutes
  les requêtes ci-dessous sont relatives à `{base}/api/v1`.
* Réponses JSON en UTF-8. En cas d'erreur (statut 400 ou plus) : `{"error": "message lisible"}`, et
  éventuellement `"errors": ["…", "…"]` pour une liste de problèmes. Le client affiche ces messages.
* Identifiants de thème (`slug`) : minuscules, chiffres et tirets simples, 2 à 60 caractères. Versions :
  versionnage sémantique (`1.2.3`, `1.0.0-beta.2`). Contraintes de compatibilité : syntaxe du manifeste
  (`>=0.9.0`, `^1.2.0`, `~1.2.0`, listes séparées par des virgules) — voir [THEMES.md](THEMES.md).
* Un serveur peut limiter le débit : statut 429 avec l'en-tête `Retry-After` (secondes). Le client le traduit
  en « réessayez dans N s ».

## Archives

Une archive de thème (`.alwt`, type `application/vnd.alweb.theme+zip`) est un fichier ZIP qui contient
`alweb-theme.json` à sa racine, construit par `alweb theme package`. Le client la contrôle comme une
installation locale (chemins, types de fichiers, tailles, manifeste, gabarits : [THEMES.md](THEMES.md),
section « Sécurité ») : un serveur n'a pas à le faire, mais devrait refuser à la publication ce que le client
refusera à l'installation.

## Signatures

* Algorithme : ECDSA sur la courbe P-256, hachage SHA-256, signature encodée en DER puis en hexadécimal.
* Clé publique de l'éditeur : point non compressé (65 octets, `04‖x‖y`) en hexadécimal.
* Message signé, en UTF-8, avec des retours à la ligne `\n` :

  ```
  alweb-theme/1
  <slug>
  <version>
  <SHA-256 de l'archive, en hexadécimal minuscule>
  ```

* Empreinte d'une clé (affichage) : SHA-256 de la clé publique écrite en hexadécimal minuscule, 32 premiers
  caractères hexadécimaux groupés par 4 et séparés par `:`.

Implémentation de référence : `alweb.themes.signing` (`generate`, `sign`, `verify`, `fingerprint`).

## Lecture

### `GET /themes?q=&category=&alweb=&sort=&page=`

Recherche. `alweb` : version d'alweb du client (ne garder que les thèmes qui ont une version compatible) ;
`sort` : `popular`, `recent`, `rating`, `downloads` ou `name` (un serveur peut en ignorer).

```json
{"items": [{"slug": "modern-business", "name": "Modern Business", "description": "…", "category": "business",
            "latest": "1.1.0", "publisher": "ennuum", "downloads": 42, "rating": 4.5, "reviews": 2}],
 "total": 1, "page": 1, "per_page": 24}
```

`rating` vaut `null` sans avis.

### `GET /themes/{slug}`

Fiche d'un thème, ou 404 s'il n'existe pas (410 s'il a été retiré par la modération, avec un message).

```json
{"slug": "modern-business", "name": "Modern Business",
 "publisher": {"name": "ennuum", "public_key": "04…", "fingerprint": "e2ba:ff4e:…"},
 "versions": [{"version": "1.1.0", "framework_version": ">=0.9.0", "sha256": "…", "size": 12859,
               "signature": "3045…", "yanked": false}]}
```

D'autres champs peuvent s'ajouter (description, captures…). Le client choisit la plus haute version non
retirée (`yanked`) dont `framework_version` accepte sa version d'alweb, ou celle qu'on lui demande.

### `GET /themes/{slug}/{version}/archive`

Les octets de l'archive (200). Le client vérifie, dans l'ordre :

1. que la taille et le SHA-256 reçus sont ceux de la fiche ;
2. que `signature` est valide pour `(slug, version, sha256)` avec `public_key` ;
3. que cette clé est celle épinglée dans `alweb.lock` lors d'une installation précédente du même thème (sinon
   refus, sauf `--nouvelle-cle`) ;
4. que le manifeste de l'archive porte bien ce `slug` et cette `version`.

En-tête facultatif `X-Alweb-Review-Token` : un **reçu d'installation**, chaîne opaque que le client garde dans
`alweb.lock` (`review_token`) et renvoie pour donner son avis. Le serveur en définit le format (par exemple
une valeur signée par lui) ; il ne devrait en accepter qu'un avis à la fois.

### `GET /themes/{slug}/reviews?page=`

```json
{"items": [{"rating": 4, "title": "Très bien", "body": "…", "author": "Awa D.", "version": "1.1.0"}],
 "total": 1, "page": 1, "pages": 1, "rating": 4.0, "count": 1}
```

## Écriture

### `POST /themes` — publication

En-têtes : `Authorization: Bearer <jeton de l'éditeur>`, `Content-Type: application/vnd.alweb.theme+zip`,
`X-Alweb-Signature` (signature de l'archive, ci-dessus), `X-Alweb-Public-Key` (clé publique de l'éditeur).
Corps : l'archive. Réponse 201 :

```json
{"slug": "modern-business", "version": "1.1.0", "sha256": "…", "size": 12859, "publisher": "ennuum",
 "fingerprint": "e2ba:ff4e:…", "url": "/themes/modern-business"}
```

Codes d'erreur attendus : 400 (requête incomplète), 401 (jeton), 403 (signature, clé ou identifiant refusés),
409 (version déjà publiée : une version ne se remplace pas), 413 (archive trop grosse), 422 (archive ou
thème invalide, avec `errors`).

### `POST /themes/{slug}/{version}/yank` et `/unyank`

Retirer une version (elle n'est plus proposée, mais reste téléchargeable si on la demande exactement), ou la
remettre. `Authorization: Bearer …`. Réponse : `{"slug": …, "version": …, "yanked": true}`.

### `POST /themes/{slug}/reviews`

Corps JSON : `{"token": "<reçu>", "rating": 1..5, "title": …, "body": …, "author": …, "version": …}`
(`title`, `body`, `author` et `version` facultatifs). Réponse 201 (nouvel avis) ou 200 (avis remplacé) :
`{"status": "visible" | "pending" | "hidden", "created": true | false}`. Erreurs : 403 (reçu invalide pour ce
thème), 422 (valeurs), 429 (trop d'avis).

### `POST /themes/{slug}/reviews/delete`

Corps : `{"token": "<reçu>"}`. Réponse : `{"deleted": true | false}`.

## Pour les tests

`alweb.themes.client.Client(url, {"transport": fn})` accepte un transport de remplacement :
`fn(méthode, url, corps, en-têtes)` rend `{"status", "headers" (noms en minuscules), "body"}`. Les tests
d'alweb (`tests/test_theme_client.al`) simulent ainsi une marketplace complète, archives signées comprises.
