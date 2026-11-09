# L'exemple « notes » fonctionne de bout en bout (client en mémoire), avec les deux stockages, et avec la
# configuration de test réelle (examples/config, profil test).
use alweb
use alweb.config as conf
use alweb.testing as at
use examples.notes_app as notes
from testing use assert_eq, assert_true, assert_contains

async func test_crud_notes_memoire():
    await crud(conf.from_dict({"stockage": "memoire", "journal": false}))

async func test_crud_notes_sql():
    await crud(conf.from_dict({"stockage": "sql", "database": {"url": "memory:"}, "journal": false}))

async func test_configuration_de_test_reelle():
    cfg := conf.load("examples/config", "test", "ALWEB", {})
    assert_eq(cfg.get("stockage"), "memoire")
    await crud(cfg)

async func crud(cfg):
    app := notes.make_app(cfg)
    c := at.Client(app)
    assert_eq((await c.get("/api/notes")).json_value(), {"page": 1, "total": 0, "notes": []})
    r := await c.post("/api/notes", {"json": {"titre": "Courses <pain>"}})
    assert_eq(r.status, 201)
    assert_eq(r.headers.get("location"), "/api/notes/1")
    assert_eq(r.json_value(), {"id": 1, "titre": "Courses <pain>", "texte": ""})
    await c.post("/api/notes", {"json": {"titre": "Deuxième", "texte": "x"}})
    assert_eq((await c.get("/api/notes", {"params": {"taille": "1", "page": "2"}})).json_value()["notes"], [{"id": 2, "titre": "Deuxième", "texte": "x"}])
    page := await c.get("/")
    assert_contains(page.text(), "<li>Courses &lt;pain&gt;</li>")
    assert_eq(page.headers.get("x-frame-options"), "DENY")
    assert_eq((await c.post("/api/notes", {"json": {"texte": "sans titre"}})).status, 422)
    assert_eq((await c.delete("/api/notes/1")).status, 204)
    assert_eq((await c.get("/api/notes/1")).status, 404)
    assert_eq((await c.delete("/api/notes/1")).status, 404)
    await c.stop()
