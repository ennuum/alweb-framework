# Courriels (alweb.mail) : réglages, envois mémoire / console / fichier, gabarits texte et HTML, liens absolus,
# SMTP de bout en bout contre un petit serveur de test (STARTTLS, AUTH PLAIN, DATA ; refus d'authentifier en clair),
# jetons de réinitialisation et de confirmation (alweb.auth), colonne ajoutée par migration (orm.add_column).
#   alexc test tests/test_mail.al
use time
use string as s
use concurrency.thread as thread
use network.tcp as tcp
use network.tls as tls
use network.encoding as enc
use network.utils as nu
use alweb
use alweb.mail as mail
use alweb.auth as auth
use alweb.orm as orm
use database.database as dbm
use alweb.config as conf
use alweb.testing as at
use os
use io
from testing use assert_eq, assert_true, assert_raises, assert_contains
from core use len
from collections use append

const CERT := "tests/fixtures/localhost-cert.pem"
const CLE := "tests/fixtures/localhost-key.pem"
const SECRET := "une-cle-secrete-de-test-assez-longue"

func app_avec(mail_cfg, extra=null):
    d := {"mail": mail_cfg, "secret_key": SECRET}
    if extra != null:
        for k in extra:
            d[k] = extra[k]
    app := alweb.App("Blog")
    app.configure(conf.from_dict(d))
    return app

# ---------------------------------------------------------------- réglages

func test_reglages():
    m := mail.Mailer({"url": "smtp://moi%40x.org:p%3Ass@smtp.exemple.org?starttls=true&timeout=5", "from": "a@x.org"})
    assert_eq(m.kind, "smtp")
    assert_eq([m.smtp["host"], m.smtp["port"], m.smtp["user"], m.smtp["password"], m.smtp["starttls"], m.smtp["timeout"]], ["smtp.exemple.org", 587, "moi@x.org", "p:ss", true, 5.0])
    assert_eq(mail.Mailer({"url": "smtps://smtp.exemple.org"}).describe(), "smtps://smtp.exemple.org:465")
    assert_eq(mail.Mailer({"url": "smtp://relais:25?starttls=false"}).smtp["starttls"], false)
    assert_eq(mail.Mailer(null, true).kind, "console")             # debug sans réglage : console
    assert_eq(mail.Mailer(null, false).kind, "none")
    assert_eq(mail.Mailer({"url": "file:build/courriels"}).describe(), "file:build/courriels")
    assert_raises(() => mail.Mailer({"url": "http://x"}))
    assert_raises(() => mail.Mailer({"url": "file:"}))
    assert_raises(() => mail.Mailer({"url": "smtp://h"}).message("b@x.org", "s", "t"))   # SMTP sans expéditeur
    mm := mail.Mailer({"url": "memory"})
    assert_raises(() => mm.message("pas une adresse", "s", "t"))
    assert_raises(() => mm.message("a@x.org", "s\r\nBcc: c@x.org", "t"))                  # injection d'en-tête

async func test_sans_reglage_en_production():
    app := app_avec(null)
    try:
        await app.mail().send("b@x.org", "Objet", "texte")
        assert_true(false, "envoi sans réglage accepté")
    catch e:
        assert_contains(e.message, "mail.url")

# ---------------------------------------------------------------- mémoire, console, fichier

async func test_memoire():
    app := app_avec({"url": "memory", "from": "Blog <noreply@blog.test>", "reply_to": "contact@blog.test"})
    mid := await app.mail().send("Alice <alice@x.test>", "Été à Montréal", "Bonjour Alice", "<p>Bonjour <b>Alice</b></p>", {"cc": "bob@x.test", "bcc": ["chef@x.test"], "headers": {"X-Campagne": "été"}, "attachments": [["note.txt", "contenu", "text/plain"]]})
    boite := at.outbox(app)
    assert_eq(len(boite), 1)
    m := boite[0]
    assert_eq(m.to, ["alice@x.test"])
    assert_eq(m.cc, ["bob@x.test"])
    assert_eq(m.bcc, ["chef@x.test"])
    assert_eq(m.sender, "noreply@blog.test")
    assert_eq(m.subject, "Été à Montréal")
    assert_eq(m.message_id, mid)
    assert_contains(m.raw, "Reply-To: contact@blog.test")
    assert_contains(m.raw, "X-Campagne:")
    assert_contains(m.raw, "multipart/mixed")
    assert_contains(m.raw, "multipart/alternative")
    assert_true(not s.contains(m.raw, "chef@x.test"), "Bcc absent des en-têtes")
    assert_eq(app.mail().sent, 1)
    assert_eq(len(at.outbox(app, true)), 1)
    assert_eq(len(at.outbox(app)), 0)

async func test_fichier_et_console():
    d := os.join(os.cwd(), "build/test_mail/eml")
    if os.exists(d):
        for f in os.list_dir(d):
            os.remove(os.join(d, f))
    app := app_avec({"url": "file:" + d, "from": "noreply@blog.test"})
    await app.mail().send("a@x.test", "Fichier", "corps")
    fs := os.list_dir(d)
    assert_eq(len(fs), 1)
    assert_true(s.ends_with(fs[0], ".eml"))
    assert_contains(io.read_raw(os.join(d, fs[0])), "Subject: Fichier")
    c := app_avec({"url": "console"})
    await c.mail().send("a@x.test", "Console", "affiché")        # rien à vérifier de plus que l'absence d'erreur
    assert_eq(c.mail().sent, 1)

