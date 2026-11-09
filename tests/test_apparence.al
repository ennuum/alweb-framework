# Panneau « Apparence » de l'administration (alweb.themes.panel) : accès, formulaire produit depuis le schéma du
# thème, brouillon d'aperçu limité au cadre de la personne qui règle (en-têtes de cadre adaptés), enregistrement
# des seules valeurs changées, erreurs par champ, image envoyée dans le stockage, historique et restauration,
# retour aux valeurs du thème, export, activation d'un autre thème, relecture à chaud du fichier des choix.
#   alexc test tests/test_apparence.al
use os
use io
use json
use string as s
use alweb
use alweb.admin as adm
use alweb.auth as auth
use alweb.sessions as sessions
use alweb.middleware as mw
use alweb.storage as storage
use alweb.themes as themes
use alweb.themes.registry as registry
use alweb.config as conf
use alweb.testing as at
use alweb.cli as cli
use alweb.i18n as i18n
use network.http_multipart as mp
from core use len
from collections use append
from testing use assert_eq, assert_true, assert_false, assert_contains

const BASE := "build/test_apparence"
const MODELE := "alweb/modele-theme"
SECRET := "clé-de-test-suffisamment-longue-pour-apparence"
HTML := {"headers": {"Accept": "text/html"}}
DERNIER := {}
CADRE := {"headers": {"Accept": "text/html", "Sec-Fetch-Dest": "iframe"}}

func neuf(d):
    if os.exists(d):
        os.rmdir(d, true)
    os.mkdir_all(d)
    return d

# Projet avec le thème Modern Business installé (et un second thème « autre-theme »).
func projet(nom, second=false):
    root := neuf(os.join(BASE, nom))
    src := os.join(BASE, nom + "-src")
    if os.exists(src):
        os.rmdir(src, true)
    cli.create_theme("modern-business", {"dir": src, "modele": MODELE, "auteur": "Test"})
    reg := registry.Registry(root)
    reg.install(src)
    if second:
        src2 := os.join(BASE, nom + "-src2")
        if os.exists(src2):
            os.rmdir(src2, true)
        cli.create_theme("autre-theme", {"dir": src2, "modele": MODELE, "auteur": "Test"})
        reg.install(src2)
    return root

func appli(root, journal=null, avec_stockage=false, options=null):
    app := alweb.App("Vitrine")
    app.configure(conf.from_dict({"secret_key": "s" * 40}))
    app.middleware([mw.security_headers(), sessions.middleware(SECRET)])
    if avec_stockage:
        app.storage = storage.open("memory:")
    themes.setup(app, null, {"root": root})

    @app.get("/")
    func accueil(req):
        return alweb.render(req, "index.html", {"services": []})

    @app.get("/services")
    func services(req):
        return alweb.render(req, "services.html", {})

    @app.post("/connexion-test")
    func connexion(req):
        d := req.json()
        auth.login(req, d["id"], d["roles"])
        return "ok"

    app.get("/connexion", (req) => "connexion")
    ev := journal if journal != null else []
    o := {"on_change": (req, e) => append(ev, e)}
    if options != null:
        for k in options:
            o[k] = options[k]
    DERNIER["admin"] = adm.Admin(app, o)
    return app

async func admin_client(app, roles=null):
    c := at.Client(app)
    await c.post("/connexion-test", {"json": {"id": 1, "roles": roles if roles != null else ["admin"]}})
    return c

func jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := s.find(html, marque)
    if i < 0:
        return null
    rest := html[i + len(marque):len(html)]
    return rest[0:s.find(rest, "\"")]

