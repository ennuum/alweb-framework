# Tests de {{Nom}} (blog) avec le client en mémoire (aucun port ouvert) : profil test, SQLite en mémoire,
# articles d'exemple, thème du projet (themes/, alweb.lock).
#   alweb test     (ou  ALWEB_ENV=test alexc test tests)
use os
use string as s
use alweb
use alweb.testing as at
use application
from testing use assert_eq, assert_true, assert_false, assert_contains

# Racine du projet (le dossier parent de tests/) : les tests passent quel que soit le dossier courant.
RACINE := os.dirname(os.dirname(os.absolute(os.argv()[0])))

func client():
    return at.Client(application.creer(alweb.load_config(os.join(RACINE, "config"), "test"), RACINE))

func jeton_csrf(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

func test_dates_et_lecture():
    assert_eq(application.date_texte("2026-11-08"), "8 novembre 2026")
    assert_eq(application.date_texte("2026-02-01"), "1 février 2026")
    assert_eq(application.date_texte("hier"), "hier")
    assert_eq(application.lecture("un deux trois"), 1)

async func test_accueil_et_liste():
    c := client()
    r := await c.get("/")
    assert_eq(r.status, 200)
    for attendu in ["Une semaine dans les Alpes", "/blog/une-semaine-dans-les-alpes", "/blog/categorie/cuisine", "8 novembre 2026"]:
        assert_contains(r.text(), attendu)
    r = await c.get("/blog")
    assert_contains(r.text(), "Un potager sur un balcon")
    assert_contains(r.text(), "Catégories")
    r = await c.get("/blog/categorie/cuisine")
    assert_contains(r.text(), "Le café filtre")
    assert_false(s.contains(r.text(), "Aller au travail à vélo"))
    assert_eq((await c.get("/blog/categorie/inconnue")).status, 404)
    assert_eq((await c.get("/blog?page=abc")).status, 200)

async func test_article():
    c := client()
    r := await c.get("/blog/le-cafe-filtre")
    assert_eq(r.status, 200)
    assert_contains(r.text(), "60 grammes")
    assert_contains(r.text(), "Par Awa Koné")
    assert_eq((await c.get("/blog/inconnu")).status, 404)

async func test_pages_et_contact():
    c := client()
    assert_contains((await c.get("/about")).text(), "plusieurs mains")
    page := await c.get("/contact")
    r := await c.post("/contact", {"form": {"nom": "Bob", "courriel": "bob@exemple.fr", "message": "Bonjour", "csrf_token": jeton_csrf(page.text())}})
    assert_contains(r.text(), "Merci, votre message a bien été envoyé.")

async func test_sante():
    r := await client().get("/sante")
    assert_eq(r.json_value()["statut"], "ok")
