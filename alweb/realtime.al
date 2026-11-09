# alweb.realtime — salons temps réel : diffusion WebSocket, présence, historique et flux SSE avec reprise.
#
#   use alweb.realtime as rt
#   hub := rt.Hub()                                   # un seul processus (historique en mémoire)
#   hub := rt.Hub(rt.DatabaseBroker(db))              # plusieurs processus : événements partagés par la base
#   hub.attach(app)                                   # démarrage / arrêt avec l'application
#
#   @app.websocket("/ws/{salon}")
#   async func salon(req, ws):
#       room := hub.room(req.params["salon"])
#       await room.serve(ws, {"id": pseudo, "nom": pseudo})   # rejoint, diffuse chaque message reçu, quitte
#
#   app.get("/salons/{salon}/evenements", hub.sse((req) => req.params["salon"]))
#
# Chaque événement porte un identifiant croissant ; un client SSE qui se reconnecte avec Last-Event-ID reçoit ce
# qu'il a manqué (dans la limite de l'historique). Message envoyé aux clients WebSocket et SSE (JSON) :
#   {"id": 42, "room": "general", "type": "message" | "join" | "leave" | <type libre>, "data": ..., "member": {...}}
#
# Présence : room.members() liste les membres connectés (tous processus confondus avec DatabaseBroker) ; un membre
# est identifié par member["id"] et compté une fois même s'il a plusieurs onglets. Si un processus meurt sans
# prévenir, ses membres restent affichés jusqu'à la purge de l'historique (retention).

from core use len, type, to_int
from collections use append, keys, remove
use asyncio as _aio
use json as _json
use time as _time
use random as _random
use alweb.errors as _err
use alweb.orm as _orm
use string as _s
use web.server.streaming as _st

# ---------------------------------------------------------------- courtiers

# Événements gardés en mémoire du processus : history derniers événements par salon.
class MemoryBroker:
    func init(history=1000):
        self.local = true                # événements livrés dès leur publication
        self.history = history
        self.seq = 0
        self.events = {}                 # salon -> liste de [id, événement]

    async func start(hub):
        return null

    async func stop():
        return null

    async func publish(room, event):
        self.seq += 1
        if not (room in self.events):
            self.events[room] = []
        lst := self.events[room]
        append(lst, [self.seq, event])
        if len(lst) > self.history:
            self.events[room] = lst[len(lst) - self.history:len(lst)]
        return self.seq

    # Événements du salon d'identifiant > last_id (au plus limit, les plus anciens d'abord).
    async func since(room, last_id, limit=500):
        out := []
        if not (room in self.events):
            return out
        for e in self.events[room]:
            if e[0] > last_id:
                append(out, e)
                if len(out) >= limit:
                    break
        return out

    async func latest(room):
        if not (room in self.events) or len(self.events[room]) == 0:
            return 0
        lst := self.events[room]
        return lst[len(lst) - 1][0]

