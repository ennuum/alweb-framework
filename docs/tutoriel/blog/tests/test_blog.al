# Tests du blog du tutoriel (étape 10) : le client en mémoire garde les cookies comme un navigateur ; chaque test
# part d'une base SQLite en mémoire neuve (profil test).
#   alweb test     (ou  ALWEB_ENV=test alexc test tests)
use os
use time
use string as s
use alweb
use alweb.testing as at
use application
from testing use assert_eq, assert_true, assert_contains
from core use len

# Racine du projet (le dossier parent de tests/) : les tests passent quel que soit le dossier courant.
RACINE := os.dirname(os.dirname(os.absolute(os.argv()[0])))

func nouvelle_app():
    return application.creer(alweb.load_config(os.join(RACINE, "config"), "test"), RACINE)

# Jeton CSRF du premier formulaire de la page.
func jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    reste := html[i + len(marque):len(html)]
    return reste[0:s.find(reste, "\"")]

async func envoyer(c, page, chemin, champs):
    p := await c.get(page)
    champs["csrf_token"] = jeton(p.text())
    return await c.post(chemin, {"form": champs})

async func inscrire(c, nom):
    return await envoyer(c, "/inscription", "/inscription", {"nom": nom, "courriel": nom + "@blog.test", "mdp": "motdepasse"})

async func test_accueil_vide():
    r := await at.Client(nouvelle_app()).get("/")
    assert_eq(r.status, 200)
    assert_contains(r.text(), "Aucun article pour l&#39;instant.")         # apostrophe échappée par _()
    assert_contains(r.text(), "href=\"/connexion\"")

async func test_inscription_et_connexion():
    c := at.Client(nouvelle_app())
    r := await inscrire(c, "alice")
    assert_eq(r.status, 303)
    r = await c.get("/")
    assert_contains(r.text(), "Bienvenue, alice !")
    assert_contains(r.text(), "Se déconnecter")
    r = await inscrire(at.Client(c.app), "alice")
    assert_eq(r.status, 422)
    assert_contains(r.text(), "ce nom est déjà pris")
    r = await envoyer(c, "/", "/deconnexion", {})
    assert_eq(r.status, 303)
    r = await envoyer(c, "/connexion", "/connexion", {"nom": "alice", "mdp": "mauvais"})
    assert_eq(r.status, 401)
    r = await envoyer(c, "/connexion", "/connexion", {"nom": "alice", "mdp": "motdepasse"})
    assert_eq(r.status, 303)

async func test_csrf_obligatoire():
    c := at.Client(nouvelle_app())
    r := await c.post("/inscription", {"form": {"nom": "alice", "mdp": "motdepasse"}})
    assert_eq(r.status, 403)

async func test_articles_droits_et_commentaires():
    app := nouvelle_app()
    alice := at.Client(app)
    bob := at.Client(app)
    visiteur := at.Client(app)
    await inscrire(alice, "alice")                        # premier compte : administrateur
    await inscrire(bob, "bob")

    # Un navigateur (Accept: text/html) est renvoyé vers la connexion ; un client d'API reçoit 401.
    r := await visiteur.get("/ecrire", {"headers": {"Accept": "text/html"}})
    assert_eq(r.status, 303)
    assert_eq(r.header("location"), "/connexion?next=/ecrire")
    r = await visiteur.get("/ecrire")
    assert_eq(r.status, 401)

    r = await envoyer(bob, "/ecrire", "/ecrire", {"titre": "", "texte": "x"})
    assert_eq(r.status, 422)
    r = await envoyer(bob, "/ecrire", "/ecrire", {"titre": "Premier billet", "texte": "Bonjour à tous"})
    assert_eq(r.status, 303)
    lien := r.header("location")
    assert_eq(lien, "/articles/1")
    r = await visiteur.get("/")
    assert_contains(r.text(), "Premier billet")
    assert_contains(r.text(), "par bob")

    # bob (auteur) et alice (admin) peuvent modifier ; un autre auteur non.
    await inscrire(at.Client(app), "carole")
    carole := at.Client(app)
    await envoyer(carole, "/connexion", "/connexion", {"nom": "carole", "mdp": "motdepasse"})
    r = await carole.get("/articles/1/modifier")
    assert_eq(r.status, 403)
    r = await envoyer(alice, "/articles/1/modifier", "/articles/1/modifier", {"titre": "Premier billet (revu)", "texte": "Bonjour"})
    assert_eq(r.status, 303)
    r = await visiteur.get(lien)
    assert_contains(r.text(), "Premier billet (revu)")

    r = await envoyer(carole, lien, "/articles/1/commentaires", {"texte": "Bravo !"})
    assert_eq(r.status, 303)
    r = await visiteur.get(lien)
    assert_contains(r.text(), "1 commentaire")
    assert_contains(r.text(), "<strong>carole</strong> : Bravo !")

    r = await envoyer(bob, lien, "/articles/1/supprimer", {})
    assert_eq(r.status, 303)
    r = await visiteur.get(lien)
    assert_eq(r.status, 404)

