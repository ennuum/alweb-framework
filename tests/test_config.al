# Configuration : superposition des fichiers, profils, variables d'environnement converties, validation,
# secrets masqués, branchement sur l'application.
use os
use io
use json
use alweb
use alweb.config as conf
use alweb.testing as at
use serialization.schema as sch
from testing use assert_eq, assert_true, assert_null, assert_contains

func dossier():
    d := os.join(os.tmp_dir(), "alweb_conf_" + str(os.pid()))
    os.mkdir_all(d)
    io.write_file(os.join(d, "base.json"), json.stringify({"debug": false, "nom": "notes", "database": {"url": "sqlite:app.db", "pool": 4}, "secret_key": "", "tags": ["a"], "ratio": 0.5}))
    io.write_file(os.join(d, "dev.json"), json.stringify({"debug": true}))
    io.write_file(os.join(d, "test.json"), json.stringify({"database": {"url": "memory:"}}))
    io.write_file(os.join(d, "local.json"), json.stringify({"database": {"pool": 2}}))
    return d

func test_superposition_et_profils():
    d := dossier()
    dev := conf.load(d, null, "ALWEB", {})
    assert_eq(dev.profile, "dev")
    assert_eq(dev.get("debug"), true)
    assert_eq(dev.get("database.url"), "sqlite:app.db")
    assert_eq(dev.get("database.pool"), 2)              # local.json
    assert_eq(len(dev.sources), 3)
    t := conf.load(d, null, "ALWEB", {"ALWEB_ENV": "test"})
    assert_eq(t.profile, "test")
    assert_eq(t.get("database.url"), "memory:")
    assert_eq(t.get("database.pool"), 4)                # local.json ignoré en test
    assert_eq(t.get("debug"), false)
    assert_eq(t.get("absent.chemin", "défaut"), "défaut")
    assert_true(t.is_test())
    os.rmdir(d, true)

func test_variables_d_environnement_converties():
    d := dossier()
    env := {"ALWEB_ENV": "prod", "ALWEB_DEBUG": "oui", "ALWEB_DATABASE__POOL": "16", "ALWEB_DATABASE__URL": "sqlite:/srv/app.db", "ALWEB_RATIO": "0.75", "ALWEB_TAGS": "[\"x\", \"y\"]", "ALWEB_NOUVEAU__PORT": "8080", "ALWEB_NOUVEAU__NOM": "texte", "AUTRE_VAR": "ignorée"}
    c := conf.load(d, null, "ALWEB", env)
    assert_eq(c.profile, "prod")
    assert_eq(c.get("debug"), true)
    assert_eq(c.get("database.pool"), 16)
    assert_eq(c.get("database.url"), "sqlite:/srv/app.db")
    assert_eq(c.get("ratio"), 0.75)
    assert_eq(c.get("tags"), ["x", "y"])
    assert_eq(c.get("nouveau.port"), 8080)
    assert_eq(c.get("nouveau.nom"), "texte")
    assert_contains(str(c.sources), "$ALWEB_DATABASE__POOL")
    try:
        conf.load(d, null, "ALWEB", {"ALWEB_DATABASE__POOL": "beaucoup"})
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "ConfigError")
    os.rmdir(d, true)

func test_require_et_validation():
    d := dossier()
    c := conf.load(d, "prod", "ALWEB", {})
    try:
        c.require("secret_key")
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "ConfigError")
        assert_contains(e.message, "secret_key")
    assert_eq(conf.load(d, "prod", "ALWEB", {"ALWEB_SECRET_KEY": "s3cr3t"}).require("secret_key"), "s3cr3t")
    schema := sch.object({"nom": sch.string(1, 20), "database": sch.object({"url": sch.string(), "pool": sch.integer(1, 64)}, ["url"])}, ["nom", "database"])
    assert_eq(conf.load(d, "prod", "ALWEB", {}, schema).get("database.pool"), 2)
    try:
        conf.load(d, "prod", "ALWEB", {"ALWEB_DATABASE__POOL": "500"}, schema)
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "ConfigError")
        assert_contains(e.message, "pool")
    os.rmdir(d, true)

func test_json_invalide():
    d := os.join(os.tmp_dir(), "alweb_conf_bad_" + str(os.pid()))
    os.mkdir_all(d)
    io.write_file(os.join(d, "base.json"), "{pas du json")
    try:
        conf.load(d, "dev", "ALWEB", {})
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "ConfigError")
        assert_contains(e.message, "base.json")
    os.rmdir(d, true)

func test_secrets_masques():
    c := conf.from_dict({"secret_key": "x", "database": {"password": "p", "url": "u"}, "api-key": "k", "cycle": 3, "mot_de_passe": "m", "jetons": {"a": 1}})
    m := c.safe_dict()
    assert_eq(m["secret_key"], "***")
    assert_eq(m["database"], {"password": "***", "url": "u"})
    assert_eq(m["api-key"], "***")
    assert_eq(m["cycle"], 3)
    assert_eq(m["mot_de_passe"], "***")
    assert_eq(m["jetons"], {"a": 1})

async func test_branchement_sur_l_application():
    app := alweb.App("conf")
    app.configure(conf.from_dict({"debug": true, "salut": "Bonjour"}))
    app.get("/", (req) => req.state["app"].config.get("salut"))
    app.get("/boom", (req) => 1 / 0)
    c := at.Client(app)
    assert_eq((await c.get("/")).text(), "Bonjour")
    assert_contains((await c.get("/boom")).text(), "ZeroDivisionError")   # debug repris de la configuration

# server.trusted_proxies : transmis au serveur (un seul processus comme ouvriers), liste ou valeur seule ; absent,
# le serveur ne croit aucun en-tête X-Forwarded-For.
func test_mandataires_de_confiance():
    app := alweb.App("m")
    app.configure(conf.from_dict({"server": {"trusted_proxies": ["127.0.0.1", "10."]}}))
    assert_eq(app.server("127.0.0.1", 0).config.trusted_proxies, ["127.0.0.1", "10."])
    seul := alweb.App("s")
    seul.configure(conf.from_dict({"server": {"trusted_proxies": "*"}}))
    assert_eq(seul.server("127.0.0.1", 0).config.trusted_proxies, ["*"])
    aucun := alweb.App("a")
    aucun.configure(conf.from_dict({}))
    assert_null(aucun.server("127.0.0.1", 0).config.trusted_proxies)
