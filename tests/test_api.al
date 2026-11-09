# Outils d'API : description OpenAPI 3.1, page de documentation, versionnage (Deprecation / Sunset), pagination
# par page et par curseur, CORS par route.
use json
use alweb
use alweb.openapi as oa
use alweb.pagination as pg
use alweb.testing as at
use serialization.schema as sch
use string as s
from core use len
from collections use keys, append
from testing use assert_eq, assert_true, assert_contains, assert_null

ARTICLE := oa.component("Article", sch.object({"titre": sch.string(1, 120).describe("titre affiché"), "tags": sch.list_of(sch.string(), null, 5).optional(), "etat": sch.enum_of(["brouillon", "publie"]).default("brouillon")}, ["titre"], false))
AUTEUR := oa.component("Auteur", sch.object({"nom": sch.string(), "articles": sch.list_of(ARTICLE)}, ["nom"]))
FILTRE := sch.object({"q": sch.string().optional(), "page": sch.integer(1).default(1)})

ITEMS := []

func make_app():
    app := alweb.App("journal")
    i := 1
    while i <= 45:
        append(ITEMS, {"id": i})
        i += 1
    v1 := app.group("/api/v1", null, null, {"tags": ["v1"], "deprecated": 1767225600, "sunset": 1782864000})
    v1.get("/articles", (req) => [], {"summary": "Anciens articles"})
    v2 := app.group("/api/v2", null, null, {"tags": ["v2"]})
    v2.get("/articles", liste, {"summary": "Articles paginés", "query": FILTRE, "name": "articles"})
    v2.post("/articles", (req) => (alweb.data(req), 201), {"body": ARTICLE, "response": ARTICLE, "security": ["bearer"], "responses": {"409": "titre déjà pris"}})
    v2.get("/articles/{id:int}", (req) => {"id": req.params["id"]}, {"response": ARTICLE, "tags": ["lecture"], "cors": ["https://lecteur.example"]})
    v2.get("/auteurs/{slug:slug}", (req) => {}, {"response": AUTEUR})
    v2.get("/flux", flux)
    app.get("/interne", (req) => "ok", {"hidden": true})
    oa.setup(app, "Journal", "2.1.0", "API du journal")
    oa.setup(app, "Journal v2", "2", null, "/api/v2", null, "/api/v2/openapi.json", false)
    return app

func liste(req):
    p := pg.params(req, 10, 20)
    return pg.page(req, ITEMS[p["offset"]:p["offset"] + p["per_page"]], len(ITEMS), p["page"], p["per_page"])

func flux(req):
    apres := pg.cursor(req)
    debut := apres if apres != null else 0
    lot := ITEMS[debut:debut + 20]
    return pg.cursor_page(req, lot, debut + 20 if debut + 20 < len(ITEMS) else null)

APP := make_app()

async func spec(path="/openapi.json"):
    r := await at.Client(APP).get(path)
    assert_eq(r.status, 200)
    return json.parse(r.body)

async func test_description_openapi():
    d := await spec()
    assert_eq(d["openapi"], "3.1.0")
    assert_eq(d["info"], {"title": "Journal", "version": "2.1.0", "description": "API du journal"})
    assert_eq(len(keys(d["paths"])), 5)                      # /interne, /openapi.json et /docs sont cachées
    assert_true(not ("/interne" in d["paths"]))
    lire := d["paths"]["/api/v2/articles/{id}"]["get"]
    assert_eq(lire["parameters"][0], {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}})
    assert_eq(lire["tags"], ["v2", "lecture"])
    assert_eq(lire["responses"]["200"]["content"]["application/json"]["schema"], {"$ref": "#/components/schemas/Article"})
    creer := d["paths"]["/api/v2/articles"]["post"]
    assert_eq(creer["requestBody"]["content"]["application/json"]["schema"]["$ref"], "#/components/schemas/Article")
    assert_eq(sorted(keys(creer["responses"])), ["201", "401", "409", "422"])
    assert_eq(creer["security"], [{"bearer": []}])
    assert_eq(d["components"]["securitySchemes"]["bearer"]["scheme"], "bearer")
    art := d["components"]["schemas"]["Article"]
    assert_eq(art["required"], ["titre"])
    assert_eq(art["additionalProperties"], false)
    assert_eq(art["properties"]["titre"], {"type": "string", "minLength": 1, "maxLength": 120, "description": "titre affiché"})
    assert_eq(art["properties"]["tags"], {"type": ["array", "null"], "items": {"type": "string"}, "maxItems": 5})
    assert_eq(art["properties"]["etat"], {"enum": ["brouillon", "publie"], "default": "brouillon"})
    assert_eq(d["components"]["schemas"]["Auteur"]["properties"]["articles"]["items"], {"$ref": "#/components/schemas/Article"})
    liste := d["paths"]["/api/v2/articles"]["get"]
    assert_eq(liste["operationId"], "articles")
    assert_eq(liste["parameters"][1]["schema"], {"type": "integer", "minimum": 1, "default": 1})
    assert_eq(d["paths"]["/api/v1/articles"]["get"]["deprecated"], true)
    assert_eq(d["paths"]["/api/v2/auteurs/{slug}"]["get"]["operationId"], "get_api_v2_auteurs_slug")

