# Coût par requête dans le processus (client en mémoire), sans réseau.  alexc run bench/inproc.al
use time
use asyncio as aio
use alweb
use alweb.middleware as mw
use alweb.testing as at

async func passe(req, nxt):
    return await nxt(req)

func make(kind):
    app := alweb.App()
    if kind == "1 intergiciel vide":
        app.middleware(passe)
    if kind == "3 intergiciels":
        app.middleware([mw.request_id(), mw.timing(), mw.security_headers()])
    if kind == "request_id":
        app.middleware(mw.request_id())
    if kind == "timing":
        app.middleware(mw.timing())
    if kind == "security_headers":
        app.middleware(mw.security_headers())
    app.get("/", (req) => "Bonjour")
    return app

async func mesure(kind, n):
    c := at.Client(make(kind))
    await c.get("/")
    t0 := time.monotonic()
    i := 0
    while i < n:
        await c.get("/")
        i += 1
    dt := time.monotonic() - t0
    print(kind + " : " + str(dt / n * 1000000.0) + " µs/requête")

async func bare_tasks(n):
    t0 := time.monotonic()
    i := 0
    while i < n:
        await passe_rien()
        i += 1
    print("tâche vide créée + attendue : " + str((time.monotonic() - t0) / n * 1000000.0) + " µs")

async func passe_rien():
    return 1

await bare_tasks(5000)
for k in ["sans intergiciel", "1 intergiciel vide", "request_id", "timing", "security_headers", "3 intergiciels"]:
    await mesure(k, 1000)
