# Dépendances déclarées : portées app et request, chaînage, cache par requête, refus par un fournisseur,
# groupes, validation avant résolution, teardown, substitution en test, cycles.
use alweb
use alweb.testing as at
use asyncio as aio
use serialization.schema as sch
from collections use append, clear
from testing use assert_eq, assert_true, assert_contains

EV := []
COMPTES := {"j1": {"nom": "Awa"}, "j2": {"nom": "Kofi"}}

class FausseBase:
    func init():
        self.ouverte = true

    async func compte(jeton):
        await aio.sleep(0)
        append(EV, "requête base")
        return COMPTES[jeton] if jeton in COMPTES else null

async func ouvrir_base(app):
    append(EV, "base ouverte")
    return FausseBase()

func fermer_base(db):
    db.ouverte = false
    append(EV, "base fermée")

async func utilisateur(req):
    db := await alweb.dep(req, "db")
    append(EV, "utilisateur")
    u := await db.compte(req.header("x-jeton", ""))
    if u == null:
        alweb.abort(401, "jeton invalide")
    return u

func horloge(req):
    append(EV, "horloge")
    return 1234

async func trace(req):
    append(EV, "trace ouverte")
    return {"id": 7}

func fin_trace(t):
    append(EV, "trace fermée")

func cycle_a(req):
    return alweb.dep(req, "cycle_b")

func cycle_b(req):
    return alweb.dep(req, "cycle_a")

NOTE := sch.object({"titre": sch.string(1, 50)}, ["titre"])

func make_app():
    app := alweb.App("deps")
    app.provide("db", ouvrir_base, "app", fermer_base)
    app.provide("user", utilisateur)
    app.provide("horloge", horloge)
    app.provide("trace", trace, "request", fin_trace)
    app.provide("cycle_a", cycle_a)
    app.provide("cycle_b", cycle_b)

    @app.get("/moi", {"deps": ["user", "horloge", "db"]})
    async func moi(req):
        u2 := await alweb.dep(req, "user")            # même valeur, pas de second calcul
        return {"nom": req.deps["user"]["nom"], "t": req.deps["horloge"], "meme": u2 == req.deps["user"], "db": req.deps["db"].ouverte}

    @app.post("/notes", {"body": NOTE, "deps": ["user"]})
    func creer(req):
        return ({"auteur": req.deps["user"]["nom"], "titre": alweb.data(req)["titre"]}, 201)

    @app.get("/panne", {"deps": ["trace"]})
    func panne(req):
        raise("ValueError", "panne")

    @app.get("/cycle", {"deps": ["cycle_a"]})
    func cyc(req):
        return "jamais"

    api := app.group("/api", null, ["user"])
    api.get("/profil", (req) => req.deps["user"])
    return app

APP := make_app()

async func test_portee_app_creee_une_fois_et_fermee():
    clear(EV)
    app := make_app()
    c := at.Client(app)
    await c.get("/moi", {"headers": {"X-Jeton": "j1"}})
    await c.get("/moi", {"headers": {"X-Jeton": "j2"}})
    assert_eq(len([e for e in EV if e == "base ouverte"]), 1)
    await c.stop()
    assert_eq(EV[len(EV) - 1], "base fermée")

async func test_resolution_chainage_et_cache():
    clear(EV)
    c := at.Client(APP)
    r := await c.get("/moi", {"headers": {"X-Jeton": "j1"}})
    assert_eq(r.status, 200)
    assert_eq(r.json_value(), {"nom": "Awa", "t": 1234, "meme": true, "db": true})     # portée app dans req.deps
    assert_eq(len([e for e in EV if e == "utilisateur"]), 1)
    assert_eq(len([e for e in EV if e == "requête base"]), 1)

async func test_refus_par_un_fournisseur():
    c := at.Client(APP)
    r := await c.get("/moi", {"headers": {"X-Jeton": "faux"}})
    assert_eq(r.status, 401)
    assert_contains(r.text(), "jeton invalide")

async func test_validation_avant_les_dependances():
    clear(EV)
    c := at.Client(APP)
    r := await c.post("/notes", {"json": {"titre": ""}, "headers": {"X-Jeton": "j1"}})
    assert_eq(r.status, 422)
    assert_eq(len([e for e in EV if e == "utilisateur"]), 0)
    r = await c.post("/notes", {"json": {"titre": "Été"}, "headers": {"X-Jeton": "j2"}})
    assert_eq(r.status, 201)
    assert_eq(r.json_value(), {"auteur": "Kofi", "titre": "Été"})

async func test_dependances_de_groupe():
    c := at.Client(APP)
    assert_eq((await c.get("/api/profil")).status, 401)
    assert_eq((await c.get("/api/profil", {"headers": {"X-Jeton": "j1"}})).json_value(), {"nom": "Awa"})

async func test_teardown_meme_si_le_gestionnaire_echoue():
    clear(EV)
    c := at.Client(APP)
    r := await c.get("/panne")
    assert_eq(r.status, 500)
    assert_eq(EV, ["trace ouverte", "trace fermée"])

async func test_substitution_en_test():
    app := make_app()
    app.override("user", (req) => {"nom": "Test"})
    c := at.Client(app)
    assert_eq((await c.get("/api/profil")).json_value(), {"nom": "Test"})
    app.clear_overrides()
    assert_eq((await c.get("/api/profil")).status, 401)

async func test_cycle_detecte():
    c := at.Client(APP)
    r := await c.get("/cycle")
    assert_eq(r.status, 500)

func test_dependance_inconnue_refusee_a_la_declaration():
    app := alweb.App()
    try:
        app.get("/x", (req) => "x", {"deps": ["absente"]})
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "AlwebError")
        assert_contains(e.message, "absente")
