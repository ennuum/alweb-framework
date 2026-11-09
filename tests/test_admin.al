# Administration générée (alweb.admin) : accès (connexion, rôles, rôles par table), tableau de bord, liste
# (recherche, filtres, tri, pages, clés étrangères), création, modification, suppression, CSRF imposé par le groupe,
# erreurs par champ (validation, unicité), colonnes exclues et en lecture seule, export CSV, journal d'audit.
use os
use string as s
use alweb
use alweb.admin as adm
use alweb.i18n as i18n
use alweb.jobs as jobs
use alweb.auth as auth
use alweb.orm as orm
use alweb.sessions as sessions
use alweb.testing as at
use database.async_database as adb
use database.database as dbm
from core use len
from collections use append
from testing use assert_eq, assert_true, assert_false, assert_contains, assert_null

SECRET := "clé-de-test-suffisamment-longue-pour-admin"

AUTEURS := orm.table("auteurs", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(null_ok=true), "cree_le": orm.timestamp(auto=true)})
LIVRES := orm.table("livres", {"id": orm.pk(), "titre": orm.text(60), "resume": orm.text(null_ok=true), "pages": orm.integer(null_ok=true),
                               "prix": orm.real(null_ok=true), "dispo": orm.boolean(default=true), "auteur_id": orm.ref("auteurs"),
                               "etat": orm.text(10, default="neuf"), "meta": orm.json(), "paru_le": orm.timestamp(null_ok=true)})
SECRETS := orm.table("secrets", {"id": orm.pk(), "valeur": orm.text(40)})
MIGRATIONS := [orm.migration(1, "tables", [AUTEURS, LIVRES, SECRETS])]

func url_base():
    return "sqlite::memory:" if "sqlite" in dbm.backends() else "memory:"

func make_app(journal=null):
    app := alweb.App("admin-test")
    app.middleware(sessions.middleware(SECRET))           # pas de CSRF au niveau de l'application : l'admin l'impose
    db := adb.open(url_base())
    app.provide("db", (a) => db, "app")

    @app.on_startup
    async func demarrer():
        await orm.migrate(db, MIGRATIONS)
        for nom in ["Ada", "Bob", "Chloé"]:
            await AUTEURS.insert(db, {"nom": nom, "mdp": "secret-" + nom})
        i := 1
        while i <= 30:
            await LIVRES.insert(db, {"titre": "Livre " + str(i), "pages": i * 10, "dispo": i % 3 != 0, "auteur_id": 1 + i % 3,
                                     "resume": "Histoire de mer" if i == 7 else null})
            i += 1
        await SECRETS.insert(db, {"valeur": "x"})

    @app.post("/connexion-test")
    func connexion(req):
        d := req.json()
        auth.login(req, d["id"], d["roles"])
        return "ok"

    app.get("/connexion", (req) => "page de connexion")
    evenements := journal if journal != null else []
    admin := adm.Admin(app, {"title": "Gestion", "on_change": (req, ev) => append(evenements, ev)})
    admin.register(AUTEURS, {"exclude": ["mdp"], "display": "nom", "can_delete": false})
    admin.register(LIVRES, {"list": ["id", "titre", "pages", "dispo", "auteur_id"], "search": ["titre", "resume"], "filters": ["dispo", "auteur_id"],
                            "display": "titre", "per_page": 10, "choices": {"etat": [["neuf", "Neuf"], ["use", "Usé"]]},
                            "readonly": ["paru_le"], "labels": {"auteur_id": "Auteur"}, "help": {"pages": "nombre de pages"}})
    admin.register(SECRETS, {"roles": ["super"]})
    return [app, db, admin, evenements]

async func client(roles=null):
    r := make_app()
    c := at.Client(r[0])
    if roles != null:
        await c.post("/connexion-test", {"json": {"id": 1, "roles": roles}})
    return [c, r[1], r[3]]

func jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := 0
    while i < len(html) - len(marque):
        if html[i:i + len(marque)] == marque:
            j := i + len(marque)
            fin := j
            while html[fin:fin + 1] != "\"":
                fin += 1
            return html[j:fin]
        i += 1
    return null

func compte(texte, motif):
    n := 0
    i := 0
    while i <= len(texte) - len(motif):
        if texte[i:i + len(motif)] == motif:
            n += 1
            i += len(motif)
        else:
            i += 1
    return n

HTML := {"headers": {"Accept": "text/html"}}

async func test_acces():
    c := (await client())[0]
    r := await c.get("/admin", HTML)
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("Location"), "/connexion?next=/admin")
    assert_eq((await c.get("/admin/livres", {"headers": {"Accept": "application/json"}})).status, 401)
    c = (await client(["auteur"]))[0]
    assert_eq((await c.get("/admin", HTML)).status, 403)
    c = (await client(["admin"]))[0]
    r = await c.get("/admin", HTML)
    assert_eq(r.status, 200)
    assert_eq(r.headers.get("Cache-Control"), "no-store")
    assert_eq(r.headers.get("X-Frame-Options"), "DENY")
    assert_contains(r.text(), "<title>Gestion · Gestion</title>")
    assert_contains(r.text(), "<link rel=\"stylesheet\" href=\"/admin/_admin.css\">")
    assert_false("<style" in r.text() or "style=" in r.text())       # rien en ligne : compatible avec une CSP 'self'
    css := await c.get("/admin/_admin.css", HTML)
    assert_eq(css.status, 200)
    assert_eq(css.headers.get("Content-Type"), "text/css; charset=utf-8")
    assert_contains(css.text(), ".tableau{")
    assert_contains(r.text(), ">auteurs</a><div class=\"n\">3</div>")
    assert_contains(r.text(), ">livres</a><div class=\"n\">30</div>")
    assert_false("secrets" in r.text())                           # table réservée au rôle « super »
    assert_eq((await c.get("/admin/secrets", HTML)).status, 403)
    assert_eq((await c.get("/admin/inconnue", HTML)).status, 404)
    assert_eq((await c.get("/admin/livres/999", HTML)).status, 404)
    c = (await client(["admin", "super"]))[0]
    assert_eq((await c.get("/admin/secrets", HTML)).status, 200)

async func test_liste_recherche_filtres_tri_pages():
    c := (await client(["admin"]))[0]
    r := await c.get("/admin/livres", HTML)
    t := r.text()
    assert_eq(r.status, 200)
    assert_eq(compte(t, "<tr><td class=\"pk\">"), 10)              # 10 par page
    assert_contains(t, "<a href=\"/admin/livres/30\">30</a>")     # tri par défaut : -id
    assert_contains(t, "<a href=\"/admin/auteurs/1\">Ada</a>")    # clé étrangère : nom de l'auteur, lien
    assert_contains(t, "<td class=\"text\"><a href=\"/admin/livres/30\">Livre 30</a></td>")    # colonne display : lien
    assert_contains(t, "<nav><a href=\"/admin/auteurs\">auteurs</a><a href=\"/admin/livres\" class=\"actif\">livres</a></nav>")
    assert_contains(t, "<th class=\"\"><a href=\"/admin/livres?tri=auteur_id\">Auteur</a></th>")
    assert_contains(t, "page 1 sur 3")
    assert_contains(t, "href=\"/admin/livres?page=2\"")
    t = (await c.get("/admin/livres?q=LIVRE%202", HTML)).text()    # sans tenir compte de la casse : 2, 20..29
    assert_eq(compte(t, "<tr><td class=\"pk\">"), 10)
    assert_contains(t, "page 1 sur 2")
    assert_contains(t, "href=\"/admin/livres?q=LIVRE+2&amp;page=2\"")
    t = (await c.get("/admin/livres?q=mer", HTML)).text()         # recherche dans le résumé aussi (OU)
    assert_eq(compte(t, "<tr><td class=\"pk\">"), 1)
    assert_contains(t, ">Livre 7</a>")
    t = (await c.get("/admin/livres?f_dispo=0&tri=pages", HTML)).text()      # 3, 6, ..., 30 : 10 lignes
    assert_eq(compte(t, "<tr><td class=\"pk\">"), 10)
    assert_contains(t, "<th class=\"asc\"><a href=\"/admin/livres?f_dispo=0&amp;tri=-pages\">Pages</a></th>")
    assert_true(s.find(t, ">60</td>") > s.find(t, ">30</td>"))          # pages croissantes
    assert_contains(t, "<option value=\"0\" selected>non</option>")
    t = (await c.get("/admin/livres?f_auteur_id=1&f_dispo=1", HTML)).text()  # i % 3 == 0 exclus : auteur 1 n'a que des non dispo
    assert_contains(t, "Aucune ligne ne correspond.")
    t = (await c.get("/admin/livres?f_auteur_id=2&tri=nimporte", HTML)).text()  # tri inconnu ignoré
    assert_eq(compte(t, "<tr><td class=\"pk\">"), 10)
    assert_contains(t, "<option value=\"2\" selected>Bob</option>")
    t = (await c.get("/admin/livres?page=3", HTML)).text()
    assert_contains(t, "<a href=\"/admin/livres/1\">1</a>")
    assert_contains(t, "href=\"/admin/livres?page=2\"")

