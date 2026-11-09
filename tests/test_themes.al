# Thèmes (alweb.themes) : manifeste et versions, paramètres typés, validation (fichiers interdits, liens, SVG
# piégé, gabarits et références), archives .alwt (construction reproductible, archives piégées refusées),
# installation dans un projet (alweb.lock, activation, mise à jour, retour arrière, dépendances, compatibilité),
# intégration à une application (pages du thème, remplacement par l'application, composants, ressources
# versionnées, paramètres, feuille CSS), aperçu et commandes.
#   alexc test tests/test_themes.al
use os
use io
use json
use string as s
use alweb
use alweb.themes as themes
use alweb.themes.manifest as manifest
use alweb.themes.customization as custom
use alweb.themes.validator as validator
use alweb.themes.package as package
use alweb.themes.registry as registry
use alweb.templates as tpl
use alweb.config as conf
use alweb.testing as at
use alweb.cli as cli
use office.archive as zip
from testing use assert_eq, assert_true, assert_false, assert_contains, assert_raises
from core use len
from collections use append

const BASE := "build/test_themes"
const MODELE := "alweb/modele-theme"

func neuf(d):
    if os.exists(d):
        os.rmdir(d, true)
    os.mkdir_all(d)
    return d

# Thème « modern-business » créé depuis le modèle dans BASE/<nom>.
func theme(nom="mb", version=null):
    d := os.join(BASE, nom)
    if os.exists(d):
        os.rmdir(d, true)
    cli.create_theme("modern-business", {"dir": d, "modele": MODELE, "auteur": "Test"})
    if version != null:
        p := os.join(d, "alweb-theme.json")
        m := json.parse(io.read_file(p))
        m["version"] = version
        io.write_file(p, json.stringify(m))
    return d

func erreur(f):
    try:
        f()
    catch e:
        return e.message
    return null

func test_versions():
    assert_eq(manifest.parse_version("1.2.3"), [1, 2, 3, ""])
    assert_eq(manifest.parse_version("1.0.0-beta.2+build.5"), [1, 0, 0, "beta.2"])
    for faux in ["1.2", "01.2.3", "1.2.3.4", "a.b.c", "", "1.2.3-"]:
        assert_eq(manifest.parse_version(faux), null)
    assert_eq([manifest.compare("1.0.0-beta", "1.0.0"), manifest.compare("1.10.0", "1.9.9"), manifest.compare("2.0.0", "2.0.0")], [-1, 1, 0])
    assert_true(manifest.satisfies("0.9.0", ">=0.9.0"))
    assert_true(manifest.satisfies("1.4.2", ">=1.2.0, <2.0.0"))
    assert_false(manifest.satisfies("2.0.0", ">=1.2.0, <2.0.0"))
    assert_eq([manifest.satisfies("1.9.0", "^1.2.0"), manifest.satisfies("2.0.0", "^1.2.0"), manifest.satisfies("0.3.1", "^0.3.0"), manifest.satisfies("0.4.0", "^0.3.0")], [true, false, true, false])
    assert_eq([manifest.satisfies("1.2.9", "~1.2.0"), manifest.satisfies("1.3.0", "~1.2.0"), manifest.satisfies("1.2.0", "1.2.0"), manifest.satisfies("5.0.0", "*")], [true, false, true, true])
    assert_raises(() => manifest.satisfies("1.0.0", ">=deux"))
    assert_eq([manifest.valid_slug("modern-business"), manifest.valid_slug("Modern"), manifest.valid_slug("-x"), manifest.valid_slug("a--b"), manifest.valid_slug("x")], [true, false, false, false, false])
    assert_eq([manifest.safe_path("static/css/a.css"), manifest.safe_path("../x"), manifest.safe_path("/etc"), manifest.safe_path("a//b"), manifest.safe_path("c:x")], [true, false, false, false, false])

