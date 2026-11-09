# Limitation de débit : fenêtre glissante, en-têtes, 429, clés, exemptions, stockage partagé par la base.
use os
use json
use alweb
use alweb.ratelimit as rl
use alweb.testing as at
use database.async_database as adb
use database.database as dbm
from core use len
from testing use assert_eq, assert_true

HORLOGE := [1000.0]

func horloge():
    return HORLOGE[0]

func make_app(store=null):
    app := alweb.App("limite")
    app.middleware(rl.limit(3, 10, null, store, "global", true, (req) => req.path() == "/sante", horloge))
    app.get("/", (req) => {"ok": true})
    app.get("/sante", (req) => "ok")
    app.post("/connexion", (req) => {"ok": true}, {"middleware": rl.limit(1, 60, rl.by_header("X-Cle"), null, "connexion", true, null, horloge)})
    return app

async func test_fenetre_et_entetes():
    HORLOGE[0] = 1000.0
    c := at.Client(make_app())
    r := await c.get("/")
    assert_eq(r.status, 200)
    assert_eq(r.headers.get("RateLimit-Limit"), "3")
    assert_eq(r.headers.get("RateLimit-Remaining"), "2")
    assert_eq(r.headers.get("RateLimit-Policy"), "3;w=10")
    await c.get("/")
    await c.get("/")
    r = await c.get("/", {"headers": {"Accept": "application/json"}})
    assert_eq(r.status, 429)
    assert_eq(r.headers.get("Retry-After"), "10")
    assert_eq(r.headers.get("RateLimit-Remaining"), "0")
    assert_eq(json.parse(r.body)["status"], 429)
    assert_eq((await c.get("/sante")).status, 200)        # exemptée
    # fenêtre suivante, tout début : la précédente (4 requêtes) pèse encore presque entièrement
    HORLOGE[0] = 1010.5
    assert_eq((await c.get("/")).status, 429)
    # milieu de la fenêtre d'après : la précédente (1 requête) ne compte plus qu'à moitié
    HORLOGE[0] = 1025.0
    r = await c.get("/")
    assert_eq(r.status, 200)

async func test_limite_par_route_et_par_cle():
    HORLOGE[0] = 5000.0
    c := at.Client(make_app())
    assert_eq((await c.post("/connexion", {"headers": {"X-Cle": "a"}})).status, 200)
    assert_eq((await c.post("/connexion", {"headers": {"X-Cle": "a"}})).status, 429)
    assert_eq((await c.post("/connexion", {"headers": {"X-Cle": "b"}})).status, 200)
    # les requêtes refusées par la limite de route comptent quand même dans celle de l'application (3 / 10 s)
    assert_eq((await c.get("/")).status, 429)

async func test_partage_par_la_base():
    ax := at.alexdb_database("alweb_rate_t")
    pg := os.getenv("ALWEB_TEST_POSTGRES") if ax == null else null
    url := ax if ax != null else (pg if pg != null else "sqlite:/tmp/alweb-test-rate.db")
    if ax == null and pg == null and not ("sqlite" in dbm.backends()):
        # deux connexions doivent voir la même base : le moteur embarqué n'est pas partagé entre connexions
        raise("SkipTest", "SQLite indisponible (exécutable natif sans FFI, ou libsqlite3 absente)")
    if ax != null:
        pass
    elif pg == null:
        if os.exists("/tmp/alweb-test-rate.db"):
            os.remove("/tmp/alweb-test-rate.db")
    else:
        await adb.open(pg).execute("DROP TABLE IF EXISTS alweb_rate", [])
    HORLOGE[0] = 9000.0
    # deux applications, deux connexions : comme deux processus ouvriers
    c1 := at.Client(make_app(rl.DatabaseStore(adb.open(url))))
    c2 := at.Client(make_app(rl.DatabaseStore(adb.open(url))))
    assert_eq((await c1.get("/")).status, 200)
    assert_eq((await c2.get("/")).status, 200)
    assert_eq((await c1.get("/")).headers.get("RateLimit-Remaining"), "0")
    assert_eq((await c2.get("/")).status, 429)
    assert_eq((await c1.get("/")).status, 429)

async func test_base_indisponible():
    HORLOGE[0] = 100.0
    casse := rl.DatabaseStore(adb.open("postgres://x:y@127.0.0.1:1/rien"))
    ouvert := alweb.App("o")
    ouvert.middleware(rl.limit(1, 10, null, casse))
    ouvert.get("/", (req) => "ok")
    assert_eq((await at.Client(ouvert).get("/")).status, 200)
    ferme := alweb.App("f")
    ferme.middleware(rl.limit(1, 10, null, casse, null, false))
    ferme.get("/", (req) => "ok")
    assert_eq((await at.Client(ferme).get("/")).status, 503)
