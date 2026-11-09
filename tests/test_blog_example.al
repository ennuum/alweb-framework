# Le blog d'exemple (jalon de la phase 3) de bout en bout avec le client en mémoire : inscription, connexion,
# CSRF, articles avec photo (vignette et grande image dans alweb.storage) et pièce jointe PDF réservée aux lecteurs
# connectés (lien signé), commentaires, droits (auteur, admin), pagination, API JSON avec jeton Bearer.
# Base : SQLite en mémoire ; ALWEB_TEST_POSTGRES=postgres://... : la même chose sur PostgreSQL (tables recréées) ;
# ALWEB_TEST_ALEXDB=alexdb://... : sur ALEX DB (base alweb_blog_test recréée).
use os
use time
use string as s
use alweb.config as conf
use alweb.testing as at
use database.async_database as adb
use io
use network.http_multipart as mp
use examples.blog_app as blog
from testing use assert_eq, assert_true, assert_contains

PHOTO := io.read_raw("tests/fixtures/photo.jpg")                 # 640 × 480
PDF := "%PDF-1.4\n% essai\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n"

async func configuration():
    env := {}
    ax := at.alexdb_database("alweb_blog_test")
    pg := os.getenv("ALWEB_TEST_POSTGRES") if ax == null else null
    if ax != null:
        env["ALWEB_DATABASE__URL"] = ax
    elif pg != null:
        # Base à part (alweb_blog_test, créée au besoin) : test_orm peut tourner en même temps sur la base donnée.
        db := adb.open(pg)
        if (await db.scalar("SELECT COUNT(*) FROM pg_database WHERE datname = 'alweb_blog_test'")) == 0:
            await db.script("CREATE DATABASE alweb_blog_test")
        await db.close()
        k := s.find(pg, "?")
        base := pg if k < 0 else pg[0:k]
        url := base[0:dernier_slash(base) + 1] + "alweb_blog_test" + ("" if k < 0 else pg[k:len(pg)])
        db = adb.open(url)
        await db.script("DROP TABLE IF EXISTS commentaires, articles, utilisateurs, alweb_migrations CASCADE")
        await db.close()
        env["ALWEB_DATABASE__URL"] = url
    return conf.load("examples/blog/config", "test", "ALWEB", env)

func dernier_slash(t):
    i := len(t) - 1
    while i >= 0 and t[i:i + 1] != "/":
        i -= 1
    return i

