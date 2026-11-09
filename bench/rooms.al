# Diffusion dans un salon : 10 clients WebSocket reçoivent 200 messages envoyés par un 11e, en mémoire puis par
# une base SQLite partagée.   alexc run bench/rooms.al
use time
use json
use os
use concurrency.thread as thread
use network.websocket as wsc
use alweb
use alweb.realtime as rt
use database.async_database as adb
from collections use append

N := 10
M := 200

func make_app(shared):
    app := alweb.App("bench")
    hub := rt.Hub(rt.DatabaseBroker(adb.open("sqlite:/tmp/bench_rooms.db")) if shared else null)
    hub.attach(app)
    @app.websocket("/ws")
    async func s(req, ws):
        await hub.room("r").serve(ws, {"id": req.query_param("id")})
    return app

func recepteur(port, i):
    c := wsc.connect("ws://127.0.0.1:" + str(port) + "/ws?id=r" + str(i))
    n := 0
    t0 := null
    while n < M:
        m := c.receive(20.0)
        if m == null:
            break
        e := json.parse(m.text())
        if e["type"] == "message":
            if t0 == null:
                t0 = time.monotonic()
            n += 1
    c.close()
    return [n, time.monotonic()]

func emetteur(port):
    time.sleep(1.0)
    c := wsc.connect("ws://127.0.0.1:" + str(port) + "/ws?id=e")
    time.sleep(0.5)
    t0 := time.monotonic()
    i := 0
    while i < M:
        c.send_text("m" + str(i))
        i += 1
    time.sleep(0.2)
    c.close()
    return t0

async func run(shared):
    if os.exists("/tmp/bench_rooms.db"):
        os.remove("/tmp/bench_rooms.db")
    app := make_app(shared)
    await app.start()
    srv := app.server("127.0.0.1", 0).start()
    ts := []
    i := 0
    while i < N:
        append(ts, thread.spawn(recepteur, [srv.port(), i]))
        i += 1
    te := thread.spawn(emetteur, [srv.port()])
    alive := true
    while alive:
        await srv.serve_for_async(0.01)
        alive = te.is_alive()
        for t in ts:
            alive = alive or t.is_alive()
    t0 := te.join(1.0)
    fin := 0.0
    total := 0
    for t in ts:
        r := t.join(1.0)
        total += r[0]
        if r[1] > fin:
            fin = r[1]
    srv.close()
    await app.stop()
    d := fin - t0
    print(("partagé (SQLite)" if shared else "mémoire") + " : " + str(total) + " livraisons en " + str(d) + " s, soit " + str(total / d) + " messages livrés/s")

if thread.is_main():
    await run(false)
    await run(true)
