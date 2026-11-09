# Exemple vitrine (examples/vitrine_app.al) : thème installé au premier lancement, pages du thème remplies,
# contact avec CSRF, connexion et page « Apparence » qui change le site.
use os
use json
use io
use string as s
use alweb.testing as at
use examples.vitrine_app as vitrine
from testing use assert_eq, assert_true, assert_contains, assert_false

const RACINE := "build/test_vitrine"
HTML := {"headers": {"Accept": "text/html"}}

func jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

func neuf():
    if os.exists(RACINE):
        os.rmdir(RACINE, true)
    return RACINE

async func test_vitrine():
    app := vitrine.make_app(neuf(), "alweb/modele-theme", "mot-de-passe-local", "s" * 40)
    assert_true(os.isfile(os.join(RACINE, "alweb.lock")))
    await app.start()
    c := at.Client(app)
    h := (await c.get("/", HTML)).text()
    assert_contains(h, "<title>Modern Business</title>")
    assert_contains(h, "/theme/css/theme.css?v=")
    for p in ["/services", "/about", "/blog", "/blog/1", "/contact"]:
        assert_eq([p, (await c.get(p, HTML)).status], [p, 200])
    assert_contains((await c.get("/blog", HTML)).text(), "href=\"/blog/1\"")
    assert_eq((await c.get("/blog/99", HTML)).status, 404)
    # contact
    page := (await c.get("/contact", HTML)).text()
    r := await c.post("/contact", {"form": {"csrf_token": jeton(page), "nom": "Awa", "courriel": "awa@exemple.org", "message": "Bonjour, un devis ?"}})
    assert_contains(r.text(), "Merci, votre message a bien été envoyé.")
    assert_eq((await c.post("/contact", {"form": {"csrf_token": jeton(page), "nom": "", "courriel": "x", "message": "a"}})).status, 422)
    assert_eq((await c.post("/contact", {"form": {"nom": "Awa", "courriel": "a@b.c", "message": "Bonjour"}})).status, 403)
    # administration
    assert_eq((await c.get("/admin/_apparence", HTML)).headers.get("Location"), "/connexion?next=/admin/_apparence")
    page = (await c.get("/connexion", HTML)).text()
    assert_eq((await c.post("/connexion", {"form": {"csrf_token": jeton(page), "mdp": "faux"}})).status, 401)
    r = await c.post("/connexion", {"form": {"csrf_token": jeton(page), "mdp": "mot-de-passe-local", "next": "/admin/_apparence"}})
    assert_eq(r.headers.get("Location"), "/admin/_apparence")
    a := (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(a, "Thème « Modern Business »")
    assert_contains(a, "type=\"file\" name=\"f.logo\"")                                   # stockage branché
    await c.post("/admin/_apparence", {"form": {"csrf_token": jeton(a), "v.site.nom": "Cabinet Koffi"}})
    assert_eq(json.parse(io.read_file(os.join(RACINE, "config", "theme.modern-business.json")))["site"]["nom"], "Cabinet Koffi")
    assert_contains((await at.Client(app).get("/", HTML)).text(), "<title>Cabinet Koffi</title>")
    await app.stop()
    # deuxième lancement : le thème déjà installé et les réglages sont gardés
    app2 := vitrine.make_app(RACINE, "alweb/modele-theme", "mot-de-passe-local", "s" * 40)
    assert_contains((await at.Client(app2).get("/", HTML)).text(), "<title>Cabinet Koffi</title>")
