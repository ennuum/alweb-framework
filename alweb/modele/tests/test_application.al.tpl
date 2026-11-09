# Tests de {{Nom}} avec le client en mémoire (aucun port ouvert) : profil test, SQLite en mémoire.
#   alweb test     (ou  ALWEB_ENV=test alexc test tests)
use os
use string as s
use alweb
use alweb.testing as at
use application
from testing use assert_eq, assert_contains

# Racine du projet (le dossier parent de tests/) : les tests passent quel que soit le dossier courant.
RACINE := os.dirname(os.dirname(os.absolute(os.argv()[0])))

func client():
    return at.Client(application.creer(alweb.load_config(os.join(RACINE, "config"), "test"), RACINE))

func jeton_csrf(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

async func test_accueil():
    r := await client().get("/")
    assert_eq(r.status, 200)
    assert_contains(r.text(), "Aucun message")

async func test_publier_par_le_formulaire():
    c := client()
    page := await c.get("/")
    r := await c.post("/messages", {"form": {"auteur": "Alice", "texte": "Bonjour !", "csrf_token": jeton_csrf(page.text())}})
    assert_eq(r.status, 303)
    r = await c.get("/")
    assert_contains(r.text(), "Bonjour !")
    assert_contains(r.text(), "Message publié.")

async func test_formulaire_invalide_et_csrf():
    c := client()
    page := await c.get("/")
    r := await c.post("/messages", {"form": {"auteur": "", "texte": "x", "csrf_token": jeton_csrf(page.text())}})
    assert_eq(r.status, 422)
    r = await c.post("/messages", {"form": {"auteur": "Bob", "texte": "sans jeton"}})
    assert_eq(r.status, 403)

async func test_api():
    c := client()
    r := await c.post("/api/messages", {"json": {"auteur": "API", "texte": "depuis l'API"}})
    assert_eq(r.status, 201)
    r = await c.get("/api/messages")
    assert_eq(r.status, 200)
    assert_eq(r.json_value()["messages"][0]["texte"], "depuis l'API")
    r = await c.post("/api/messages", {"json": {"auteur": "API"}})
    assert_eq(r.status, 422)

async func test_sante():
    r := await client().get("/sante")
    assert_eq(r.json_value()["statut"], "ok")
