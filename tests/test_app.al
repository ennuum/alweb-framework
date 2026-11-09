# Tests d'alweb avec le client en mémoire : routes, décorateurs, async, groupes, intergiciels, validation,
# erreurs, cycle de vie, cookies.  alexc test tests/test_app.al
use alweb
use alweb.testing as at
use alweb.middleware as mw
use asyncio as aio
use serialization.schema as sch
from collections use append, clear
from testing use assert_eq, assert_true, assert_null, assert_contains

NOTES := {1: {"id": 1, "titre": "Première"}}
JOURNAL := []
EVENTS := []

NOTE := sch.object({"titre": sch.string(1, 80), "tags": sch.list_of(sch.string()).optional()}, ["titre"])
PAGE := sch.object({"page": sch.integer(1, 100).default(1), "taille": sch.integer(1, 50).default(10)})

func make_app():
    app := alweb.App("test")

    @app.get("/")
    func accueil(req):
        return "<h1>Accueil</h1>"

    @app.get("/notes/{id:int}", {"name": "note"})
    async func voir(req):
        await aio.sleep(0.01)
        n := NOTES[req.params["id"]] if req.params["id"] in NOTES else null
        if n == null:
            alweb.abort(404, "note introuvable")
        return n

    @app.post("/notes", {"body": NOTE})
    async func creer(req):
        d := alweb.data(req)
        return ({"titre": d["titre"], "tags": d["tags"] if "tags" in d else []}, 201)

    @app.get("/liste", {"query": PAGE})
    func liste(req):
        return alweb.data(req, "query")

    app.get("/texte", (req) => alweb.text("brut"))
    app.get("/boom", (req) => 1 / 0)

    @app.get("/session")
    func session(req):
        r := alweb.text("ok")
        r.set_cookie("sid", "abc", 3600)
        return r

    app.get("/qui", (req) => req.cookie("sid", "personne"))

    async func garde(req, suivant):
        if req.header("x-cle") != "secret":
            return alweb.json({"error": "interdit"}, 403)
        return await suivant(req)

    api := app.group("/api", [garde])

    @api.get("/etat")
    async func etat(req):
        await aio.sleep(0)
        return {"ok": true}

    admin := api.group("/admin")
    admin.get("/stats", (req) => {"notes": 1})

    async func trace(req, suivant):
        append(JOURNAL, "avant " + req.path())
        r := await suivant(req)
        append(JOURNAL, "après " + str(r.status))
        return r

    app.middleware([mw.request_id(), trace])

    @app.error_handler(404)
    func introuvable(req, status, message):
        return alweb.json({"perdu": req.path(), "message": message}, 404)

    @app.on_startup
    async func demarrer():
        await aio.sleep(0)
        append(EVENTS, "start")

    @app.on_shutdown
    func arreter():
        append(EVENTS, "stop")

    return app

APP := make_app()

async func test_routes_sync_et_async():
    c := at.Client(APP)
    r := await c.get("/")
    assert_eq(r.status, 200)
    assert_eq(r.text(), "<h1>Accueil</h1>")
    assert_contains(r.headers.get("content-type"), "text/html")
    r = await c.get("/notes/1")
    assert_eq(r.status, 200)
    assert_eq(r.json_value(), {"id": 1, "titre": "Première"})
    assert_eq((await c.get("/texte")).text(), "brut")
    assert_eq(APP.url_for("note", {"id": 7}), "/notes/7")

async func test_cycle_de_vie():
    c := at.Client(APP)
    await c.get("/")
    assert_eq(EVENTS[0], "start")
    await c.stop()
    assert_eq(EVENTS, ["start", "stop"])

async func test_erreurs():
    c := at.Client(APP)
    r := await c.get("/notes/99")
    assert_eq(r.status, 404)
    assert_eq(r.json_value(), {"perdu": "/notes/99", "message": "note introuvable"})
    r = await c.get("/absente")
    assert_eq(r.status, 404)
    assert_eq(r.json_value()["perdu"], "/absente")
    r = await c.get("/boom")
    assert_eq(r.status, 500)
    r = await c.request("DELETE", "/")
    assert_eq(r.status, 405)

async func test_validation_corps():
    c := at.Client(APP)
    r := await c.post("/notes", {"json": {"titre": "Été", "tags": ["a"]}})
    assert_eq(r.status, 201)
    assert_eq(r.json_value(), {"titre": "Été", "tags": ["a"]})
    r = await c.post("/notes", {"json": {"titre": ""}})
    assert_eq(r.status, 422)
    v := r.json_value()
    assert_eq(v["status"], 422)
    assert_eq(len(v["details"]), 1)
    assert_contains(v["details"][0], "titre")
    r = await c.post("/notes", {"body": "{pas du json", "headers": {"Content-Type": "application/json"}})
    assert_eq(r.status, 400)

async func test_validation_requete():
    c := at.Client(APP)
    assert_eq((await c.get("/liste")).json_value(), {"page": 1, "taille": 10})
    assert_eq((await c.get("/liste", {"params": {"page": "3"}})).json_value(), {"page": 3, "taille": 10})
    r := await c.get("/liste?page=0")
    assert_eq(r.status, 422)

async func test_groupes_et_intergiciels():
    c := at.Client(APP)
    assert_eq((await c.get("/api/etat")).status, 403)
    r := await c.get("/api/etat", {"headers": {"X-Cle": "secret"}})
    assert_eq(r.status, 200)
    assert_eq(r.json_value(), {"ok": true})
    r = await c.get("/api/admin/stats", {"headers": {"X-Cle": "secret"}})
    assert_eq(r.json_value(), {"notes": 1})
    assert_eq((await c.get("/api/admin/stats")).status, 403)
    assert_true(r.headers.get("x-request-id") != null)

async func test_ordre_des_intergiciels():
    clear(JOURNAL)
    c := at.Client(APP)
    await c.get("/notes/1")
    assert_eq(JOURNAL, ["avant /notes/1", "après 200"])

async func test_cookies_du_client():
    c := at.Client(APP)
    assert_eq((await c.get("/qui")).text(), "personne")
    await c.get("/session")
    assert_eq((await c.get("/qui")).text(), "abc")

func test_decorateur_rend_la_fonction():
    app := alweb.App()
    @app.get("/x")
    func x(req):
        return "x"
    assert_eq(x(null), "x")
    assert_eq(len(app.routes()), 1)

func test_options_inconnues_refusees():
    app := alweb.App()
    try:
        app.get("/x", (req) => "x", {"nom": "x"})
        assert_true(false, "une option inconnue doit être refusée")
    catch e:
        assert_eq(e.type, "AlwebError")
        assert_contains(e.message, "nom")
