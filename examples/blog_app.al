# Exemple alweb : blog multi-utilisateur (jalon de la phase 3). Lancement : examples/blog.al.
# Ce module ne fait que définir l'application (make_app(config)), pour que les tests puissent l'importer.
#
# Montre : gabarits (héritage, macros, échappement), sessions signées, CSRF, comptes (empreintes PBKDF2 calculées
# hors de la boucle), gardes login_required et rôles, ORM (tables, migrations, relations, pagination) sur SQLite
# ou PostgreSQL, API JSON protégée par jeton JWT (Bearer), et les fichiers : photo d'article réduite en vignette
# (liste) et en grande image (article) par alweb.images, pièce jointe PDF réservée aux lecteurs connectés (lien
# signé de 5 minutes), le tout rangé par alweb.storage (dossier media/ en dev, mémoire en test, S3 en production
# avec ALWEB_STORAGE__URL=s3://…). Les images publiques passent aussi par des liens signés, stables pendant une
# heure (le navigateur les garde en cache).
#
# Le premier compte créé reçoit le rôle « admin » (il peut modifier et supprimer tous les articles) ; les suivants
# sont « auteur » (leurs articles seulement). Tout visiteur connecté peut commenter. Les administrateurs ont
# aussi /admin (alweb.admin) : comptes (sans les empreintes de mot de passe), articles et commentaires.
#
#   curl -X POST localhost:8000/api/jeton -H 'Content-Type: application/json' -d '{"nom": "alice", "mdp": "..."}'
#   curl localhost:8000/api/articles
#   curl -X POST localhost:8000/api/articles -H 'Authorization: Bearer <jeton>' -H 'Content-Type: application/json' \
#        -d '{"titre": "Depuis l API", "texte": "Bonjour"}'
from core use len, to_int
from collections use append
use os
use string as _s
use reflection as _refl
use serialization.schema as sch
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.forms as forms
use alweb.auth as auth
use alweb.orm as orm
use alweb.admin as adm
use alweb.storage as storage
use alweb.images as images

# ---------------------------------------------------------------- modèle

UTILISATEURS := orm.table("utilisateurs", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(), "roles": orm.json(default=["auteur"]), "cree_le": orm.timestamp(auto=true)})
# photo : {"vignette", "grande", "largeur", "hauteur"} (clés du stockage) ; piece : {"cle", "nom", "taille"}.
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(120), "texte": orm.text(), "photo": orm.json(), "piece": orm.json(), "auteur_id": orm.ref("utilisateurs"), "cree_le": orm.timestamp(auto=true)})
COMMENTAIRES := orm.table("commentaires", {"id": orm.pk(), "article_id": orm.ref("articles"), "auteur_id": orm.ref("utilisateurs"), "texte": orm.text(2000), "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "tables", [UTILISATEURS, ARTICLES, COMMENTAIRES]),
    orm.migration(2, "index", ["CREATE INDEX articles_auteur ON articles (auteur_id)", "CREATE INDEX commentaires_article ON commentaires (article_id)"]),
    # bases d'avant alweb.storage : la colonne image (fichier de media/) reste, inutilisée
    orm.migration(3, "fichiers", [orm.add_column(ARTICLES, "photo"), orm.add_column(ARTICLES, "piece")])
]

COMPTE := sch.object({"nom": sch.string(3, 40), "mdp": sch.string(8, 200)}, ["nom", "mdp"])
ARTICLE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(1, 50000)}, ["titre", "texte"])
COMMENTAIRE := sch.object({"texte": sch.string(1, 2000)}, ["texte"])
IDENTIFIANTS := sch.object({"nom": sch.string(1, 40), "mdp": sch.string(1, 200)}, ["nom", "mdp"])

TAILLE_PHOTO := 15000000                 # photos de téléphone comprises
TAILLE_PIECE := 5000000
# vignette 16:9 recadrée pour la liste, grande image pour l'article ; l'original n'est pas gardé
TAILLES := {"vignette": [480, 270, "cover"], "grande": [1200, 1200, "fit"]}

# ---------------------------------------------------------------- dépendances

# Base (portée app) : ouverte au démarrage, migrations appliquées, fermée à l'arrêt. « memory: » : SQLite en
# mémoire si SQLite est disponible.
async func ouvrir_base(app):
    url := app.config.require("database.url")
    if url == "memory:" and "sqlite" in dbm.backends():
        url = "sqlite::memory:"
    db := alweb.database(url)
    await orm.migrate(db, MIGRATIONS)
    return db

async func fermer_base(db):
    await db.close()

async func charger_utilisateur(req, id):
    db := await alweb.dep(req, "db")
    return await UTILISATEURS.get(db, id)

