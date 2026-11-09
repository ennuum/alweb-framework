# Application {{Nom}} (portfolio). creer(cfg, dossier) construit l'App sans la lancer : main.al la lance, les
# tests l'importent et `alweb routes` l'inspecte. Les pages viennent du thème actif (themes/, alweb.lock) ; un
# gabarit du même nom dans templates/ le remplace.
#
#   /                               présentation, projets choisis (« vedette ») et compétences
#   /projets                        tous les projets ; /projets/categorie/<rubrique> : une catégorie
#   /projets/<slug>                 fiche projet et deux autres projets
#   /about, /contact                pages du thème ; les demandes de contact sont enregistrées
from core use len
from collections use append
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

PRESENTATION := "Je travaille depuis dix ans avec des marques, des éditeurs et des associations, du premier croquis au fichier final."
COMPETENCES := [
    {"titre": "Identité visuelle", "texte": "Logos, chartes et déclinaisons qui tiennent dans le temps."},
    {"titre": "Édition", "texte": "Livres, revues, rapports : mise en page soignée et lisible."},
    {"titre": "Web", "texte": "Sites et interfaces simples, rapides et accessibles."}
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
    if app.config.get("exemples", true):
        await modeles.exemples(db)
    return db

async func fermer_base(db):
    await db.close()

# Projet pour une liste du thème : {titre, url, image, categorie, annee, resume}.
func carte(p):
    return {"titre": p["titre"], "url": "/projets/" + p["slug"], "image": p["image"], "categorie": p["categorie"],
            "annee": p["annee"], "resume": p["resume"]}

func cartes(projets):
    return [carte(p) for p in projets]

async func categories(db, actif=null):
    vus := {}
    out := []
    tous := await modeles.PROJETS.query().order_by("categorie").all(db)
    for p in tous:
        if not (p["rubrique"] in vus):
            vus[p["rubrique"]] = true
            append(out, {"nom": p["categorie"], "url": "/projets/categorie/" + p["rubrique"], "actif": p["rubrique"] == actif})
    return out

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

    # ------------------------------------------------ projets

    @app.get("/", {"name": "accueil", "deps": ["db"]})
    async func accueil(req):
        choisis := await modeles.PROJETS.where("vedette", true).order_by("ordre").limit(6).all(db_de(req))
        return alweb.render(req, "index.html", {"projets": cartes(choisis), "competences": COMPETENCES})

    @app.get("/projets", {"name": "projets", "deps": ["db"]})
    async func projets(req):
        db := db_de(req)
        tous := await modeles.PROJETS.query().order_by("ordre").all(db)
        return alweb.render(req, "projets/index.html", {"projets": cartes(tous), "categories": await categories(db), "categorie": null})

    @app.get("/projets/categorie/{rubrique:slug}", {"name": "categorie", "deps": ["db"]})
    async func categorie(req):
        db := db_de(req)
        liste := await modeles.PROJETS.where("rubrique", req.params["rubrique"]).order_by("ordre").all(db)
        if len(liste) == 0:
            alweb.abort(404, "catégorie introuvable")
        return alweb.render(req, "projets/index.html", {"projets": cartes(liste), "categories": await categories(db, req.params["rubrique"]),
                                                        "categorie": liste[0]["categorie"]})

    @app.get("/projets/{slug:slug}", {"name": "projet", "deps": ["db"]})
    async func projet(req):
        db := db_de(req)
        p := await modeles.PROJETS.where("slug", req.params["slug"]).first(db)
        if p == null:
            alweb.abort(404, "projet introuvable")
        autres := await modeles.PROJETS.where("id", "!=", p["id"]).order_by("ordre").limit(2).all(db)
        fiche := carte(p)
        for k in ["description", "client", "lien", "images"]:
            fiche[k] = p[k]
        return alweb.render(req, "projets/detail.html", {"projet": fiche, "autres": cartes(autres)})

    # ------------------------------------------------ pages du thème

    @app.get("/about", {"name": "a_propos"})
    func a_propos(req):
        return alweb.render(req, "about.html", {"presentation": PRESENTATION})

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

func db_de(req):
    return req.deps["db"]