func test_manifeste():
    r := manifest.check({"name": "X", "slug": "x-theme", "version": "1.0.0", "framework": "ALWEB", "framework_version": ">=0.9.0", "license": "MIT", "entry": "templates/index.html"})
    assert_eq(r[1], [])
    assert_eq([r[0]["templates"], r[0]["assets"], r[0]["category"], r[0]["responsive"]], ["templates", "static", "other", true])
    r = manifest.check({"name": "", "slug": "X", "version": "1", "framework": "Django", "framework_version": "≥1", "license": "MIT", "entry": "../index.html", "categorie": "x", "category": "jeux", "screenshots": ["/etc/passwd"]})
    t := s.join(" | ", r[1])
    for attendu in ["clé inconnue « categorie »", "name : ne doit pas être vide", "slug :", "version : version sémantique", "framework : « ALWEB »", "framework_version : contrainte", "entry : chemin relatif", "category : catégorie inconnue « jeux »", "screenshots : chemin invalide"]:
        assert_contains(t, attendu)
    assert_contains(manifest.check({"name": "X", "slug": "xx"})[1][0], "champ requis manquant")

func test_parametres():
    schema := json.parse(io.read_file(os.join(MODELE, "config", "theme.json")))
    assert_eq(custom.check_schema(schema), [])
    v := custom.merge(schema, {"couleurs": {"primaire": "#1f6feb"}, "site": {"nom": "Ma société"}})
    assert_eq([v["couleurs"]["primaire"], v["couleurs"]["secondaire"], v["site"]["nom"], v["mise_en_page"]["barre_laterale"]], ["#1f6feb", "#20242b", "Ma société", true])
    assert_eq(custom.get(v, "typographie.taille"), "17px")
    css := custom.css(schema, v)
    assert_contains(css, "--couleurs-primaire: #1f6feb;")
    assert_contains(css, "--mise-en-page-largeur: 1120px;")
    assert_true(not s.contains(css, "barre"))                   # booléens : pas de variable CSS
    m := erreur(() => custom.merge(schema, {"couleurs": {"primaire": "red; } body { display:none"}, "inconnu": 1, "menu": [{"label": "x", "url": "javascript:alert(1)"}], "typographie": {"taille": "16 px"}}))
    for attendu in ["couleurs.primaire : couleur", "inconnu : paramètre inconnu", "menu : liste de liens", "typographie.taille : taille attendue"]:
        assert_contains(m, attendu)
    assert_eq(custom.check_value({"type": "image"}, "media:logos/a.png"), null)
    assert_true(custom.check_value({"type": "image"}, "../../etc/passwd") != null)
    assert_true(custom.check_value({"type": "text"}, "</style><script>") != null)
    assert_eq(custom.check_value({"type": "choice", "options": ["a", "b"]}, "b"), null)
    assert_eq(custom.check_schema({"a": {"type": "color", "default": "bleu"}, "b-c": {"type": "bool", "default": true}, "d": {"type": "inconnu", "default": 1}}), ["a : valeur par défaut : couleur « #rrggbb » attendue", "b-c : nom invalide (lettres, chiffres, _)", "d : type inconnu « inconnu » (color, size, font, text, bool, number, choice, url, image, links)"])

func test_validation():
    d := theme("valide")
    r := validator.validate(d)
    assert_eq(r["errors"], [])
    assert_eq(len(r["files"]), 24)
    assert_eq(r["warnings"], [])
    assert_eq(r["manifest"]["screenshots"], ["preview/accueil.jpg"])
    # fichiers interdits, SVG piégé, lien symbolique, gabarit cassé, référence absente
    io.write_file(os.join(d, "static", "js", "outil.al"), "print(1)")
    io.write_file(os.join(d, "static", "lanceur.sh"), "rm -rf /")
    io.write_file(os.join(d, "static", "images", "x.svg"), "<svg onload=\"alert(1)\"></svg>")
    io.write_file(os.join(d, "static", "notes.docx"), "x")
    io.write_file(os.join(d, "templates", "casse.html"), "{% if x %}sans fin")
    io.write_file(os.join(d, "templates", "orphelin.html"), "{% extends \"absent.html\" %}{% include \"components/absent.html\" %}")
    os.execute("ln -s /etc/passwd " + os.join(d, "static", "lien.txt"))
    t := s.join(" | ", validator.validate(d)["errors"])
    for attendu in ["static/js/outil.al : type de fichier interdit", "static/lanceur.sh : type de fichier interdit", "static/images/x.svg : SVG avec script", "static/notes.docx : extension non permise", "templates/casse.html :", "gabarit « absent.html » introuvable", "gabarit « components/absent.html » introuvable", "static/lien.txt : lien symbolique refusé"]:
        assert_contains(t, attendu)
    assert_raises(() => validator.check(d))
    assert_eq(validator.references("{%- extends 'base.html' -%}{% import \"components/cards.html\" as c %}{% include x %}"), ["base.html", "components/cards.html"])

