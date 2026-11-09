# Application {{Nom}}. creer(cfg, dossier) construit l'App sans la lancer : main.al la lance, les tests
# l'importent et `alweb routes` l'inspecte. dossier : racine du projet (gabarits dans templates/, fichiers
# statiques dans static/).
use os
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.ratelimit as rl
use alweb.orm as orm
use alweb.alexdb as axdb
use alweb.themes as themes
use modeles

# Base de données (portée app) : ouverte au démarrage de chaque processus, migrée, fermée à l'arrêt.
# « memory: » : SQLite en mémoire (profil test). Serveur ALEX DB (alexdb://) avec database.create : la base est
# créée si elle manque (compte super-utilisateur, comme pour les migrations).
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

async func derniers_messages(db):
    return await modeles.MESSAGES.order_by("-id").limit(20).all(db)

func creer(cfg, dossier="."):
    app := alweb.App(cfg.get("nom", "{{Nom}}"))
    app.configure(cfg)
    app.provide("db", ouvrir_base, "app", fermer_base)

    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", "") != "":
        mws = mws + [mw.logger(cfg.get("journal"))]
    app.middleware(mws + [sessions.middleware(cfg.require("secret_key")), csrf.middleware(["/api/"])])
    themes.setup(app, null, {"root": dossier})     # thème actif (alweb.lock) ; sinon templates/ seul
    app.static("/static", os.join(dossier, "static"))

    # ------------------------------------------------ pages

    @app.get("/", {"name": "accueil", "deps": ["db"]})
    async func accueil(req):
        return alweb.render(req, "index.html", {"messages": await derniers_messages(req.deps["db"]), "form": null})

    @app.post("/messages", {"name": "publier", "deps": ["db"]})
    async func publier(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, modeles.MESSAGE)
        if not f.valid:
            return alweb.render(req, "index.html", {"messages": await derniers_messages(db), "form": f}, 422)
        await modeles.MESSAGES.insert(db, {"auteur": f.data["auteur"], "texte": f.data["texte"]})
        alweb.session(req).flash("Message publié.", "succes")
        return alweb.redirect(app.url_for("accueil"), 303)

    # ------------------------------------------------ API JSON (sans session ni CSRF, débit limité par IP)

    api := app.group("/api", [rl.limit(cfg.get("api.limite", 120), 60)], ["db"])

    @api.get("/messages")
    async func api_messages(req):
        return {"messages": await derniers_messages(req.deps["db"])}

    @api.post("/messages", {"body": modeles.MESSAGE})
    async func api_publier(req):
        d := alweb.data(req)
        id := await modeles.MESSAGES.insert(req.deps["db"], {"auteur": d["auteur"], "texte": d["texte"]})
        return ({"id": id}, 201)

    # ------------------------------------------------ supervision (mandataire, Docker, systemd)

    @app.get("/sante", {"name": "sante"})
    func sante(req):
        return {"statut": "ok", "application": app.name}

    return app