# Événements dans une table partagée (SQLite sur fichier, PostgreSQL ou ALEX DB) : chaque processus publie dans la table et
# la relit toutes les interval secondes ; tous les événements, y compris les siens, sont livrés aux sockets dans
# l'ordre de leurs identifiants, le même pour tous les clients de tous les processus (latence : interval). db : alweb.database(url). retention : secondes
# pendant lesquelles les événements restent rejouables (historique SSE, présence au démarrage d'un processus).
class DatabaseBroker:
    # db : base, ou fonction sans argument qui la rend (base ouverte au démarrage : () => app.value("db")).
    func init(db, interval=0.05, retention=3600, table="alweb_events"):
        self.local = false
        self.db = db
        self.interval = interval
        self.retention = retention
        self.table = table
        self.origin = str(to_int(_time.time() * 1000)) + "-" + str(_random.randint(100000, 999999))
        self.running = false
        self.task = null
        self.last = 0
        self.ready = false
        self.polls = 0

    async func setup():
        if self.ready:
            return
        if type(self.db) == "function":
            self.db = self.db()
        d := _orm.dialect(self.db)
        idcol := "BIGSERIAL PRIMARY KEY" if d == "postgres" else ("INT PRIMARY KEY" if d == "alexdb" else "INTEGER PRIMARY KEY AUTOINCREMENT")
        await self.db.execute("CREATE TABLE IF NOT EXISTS " + self.table + " (id " + idcol + ", room TEXT NOT NULL, origin TEXT NOT NULL, created " + _orm.float_type(self.db) + " NOT NULL, payload TEXT NOT NULL)")
        # ALEX DB : index d'une colonne (pas d'index composite) ; ses identifiants ne sont jamais réattribués
        await self.db.execute("CREATE INDEX IF NOT EXISTS " + self.table + "_room ON " + self.table + (" (room)" if d == "alexdb" else " (room, id)"))
        self.ready = true

    # Rejoue les événements retenus (présence), puis lance la relève périodique.
    async func start(hub):
        await self.setup()
        await self._prune()
        rows := await self.db.query("SELECT id, room, payload FROM " + self.table + " ORDER BY id", [])
        for r in rows:
            hub.room(r["room"])._apply(_json.parse(r["payload"]))
            self.last = to_int(r["id"])
        self.running = true
        self.task = self._loop(hub)
        return null

    async func stop():
        self.running = false
        if self.task != null:
            _aio.cancel(self.task)
            self.task = null
        return null

    async func publish(room, event):
        await self.setup()
        return to_int(await self.db.insert(self.table, {"room": room, "origin": self.origin, "created": _time.time(), "payload": _json.stringify(event)}))

    async func since(room, last_id, limit=500):
        await self.setup()
        rows := await self.db.query("SELECT id, payload FROM " + self.table + " WHERE room = ? AND id > ? ORDER BY id LIMIT " + str(to_int(limit)), [room, last_id])
        out := []
        for r in rows:
            append(out, [to_int(r["id"]), _json.parse(r["payload"])])
        return out

    async func latest(room):
        await self.setup()
        v := await self.db.scalar("SELECT MAX(id) FROM " + self.table + " WHERE room = ?", [room])
        return to_int(v) if v != null else 0

    async func _loop(hub):
        while self.running:
            try:
                await self.poll(hub)
            catch e:
                if e.type == "CancelledError":
                    return
                hub.errors = hub.errors + [str(e)]
            await _aio.sleep(self.interval)

    # Une relève : livre aux sockets de ce processus les nouveaux événements, dans l'ordre (la présence des
    # événements de ce processus est déjà à jour depuis leur publication).
    async func poll(hub):
        rows := await self.db.query("SELECT id, room, origin, payload FROM " + self.table + " WHERE id > ? ORDER BY id LIMIT 1000", [self.last])
        for r in rows:
            id := to_int(r["id"])
            hub._deliver(r["room"], id, _json.parse(r["payload"]), r["origin"] != self.origin)
            if id > self.last:
                self.last = id
        self.polls += 1
        if self.polls % 1200 == 0:
            await self._prune()

    async func _prune():
        await self.db.execute("DELETE FROM " + self.table + " WHERE created < ?", [_time.time() - self.retention])


# ---------------------------------------------------------------- concentrateur et salons

class Hub:
    func init(broker=null):
        self.broker = broker if broker != null else MemoryBroker()
        self.rooms = {}
        self.waiters = {}                # salon -> futurs des flux SSE en attente
        self.errors = []
        self.started = false

    # Démarre et arrête le concentrateur avec l'application (app.on_startup / on_shutdown).
    func attach(app):
        app.on_startup(() => self.start())
        app.on_shutdown(() => self.stop())
        return self

    async func start():
        if self.started:
            return self
        await self.broker.start(self)
        self.started = true
        return self

    async func stop():
        await self.broker.stop()
        self.started = false
        return self

    func room(name):
        n := str(name)
        if not (n in self.rooms):
            self.rooms[n] = Room(self, n)
        return self.rooms[n]

    # Publie un événement dans un salon (tous processus) ; rend son identifiant.
    async func publish(room, kind, data=null, member=null):
        ev := {"type": kind, "data": data, "member": member}
        id := await self.broker.publish(str(room), ev)
        if self.broker.local:
            self._deliver(str(room), id, ev, true)
        else:
            self.room(room)._apply(ev)    # présence à jour tout de suite ; diffusion à la relève, dans l'ordre
        return id

    # Événements manqués depuis last_id (messages au format envoyé aux clients).
    async func history(room, last_id=0, limit=500):
        out := []
        for e in await self.broker.since(str(room), last_id, limit):
            append(out, _wire(str(room), e[0], e[1]))
        return out

    func _deliver(room, id, ev, apply):
        r := self.room(room)
        if apply:
            r._apply(ev)
        r._fanout(id, _json.stringify(_wire(room, id, ev)))
        if room in self.waiters:
            ws := self.waiters[room]
            self.waiters[room] = []
            for f in ws:
                _aio.resolve(f, true)

    func _waiter(room):
        f := _aio.future()
        if not (room in self.waiters):
            self.waiters[room] = []
        append(self.waiters[room], f)
        return f

    # Gestionnaire de route SSE pour un salon : room_of est un nom ou fn(req) -> nom. Sans Last-Event-ID (ni
    # paramètre ?last_event_id=), le flux commence aux événements à venir ; avec, il rejoue d'abord ce qui manque.
    func sse(room_of, keepalive=15.0):
        return _st.sse((req, flux) => self._sse(req, flux, room_of), keepalive)

    async func _sse(req, flux, room_of):
        req.params = req.route_params
        room := str(room_of(req) if type(room_of) != "str" else room_of)
        last := _parse_id(flux.last_event_id)
        if last == null:
            last = _parse_id(req.query_param("last_event_id"))
        if last == null:
            last = await self.broker.latest(room)
        while not flux.closed:
            f := self._waiter(room)
            evs := await self.broker.since(room, last, 500)
            for e in evs:
                w := _wire(room, e[0], e[1])
                await flux.send(w, w["type"], e[0])
                last = e[0]
            if len(evs) == 0:
                await _aio.race([f, _aio.sleep(1.0)])