func test_archives():
    d := theme("archive")
    sortie := neuf(os.join(BASE, "dist"))
    r := package.build(d, sortie)
    assert_eq([os.basename(r["path"]), r["files"]], ["modern-business-0.1.0.alwt", 24])
    assert_eq(package.build(d, sortie)["sha256"], r["sha256"])          # reproductible
    x := neuf(os.join(BASE, "extrait"))
    package.extract(r["path"], x)
    assert_eq(package.tree_sha256(x), package.tree_sha256(d))
    # archives piégées : refusées avant d'écrire quoi que ce soit
    for cas in [["../../evil.html", "x", "chemin refusé"], ["templates/a.al", "x", "type de fichier refusé"], ["templates/../../x.html", "x", "chemin refusé"], ["static\\..\\x.html", "x", "chemin refusé"], ["bin/outil", "x", "type de fichier refusé"]]:
        z := zip.new()
        z.write("alweb-theme.json", "{}")
        z.write(cas[0], cas[1])
        cible := neuf(os.join(BASE, "piege"))
        m := erreur(() => package.extract(s.byte_pack(z.to_bytes()), cible))
        assert_contains(m, cas[2])
        assert_eq(os.list_dir(cible), [])
    z := zip.new()
    z.write("templates/index.html", "x")
    assert_contains(erreur(() => package.extract(s.byte_pack(z.to_bytes()), neuf(os.join(BASE, "piege")))), "alweb-theme.json absent")
    assert_contains(erreur(() => package.extract("pas une archive", neuf(os.join(BASE, "piege")))), "archive illisible")

func test_installation():
    projet := neuf(os.join(BASE, "projet"))
    sortie := neuf(os.join(BASE, "dist2"))
    a1 := package.build(theme("v1", "1.0.0"), sortie)["path"]
    a2 := package.build(theme("v2", "1.1.0"), sortie)["path"]
    reg := registry.Registry(projet)
    assert_eq(reg.list(), [])
    e := reg.install(a1)
    assert_eq([e["version"], reg.active()], ["1.0.0", "modern-business"])           # premier installé : actif
    assert_true(os.isfile(os.join(projet, "themes", "modern-business", "templates", "index.html")))
    lock := json.parse(io.read_file(os.join(projet, "alweb.lock")))
    assert_eq([lock["active"], lock["themes"]["modern-business"]["version"], len(lock["themes"]["modern-business"]["archive_sha256"])], ["modern-business", "1.0.0", 64])
    assert_contains(erreur(() => reg.install(a1)), "déjà installé")
    # mise à jour : l'ancienne version est gardée, retour arrière possible
    e = reg.install(a2)
    assert_eq([e["version"], e["previous"]], ["1.1.0", "1.0.0"])
    assert_true(os.isdir(os.join(projet, "themes", ".versions", "modern-business-1.0.0")))
    assert_eq(reg.rollback("modern-business"), "1.0.0")
    assert_eq(reg.info("modern-business")["manifest"]["version"], "1.0.0")
    assert_false(reg.info("modern-business")["modified"])
    io.write_file(os.join(projet, "themes", "modern-business", "templates", "index.html"), "modifié")
    assert_true(reg.info("modern-business")["modified"])
    # désactivation, activation, retrait
    assert_eq(reg.deactivate(), "modern-business")
    assert_eq(reg.active(), null)
    reg.activate("modern-business")
    assert_contains(erreur(() => reg.activate("autre")), "non installé")
    # compatibilité et dépendances
    t3 := theme("incompatible", "2.0.0")
    m := json.parse(io.read_file(os.join(t3, "alweb-theme.json")))
    m["framework_version"] = ">=9.0.0"
    io.write_file(os.join(t3, "alweb-theme.json"), json.stringify(m))
    assert_contains(erreur(() => reg.install(t3)), "le thème demande ALWEB >=9.0.0 (installé : 0.9.0)")
    m["framework_version"] = ">=0.9.0"
    m["slug"] = "enfant"
    m["dependencies"] = [{"slug": "absent", "version": ">=1.0.0"}]
    io.write_file(os.join(t3, "alweb-theme.json"), json.stringify(m))
    assert_contains(erreur(() => reg.install(t3)), "dépendance absente : thème « absent »")
    m["dependencies"] = [{"slug": "modern-business", "version": ">=1.0.0"}]
    io.write_file(os.join(t3, "alweb-theme.json"), json.stringify(m))
    assert_eq(reg.install(t3)["version"], "2.0.0")                                   # depuis un dossier
    assert_contains(erreur(() => reg.remove("modern-business")), "« enfant » dépend de « modern-business »")
    reg.remove("enfant")
    reg.remove("modern-business")
    assert_eq([reg.list(), reg.active()], [[], null])
    assert_eq([x for x in os.list_dir(os.join(projet, "themes")) if not s.starts_with(x, ".")], [])
    assert_contains(erreur(() => reg.install("absent.alwt")), "source introuvable")

