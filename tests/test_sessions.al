# Sessions : cookie signé, stockages côté serveur (mémoire, base), rotation d'identifiant, déconnexion,
# messages flash, falsification refusée, pas de cookie inutile, expiration.
use time
use alweb
use alweb.sessions as sessions
use alweb.testing as at
use database.async_database as adb
from testing use assert_eq, assert_true, assert_null, assert_contains

SECRET := "une-clé-secrète-de-test-assez-longue"

func make_app(store=null, max_age=1209600):
    app := alweb.App("sessions")
    app.middleware(sessions.middleware(SECRET, store, "sid", max_age))

    @app.post("/connexion")
    func connexion(req):
        s := alweb.session(req)
        s.regenerate()
        s.set("user", req.query_param("nom"))
        s.flash("Bienvenue " + req.query_param("nom"), "succes")
        return {"id": s.id}

    @app.get("/moi")
    func moi(req):
        s := alweb.session(req)
        return {"user": s.get("user"), "id": s.id, "flashes": s.pop_flashes()}

    @app.post("/compteur")
    func compteur(req):
        s := alweb.session(req)
        s.set("n", s.get("n", 0) + 1)
        return {"n": s.get("n")}

    @app.post("/deconnexion")
    func deconnexion(req):
        alweb.session(req).invalidate()
        return null

    app.get("/rien", (req) => "rien")
    return app

func cookie_de(r):
    for line in r.headers.get_all("set-cookie"):
        return line
    return null

async func parcours(app):
    c := at.Client(app)
    r := await c.get("/rien")
    assert_null(cookie_de(r))                                  # pas de session, pas de cookie
    r = await c.post("/connexion?nom=Awa")
    id1 := r.json_value()["id"]
    assert_contains(cookie_de(r), "HttpOnly")
    assert_contains(cookie_de(r), "SameSite=Lax")
    m := (await c.get("/moi")).json_value()
    assert_eq(m["user"], "Awa")
    assert_eq(m["id"], id1)
    assert_eq(m["flashes"], [{"message": "Bienvenue Awa", "category": "succes"}])
    assert_eq((await c.get("/moi")).json_value()["flashes"], [])            # affiché une seule fois
    assert_eq((await c.post("/compteur")).json_value()["n"], 1)
    assert_eq((await c.post("/compteur")).json_value()["n"], 2)
    r = await c.post("/connexion?nom=Kofi")
    assert_true(r.json_value()["id"] != id1)                   # nouvel identifiant à la connexion
    await c.post("/deconnexion")
    assert_null((await c.get("/moi")).json_value()["user"])
    return c

async func test_cookie_signe():
    await parcours(make_app())

async func test_stockage_memoire():
    store := sessions.MemoryStore()
    await parcours(make_app(store))
    assert_eq(len(store.items), 0)                             # session supprimée à la déconnexion

async func test_stockage_base():
    db := adb.open("memory:")
    store := sessions.DatabaseStore(db)
    c := at.Client(make_app(store))
    await c.post("/connexion?nom=Zoé")
    assert_eq((await c.get("/moi")).json_value()["user"], "Zoé")
    assert_eq(await db.scalar("SELECT COUNT(*) FROM alweb_sessions"), 1)
    await c.post("/connexion?nom=Ali")                         # rotation : l'ancien identifiant disparaît
    assert_eq(await db.scalar("SELECT COUNT(*) FROM alweb_sessions"), 1)
    await db.close()

async func test_falsification_refusee():
    app := make_app()
    c := at.Client(app)
    await c.post("/connexion?nom=Awa")
    vrai := c.cookies["sid"]
    c.cookies["sid"] = vrai[0:len(vrai) - 3] + "abc"
    assert_null((await c.get("/moi")).json_value()["user"])
    autre := at.Client(app)
    autre.cookies["sid"] = "n'importe.quoi.ici"
    assert_null((await autre.get("/moi")).json_value()["user"])

async func test_expiration():
    c := at.Client(make_app(null, 1))
    await c.post("/connexion?nom=Awa")
    assert_eq((await c.get("/moi")).json_value()["user"], "Awa")
    time.sleep(2.1)
    assert_null((await c.get("/moi")).json_value()["user"])

func test_cle_trop_courte_refusee():
    try:
        sessions.middleware("court")
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "ConfigError")