async func test_creation_csrf_et_erreurs():
    r := await client(["admin"])
    c := r[0]
    db := r[1]
    journal := r[2]
    page := await c.get("/admin/livres/nouveau", HTML)
    t := page.text()
    assert_eq(page.status, 200)
    assert_contains(t, "<option value=\"1\">Ada</option>")         # clé étrangère en liste déroulante
    assert_contains(t, "<option value=\"neuf\" selected>Neuf</option>")   # choices, valeur par défaut
    assert_contains(t, "<input type=\"checkbox\" name=\"dispo\" value=\"1\" checked>")
    assert_contains(t, "nombre de pages")
    assert_false("paru_le" in t)                                   # lecture seule : absent à la création
    k := jeton(t)
    assert_true(k != null)
    donnees := {"titre": "Neuf", "pages": "120", "prix": "12,5", "auteur_id": "2", "etat": "use", "meta": "{\"isbn\": \"978\"}", "dispo": "1"}
    assert_eq((await c.post("/admin/livres/nouveau", {"form": donnees})).status, 403)      # CSRF imposé par l'admin
    donnees["csrf_token"] = k
    r = await c.post("/admin/livres/nouveau", {"form": donnees})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("Location"), "/admin/livres/31")
    l := await LIVRES.get(db, 31)
    assert_eq([l["titre"], l["pages"], l["prix"], l["auteur_id"], l["etat"], l["meta"], l["dispo"]], ["Neuf", 120, 12.5, 2, "use", {"isbn": "978"}, true])
    assert_eq(journal[0]["action"], "create")
    assert_eq(journal[0]["id"], 31)
    assert_eq(journal[0]["user_id"], 1)
    t = (await c.get("/admin/livres/31", HTML)).text()
    assert_contains(t, "livres : « Neuf » créé.")                  # message flash après la redirection
    # erreurs : obligatoire, type, JSON, liste fermée, longueur (ORM) ; saisie réaffichée et échappée
    r = await c.post("/admin/livres/nouveau", {"form": {"csrf_token": k, "titre": "", "pages": "douze", "meta": "{faux", "etat": "volé", "auteur_id": "1"}})
    t = r.text()
    assert_eq(r.status, 422)
    assert_contains(t, "<div class=\"err\">valeur requise</div>")
    assert_contains(t, "<div class=\"err\">entier attendu</div>")
    assert_contains(t, "JSON invalide")
    assert_contains(t, "<div class=\"err\">valeur hors de la liste</div>")
    assert_contains(t, "value=\"douze\"")
    r = await c.post("/admin/livres/nouveau", {"form": {"csrf_token": k, "titre": "<b>" + s.repeat("x", 70), "auteur_id": "1"}})
    assert_eq(r.status, 422)
    assert_contains(r.text(), "Au plus 60 caractères.")                   # message de l'ORM rédigé pour la saisie
    assert_contains(r.text(), "&lt;b&gt;xxx")
    assert_eq(await LIVRES.query().count(db), 31)
    # unicité : erreur au champ
    r = await c.post("/admin/auteurs/nouveau", {"form": {"csrf_token": k, "nom": "Ada"}})
    assert_eq(r.status, 422)
    assert_contains(r.text(), "<div class=\"err\">valeur déjà utilisée</div>")
    r = await c.post("/admin/auteurs/nouveau", {"form": {"csrf_token": k, "nom": "Dan", "_encore": "1"}})
    assert_eq(r.headers.get("Location"), "/admin/auteurs/nouveau")

