# Intergiciels d'alweb : en-têtes de sécurité, CORS, journal, identifiant de requête, durée.
use json
use alweb
use asyncio as aio
use alweb.middleware as mw
use alweb.testing as at
use web.http.request as rq
from collections use append
from testing use assert_eq, assert_true, assert_null, assert_contains

func app_with(m):
    app := alweb.App()
    app.middleware(m)
    app.get("/", (req) => "ok")

    @app.get("/cadre")
    func cadre(req):
        r := alweb.text("ok")
        r.headers.set("X-Frame-Options", "SAMEORIGIN")
        return r

    return app

async func test_security_headers():
    app := app_with(mw.security_headers())
    c := at.Client(app)
    r := await c.get("/")
    assert_eq(r.headers.get("x-content-type-options"), "nosniff")
    assert_eq(r.headers.get("x-frame-options"), "DENY")
    assert_contains(r.headers.get("content-security-policy"), "default-src 'self'")
    assert_null(r.headers.get("strict-transport-security"))
    r = await c.get("/cadre")
    assert_eq(r.headers.get("x-frame-options"), "SAMEORIGIN")
    assert_eq(len(r.headers.get_all("x-frame-options")), 1)

async func test_hsts_en_https_seulement():
    app := app_with(mw.security_headers(false, 600))
    req := rq.Request("GET", "/", {"Host": "x"})
    req.state["scheme"] = "https"
    r := app.handle(req)                     # hooks seulement : réponse synchrone, aucune tâche
    assert_true(not aio.is_future(r))
    assert_eq(r.headers.get("strict-transport-security"), "max-age=600")
    assert_null(r.headers.get("content-security-policy"))

async func test_cors():
    app := app_with(mw.cors(["https://a.exemple"]))
    c := at.Client(app)
    r := await c.options("/", {"headers": {"Origin": "https://a.exemple", "Access-Control-Request-Method": "GET"}})
    assert_eq(r.status, 204)
    assert_eq(r.headers.get("access-control-allow-origin"), "https://a.exemple")
    r = await c.get("/", {"headers": {"Origin": "https://a.exemple"}})
    assert_eq(r.headers.get("access-control-allow-origin"), "https://a.exemple")
    r = await c.get("/", {"headers": {"Origin": "https://pirate.exemple"}})
    assert_null(r.headers.get("access-control-allow-origin"))
    r = await c.get("/")
    assert_null(r.headers.get("vary"))

async func test_request_id_et_timing():
    app := app_with([mw.request_id(), mw.timing()])
    c := at.Client(app)
    r := await c.get("/", {"headers": {"X-Request-Id": "abc-123"}})
    assert_eq(r.headers.get("x-request-id"), "abc-123")
    assert_contains(r.headers.get("server-timing"), "app;dur=")
    r = await c.get("/", {"headers": {"X-Request-Id": "pas valable"}})
    assert_true(r.headers.get("x-request-id") != "pas valable")

async func test_logger_json():
    lignes := []
    app := app_with([mw.request_id(), mw.logger("json", (l) => append(lignes, l))])
    c := at.Client(app)
    await c.get("/?x=1")
    assert_eq(len(lignes), 1)
    rec := json.parse(lignes[0])
    assert_eq(rec["method"], "GET")
    assert_eq(rec["path"], "/")
    assert_eq(rec["status"], 200)
    assert_true("request_id" in rec)

# Hooks (intergiciels synchrones) : court-circuit, ordre, mélange avec des intergiciels async et des routes async,
# exceptions transformées en page d'erreur.
async func test_hooks():
    trace := []
    app := alweb.App("h")
    app.middleware(alweb.hook((req) => trace_add(trace, "avant1"), (req, r) => marque(trace, r, "après1")))
    app.middleware(async_mw(trace))
    app.middleware(alweb.hook((req) => bloque(req), null))
    app.get("/", (req) => "ok")
    app.get("/lent", lent)
    app.get("/casse", (req) => "jamais", {"middleware": [alweb.hook(null, (req, r) => casse())]})
    c := at.Client(app)
    r := await c.get("/")
    assert_eq(r.body, "ok")
    assert_eq(r.headers.get("X-Marque"), "après1")
    assert_eq(trace, ["avant1", "async-avant", "async-après", "après1"])
    r = await c.get("/lent")
    assert_eq(r.body, "lent")
    assert_eq(r.headers.get("X-Marque"), "après1")
    r = await c.get("/?stop=1")
    assert_eq(r.status, 403)
    assert_eq(r.headers.get("X-Marque"), "après1")            # les hooks extérieurs voient la réponse courte
    r = await c.get("/casse")
    assert_eq(r.status, 500)

func trace_add(trace, x):
    append(trace, x)
    return null

func marque(trace, r, x):
    append(trace, x)
    r.headers.set("X-Marque", x)
    return r

func bloque(req):
    return alweb.text("interdit", 403) if req.query_param("stop") != null else null

func casse():
    raise("ValueError", "hook cassé")

func async_mw(trace):
    return (req, nxt) => _async_mw(req, nxt, trace)

async func _async_mw(req, nxt, trace):
    append(trace, "async-avant")
    r := await nxt(req)
    append(trace, "async-après")
    return r

async func lent(req):
    await aio.sleep(0.01)
    return "lent"
