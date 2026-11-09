# Le blog du tutoriel. creer(cfg, dossier) construit l'App sans la lancer : main.al la lance, les tests l'importent
# et `alweb routes` l'inspecte. Les routes sont rangées par thème dans comptes.al, articles.al et api.al.
use os
use reflection as _refl
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.auth as auth
use alweb.orm as orm
use alweb.jobs as jobs
use alweb.admin as adm
use alweb.i18n as i18n
use modeles
use comptes
use articles
use api

async func ouvrir_base(app):
    url := app.config.require("database.url")
    if url == "memory:" and "sqlite" in dbm.backends():
        url = "sqlite::memory:"
    db := alweb.database(url)
    if app.config.get("database.migrate", true):
        await orm.migrate(db, modeles.MIGRATIONS)
    return db

async func fermer_base(db):
    await db.close()

# Utilisateur de la session (auth.current_user) : rechargé depuis la base à chaque requête qui le demande.
async func charger_utilisateur(req, id):
    db := await alweb.dep(req, "db")
    return await modeles.UTILISATEURS.get(db, id)

func creer(cfg, dossier="."):
    app := alweb.App(cfg.get("nom", "Blog"))
    app.configure(cfg)
    app.provide("db", ouvrir_base, "app", fermer_base)
    app.provide("user", auth.current_user(charger_utilisateur))
    # Tâches de fond rangées dans la base du blog (courriels de send_later, rappels) : elles survivent à un
    # redémarrage et sont partagées par les processus ouvriers.
    jobs.Queue(app, jobs.DatabaseStore(() => app.value("db")))

    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", "") != "":
        mws = mws + [mw.logger(cfg.get("journal"))]
    app.middleware(mws + [sessions.middleware(cfg.require("secret_key")), csrf.middleware(["/api/"])])
    # Français et anglais : catalogues locales/<langue>.json, langue du navigateur ou choisie en pied de page
    # (?lang=en, retenue par un cookie). Les clés sont le texte français : fr.json ne contient que les pluriels.
    i18n.I18n(app, os.join(dossier, "locales"), {"default": "fr", "locales": ["fr", "en"]})
    app.use_templates(os.join(dossier, "templates"))
    app.static("/static", os.join(dossier, "static"))

    # current_user dans tous les gabarits (null pour un visiteur).
    @app.context_processor
    func utilisateur_courant(req):
        connu := _refl.has_field(req, "deps") and req.deps != null and "user" in req.deps
        return {"current_user": req.deps["user"] if connu else null}

    comptes.installer(app, cfg)
    articles.installer(app, cfg)
    api.installer(app, cfg)

    # Administration (réservée au rôle admin) : comptes, articles, commentaires, et la page des tâches de fond.
    admin := adm.Admin(app, {"title": "Administration du blog"})
    admin.register(modeles.UTILISATEURS, {"exclude": ["mdp"], "display": "nom", "list": ["id", "nom", "courriel", "confirme", "cree_le"], "search": ["nom", "courriel"], "filters": ["confirme"], "can_create": false})
    admin.register(modeles.ARTICLES, {"display": "titre", "list": ["id", "titre", "auteur_id", "cree_le"], "search": ["titre", "texte"], "filters": ["auteur_id"]})
    admin.register(modeles.COMMENTAIRES, {"list": ["id", "article_id", "auteur_id", "cree_le"], "search": ["texte"]})

    @app.get("/sante", {"name": "sante"})
    func sante(req):
        return {"statut": "ok", "application": app.name}

    return app
