# HTTPS configuré par server.tls (sans code) : poignée de main vérifiée (certificat, nom), HTTP/1.1 et h2 par
# ALPN, req.secure, HSTS de security_headers, refus d'une configuration incomplète. Tourne aussi dans
# l'exécutable natif (TLS 1.3 écrit en ALEX, network.tls13).   alexc test tests/test_https.al
use time
use string as s
use concurrency.thread as thread
use network.tcp as tcp
use network.tls as tls
use network.tls13 as tls13
use alweb
use alweb.config as conf
use alweb.middleware as mw
use alweb.cli as cli
use os
use io
from testing use assert_eq, assert_true, assert_raises
from core use len

const CERT := "tests/fixtures/localhost-cert.pem"
const CLE := "tests/fixtures/localhost-key.pem"

func make_app(tls_cfg):
    app := alweb.App("https")
    app.configure(conf.from_dict({"server": {"tls": tls_cfg}}))
    app.middleware([mw.security_headers()])
    app.get("/", (req) => {"secure": req.secure, "version": req.version})
    return app

# Client (dans un fil) : requête HTTP/1.1 sur TLS, certificat vérifié contre le fichier du serveur.
func client(port, alpn):
    c := tls.connect("127.0.0.1", port, 20.0, true, CERT, alpn, 0, "localhost")
    info := [c.socket.version, c.socket.alpn]
    c.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    texte := ""
    while true:
        d := c.socket.recv(65536, 20.0)
        if d == "":
            break
        texte = texte + d
    c.close()
    return info + [texte]

async func servir(app, alpn):
    srv := app.server("127.0.0.1", 0).start()
    await app.start()
    t := thread.spawn(client, [srv.port(), alpn])
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < 60.0:
        await srv.serve_for_async(0.01)
    r := t.join(2.0)
    srv.close()
    await app.stop()
    return r

async func test_https_par_la_configuration():
    r := await servir(make_app({"cert": CERT, "key": CLE}), ["http/1.1"])
    assert_eq(r[0], "TLSv1.3")
    assert_eq(r[1], "http/1.1")
    assert_true(s.starts_with(r[2], "HTTP/1.1 200"))
    assert_true(s.contains(r[2], "\"secure\":true"))
    assert_true(s.contains(s.lower(r[2]), "strict-transport-security: max-age="))

async func test_h2_propose_par_alpn():
    r := await servir(make_app({"cert": CERT, "key": CLE}), ["h2", "http/1.1"])
    assert_eq(r[1], "h2")
    r = await servir(make_app({"cert": CERT, "key": CLE, "http2": false}), ["h2", "http/1.1"])
    assert_eq(r[1], "http/1.1")

# Un client qui commence la poignée de main puis se tait ne bloque pas les autres : la boucle fait avancer chaque
# poignée de main sans l'attendre, avec le TLS ALEX comme avec OpenSSL (avant : serveur figé jusqu'au délai de 10 s).
func muet(port):
    c := tcp.connect("127.0.0.1", port, 5.0)
    c.socket.send(s.byte_pack([22, 3, 1, 0, 200, 1, 0, 0]), 5.0)      # début de ClientHello, puis silence
    time.sleep(4.0)
    c.close()
    return true

func presse(port):
    time.sleep(0.5)
    t0 := time.monotonic()
    r := client(port, ["http/1.1"])
    return [time.monotonic() - t0, s.starts_with(r[2], "HTTP/1.1 200")]

async func test_client_muet_ne_bloque_pas():
    app := make_app({"cert": CERT, "key": CLE})
    srv := app.server("127.0.0.1", 0).start()
    await app.start()
    m := thread.spawn(muet, [srv.port()])
    p := thread.spawn(presse, [srv.port()])
    t0 := time.monotonic()
    while p.is_alive() and time.monotonic() - t0 < 30.0:
        await srv.serve_for_async(0.01)
    r := p.join(2.0)
    while m.is_alive() and time.monotonic() - t0 < 30.0:
        await srv.serve_for_async(0.01)
    m.join(2.0)
    srv.close()
    await app.stop()
    assert_true(r[1])
    assert_true(r[0] < 2.0, "requête servie en " + str(r[0]) + " s pendant qu'un client muet occupe une poignée de main")

# Reprise de session : le serveur envoie un ticket, le client le redonne et se reconnecte sans signature. Le
# client est celui d'ALEX (network.tls13), le serveur ALEX ou OpenSSL (contexte partagé entre connexions).
func client_reprise(port, session):
    c := tcp.connect("127.0.0.1", port, 20.0)
    ts := tls13.wrap_client(c.socket, "localhost", ["http/1.1"], 20.0, true, CERT, session)
    ts.send("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", 20.0)
    while ts.recv(65536, 20.0) != "":
        ignored := 0
    sess := ts.session
    reprise := ts.resumed
    ts.close()
    return [reprise, sess]

async func test_reprise_de_session():
    app := make_app({"cert": CERT, "key": CLE})
    srv := app.server("127.0.0.1", 0).start()
    await app.start()
    r := [null, null]
    for i in [0, 1]:
        t := thread.spawn(client_reprise, [srv.port(), r[1]])
        t0 := time.monotonic()
        while t.is_alive() and time.monotonic() - t0 < 30.0:
            await srv.serve_for_async(0.01)
        r = t.join(2.0)
        if i == 0:
            assert_true(r[0] == false and r[1] != null)
    srv.close()
    await app.stop()
    assert_true(r[0])

# `alweb run --https` : certificat de développement créé en ALEX une fois (puis réutilisé), servi et vérifié.
async func test_certificat_de_developpement():
    projet := os.join(os.cwd(), "build/test_https_dev")
    for n in ["localhost.pem", "localhost.key"]:
        p := os.join(projet, ".alweb/dev-tls/" + n)
        if os.exists(p):
            os.remove(p)
    f := cli.dev_certificate(projet)
    avant := io.read_raw(f[0])
    assert_eq(cli.dev_certificate(projet)[0], f[0])
    assert_eq(io.read_raw(f[0]), avant)                  # réutilisé tant qu'il n'expire pas
    app := make_app({"cert": f[0], "key": f[1]})
    srv := app.server("127.0.0.1", 0).start()
    await app.start()
    t := thread.spawn(client_ca, [srv.port(), f[0]])
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < 30.0:
        await srv.serve_for_async(0.01)
    r := t.join(2.0)
    srv.close()
    await app.stop()
    assert_true(s.starts_with(r, "HTTP/1.1 200"))

func client_ca(port, ca):
    c := tls.connect("127.0.0.1", port, 20.0, true, ca, ["http/1.1"], 0, "localhost")
    c.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    texte := ""
    while true:
        d := c.socket.recv(65536, 20.0)
        if d == "":
            break
        texte = texte + d
    c.close()
    return texte

func test_configuration_incomplete():
    assert_raises(() => make_app({"cert": CERT}))
