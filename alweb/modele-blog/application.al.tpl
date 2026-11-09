# Application {{Nom}} (blog). creer(cfg, dossier) construit l'App sans la lancer : main.al la lance, les tests
# l'importent et `alweb routes` l'inspecte. Les pages viennent du thème actif (themes/, alweb.lock) ; un gabarit du
# même nom dans templates/ le remplace.
#
#   /                               accueil : article à la une et derniers articles
#   /blog?page=N                    tous les articles, 8 par page ; /blog/categorie/<rubrique> : une catégorie
#   /blog/<slug>                    un article et trois articles de la même catégorie
#   /about, /contact                pages du thème ; les demandes de contact sont enregistrées
from core use len, to_int
from collections use append, keys
use os
use string as _s
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.orm as orm
use alweb.alexdb as axdb
use alweb.themes as themes
use modeles

const PAR_PAGE := 8
const MOIS := ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
PRESENTATION := "Un blog écrit à plusieurs mains : des guides pratiques, des retours d'expérience et quelques coups de cœur."

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

# « 2026-11-08 » -> « 8 novembre 2026 » (texte tel quel s'il n'a pas cette forme).
func date_texte(iso):
    p := _s.split(iso if iso != null else "", "-")
    if len(p) != 3:
        return iso
    try:
        return str(to_int(p[2])) + " " + MOIS[to_int(p[1]) - 1] + " " + p[0]
    catch e:
        return iso

# Minutes de lecture (environ 200 mots par minute, 1 au moins).
func lecture(texte):
    return len(_s.split(texte if texte != null else "", " ")) // 200 + 1

func url_article(a):
    return "/blog/" + a["slug"]

# Article pour une liste du thème : {titre, url, resume, image, categorie, date, auteur, lecture}.
func carte(a):
    return {"titre": a["titre"], "url": url_article(a), "resume": a["resume"], "image": a["image"], "categorie": a["categorie"],
            "date": date_texte(a["publie_le"]), "auteur": a["auteur"], "lecture": lecture(a["contenu"])}

func cartes(articles):
    return [carte(a) for a in articles]

func publies():
    return modeles.ARTICLES.where("publie", true)

# Catégories des articles publiés, avec leur nombre d'articles.
async func categories(db, actif=null):
    nombres := {}
    noms := {}
    ordre := []
    tous := await publies().order_by("categorie").all(db)
    for a in tous:
        r := a["rubrique"]
        if not (r in nombres):
            nombres[r] = 0
            noms[r] = a["categorie"]
            append(ordre, r)
        nombres[r] = nombres[r] + 1
    return [{"nom": noms[r], "url": "/blog/categorie/" + r, "actif": r == actif, "nombre": nombres[r]} for r in ordre]

func numero_page(req):
    try:
        n := to_int(_s.trim(req.query_param("page", "1")))
        return n if n > 0 else 1
    catch e:
        return 1

func pagination(p, base):
    return {"page": p["page"], "pages": p["pages"],
            "precedente": base + "?page=" + str(p["page"] - 1) if p["page"] > 1 else null,
            "suivante": base + "?page=" + str(p["page"] + 1) if p["page"] < p["pages"] else null}

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

    # ------------------------------------------------ lecture

    @app.get("/", {"name": "accueil", "deps": ["db"]})
    async func accueil(req):
        db := req.deps["db"]
        derniers := await publies().order_by("-publie_le").limit(7).all(db)
        return alweb.render(req, "index.html", {"articles": cartes(derniers), "categories": await categories(db)})

    async func liste(req, rubrique):
        db := req.deps["db"]
        q := publies()
        base := "/blog"
        if rubrique != null:
            q = q.where("rubrique", rubrique)
            base = "/blog/categorie/" + rubrique
        p := await q.order_by("-publie_le").paginate(db, numero_page(req), PAR_PAGE)
        if rubrique != null and p["total"] == 0:
            alweb.abort(404, "catégorie introuvable")
        recents := await publies().order_by("-publie_le").limit(5).all(db)
        return alweb.render(req, "blog/index.html", {"articles": cartes(p["items"]), "pagination": pagination(p, base),
                                                     "categories": await categories(db, rubrique), "recents": cartes(recents),
                                                     "categorie": p["items"][0]["categorie"] if rubrique != null and len(p["items"]) > 0 else null})

    @app.get("/blog", {"name": "blog", "deps": ["db"]})
    async func blog(req):
        return await liste(req, null)

    @app.get("/blog/categorie/{rubrique:slug}", {"name": "categorie", "deps": ["db"]})
    async func categorie(req):
        return await liste(req, req.params["rubrique"])

    @app.get("/blog/{slug:slug}", {"name": "article", "deps": ["db"]})
    async func article(req):
        db := req.deps["db"]
        a := await publies().where("slug", req.params["slug"]).first(db)
        if a == null:
            alweb.abort(404, "article introuvable")
        proches := await publies().where("rubrique", a["rubrique"]).where("id", "!=", a["id"]).order_by("-publie_le").limit(3).all(db)
        fiche := carte(a)
        fiche["contenu"] = a["contenu"]
        fiche["categorie_url"] = "/blog/categorie/" + a["rubrique"]
        return alweb.render(req, "blog/detail.html", {"article": fiche, "similaires": cartes(proches)})

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
