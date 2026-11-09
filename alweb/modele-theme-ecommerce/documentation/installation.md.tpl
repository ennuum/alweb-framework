# {{nom}} — thème e-commerce

Thème de boutique en ligne pour alweb : accueil avec rayons et sélection, catalogue filtrable, fiche produit,
panier et commande.

## Installation

```sh
alweb theme validate && alweb theme package
cd ../mon-projet
alweb theme install ../{{slug}}/dist/{{slug}}-0.1.0.alwt
```

Un projet créé avec `alweb new <nom> --domaine ecommerce` contient déjà les routes, les tables et ce thème.

## Pages et données attendues

| Gabarit | Variables |
|---|---|
| `index.html` | `produits` (sélection), `categories` |
| `boutique/index.html` | `produits`, `categories` (`{nom, url, actif}`), `categorie` (rayon affiché) |
| `boutique/produit.html` | `produit` (`{id, nom, image, prix, prix_barre, resume, description, stock, categorie}`), `similaires` ; formulaire envoyé à `ajout_action` (défaut `/panier/ajouter`, champs `produit`, `quantite`) |
| `panier.html` | `lignes` (`{id, nom, url, image, prix, quantite, total}`), `total` ; formulaire `maj_action` (défaut `/panier`, champs `q_<id>`) |
| `commande.html` | `lignes`, `total`, `form` ; `confirmee` et `numero` après la commande ; champs `nom`, `courriel`, `telephone`, `adresse` |
| toutes | `panier_nombre` (pastille du panier dans l'en-tête) |

Un produit de liste : `{nom, url, image, prix, prix_barre, categorie}`. Les prix sont des textes déjà formatés
(« 24,90 ») ; la devise vient du réglage « boutique.devise ».

## Réglages

Couleurs (dont la couleur des promotions), police, largeur, devise, bandeau d'annonce, nombre de produits par
ligne, logo, menu, réseaux sociaux, texte du pied de page : page « Apparence » de l'administration, ou
`config/theme.{{slug}}.json` du projet.