func appli(projet, avec_override=false):
    app := alweb.App("Vitrine")
    app.configure(conf.from_dict({"secret_key": "s" * 40}))
    th := themes.setup(app, null, {"root": projet})

    @app.get("/", {"name": "accueil"})
    func accueil(req):
        return alweb.render(req, "index.html", {"services": [{"titre": "Conseil <b>", "texte": "Audit", "lien": "/services"}]})

    @app.get("/services")
    func services(req):
        return alweb.render(req, "services.html", {})
    return app

async func test_integration():
    projet := neuf(os.join(BASE, "integration"))
    registry.Registry(projet).install(theme("integ"))
    os.mkdir_all(os.join(projet, "config"))
    io.write_file(os.join(projet, "config", "theme.modern-business.json"), "{\"couleurs\": {\"primaire\": \"#1f6feb\"}, \"site\": {\"nom\": \"Ma société\"}, \"menu\": [{\"label\": \"Accueil\", \"url\": \"/\"}]}")
    app := appli(projet)
    assert_eq([app.theme.slug, themes.setting(app, "couleurs.primaire")], ["modern-business", "#1f6feb"])
    c := at.Client(app)
    h := (await c.get("/")).text()
    assert_contains(h, "<title>Ma société</title>")
    assert_contains(h, "Conseil &lt;b&gt;")                                         # données de l'application, échappées
    assert_contains(h, "<a href=\"/\" aria-current=\"page\">Accueil</a>")           # composant navbar, menu du projet
    css := s.find(h, "/theme/css/theme.css?v=")
    assert_true(css > 0)
    url := h[css:css + s.find(h[css:len(h)], "\"")]
    r := await c.get(url)
    assert_eq([r.status, r.headers.get("Cache-Control")], [200, "public, max-age=31536000"])
    v := await c.get(s.find(h, "/_theme.css?v=") > 0 and "/_theme.css" or "")
    assert_contains(v.text(), "--couleurs-primaire: #1f6feb;")
    assert_true(s.contains((await c.get("/services")).text(), "Aucun service pour le moment."))   # état vide propre
    # page remplacée par l'application (templates/ du projet passe avant le thème)
    os.mkdir_all(os.join(projet, "templates"))
    io.write_file(os.join(projet, "templates", "services.html"), "{% extends \"base.html\" %}{% block contenu %}<p>Ma page à moi</p>{% endblock %}")
    h2 := (await at.Client(appli(projet)).get("/services")).text()
    assert_contains(h2, "<p>Ma page à moi</p>")
    assert_contains(h2, "class=\"entete\"")                                          # avec la mise en page du thème
    # paramètre invalide : refusé au démarrage, message clair
    io.write_file(os.join(projet, "config", "theme.modern-business.json"), "{\"couleurs\": {\"primaire\": \"rouge\"}}")
    assert_contains(erreur(() => appli(projet)), "couleurs.primaire : couleur « #rrggbb » attendue")
    # sans thème actif : gabarits de l'application seuls
    registry.Registry(projet).deactivate()
    app3 := appli(projet)
    assert_eq(app3.theme, null)

