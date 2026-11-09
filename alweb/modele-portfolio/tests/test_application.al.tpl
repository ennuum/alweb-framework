# Tests de {{Nom}} (portfolio) avec le client en mémoire (aucun port ouvert) : profil test, SQLite en mémoire,
# projets d'exemple, thème du projet (themes/, alweb.lock).
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

async func test_accueil_et_projets():
    c := client()
    r := await c.get("/")
    assert_eq(r.status, 200)
    for attendu in ["Projets choisis", "Atelier Mira", "/projets/revue-terrain", "Ce que je fais"]:
        assert_contains(r.text(), attendu)
    assert_false(s.contains(r.text(), "Studio Rosa"))                            # pas en vedette
    r = await c.get("/projets")
    assert_contains(r.text(), "Studio Rosa")
    assert_contains(r.text(), "/projets/categorie/affiche")
    r = await c.get("/projets/categorie/affiche")
    assert_contains(r.text(), "Festival Lumen")
    assert_false(s.contains(r.text(), "Atelier Mira</strong>"))
    assert_eq((await c.get("/projets/categorie/inconnue")).status, 404)

async func test_fiche_projet():
    c := client()
    r := await c.get("/projets/atelier-mira")
    assert_eq(r.status, 200)
    for attendu in ["Atelier Mira, Lyon", "monogramme", "Autres projets", "/static/projets/edition.svg"]:
        assert_contains(r.text(), attendu)
    assert_contains((await c.get("/projets/studio-rosa")).text(), "https://exemple.fr")
    assert_eq((await c.get("/projets/inconnu")).status, 404)

async func test_pages_et_contact():
    c := client()
    assert_contains((await c.get("/about")).text(), "dix ans")
    page := await c.get("/contact")
    r := await c.post("/contact", {"form": {"nom": "Bob", "courriel": "bob@exemple.fr", "message": "Bonjour", "csrf_token": jeton_csrf(page.text())}})
    assert_contains(r.text(), "Merci, votre message a bien été envoyé.")

async func test_sante():
    r := await client().get("/sante")
    assert_eq(r.json_value()["statut"], "ok")
