# Tests de {{Nom}} (site vitrine) avec le client en mémoire (aucun port ouvert) : profil test, SQLite en mémoire,
# thème du projet (themes/, alweb.lock).
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

async func test_pages():
    c := client()
    for p in [["/", "Nos services"], ["/services", "Développement"], ["/about", "Chloé Martin"], ["/blog", "Nos nouveaux locaux"],
              ["/blog/pourquoi-un-theme", "sans toucher au code"], ["/contact", "name=\"courriel\""]]:
        r := await c.get(p[0])
        assert_eq(r.status, 200)
        assert_contains(r.text(), p[1])
    assert_eq((await c.get("/blog/inconnu")).status, 404)

async func test_contact():
    c := client()
    jeton := jeton_csrf((await c.get("/contact")).text())
    r := await c.post("/contact", {"form": {"nom": "", "courriel": "a@b.fr", "message": "x", "csrf_token": jeton}})
    assert_eq(r.status, 422)
    r = await c.post("/contact", {"form": {"nom": "Alice", "courriel": "alice@exemple.fr", "message": "Bonjour", "csrf_token": jeton}})
    assert_contains(r.text(), "Merci, votre message a bien été envoyé.")

async func test_sante():
    r := await client().get("/sante")
    assert_eq(r.json_value()["statut"], "ok")
