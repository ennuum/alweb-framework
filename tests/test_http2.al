# Une application alweb servie en HTTP/2 : h2c (préface) et h2 sur TLS (ALPN), avec hooks, route async,
# validation, session (cookie) et SSE ; HTTP/1.1 toujours servi.   alexc test tests/test_http2.al
use json
use time
use asyncio as aio
use string as s
use concurrency.thread as thread
use network.tcp as tcp
use network.tls as tls
use network.grpc as g
use serialization.schema as sch
use alweb
use alweb.middleware as mw
use web.client as http
from core use len, to_int
from collections use append

const CERT := "tests/fixtures/localhost-cert.pem"
const CLE := "tests/fixtures/localhost-key.pem"
NOTE := sch.object({"titre": sch.string(1, 20)}, ["titre"])

async func lent(req):
    await aio.sleep(0.2)
    return {"n": req.params["n"], "version": req.version}

async func ticks(req, flux):
    i := 0
    while i < 2:
        await flux.send({"i": i}, "tick", i)
        i += 1

func make_app():
    app := alweb.App("h2")
    app.middleware([mw.request_id(), mw.security_headers()])
    app.get("/lent/{n:int}", lent)
    app.post("/notes", (req) => (alweb.data(req), 201), {"body": NOTE})
    app.get("/sse", alweb.sse(ticks))
    return app

func ouvrir(port, secure):
    if secure:
        c := tls.connect("127.0.0.1", port, 5.0, false, null, ["h2"])
        h := g.H2Connection(c, true)
        h.start()
        return [h, c.socket.alpn]
    h := g.H2Connection(tcp.connect("127.0.0.1", port, 5.0), true)
    h.start()
    return [h, "h2c"]

func envoyer(h, method, path, body=null, scheme="http"):
    st := h.new_stream()
    hs := [[":method", method], [":scheme", scheme], [":authority", "localhost"], [":path", path]]
    if body != null:
        append(hs, ["content-type", "application/json"])
        h.send_headers(st.id, hs, false)
        h.send_data(st.id, body, true, 5.0)
    else:
        h.send_headers(st.id, hs, true)
    return st

func lire(h, st):
    h.wait_until(() => st.ended or st.reset_code != null, 10.0)
    d := {}
    for e in st.headers:
        d[e[0]] = e[1]
    return [to_int(d[":status"]), d, st.take_data()]

func scenario(port, secure):
    out := {}
    o := ouvrir(port, secure)
    h := o[0]
    out["alpn"] = o[1]
    scheme := "https" if secure else "http"
    t0 := time.monotonic()
    flux := [envoyer(h, "GET", "/lent/" + str(i), null, scheme) for i in range(4)]
    rs := [lire(h, f) for f in flux]
    out["multiplex"] = [[json.parse(r[2])["n"] for r in rs], time.monotonic() - t0, json.parse(rs[0][2])["version"]]
    out["entetes"] = [rs[0][1]["x-content-type-options"], len(rs[0][1]["x-request-id"]) > 0, "connection" in rs[0][1]]
    out["valide"] = lire(h, envoyer(h, "POST", "/notes", "{\"titre\": \"ok\"}", scheme))[0]
    out["invalide"] = lire(h, envoyer(h, "POST", "/notes", "{\"titre\": \"\"}", scheme))[0]
    out["sse"] = lire(h, envoyer(h, "GET", "/sse", null, scheme))[2]
    h.close()
    return out

func version_http1(port):
    return http.get("http://127.0.0.1:" + str(port) + "/lent/9").json()["version"]

async func drive(srv, t, limit=30.0):
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < limit:
        await srv.serve_for_async(0.01)

async func servir(secure):
    app := make_app()
    cfg := alweb.https(CERT, CLE) if secure else null
    srv := app.server("127.0.0.1", 0, cfg).start()
    await app.start()
    t := thread.spawn(scenario, [srv.port(), secure])
    await drive(srv, t)
    r := t.join(2.0)
    h1 := null
    if not secure:
        t1 := thread.spawn(version_http1, [srv.port()])
        await drive(srv, t1)
        h1 = t1.join(1.0)
    srv.close()
    await app.stop()
    return [r, h1, srv.metrics.http2_sessions]

func verifier(res, alpn):
    r := res[0]
    if r == null:
        raise("AssertionError", "scénario HTTP/2 inachevé")
    if r["alpn"] != alpn:
        raise("AssertionError", "protocole négocié : " + str(r["alpn"]))
    m := r["multiplex"]
    if m[0] != [0, 1, 2, 3] or m[1] > 0.6 or m[2] != "HTTP/2":
        raise("AssertionError", "multiplexage : " + str(m))
    if r["entetes"] != ["nosniff", true, false]:
        raise("AssertionError", "en-têtes : " + str(r["entetes"]))
    if r["valide"] != 201 or r["invalide"] != 422:
        raise("AssertionError", "validation : " + str([r["valide"], r["invalide"]]))
    if not s.contains(r["sse"], "event: tick\nid: 1\ndata: {\"i\":1}"):
        raise("AssertionError", "SSE : " + r["sse"])
    if res[2] != 1:
        raise("AssertionError", "sessions HTTP/2 : " + str(res[2]))

if thread.is_main():
    clair := await servir(false)
    verifier(clair, "h2c")
    if clair[1] != "HTTP/1.1":
        raise("AssertionError", "HTTP/1.1 sur le même port : " + str(clair[1]))
    # TLS : OpenSSL, ou TLS 1.3 écrit en ALEX (network.tls13) dans l'exécutable natif ou avec ALEX_TLS=alex
    verifier(await servir(true), "h2")
    print("HTTP/2 (h2c et h2 sur TLS, " + tls.backend() + ") : OK")