func peut_modifier(user, article):
    return user != null and article != null and (user["id"] == article["auteur_id"] or "admin" in user["roles"])

func formulaire_vide(values=null):
    return forms.FormResult(true, values if values != null else {}, null, {})

func erreur_formulaire(values, message, champ=""):
    return forms.FormResult(false, values, null, {champ: message})

func sans_mdp(u):
    return {"id": u["id"], "nom": u["nom"]} if u != null else null

# ---------------------------------------------------------------- application

# dossier : dossier de l'exemple (gabarits dans templates/, fichiers statiques dans static/).
func make_app(cfg, dossier="examples/blog"):
    app := alweb.App(cfg.get("nom", "blog"))
    app.configure(cfg)
    secret := cfg.require("secret_key")
    iterations := cfg.get("auth.iterations", 600000)
    par_page := cfg.get("par_page", 5)

    app.provide("db", ouvrir_base, "app", fermer_base)
    app.provide("user", auth.current_user(charger_utilisateur))
    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", false):
        mws = mws + [mw.logger()]
    app.middleware(mws + [sessions.middleware(secret), csrf.middleware(["/api/"])])
    app.use_templates(os.join(dossier, "templates"))
    app.static("/static", os.join(dossier, "static"))
    st := storage.setup(app)                  # clé « storage » ; liens signés servis sous /_fichiers/ (disque, mémoire)

    @app.context_processor
    func utilisateur_courant(req):
        return {"current_user": req.deps["user"] if _refl.has_field(req, "deps") and req.deps != null and "user" in req.deps else null,
                "media": (cle) => st.url(cle, 86400) if cle != null else ""}

    site := app.group("", null, ["db", "user"])
    connecte := [auth.login_required("/connexion")]

    # ------------------------------------------------ lecture

    @site.get("/", {"name": "accueil"})
    async func accueil(req):
        n := _s.trim(req.query_param("page", "1"))
        page := 1
        try:
            page = to_int(n)
        catch e:
            page = 1
        p := await ARTICLES.order_by("-id").with_one(UTILISATEURS, "auteur_id", "auteur").paginate(req.deps["db"], page, par_page)
        return alweb.render(req, "index.html", {"page": p})

    @site.get("/articles/{id:int}", {"name": "article"})
    async func voir(req):
        db := req.deps["db"]
        a := await ARTICLES.where("id", req.params["id"]).with_one(UTILISATEURS, "auteur_id", "auteur").first(db)
        if a == null:
            alweb.abort(404, "article introuvable")
        coms := await COMMENTAIRES.where("article_id", a["id"]).order_by("id").with_one(UTILISATEURS, "auteur_id", "auteur").all(db)
        return alweb.render(req, "article.html", {"article": a, "commentaires": coms, "peut_modifier": peut_modifier(req.deps["user"], a)})

    # ------------------------------------------------ comptes

    @site.get("/inscription")
    func inscription_page(req):
        return alweb.render(req, "compte.html", compte_ctx("Créer un compte", "S'inscrire", formulaire_vide(), "/"))

    @site.post("/inscription")
    async func inscription(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, COMPTE)
        if not f.valid:
            return alweb.render(req, "compte.html", compte_ctx("Créer un compte", "S'inscrire", f, "/"), 422)
        if await UTILISATEURS.where("nom", f.data["nom"]).exists(db):
            return alweb.render(req, "compte.html", compte_ctx("Créer un compte", "S'inscrire", erreur_formulaire(f.values, "ce nom est déjà pris", "nom"), "/"), 422)
        premier := (await UTILISATEURS.query().count(db)) == 0
        roles := ["admin", "auteur"] if premier else ["auteur"]
        id := await UTILISATEURS.insert(db, {"nom": f.data["nom"], "mdp": await auth.hash_password(f.data["mdp"], iterations), "roles": roles})
        auth.login(req, id, roles)
        alweb.session(req).flash("Bienvenue, " + f.data["nom"] + " !", "succes")
        return alweb.redirect("/", 303)

    @site.get("/connexion")
    func connexion_page(req):
        return alweb.render(req, "compte.html", compte_ctx("Connexion", "Se connecter", formulaire_vide(), auth.next_url(req, "/")))

    @site.post("/connexion")
    async func connexion(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, IDENTIFIANTS)
        nxt := auth.next_url(req, "/")
        if f.valid:
            u := await UTILISATEURS.where("nom", f.data["nom"]).first(db)
            if u != null and await auth.verify_password(f.data["mdp"], u["mdp"]):
                if auth.needs_rehash(u["mdp"]) and iterations >= 600000:
                    await UTILISATEURS.where("id", u["id"]).update(db, {"mdp": await auth.hash_password(f.data["mdp"], iterations)})
                auth.login(req, u["id"], u["roles"])
                alweb.session(req).flash("Vous êtes connecté.", "succes")
                return alweb.redirect(nxt, 303)
        return alweb.render(req, "compte.html", compte_ctx("Connexion", "Se connecter", erreur_formulaire(f.values, "nom ou mot de passe incorrect"), nxt), 401)

    @site.post("/deconnexion")
    func deconnexion(req):
        auth.logout(req)
        alweb.session(req).flash("À bientôt !", "info")
        return alweb.redirect("/", 303)

    # ------------------------------------------------ écriture

    @site.get("/ecrire", {"middleware": connecte})
    func ecrire_page(req):
        return alweb.render(req, "article_form.html", {"form": formulaire_vide(), "article": null})

    @site.post("/ecrire", {"middleware": connecte})
    async func ecrire(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, ARTICLE)
        fichiers := null
        if f.valid:
            fichiers = await enregistrer_fichiers(req, st)
            if fichiers[0] != null:
                f = erreur_formulaire(f.values, fichiers[1], fichiers[0])
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": null}, 422)
        id := await ARTICLES.insert(db, {"titre": f.data["titre"], "texte": f.data["texte"], "photo": fichiers[2], "piece": fichiers[3], "auteur_id": req.deps["user"]["id"]})
        alweb.session(req).flash("Article publié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": id}), 303)

    @site.get("/articles/{id:int}/modifier", {"name": "modifier", "middleware": connecte})
    async func modifier_page(req):
        a := await article_modifiable(req)
        return alweb.render(req, "article_form.html", {"form": formulaire_vide({"titre": a["titre"], "texte": a["texte"]}), "article": a})

    @site.post("/articles/{id:int}/modifier", {"middleware": connecte})
    async func modifier(req):
        db := req.deps["db"]
        a := await article_modifiable(req)
        f := alweb.validate_form(req, ARTICLE)
        valeurs := {}
        if f.valid:
            valeurs = {"titre": f.data["titre"], "texte": f.data["texte"]}
            fichiers := await enregistrer_fichiers(req, st)
            if fichiers[0] != null:
                f = erreur_formulaire(f.values, fichiers[1], fichiers[0])
            else:
                if fichiers[2] != null:                      # nouvelle photo : l'ancienne est retirée
                    valeurs["photo"] = fichiers[2]
                    await supprimer_fichiers(st, a["photo"], null)
                if fichiers[3] != null:
                    valeurs["piece"] = fichiers[3]
                    await supprimer_fichiers(st, null, a["piece"])
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": a}, 422)
        await ARTICLES.where("id", a["id"]).update(db, valeurs)
        alweb.session(req).flash("Article modifié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)

    @site.post("/articles/{id:int}/supprimer", {"middleware": connecte})
    async func supprimer(req):
        db := req.deps["db"]
        a := await article_modifiable(req)
        await COMMENTAIRES.where("article_id", a["id"]).delete(db)
        await ARTICLES.where("id", a["id"]).delete(db)
        await supprimer_fichiers(st, a["photo"], a["piece"])
        alweb.session(req).flash("Article supprimé.", "info")
        return alweb.redirect("/", 303)

    # Pièce jointe : réservée aux lecteurs connectés ; lien signé de 5 minutes vers le stockage (S3 : téléchargée
    # directement chez le fournisseur, sans passer par le serveur), sous son nom d'origine.
    @site.get("/articles/{id:int}/piece", {"name": "piece", "middleware": connecte})
    async func piece(req):
        a := await ARTICLES.get(req.deps["db"], req.params["id"])
        if a == null or a["piece"] == null:
            alweb.abort(404, "pas de pièce jointe")
        return alweb.redirect(st.url(a["piece"]["cle"], 300, a["piece"]["nom"]), 303)

    @site.post("/articles/{id:int}/commentaires", {"middleware": connecte})
    async func commenter(req):
        db := req.deps["db"]
        a := await ARTICLES.get(db, req.params["id"])
        if a == null:
            alweb.abort(404, "article introuvable")
        f := alweb.validate_form(req, COMMENTAIRE)
        if f.valid:
            await COMMENTAIRES.insert(db, {"article_id": a["id"], "auteur_id": req.deps["user"]["id"], "texte": f.data["texte"]})
            alweb.session(req).flash("Commentaire publié.", "succes")
        else:
            alweb.session(req).flash("Commentaire vide ou trop long.", "erreur")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)

    # ------------------------------------------------ API JSON (jeton Bearer, sans session ni CSRF)

    api := app.group("/api", null, ["db"])

    @api.post("/jeton", {"body": IDENTIFIANTS})
    async func jeton(req):
        d := alweb.data(req)
        u := await UTILISATEURS.where("nom", d["nom"]).first(req.deps["db"])
        if u == null or not await auth.verify_password(d["mdp"], u["mdp"]):
            return ({"erreur": "identifiants invalides"}, 401)
        return {"jeton": auth.jwt_encode({"sub": u["id"], "roles": u["roles"]}, secret, 3600), "expire_dans": 3600}

    @api.get("/articles")
    async func api_articles(req):
        page := 1
        try:
            page = to_int(req.query_param("page", "1"))
        catch e:
            page = 1
        p := await ARTICLES.order_by("-id").with_one(UTILISATEURS, "auteur_id", "auteur").paginate(req.deps["db"], page, par_page)
        items := []
        for a in p["items"]:
            photo := {"vignette": st.url(a["photo"]["vignette"], 86400), "grande": st.url(a["photo"]["grande"], 86400)} if a["photo"] != null else null
            append(items, {"id": a["id"], "titre": a["titre"], "texte": a["texte"], "photo": photo, "piece": a["piece"] != null, "auteur": sans_mdp(a["auteur"]), "cree_le": a["cree_le"]})
        return {"page": p["page"], "pages": p["pages"], "total": p["total"], "articles": items}

    @api.post("/articles", {"body": ARTICLE, "middleware": [auth.bearer(secret)]})
    async func api_publier(req):
        d := alweb.data(req)
        id := await ARTICLES.insert(req.deps["db"], {"titre": d["titre"], "texte": d["texte"], "auteur_id": auth.user_id(req)})
        r := alweb.json({"id": id}, 201)
        r.headers.set("Location", app.url_for("article", {"id": id}))
        return r

    # ------------------------------------------------ administration (rôle « admin »)

    admin := adm.Admin(app, {"title": "Administration du blog", "login_url": "/connexion"})
    admin.register(UTILISATEURS, {"label": "Comptes", "exclude": ["mdp"], "display": "nom", "can_create": false,
                                  "list": ["id", "nom", "roles", "cree_le"], "help": {"roles": "liste JSON, ex. [\"auteur\"]"}})
    admin.register(ARTICLES, {"label": "Articles", "list": ["id", "titre", "auteur_id", "cree_le"], "search": ["titre", "texte"],
                              "filters": ["auteur_id"], "display": "titre", "labels": {"auteur_id": "Auteur"}})
    admin.register(COMMENTAIRES, {"label": "Commentaires", "list": ["id", "texte", "article_id", "auteur_id", "cree_le"],
                                  "search": ["texte"], "filters": ["article_id"], "display": "texte",
                                  "labels": {"article_id": "Article", "auteur_id": "Auteur"}})
    return app

