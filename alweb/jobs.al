# alweb.jobs — tâches de fond persistantes : file d'attente en base (survit à un redémarrage, partagée entre les
# processus), nouveaux essais espacés, délai d'exécution, tâches planifiées (intervalle ou expression cron) sans
# doublon entre processus.
#
#   use alweb.jobs as jobs
#   q := jobs.Queue(app, jobs.DatabaseStore(() => app.value("db")))      # ou jobs.MemoryStore() (un processus)
#
#   @q.task("rapport")
#   async func rapport(payload, job):                 # job : id, name, attempt, max_attempts, app
#       ...                                           # une exception : nouvel essai plus tard
#
#   await q.enqueue("rapport", {"id": 3})                               # dès que possible
#   await q.enqueue("rapport", {"id": 3}, {"delay": 600, "attempts": 3, "key": "rapport-3"})
#
#   @q.every("menage", "30 3 * * *")                  # tous les jours à 3 h 30 (heure locale du serveur)
#   async func menage(payload, job): ...
#   q.every("pouls", 300, battre)                     # toutes les 5 minutes
#
# run et run_workers font tourner la file dans chaque processus qui sert (pas dans le maître) ; les tests la font
# avancer à la main : await q.run_pending() (ou at.run_jobs(app)). Avec une file, mailer.send_later passe par elle
# (tâche « alweb.mail » : un courriel en échec est réessayé) ; mail.queue = false pour l'envoyer tout de suite.
#
# Options de Queue (dict) : concurrency (4 tâches à la fois par processus), poll (1 s entre deux relevés),
# timeout (600 s par exécution), attempts (5), backoff (30 s : 30, 60, 120… entre essais, au plus 6 h),
# keep_done (1 jour), keep_failed (7 jours), utc (false : cron en heure locale).
# Options d'enqueue : delay (s), at (horodatage), attempts, key (une seule tâche en attente pour cette clé : un
# second enqueue avec la même clé est ignoré et rend null tant que la première n'est pas finie ; once : true,
# ignoré tant que la tâche est gardée, même finie — c'est ainsi qu'un créneau planifié ne tourne qu'une fois).
#
# Une tâche est « au moins une fois » : un processus qui meurt en pleine exécution la laisse « en cours » ; elle
# repart après timeout. Écrivez des tâches qu'on peut rejouer sans dommage.
from core use len, type, to_int, to_float, is_callable
from collections use append, keys
use os as _os
use io as _io
use time as _time
use json as _json
use string as _s
use asyncio as _aio
use network.security as _sec
use network.encoding as _enc
use alweb.errors as _err
use alweb.orm as _orm

const MAX_BACKOFF := 21600.0

# ================================================================ planification

# Prochain instant (secondes depuis 1970, à la minute) strictement après t pour une expression cron à 5 champs
# « minute heure jour-du-mois mois jour-de-la-semaine » (*, listes a,b, plages a-b, pas */n ou a-b/n ; dimanche
# = 0 ou 7). offset : décalage de l'heure locale (s à l'est de UTC). Jour du mois et jour de la semaine tous deux
# restreints : l'un ou l'autre suffit (comme cron).
func cron_next(expr, t, offset=0):
    c := parse_cron(expr)
    start := (to_int(t) + offset) // 60 * 60 + 60           # minute suivante, en heure locale
    day := start // 86400
    first_min := (start % 86400) // 60
    n := 0
    while n < 1500:                                        # au plus 4 ans (29 février un lundi…)
        f := _time.gmtime(day * 86400)
        if c["month"][f["month"]] and _day_ok(c, f):
            m := first_min if n == 0 else 0
            while m < 1440:
                h := m // 60
                if c["hour"][h] and c["minute"][m % 60]:
                    return day * 86400 + m * 60 - offset
                m += 1
        day += 1
        n += 1
    _err.alweb_error("jobs.cron", "« " + expr + " » ne se produit jamais")

func _day_ok(c, f):
    dow := (f["weekday"] + 1) % 7                           # time : lundi = 0 ; cron : dimanche = 0
    dom_ok := c["dom"][f["day"]]
    dow_ok := c["dow"][dow]
    if c["dom_star"] or c["dow_star"]:
        return dom_ok and dow_ok
    return dom_ok or dow_ok