async func test_pagination():
    app := nouvelle_app()
    c := at.Client(app)
    await inscrire(c, "alice")
    i := 1
    while i <= 7:
        await envoyer(c, "/ecrire", "/ecrire", {"titre": "Billet " + str(i), "texte": "texte"})
        i += 1
    r := await c.get("/")
    assert_contains(r.text(), "Billet 7")
    assert_contains(r.text(), "plus anciens")
    assert_true(not s.contains(r.text(), "Billet 2<"))
    r = await c.get("/?page=2")
    assert_contains(r.text(), "Billet 2<")
    assert_contains(r.text(), "plus récents")

async func test_api_avec_jeton():
    app := nouvelle_app()
    c := at.Client(app)
    await inscrire(c, "alice")
    api := at.Client(app)
    r := await api.post("/api/jeton", {"json": {"nom": "alice", "mdp": "faux"}})
    assert_eq(r.status, 401)
    r = await api.post("/api/jeton", {"json": {"nom": "alice", "mdp": "motdepasse"}})
    assert_eq(r.status, 200)
    j := r.json_value()["jeton"]
    r = await api.post("/api/articles", {"json": {"titre": "Sans jeton", "texte": "x"}})
    assert_eq(r.status, 401)
    r = await api.post("/api/articles", {"json": {"titre": "Depuis l'API", "texte": "Bonjour"}, "headers": {"Authorization": "Bearer " + j}})
    assert_eq(r.status, 201)
    assert_eq(r.header("location"), "/articles/1")
    r = await api.get("/api/articles")
    d := r.json_value()
    assert_eq(d["total"], 1)
    assert_eq(d["articles"][0]["auteur"], "alice")

# Chemin d'un lien reçu par courriel (https://blog.test/... : site_url du profil test).
func chemin(lien):
    return s.replace(lien, "https://blog.test", "")

async func test_confirmation_par_courriel():
    c := at.Client(nouvelle_app())
    await inscrire(c, "alice")
    assert_eq(len(at.outbox(c.app)), 0)                   # en file (tâche « alweb.mail »)
    await at.run_jobs(c.app)
    boite := at.outbox(c.app)
    assert_eq(len(boite), 1)
    assert_eq(boite[0].to, ["alice@blog.test"])
    assert_eq(boite[0].subject, "Confirmez votre adresse")
    assert_contains(boite[0].html, "Confirmer mon adresse")
    lien := at.links(boite[0].text)[0]
    assert_true(s.starts_with(lien, "https://blog.test/confirmation/"))
    r := await c.get("/")
    assert_contains(r.text(), "Confirmez votre adresse (alice@blog.test)")
    # le lendemain, sans confirmation : rappel (tâche différée d'un jour)
    c.app.jobs.clock = () => time.time() + 86401
    await at.run_jobs(c.app)
    assert_eq(at.outbox(c.app)[1].subject, "Rappel : confirmez votre adresse")
    c.app.jobs.clock = time.time
    r = await c.get(chemin(lien))
    assert_eq(r.status, 303)
    r = await c.get("/")
    assert_contains(r.text(), "Adresse confirmée, merci !")
    assert_true(not s.contains(r.text(), "Renvoyer le lien"))
    r = await c.get("/confirmation/faux.jeton")
    r = await c.get("/")
    assert_contains(r.text(), "Ce lien de confirmation n")
    # adresse déjà prise, adresse invalide
    r = await envoyer(at.Client(c.app), "/inscription", "/inscription", {"nom": "alice2", "courriel": "ALICE@blog.test", "mdp": "motdepasse"})
    assert_eq(r.status, 422)
    assert_contains(r.text(), "un compte utilise déjà cette adresse")
    r = await envoyer(at.Client(c.app), "/inscription", "/inscription", {"nom": "bob", "courriel": "pas-une-adresse", "mdp": "motdepasse"})
    assert_contains(r.text(), "adresse de courriel invalide")

