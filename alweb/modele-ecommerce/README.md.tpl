# {{Nom}}

{{description}}

Boutique en ligne [alweb](https://github.com/ennuum/alweb) créée par `alweb new --domaine ecommerce` : catalogue
avec rayons, fiche produit, panier (gardé dans la session), commande enregistrée avec mise à jour du stock,
pages À propos et Contact. L'interface vient du thème du projet (`themes/`), déjà installé et actif.

## Démarrer

```sh
alweb run            # http://127.0.0.1:8000/ : debug, rechargement à chaud (profil dev)
alweb test           # tests (profil test, base en mémoire)
alweb routes         # routes de l'application
```

Au premier démarrage, six produits d'exemple sont ajoutés si la table est vide (`modeles.EXEMPLES`) ;
`"exemples": false` dans `config/base.json` pour ne pas les ajouter.

## Organisation

| Fichier | Rôle |
|---|---|
| `application.al` | routes : catalogue, panier, commande, contact |
| `modeles.al` | tables `produits`, `commandes`, `lignes_commande`, `contacts` ; produits d'exemple |
| `themes/`, `alweb.lock` | thème installé (pages, styles, réglages) |
| `config/theme.<thème>.json` | vos réglages du thème : couleurs, devise, bandeau, menu… (ou page Apparence de l'administration) |
| `templates/` | un gabarit du même nom qu'une page du thème la remplace (copiez-le depuis `themes/`) |
| `static/produits/` | images des produits d'exemple |

Prix en centimes dans la base (`prix`, `prix_barre`) ; `prix_texte` les affiche (« 18,90 »), la devise vient du
réglage « boutique.devise » du thème. Le paiement en ligne n'est pas inclus : la commande est enregistrée avec le
statut « nouvelle » (paiement à la livraison).

## Production

```sh
alweb secret                                        # une clé pour ALWEB_SECRET_KEY
ALWEB_ENV=prod ALWEB_SECRET_KEY=... alweb run
alweb deploy systemd caddy                          # ou docker, nginx : fichiers écrits dans deploy/
```