# Champs du formulaire tels que la page les envoie (valeurs actuelles), avec des remplacements.
async func formulaire(c, changes=null):
    h := (await c.get("/admin/_apparence", HTML)).text()
    d := {"csrf_token": jeton(h)}
    i := 0
    while true:
        j := s.find(h[i:len(h)], " name=\"v.")
        if j < 0:
            break
        j = i + j + 7
        nom := h[j:j + s.find(h[j:len(h)], "\"")]
        balise_debut := j
        while h[balise_debut:balise_debut + 1] != "<":
            balise_debut -= 1
        fin := j + s.find(h[j:len(h)], ">")
        balise := h[balise_debut:fin + 1]
        if s.starts_with(balise, "<textarea"):
            d[nom] = h[fin + 1:fin + 1 + s.find(h[fin + 1:len(h)], "</textarea>")]
        elif s.starts_with(balise, "<select"):
            bloc := h[fin:fin + s.find(h[fin:len(h)], "</select>")]
            k := s.find(bloc, "selected")
            av := bloc[0:k]
            q := dernier(av, "value=\"")
            d[nom] = av[q + 7:q + 7 + s.find(av[q + 7:len(av)], "\"")]
        elif s.contains(balise, "type=\"checkbox\""):
            if s.contains(balise, " checked"):
                d[nom] = "1"
        else:
            q := s.find(balise, "value=\"")
            d[nom] = balise[q + 7:q + 7 + s.find(balise[q + 7:len(balise)], "\"")] if q >= 0 else ""
        i = fin
    i = 0
    while true:
        j := s.find(h[i:len(h)], "name=\"b.")
        if j < 0:
            break
        j = i + j + 6
        d[h[j:j + s.find(h[j:len(h)], "\"")]] = "1"
        i = j
    if changes != null:
        for k in changes:
            if changes[k] == null:
                d2 := {}
                for x in d:
                    if x != k:
                        d2[x] = d[x]
                d = d2
            else:
                d[k] = changes[k]
    return d

func corps(d):
    return d

func envoi(champs, nom, octets):
    c := mp.encode(champs, {"f.logo": mp.File(nom, octets, "image/png")})
    return {"body": c[0], "headers": {"Content-Type": c[1]}}

func dernier(t, motif):
    k := -1
    i := 0
    while true:
        j := s.find(t[i:len(t)], motif)
        if j < 0:
            return k
        k = i + j
        i = k + 1

func choix(root):
    p := os.join(root, "config", "theme.modern-business.json")
    return json.parse(io.read_file(p)) if os.isfile(p) else null

func compte(t, motif):
    n := 0
    i := 0
    while true:
        j := s.find(t[i:len(t)], motif)
        if j < 0:
            return n
        n += 1
        i = i + j + len(motif)

