# La commande `alweb` (alweb.cli) : modèle de projet, réglages, déploiement, et un parcours complet sur un projet
# généré (dépendances installées, tests du projet, routes, migrations) dans build/test_cli/.
use os
use io
use json
use string as s
use alweb.cli as cli
from testing use assert_eq, assert_true, assert_false, assert_contains, assert_raises

HOME := os.absolute("alweb")

func dossier_essai(nom):
    d := os.join(os.join(os.join(os.cwd(), "build"), "test_cli"), nom)
    if os.exists(d):
        os.rmdir(d, true)
    return d

func lire(d, rel):
    return io.read_file(os.join(d, rel))

func test_substitution_et_noms():
    assert_eq(cli.render("{{nom}} / {{Nom}} / {{ app_name }}", {"nom": "blog", "Nom": "Blog"}), "blog / Blog / {{ app_name }}")
    assert_true(cli.is_valid_name("mon_blog2"))
    assert_false(cli.is_valid_name("2blog"))
    assert_false(cli.is_valid_name("Blog"))
    assert_false(cli.is_valid_name("mon-blog"))
    assert_eq(cli.display_name("mon_blog"), "Mon blog")
    assert_eq(len(cli.make_secret(16)), 32)
    assert_true(cli.make_secret() != cli.make_secret())

func test_chemins_relatifs():
    if os.platform() == "windows":
        assert_eq(cli.relative_path("C:\\a\\b", "C:\\a\\c\\d"), "../c/d")
        assert_eq(cli.relative_path("C:\\a", "D:\\a"), null)
    else:
        assert_eq(cli.relative_path("/srv/a/b", "/srv/a/c/d"), "../c/d")
        assert_eq(cli.relative_path("/srv/a", "/srv/a"), ".")
        assert_eq(cli.relative_path("/srv/a", "/opt/x"), "../../opt/x")
    assert_eq(cli.dependency_line("/x", null), "alweb = \"^" + cli.VERSION + "\"")
    assert_eq(cli.dependency_line("/x", null, ">=0.8"), "alweb = \">=0.8\"")

func test_nouveau_projet_par_domaine():
    for dom in ["ecommerce", "blog", "portfolio", "business"]:
        nom := "site_" + dom
        d := dossier_essai(nom)
        res := cli.new_project(nom, {"dir": d, "home": HOME, "alweb": HOME, "domaine": dom})
        slug := "site-" + dom
        assert_eq([res["domain"], res["theme"]], [dom, slug])
        for f in ["application.al", "modeles.al", "tests/test_application.al", "templates/LISEZMOI.md", "README.md"]:
            assert_true(f in res["files"])
        assert_false(os.exists(os.join(d, "templates", "index.html")))               # le thème fournit les pages
        assert_false(os.exists(os.join(d, "templates", "base.html")))
        assert_false(os.exists(os.join(d, ".alweb", "theme-" + slug)))               # dossier de travail retiré
        lock := json.parse(lire(d, "alweb.lock"))
        assert_eq(lock["active"], slug)
        assert_eq(json.parse(lire(d, "themes/" + slug + "/alweb-theme.json"))["category"], dom)
        app := lire(d, "application.al")
        assert_contains(app, "themes.setup(app, null, {\"root\": dossier})")
        assert_eq(cli.wire_theme(d)[0], "deja")                                     # déjà branché
        for f in res["files"]:
            assert_false(s.ends_with(f, ".tpl"))
            if not s.ends_with(f, ".html") and not s.ends_with(f, ".svg"):
                assert_false(s.contains(lire(d, f), "{{"))
    assert_raises(() => cli.new_project("site_x", {"dir": dossier_essai("site_x"), "home": HOME, "domaine": "restaurant"}))
    assert_eq(cli.project_theme_slug("ma_boutique"), "ma-boutique")
    assert_eq(cli.project_theme_slug("a"), "theme-a")

