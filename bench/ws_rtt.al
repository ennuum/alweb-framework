# Latence aller-retour WebSocket (écho), session async de web.server.  alexc run bench/ws_rtt.al
use time
use concurrency.thread as thread
use network.websocket as wsc
use web.server as server
from core use len

async func echo(req, ws):
    while true:
        m := await ws.receive()
        if m == null:
            return
        await ws.send_text(m.text())

func client(port, n, pause):
    c := wsc.connect("ws://127.0.0.1:" + str(port) + "/ws")
    total := 0.0
    worst := 0.0
    i := 0
    while i < n:
        if pause > 0:
            time.sleep(pause)
        t0 := time.monotonic()
        c.send_text("ping " + str(i))
        c.receive(5.0)
        dt := time.monotonic() - t0
        total += dt
        if dt > worst:
            worst = dt
        i += 1
    c.close()
    return [total / n * 1000.0, worst * 1000.0]

if thread.is_main():
    app := server.App()
    app.websocket("/ws", echo)
    srv := server.Server(app, server.config("127.0.0.1", 0)).start()
    for cas in [[500, 0.0], [50, 0.1]]:
        t := thread.spawn(client, [srv.port(), cas[0], cas[1]])
        while t.is_alive():
            await srv.serve_for_async(0.05)
        r := t.join(5.0)
        print("messages enchaînés" if cas[1] == 0.0 else "messages espacés de 100 ms", ": moyenne", r[0], "ms, pire", r[1], "ms")
    srv.close()