# Expression cron -> {minute, hour, dom, month, dow : tableaux de booléens, dom_star, dow_star}.
func parse_cron(expr):
    if type(expr) != "str":
        _err.alweb_error("jobs.cron", "expression cron attendue (texte)")
    parts := []
    for p in _s.split(_s.trim(expr), " "):
        if p != "":
            append(parts, p)
    if len(parts) != 5:
        _err.alweb_error("jobs.cron", "« " + expr + " » : 5 champs attendus (minute heure jour mois jour-de-semaine)")
    dow := _field(parts[4], 0, 7, expr)
    if dow[7]:
        dow[0] = true
    return {"minute": _field(parts[0], 0, 59, expr), "hour": _field(parts[1], 0, 23, expr), "dom": _field(parts[2], 1, 31, expr), "month": _field(parts[3], 1, 12, expr), "dow": dow, "dom_star": parts[2] == "*", "dow_star": parts[4] == "*"}

func _field(text, lo, hi, expr):
    out := []
    i := 0
    while i <= hi:
        append(out, false)
        i += 1
    for item in _s.split(text, ","):
        step := 1
        rng := item
        k := _s.find(item, "/")
        if k >= 0:
            step = _int(_s.slice(item, k + 1, len(item)), expr)
            rng = _s.slice(item, 0, k)
            if step < 1:
                _err.alweb_error("jobs.cron", "« " + expr + " » : pas nul")
        a := lo
        b := hi
        if rng != "*":
            d := _s.find(rng, "-")
            if d >= 0:
                a = _int(_s.slice(rng, 0, d), expr)
                b = _int(_s.slice(rng, d + 1, len(rng)), expr)
            else:
                a = _int(rng, expr)
                b = a if k < 0 else hi
        if a < lo or b > hi or a > b:
            _err.alweb_error("jobs.cron", "« " + expr + " » : " + item + " hors de " + str(lo) + "-" + str(hi))
        v := a
        while v <= b:
            out[v] = true
            v += step
    return out

func _int(t, expr):
    ok := t != "" and len(t) <= 4
    for ch in t:
        c := str(ch)
        if c < "0" or c > "9":
            ok = false
    if not ok:
        _err.alweb_error("jobs.cron", "« " + expr + " » : nombre attendu, obtenu « " + t + " »")
    return to_int(t)

# Prochain créneau d'une planification (secondes : multiples de l'intervalle depuis 1970, donc les mêmes dans
# tous les processus ; texte : cron).
func next_slot(schedule, t, offset=0):
    if type(schedule) == "int" or type(schedule) == "float":
        every := to_float(schedule)
        return (_floor(t / every) + 1) * every
    return cron_next(schedule, t, offset) * 1.0

func _floor(x):
    i := to_int(x)
    return i - 1 if i > x else i

# ================================================================ magasins

func _new_id():
    return _s.replace(_s.replace(_sec.random_token(12), "-", "x"), "_", "y")

# Tâches en mémoire : un seul processus, perdues à l'arrêt (tests, petites applications).
class MemoryStore:
    func init():
        self.rows = {}

    async func setup():
        return null

    async func insert(row, once=false):
        if row["id"] in self.rows:
            old := self.rows[row["id"]]
            if once or old["status"] == "pending" or old["status"] == "running":
                return false
        r := _copy(row)
        r["status"] = "pending"
        r["attempts"] = 0
        r["locked_by"] = null
        r["locked_at"] = null
        r["last_error"] = null
        r["finished_at"] = null
        self.rows[row["id"]] = r
        return true

    async func due(now, limit):
        cand := []
        for k in keys(self.rows):
            r := self.rows[k]
            if r["status"] == "pending" and r["run_at"] <= now:
                append(cand, r)
        cand = _sort_by_run_at(cand)
        out := []
        for r in cand:
            if len(out) < limit:
                append(out, r["id"])
        return out

    async func claim(id, worker, now):
        if not (id in self.rows) or self.rows[id]["status"] != "pending":
            return null
        r := self.rows[id]
        r["status"] = "running"
        r["locked_by"] = worker
        r["locked_at"] = now
        r["attempts"] = r["attempts"] + 1
        return _copy(r)

    async func finish(id, now):
        if id in self.rows:
            self.rows[id]["status"] = "done"
            self.rows[id]["finished_at"] = now

    async func retry(id, run_at, error):
        if id in self.rows:
            r := self.rows[id]
            r["status"] = "pending"
            r["run_at"] = run_at
            r["last_error"] = error
            r["locked_by"] = null

    async func fail(id, error, now):
        if id in self.rows:
            r := self.rows[id]
            r["status"] = "failed"
            r["last_error"] = error
            r["finished_at"] = now

    async func recover(before):
        n := 0
        for k in keys(self.rows):
            r := self.rows[k]
            if r["status"] == "running" and r["locked_at"] < before:
                r["status"] = "pending"
                r["last_error"] = "interrompue (processus arrêté ou délai dépassé)"
                n += 1
        return n

    async func purge(done_before, failed_before):
        kept := {}
        n := 0
        for k in keys(self.rows):
            r := self.rows[k]
            gone := (r["status"] == "done" and r["finished_at"] < done_before) or (r["status"] == "failed" and r["finished_at"] < failed_before)
            if gone:
                n += 1
            else:
                kept[k] = r
        self.rows = kept
        return n

    async func delete(id):
        if not (id in self.rows) or self.rows[id]["status"] == "running":
            return false
        self.rows = _without(self.rows, id)
        return true

    async func requeue(id, now):
        n := 0
        for k in keys(self.rows):
            r := self.rows[k]
            if r["status"] == "failed" and (id == null or k == id):
                r["status"] = "pending"
                r["run_at"] = now
                r["attempts"] = 0
                n += 1
        return n

    async func get(id):
        return _copy(self.rows[id]) if id in self.rows else null

    async func list(status=null, limit=100):
        out := []
        for r in _sort_by_run_at(_values(self.rows)):
            if (status == null or r["status"] == status) and len(out) < limit:
                append(out, _copy(r))
        return out

    async func counts():
        c := {"pending": 0, "running": 0, "done": 0, "failed": 0}
        for k in keys(self.rows):
            c[self.rows[k]["status"]] = c[self.rows[k]["status"]] + 1
        return c

