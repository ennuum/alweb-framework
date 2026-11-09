# Authentification : mots de passe (sans bloquer la boucle), connexion par session, gardes, rôles, utilisateur
# courant, redirection « next » sûre, JWT (signature, algorithme, expiration), intergiciel bearer.
use time
use asyncio as aio
use string as s
use alweb
use alweb.auth as auth
use alweb.sessions as sessions
use alweb.testing as at
from collections use append
from testing use assert_eq, assert_true, assert_null, assert_contains

SECRET := "clé-secrète-de-test-pour-l-auth-123"
COMPTES := {}

async func charger(req, id):
    await aio.sleep(0)
    return COMPTES[id] if id in COMPTES else null

func make_app():
    app := alweb.App("auth")
    app.middleware(sessions.middleware(SECRET))
    app.provide("user", auth.current_user(charger))

    @app.post("/inscription")
    async func inscription(req):
        f := alweb.form(req)
        id := len(COMPTES) + 1
        COMPTES[id] = {"id": id, "nom": f.get("nom"), "mdp": await auth.hash_password(f.get("mdp"), 2000), "roles": [f.get("role", "lecteur")]}
        return ({"id": id}, 201)

    @app.post("/connexion")
    async func connexion(req):
        f := alweb.form(req)
        for id in COMPTES:
            c := COMPTES[id]
            if c["nom"] == f.get("nom") and await auth.verify_password(f.get("mdp", ""), c["mdp"]):
                auth.login(req, id, c["roles"])
                return alweb.redirect(auth.next_url(req, "/"), 303)
        return ({"erreur": "identifiants invalides"}, 401)

    app.post("/deconnexion", (req) => auth.logout(req))

    @app.get("/moi", {"middleware": [auth.login_required()], "deps": ["user"]})
    func moi(req):
        return {"nom": req.deps["user"]["nom"], "roles": auth.roles(req)}

    app.get("/admin", (req) => "zone admin", {"middleware": [auth.roles_required(["admin"])]})
    app.get("/qui", (req) => {"user": req.deps["user"]["nom"] if req.deps["user"] != null else null}, {"deps": ["user"]})

    api := app.group("/api", [auth.bearer(SECRET)])
    api.get("/jeton", (req) => {"sub": auth.user_id(req), "roles": auth.roles(req)})
    api.get("/admin", (req) => "api admin", {"middleware": [auth.roles_required(["admin"])]})
    return app

async func test_mots_de_passe():
    e := await auth.hash_password("correct horse", 2000)
    assert_true(s.starts_with(e, "pbkdf2_sha256$2000$"))
    assert_true(await auth.verify_password("correct horse", e))
    assert_true(not await auth.verify_password("mauvais", e))
    assert_true(auth.needs_rehash(e))

async func tic(compteur, duree):
    t0 := time.monotonic()
    while time.monotonic() - t0 < duree:
        await aio.sleep(0.01)
        compteur[0] = compteur[0] + 1

async func test_hachage_ne_bloque_pas_la_boucle():
    compteur := [0]
    t := tic(compteur, 30.0)
    t0 := time.monotonic()
    e := await auth.hash_password("un mot de passe")          # 600 000 itérations
    dt := time.monotonic() - t0
    aio.cancel(t)
    assert_true(s.starts_with(e, "pbkdf2_sha256$600000$"))
    if dt > 0.1:
        assert_true(compteur[0] >= dt / 0.01 * 0.4, "boucle bloquée : " + str(compteur[0]) + " impulsions en " + str(dt) + " s")

async func test_parcours_de_connexion():
    c := at.Client(make_app())
    assert_eq((await c.post("/inscription", {"form": {"nom": "awa", "mdp": "s3cret!", "role": "auteur"}})).status, 201)
    r := await c.get("/moi", {"headers": {"Accept": "text/html"}})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("location"), "/connexion?next=/moi")
    assert_eq((await c.get("/moi", {"headers": {"Accept": "application/json"}})).status, 401)
    assert_eq((await c.post("/connexion", {"form": {"nom": "awa", "mdp": "faux"}})).status, 401)
    r = await c.post("/connexion?next=/moi", {"form": {"nom": "awa", "mdp": "s3cret!"}})
    assert_eq(r.status, 303)
    assert_eq(r.headers.get("location"), "/moi")
    assert_eq((await c.get("/moi")).json_value(), {"nom": "awa", "roles": ["auteur"]})
    assert_eq((await c.get("/admin")).status, 403)
    await c.post("/deconnexion")
    assert_eq((await c.get("/qui")).json_value(), {"user": null})

async func test_roles():
    c := at.Client(make_app())
    await c.post("/inscription", {"form": {"nom": "chef", "mdp": "pw", "role": "admin"}})
    await c.post("/connexion", {"form": {"nom": "chef", "mdp": "pw"}})
    assert_eq((await c.get("/admin")).text(), "zone admin")

async func test_redirection_next_sure():
    c := at.Client(make_app())
    await c.post("/inscription", {"form": {"nom": "zoe", "mdp": "pw"}})
    for mauvais in ["https://pirate.exemple/", "//pirate.exemple/x", "javascript:alert(1)"]:
        r := await c.post("/connexion?next=" + mauvais, {"form": {"nom": "zoe", "mdp": "pw"}})
        assert_eq(r.headers.get("location"), "/")

func test_jwt():
    j := auth.jwt_encode({"sub": "7", "roles": ["admin"]}, SECRET, 60)
    c := auth.jwt_decode(j, SECRET)
    assert_eq(c["sub"], "7")
    assert_eq(c["roles"], ["admin"])
    assert_true(c["exp"] - c["iat"] == 60)
    erreurs := []
    parts := s.split(j, ".")
    sans_algo := auth._b64("{\"alg\":\"none\",\"typ\":\"JWT\"}") + "." + parts[1] + "."
    falsifie := parts[0] + "." + auth._b64("{\"sub\":\"1\",\"roles\":[\"admin\"]}") + "." + parts[2]
    for cas in [[j, "autre-secret-tout-aussi-long-123"], [sans_algo, SECRET], [falsifie, SECRET], [auth.jwt_encode({"sub": "7"}, SECRET, -100), SECRET], ["pas.un.jeton", SECRET], ["abc", SECRET]]:
        try:
            auth.jwt_decode(cas[0], cas[1])
            append(erreurs, "accepté : " + cas[0])
        catch e:
            assert_eq(e.type, "JWTError")
    assert_eq(erreurs, [])

async func test_api_bearer():
    c := at.Client(make_app())
    assert_eq((await c.get("/api/jeton")).status, 401)
    assert_eq((await c.get("/api/jeton", {"headers": {"Authorization": "Bearer faux"}})).status, 401)
    lecteur := auth.jwt_encode({"sub": "3", "roles": ["lecteur"]}, SECRET, 60)
    r := await c.get("/api/jeton", {"headers": {"Authorization": "Bearer " + lecteur}})
    assert_eq(r.json_value(), {"sub": "3", "roles": ["lecteur"]})
    assert_eq((await c.get("/api/admin", {"headers": {"Authorization": "Bearer " + lecteur}})).status, 403)
    admin := auth.jwt_encode({"sub": "4", "roles": ["admin"]}, SECRET, 60)
    assert_eq((await c.get("/api/admin", {"headers": {"Authorization": "Bearer " + admin}})).text(), "api admin")
