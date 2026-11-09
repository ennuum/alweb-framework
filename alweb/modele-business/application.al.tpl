# Application {{Nom}} (site vitrine d'entreprise). creer(cfg, dossier) construit l'App sans la lancer : main.al la
# lance, les tests l'importent et `alweb routes` l'inspecte. Les pages viennent du thème actif (themes/,
# alweb.lock) ; un gabarit du même nom dans templates/ le remplace.
#
#   /, /services, /about            contenu des constantes SERVICES, PRESENTATION, EQUIPE (à remplacer)
#   /blog, /blog/<slug>             actualités (constante ACTUALITES)
#   /contact                        formulaire ; les demandes sont enregistrées (table contacts)
from core use len
use os
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.orm as orm
use alweb.alexdb as axdb
use alweb.themes as themes
use modeles

# Contenu du site : à remplacer par le vôtre.
SERVICES := [
    {"titre": "Conseil", "texte": "Un regard extérieur sur votre organisation et vos outils.", "lien": "/contact"},
    {"titre": "Développement", "texte": "Des applications web sur mesure, rapides et sûres.", "lien": "/contact"},
    {"titre": "Formation", "texte": "Vos équipes autonomes sur les outils qu'elles utilisent.", "lien": "/contact"}
]
PRESENTATION := "Nous aidons les entreprises à concevoir et faire vivre leurs outils numériques."
EQUIPE := [{"nom": "Awa Koné", "role": "Direction"}, {"nom": "Bruno Diallo", "role": "Développement"}, {"nom": "Chloé Martin", "role": "Design"}]
ACTUALITES := [
    {"slug": "nouveaux-locaux", "titre": "Nos nouveaux locaux", "date": "8 novembre 2026", "auteur": "Awa Koné",
     "resume": "Nous vous accueillons désormais au centre-ville.", "contenu": "Après six ans, l'équipe s'installe dans des bureaux plus grands, à deux pas de la gare.\n\nVenez nous rendre visite !"},
    {"slug": "pourquoi-un-theme", "titre": "Pourquoi un thème ?", "date": "2 novembre 2026", "auteur": "Bruno Diallo",
     "resume": "Séparer l'interface du code métier change la vie d'une équipe.", "contenu": "Un thème regroupe les pages, les styles et les réglages.\n\nL'application garde ses routes et ses données : on peut changer d'apparence sans toucher au code."}
]

async func ouvrir_base(app):
    url := app.config.require("database.url")
    if url == "memory:" and "sqlite" in dbm.backends():
        url = "sqlite::memory:"
    if axdb.is_url(url) and app.config.get("database.create", false):
        await axdb.ensure_database(url)
    db := alweb.database(url)
    if app.config.get("database.migrate", true):
        await orm.migrate(db, modeles.MIGRATIONS)
    return db

async func fermer_base(db):
    await db.close()

func actualites():
    return [{"titre": a["titre"], "resume": a["resume"], "date": a["date"], "url": "/blog/" + a["slug"]} for a in ACTUALITES]

func creer(cfg, dossier="."):
    app := alweb.App(cfg.get("nom", "{{Nom}}"))
    app.configure(cfg)
    app.provide("db", ouvrir_base, "app", fermer_base)

    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", "") != "":
        mws = mws + [mw.logger(cfg.get("journal"))]
    app.middleware(mws + [sessions.middleware(cfg.require("secret_key")), csrf.middleware(["/api/"])])
    themes.setup(app, null, {"root": dossier})     # thème actif (alweb.lock) ; templates/ du projet passe avant
    app.static("/static", os.join(dossier, "static"))

    # ------------------------------------------------ pages

    @app.get("/", {"name": "accueil"})
    func accueil(req):
        return alweb.render(req, "index.html", {"services": SERVICES, "articles": actualites()})

    @app.get("/services", {"name": "services"})
    func services(req):
        return alweb.render(req, "services.html", {"services": SERVICES})

    @app.get("/about", {"name": "a_propos"})
    func a_propos(req):
        return alweb.render(req, "about.html", {"presentation": PRESENTATION, "equipe": EQUIPE})

    @app.get("/blog", {"name": "blog"})
    func blog(req):
        return alweb.render(req, "blog/index.html", {"articles": actualites(), "recents": actualites()})

    @app.get("/blog/{slug:slug}", {"name": "article"})
    func article(req):
        for a in ACTUALITES:
            if a["slug"] == req.params["slug"]:
                return alweb.render(req, "blog/detail.html", {"article": a})
        alweb.abort(404, "article introuvable")

    @app.get("/contact", {"name": "contact"})
    func contact(req):
        return alweb.render(req, "contact.html", {"form": null, "envoye": false})

    @app.post("/contact", {"name": "contact_envoi", "deps": ["db"]})
    async func contact_envoi(req):
        f := alweb.validate_form(req, modeles.CONTACT)
        if not f.valid:
            return alweb.render(req, "contact.html", {"form": f, "envoye": false}, 422)
        await modeles.CONTACTS.insert(req.deps["db"], {"nom": f.data["nom"], "courriel": f.data["courriel"], "message": f.data["message"]})
        return alweb.render(req, "contact.html", {"form": null, "envoye": true})

    # ------------------------------------------------ supervision (mandataire, Docker, systemd)

    @app.get("/sante", {"name": "sante"})
    func sante(req):
        return {"statut": "ok", "application": app.name}

    return app