# Tâches dans une table de la base de l'application : persistantes, partagées entre processus et serveurs
# (SQLite, PostgreSQL, ALEX DB). db : base, ou fonction qui la rend (() => app.value("db")).
class DatabaseStore:
    func init(db, table="alweb_jobs"):
        _check_ident(table)
        self.db = db
        self.table = table
        self.ready = false

    async func setup():
        if self.ready:
            return null
        if is_callable(self.db):
            self.db = self.db()
            if _aio.is_future(self.db):
                self.db = await self.db
        if self.db == null:
            _err.alweb_error("jobs.DatabaseStore", "base absente (dépendance pas encore ouverte : app.start() d'abord ?)")
        d := _orm.dialect(self.db)
        fl := _orm.float_type(self.db)
        it := "INT" if d == "alexdb" else "INTEGER"
        t := self.table
        await self.db.execute("CREATE TABLE IF NOT EXISTS " + t + " (id TEXT PRIMARY KEY, name TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, run_at " + fl + " NOT NULL, attempts " + it + " NOT NULL, max_attempts " + it + " NOT NULL, locked_by TEXT, locked_at " + fl + ", last_error TEXT, created_at " + fl + " NOT NULL, finished_at " + fl + ")", [])
        await self.db.execute("CREATE INDEX IF NOT EXISTS " + t + "_status ON " + t + " (status" + ("" if d == "alexdb" else ", run_at") + ")", [])
        self.ready = true
        return null

    async func insert(row, once=false):
        await self.setup()
        t := self.table
        old := await self.db.query_one("SELECT status FROM " + t + " WHERE id = ?", [row["id"]])
        if old != null:
            if once or old["status"] == "pending" or old["status"] == "running":
                return false
            await self.db.execute("DELETE FROM " + t + " WHERE id = ? AND status IN ('done', 'failed')", [row["id"]])
        try:
            await self.db.execute("INSERT INTO " + t + " (id, name, payload, status, run_at, attempts, max_attempts, created_at) VALUES (?, ?, ?, 'pending', ?, 0, ?, ?)", [row["id"], row["name"], row["payload"], row["run_at"], row["max_attempts"], row["created_at"]])
        catch e:
            # même clé insérée au même moment par un autre processus (tâche planifiée) : déjà prise
            if await self.db.query_one("SELECT id FROM " + t + " WHERE id = ?", [row["id"]]) != null:
                return false
            raise(e.type, e.message)
        return true

    async func due(now, limit):
        await self.setup()
        out := []
        for r in await self.db.query("SELECT id FROM " + self.table + " WHERE status = 'pending' AND run_at <= ? ORDER BY run_at LIMIT " + str(to_int(limit)), [now]):
            append(out, r["id"])
        return out

    # Réservation atomique : seul le processus dont l'UPDATE touche la ligne l'exécute.
    async func claim(id, worker, now):
        r := await self.db.execute("UPDATE " + self.table + " SET status = 'running', locked_by = ?, locked_at = ?, attempts = attempts + 1 WHERE id = ? AND status = 'pending'", [worker, now, id])
        if r["rowcount"] != 1:
            return null
        return await self.get(id)

    async func finish(id, now):
        await self.db.execute("UPDATE " + self.table + " SET status = 'done', finished_at = ?, locked_by = NULL WHERE id = ?", [now, id])

    async func retry(id, run_at, error):
        await self.db.execute("UPDATE " + self.table + " SET status = 'pending', run_at = ?, last_error = ?, locked_by = NULL WHERE id = ?", [run_at, error, id])

    async func fail(id, error, now):
        await self.db.execute("UPDATE " + self.table + " SET status = 'failed', last_error = ?, finished_at = ?, locked_by = NULL WHERE id = ?", [error, now, id])

    async func recover(before):
        await self.setup()
        r := await self.db.execute("UPDATE " + self.table + " SET status = 'pending', last_error = ?, locked_by = NULL WHERE status = 'running' AND locked_at < ?", ["interrompue (processus arrêté ou délai dépassé)", before])
        return r["rowcount"]

    async func purge(done_before, failed_before):
        await self.setup()
        a := await self.db.execute("DELETE FROM " + self.table + " WHERE status = 'done' AND finished_at < ?", [done_before])
        b := await self.db.execute("DELETE FROM " + self.table + " WHERE status = 'failed' AND finished_at < ?", [failed_before])
        return a["rowcount"] + b["rowcount"]

    async func delete(id):
        await self.setup()
        r := await self.db.execute("DELETE FROM " + self.table + " WHERE id = ? AND status <> 'running'", [id])
        return r["rowcount"] == 1

    async func requeue(id, now):
        await self.setup()
        sql := "UPDATE " + self.table + " SET status = 'pending', run_at = ?, attempts = 0 WHERE status = 'failed'"
        r := await self.db.execute(sql + (" AND id = ?" if id != null else ""), [now, id] if id != null else [now])
        return r["rowcount"]

    async func get(id):
        await self.setup()
        return _row(await self.db.query_one("SELECT * FROM " + self.table + " WHERE id = ?", [id]))

    async func list(status=null, limit=100):
        await self.setup()
        out := []
        sql := "SELECT * FROM " + self.table + (" WHERE status = ?" if status != null else "") + " ORDER BY run_at LIMIT " + str(to_int(limit))
        for r in await self.db.query(sql, [status] if status != null else []):
            append(out, _row(r))
        return out

    async func counts():
        await self.setup()
        c := {"pending": 0, "running": 0, "done": 0, "failed": 0}
        for r in await self.db.query("SELECT status, COUNT(*) AS n FROM " + self.table + " GROUP BY status", []):
            c[r["status"]] = to_int(r["n"])
        return c

