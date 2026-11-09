# Exemple alweb : messagerie temps réel (jalon Bêta de la phase 4). Lancement : examples/chat.al.
# Ce module ne fait que définir l'application (make_app(config)), pour que les tests puissent l'importer.
#
# Montre : salons WebSocket (diffusion, présence, indicateur « en train d'écrire »), flux SSE en lecture seule avec
# reprise par Last-Event-ID, API REST versionnée (/api/v1) décrite en OpenAPI 3.1 avec sa page /docs, pagination
# par curseur de l'historique, limitation de débit (globale, connexion, envoi), jetons JWT, ORM sur SQLite ou
# PostgreSQL. Avec temps_reel.partage (ou plusieurs processus), les événements et les limites passent par la base :
# deux clients servis par deux ouvriers différents se voient et sont limités ensemble.
#
#   curl -X POST localhost:8000/api/v1/comptes -H 'Content-Type: application/json' -d '{"pseudo": "ana", "mot_de_passe": "secret123"}'
#   curl -X POST localhost:8000/api/v1/jeton   -H 'Content-Type: application/json' -d '{"pseudo": "ana", "mot_de_passe": "secret123"}'
#   curl -X POST localhost:8000/api/v1/salons/general/messages -H 'Authorization: Bearer <jeton>' \
#        -H 'Content-Type: application/json' -d '{"texte": "Bonjour"}'
#   curl -N localhost:8000/salons/general/evenements                     # flux SSE
#   websocat 'ws://localhost:8000/ws/general?jeton=<jeton>'               # {"texte": "..."} ou {"type": "ecrit"}
from core use len, type, to_int
from collections use append
use os
use json
use string as _s
use serialization.schema as sch
use database.database as dbm
use alweb
use alweb.middleware as mw
use alweb.auth as auth
use alweb.orm as orm
use alweb.realtime as rt
use alweb.ratelimit as rl
use alweb.openapi as oa
use alweb.pagination as pg

# ---------------------------------------------------------------- modèle