async func test_modification_lecture_seule_et_exclusions():
    r := await client(["admin"])
    c := r[0]
    db := r[1]
    t := (await c.get("/admin/auteurs/1", HTML)).text()
    assert_false("secret-Ada" in t)                                # colonne exclue jamais montrée
    assert_false("name=\"mdp\"" in t)
    assert_false("name=\"cree_le\"" in t)                          # horodatage automatique : lecture seule
    assert_contains(t, "<div class=\"lecture\" id=\"c_cree_le\">20")
    assert_false("/supprimer" in t)                                # can_delete faux
    k := jeton(t)
    avant := await AUTEURS.get(db, 1)
    r = await c.post("/admin/auteurs/1", {"form": {"csrf_token": k, "nom": "Ada L.", "mdp": "pirate", "cree_le": "2000-01-01T00:00", "id": "9"}})
    assert_eq(r.status, 303)
    apres := await AUTEURS.get(db, 1)
    assert_eq([apres["id"], apres["nom"], apres["mdp"], apres["cree_le"]], [1, "Ada L.", "secret-Ada", avant["cree_le"]])
    # case décochée -> faux ; champ vide facultatif -> null ; date lue
    await LIVRES.where("id", 5).update(db, {"paru_le": 1794084000.0})
    t = (await c.get("/admin/livres/5", HTML)).text()
    assert_contains(t, "<div class=\"lecture\" id=\"c_paru_le\">2026-11-07 ")
    assert_contains(t, "<option value=\"3\" selected>Chloé</option>")
    r = await c.post("/admin/livres/5", {"form": {"csrf_token": k, "titre": "Livre cinq", "pages": "", "auteur_id": "1", "etat": "neuf", "meta": "[1, 2]", "paru_le": "1999-01-01"}})
    assert_eq(r.status, 303)
    l := await LIVRES.get(db, 5)
    assert_eq([l["titre"], l["pages"], l["dispo"], l["auteur_id"], l["meta"], l["paru_le"]], ["Livre cinq", null, false, 1, [1, 2], 1794084000.0])
    assert_eq((await c.post("/admin/auteurs/1/supprimer", {"form": {"csrf_token": k}})).status, 403)
    assert_eq((await c.get("/admin/auteurs/1/supprimer", HTML)).status, 403)

async func test_suppression_et_journal():
    r := await client(["admin"])
    c := r[0]
    db := r[1]
    journal := r[2]
    t := (await c.get("/admin/livres/4/supprimer", HTML)).text()
    assert_contains(t, "Supprimer « Livre 4 » ?")
    k := jeton(t)
    assert_eq((await c.post("/admin/livres/4/supprimer", {"form": {}})).status, 403)
    assert_true((await LIVRES.get(db, 4)) != null)
    r = await c.post("/admin/livres/4/supprimer", {"form": {"csrf_token": k}})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("Location"), "/admin/livres")
    assert_null(await LIVRES.get(db, 4))
    assert_eq([journal[0]["action"], journal[0]["table"], journal[0]["id"], journal[0]["values"]["titre"]], ["delete", "livres", 4, "Livre 4"])
    assert_contains((await c.get("/admin/livres", HTML)).text(), "livres : « Livre 4 » supprimé.")

