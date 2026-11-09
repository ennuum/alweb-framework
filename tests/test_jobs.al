# Tâches de fond (alweb.jobs) : expressions cron, file en mémoire et en base (SQLite), nouveaux essais espacés,
# abandon, délai, clé unique, reprise des tâches interrompues, deux processus sur la même base (chaque tâche une
# seule fois), tâches planifiées sans doublon, courriels de send_later par la file, boucle de fond.
#   alexc test tests/test_jobs.al
use time
use string as s
use asyncio as aio
use alweb
use alweb.jobs as jobs
use alweb.config as conf
use alweb.testing as at
use alweb.cli as cli
use os
use database.database as dbm
from testing use assert_eq, assert_true, assert_raises, assert_contains
from core use len
from collections use append

# 2026-11-02 00:00:00 UTC est un lundi.
const LUNDI := 1793577600

func utc(t):
    f := time.gmtime(t)
    return str(f["year"]) + "-" + str(f["month"]) + "-" + str(f["day"]) + " " + str(f["hour"]) + ":" + str(f["minute"]) + " j" + str(f["weekday"])

func test_cron():
    assert_eq(utc(jobs.cron_next("30 3 * * *", LUNDI)), "2026-11-2 3:30 j0")
    assert_eq(utc(jobs.cron_next("30 3 * * *", LUNDI + 4 * 3600)), "2026-11-3 3:30 j1")
    assert_eq(utc(jobs.cron_next("*/15 * * * *", LUNDI + 61)), "2026-11-2 0:15 j0")
    assert_eq(utc(jobs.cron_next("0 9 * * 1-5", LUNDI + 5 * 86400)), "2026-11-9 9:0 j0")       # samedi -> lundi
    assert_eq(utc(jobs.cron_next("0 12 * * 0", LUNDI)), "2026-11-8 12:0 j6")                    # dimanche = 0
    assert_eq(utc(jobs.cron_next("0 12 * * 7", LUNDI)), "2026-11-8 12:0 j6")                    # ou 7
    assert_eq(utc(jobs.cron_next("0 0 29 2 *", LUNDI)), "2028-2-29 0:0 j1")                    # année bissextile
    assert_eq(utc(jobs.cron_next("0 0 13 * 5", LUNDI)), "2026-11-6 0:0 j4")                   # le 13 OU un vendredi
    assert_eq(utc(jobs.cron_next("0 8,18 * * *", LUNDI + 9 * 3600)), "2026-11-2 18:0 j0")
    assert_eq(utc(jobs.cron_next("30 3 * * *", LUNDI, 3600)), "2026-11-2 2:30 j0")             # 3 h 30 à UTC+1
    for faux in ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "*/0 * * * *", "a * * * *", "5-1 * * * *"]:
        assert_raises(() => jobs.parse_cron(faux))
    assert_raises(() => jobs.cron_next("0 0 31 2 *", LUNDI))                                    # jamais
    assert_eq(jobs.next_slot(300, LUNDI + 10), LUNDI + 300.0)                                   # mêmes créneaux partout

# File réglée sur une horloge qu'on avance à la main.
func file(store=null, options=null):
    q := jobs.Queue(null, store, options)
    q.quiet = true
    h := [LUNDI * 1.0]
    q.clock = () => h[0]
    return [q, h]

async func test_execution_et_essais():
    f := file(null, {"backoff": 10})
    q := f[0]
    h := f[1]
    vus := []
    @q.task("addition")
    func addition(p, job):
        append(vus, [p["a"] + p["b"], job.attempt, job.name])
    @q.task("capricieuse")
    async func capricieuse(p, job):
        await aio.sleep(0)
        if job.attempt < 3:
            raise("Panne", "essai " + str(job.attempt))
        append(vus, "réussie au 3e essai")
    @q.task("perdue")
    func perdue(p, job):
        raise("Panne", "toujours")
    await q.enqueue("addition", {"a": 2, "b": 3})
    c := await q.enqueue("capricieuse")
    p := await q.enqueue("perdue", null, {"attempts": 2})
    assert_eq(await q.run_pending(), 3)
    assert_eq(vus, [[5, 1, "addition"]])
    j := await q.get(c)
    assert_eq([j["status"], j["attempts"], j["last_error"]], ["pending", 1, "Panne : essai 1"])
    assert_eq(j["run_at"], h[0] + 10.0)                    # 1er nouvel essai après backoff
    h[0] = h[0] + 10.0
    await q.run_pending()
    assert_eq((await q.get(c))["run_at"], h[0] + 20.0)     # puis 2 × backoff
    h[0] = h[0] + 20.0
    await q.run_pending()
    assert_eq(vus[1], "réussie au 3e essai")
    assert_eq((await q.get(c))["status"], "done")
    j = await q.get(p)
    assert_eq([j["status"], j["attempts"]], ["failed", 2])
    st := await q.stats()
    assert_eq([st["done"], st["failed"], st["pending"]], [2, 1, 0])
    try:
        await q.enqueue("inconnue")
        assert_true(false, "tâche inconnue acceptée")
    catch e:
        assert_contains(e.message, "tâche inconnue")

async func test_delai_cle_et_reprise():
    f := file(null, {"timeout": 60})
    q := f[0]
    h := f[1]
    n := [0]
    func compter(p, job):
        n[0] = n[0] + 1
    q.task("t", compter)
    assert_true(await q.enqueue("t", null, {"delay": 120}) != null)
    assert_eq(await q.run_pending(), 0)                    # pas encore l'heure
    h[0] = h[0] + 120.0
    assert_eq(await q.run_pending(), 1)
    a := await q.enqueue("t", 1, {"key": "unique", "delay": 30})
    assert_eq(a, "k:unique")
    assert_eq(await q.enqueue("t", 2, {"key": "unique"}), null)          # déjà en attente : ignorée
    h[0] = h[0] + 30.0
    await q.run_pending()
    assert_eq(await q.enqueue("t", 3, {"key": "unique"}), "k:unique")    # finie : on peut la remettre
    # tâche « en cours » d'un processus mort : remise en file après timeout
    row := await q.store.claim("k:unique", "mort", h[0])
    assert_eq(row["status"], "running")
    h[0] = h[0] + 400.0
    await q.run_pending()
    assert_eq((await q.get("k:unique"))["status"], "done")
    assert_eq(n[0], 3)