# Salon : sockets locales (ce processus) et présence (tous processus).
class Room:
    func init(hub, name):
        self.hub = hub
        self.name = name
        self.sockets = []                # [ws, membre, id du join] : la session reçoit les événements suivants
        self.presence = {}               # id du membre -> [membre, nombre de connexions]

    # Annonce le membre (événement « join », non renvoyé à la session qui arrive) puis ajoute la session au salon.
    async func join(ws, member=null):
        m := _member(member)
        id := await self.hub.publish(self.name, "join", null, m)
        append(self.sockets, [ws, m, id])
        return id

    async func leave(ws):
        kept := []
        gone := null
        for e in self.sockets:
            if e[0] == ws:
                gone = e[1]
            else:
                append(kept, e)
        self.sockets = kept
        if gone == null:
            return null
        return await self.hub.publish(self.name, "leave", null, gone)

    # Diffuse data à tous les membres du salon (tous processus) ; rend l'identifiant de l'événement.
    async func broadcast(data, member=null, kind="message"):
        return await self.hub.publish(self.name, kind, data, member)

    # Membres connectés, sans doublon.
    func members():
        out := []
        for k in keys(self.presence):
            append(out, self.presence[k][0])
        return out

    func count():
        return len(keys(self.presence))

    # Boucle complète d'une session : join, puis chaque message texte reçu est passé à on_message(ws, texte,
    # membre) s'il est donné (sinon diffusé tel quel), et leave à la fermeture.
    async func serve(ws, member=null, on_message=null):
        m := _member(member)
        await self.join(ws, m)
        try:
            while true:
                msg := await ws.receive()
                if msg == null:
                    break
                if on_message != null:
                    r := on_message(ws, msg.text(), m)
                    if _aio.is_future(r):
                        await r
                else:
                    await self.broadcast(msg.text(), m)
        finally:
            await self.leave(ws)

    func _apply(ev):
        m := ev["member"]
        if m == null or not ("id" in m):
            return
        k := str(m["id"])
        if ev["type"] == "join":
            if k in self.presence:
                self.presence[k][1] = self.presence[k][1] + 1
            else:
                self.presence[k] = [m, 1]
        elif ev["type"] == "leave" and k in self.presence:
            n := self.presence[k][1] - 1
            if n <= 0:
                remove(self.presence, k)
            else:
                self.presence[k][1] = n

    func _fanout(id, text):
        dead := false
        for e in self.sockets:
            ws := e[0]
            if ws.closed:
                dead = true
                continue
            if id <= e[2]:
                continue
            try:
                ws.send_text(text)
            catch err:
                dead = true
        if dead:
            kept := []
            for e in self.sockets:
                if not e[0].closed:
                    append(kept, e)
            self.sockets = kept

func _wire(room, id, ev):
    return {"id": id, "room": room, "type": ev["type"], "data": ev["data"], "member": ev["member"]}

_anon := [0]

func _member(member):
    if member == null:
        _anon[0] = _anon[0] + 1
        return {"id": "anonyme-" + str(_random.randint(1000, 9999)) + "-" + str(_anon[0])}
    if type(member) != "dict":
        return {"id": str(member)}
    if not ("id" in member):
        _err.alweb_error("Room.join", "membre sans clé « id »")
    return member

func _parse_id(v):
    if v == null or v == "":
        return null
    try:
        return to_int(v)
    catch e:
        return null