async func test_export_csv():
    r := await client(["admin"])
    c := r[0]
    db := r[1]
    await LIVRES.where("id", 2).update(db, {"titre": "=SOMME(A1)", "resume": "dit \"oui\", puis non"})
    r = await c.get("/admin/livres/export.csv?f_auteur_id=3&tri=id")
    assert_eq(r.status, 200)
    assert_eq(r.headers.get("Content-Type"), "text/csv; charset=utf-8")
    assert_contains(r.headers.get("Content-Disposition"), "livres.csv")
    lignes := s.split(r.text(), "\r\n")
    assert_eq(lignes[0], "Id,Titre,Resume,Pages,Prix,Dispo,Auteur,Etat,Meta,Paru le")
    assert_eq(lignes[1], "2,'=SOMME(A1),\"dit \"\"oui\"\", puis non\",20,,1,3,neuf,,")
    assert_eq(len(lignes), 12)                                    # en-tête, 10 lignes (2, 5, ..., 29), fin

async func test_declarations_refusees():
    app := alweb.App("x")
    admin := adm.Admin(app)
    for essai in [{"inconnue": 1}, {"list": ["absente"]}, {"exclude": ["id"]}, {"list": ["mdp"], "exclude": ["mdp"]}]:
        try:
            admin.register(AUTEURS, essai)
            assert_true(false, "erreur attendue : " + str(essai))
        catch e:
            assert_eq(e.type, "AlwebError")
    admin.register(AUTEURS)
    try:
        admin.register(AUTEURS)
        assert_true(false, "double enregistrement accepté")
    catch e:
        assert_contains(e.message, "déjà enregistrée")
    try:
        adm.Admin(app, {"prefixe": "/x"})
        assert_true(false, "option inconnue acceptée")
    catch e:
        assert_contains(e.message, "option inconnue")

async func test_recherche_orm():
    db := adb.open(url_base())
    await orm.migrate(db, MIGRATIONS)
    await AUTEURS.insert(db, {"nom": "Marie Curie"})
    await AUTEURS.insert(db, {"nom": "Pierre"})
    assert_eq([a["nom"] for a in await AUTEURS.search(["nom"], "CURIE").all(db)], ["Marie Curie"])
    assert_eq(await AUTEURS.search(["nom", "mdp"], "  ").count(db), 2)       # terme vide : sans effet
    assert_eq(await AUTEURS.search("nom", "r").where("id", ">", 1).count(db), 1)
    try:
        AUTEURS.search(["absente"], "x")
        assert_true(false, "colonne inconnue acceptée")
    catch e:
        assert_contains(e.message, "colonne inconnue")

# ---------------------------------------------------------------- tâches de fond (alweb.jobs)

async func client_taches(roles, jobs_opt=true):
    app := alweb.App("admin-taches")
    app.middleware(sessions.middleware(SECRET))
    app.provide("db", (a) => null, "app")
    @app.post("/connexion-test")
    func connexion(req):
        d := req.json()
        auth.login(req, d["id"], d["roles"])
        return "ok"
    q := jobs.Queue(app)
    q.quiet = true
    q.task("ok", (p, job) => p)
    @q.task("panne")
    func panne(p, job):
        raise("SmtpError", "smtp : 550 <" + str(p) + "> refusé")
    journal := []
    adm.Admin(app, {"jobs": jobs_opt, "on_change": (req, ev) => append(journal, ev)})
    c := at.Client(app)
    await c.post("/connexion-test", {"json": {"id": 1, "roles": roles}})
    return [c, q, journal]

