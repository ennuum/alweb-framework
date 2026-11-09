# Certificat automatique (server.tls.acme, alweb.acme) : réglages, certificat d'attente, port des défis
# (jeton servi, redirection vers HTTPS), puis, si un banc Pebble tourne (ALWEB_TEST_ACME = URL de l'annuaire,
# ALWEB_TEST_ACME_CA = autorité de son API, défis sur le port ALWEB_TEST_ACME_PORT), délivrance de bout en bout :
# le serveur HTTPS en marche passe du certificat d'attente au vrai sans redémarrer.   alexc test tests/test_acme.al
use time
use string as s
use concurrency.thread as thread
use network.tcp as tcp
use network.http as http
use network.tls13 as tls13
use crypto.x509 as x509
use alweb
use alweb.acme as acme
use alweb.config as conf
use os
use io
from testing use assert_eq, assert_true, assert_raises
from core use len, to_int

func dossier(nom):
    d := os.join(os.cwd(), "build/test_acme/" + nom)
    for f in ["exemple.test/cert.pem", "exemple.test/key.pem", "account.key", "challenges/jeton-abc_123"]:
        p := os.join(d, f)
        if os.exists(p):
            os.remove(p)
    return d

func reglages(extra):
    o := {"domains": ["exemple.test", "www.exemple.test"], "agree_tos": true, "http_port": 0}
    for k in extra:
        o[k] = extra[k]
    return o

func test_reglages():
    st := acme.Settings(reglages({"dir": "/srv/x"}))
    assert_eq(st.cert, "/srv/x/exemple.test/cert.pem")
    assert_eq(st.key, "/srv/x/exemple.test/key.pem")
    assert_eq(st.directory, "https://acme-v02.api.letsencrypt.org/directory")
    assert_eq(acme.Settings(reglages({"directory": "staging"})).directory, "https://acme-staging-v02.api.letsencrypt.org/directory")
    assert_eq(acme.Settings(reglages({}), "c.pem", "k.pem").cert, "c.pem")
    assert_raises(() => acme.Settings({"domains": ["exemple.test"]}))                        # sans agree_tos
    assert_raises(() => acme.Settings({"domains": [], "agree_tos": true}))
    assert_raises(() => acme.Settings({"domains": ["*.exemple.test"], "agree_tos": true}))  # joker : pas en http-01
    assert_raises(() => acme.Settings(reglages({"directory": "ftp"})))

func test_configuration_de_l_application():
    app := alweb.App("acme")
    app.configure(conf.from_dict({"server": {"tls": {"acme": reglages({"dir": "build/test_acme/cfg"})}}}))
    assert_eq(app.tls[0], "build/test_acme/cfg/exemple.test/cert.pem")
    assert_true(app.acme != null)

func get(port, chemin, hote):
    c := tcp.connect("127.0.0.1", port, 10.0)
    c.write("GET " + chemin + " HTTP/1.1\r\nHost: " + hote + "\r\nConnection: close\r\n\r\n")
    texte := ""
    while true:
        d := c.socket.recv(65536, 10.0)
        if d == "":
            break
        texte = texte + d
    c.close()
    return texte

func servir(mgr, fn, args):
    t := thread.spawn(fn, args)
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < 20.0:
        mgr.step(0.01)
    return t.join(2.0)

func test_attente_defis_et_redirection():
    d := dossier("defis")
    mgr := acme.Manager(acme.Settings(reglages({"dir": d})), 8443, "127.0.0.1", true).start()
    st := mgr.s
    # certificat d'attente : auto-signé, couvre les noms, clé assortie ; l'ACME le remplacera
    c := x509.load_certificates(io.read_raw(st.cert))[0]
    assert_true(c.issuer_raw == c.subject_raw and x509.matches_host(c, "www.exemple.test"))
    assert_true(x509.key_matches(c, x509.load_private_key(io.read_raw(st.key))))
    io.write_file(os.join(st.challenges, "jeton-abc_123"), "jeton-abc_123.empreinte")
    port := mgr.http_port()
    r := servir(mgr, get, [port, "/.well-known/acme-challenge/jeton-abc_123", "exemple.test"])
    assert_true(s.starts_with(r, "HTTP/1.1 200"))
    assert_true(s.ends_with(r, "\r\n\r\njeton-abc_123.empreinte"))
    assert_true(s.starts_with(servir(mgr, get, [port, "/.well-known/acme-challenge/absent", "exemple.test"]), "HTTP/1.1 404"))
    assert_true(s.starts_with(servir(mgr, get, [port, "/.well-known/acme-challenge/../config", "exemple.test"]), "HTTP/1.1 404"))
    r = servir(mgr, get, [port, "/compte?x=1", "www.exemple.test:80"])
    assert_true(s.starts_with(r, "HTTP/1.1 301"))
    assert_true(s.contains(s.lower(r), "location: https://www.exemple.test:8443/compte?x=1\r\n"))
    mgr.shutdown()