async func test_envoi_differe():
    app := app_avec({"url": "memory"})
    assert_eq(await app.mail().send_later("a@x.test", "Plus tard", "x"), app.mail().outbox[0].message_id)
    r := await app.mail().send_later("pas une adresse", "Raté", "x")     # erreur journalisée, pas levée
    assert_eq(r, null)
    assert_eq(app.mail().failed, 1)

# ---------------------------------------------------------------- gabarits et liens

async func test_gabarits():
    app := app_avec({"url": "memory"}, {"site_url": "https://blog.test/"})
    app.use_templates("build/test_mail/gabarits")
    app.templates.add("emails/bienvenue.txt", "Bonjour {{ nom }} ! Lien : {{ site_url }}/compte ({{ app_name }})")
    app.templates.add("emails/bienvenue.html", "<p>Bonjour {{ nom }}</p>")
    app.templates.add("emails/texte_seul.txt", "Rien que du texte")
    await app.mail().send_template("a@x.test", "Bienvenue", "bienvenue", {"nom": "<Zoé & Cie>"})
    m := at.outbox(app)[0]
    assert_eq(m.text, "Bonjour <Zoé & Cie> ! Lien : https://blog.test/compte (Blog)")    # texte : sans échappement
    assert_eq(m.html, "<p>Bonjour &lt;Zoé &amp; Cie&gt;</p>")                         # HTML : échappé
    assert_eq(at.links(m.text), ["https://blog.test/compte"])
    await app.mail().send_template("a@x.test", "Texte", "texte_seul")
    assert_eq(at.outbox(app)[1].html, null)
    try:
        await app.mail().send_template("a@x.test", "?", "absent")
        assert_true(false, "gabarit absent accepté")
    catch e:
        assert_contains(e.message, "emails/absent")

async func test_liens_absolus():
    for debug in [false, true]:
        app := app_avec({"url": "memory"}, {"debug": debug})
        app.get("/x", (req) => mail.absolute_url(req, "/reinitialisation/abc"))
        r := await at.Client(app, {"Host": "attaquant.test"}).get("/x")
        if debug:
            assert_eq(r.text(), "http://attaquant.test/reinitialisation/abc")
        else:
            assert_eq(r.status, 500)                  # production sans site_url : jamais l'en-tête Host
    app := app_avec({"url": "memory"}, {"site_url": "https://blog.test"})
    app.get("/x", (req) => mail.absolute_url(req, "/y"))
    assert_eq((await at.Client(app, {"Host": "attaquant.test"}).get("/x")).text(), "https://blog.test/y")

# ---------------------------------------------------------------- SMTP de bout en bout

# Serveur SMTP de test (une session) : STARTTLS si tls, AUTH PLAIN, rend ce qu'il a reçu.
class Ligne:
    func init(sock):
        self.sock = sock
        self.buf = ""

    func line():
        while not s.contains(self.buf, "\r\n"):
            d := self.sock.recv(65536, 10.0)
            if d == "":
                return null
            self.buf = self.buf + d
        i := s.find(self.buf, "\r\n")
        l := s.slice(self.buf, 0, i)
        self.buf = s.slice(self.buf, i + 2, len(self.buf))
        return l

    func send(t):
        self.sock.send(t + "\r\n", 10.0)

func serveur(port, avec_tls):
    lst := tcp.listen("127.0.0.1", port)
    c := lst.accept(10.0)
    lst.close()
    io_ := Ligne(c.socket)
    recu := {"commandes": [], "auth": null, "data": null, "tls": false}
    io_.send("220 test ESMTP")
    while true:
        l := io_.line()
        if l == null:
            break
        append(recu["commandes"], s.slice(l, 0, 4))
        v := s.upper(s.slice(l, 0, 4))
        if v == "EHLO":
            if avec_tls and not recu["tls"]:
                io_.send("250-test")
                io_.send("250-STARTTLS")
                io_.send("250 8BITMIME")
            else:
                io_.send("250-test")
                io_.send("250-AUTH PLAIN")
                io_.send("250 8BITMIME")
        elif v == "STAR":
            io_.send("220 allez-y")
            io_ = Ligne(tls.wrap_server(c.socket, CERT, CLE, null, 10.0))
            recu["tls"] = true
        elif v == "AUTH":
            recu["auth"] = enc.base64_decode(s.slice(l, 11, len(l)))
            io_.send("235 ok")
        elif v == "MAIL":
            io_.send("250 ok")
        elif v == "RCPT":
            io_.send("550 inconnu" if s.contains(l, "inconnu@") else "250 ok")
        elif v == "DATA":
            io_.send("354 fin par .")
            corps := ""
            while true:
                d := io_.line()
                if d == null or d == ".":
                    break
                corps = corps + d + "\n"
            recu["data"] = corps
            io_.send("250 reçu")
        elif v == "QUIT":
            io_.send("221 au revoir")
            break
        else:
            io_.send("500 ?")
    c.close()
    return recu