async func test_acces_et_formulaire():
    root := projet("acces")
    app := appli(root)
    c := at.Client(app)
    assert_eq((await c.get("/admin/_apparence", HTML)).status, 303)               # pas connecté
    c = await admin_client(app, ["auteur"])
    assert_eq((await c.get("/admin/_apparence", HTML)).status, 403)
    c = await admin_client(app)
    r := await c.get("/admin", HTML)
    assert_contains(r.text(), "href=\"/admin/_apparence\"")                       # menu et carte du tableau de bord
    assert_contains(r.text(), "Modern Business")
    r = await c.get("/admin/_apparence", HTML)
    assert_eq([r.status, r.headers.get("Cache-Control")], [200, "no-store"])
    h := r.text()
    for attendu in ["<legend>Couleurs</legend>", "<legend>Mise en page</legend>", "<legend>Général</legend>", "Couleur principale",
                    "type=\"color\" id=\"c_couleurs_primaire_p\" value=\"#e87524\"", "name=\"v.couleurs.primaire\" value=\"#e87524\" data-css=\"--couleurs-primaire\"",
                    "name=\"b.mise_en_page.barre_laterale\"", "name=\"v.menu.0.label\" value=\"Accueil\"", "Valeur du thème : #e87524",
                    "<iframe id=\"apercu\" src=\"/?_apercu_theme=1\"", "<option value=\"/services\">", "<script src=\"/admin/_apparence.js\"></script>",
                    "0 réglage(s) modifié(s)", "Aucune version précédente."]:
        assert_contains(h, attendu)
    assert_false(s.contains(h, "type=\"file\""))                                   # pas de stockage : pas d'envoi
    js := await c.get("/admin/_apparence.js")
    assert_eq(js.headers.get("Content-Type"), "text/javascript; charset=utf-8")
    assert_contains(js.text(), "X-CSRF-Token")
    # aperçu : chaque vue a sa largeur d'appareil (sinon « Ordinateur » s'affiche en mise en page tablette)
    for attendu in ["data-vue=\"ordinateur\" data-largeur=\"1280\"", "data-vue=\"tablette\" data-largeur=\"768\"",
                    "data-vue=\"mobile\" data-largeur=\"390\"", "<div class=\"cadre ordinateur\" id=\"cadre\" data-largeur=\"1280\">"]:
        assert_contains(h, attendu)
    assert_contains(js.text(), "scale(")
    # option appearance: false -> pas de page ; liste de rôles
    c2 := await admin_client(appli(root, null, false, {"appearance": false}))
    assert_eq((await c2.get("/admin/_apparence", HTML)).status, 404)
    assert_false(s.contains((await c2.get("/admin", HTML)).text(), "_apparence"))
    c3 := await admin_client(appli(root, null, false, {"appearance": ["design"]}))
    assert_eq((await c3.get("/admin/_apparence", HTML)).status, 403)
    c4 := await admin_client(appli(root, null, false, {"appearance": ["design"]}), ["admin", "design"])
    assert_eq((await c4.get("/admin/_apparence", HTML)).status, 200)

