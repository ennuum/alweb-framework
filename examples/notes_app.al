# Exemple alweb : API « notes » (CRUD) et une page HTML. Lancement : examples/notes.al.
# Ce module ne fait que définir l'application (make_app(config)), pour que les tests puissent l'importer.
#
# Montre : configuration par profils (examples/config), stockage fourni comme dépendance de portée « app »
# (créé au démarrage selon la configuration, fermé à l'arrêt), validation, groupes, intergiciels.
#   curl localhost:8000/api/notes
#   curl -X POST localhost:8000/api/notes -H 'Content-Type: application/json' -d '{"titre": "Courses", "texte": "pain"}'
from core use len
from collections use append, keys
use asyncio as aio
use web.html.html_escape as esc
use serialization.schema as sch
use alweb
use alweb.middleware as mw
use database.database as dbm
use string as _s

NOTE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(0, 10000).default("")}, ["titre"])
PAGE := sch.object({"page": sch.integer(1, 1000).default(1), "taille": sch.integer(1, 100).default(20)})

# Stockage en mémoire, avec des accès async pour imiter une vraie base de données.
class Store:
    func init():
        self.notes = {}
        self.next_id = 1

    async func all():
        await aio.sleep(0)
        out := []
        for k in keys(self.notes):
            append(out, self.notes[k])
        return out

    async func get(id):
        await aio.sleep(0)
        return self.notes[id] if id in self.notes else null

    async func create(data):
        await aio.sleep(0)
        n := {"id": self.next_id, "titre": data["titre"], "texte": data["texte"]}
        self.notes[self.next_id] = n
        self.next_id += 1
        return n

    async func delete(id):
        await aio.sleep(0)
        if not (id in self.notes):
            return false
        kept := {}
        for k in keys(self.notes):
            if k != id:
                kept[k] = self.notes[k]
        self.notes = kept
        return true

# Stockage SQL attendu avec await (alweb.database : la connexion vit dans un fil dédié). Même interface que Store.
class SqlStore:
    func init(url="memory:"):
        self.db = alweb.database(url)
        self.ready = false

    async func _init():
        if not self.ready:
            await self.db.script("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, titre TEXT, texte TEXT)")
            self.ready = true

    async func all():
        await self._init()
        return await self.db.query("SELECT id, titre, texte FROM notes ORDER BY id")

    async func get(id):
        await self._init()
        return await self.db.query_one("SELECT id, titre, texte FROM notes WHERE id = ?", [id])

    async func create(data):
        await self._init()
        id := await self.db.insert("notes", {"titre": data["titre"], "texte": data["texte"]})
        return {"id": id, "titre": data["titre"], "texte": data["texte"]}

    async func delete(id):
        await self._init()
        r := await self.db.execute("DELETE FROM notes WHERE id = ?", [id])
        return r["rowcount"] > 0

    async func close():
        await self.db.close()

# Fournisseur du stockage (portée app) : « memoire » ou « sql » (database.url ; SQLite si disponible).
async func ouvrir_stockage(app):
    cfg := app.config
    if cfg.get("stockage", "sql") == "memoire":
        return Store()
    url := cfg.require("database.url")
    if _s.starts_with(url, "sqlite:") and not ("sqlite" in dbm.backends()):
        url = "memory:"
    return SqlStore(url)

async func fermer_stockage(store):
    if isinstance(store, SqlStore):
        await store.close()

func make_app(cfg):
    app := alweb.App(cfg.get("nom", "notes"))
    app.configure(cfg)
    app.provide("store", ouvrir_stockage, "app", fermer_stockage)
    mws := [mw.request_id(), mw.timing(), mw.security_headers()]
    if cfg.get("journal", true):
        mws = mws + [mw.logger(cfg.get("journal_format", "text"))]
    app.middleware(mws)

    @app.get("/", {"deps": ["store"]})
    async func accueil(req):
        items := ""
        for n in await req.deps["store"].all():
            items = items + "<li>" + esc.escape_text(n["titre"]) + "</li>"
        return "<!DOCTYPE html><title>Notes</title><h1>Notes</h1><ul>" + items + "</ul>"

    api := app.group("/api", null, ["store"])

    @api.get("/notes", {"query": PAGE})
    async func lister(req):
        q := alweb.data(req, "query")
        notes := await req.deps["store"].all()
        debut := (q["page"] - 1) * q["taille"]
        fin := debut + q["taille"]
        if fin > len(notes):
            fin = len(notes)
        return {"page": q["page"], "total": len(notes), "notes": notes[debut:fin] if debut < len(notes) else []}

    @api.get("/notes/{id:int}", {"name": "note"})
    async func voir(req):
        n := await req.deps["store"].get(req.params["id"])
        if n == null:
            alweb.abort(404, "note introuvable")
        return n

    @api.post("/notes", {"body": NOTE})
    async func creer(req):
        n := await req.deps["store"].create(alweb.data(req))
        r := alweb.json(n, 201)
        r.headers.set("Location", app.url_for("note", {"id": n["id"]}))
        return r

    @api.delete("/notes/{id:int}")
    async func supprimer(req):
        if not await req.deps["store"].delete(req.params["id"]):
            alweb.abort(404, "note introuvable")
        return null                      # 204

    return app