async func envoi_smtp(avec_tls, url_extra, a):
    port := nu.free_port("127.0.0.1")
    t := thread.spawn(serveur, [port, avec_tls])
    time.sleep(0.3)
    app := app_avec({"url": "smtp://alice:secret@127.0.0.1:" + str(port) + url_extra, "from": "noreply@blog.test", "ca_file": CERT})
    err := null
    try:
        await app.mail().send(a, "Par SMTP", "Ligne 1\n.point en tête\nfin")
    catch e:
        err = e.message
    r := t.join(15.0)
    return [r, err]

async func test_smtp_starttls_et_authentification():
    x := await envoi_smtp(true, "", ["bob@x.test", "inconnu@x.test"])
    r := x[0]
    assert_eq(x[1], null)
    assert_true(r["tls"], "STARTTLS négocié")
    assert_eq(r["auth"], "\u0000alice\u0000secret")
    assert_contains(r["data"], "Subject: Par SMTP")
    assert_contains(r["data"], "\n..point en t")           # transparence des points (RFC 5321, 4.5.2)
    assert_eq(r["commandes"][0:2], ["EHLO", "STAR"])

async func test_smtp_refuse_d_authentifier_en_clair():
    x := await envoi_smtp(false, "?starttls=false", ["bob@x.test"])
    assert_true(x[1] != null and s.contains(x[1], "non chiffrée"), "authentification en clair refusée : " + str(x[1]))
    assert_eq(x[0]["auth"], null)
    assert_eq(x[0]["data"], null)

# ---------------------------------------------------------------- jetons

func test_jeton_de_reinitialisation():
    h := "pbkdf2_sha256$1000$sel$empreinte"
    j := auth.reset_token(SECRET, 42, h)
    assert_eq(auth.reset_token_user(SECRET, j), 42)
    assert_true(auth.check_reset_token(SECRET, j, h))
    assert_true(not auth.check_reset_token(SECRET, j, "pbkdf2_sha256$1000$sel$nouveau"), "mot de passe changé : jeton usé")
    assert_eq(auth.reset_token_user("une-autre-cle-secrete-assez-longue", j), null)
    assert_eq(auth.reset_token_user(SECRET, j + "x"), null)
    assert_eq(auth.reset_token_user(SECRET, "abc"), null)
    assert_eq(auth.reset_token_user(SECRET, null), null)
    vieux := auth.reset_token(SECRET, 42, h, 3600, time.time() - 7200)
    assert_eq(auth.reset_token_user(SECRET, vieux), null)          # expiré
    c := auth.confirm_token(SECRET, 42, "Alice@X.test")
    assert_eq(auth.read_confirm_token(SECRET, c), {"id": 42, "email": "alice@x.test"})
    assert_eq(auth.reset_token_user(SECRET, c), null)              # usage différent
    assert_eq(auth.read_confirm_token(SECRET, j), null)
    assert_raises(() => auth.reset_token("courte", 1, h))

# ---------------------------------------------------------------- migration : colonne ajoutée

async func test_colonne_ajoutee():
    if not ("sqlite" in dbm.backends()):
        print("  (pas de SQLite ici : exécutable natif)")
        return
    v1 := orm.table("gens", {"id": orm.pk(), "nom": orm.text(40)})
    v2 := orm.table("gens", {"id": orm.pk(), "nom": orm.text(40), "courriel": orm.text(254, true), "confirme": orm.boolean(false)})
    migs := [orm.migration(1, "gens", [v2]), orm.migration(2, "courriel", [orm.add_column(v2, "courriel"), orm.add_column(v2, "confirme"), orm.index("gens_courriel", "gens", ["courriel"], true)])]
    # base existante (créée avant la colonne) puis base neuve (CREATE TABLE l'a déjà) : les deux arrivent au même schéma
    ancienne := alweb.database("sqlite::memory:")
    await orm.migrate(ancienne, [orm.migration(1, "gens", [v1])])
    await v1.insert(ancienne, {"nom": "alice"})
    assert_eq(await orm.migrate(ancienne, migs), [2])
    neuve := alweb.database("sqlite::memory:")
    assert_eq(await orm.migrate(neuve, migs), [1, 2])
    for db in [ancienne, neuve]:
        id := await v2.insert(db, {"nom": "bob", "courriel": "bob@x.test"})
        b := await v2.get(db, id)
        assert_eq([b["courriel"], b["confirme"]], ["bob@x.test", false])
        try:
            await v2.insert(db, {"nom": "bob2", "courriel": "bob@x.test"})
            assert_true(false, "adresse en double acceptée")
        catch e:
            assert_true(true)
        await db.close()
    assert_raises(() => orm.add_column(v2, "absente"))
    assert_raises(() => orm.add_column(orm.table("t", {"id": orm.pk(), "n": orm.integer()}), "n"))   # NOT NULL sans défaut