func _row(r):
    if r == null:
        return null
    out := {}
    for k in keys(r):
        out[k] = r[k]
    for k in ["attempts", "max_attempts"]:
        out[k] = to_int(out[k])
    return out

func _check_ident(name):
    i := 0
    for ch in name:
        c := str(ch)
        if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (i > 0 and c >= "0" and c <= "9")):
            _err.alweb_error("jobs", "nom de table invalide : " + name)
        i += 1

func _copy(d):
    out := {}
    for k in keys(d):
        out[k] = d[k]
    return out

func _values(d):
    out := []
    for k in keys(d):
        append(out, d[k])
    return out

func _sort_by_run_at(rows):
    out := []
    for r in rows:
        i := len(out)
        append(out, r)
        while i > 0 and out[i - 1]["run_at"] > r["run_at"]:
            out[i] = out[i - 1]
            i -= 1
        out[i] = r
    return out

# ================================================================ file

# Une exécution vue par la fonction de la tâche.
class Job:
    func init(row, app):
        self.id = row["id"]
        self.name = row["name"]
        self.attempt = row["attempts"]
        self.max_attempts = row["max_attempts"]
        self.app = app
        self.last_error = row["last_error"] if "last_error" in row else null

class Queue:
    # app : alweb.App (devient app.jobs) ou null ; store : DatabaseStore, MemoryStore (défaut) ; options : voir
    # l'en-tête du module.
    func init(app=null, store=null, options=null):
        o := options if options != null else {}
        self.app = app
        self.store = store if store != null else MemoryStore()
        self.handlers = {}
        self.schedules = []
        self.concurrency = _o(o, "concurrency", 4)
        self.poll = to_float(_o(o, "poll", 1.0))
        self.timeout = to_float(_o(o, "timeout", 600.0))
        self.attempts = _o(o, "attempts", 5)
        self.backoff = to_float(_o(o, "backoff", 30.0))
        self.keep_done = to_float(_o(o, "keep_done", 86400.0))
        self.keep_failed = to_float(_o(o, "keep_failed", 604800.0))
        self.utc = _o(o, "utc", false) == true
        self.worker = str(_os.pid()) + "-" + _new_id()
        self.running = {}                   # id -> tâche asyncio
        self.tracked = []                   # mises en file en cours (send_later), attendues par run_pending
        self.stopping = false
        self.loop_task = null
        self.processed = 0
        self.failures = 0
        self.last_purge = 0.0
        self.quiet = false
        self.clock = _time.time
        self.task("alweb.mail", _mail_job)
        if app != null:
            app.jobs = self

    # Déclare la fonction d'une tâche : fn(payload, job), synchrone ou async (décorateur sans fn).
    func task(name, fn=null):
        if fn == null:
            return (f) => self.task(name, f)
        if type(name) != "str" or name == "":
            _err.alweb_error("jobs.task", "nom de tâche requis")
        self.handlers[name] = fn
        return fn

    # Tâche planifiée : schedule en secondes (toutes les N s) ou expression cron ; une seule exécution par
    # créneau, quel que soit le nombre de processus. Les créneaux manqués (service arrêté) ne sont pas rattrapés.
    func every(name, schedule, fn=null, options=null):
        if fn == null:
            return (f) => self.every(name, schedule, f, options)
        if type(schedule) == "str":
            parse_cron(schedule)
        elif not ((type(schedule) == "int" or type(schedule) == "float") and schedule >= 1):
            _err.alweb_error("jobs.every", "intervalle d'au moins 1 s ou expression cron attendu")
        self.task(name, fn)
        o := options if options != null else {}
        append(self.schedules, {"name": name, "schedule": schedule, "next": null, "payload": _o(o, "payload", null), "attempts": _o(o, "attempts", 1)})
        return fn

    func _offset():
        return 0 if self.utc else _time.local_utc_offset()

    # Met une tâche en file ; rend son identifiant, ou null si une tâche de même clé attend déjà.
    async func enqueue(name, payload=null, options=null):
        o := options if options != null else {}
        if not (name in self.handlers):
            _err.alweb_error("jobs.enqueue", "tâche inconnue : " + str(name) + " (déclarer avec @queue.task)")
        now := self.clock()
        at := to_float(o["at"]) if "at" in o else now + to_float(_o(o, "delay", 0))
        id := "k:" + str(o["key"]) if "key" in o and o["key"] != null else _new_id()
        text := _json.stringify(payload)
        row := {"id": id, "name": name, "payload": text, "run_at": at, "max_attempts": _o(o, "attempts", self.attempts), "created_at": now}
        if not await self.store.insert(row, _o(o, "once", false) == true):
            return null
        return id

    # Tâches planifiées dont le créneau est arrivé : mises en file (clé du créneau : une seule par créneau).
    async func _schedule(now):
        for s in self.schedules:
            if s["next"] == null:
                s["next"] = next_slot(s["schedule"], now, self._offset())
                continue
            if now >= s["next"]:
                slot := s["next"]
                s["next"] = next_slot(s["schedule"], now, self._offset())
                await self.enqueue(s["name"], s["payload"], {"key": "cron:" + s["name"] + ":" + str(to_int(slot)), "attempts": s["attempts"], "at": slot, "once": true})

    # Un relevé : planifications, tâches interrompues remises en file, ménage, puis lancement des tâches dues
    # (au plus concurrency en même temps). Rend le nombre de tâches lancées.
    async func tick():
        now := self.clock()
        await self._schedule(now)
        if now - self.last_purge > 300.0:
            self.last_purge = now
            await self.store.recover(now - self.timeout)
            await self.store.purge(now - self.keep_done, now - self.keep_failed)
        free := self.concurrency - len(self.running)
        if free <= 0:
            return 0
        started := 0
        for id in await self.store.due(now, free):
            row := await self.store.claim(id, self.worker, now)
            if row != null:
                self.running[id] = self._execute(row)
                started += 1
        return started

    async func _execute(row):
        id := row["id"]
        err := null
        try:
            fn := self.handlers[row["name"]] if row["name"] in self.handlers else null
            if fn == null:
                raise("JobError", "aucune fonction pour la tâche « " + row["name"] + " » dans ce processus")
            r := fn(_json.parse(row["payload"]), Job(row, self.app))
            if _aio.is_future(r):
                await _aio.timeout(r, self.timeout)
        catch e:
            err = str(e.type) + " : " + str(e.message)
        now := self.clock()
        try:
            if err == null:
                await self.store.finish(id, now)
                self.processed += 1
            elif row["attempts"] < row["max_attempts"]:
                wait := self.backoff * _pow2(row["attempts"] - 1)
                await self.store.retry(id, now + (wait if wait < MAX_BACKOFF else MAX_BACKOFF), err)
                self.failures += 1
                self._log("« " + row["name"] + " » en échec (essai " + str(row["attempts"]) + "/" + str(row["max_attempts"]) + ") : " + err)
            else:
                await self.store.fail(id, err, now)
                self.failures += 1
                self._log("« " + row["name"] + " » abandonnée après " + str(row["attempts"]) + " essai(s) : " + err)
        finally:
            self.running = _without(self.running, id)
        return err

    func _log(text):
        if not self.quiet:
            print("alweb jobs : " + text)
            _io.flush()

    # Tâche (une mise en file en cours, par exemple) que run_pending attend avant de relever la file.
    func track(task):
        kept := []
        for x in self.tracked:
            if not _aio.done(x):
                append(kept, x)
        append(kept, task)
        self.tracked = kept
        return task

    # Tests et scripts : exécute tout ce qui est dû maintenant (et ce que ces tâches mettent en file pour tout de
    # suite), jusqu'à ce qu'il n'y ait plus rien. Rend le nombre d'exécutions.
    async func run_pending(max_rounds=100):
        n := 0
        k := 0
        while k < max_rounds:
            k += 1
            pend := self.tracked
            self.tracked = []
            for x in pend:
                await x
            started := await self.tick()
            if started == 0 and len(self.running) == 0:
                break
            tasks := []
            for id in keys(self.running):
                append(tasks, self.running[id])
            for x in tasks:
                await x
            n += started
        return n

    # Boucle de fond (run / run_workers) : un relevé toutes les poll secondes, plus vite quand il y a du travail.
    async func loop():
        self.stopping = false
        while not self.stopping:
            started := 0
            try:
                started = await self.tick()
            catch e:
                self._log("relevé en échec : " + str(e.type) + " : " + str(e.message))
            await _aio.sleep(0.05 if started > 0 else self.poll)
        # arrêt : on laisse finir les exécutions en cours (au plus 10 s), les autres repartiront plus tard
        t0 := _time.monotonic()
        while len(self.running) > 0 and _time.monotonic() - t0 < 10.0:
            await _aio.sleep(0.05)
        return self.processed

    func start():
        if self.loop_task == null:
            self.loop_task = self.loop()
        return self.loop_task

    async func stop():
        self.stopping = true
        if self.loop_task != null:
            t := self.loop_task
            self.loop_task = null
            await t
        return self

    async func stats():
        c := await self.store.counts()
        c["processed"] = self.processed
        c["failures"] = self.failures
        c["running_here"] = len(self.running)
        return c

    async func get(id):
        return await self.store.get(id)

    # Supprime une tâche (en attente, finie ou abandonnée ; pas en cours) ; vrai si elle l'a été.
    async func delete(id):
        return await self.store.delete(id)

    # Remet en file une tâche abandonnée (id), ou toutes (id null), avec de nouveaux essais ; rend leur nombre.
    async func retry_failed(id=null):
        return await self.store.requeue(id, self.clock())

    async func list(status=null, limit=100):
        return await self.store.list(status, limit)

func _o(o, k, d):
    return o[k] if k in o and o[k] != null else d

func _pow2(n):
    r := 1.0
    i := 0
    while i < n and i < 30:
        r = r * 2.0
        i += 1
    return r

func _without(d, k):
    out := {}
    for x in keys(d):
        if x != k:
            out[x] = d[x]
    return out

# ================================================================ courriels (alweb.mail.send_later)

async func _mail_job(p, job):
    if job.app == null:
        raise("JobError", "alweb.mail : file sans application")
    o := p["options"]
    if "attachments64" in o:
        atts := []
        for a in o["attachments64"]:
            if type(a) == "list":
                append(atts, [a[0], _enc.base64_decode(a[1]), a[2]])
            else:
                append(atts, a)
        o["attachments"] = atts
        o = _without(o, "attachments64")
    return await job.app.mail().send(p["to"], p["subject"], p["text"], p["html"], o)
