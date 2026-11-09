# Base locale alexdb+local: (alweb.alexdb_local) : serveur ALEX DB embarqué, hébergé par le maître et partagé par
# les ouvriers ; migrations lancées ensemble par plusieurs ouvriers ; arrêt propre ; données gardées.
#   ALWEB_ALEXDB_HOME=/chemin/vers/AlexDB alexc run tests/test_alexdb_local.al
# Sans ALWEB_ALEXDB_HOME, seules les vérifications sans serveur tournent (le module alweb.alexdb_local importe le
# projet AlexDB : il est compilé dans un projet temporaire dont alex.toml déclare AlexDB dans ses sources).
use os
use io
use time
use json
use process as proc
use process.process_signal as psig
use network.utils as nu
use web.client as http
use alweb.alexdb as axdb
use thread
from core use len, to_int
from collections use append

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

func raises(f, morceau):
    try:
        f()
    catch e:
        expect(_contains(e.message, morceau), "message inattendu : " + e.message)
        return
    raise("AssertionError", "erreur attendue (" + morceau + ")")

func _contains(t, m):
    i := 0
    while i + len(m) <= len(t):
        if t[i:i + len(m)] == m:
            return true
        i += 1
    return false

APP := """use os
use io
use alweb
use alweb.alexdb_local
use alweb.orm as orm
use web.server.workers as workers
from core use to_int

COMPTEUR := orm.table("compteur", {"id": orm.pk(), "n": orm.integer()})
MIGRATIONS := [orm.migration(1, "compteur", [COMPTEUR]), orm.migration(2, "index", [orm.index("compteur_n", "compteur", ["n"])])]

async func ouvrir(app):
    db := alweb.database(app.config.require("database.url"))
    await orm.migrate(db, MIGRATIONS)
    return db

if os.getenv("ALWEB_TEST_ALEX") != null:            # lanceur des ouvriers imposé par le test
    os.setenv("ALEX_EXE", os.getenv("ALWEB_TEST_ALEX"))
app := alweb.App("partage")
app.configure(alweb.load_config("config"))
app.provide("db", ouvrir, "app")

@app.get("/incr", {"deps": ["db"]})
async func incr(req):
    db := req.deps["db"]
    await COMPTEUR.insert(db, {"n": 1})
    return {"pid": os.pid(), "lignes": await COMPTEUR.query().count(db)}

if os.getenv("RELIRE") != null:
    db := alweb.database(app.config.require("database.url"))
    print("lignes=" + str(await db.scalar("SELECT COUNT(*) FROM compteur")) + " migrations=" + str(await db.scalar("SELECT COUNT(*) FROM alweb_migrations")))
else:
    if not workers.is_worker():
        io.write_file("maitre.pid", str(os.pid()))        # `alex run` lance le programme dans un processus fils
    await app.run_workers("127.0.0.1", to_int(os.getenv("PORT")), 2)
"""

# ---------------------------------------------------------------- sans serveur

func sans_serveur():
    p := axdb.local_parts("alexdb+local:donnees/x?base=blog")
    expect(p[1] == "blog", "base lue : " + str(p))
    expect(p[0] == os.normalize(os.absolute("donnees/x")), "dossier absolu : " + str(p))
    expect(axdb.local_parts("alexdb+local:d")[1] == "app", "base par défaut")
    expect(axdb.is_local("alexdb+local:d") and not axdb.is_local("alexdb://u:p@h:1/b"), "is_local")
    raises(() => axdb.local_parts("alexdb+local:"), "dossier attendu")
    raises(() => axdb.local_parts("alexdb+local:d?base=alexdb"), "base d'administration")
    raises(() => axdb.local_parts("alexdb+local:d?base=a-b"), "nom de base invalide")
    if not axdb.local_available():
        raises(() => axdb.resolve_local("alexdb+local:d"), "use alweb.alexdb_local")
    expect(axdb.master_setup("sqlite:x.db") == [[], {}], "master_setup sans base locale")
    expect(axdb.master_setup(null) == [[], {}], "master_setup sans configuration")
    print("alexdb+local (sans serveur) : OK")

