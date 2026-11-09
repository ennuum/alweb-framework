# {{nom}} — thème portfolio

Thème de portfolio pour alweb : grande présentation, projets en grille, filtre par catégorie, fiche projet
(visuel, informations, texte, galerie) et appel au contact.

## Installation

```sh
alweb theme validate && alweb theme package
cd ../mon-projet
alweb theme install ../{{slug}}/dist/{{slug}}-0.1.0.alwt
```

Un projet créé avec `alweb new <nom> --domaine portfolio` contient déjà les routes, la table des projets et ce thème.

## Pages et données attendues

| Gabarit | Variables |
|---|---|
| `index.html` | `projets` (projets choisis), `competences` (`{titre, texte}`) |
| `projets/index.html` | `projets`, `categories` (`{nom, url, actif}`), `categorie` |
| `projets/detail.html` | `projet` (`{titre, resume, description, image, images, client, categorie, annee, lien}`), `autres` |

Un projet de liste : `{titre, url, image, categorie, annee, resume}`.

## Réglages

Couleurs, police du texte et des titres, taille, largeur, mention « disponible », adresse e-mail affichée, logo,
menu, réseaux sociaux, pied de page : page « Apparence » ou `config/theme.{{slug}}.json` du projet.
