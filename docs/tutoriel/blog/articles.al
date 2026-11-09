# Articles et commentaires : lecture paginée, écriture réservée aux comptes, droits de modification (étapes 3, 5
# et 6 du tutoriel).
from core use to_int
use alweb
use alweb.auth as auth
use alweb.forms as forms
use modeles as m

func numero_de_page(req):
    try:
        return to_int(req.query_param("page", "1"))
    catch e:
        return 1

# L'article de l'URL, s'il existe (404) et si l'utilisateur peut le modifier (403).
async func article_modifiable(req):
    a := await m.ARTICLES.get(req.deps["db"], req.params["id"])
    if a == null:
        alweb.abort(404, "article introuvable")
    if not m.peut_modifier(req.deps["user"], a):
        alweb.abort(403, "cet article ne vous appartient pas")
    return a

func formulaire(values=null):
    return forms.FormResult(true, values if values != null else {}, null, {})

func installer(app, cfg):
    par_page := cfg.get("par_page", 5)
    site := app.group("", null, ["db", "user"])
    connecte := [auth.login_required("/connexion")]

    # ------------------------------------------------ lecture

    @site.get("/", {"name": "accueil"})
    async func accueil(req):
        p := await m.ARTICLES.order_by("-id").with_one(m.UTILISATEURS, "auteur_id", "auteur").paginate(req.deps["db"], numero_de_page(req), par_page)
        return alweb.render(req, "index.html", {"page": p})

    @site.get("/articles/{id:int}", {"name": "article"})
    async func voir(req):
        db := req.deps["db"]
        a := await m.ARTICLES.where("id", req.params["id"]).with_one(m.UTILISATEURS, "auteur_id", "auteur").first(db)
        if a == null:
            alweb.abort(404, "article introuvable")
        coms := await m.COMMENTAIRES.where("article_id", a["id"]).order_by("id").with_one(m.UTILISATEURS, "auteur_id", "auteur").all(db)
        return alweb.render(req, "article.html", {"article": a, "commentaires": coms, "peut_modifier": m.peut_modifier(req.deps["user"], a)})

    # ------------------------------------------------ écriture

    @site.get("/ecrire", {"name": "ecrire", "middleware": connecte})
    func ecrire_page(req):
        return alweb.render(req, "article_form.html", {"form": formulaire(), "article": null})

    @site.post("/ecrire", {"middleware": connecte})
    async func ecrire(req):
        f := alweb.validate_form(req, m.ARTICLE)
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": null}, 422)
        id := await m.ARTICLES.insert(req.deps["db"], {"titre": f.data["titre"], "texte": f.data["texte"], "auteur_id": req.deps["user"]["id"]})
        alweb.session(req).flash("Article publié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": id}), 303)

    @site.get("/articles/{id:int}/modifier", {"name": "modifier", "middleware": connecte})
    async func modifier_page(req):
        a := await article_modifiable(req)
        return alweb.render(req, "article_form.html", {"form": formulaire({"titre": a["titre"], "texte": a["texte"]}), "article": a})

    @site.post("/articles/{id:int}/modifier", {"middleware": connecte})
    async func modifier(req):
        a := await article_modifiable(req)
        f := alweb.validate_form(req, m.ARTICLE)
        if not f.valid:
            return alweb.render(req, "article_form.html", {"form": f, "article": a}, 422)
        await m.ARTICLES.where("id", a["id"]).update(req.deps["db"], {"titre": f.data["titre"], "texte": f.data["texte"]})
        alweb.session(req).flash("Article modifié.", "succes")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)

    @site.post("/articles/{id:int}/supprimer", {"name": "supprimer", "middleware": connecte})
    async func supprimer(req):
        db := req.deps["db"]
        a := await article_modifiable(req)
        await m.COMMENTAIRES.where("article_id", a["id"]).delete(db)
        await m.ARTICLES.where("id", a["id"]).delete(db)
        alweb.session(req).flash("Article supprimé.", "info")
        return alweb.redirect("/", 303)

    # ------------------------------------------------ commentaires

    @site.post("/articles/{id:int}/commentaires", {"name": "commenter", "middleware": connecte})
    async func commenter(req):
        db := req.deps["db"]
        a := await m.ARTICLES.get(db, req.params["id"])
        if a == null:
            alweb.abort(404, "article introuvable")
        f := alweb.validate_form(req, m.COMMENTAIRE)
        if f.valid:
            await m.COMMENTAIRES.insert(db, {"article_id": a["id"], "auteur_id": req.deps["user"]["id"], "texte": f.data["texte"]})
            alweb.session(req).flash("Commentaire publié.", "succes")
        else:
            alweb.session(req).flash("Commentaire vide ou trop long.", "erreur")
        return alweb.redirect(app.url_for("article", {"id": a["id"]}), 303)