async func test_page_des_taches():
    x := await client_taches(["admin"])
    c := x[0]
    q := x[1]
    await q.enqueue("panne", "bob@x.test", {"attempts": 1})
    await q.enqueue("ok", 1, {"delay": 3600, "key": "plus/tard é"})
    await q.run_pending()
    r := await c.get("/admin", HTML)
    assert_contains(r.text(), "<a href=\"/admin/_taches\">Tâches</a>")                  # dans la navigation
    assert_contains(r.text(), "<div class=\"note\">1 abandonnée</div>")
    r = await c.get("/admin/_taches", HTML)
    assert_eq(r.status, 200)
    t := r.text()
    assert_contains(t, "Abandonnées (1)")
    assert_contains(t, "En attente (1)")
    assert_contains(t, "SmtpError : smtp : 550 &lt;bob@x.test&gt; refusé")            # erreur échappée
    assert_contains(t, "href=\"/admin/_taches/k:plus%2Ftard%20%C3%A9\"")                # identifiant encodé dans le lien
    echouee := (await q.list("failed"))[0]["id"]
    r = await c.get("/admin/_taches/" + echouee, HTML)
    assert_contains(r.text(), "&quot;bob@x.test&quot;")                                # charge JSON
    assert_contains(r.text(), ">Réessayer</button>")
    k := jeton(r.text())
    assert_eq((await c.post("/admin/_taches/" + echouee + "/reessayer", {"form": {}})).status, 403)          # CSRF
    r = await c.post("/admin/_taches/" + echouee + "/reessayer", {"form": {"csrf_token": k}})
    assert_eq(r.status, 303)
    assert_eq((await q.get(echouee))["status"], "pending")
    assert_eq((await q.get(echouee))["attempts"], 0)
    r = await c.get("/admin/_taches/k:plus%2Ftard%20%C3%A9", HTML)
    assert_eq(r.status, 200)
    r = await c.post("/admin/_taches/k:plus%2Ftard%20%C3%A9/supprimer", {"form": {"csrf_token": jeton(r.text())}})
    assert_eq(r.status, 303)
    assert_null(await q.get("k:plus/tard é"))
    await q.run_pending()                                  # le nouvel essai échoue encore : de nouveau abandonnée
    r = await c.get("/admin/_taches", HTML)
    r = await c.post("/admin/_taches/reessayer", {"form": {"csrf_token": jeton(r.text())}})
    assert_eq((await q.stats())["failed"], 0)
    assert_eq([x[2][0]["action"], x[2][0]["table"], x[2][1]["action"], x[2][2]["id"]], ["job_retry", "jobs", "job_delete", null])
    assert_eq((await c.get("/admin/_taches/inconnue", HTML)).status, 404)

async func test_taches_droits():
    x := await client_taches(["admin"], ["exploitation"])
    assert_eq((await x[0].get("/admin/_taches", HTML)).status, 403)
    assert_false(s.contains((await x[0].get("/admin", HTML)).text(), "Tâches"))
    x = await client_taches(["admin", "exploitation"], ["exploitation"])
    assert_eq((await x[0].get("/admin/_taches", HTML)).status, 200)
    x = await client_taches(["admin"], false)
    assert_eq((await x[0].get("/admin/_taches", HTML)).status, 404)

# Administration en anglais : application avec alweb.i18n, navigateur en anglais (textes d'alweb.messages).
async func test_administration_en_anglais():
    r := make_app()
    app := r[0]
    i18n.I18n(app, null, {"default": "fr", "locales": ["fr", "en"]})
    c := at.Client(app, {"Accept-Language": "en", "Accept": "text/html"})
    await c.post("/connexion-test", {"json": {"id": 1, "roles": ["admin"]}})
    t := (await c.get("/admin")).text()
    assert_contains(t, "<html lang=\"en\" dir=\"ltr\">")
    assert_contains(t, "signed in: #1")
    assert_contains(t, ">Add</a>")
    t = (await c.get("/admin/livres?f_dispo=1")).text()
    assert_contains(t, ">Search</label>")
    assert_contains(t, "<option value=\"1\" selected>yes</option>")
    assert_contains(t, "page 1 of 2")
    p := (await c.get("/admin/livres/nouveau")).text()
    r2 := await c.post("/admin/livres/nouveau", {"form": {"csrf_token": jeton(p), "titre": s.repeat("x", 70), "pages": "douze", "auteur_id": "1"}})
    t = r2.text()
    assert_contains(t, "<div class=\"err\">whole number expected</div>")
    assert_contains(t, ">Save and add another</button>")
    r2 = await c.post("/admin/livres/nouveau", {"form": {"csrf_token": jeton(p), "titre": s.repeat("x", 70), "auteur_id": "1"}})
    assert_contains(r2.text(), "<div class=\"err\">At most 60 characters.</div>")
    r2 = await c.get("/admin/livres/999")
    assert_eq(r2.status, 404)
    assert_contains(r2.text(), "<h1>Page not found</h1>")
    assert_contains(r2.text(), "livres #999 not found")