async func test_mot_de_passe_oublie():
    app := nouvelle_app()
    alice := at.Client(app)
    await inscrire(alice, "alice")
    await envoyer(alice, "/", "/deconnexion", {})
    await at.run_jobs(app)
    at.outbox(app, true)
    c := at.Client(app)
    # adresse inconnue : même réponse, aucun courriel (on ne révèle pas qui a un compte)
    r := await envoyer(c, "/mot-de-passe-oublie", "/mot-de-passe-oublie", {"courriel": "inconnu@blog.test"})
    assert_contains(r.text(), "Si un compte utilise cette adresse")
    await at.run_jobs(app)
    assert_eq(len(at.outbox(app)), 0)
    r = await envoyer(c, "/mot-de-passe-oublie", "/mot-de-passe-oublie", {"courriel": "Alice@Blog.test"})
    assert_contains(r.text(), "Si un compte utilise cette adresse")
    await at.run_jobs(app)
    m := at.outbox(app)[0]
    assert_eq([m.to, m.subject], [["alice@blog.test"], "Réinitialiser votre mot de passe"])
    p := chemin(at.links(m.text)[0])
    r = await envoyer(c, p, p, {"mdp": "court"})
    assert_eq(r.status, 422)
    r = await envoyer(c, p, p, {"mdp": "nouveau-secret"})
    assert_eq([r.status, r.header("location")], [303, "/connexion"])
    # le lien a servi : il ne vaut plus
    r = await c.get(p)
    assert_eq([r.status, r.header("location")], [303, "/mot-de-passe-oublie"])
    r = await envoyer(c, "/connexion", "/connexion", {"nom": "alice", "mdp": "motdepasse"})
    assert_eq(r.status, 401)
    r = await envoyer(c, "/connexion", "/connexion", {"nom": "alice", "mdp": "nouveau-secret"})
    assert_eq(r.status, 303)
    # 5 demandes par quart d'heure et par adresse IP
    for i in [1, 2, 3, 4]:
        r = await envoyer(c, "/mot-de-passe-oublie", "/mot-de-passe-oublie", {"courriel": "x@blog.test"})
    assert_eq(r.status, 429)

async func test_administration_et_taches():
    app := nouvelle_app()
    alice := at.Client(app)
    await inscrire(alice, "alice")                         # premier compte : administrateur
    bob := at.Client(app)
    await inscrire(bob, "bob")
    html := {"headers": {"Accept": "text/html"}}
    assert_eq((await bob.get("/admin", html)).status, 403)
    r := await alice.get("/admin", html)
    assert_eq(r.status, 200)
    assert_contains(r.text(), "Tâches")
    r = await alice.get("/admin/_taches?etat=pending", html)
    assert_contains(r.text(), "rappel_confirmation")         # rappels du lendemain, en attente
    assert_contains(r.text(), "alweb.mail")                  # courriels pas encore partis
    await at.run_jobs(app)
    r = await alice.get("/admin/_taches?etat=pending", html)
    assert_true(not s.contains(r.text(), "alweb.mail"))
    r = await alice.get("/admin/utilisateurs", html)
    assert_contains(r.text(), "bob@blog.test")
    assert_true(not s.contains(r.text(), "pbkdf2"))         # mots de passe jamais montrés

# Étape 11 (internationalisation) : anglais selon le navigateur ou choisi en pied de page, retenu par un cookie.
async func test_en_anglais():
    c := at.Client(nouvelle_app())
    await inscrire(c, "awa")
    await envoyer(c, "/ecrire", "/ecrire", {"titre": "Hello", "texte": "Premier article"})
    r := await c.get("/", {"headers": {"Accept-Language": "en-GB,en;q=0.8"}})
    h := r.text()
    assert_contains(h, "<html lang=\"en\" dir=\"ltr\">")
    assert_contains(h, ">Write</a>")
    assert_contains(h, "by awa, ")
    assert_contains(h, "<a href=\"/?lang=fr\" hreflang=\"fr\" lang=\"fr\">Français</a>")
    assert_eq(r.headers.get("Content-Language"), "en")
    h = (await c.get("/")).text()
    assert_contains(h, ">Écrire</a>")
    assert_contains(h, "par awa, le ")
    h = (await c.get("/?lang=en")).text()
    assert_contains(h, "Powered by alweb")
    assert_contains((await c.get("/")).text(), "Powered by alweb")      # retenu
