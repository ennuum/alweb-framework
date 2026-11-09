# Tests de {{Nom}} (boutique) avec le client en mémoire (aucun port ouvert) : profil test, SQLite en mémoire,
# produits d'exemple, thème du projet (themes/, alweb.lock).
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

func test_prix():
    assert_eq(application.prix_texte(1890), "18,90")
    assert_eq(application.prix_texte(1205), "12,05")
    assert_eq(application.prix_texte(0), "0,00")
    assert_eq(application.prix_texte(null), null)

async func test_catalogue():
    c := client()
    r := await c.get("/")
    assert_eq(r.status, 200)
    for attendu in ["Mug céramique", "/boutique/rayon/maison", "18,00 €"]:
        assert_contains(r.text(), attendu)
    r = await c.get("/boutique")
    assert_contains(r.text(), "Bougie parfumée")
    r = await c.get("/boutique/rayon/papeterie")
    assert_contains(r.text(), "Carnet ligné")
    assert_false(s.contains(r.text(), "Mug céramique"))
    assert_eq((await c.get("/boutique/rayon/inconnu")).status, 404)
    r = await c.get("/boutique/sac-en-toile")
    assert_contains(r.text(), "34,90 €")
    assert_contains(r.text(), "42,00 €")                                       # prix barré
    assert_contains(r.text(), "Ajouter au panier")
    assert_contains((await c.get("/boutique/casquette-brodee")).text(), "Épuisé")
    assert_eq((await c.get("/boutique/inconnu")).status, 404)

async func test_panier_et_commande():
    c := client()
    page := await c.get("/boutique/mug-ceramique")
    jeton := jeton_csrf(page.text())
    r := await c.post("/panier/ajouter", {"form": {"produit": "1", "quantite": "2", "csrf_token": jeton}})
    assert_eq([r.status, r.headers.get("Location")], [303, "/panier"])
    r = await c.get("/panier")
    assert_contains(r.text(), "Mug céramique")
    assert_contains(r.text(), "36,00 €")
    assert_contains(r.text(), "ajouté au panier")
    r = await c.post("/panier", {"form": {"q_1": "3", "csrf_token": jeton}})
    assert_eq(r.status, 303)
    assert_contains((await c.get("/panier")).text(), "54,00 €")
    r = await c.post("/commande", {"form": {"nom": "", "courriel": "a@b.fr", "adresse": "x", "csrf_token": jeton}})
    assert_eq(r.status, 422)
    r = await c.post("/commande", {"form": {"nom": "Alice Martin", "courriel": "alice@exemple.fr", "adresse": "12 rue des Lilas, Lyon", "csrf_token": jeton}})
    assert_eq([r.status, r.headers.get("Location")], [303, "/commande/confirmee"])
    r = await c.get("/commande/confirmee")
    assert_contains(r.text(), "Merci pour votre commande")
    assert_contains(r.text(), "n° 1")
    assert_contains((await c.get("/panier")).text(), "Votre panier est vide")
    assert_eq((await c.get("/commande")).status, 303)                          # panier vide : retour au panier

async func test_quantite_limitee_au_stock():
    c := client()
    jeton := jeton_csrf((await c.get("/boutique/sac-en-toile")).text())
    await c.post("/panier/ajouter", {"form": {"produit": "2", "quantite": "10", "csrf_token": jeton}})
    assert_contains((await c.get("/panier")).text(), "value=\"3\"")              # 3 en stock
    r = await c.post("/panier/ajouter", {"form": {"produit": "6", "quantite": "1", "csrf_token": jeton}})
    assert_eq(r.headers.get("Location"), "/boutique/casquette-brodee")          # épuisé
    assert_eq((await c.post("/panier/ajouter", {"form": {"produit": "1"}})).status, 403)   # sans jeton CSRF

async func test_pages_et_contact():
    c := client()
    assert_contains((await c.get("/about")).text(), "boutique indépendante")
    page := await c.get("/contact")
    assert_eq(page.status, 200)
    r := await c.post("/contact", {"form": {"nom": "Bob", "courriel": "bob@exemple.fr", "message": "Bonjour", "csrf_token": jeton_csrf(page.text())}})
    assert_contains(r.text(), "Merci, votre message a bien été envoyé.")

async func test_sante():
    r := await client().get("/sante")
    assert_eq(r.json_value()["statut"], "ok")