async func test_delai_d_execution():
    f := file(null, {"timeout": 0.2, "attempts": 1})
    q := f[0]
    @q.task("lente")
    async func lente(p, job):
        await aio.sleep(5)
    id := await q.enqueue("lente")
    await q.run_pending()
    j := await q.get(id)
    assert_eq(j["status"], "failed")
    assert_contains(j["last_error"], "Timeout")

async func base_sqlite():
    db := alweb.database("sqlite::memory:")
    return db

async func test_en_base_et_deux_processus():
    if not ("sqlite" in dbm.backends()):
        print("  (pas de SQLite ici : exécutable natif)")
        return
    db := alweb.database("sqlite:build/test_jobs.db")
    await db.execute("DROP TABLE IF EXISTS alweb_jobs", [])
    vus := []
    files := []
    for i in [0, 1]:
        f := file(jobs.DatabaseStore(() => db), {"concurrency": 3})
        q := f[0]
        q.task("compte", (p, job) => append(vus, p))
        q.every("minute", 60, (p, job) => append(vus, "créneau"))
        append(files, f)
    q0 := files[0][0]
    for k in [1, 2, 3, 4, 5, 6, 7]:
        await q0.enqueue("compte", k)
    # les deux « processus » relèvent la même file en même temps : chaque tâche n'est faite qu'une fois
    t0 := files[0][0].run_pending()
    t1 := files[1][0].run_pending()
    await t0
    await t1
    assert_eq(len(vus), 7)
    st := await q0.stats()
    assert_eq([st["done"], st["pending"], st["running"]], [7, 0, 0])
    # tâche planifiée : premier relevé = repère ; au créneau suivant, une seule exécution pour les deux
    for f in files:
        await f[0].tick()
        f[1][0] = f[1][0] + 61.0
    await files[0][0].run_pending()
    await files[1][0].run_pending()
    assert_eq(len(vus), 8)
    assert_eq(vus[7], "créneau")
    l := await q0.list("done", 20)
    assert_eq(len(l), 8)
    assert_true(s.starts_with(l[7]["id"], "k:cron:minute:") or s.starts_with(l[0]["id"], "k:cron:minute:"))
    await db.close()

async func test_courriels_par_la_file():
    app := alweb.App("Blog")
    app.configure(conf.from_dict({"mail": {"url": "memory", "from": "noreply@blog.test"}}))
    q := jobs.Queue(app, jobs.MemoryStore())
    q.quiet = true
    assert_true(app.jobs == q)
    app.mail().send_later("a@x.test", "Par la file", "corps", null, {"attachments": [["octets.bin", "\u0000ÿ\u0001", "application/octet-stream"]]})
    assert_eq(len(at.outbox(app)), 0)                     # en file, pas encore envoyé
    assert_eq(await at.run_jobs(app), 1)
    m := at.outbox(app)[0]
    assert_eq([m.to, m.subject], [["a@x.test"], "Par la file"])
    assert_contains(m.raw, "octets.bin")
    # SMTP injoignable : la tâche reste en file pour un nouvel essai, l'erreur est gardée
    app2 := alweb.App("Blog")
    app2.configure(conf.from_dict({"mail": {"url": "smtp://127.0.0.1:1?timeout=2", "from": "noreply@blog.test"}}))
    q2 := jobs.Queue(app2)
    q2.quiet = true
    t := app2.mail().send_later("a@x.test", "Raté", "corps")
    await at.run_jobs(app2)
    l := await q2.list("pending")
    assert_eq(len(l), 1)
    assert_true(l[0]["last_error"] != null)
    assert_eq(l[0]["name"], "alweb.mail")
    # mail.queue = false : envoi direct malgré la file
    app3 := alweb.App("Blog")
    app3.configure(conf.from_dict({"mail": {"url": "memory", "queue": false}}))
    jobs.Queue(app3)
    await app3.mail().send_later("a@x.test", "Direct", "x")
    assert_eq(len(at.outbox(app3)), 1)

async func test_boucle_de_fond():
    q := jobs.Queue(null, null, {"poll": 0.05})
    q.quiet = true
    fait := [false]
    func marquer(p, job):
        fait[0] = true
    q.task("t", marquer)
    q.start()
    await q.enqueue("t")
    t0 := time.monotonic()
    while not fait[0] and time.monotonic() - t0 < 5.0:
        await aio.sleep(0.02)
    await q.stop()
    assert_true(fait[0])
    assert_eq(q.processed, 1)

# `alweb jobs` sur le blog du tutoriel (profil test : base en mémoire, file vide mais lisible).
func test_commande_jobs():
    d := cli.project_jobs(os.join(os.cwd(), "docs/tutoriel/blog"), "status", "", "test")
    assert_eq([d["stats"]["pending"], d["stats"]["failed"]], [0, 0])
    assert_contains(cli.format_jobs(d), "en attente 0")
    assert_contains(cli.format_jobs({"stats": d["stats"], "failed": [{"id": "x1", "name": "alweb.mail", "attempts": 5, "max_attempts": 5, "last_error": "SmtpError : refus"}], "pending": [], "requeued": 1}), "x1  alweb.mail  essais 5/5  SmtpError : refus")