func test_domaines():
    assert_eq(cli.domain_of("e-commerce"), "ecommerce")
    assert_eq(cli.domain_of(" Boutique "), "ecommerce")
    assert_eq(cli.domain_of(null), null)
    assert_contains(erreur(() => cli.domain_of("restaurant")), "domaine inconnu")
    for dom in ["business", "ecommerce", "blog", "portfolio"]:
        d := os.join(BASE, "dom-" + dom)
        if os.exists(d):
            os.rmdir(d, true)
        w := cli.create_theme("site-" + dom, {"dir": d, "modele": MODELE, "auteur": "Test", "domaine": dom})
        r := validator.validate(d)
        assert_eq(r["errors"], [])
        assert_eq(r["manifest"]["category"], dom)
        assert_eq(len(w), len(r["files"]))                                       # chaque fichier compté une fois
        rw := s.join(" | ", r["warnings"])
        for absent in ["classes CSS absentes", "block contenu", "site.slogan", "site.nom"]:
            assert_false(s.contains(rw, absent))
        assert_false(s.contains(io.read_file(os.join(d, "config", "theme.json")), "{{"))
    e := os.join(BASE, "dom-ecommerce")
    for f in ["templates/boutique/index.html", "templates/boutique/produit.html", "templates/panier.html", "templates/commande.html", "components/boutique.html"]:
        assert_true(os.isfile(os.join(e, f)))
    css := io.read_file(os.join(e, "static", "css", "theme.css"))
    assert_contains(css, ".menu-bouton")                                         # feuille du modèle…
    assert_contains(css, ".grille-produits")                                     # …complétée par le domaine
    assert_false(os.exists(os.join(e, "static", "css", "theme.css.ajout")))
    assert_eq(json.parse(io.read_file(os.join(e, "config", "theme.json")))["site"]["nom"]["default"], "Site Ecommerce")
    assert_true(os.isfile(os.join(BASE, "dom-blog", "templates", "blog", "detail.html")))
    assert_true(os.isfile(os.join(BASE, "dom-portfolio", "templates", "projets", "detail.html")))
    assert_eq(json.parse(io.read_file(os.join(BASE, "dom-business", "alweb-theme.json")))["keywords"], ["entreprise", "vitrine", "services"])

func test_remarques_de_compatibilite():
    d := theme("compat")
    w := s.join(" | ", validator.validate(d)["warnings"])
    for absent in ["block contenu", "site.nom", "site.slogan", "classes CSS absentes"]:
        assert_false(s.contains(w, absent))                                       # le modèle convient
    p := os.join(d, "templates", "base.html")
    io.write_file(p, s.replace(io.read_file(p), "{% block contenu %}{% endblock %}", ""))
    sp := os.join(d, "config", "theme.json")
    sc := json.parse(io.read_file(sp))
    sc["site"] = {"nom": sc["site"]["nom"]}
    io.write_file(sp, json.stringify(sc))
    cp := os.join(d, "static", "css", "theme.css")
    io.write_file(cp, s.replace(io.read_file(cp), ".hero", ".banniere"))
    r := validator.validate(d)
    assert_eq(r["errors"], [])                                                       # des remarques, pas des erreurs
    w = s.join(" | ", r["warnings"])
    assert_contains(w, "pas de {% block contenu %}")
    assert_contains(w, "réglage site.slogan absent")
    assert_false(s.contains(w, "site.nom absent"))
    assert_contains(w, "classes CSS absentes (hero)")

