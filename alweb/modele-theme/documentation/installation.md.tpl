# Installer {{nom}}

```sh
alweb theme install {{slug}}-0.1.0.alwt      # dans le projet : themes/{{slug}}/, alweb.lock
alweb theme activate {{slug}}                # s'il n'est pas déjà le thème actif
```

```al
use alweb
use alweb.themes as themes

app := alweb.App("Mon entreprise")
app.configure(alweb.load_config("config"))
themes.setup(app)

@app.get("/", {"name": "accueil"})
func accueil(req):
    return alweb.render(req, "index.html", {"services": [{"titre": "Conseil", "texte": "…", "lien": "/services"}]})
```

Le menu, les couleurs et le logo se règlent dans `config/theme.{{slug}}.json` :

```json
{"site": {"nom": "Mon entreprise"}, "couleurs": {"primaire": "#1f6feb"},
 "menu": [{"label": "Accueil", "url": "/"}, {"label": "Contact", "url": "/contact"}]}
```

Une page à adapter : copiez-la dans `templates/` du projet (même nom) ; elle remplace celle du thème, que les
mises à jour ne touchent pas.
