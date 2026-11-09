# {{nom}} — thème blog

Thème de blog pour alweb : article à la une, grille des derniers articles, liste paginée avec catégories,
barre latérale, page de lecture confortable (police dédiée) et articles similaires.

## Installation

```sh
alweb theme validate && alweb theme package
cd ../mon-projet
alweb theme install ../{{slug}}/dist/{{slug}}-0.1.0.alwt
```

Un projet créé avec `alweb new <nom> --domaine blog` contient déjà les routes, la table des articles et ce thème.

## Pages et données attendues

| Gabarit | Variables |
|---|---|
| `index.html` | `articles` (le premier est à la une), `categories` |
| `blog/index.html` | `articles`, `categories` (`{nom, url, actif, nombre}`), `categorie`, `recents`, `recherche`, `pagination` (`{page, pages, precedente, suivante}`) |
| `blog/detail.html` | `article` (`{titre, resume, contenu, image, categorie, categorie_url, date, auteur, lecture}`), `similaires` |

Un article de liste : `{titre, url, resume, image, categorie, date, auteur, lecture}` (`lecture` : minutes).

## Réglages

Couleurs, police de l'interface et police des articles, taille, largeur, barre latérale, auteur et présentation,
logo, menu, réseaux sociaux, pied de page : page « Apparence » ou `config/theme.{{slug}}.json` du projet.