func test_branchement_automatique():
    projet := neuf(os.join(BASE, "branche"))
    io.write_file(os.join(projet, "alex.toml"), "[package]\nname = \"monsite\"\n")
    avant := "# Application\nuse os\nuse alweb\nuse modeles\n\nfunc creer(cfg, dossier=\".\"):\n    app := alweb.App(\"x\")\n    app.use_templates(os.join(dossier, \"templates\"))\n    app.static(\"/static\", os.join(dossier, \"static\"))\n    return app\n"
    p := os.join(projet, "application.al")
    io.write_file(p, avant)
    assert_eq(cli.wire_theme(projet), ["branche", p])
    t := io.read_file(p)
    assert_contains(t, "use modeles\nuse alweb.themes as themes\n\nfunc creer")
    assert_contains(t, "\n    themes.setup(app, null, {\"root\": dossier})")
    assert_false(s.contains(t, "use_templates"))
    assert_contains(t, "app.static(\"/static\"")                                  # le reste ne bouge pas
    assert_eq(cli.wire_theme(projet), ["deja", p])                                  # une seule fois
    assert_eq(io.read_file(p), t)
    assert_contains(cli.wire_message(projet), "redémarrez")
    # forme non reconnue : rien n'est modifié
    autre := "use alweb\nfunc creer(cfg, d):\n    app := alweb.App(\"x\")\n    app.use_templates(\"gabarits\")\n    return app\n"
    io.write_file(p, autre)
    assert_eq(cli.wire_theme(projet)[0], "manuel")
    assert_eq(io.read_file(p), autre)
    assert_contains(cli.wire_message(projet), "à faire")
    # le modèle de projet est déjà branché
    assert_contains(io.read_file("alweb/modele/application.al.tpl"), "themes.setup(app, null, {\"root\": dossier})")

func test_moteur_plusieurs_dossiers_et_tranches():
    a := neuf(os.join(BASE, "env", "a"))
    b := neuf(os.join(BASE, "env", "b"))
    comp := neuf(os.join(BASE, "env", "comp"))
    io.write_file(os.join(a, "page.html"), "A {% include \"components/x.html\" %}")
    io.write_file(os.join(b, "page.html"), "B")
    io.write_file(os.join(b, "autre.html"), "autre de B")
    io.write_file(os.join(comp, "x.html"), "[x]")
    env := tpl.Environment([a, b, ["components", comp]])
    assert_eq(env.render("page.html"), "A [x]")
    assert_eq(env.render("autre.html"), "autre de B")
    assert_eq(env.exists("components/x.html"), true)
    assert_eq(env.exists("x.html"), false)                                           # préfixe obligatoire
    e := tpl.Environment()
    assert_eq(e.from_string("{{ l[1:3] }}|{{ l[:2] }}|{{ l[-2:] }}|{{ t[0:1] }}|{{ l[5:9] }}|{{ n[0:1] }}").render({"l": [1, 2, 3, 4], "t": "Awa", "n": null}), "[2, 3]|[1, 2]|[3, 4]|A|[]|")

async func test_apercu_et_commandes():
    d := theme("apercu")
    c := at.Client(themes.preview_app(d))
    assert_eq(themes.pages(c.app.theme), ["about", "blog/detail", "blog/index", "contact", "index", "services"])
    assert_contains((await c.get("/")).text(), "Développement")                        # données de preview/data.json
    assert_contains((await c.get("/blog")).text(), "1 / 3")
    assert_contains((await c.get("/blog/detail")).text(), "Un site rapide commence")
    ap := (await c.get("/_apercu?page=contact")).text()
    assert_contains(ap, "src=\"/contact\"")
    assert_contains(ap, "Mobile · 390 px")
    assert_eq((await c.get("/inconnue", {"headers": {"Accept": "text/html"}})).status, 404)
    assert_eq(cli.theme_display_name("modern-business"), "Modern Business")
    assert_contains(erreur(() => cli.create_theme("Mauvais Nom", {"modele": MODELE})), "identifiant de thème invalide")
    assert_contains(erreur(() => cli.create_theme("modern-business", {"dir": d, "modele": MODELE})), "n'est pas vide")
    assert_contains(cli.format_validation(validator.validate(d)), "thème valide")
