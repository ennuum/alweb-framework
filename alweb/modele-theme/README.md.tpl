# {{nom}}

Thème ALWEB (`{{slug}}`) : site vitrine d'entreprise — accueil, services, à propos, blog, contact, page 404.

```sh
alweb theme validate                 # contrôle le thème
alweb theme preview                  # aperçu : ordinateur, tablette, mobile
alweb theme package                  # archive dist/{{slug}}-0.1.0.alwt
```

Dans un projet : `alweb theme install chemin/{{slug}}-0.1.0.alwt`, puis `themes.setup(app)` dans l'application
(voir `documentation/installation.md`).

## Pages et données attendues

| Gabarit | Variables |
|---|---|
| `index.html` | `services` (liste de `{titre, texte, lien}`), `articles` (liste de `{titre, resume, url, date}`) |
| `services.html` | `services` |
| `about.html` | `presentation` (texte), `equipe` (liste de `{nom, role}`) |
| `contact.html` | `form` (résultat de `alweb.validate_form`, facultatif), `envoye` (booléen), `contact_action` |
| `blog/index.html` | `articles`, `pagination` (`{page, pages, precedente, suivante}`, facultatif) |
| `blog/detail.html` | `article` (`{titre, contenu, auteur, date, image}`) |

Toutes les pages ont un état vide propre : un thème installé s'affiche avant même que l'application n'envoie de
données. Les données d'exemple de l'aperçu sont dans `preview/data.json`.

## Paramètres

Couleurs, police, largeur, logo, menu, réseaux sociaux, texte du pied de page : `config/theme.json`. Un projet les
change dans `config/theme.{{slug}}.json` (seules les valeurs modifiées).