func test_nouveau_projet():
    d := dossier_essai("journal")
    res := cli.new_project("journal", {"dir": d, "home": HOME, "alweb": HOME})
    for f in ["alex.toml", "main.al", "application.al", "modeles.al", "config/base.json", "config/dev.json", "config/test.json",
              "config/prod.json", "templates/base.html", "templates/index.html", "static/style.css", "tests/test_application.al",
              "README.md", ".gitignore"]:
        assert_true(f in res["files"])
        assert_true(os.isfile(os.join(d, f)))
    for f in res["files"]:
        assert_false(s.ends_with(f, ".tpl"))
        if not s.ends_with(f, ".html"):
            assert_false(s.contains(lire(d, f), "{{"))
    toml := lire(d, "alex.toml")
    assert_contains(toml, "name = \"journal\"")
    assert_contains(toml, "alweb = { path = \"")
    assert_contains(lire(d, "templates/base.html"), "{{ app_name }}")                 # gabarits HTML intacts
    dev := json.parse(lire(d, "config/dev.json"))
    tst := json.parse(lire(d, "config/test.json"))
    assert_eq(len(dev["secret_key"]), 48)
    assert_true(dev["secret_key"] != tst["secret_key"])
    assert_eq(json.parse(lire(d, "config/base.json"))["database"]["url"], "sqlite:journal.db")
    # Refus : dossier non vide, nom invalide, nom réservé.
    assert_raises(() => cli.new_project("journal", {"dir": d, "home": HOME}))
    assert_raises(() => cli.new_project("Journal", {"dir": dossier_essai("x"), "home": HOME}))
    assert_raises(() => cli.new_project("alweb", {"dir": dossier_essai("y"), "home": HOME}))
    # Version du registre plutôt qu'un dossier.
    r := cli.new_project("carnet", {"dir": dossier_essai("carnet"), "home": HOME, "registry": true})
    assert_eq(r["dependency"], "alweb = \"^" + cli.VERSION + "\"")

func test_nouveau_projet_alexdb():
    assert_eq(cli.database_url("x"), "sqlite:x.db")
    assert_eq(cli.database_url("x", "alexdb"), "alexdb://admin:changez-moi@127.0.0.1:5442/x")
    assert_eq(cli.database_url("x", "postgres://u@h/b"), "postgres://u@h/b")
    assert_raises(() => cli.database_url("x", "mysql://h/b"))
    d := dossier_essai("registre")
    r := cli.new_project("registre", {"dir": d, "home": HOME, "alweb": HOME, "database": "alexdb://app:m\"p@10.0.0.2:5442/reg"})
    base := json.parse(lire(d, "config/base.json"))["database"]
    assert_eq(base["url"], "alexdb://app:m\"p@10.0.0.2:5442/reg")
    assert_eq(base["create"], true)
    assert_eq(r["database"], base["url"])
    assert_contains(lire(d, "application.al"), "axdb.ensure_database(url)")
    assert_eq(json.parse(lire(d, "config/test.json"))["database"]["url"], "memory:")

func test_reglages_du_projet():
    d := dossier_essai("reglages")
    cli.new_project("reglages", {"dir": d, "home": HOME, "alweb": HOME})
    st := cli.settings(d)
    assert_eq(st["name"], "reglages")
    assert_eq(st["entry"], "main.al")
    assert_eq(st["app"], "application")
    io.write_file(os.join(d, "alweb.json"), "{\"app\": \"site.appli\", \"migrations\": \"site.schema.MIGRATIONS\"}")
    st = cli.settings(d)
    assert_eq(st["app"], "site.appli")
    assert_eq(st["migrations"], "site.schema.MIGRATIONS")
    assert_contains(cli.routes_script(st), "use site.appli as _projet")
    assert_contains(cli.migrate_script(st, "up"), "use site.schema as _m")
    assert_contains(cli.migrate_script(st, "up"), "_migs := _m.MIGRATIONS")
    io.write_file(os.join(d, "alweb.json"), "{\"inconnue\": 1}")
    assert_raises(() => cli.settings(d))
    io.write_file(os.join(d, "alweb.json"), "{\"app\": \"x; os.exit(1)\"}")         # injecté dans un script : refusé
    assert_raises(() => cli.settings(d))
    io.write_file(os.join(d, "alweb.json"), "{\"migrations\": \"MIGRATIONS\"}")
    assert_raises(() => cli.settings(d))
    assert_eq(cli.find_project(os.join(d, "templates")), d)

