# Exemple alweb : site vitrine avec un thème installable (ALWEB Templates). Lancement : examples/vitrine.al.
# Ce module ne fait que définir l'application (make_app), pour que les tests puissent l'importer.
#
# Montre : le thème « Modern Business » installé dans le projet (themes/, alweb.lock) au premier lancement,
# branché par themes.setup (pages du thème remplies avec ses données de démonstration, ressources versionnées,
# variables CSS), formulaire de contact avec CSRF, et l'administration avec la page « Apparence » (réglages
# du thème, aperçu en direct, logo envoyé dans alweb.storage) protégée par un mot de passe.
from core use len, to_int
use os
use io
use json
use alweb
use alweb.config as conf
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.auth as auth
use alweb.forms as forms
use alweb.admin as adm
use alweb.storage as storage
use alweb.ratelimit as rl
use alweb.themes as themes
use alweb.themes.registry as registry
use alweb.cli as cli
use alweb.templates as tpl
use web.http.response as response
use serialization.schema as sch

const CONNEXION := """<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connexion</title><link rel="stylesheet" href="{{ theme_css }}"><link rel="stylesheet" href="{{ asset('css/theme.css') }}"></head><body>
<section class="section"><div class="conteneur etroit"><h1>Administration</h1>{% if erreur %}<p class="flash erreur">{{ erreur }}</p>{% endif %}
<form class="formulaire" method="post" action="/connexion">{{ csrf_field() }}<input type="hidden" name="next" value="{{ next }}">
<label for="mdp">Mot de passe</label><input id="mdp" type="password" name="mdp" required autofocus>
<button class="bouton" type="submit">Se connecter</button></form></div></section></body></html>"""

CONTACT := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "message": sch.string(5, 4000)}, ["nom", "courriel", "message"])

# Installe le thème modèle dans le projet s'il n'y est pas encore (comme alweb theme create + install).
func preparer(root, modele):
    reg := registry.Registry(root)
    if not reg.installed("modern-business"):
        src := os.join(root, ".sources", "modern-business")
        if os.exists(src):
            os.rmdir(src, true)
        cli.create_theme("modern-business", {"dir": src, "modele": modele, "auteur": "Ennuum Group"})
        reg.install(src)
    return reg

func donnees(th):
    p := os.join(th.directory, "preview", "data.json")
    return json.parse(io.read_file(p)) if os.isfile(p) else {}

# root : dossier du projet (thème installé dans root/themes, choix dans root/config, fichiers dans root/media) ;
# modele : dossier modele-theme du paquet alweb ; admin_password : mot de passe de /admin ; secret : clé des
# sessions (32 caractères au moins).
func make_app(root, modele, admin_password, secret):
    os.mkdir_all(root)
    preparer(root, modele)
    app := alweb.App("Vitrine")
    app.configure(conf.from_dict({"secret_key": secret, "storage": {"url": "file:" + os.join(root, "media")}}))
    app.middleware([mw.security_headers(), sessions.middleware(secret), csrf.middleware()])
    storage.setup(app)
    th := themes.setup(app, null, {"root": root})
    data := donnees(th)
    articles := data["blog/index"]["articles"] if "blog/index" in data else []
    i := 0
    for a in articles:
        i += 1
        a["url"] = "/blog/" + str(i)

    func ctx(page, extra=null):
        c := {}
        for src in [data["commun"] if "commun" in data else {}, data[page] if page in data else {}, extra if extra != null else {}]:
            for k in src:
                c[k] = src[k]
        return c

    func vue(page, fichier):
        return (req) => alweb.render(req, fichier, ctx(page))

    app.get("/", vue("index", "index.html"), {"name": "accueil"})
    app.get("/services", vue("services", "services.html"))
    app.get("/about", vue("about", "about.html"))
    app.get("/blog", (req) => alweb.render(req, "blog/index.html", ctx("blog/index", {"articles": articles, "pagination": null})))

    @app.get("/blog/{n:int}")
    func article(req):
        n := req.params["n"]
        if n < 1 or n > len(articles):
            alweb.abort(404, "article introuvable")
        a := articles[n - 1]
        modele_article := data["blog/detail"]["article"] if "blog/detail" in data else {}
        detail := {"titre": a["titre"], "date": a["date"], "auteur": modele_article["auteur"] if "auteur" in modele_article else "",
                   "contenu": modele_article["contenu"] if "contenu" in modele_article else a["resume"]}
        return alweb.render(req, "blog/detail.html", ctx("blog/detail", {"article": detail}))

    @app.get("/contact")
    func contact(req):
        return alweb.render(req, "contact.html", ctx("contact", {"form": null, "envoye": false}))

    @app.post("/contact")
    func envoyer(req):
        f := alweb.validate_form(req, CONTACT)
        if not f.valid:
            return alweb.render(req, "contact.html", ctx("contact", {"form": f, "envoye": false}), 422)
        print("message de " + f.data["nom"] + " <" + f.data["courriel"] + "> : " + f.data["message"])
        return alweb.render(req, "contact.html", ctx("contact", {"form": null, "envoye": true}))

    # ------------------------------------------------ administration (page « Apparence »)
    etat := {"empreinte": null}

    @app.on_startup
    async func demarrer():
        etat["empreinte"] = await auth.hash_password(admin_password)

    env := tpl.Environment()
    env.add("connexion.html", CONNEXION)
    env.globals["asset"] = (p) => th.asset(app, p, false)
    env.globals["theme_css"] = themes.CSS_ROUTE + "?v=" + th.css_hash

    func page_connexion(req, suite, erreur, statut):
        return response.html(env.render("connexion.html", {"csrf_field": () => csrf.field(req), "next": suite, "erreur": erreur}), statut)

    app.get("/connexion", (req) => page_connexion(req, req.query_param("next", "/admin/_apparence"), null, 200))

    @app.post("/connexion", {"middleware": [rl.limit(5, 60, null, null, "connexion")]})
    async func connexion(req):
        f := forms.form(req)
        suite := f.get("next", "/admin/_apparence")
        if not (suite[0:1] == "/" and suite[1:2] != "/"):
            suite = "/admin/_apparence"
        if not await auth.verify_password(f.get("mdp", ""), etat["empreinte"]):
            return page_connexion(req, suite, "Mot de passe incorrect.", 401)
        auth.login(req, 1, ["admin"])
        return alweb.redirect(suite, 303)

    adm.Admin(app, {"title": "Vitrine", "jobs": false})
    return app