async func test_brouillon_limite_au_cadre():
    root := projet("brouillon")
    app := appli(root)
    c := await admin_client(app)
    # page du panneau ouverte, rien changé : le site s'affiche dans le cadre, avec les valeurs enregistrées
    await c.get("/admin/_apparence", HTML)
    f0 := await c.get("/", CADRE)
    assert_eq(f0.headers.get("X-Frame-Options"), "SAMEORIGIN")
    assert_contains(f0.text(), "<title>Modern Business</title>")
    assert_eq((await c.get("/", HTML)).headers.get("X-Frame-Options"), "DENY")
    d := await formulaire(c, {"v.couleurs.primaire": "#1f6feb", "v.site.nom": "Nouveau nom"})
    tok := d["csrf_token"]
    r := await c.post("/admin/_apparence/apercu", {"form": corps(d), "headers": {"X-CSRF-Token": tok}})
    assert_eq(r.status, 200)
    j := json.parse(r.text())
    assert_eq([j["ok"], j["modified"]], [true, ["site.nom", "couleurs.primaire"]])
    assert_eq(choix(root), null)                                                      # rien d'enregistré
    # dans le cadre : réglages en cours, page affichable dans un cadre de même origine
    f := await c.get("/", CADRE)
    assert_contains(f.text(), "<title>Nouveau nom</title>")
    assert_eq(f.headers.get("X-Frame-Options"), "SAMEORIGIN")
    assert_contains(f.headers.get("Content-Security-Policy"), "frame-ancestors 'self'")
    i := s.find(f.text(), "/_theme.css?apercu=")
    assert_true(i > 0)
    lien := f.text()[i:i + s.find(f.text()[i:len(f.text())], "\"")]
    css := await c.get(lien)
    assert_contains(css.text(), "--couleurs-primaire: #1f6feb;")
    assert_eq(css.headers.get("Cache-Control"), "no-store")
    # même personne hors du cadre, et autre visiteur : valeurs enregistrées, cadre interdit
    hors := await c.get("/", HTML)
    assert_contains(hors.text(), "<title>Modern Business</title>")
    assert_eq(hors.headers.get("X-Frame-Options"), "DENY")
    v := at.Client(app)
    autre := await v.get("/", CADRE)
    assert_contains(autre.text(), "<title>Modern Business</title>")
    assert_eq(autre.headers.get("X-Frame-Options"), "DENY")
    assert_false(s.contains((await v.get(lien)).text(), "#1f6feb"))
    # la page du panneau reprend le brouillon ; « Abandonner » l'oublie
    p := (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(p, "value=\"#1f6feb\"")
    assert_contains(p, "id=\"abandonner\" formaction=\"/admin/_apparence/abandonner\" formnovalidate>")
    await c.post("/admin/_apparence/abandonner", {"form": [["csrf_token", tok]]})
    assert_contains((await c.get("/", CADRE)).text(), "<title>Modern Business</title>")
    # valeur invalide : erreurs par champ, brouillon inchangé
    d = await formulaire(c, {"v.couleurs.primaire": "rouge", "v.typographie.taille": "grand", "v.menu.0.url": "javascript:alert(1)"})
    j = json.parse((await c.post("/admin/_apparence/apercu", {"form": corps(d), "headers": {"X-CSRF-Token": tok}})).text())
    assert_false(j["ok"])
    assert_eq(len(j["errors"]), 3)
    assert_contains(j["errors"]["couleurs.primaire"], "#rrggbb")
    assert_contains(j["errors"]["menu"], "liste de liens")
    # sans jeton CSRF : refusé
    d["csrf_token"] = "faux"
    assert_eq((await c.post("/admin/_apparence/apercu", {"form": corps(d)})).status, 403)

async func test_enregistrer_historique_restaurer():
    root := projet("enregistrer")
    ev := []
    app := appli(root, ev)
    c := await admin_client(app)
    d := await formulaire(c, {"v.couleurs.primaire": "#1f6feb", "v.mise_en_page.barre_laterale": null, "v.menu.1.label": "", "v.menu.1.url": "",
                              "v.menu.5.label": "Presse", "v.menu.5.url": "/presse"})
    r := await c.post("/admin/_apparence", {"form": corps(d)})
    assert_eq([r.status, r.headers.get("Location")], [303, "/admin/_apparence"])
    ch := choix(root)
    assert_eq(ch["couleurs"], {"primaire": "#1f6feb"})                               # seules les valeurs changées
    assert_eq(ch["mise_en_page"], {"barre_laterale": false})
    assert_eq([l["label"] for l in ch["menu"]], ["Accueil", "À propos", "Blog", "Contact", "Presse"])
    assert_false("site" in ch)
    assert_eq([ev[0]["action"], ev[0]["table"], ev[0]["id"]], ["theme_update", "theme", "modern-business"])
    # appliqué tout de suite pour tous les visiteurs
    v := at.Client(app)
    h := (await v.get("/", HTML)).text()
    assert_contains(h, ">Presse</a>")
    i := s.find(h, "/_theme.css?v=")
    assert_contains((await v.get(h[i:i + s.find(h[i:len(h)], "\"")])).text(), "--couleurs-primaire: #1f6feb;")
    p := (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(p, "Apparence enregistrée")
    assert_contains(p, "3 réglage(s) modifié(s)")
    assert_contains(p, "Aucune version précédente.")                                 # premier enregistrement
    # deuxième enregistrement : le premier part dans l'historique
    d = await formulaire(c, {"v.couleurs.primaire": "#222222"})
    await c.post("/admin/_apparence", {"form": corps(d)})
    assert_eq(choix(root)["couleurs"]["primaire"], "#222222")
    hist := themes.history(os.join(root, ".alweb", "themes", "modern-business", "historique"))
    assert_eq(len(hist), 1)
    p = (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(p, "<option value=\"" + hist[0]["name"] + "\">")
    await c.post("/admin/_apparence/restaurer", {"form": [["csrf_token", d["csrf_token"]], ["version", hist[0]["name"]]]})
    assert_eq(choix(root)["couleurs"]["primaire"], "#1f6feb")
    assert_eq(len(themes.history(os.join(root, ".alweb", "themes", "modern-business", "historique"))), 2)
    # version inconnue ou chemin piégé : refusé
    await c.post("/admin/_apparence/restaurer", {"form": [["csrf_token", d["csrf_token"]], ["version", "../../config/x.json"]]})
    assert_contains((await c.get("/admin/_apparence", HTML)).text(), "Version introuvable")
    # export
    e := await c.get("/admin/_apparence/export.json")
    assert_eq(e.headers.get("Content-Disposition"), "attachment; filename=\"theme.modern-business.json\"")
    assert_eq(json.parse(e.text())["couleurs"]["primaire"], "#1f6feb")
    # tout rétablir
    await c.post("/admin/_apparence/reinitialiser", {"form": [["csrf_token", d["csrf_token"]]]})
    assert_eq(choix(root), {})
    assert_contains((await v.get("/", HTML)).text(), "<title>Modern Business</title>")
    assert_eq([x["action"] for x in ev], ["theme_update", "theme_update", "theme_restore", "theme_reset"])

async func test_erreurs_a_l_enregistrement():
    root := projet("erreurs")
    app := appli(root)
    c := await admin_client(app)
    d := await formulaire(c, {"v.couleurs.primaire": "bleu", "v.site.nom": "<script>"})
    r := await c.post("/admin/_apparence", {"form": corps(d)})
    assert_eq(r.status, 422)
    h := r.text()
    assert_contains(h, "2 valeur(s) à corriger.")
    assert_contains(h, "name=\"v.couleurs.primaire\" value=\"bleu\"")              # saisie gardée
    assert_contains(h, "name=\"v.site.nom\" value=\"&lt;script&gt;\"")             # et échappée
    assert_contains(h, "data-err=\"couleurs.primaire\">couleur")
    assert_eq(choix(root), null)

async func test_image_envoyee_dans_le_stockage():
    root := projet("image")
    app := appli(root, null, true)
    c := await admin_client(app)
    h := (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(h, "enctype=\"multipart/form-data\"")
    assert_contains(h, "type=\"file\" name=\"f.logo\"")
    d := await formulaire(c)
    png := io.read_raw("tests/fixtures/photo.png") if os.isfile("tests/fixtures/photo.png") else null
    if png == null:
        png = s.byte_pack([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
                           0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9, 251, 3, 253, 227, 85, 242, 156, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
    r := await c.post("/admin/_apparence", envoi(d, "logo.png", png))
    assert_eq(r.status, 303)
    logo := choix(root)["logo"]
    assert_true(s.starts_with(logo, "media:theme/modern-business/"))
    assert_true(await app.storage.head(logo[6:len(logo)]) != null)
    # pas une image : refusé, rien d'enregistré de plus
    r = await c.post("/admin/_apparence", envoi(d, "x.png", "<html>pas une image</html>"))
    assert_eq(r.status, 422)
    assert_contains(r.text(), "Image PNG, JPEG, GIF ou WebP attendue.")

async func test_relecture_a_chaud_et_autre_theme():
    root := projet("chaud", true)
    app := appli(root)
    v := at.Client(app)
    assert_contains((await v.get("/", HTML)).text(), "<title>Modern Business</title>")
    # un autre processus (ou une personne) modifie le fichier des choix : pris en compte sans redémarrer
    os.mkdir_all(os.join(root, "config"))
    io.write_file(os.join(root, "config", "theme.modern-business.json"), "{\"site\": {\"nom\": \"Changé ailleurs\"}}")
    app.theme.refresh(true)
    assert_contains((await v.get("/", HTML)).text(), "<title>Changé ailleurs</title>")
    # fichier devenu invalide : valeurs précédentes gardées
    io.write_file(os.join(root, "config", "theme.modern-business.json"), "{\"couleurs\": {\"primaire\": \"vert\"}}")
    app.theme.refresh(true)
    assert_contains((await v.get("/", HTML)).text(), "<title>Changé ailleurs</title>")
    # thèmes installés : activer l'autre (pris au redémarrage)
    c := await admin_client(app)
    h := (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(h, "<h2>Thèmes installés</h2>")
    assert_eq(compte(h, "name=\"slug\""), 1)                                         # seul l'autre a un bouton
    await c.post("/admin/_apparence/activer", {"form": [["csrf_token", jeton(h)], ["slug", "autre-theme"]]})
    assert_eq(registry.Registry(root).active(), "autre-theme")
    h = (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(h, "« autre-theme » sera utilisé au prochain démarrage")
    assert_contains(h, "actif au prochain démarrage")
    await c.post("/admin/_apparence/activer", {"form": [["csrf_token", jeton(h)], ["slug", "inconnu"]]})
    assert_contains((await c.get("/admin/_apparence", HTML)).text(), "Activation impossible")
    assert_eq(appli(root).theme.slug, "autre-theme")

async func test_administration_sans_tables_ni_theme():
    root := neuf(os.join(BASE, "vide"))
    c := await admin_client(appli(root))
    r := await c.get("/admin", HTML)
    assert_eq(r.status, 200)                                                            # pas de base nécessaire
    assert_false(s.contains(r.text(), "_apparence"))
    assert_eq((await c.get("/admin/_apparence", HTML)).status, 404)

async func test_panneau_en_anglais():
    root := projet("anglais")
    app := appli(root)
    i18n.I18n(app, null, {"default": "fr", "locales": ["fr", "en"]})
    c := at.Client(app, {"Accept-Language": "en", "Accept": "text/html"})
    await c.post("/connexion-test", {"json": {"id": 1, "roles": ["admin"]}})
    t := (await c.get("/admin/_apparence")).text()
    for attendu in ["<title>Appearance · Administration</title>", "<legend>Colors</legend>", "<legend>General</legend>", "Theme value: #e87524",
                    "0 settings changed", "Discard changes", "Desktop", "Installed themes", "Download settings"]:
        assert_contains(t, attendu)

async func fiche_distante(url):
    if url != "http://market.test/api/v1/themes/modern-business":
        raise("ThemeError", "adresse inattendue : " + url)
    return {"versions": [{"version": "0.3.0", "framework_version": ">=0.9.0", "yanked": false},
                         {"version": "0.5.0", "framework_version": ">=0.9.0", "yanked": true},
                         {"version": "9.0.0", "framework_version": ">=9.0.0", "yanked": false}]}

async func injoignable(url):
    raise("ThemeError", "connexion refusée")

async func test_mises_a_jour_depuis_la_marketplace():
    root := projet("maj")
    app := appli(root)
    c := await admin_client(app)
    h := (await c.get("/admin/_apparence", HTML)).text()
    assert_false(s.contains(h, "/admin/_apparence/mises-a-jour"))                 # installé localement
    reg := registry.Registry(root)
    lock := reg.lock()
    lock["themes"]["modern-business"]["source"] = "marketplace:http://market.test"
    reg.save(lock)
    DERNIER["admin"].market_transport = fiche_distante
    h = (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(h, "action=\"/admin/_apparence/mises-a-jour\"")
    await c.post("/admin/_apparence/mises-a-jour", {"form": [["csrf_token", jeton(h)]]})
    h = (await c.get("/admin/_apparence", HTML)).text()
    assert_contains(h, "Version 0.3.0 disponible (installée : 0.1.0). Pour l&#39;installer : alweb theme update modern-business")
    DERNIER["admin"].market_transport = injoignable
    await c.post("/admin/_apparence/mises-a-jour", {"form": [["csrf_token", jeton(h)]]})
    assert_contains((await c.get("/admin/_apparence", HTML)).text(), "Marketplace injoignable (http://market.test) : connexion refusée")