async func test_description_par_version():
    d := await spec("/api/v2/openapi.json")
    assert_eq(d["info"]["title"], "Journal v2")
    for p in keys(d["paths"]):
        assert_true(s.starts_with(p, "/api/v2/"), p)
    assert_eq((await at.Client(APP).get("/api/v2/docs")).status, 404)   # docs=false : pas de page

async func test_page_de_documentation():
    r := await at.Client(APP).get("/docs")
    assert_eq(r.status, 200)
    assert_contains(r.headers.get("Content-Type"), "text/html")
    assert_contains(r.body, "const SPEC=\"/openapi.json\";")
    assert_contains(r.body, "<title>Journal — API</title>")
    assert_true(not s.contains(r.body, "https://"), "la page ne charge aucune ressource externe")

async func test_versions_depreciees():
    c := at.Client(APP)
    r := await c.get("/api/v1/articles")
    assert_eq(r.headers.get("Deprecation"), "@1767225600")
    assert_eq(r.headers.get("Sunset"), "Wed, 01 Jul 2026 00:00:00 GMT")
    r = await c.get("/api/v2/articles")
    assert_null(r.headers.get("Deprecation"))

async func test_pagination_par_page():
    c := at.Client(APP)
    r := await c.get("/api/v2/articles?page=2&q=x")
    d := json.parse(r.body)
    assert_eq(d["page"], 2)
    assert_eq(d["pages"], 5)
    assert_eq(d["total"], 45)
    assert_eq(d["items"][0], {"id": 11})
    assert_eq(r.headers.get("X-Total-Count"), "45")
    link := r.headers.get("Link")
    assert_contains(link, "</api/v2/articles?")
    assert_contains(link, "page=3")
    assert_contains(link, "rel=\"next\"")
    assert_contains(link, "rel=\"prev\"")
    assert_contains(link, "q=x")
    r = await c.get("/api/v2/articles?per_page=500")
    assert_eq(json.parse(r.body)["per_page"], 20)            # borné
    assert_eq((await c.get("/api/v2/articles?page=0")).status, 422)
    assert_eq((await c.get("/api/v2/articles?page=deux")).status, 422)

async func test_pagination_par_curseur():
    c := at.Client(APP)
    vus := 0
    url := "/api/v2/flux"
    tours := 0
    while url != null and tours < 10:
        r := await c.get(url)
        d := json.parse(r.body)
        vus += len(d["items"])
        url = ("/api/v2/flux?cursor=" + d["next"]) if d["next"] != null else null
        if d["next"] != null:
            assert_contains(r.headers.get("Link"), "rel=\"next\"")
        tours += 1
    assert_eq(vus, 45)
    assert_eq(tours, 3)
    assert_eq((await c.get("/api/v2/flux?cursor=@@@")).status, 422)

async func test_cors_par_route():
    c := at.Client(APP)
    r := await c.request("OPTIONS", "/api/v2/articles/3", {"headers": {"Origin": "https://lecteur.example", "Access-Control-Request-Method": "GET"}})
    assert_eq(r.status, 204)
    assert_eq(r.headers.get("Access-Control-Allow-Origin"), "https://lecteur.example")
    r = await c.get("/api/v2/articles/3", {"headers": {"Origin": "https://lecteur.example"}})
    assert_eq(r.headers.get("Access-Control-Allow-Origin"), "https://lecteur.example")
    r = await c.get("/api/v2/articles/3", {"headers": {"Origin": "https://autre.example"}})
    assert_null(r.headers.get("Access-Control-Allow-Origin"))
    r = await c.get("/api/v2/articles", {"headers": {"Origin": "https://lecteur.example"}})
    assert_null(r.headers.get("Access-Control-Allow-Origin"))       # les autres routes ne sont pas ouvertes

func test_options_inconnues():
    app := alweb.App()
    try:
        app.get("/x", (req) => 1, {"summry": "faute"})
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "summary")
    try:
        app.group("/v", null, null, {"prefixe": 1})
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "tags")