func compte_ctx(titre, bouton, form, nxt):
    return {"titre": titre, "bouton": bouton, "form": form, "next": nxt}

# L'article de l'URL, s'il existe (404) et si l'utilisateur peut le modifier (403).
async func article_modifiable(req):
    a := await ARTICLES.get(req.deps["db"], req.params["id"])
    if a == null:
        alweb.abort(404, "article introuvable")
    if not peut_modifier(req.deps["user"], a):
        alweb.abort(403, "cet article ne vous appartient pas")
    return a

func _fourni(f):
    return f != null and f.filename != null and f.filename != "" and f.size() > 0

# Photo (champ « photo ») et pièce jointe PDF (champ « piece ») du formulaire : [champ en erreur ou null, message,
# photo ou null, pièce ou null]. Types vérifiés sur le contenu ; en cas d'erreur, rien ne reste dans le stockage.
async func enregistrer_fichiers(req, st):
    form := alweb.form(req)
    photo := null
    piece := null
    f := form.file("photo")
    if _fourni(f):
        try:
            r := await images.store(st, f, {"prefix": "articles/", "sizes": TAILLES, "max_bytes": TAILLE_PHOTO, "keep_original": false})
            photo = {"vignette": r["variants"]["vignette"], "grande": r["variants"]["grande"], "largeur": r["width"], "hauteur": r["height"]}
        catch e:
            if e.type != "UploadError":
                raise(e)
            return ["photo", e.message, null, null]
    p := form.file("piece")
    if _fourni(p):
        try:
            cle := await storage.save_upload(st, p, {"prefix": "pieces/", "max_bytes": TAILLE_PIECE, "allowed": ["application/pdf"]})
            piece = {"cle": cle, "nom": p.safe_filename("document.pdf"), "taille": p.size()}
        catch e:
            await supprimer_fichiers(st, photo, null)
            if e.type != "UploadError":
                raise(e)
            return ["piece", e.message, null, null]
    return [null, null, photo, piece]

async func supprimer_fichiers(st, photo, piece):
    if photo != null:
        await st.delete(photo["vignette"])
        await st.delete(photo["grande"])
    if piece != null:
        await st.delete(piece["cle"])