# ---------------------------------------------------------------- maître et ouvriers

# Lanceur ALEX : ALWEB_TEST_ALEX, sinon ALEX_EXE (fixé par alexc run), sinon alexc du PATH.
func alex():
    for v in ["ALWEB_TEST_ALEX", "ALEX_EXE"]:
        x := os.getenv(v)
        if x != null and x != "":
            return x
    return proc.which("alexc")

func lancer(dossier, env):
    return proc.spawn(alex(), ["run", "app.al", "--"], dossier, env)

func avec_serveur(home):
    racine := os.normalize(os.absolute("."))
    d := os.join(os.tmp_dir(), "alweb-local-" + str(os.pid()))
    if os.exists(d):
        os.rmdir(d, true)
    os.mkdir_all(os.join(d, "config"))
    io.write_file(os.join(d, "alex.toml"), "[package]\nname = \"essai_local\"\nversion = \"0.1.0\"\nsources = [\"" + os.normalize(os.absolute(home)) + "\", \"" + racine + "\"]\n")
    io.write_file(os.join(d, "config", "base.json"), json.stringify({"database": {"url": "alexdb+local:donnees"}}))
    io.write_file(os.join(d, "app.al"), APP)
    port := nu.free_port("127.0.0.1")
    env := {"PORT": str(port), "ALEX_QUIET_RUN": "1"}
    if os.getenv("ALWEB_TEST_ALEX") != null:
        env["ALWEB_TEST_ALEX"] = os.getenv("ALWEB_TEST_ALEX")
    p := lancer(d, env)
    try:
        url := "http://127.0.0.1:" + str(port) + "/incr"
        premier := null
        t0 := time.monotonic()
        while premier == null and time.monotonic() - t0 < 300.0:
            expect(p.running(), "le maître s'est arrêté : " + str(p.poll()))
            try:
                premier = http.get(url, headers={"Connection": "close"}).json()
            catch e:
                time.sleep(0.5)
        expect(premier != null, "l'application ne répond pas")
        time.sleep(5.0)                                  # les deux ouvriers ont fini de démarrer
        pids := []
        vus := []
        i := 0
        while i < 30:
            r := http.get(url, headers={"Connection": "close"}).json()
            if not (r["pid"] in pids):
                append(pids, r["pid"])
            append(vus, r["lignes"])
            i += 1
        expect(len(pids) == 2, "deux ouvriers attendus, vus : " + str(pids))
        k := 1
        while k < len(vus):
            expect(vus[k] > vus[k - 1], "compteur commun croissant : " + str(vus))
            k += 1
        expect(vus[len(vus) - 1] == 31, "31 lignes dans la base commune : " + str(vus))
        maitre := to_int(io.read_file(os.join(d, "maitre.pid")))
        psig.terminate(maitre)
        expect(psig.wait_exit(maitre, 30.0), "arrêt du maître par TERM")
        t1 := time.monotonic()
        while p.running() and time.monotonic() - t1 < 10.0:
            time.sleep(0.2)
        journal := io.read_file(os.join(d, "donnees", "alexdb.log"))
        expect(_contains(journal, " arrêt"), "serveur ALEX DB arrêté proprement")
        expect(not os.exists(os.join(d, "donnees", "alexdb.pid")), "fichier pid retiré")
        r2 := proc.run(alex(), ["run", "app.al", "--"], null, 300.0, d, {"RELIRE": "1", "ALEX_QUIET_RUN": "1"})
        expect(_contains(r2.stdout, "lignes=31 migrations=2"), "données gardées, migrations appliquées une fois : " + r2.stdout + r2.stderr)
        print("alexdb+local (maître et deux ouvriers) : OK")
    finally:
        if p.running():
            p.kill("KILL")
        try:
            os.rmdir(d, true)
        catch e:
            ignored := e

if thread.is_main():
    sans_serveur()
    home := os.getenv("ALWEB_ALEXDB_HOME")
    if home == null or home == "":
        print("alexdb+local (maître et ouvriers) : ignoré (ALWEB_ALEXDB_HOME non défini)")
    else:
        avec_serveur(home)
