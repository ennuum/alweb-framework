# {{nom}}

Thème ALWEB (`{{slug}}`, domaine « portfolio ») : portfolio — présentation, projets en grille, filtre par catégorie, fiche projet avec galerie, à propos, contact, page 404.

```sh
alweb theme validate                 # contrôle le thème
alweb theme preview                  # aperçu : ordinateur, tablette, mobile
alweb theme package                  # archive dist/{{slug}}-0.1.0.alwt
```

Dans un projet : `alweb theme install chemin/{{slug}}-0.1.0.alwt` (le thème est branché dans l'application
automatiquement). Un projet créé avec `alweb new <nom> --domaine portfolio` contient déjà ce thème, les routes et les
tables qui l'alimentent.

Pages, données attendues et réglages : `documentation/installation.md`. Les données d'exemple de l'aperçu sont
dans `preview/data.json` ; toutes les pages ont un état vide propre.