COMPTES := orm.table("comptes", {"id": orm.pk(), "pseudo": orm.text(24, unique=true), "mdp": orm.text(), "cree_le": orm.timestamp(auto=true)})
SALONS := orm.table("salons", {"id": orm.pk(), "nom": orm.text(32, unique=true), "sujet": orm.text(200, null_ok=true), "cree_par": orm.ref("comptes", null_ok=true), "cree_le": orm.timestamp(auto=true)})
MESSAGES := orm.table("messages", {"id": orm.pk(), "salon_id": orm.ref("salons"), "auteur_id": orm.ref("comptes"), "texte": orm.text(2000), "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "tables", [COMPTES, SALONS, MESSAGES]),
    orm.migration(2, "index", [orm.index("messages_salon", "messages", ["salon_id", "id"])])
]

# ---------------------------------------------------------------- schémas (validation et documentation)

PSEUDO := sch.string(3, 24).pattern("^[a-z0-9_]+$").describe("lettres minuscules, chiffres et _")
NOM_SALON := sch.string(2, 32).pattern("^[a-z0-9-]+$")
COMPTE := oa.component("NouveauCompte", sch.object({"pseudo": PSEUDO, "mot_de_passe": sch.string(8, 200)}, ["pseudo", "mot_de_passe"], false))
JETON := oa.component("Jeton", sch.object({"jeton": sch.string(), "expire_dans": sch.integer()}, ["jeton", "expire_dans"]))
MEMBRE := oa.component("Membre", sch.object({"id": sch.string(), "pseudo": sch.string()}, ["id", "pseudo"]))
SALON := oa.component("Salon", sch.object({"nom": NOM_SALON, "sujet": sch.string().optional(), "presents": sch.integer(0)}, ["nom", "presents"]))
NOUVEAU_SALON := oa.component("NouveauSalon", sch.object({"nom": NOM_SALON, "sujet": sch.string(0, 200).optional()}, ["nom"], false))
MESSAGE := oa.component("Message", sch.object({"id": sch.integer(), "salon": sch.string(), "auteur": sch.string(), "texte": sch.string(), "cree_le": sch.number()}, ["id", "salon", "auteur", "texte", "cree_le"]))
NOUVEAU_MESSAGE := oa.component("NouveauMessage", sch.object({"texte": sch.string(1, 2000)}, ["texte"], false))
PAGE_MESSAGES := oa.component("PageMessages", sch.object({"items": sch.list_of(MESSAGE), "next": sch.string().optional().describe("curseur des messages plus anciens")}, ["items"]))

PAR_PAGE := 50

# ---------------------------------------------------------------- base

async func ouvrir_base(app):
    url := app.config.require("database.url")
    if url == "memory:" and "sqlite" in dbm.backends():
        url = "sqlite::memory:"
    db := alweb.database(url)
    await orm.migrate(db, MIGRATIONS)
    if await SALONS.where("nom", "general").count(db) == 0:
        await SALONS.insert(db, {"nom": "general", "sujet": "Pour commencer"})
    return db

async func fermer_base(db):
    await db.close()

func vue_message(m, salon, pseudo):
    return {"id": m["id"], "salon": salon, "auteur": pseudo, "texte": m["texte"], "cree_le": m["cree_le"]}

async func salon_ou_404(db, nom):
    s := await SALONS.where("nom", nom).first(db)
    if s == null:
        alweb.abort(404, "salon introuvable : " + nom)
    return s

# Enregistre le message et le diffuse aux clients du salon (WebSocket et SSE, tous processus).
async func publier(app, hub, db, salon, compte, texte):
    id := await MESSAGES.insert(db, {"salon_id": salon["id"], "auteur_id": compte["id"], "texte": texte})
    m := await MESSAGES.get(db, id)
    vue := vue_message(m, salon["nom"], compte["pseudo"])
    await hub.room(salon["nom"]).broadcast(vue, {"id": str(compte["id"]), "pseudo": compte["pseudo"]})
    return vue

# ---------------------------------------------------------------- application

# dossier : dossier de l'exemple (fichiers statiques dans static/).
func make_app(cfg, dossier="examples/chat"):
    app := alweb.App(cfg.get("nom", "messagerie"))
    app.configure(cfg)
    secret := cfg.require("secret_key")
    iterations := cfg.get("auth.iterations", 600000)
    partage := cfg.get("temps_reel.partage", false)
    limites := cfg.get("limites", {})
    lim := (k, d) => limites[k] if k in limites else d

    app.provide("db", ouvrir_base, "app", fermer_base)
    hub := rt.Hub(rt.DatabaseBroker(() => app.value("db")) if partage else null)
    hub.attach(app)
    app.state_hub = hub
    store := rl.DatabaseStore(() => app.value("db")) if partage else rl.MemoryStore()

    mws := [mw.request_id(), mw.security_headers()]
    if cfg.get("journal", false):
        mws = mws + [mw.logger()]
    app.middleware(mws + [rl.limit(lim("global", 600), 60, null, store, "global", true, (req) => _s.starts_with(req.path(), "/static/"))])
    app.static("/static", os.join(dossier, "static"))
    app.get("/", (req) => alweb.file(os.join(dossier, "static", "index.html"), "text/html; charset=utf-8"), {"hidden": true})
    app.get("/favicon.ico", (req) => alweb.no_content(), {"hidden": true})

    api := app.group("/api/v1", null, ["db"], {"tags": ["v1"]})
    jwt := [auth.bearer(secret)]

    async func compte_du_jeton(req):
        c := await COMPTES.get(req.deps["db"], to_int(req.state["jwt"]["sub"]))
        if c == null:
            alweb.abort(401, "compte supprimé")
        return c

    # ------------------------------------------------ comptes

    @api.post("/comptes", {"body": COMPTE, "summary": "Créer un compte", "tags": ["comptes"], "response": MEMBRE, "responses": {"409": "pseudo déjà pris"}, "middleware": [rl.limit(lim("inscription", 10), 3600, null, store, "inscription")]})
    async func inscription(req):
        d := alweb.data(req)
        db := req.deps["db"]
        if await COMPTES.where("pseudo", d["pseudo"]).exists(db):
            alweb.abort(409, "pseudo déjà pris")
        id := await COMPTES.insert(db, {"pseudo": d["pseudo"], "mdp": await auth.hash_password(d["mot_de_passe"], iterations)})
        return ({"id": str(id), "pseudo": d["pseudo"]}, 201)

    @api.post("/jeton", {"body": COMPTE, "summary": "Obtenir un jeton (1 h)", "tags": ["comptes"], "response": JETON, "status": 200, "responses": {"401": "identifiants refusés", "429": "trop d'essais"}, "middleware": [rl.limit(lim("connexion", 10), 60, null, store, "connexion")]})
    async func jeton(req):
        d := alweb.data(req)
        c := await COMPTES.where("pseudo", d["pseudo"]).first(req.deps["db"])
        if c == null or not await auth.verify_password(d["mot_de_passe"], c["mdp"]):
            alweb.abort(401, "identifiants refusés")
        return {"jeton": auth.jwt_encode({"sub": str(c["id"]), "pseudo": c["pseudo"]}, secret, 3600), "expire_dans": 3600}

    # ------------------------------------------------ salons

    @api.get("/salons", {"summary": "Salons et nombre de présents", "tags": ["salons"], "response": sch.list_of(SALON)})
    async func salons(req):
        out := []
        for s in await SALONS.order_by("nom").all(req.deps["db"]):
            append(out, {"nom": s["nom"], "sujet": s["sujet"], "presents": hub.room(s["nom"]).count()})
        return out

    @api.post("/salons", {"body": NOUVEAU_SALON, "summary": "Créer un salon", "tags": ["salons"], "response": SALON, "security": ["bearer"], "responses": {"409": "salon existant"}, "middleware": jwt})
    async func creer_salon(req):
        d := alweb.data(req)
        db := req.deps["db"]
        if await SALONS.where("nom", d["nom"]).exists(db):
            alweb.abort(409, "salon existant")
        await SALONS.insert(db, {"nom": d["nom"], "sujet": d["sujet"] if "sujet" in d else null, "cree_par": to_int(req.state["jwt"]["sub"])})
        await hub.publish("_salons", "salon", {"nom": d["nom"]})
        return ({"nom": d["nom"], "sujet": d["sujet"] if "sujet" in d else null, "presents": 0}, 201)

    @api.get("/salons/{nom}/presence", {"summary": "Membres connectés", "tags": ["salons"], "response": sch.list_of(MEMBRE)})
    async func presence(req):
        await salon_ou_404(req.deps["db"], req.params["nom"])
        return hub.room(req.params["nom"]).members()

    # ------------------------------------------------ messages

    @api.get("/salons/{nom}/messages", {"summary": "Historique, du plus récent au plus ancien", "description": "50 messages par page ; suivre next (ou l'en-tête Link) pour les plus anciens.", "tags": ["messages"], "response": PAGE_MESSAGES, "query": sch.object({"cursor": sch.string().optional()})})
    async func historique(req):
        db := req.deps["db"]
        s := await salon_ou_404(db, req.params["nom"])
        avant := pg.cursor(req)
        q := MESSAGES.where("salon_id", s["id"]).order_by("-id").limit(PAR_PAGE + 1).with_one(COMPTES, "auteur_id", "auteur")
        if avant != null:
            q = q.where("id", "<", to_int(avant))
        lignes := await q.all(db)
        items := []
        for m in lignes[0:PAR_PAGE]:
            append(items, vue_message(m, s["nom"], m["auteur"]["pseudo"] if m["auteur"] != null else "?"))
        return pg.cursor_page(req, items, items[len(items) - 1]["id"] if len(lignes) > PAR_PAGE else null)

    @api.post("/salons/{nom}/messages", {"body": NOUVEAU_MESSAGE, "summary": "Envoyer un message", "tags": ["messages"], "response": MESSAGE, "security": ["bearer"], "responses": {"429": "trop de messages"}, "middleware": jwt + [rl.limit(lim("envoi", 20), 10, rl.by_header("Authorization"), store, "envoi")]})
    async func envoyer(req):
        db := req.deps["db"]
        s := await salon_ou_404(db, req.params["nom"])
        c := await compte_du_jeton(req)
        return (await publier(app, hub, db, s, c, _s.trim(alweb.data(req)["texte"])), 201)

    # ------------------------------------------------ temps réel

    # WebSocket : ?jeton=<JWT> (les navigateurs ne peuvent pas poser d'en-tête Authorization). Reçoit
    # {"texte": "..."} (enregistré puis diffusé) ou {"type": "ecrit"} (diffusé seulement) ; envoie à la connexion
    # {"type": "bienvenue", "membres": [...], "pid": ...} puis les événements du salon.
    @app.websocket("/ws/{nom}")
    async func session(req, ws):
        nom := req.params["nom"]
        claims := null
        try:
            claims = auth.jwt_decode(req.query_param("jeton", ""), secret)
        catch e:
            await ws.close(4401, "jeton invalide")
            return
        db := app.value("db")
        s := await SALONS.where("nom", nom).first(db)
        if s == null:
            await ws.close(4404, "salon introuvable")
            return
        compte := await COMPTES.get(db, to_int(claims["sub"]))
        if compte == null:
            await ws.close(4401, "compte supprimé")
            return
        membre := {"id": str(compte["id"]), "pseudo": compte["pseudo"]}
        room := hub.room(nom)
        await room.join(ws, membre)
        await ws.send_text(json.stringify({"type": "bienvenue", "membres": room.members(), "pid": os.pid()}))
        try:
            while true:
                m := await ws.receive()
                if m == null:
                    break
                d := null
                try:
                    d = json.parse(m.text())
                catch e:
                    d = null
                if type(d) != "dict":
                    continue
                if "texte" in d and type(d["texte"]) == "str" and len(_s.trim(d["texte"])) > 0 and len(d["texte"]) <= 2000:
                    await publier(app, hub, db, s, compte, _s.trim(d["texte"]))
                elif "type" in d and d["type"] == "ecrit":
                    await room.broadcast(null, membre, "ecrit")
        finally:
            await room.leave(ws)

    # SSE, lecture seule (tableau d'affichage, robots) : reprise automatique par Last-Event-ID.
    app.get("/salons/{nom}/evenements", hub.sse((req) => req.params["nom"]), {"summary": "Événements du salon (Server-Sent Events)", "description": "text/event-stream ; un événement par message, arrivée (join), départ (leave) ou frappe (ecrit). Reprise : en-tête Last-Event-ID ou ?last_event_id=.", "tags": ["temps réel"]})
    app.get("/salons/evenements", hub.sse("_salons"), {"summary": "Création de salons (Server-Sent Events)", "tags": ["temps réel"]})

    oa.setup(app, "Messagerie alweb", "1.0.0", "API REST de la messagerie. Le temps réel passe par WebSocket (/ws/{nom}?jeton=...) et SSE.")
    return app
