# Application {{Nom}} (boutique en ligne). creer(cfg, dossier) construit l'App sans la lancer : main.al la lance,
# les tests l'importent et `alweb routes` l'inspecte. Les pages viennent du thème actif (themes/, alweb.lock) ;
# un gabarit du même nom dans templates/ le remplace.
#
#   /                         accueil : sélection (produits « vedette ») et rayons
#   /boutique                 tous les produits ; /boutique/rayon/<rayon> : un rayon
#   /boutique/<slug>          fiche produit
#   /panier                   panier (gardé dans la session) ; POST /panier/ajouter, POST /panier (quantités)
#   /commande                 coordonnées et validation ; la commande est enregistrée, le stock diminue
#   /about, /contact          pages du thème ; les demandes de contact sont enregistrées
from core use len, type, to_int
from collections use append, keys
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

PRESENTATION := "Une petite boutique indépendante qui sélectionne des objets utiles, beaux et durables."

# Base de données (portée app) : ouverte au démarrage de chaque processus, migrée, complétée par les produits
# d'exemple si elle est vide (réglage « exemples »), fermée à l'arrêt.
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

# ------------------------------------------------ prix, produits, panier

# 1890 -> « 18,90 » ; null -> null.
func prix_texte(centimes):
    if centimes == null:
        return null
    c := centimes % 100
    return str(centimes // 100) + "," + ("0" + str(c) if c < 10 else str(c))

func entier(v, defaut):
    try:
        return to_int(v)
    catch e:
        return defaut

# Produit pour une liste du thème : {id, nom, url, image, categorie, prix, prix_barre}.
func carte(p):
    return {"id": p["id"], "nom": p["nom"], "url": "/boutique/" + p["slug"], "image": p["image"], "categorie": p["categorie"],
            "prix": prix_texte(p["prix"]), "prix_barre": prix_texte(p["prix_barre"])}

func cartes(produits):
    return [carte(p) for p in produits]

# Rayons (un par valeur de « rayon »), dans l'ordre des noms affichés.
async func rayons(db, actif=null):
    vus := {}
    out := []
    tous := await modeles.PRODUITS.query().order_by("categorie").all(db)
    for p in tous:
        if not (p["rayon"] in vus):
            vus[p["rayon"]] = true
            append(out, {"nom": p["categorie"], "url": "/boutique/rayon/" + p["rayon"], "actif": p["rayon"] == actif})
    return out

# Panier de la session : {"<id du produit>": quantité}.
func panier(req):
    p := alweb.session(req).get("panier", null)
    return p if p != null and type(p) == "dict" else {}

func nombre_articles(req):
    n := 0
    try:
        p := panier(req)
        for k in keys(p):
            n += p[k]
    catch e:
        n = 0
    return n

# Lignes du panier d'après la base (prix et stock à jour) : [lignes, total en centimes].
async func contenu(db, p):
    lignes := []
    total := 0
    ids := [entier(k, 0) for k in keys(p)]
    if len(ids) == 0:
        return [lignes, total]
    produits := await modeles.PRODUITS.where("id", "in", ids).order_by("nom").all(db)
    for pr in produits:
        q := p[str(pr["id"])]
        if q > pr["stock"]:
            q = pr["stock"]
        if q <= 0:
            continue
        append(lignes, {"id": pr["id"], "nom": pr["nom"], "url": "/boutique/" + pr["slug"], "image": pr["image"],
                        "quantite": q, "prix": prix_texte(pr["prix"]), "total": prix_texte(pr["prix"] * q),
                        "prix_centimes": pr["prix"]})
        total += pr["prix"] * q
    return [lignes, total]

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
    app.context_processor((req) => {"panier_nombre": nombre_articles(req)})

    # ------------------------------------------------ catalogue

    @app.get("/", {"name": "accueil", "deps": ["db"]})
    async func accueil(req):
        db := req.deps["db"]
        vedettes := await modeles.PRODUITS.where("vedette", true).order_by("-id").limit(8).all(db)
        return alweb.render(req, "index.html", {"produits": cartes(vedettes), "categories": await rayons(db)})

    @app.get("/boutique", {"name": "boutique", "deps": ["db"]})
    async func boutique(req):
        db := req.deps["db"]
        tous := await modeles.PRODUITS.query().order_by("nom").all(db)
        return alweb.render(req, "boutique/index.html", {"produits": cartes(tous), "categories": await rayons(db), "categorie": null})

    @app.get("/boutique/rayon/{rayon:slug}", {"name": "rayon", "deps": ["db"]})
    async func rayon(req):
        db := req.deps["db"]
        liste := await modeles.PRODUITS.where("rayon", req.params["rayon"]).order_by("nom").all(db)
        if len(liste) == 0:
            alweb.abort(404, "rayon introuvable")
        return alweb.render(req, "boutique/index.html", {"produits": cartes(liste), "categories": await rayons(db, req.params["rayon"]),
                                                         "categorie": liste[0]["categorie"]})

    @app.get("/boutique/{slug:slug}", {"name": "produit", "deps": ["db"]})
    async func produit(req):
        db := req.deps["db"]
        p := await modeles.PRODUITS.where("slug", req.params["slug"]).first(db)
        if p == null:
            alweb.abort(404, "produit introuvable")
        proches := await modeles.PRODUITS.where("rayon", p["rayon"]).where("id", "!=", p["id"]).limit(3).all(db)
        fiche := carte(p)
        fiche["resume"] = p["resume"]
        fiche["description"] = p["description"]
        fiche["stock"] = p["stock"]
        return alweb.render(req, "boutique/produit.html", {"produit": fiche, "similaires": cartes(proches)})

    # ------------------------------------------------ panier

    @app.post("/panier/ajouter", {"name": "panier_ajouter", "deps": ["db"]})
    async func panier_ajouter(req):
        f := alweb.form(req)
        p := await modeles.PRODUITS.get(req.deps["db"], entier(f.get("produit", ""), 0))
        if p == null:
            alweb.abort(404, "produit introuvable")
        s := alweb.session(req)
        if p["stock"] <= 0:
            s.flash("« " + p["nom"] + " » est épuisé.", "erreur")
            return alweb.redirect("/boutique/" + p["slug"], 303)
        q := entier(f.get("quantite", "1"), 1)
        if q < 1:
            q = 1
        pan := panier(req)
        k := str(p["id"])
        total := (pan[k] if k in pan else 0) + q
        if total > p["stock"]:
            total = p["stock"]
        pan[k] = total
        s.set("panier", pan)
        s.flash("« " + p["nom"] + " » ajouté au panier.", "succes")
        return alweb.redirect("/panier", 303)

    @app.get("/panier", {"name": "panier", "deps": ["db"]})
    async func voir_panier(req):
        c := await contenu(req.deps["db"], panier(req))
        return alweb.render(req, "panier.html", {"lignes": c[0], "total": prix_texte(c[1])})

    @app.post("/panier", {"name": "panier_maj"})
    func panier_maj(req):
        f := alweb.form(req)
        pan := panier(req)
        neuf := {}
        for k in keys(pan):
            q := entier(f.get("q_" + k, str(pan[k])), pan[k])
            if q > 0:
                neuf[k] = q
        alweb.session(req).set("panier", neuf)
        return alweb.redirect("/panier", 303)

    # ------------------------------------------------ commande

    @app.get("/commande", {"name": "commande", "deps": ["db"]})
    async func commande(req):
        c := await contenu(req.deps["db"], panier(req))
        if len(c[0]) == 0:
            return alweb.redirect("/panier", 303)
        return alweb.render(req, "commande.html", {"lignes": c[0], "total": prix_texte(c[1]), "form": null})

    @app.post("/commande", {"name": "commander", "deps": ["db"]})
    async func commander(req):
        db := req.deps["db"]
        c := await contenu(db, panier(req))
        if len(c[0]) == 0:
            return alweb.redirect("/panier", 303)
        f := alweb.validate_form(req, modeles.COMMANDE)
        if not f.valid:
            return alweb.render(req, "commande.html", {"lignes": c[0], "total": prix_texte(c[1]), "form": f}, 422)
        d := f.data
        id := await modeles.COMMANDES.insert(db, {"nom": d["nom"], "courriel": d["courriel"], "adresse": d["adresse"], "total": c[1],
                                                  "telephone": d["telephone"] if "telephone" in d and d["telephone"] != null else ""})
        for l in c[0]:
            await modeles.LIGNES.insert(db, {"commande_id": id, "produit_id": l["id"], "nom": l["nom"], "prix": l["prix_centimes"], "quantite": l["quantite"]})
            p := await modeles.PRODUITS.get(db, l["id"])
            await modeles.PRODUITS.where("id", l["id"]).update(db, {"stock": p["stock"] - l["quantite"]})
        s := alweb.session(req)
        s.set("panier", {})
        s.set("derniere_commande", id)
        return alweb.redirect("/commande/confirmee", 303)

    @app.get("/commande/confirmee", {"name": "commande_confirmee"})
    func commande_confirmee(req):
        id := alweb.session(req).get("derniere_commande", null)
        if id == null:
            return alweb.redirect("/boutique", 303)
        return alweb.render(req, "commande.html", {"confirmee": true, "numero": id, "lignes": [], "total": null})

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
