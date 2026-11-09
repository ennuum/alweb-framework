# Objets retenus par tâche / requête (fuite de la file des tâches prêtes, correctif 0002).  alexc run bench/leak.al
use gc
use asyncio as aio
use alweb
use alweb.middleware as mw
use alweb.testing as at
use web.http.request as rq

async func passe(req, nxt):
    return await nxt(req)

async func tache_vide():
    return 1

func live():
    gc.collect()
    gc.collect()
    return gc.stats()["live"]

async func mesure(nom, fn, n):
    await fn()
    a := live()
    i := 0
    while i < n:
        await fn()
        i += 1
    b := live()
    print(nom + " : " + str((b - a) / n) + " objets retenus par itération")

async func t_tache():
    await tache_vide()

APP_NU := alweb.App()
APP_NU.get("/", (req) => "x")
APP_MW := alweb.App()
APP_MW.middleware(passe)
APP_MW.get("/", (req) => "x")

async func t_nu():
    APP_NU.handle(rq.Request("GET", "/", {"Host": "x"}))

async func t_mw():
    await APP_MW.handle(rq.Request("GET", "/", {"Host": "x"}))

await mesure("tâche vide", t_tache, 2000)
await mesure("tâche vide (2e passe)", t_tache, 4000)
await mesure("alweb sans intergiciel", t_nu, 1000)
await mesure("alweb, 1 intergiciel async", t_mw, 1000)