func test_deploiement():
    d := dossier_essai("vitrine")
    cli.new_project("vitrine", {"dir": d, "home": HOME, "alweb": HOME})
    w := cli.deploy(d, ["tout"], {"domaine": "vitrine.example.com", "port": 9000, "dossier": "/opt/vitrine"}, HOME)
    for f in ["deploy/vitrine.service", "deploy/env.exemple", "deploy/Caddyfile", "deploy/vitrine.conf", "deploy/Dockerfile", "deploy/compose.yaml", ".dockerignore"]:
        assert_true(f in w)
        assert_true(os.isfile(os.join(d, f)))
    assert_false(os.exists(os.join(d, "deploy/.dockerignore")))
    unit := lire(d, "deploy/vitrine.service")
    assert_contains(unit, "WorkingDirectory=/opt/vitrine")
    assert_contains(unit, "ExecStart=/usr/local/bin/alex run /opt/vitrine/main.al")
    assert_contains(unit, "Environment=ALWEB_SERVER__PORT=9000")
    assert_contains(lire(d, "deploy/Caddyfile"), "vitrine.example.com {")
    assert_contains(lire(d, "deploy/Caddyfile"), "reverse_proxy 127.0.0.1:9000")
    assert_contains(lire(d, "deploy/vitrine.conf"), "server 127.0.0.1:9000;")
    assert_contains(lire(d, "deploy/Dockerfile"), "EXPOSE 9000")
    assert_contains(lire(d, "deploy/compose.yaml"), "--from vitrine.example.com --to app:9000")
    for f in w:
        assert_false(s.contains(lire(d, f), "{{nom}}"))
        assert_false(s.contains(lire(d, f), "{{port}}"))
    # Une seconde fois : refus sans force, accepté avec.
    assert_raises(() => cli.deploy(d, ["systemd"], null, HOME))
    assert_eq(len(cli.deploy(d, ["systemd"], {"force": true}, HOME)), 2)
    assert_raises(() => cli.deploy(d, ["heroku"], null, HOME))

func test_tableau_des_routes():
    t := cli.format_routes([{"methods": ["GET"], "pattern": "/", "name": "accueil"}, {"methods": ["GET", "POST"], "pattern": "/api/x", "name": null}])
    lignes := s.split(t, "\n")
    assert_eq(len(lignes), 3)
    assert_eq(lignes[1], "GET       /       accueil")
    assert_eq(lignes[2], "GET,POST  /api/x  ")

# Bout en bout : le projet généré installe ses dépendances, passe ses propres tests, décrit ses routes et migre
# sa base (processus `alexc` fils, comme la commande).
func test_projet_genere_de_bout_en_bout():
    d := dossier_essai("livre")
    cli.new_project("livre", {"dir": d, "home": HOME, "alweb": HOME})
    r := cli.capture_alex(["pkg", "install"], null, d)
    assert_eq(r["code"], 0)
    assert_true(os.isfile(os.join(d, "alex_packages/alweb/alweb.al")))
    r = cli.capture_alex(["test", "tests"], {"ALWEB_ENV": "test"}, d)
    assert_eq(r["code"], 0)
    assert_contains(r["stdout"], "5 réussi(s)")
    routes := cli.project_routes(d)
    assert_eq(len(routes), 5)
    assert_eq(routes[0]["pattern"], "/")
    assert_eq(routes[0]["name"], "accueil")
    st := cli.settings(d)
    p := cli._write_script(d, "migrate.al", cli.migrate_script(st, "up"))
    r = cli.capture_alex(["run", p], null, d)
    assert_eq(r["code"], 0)
    assert_contains(r["stdout"], "appliquée : 1  messages")
    assert_true(os.isfile(os.join(d, "livre.db")))
    p = cli._write_script(d, "migrate.al", cli.migrate_script(st, "status"))
    r = cli.capture_alex(["run", p], null, d)
    assert_contains(r["stdout"], "[x] 1  messages")
    assert_contains(r["stdout"], cli.MARQUE + "1/1")

# Le blog du tutoriel (docs/tutoriel/blog) : ses propres tests tournent avec `alexc test` ; ici, ce que la commande
# en voit (routes nommées citées par le tutoriel, migrations).
func test_projet_du_tutoriel():
    d := os.absolute("docs/tutoriel/blog")
    st := cli.settings(d)
    assert_eq(st["name"], "blog")
    noms := {}
    for r in cli.project_routes(d):
        if r["name"] != null:
            noms[r["name"]] = r["pattern"]
    assert_eq(noms["accueil"], "/")
    assert_eq(noms["article"], "/articles/{id:int}")
    assert_eq(noms["modifier"], "/articles/{id:int}/modifier")
    assert_eq(noms["connexion"], "/connexion")
    assert_eq(noms["sante"], "/sante")
    p := cli._write_script(d, "migrate.al", cli.migrate_script(st, "status"))
    r := cli.capture_alex(["run", p], {"ALWEB_ENV": "test"}, d)
    assert_contains(r["stdout"], "[ ] 2  index")