# Autorité injoignable : l'erreur réelle est journalisée, nouvel essai dans 5 min, le service continue.
func test_echec_puis_nouvel_essai():
    mgr := acme.Manager(acme.Settings(reglages({"dir": dossier("echec"), "directory": "https://127.0.0.1:1/dir"})), 8443, "127.0.0.1", true).start()
    t0 := time.monotonic()
    while mgr.last_error == null and time.monotonic() - t0 < 20.0:
        mgr.step(0.01)
    mgr.shutdown()
    assert_true(mgr.last_error != null, "échec signalé")
    assert_true(not s.contains(mgr.last_error, "futur"), "erreur d'origine : " + str(mgr.last_error))
    assert_eq([mgr.failures, mgr.issued, mgr.busy()], [1, 0, false])
    assert_true(mgr.next_check - time.monotonic() > 250.0)

# ---------------------------------------------------------------- de bout en bout (banc Pebble)

func client(port, ca):
    c := tcp.connect("127.0.0.1", port, 20.0)
    ts := tls13.wrap_client(c.socket, "www.exemple.test", ["http/1.1"], 20.0, true, ca)
    ts.send("GET / HTTP/1.1\r\nHost: www.exemple.test\r\nConnection: close\r\n\r\n", 20.0)
    texte := ""
    while true:
        d := ts.recv(65536, 20.0)
        if d == "":
            break
        texte = texte + d
    ts.close()
    return texte

async func test_delivrance_pebble():
    annuaire := os.getenv("ALWEB_TEST_ACME")
    if annuaire == null or annuaire == "":
        print("  (banc Pebble absent : ALWEB_TEST_ACME non défini, délivrance non testée)")
        return
    ca := os.getenv("ALWEB_TEST_ACME_CA")
    d := dossier("pebble")
    app := alweb.App("acme")
    app.configure(conf.from_dict({"server": {"tls": {"acme": reglages({"dir": d, "directory": annuaire, "ca_file": ca, "http_port": to_int(os.getenv("ALWEB_TEST_ACME_PORT", "5002")), "email": "admin@exemple.test"})}}}))
    app.get("/", (req) => "bonjour " + str(req.secure))
    mgr := acme.Manager(app.acme, 0, "127.0.0.1", true).start()
    srv := app.server("127.0.0.1", 0).start()
    await app.start()
    t0 := time.monotonic()
    while mgr.issued == 0 and mgr.last_error == null and time.monotonic() - t0 < 60.0:
        mgr.step(0.005)
        await srv.serve_for_async(0.005)
    mgr.shutdown()
    assert_eq(mgr.last_error, null)
    assert_eq(mgr.issued, 1)
    chaine := x509.load_certificates(io.read_raw(app.acme.cert))
    assert_true(len(chaine) >= 2 and chaine[0].issuer_raw != chaine[0].subject_raw)
    assert_true(not os.exists(os.join(app.acme.challenges, "x")) and len(os.list_dir(app.acme.challenges)) == 0)
    # racine de Pebble (API de gestion) : le client vérifie toute la chaîne servie par le serveur, déjà en marche
    racine := http.request("GET", s.replace(s.replace(annuaire, ":14000", ":15000"), "/dir", "/roots/0"), null, null, 10.0, false, 0, true, ca).body
    rf := os.join(d, "racine.pem")
    io.write_file(rf, racine)
    t := thread.spawn(client, [srv.port(), rf])
    t1 := time.monotonic()
    while t.is_alive() and time.monotonic() - t1 < 30.0:
        await srv.serve_for_async(0.01)
    r := t.join(2.0)
    srv.close()
    await app.stop()
    assert_true(s.starts_with(r, "HTTP/1.1 200"))
    assert_true(s.contains(r, "bonjour true"))