# Extension (option « extensions ») : l'exemple de docs/ADMIN.md, avec menu, carte, page, envoi protégé par
# CSRF, message et journal on_change.
COMPTEUR := [0]

class Annonce:
    func init():
        self.admin = null

    func install(admin, g, h):
        self.admin = admin
        g.get("/_annonce", (req) => self.page(req), h)
        g.post("/_annonce", (req) => self.publier(req), h)
        admin.env.add("annonce.html", """{% extends "base.html" %}{% block contenu %}<h1>{{ page_title }}</h1>
<form class="fiche" method="post">{{ csrf_field() }}<input name="texte" value="{{ texte }}">
<div class="actions"><button class="principal">Publier</button></div></form>{% endblock %}""")

    func nav(admin, req):
        return [{"label": "Annonce", "href": admin.prefix + "/_annonce", "current": req.path() == admin.prefix + "/_annonce"}]

    func cards(admin, req):
        return [{"label": "Annonce", "href": admin.prefix + "/_annonce", "count": COMPTEUR[0], "note": "publications", "new": null}]

    func page(req):
        return self.admin.render(req, "annonce.html", {"page_title": "Annonce", "texte": ""})

    async func publier(req):
        COMPTEUR[0] = COMPTEUR[0] + 1
        await self.admin.notify(req, {"action": "annonce", "table": "annonces", "id": COMPTEUR[0], "values": null})
        self.admin.flash(req, "Annonce publiée.", "succes")
        return alweb.redirect(self.admin.prefix + "/_annonce", 303)

async func test_extension():
    journal := []
    app := alweb.App("extension")
    app.middleware(sessions.middleware(SECRET))
    app.provide("db", (a) => adb.open(url_base()), "app")

    @app.post("/connexion-test")
    func connexion(req):
        auth.login(req, 7, ["admin"])
        return "ok"

    app.get("/connexion", (req) => "connexion")
    adm.Admin(app, {"extensions": [Annonce()], "on_change": (req, ev) => append(journal, ev)})
    c := at.Client(app)
    assert_eq((await c.get("/admin/_annonce", HTML)).status, 303)                    # garde de l'administration
    await c.post("/connexion-test")
    h := (await c.get("/admin", HTML)).text()
    assert_contains(h, "<a href=\"/admin/_annonce\">Annonce</a>")
    assert_contains(h, "publications")
    r := await c.get("/admin/_annonce", HTML)
    assert_eq([r.status, r.headers.get("Cache-Control")], [200, "no-store"])
    assert_contains(r.text(), "<a href=\"/admin/_annonce\" class=\"actif\">Annonce</a>")
    assert_eq((await c.post("/admin/_annonce", {"form": {"texte": "x"}})).status, 403)  # CSRF imposé
    r = await c.post("/admin/_annonce", {"form": {"texte": "x", "csrf_token": jeton(r.text())}})
    assert_eq(r.headers.get("Location"), "/admin/_annonce")
    assert_contains((await c.get("/admin/_annonce", HTML)).text(), "Annonce publiée.")
    assert_eq([journal[0]["action"], journal[0]["table"], journal[0]["user_id"]], ["annonce", "annonces", 7])
