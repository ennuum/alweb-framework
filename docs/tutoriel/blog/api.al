# API JSON du blog (étape 7 du tutoriel) : jeton JWT contre identifiants, lecture paginée, publication avec
# « Authorization: Bearer <jeton> ». Ni session ni CSRF sous /api/ (exempté dans application.al).
#   curl -X POST localhost:8000/api/jeton -H 'Content-Type: application/json' -d '{"nom": "alice", "mdp": "..."}'
#   curl -X POST localhost:8000/api/articles -H 'Authorization: Bearer <jeton>' -H 'Content-Type: application/json' \
#        -d '{"titre": "Depuis l API", "texte": "Bonjour"}'
from core use to_int
from collections use append
use alweb
use alweb.auth as auth
use alweb.ratelimit as rl
use modeles as m

func installer(app, cfg):
    secret := cfg.require("secret_key")
    par_page := cfg.get("par_page", 5)
    api := app.group("/api", [rl.limit(cfg.get("api.limite", 120), 60)], ["db"])

    @api.post("/jeton", {"body": m.IDENTIFIANTS})
    async func jeton(req):
        d := alweb.data(req)
        u := await m.UTILISATEURS.where("nom", d["nom"]).first(req.deps["db"])
        if u == null or not await auth.verify_password(d["mdp"], u["mdp"]):
            return ({"erreur": "identifiants invalides"}, 401)
        return {"jeton": auth.jwt_encode({"sub": u["id"], "roles": u["roles"]}, secret, 3600), "expire_dans": 3600}

    @api.get("/articles")
    async func liste(req):
        page := 1
        try:
            page = to_int(req.query_param("page", "1"))
        catch e:
            page = 1
        p := await m.ARTICLES.order_by("-id").with_one(m.UTILISATEURS, "auteur_id", "auteur").paginate(req.deps["db"], page, par_page)
        items := []
        for a in p["items"]:
            append(items, {"id": a["id"], "titre": a["titre"], "texte": a["texte"], "auteur": a["auteur"]["nom"], "cree_le": a["cree_le"]})
        return {"page": p["page"], "pages": p["pages"], "total": p["total"], "articles": items}

    @api.post("/articles", {"body": m.ARTICLE, "middleware": [auth.bearer(secret)]})
    async func publier(req):
        d := alweb.data(req)
        id := await m.ARTICLES.insert(req.deps["db"], {"titre": d["titre"], "texte": d["texte"], "auteur_id": auth.user_id(req)})
        r := alweb.json({"id": id}, 201)
        r.headers.set("Location", app.url_for("article", {"id": id}))
        return r
