# Temps réel avec alweb sur un vrai port : salon WebSocket (diffusion entre deux clients), Server-Sent Events,
# intergiciels appliqués à la poignée de main et au flux.  alexc test tests/test_realtime.al
use time
use string as s
use asyncio as aio
use concurrency.thread as thread
use network.websocket as wsc
use network.tcp as tcp
use alweb
use alweb.middleware as mw
from core use len
from collections use append

SALONS := {}

func make_app():
    app := alweb.App("temps réel")
    app.middleware([mw.request_id(), mw.security_headers()])

    @app.websocket("/salon/{nom}")
    async func salon(req, ws):
        nom := req.params["nom"]
        if not (nom in SALONS):
            SALONS[nom] = []
        append(SALONS[nom], ws)
        while true:
            m := await ws.receive()
            if m == null:
                break
            for autre in SALONS[nom]:
                if not autre.closed:
                    await autre.send_text(m.text())
        reste := []
        for w in SALONS[nom]:
            if w != ws:
                append(reste, w)
        SALONS[nom] = reste

    async func compte(req, flux):
        i := 1
        while i <= 3 and not flux.closed:
            await flux.send({"i": i}, "compte", i)
            await aio.sleep(0.02)
            i += 1

    app.get("/compte", alweb.sse(compte))
    return app

func client_a(port):
    c := wsc.connect("ws://127.0.0.1:" + str(port) + "/salon/general")
    time.sleep(0.4)                          # B se connecte
    c.send_text("bonjour de A")
    m1 := c.receive(5.0).text()
    m2 := c.receive(5.0).text()
    c.close()
    return [m1, m2]

func client_b(port):
    time.sleep(0.15)
    c := wsc.connect("ws://127.0.0.1:" + str(port) + "/salon/general")
    m1 := c.receive(5.0).text()
    c.send_text("réponse de B")
    m2 := c.receive(5.0).text()
    c.close()
    return [m1, m2]

func client_sse(port):
    c := tcp.connect("127.0.0.1", port, 3.0)
    c.write("GET /compte HTTP/1.1\r\nHost: x\r\n\r\n")
    recu := ""
    while not s.contains(recu, "0\r\n\r\n"):
        d := c.socket.recv(65536, 5.0)
        if d == "":
            break
        recu = recu + d
    c.close()
    return recu

async func drive(srv, threads, limit=20.0):
    t0 := time.monotonic()
    while time.monotonic() - t0 < limit:
        alive := false
        for t in threads:
            if t.is_alive():
                alive = true
        if not alive:
            return
        await srv.serve_for_async(0.05)

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

if thread.is_main():
    app := make_app()
    srv := app.server("127.0.0.1", 0).start()
    p := srv.port()
    ta := thread.spawn(client_a, [p])
    tb := thread.spawn(client_b, [p])
    tc := thread.spawn(client_sse, [p])
    await drive(srv, [ta, tb, tc])
    ra := ta.join(5.0)
    rb := tb.join(5.0)
    rc := tc.join(5.0)
    srv.close()
    expect(ra == ["bonjour de A", "réponse de B"], "messages reçus par A : " + str(ra))
    expect(rb == ["bonjour de A", "réponse de B"], "messages reçus par B : " + str(rb))
    expect(s.contains(rc, "text/event-stream"), "type SSE absent : " + rc)
    expect(s.contains(rc, "X-Request-Id:") and s.contains(rc, "X-Content-Type-Options: nosniff"), "intergiciels non appliqués au flux : " + rc)
    expect(s.contains(rc, "event: compte\nid: 3\ndata: {\"i\":3}\n\n"), "événements SSE : " + rc)
    expect(len(srv.errors) == 0, "erreurs : " + str(srv.errors))
    print("alweb temps réel : OK")