func jeton_de(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    if i < 0:
        return null
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

func multipart(champs, fichier_nom, fichier_data, piece=null):
    fichiers := {"photo": mp.File(fichier_nom, fichier_data, "image/jpeg")}
    if piece != null:
        fichiers["piece"] = mp.File(piece[0], piece[1], "application/pdf")
    corps := mp.encode(champs, fichiers)
    return {"body": corps[0], "headers": {"Content-Type": corps[1]}}

# Valeur de l'attribut src de la première image après la marque.
func src_apres(html, marque):
    i := s.find(html, marque)
    reste := html[i:len(html)]
    j := s.find(reste, "src=\"") + 5
    return s.replace(reste[j:j + s.find(reste[j:len(reste)], "\"")], "&amp;", "&")

async func inscrire(c, nom, mdp):
    page := await c.get("/inscription")
    r := await c.post("/inscription", {"form": {"nom": nom, "mdp": mdp, "csrf_token": jeton_de(page.text())}})
    return r

async func test_parcours_complet():
    cfg := await configuration()
    assert_eq(cfg.get("database.url") != null, true)
    app := blog.make_app(cfg)
    alice := at.Client(app)
    bob := at.Client(app)

    accueil := await alice.get("/")
    assert_eq(accueil.status, 200)
    assert_contains(accueil.text(), "Aucun article pour l'instant.")
    assert_contains(accueil.text(), "href=\"/connexion\"")

    # Inscription : validation par champ, nom unique, CSRF obligatoire, premier compte administrateur.
    page := await alice.get("/inscription")
    assert_eq((await alice.post("/inscription", {"form": {"nom": "alice", "mdp": "motdepasse1"}})).status, 403)
    r := await alice.post("/inscription", {"form": {"nom": "al", "mdp": "court", "csrf_token": jeton_de(page.text())}})
    assert_eq(r.status, 422)
    assert_contains(r.text(), "class=\"erreur\"")
    assert_contains(r.text(), "value=\"al\"")
    r = await inscrire(alice, "alice", "motdepasse1")
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("location"), "/")
    accueil = await alice.get("/")
    assert_contains(accueil.text(), "Bienvenue, alice !")
    assert_contains(accueil.text(), "alice · <a href=\"/ecrire\">")
    assert_true(not s.contains((await alice.get("/")).text(), "Bienvenue"))       # message flash lu une fois
    assert_eq((await inscrire(bob, "alice", "autremotdepasse")).status, 422)
    assert_eq((await inscrire(bob, "bob", "motdepasse2")).status, 303)

    # Écriture : connexion exigée, photo contrôlée par son contenu et réduite (vignette, grande image), pièce jointe
    # PDF réservée aux lecteurs connectés.
    visiteur := at.Client(app)
    r = await visiteur.get("/ecrire", {"headers": {"Accept": "text/html"}})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("location"), "/connexion?next=/ecrire")
    form := await alice.get("/ecrire")
    jeton := jeton_de(form.text())
    r = await alice.post("/ecrire", multipart({"titre": "Faux", "texte": "x", "csrf_token": jeton}, "x.jpg", "pas une image"))
    assert_eq(r.status, 422)
    assert_contains(r.text(), "type de fichier refusé")
    r = await alice.post("/ecrire", multipart({"titre": "Faux", "texte": "x", "csrf_token": jeton}, "x.jpg", PHOTO, ["note.pdf", "pas un pdf"]))
    assert_eq(r.status, 422)
    assert_contains(r.text(), "type de fichier refusé")
    st := app.storage
    assert_eq(len(await st.list()), 0)                                         # photo du refus retirée
    r = await alice.post("/ecrire", multipart({"titre": "Premier <billet>", "texte": "Ligne 1\nLigne 2", "csrf_token": jeton}, "photo.jpg", PHOTO, ["Programme 2026.pdf", PDF]))
    assert_eq(r.status, 303)
    url := r.headers.get("location")
    assert_eq(url, "/articles/1")
    a := (await alice.get(url)).text()
    assert_contains(a, "<h2>Premier &lt;billet&gt;</h2>")
    assert_contains(a, "Ligne 1<br>\nLigne 2")
    cles := [x["key"] for x in await st.list()]
    assert_eq(len(cles), 3)                                                    # vignette, grande, pièce
    grande := src_apres(a, "class=\"illustration\"")
    assert_true(s.starts_with(grande, "/_fichiers/articles/") and s.contains(grande, "-grande.jpg?e="), grande)
    img := await visiteur.get(grande)
    assert_eq([img.status, img.headers.get("Content-Type")], [200, "image/jpeg"])
    assert_eq(s.byte_slice(img.body, 0, 3), s.byte_pack([255, 216, 255]))
    accueil = await visiteur.get("/")
    vignette := src_apres(accueil.text(), "class=\"vignette\"")
    assert_contains(vignette, "-vignette.jpg?e=")
    assert_eq((await visiteur.get(vignette)).status, 200)
    assert_eq(src_apres((await visiteur.get("/")).text(), "class=\"vignette\""), vignette)    # lien stable : en cache
    assert_eq((await visiteur.get(s.replace(vignette, "-vignette.jpg", "-grande.jpg"))).status, 403)
    # pièce jointe : visiteur renvoyé vers la connexion ; lecteur connecté : lien signé de 5 min, nom d'origine
    assert_contains((await visiteur.get(url)).text(), "Programme 2026.pdf — <a href=\"/connexion?next=/articles/1\">connectez-vous</a>")
    r = await visiteur.get(url + "/piece", {"headers": {"Accept": "text/html"}})
    assert_eq(r.headers.get("location"), "/connexion?next=/articles/1/piece")
    r = await bob.get(url + "/piece")
    assert_eq(r.status, 303)
    lien := r.headers.get("location")
    assert_contains(lien, "/_fichiers/pieces/")
    p := await visiteur.get(lien)                                              # le lien suffit, sans session
    assert_eq([p.status, p.body], [200, PDF])
    assert_contains(p.headers.get("Content-Disposition"), "filename=\"Programme 2026.pdf\"")
    st.clock = () => time.time() + 600
    assert_eq((await visiteur.get(lien)).status, 403)                           # expiré après 5 min
    st.clock = () => time.time()
    api := (await visiteur.get("/api/articles")).json_value()["articles"][0]
    assert_true(s.contains(api["photo"]["vignette"], "-vignette.jpg?e=") and api["piece"])

    # Commentaires : connexion exigée, texte échappé, compteur.
    pb := await bob.get(url)
    assert_contains(pb.text(), "0 commentaire")
    assert_true(not s.contains(pb.text(), ">Modifier<"))                         # pas l'auteur
    r = await bob.post(url + "/commentaires", {"form": {"texte": "Bravo <b>!</b>", "csrf_token": jeton_de(pb.text())}})
    assert_eq(r.status, 303)
    pb = await bob.get(url)
    assert_contains(pb.text(), "1 commentaire")
    assert_contains(pb.text(), "<strong>bob</strong> : Bravo &lt;b&gt;!&lt;/b&gt;")
    assert_eq((await visiteur.post(url + "/commentaires", {"form": {"texte": "anonyme"}})).status, 403)

    # Droits : bob ne peut ni modifier ni supprimer l'article d'alice ; alice (admin) peut tout.
    jb := jeton_de(pb.text())
    assert_eq((await bob.get(url + "/modifier")).status, 403)
    assert_eq((await bob.post(url + "/supprimer", {"form": {"csrf_token": jb}})).status, 403)
    r = await bob.post("/ecrire", {"form": {"titre": "Chez bob", "texte": "contenu", "csrf_token": jb}})
    assert_eq(r.status, 303)
    url_bob := r.headers.get("location")
    pa := await alice.get(url_bob)
    assert_contains(pa.text(), ">Modifier<")                                       # admin
    r = await alice.post(url_bob + "/modifier", {"form": {"titre": "Chez bob (relu)", "texte": "contenu", "csrf_token": jeton_de(pa.text())}})
    assert_eq(r.status, 303)
    assert_contains((await bob.get(url_bob)).text(), "Chez bob (relu)")

    # Déconnexion, mauvaise connexion, connexion avec retour « next ».
    assert_eq((await bob.post("/deconnexion", {"form": {"csrf_token": jb}})).status, 303)
    assert_eq((await bob.get("/ecrire")).status, 401)                              # sans Accept HTML
    pc := await bob.get("/connexion?next=/articles/1")
    r = await bob.post("/connexion", {"form": {"nom": "bob", "mdp": "faux-mot", "next": "/articles/1", "csrf_token": jeton_de(pc.text())}})
    assert_eq(r.status, 401)
    assert_contains(r.text(), "nom ou mot de passe incorrect")
    r = await bob.post("/connexion", {"form": {"nom": "bob", "mdp": "motdepasse2", "next": "/articles/1", "csrf_token": jeton_de(pc.text())}})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("location"), "/articles/1")
    r = await bob.post("/connexion", {"form": {"nom": "bob", "mdp": "motdepasse2", "next": "https://ailleurs.example/", "csrf_token": jeton_de(pc.text())}})
    assert_eq(r.status, 403)                                                        # nouvelle session : ancien jeton refusé
    pc = await bob.get("/connexion")
    r = await bob.post("/connexion", {"form": {"nom": "bob", "mdp": "motdepasse2", "next": "https://ailleurs.example/", "csrf_token": jeton_de(pc.text())}})
    assert_eq(r.headers.get("location"), "/")                                       # redirection externe refusée

    # API : liste paginée sans mot de passe, publication par jeton Bearer (sans CSRF ni session).
    r = await visiteur.get("/api/articles")
    assert_eq(r.status, 200)
    liste := r.json_value()
    assert_eq(liste["total"], 2)
    assert_eq(liste["articles"][0]["titre"], "Chez bob (relu)")
    assert_eq(liste["articles"][0]["auteur"], {"id": 2, "nom": "bob"})
    assert_eq((await visiteur.post("/api/jeton", {"json": {"nom": "bob", "mdp": "non"}})).status, 401)
    t := (await visiteur.post("/api/jeton", {"json": {"nom": "bob", "mdp": "motdepasse2"}})).json_value()["jeton"]
    assert_eq((await visiteur.post("/api/articles", {"json": {"titre": "API", "texte": "x"}})).status, 401)
    r = await visiteur.post("/api/articles", {"json": {"titre": "Par l'API", "texte": "via jeton"}, "headers": {"Authorization": "Bearer " + t}})
    assert_eq(r.status, 201)
    assert_eq(r.headers.get("location"), "/articles/3")
    for i in [4, 5, 6]:
        await visiteur.post("/api/articles", {"json": {"titre": "Billet " + str(i), "texte": "x"}, "headers": {"Authorization": "Bearer " + t}})

    # Pagination (5 par page) ; suppression par l'auteur avec son image.
    p1 := (await visiteur.get("/")).text()
    assert_contains(p1, "plus anciens →")
    assert_true(not s.contains(p1, "Premier &lt;billet&gt;"))
    p2 := (await visiteur.get("/?page=2")).text()
    assert_contains(p2, "Premier &lt;billet&gt;")
    assert_contains(p2, "← plus récents")
    pa = await alice.get(url)
    assert_eq((await alice.post(url + "/supprimer", {"form": {"csrf_token": jeton_de(pa.text())}})).status, 303)
    assert_eq((await visiteur.get(url)).status, 404)
    assert_eq(len(await st.list()), 0)                                         # photo et pièce retirées
    assert_eq((await visiteur.get("/api/articles")).json_value()["total"], 5)
    await alice.stop()

# Administration du blog : réservée au rôle admin (premier compte), compatible avec la CSP du blog (feuille de
# style servie par l'admin, rien en ligne), empreintes de mot de passe jamais montrées.
async func test_administration():
    app := blog.make_app(await configuration())
    alice := at.Client(app)
    bob := at.Client(app)
    assert_eq((await inscrire(alice, "alice", "motdepasse1")).status, 303)
    assert_eq((await inscrire(bob, "bob", "motdepasse2")).status, 303)
    html := {"headers": {"Accept": "text/html"}}
    assert_eq((await bob.get("/admin", html)).status, 403)
    assert_eq((await at.Client(app).get("/admin", html)).headers.get("location"), "/connexion?next=/admin")
    r := await alice.get("/admin", html)
    assert_eq(r.status, 200)
    assert_contains(r.headers.get("Content-Security-Policy"), "default-src 'self'")
    assert_contains(r.text(), "href=\"/admin/_admin.css\"")
    assert_contains(r.text(), ">Comptes</a><div class=\"n\">2</div>")
    t := (await alice.get("/admin/utilisateurs/2", html)).text()
    assert_contains(t, "value=\"bob\"")
    assert_true(not s.contains(t, "pbkdf2") and not s.contains(t, "name=\"mdp\""))
    r = await alice.post("/admin/utilisateurs/2", {"form": {"nom": "bob", "roles": "[\"auteur\", \"admin\"]", "csrf_token": jeton_de(t)}})
    assert_eq(r.status, 303)
    r = await bob.post("/connexion", {"form": {"nom": "bob", "mdp": "motdepasse2", "csrf_token": jeton_de((await bob.get("/connexion")).text())}})
    assert_eq((await bob.get("/admin", html)).status, 200)        # rôles relus à la connexion
