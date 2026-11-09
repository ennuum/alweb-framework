# Formulaires (urlencoded, multipart, fichiers), validation avec erreurs par champ, contrôle des fichiers par
# leur contenu, protection CSRF (champ, en-tête, refus, exemptions).
use alweb
use string as s
use alweb.sessions as sessions
use alweb.csrf as csrf
use alweb.forms as forms
use alweb.testing as at
use alweb.templates as tpl
use network.http_multipart as mp
use serialization.schema as sch
from testing use assert_eq, assert_true, assert_null, assert_contains

SECRET := "clé-de-test-suffisamment-longue-123"
ARTICLE := sch.object({"titre": sch.string(3, 50), "vues": sch.integer(0, 1000).optional()}, ["titre"])
PNG := s.byte_pack([137, 80, 78, 71, 13, 10, 26, 10]) + "données"     # octets bruts, comme sur le réseau

func make_app():
    app := alweb.App("formulaires")
    app.middleware([sessions.middleware(SECRET), csrf.middleware(["/webhooks/"])])
    env := tpl.Environment()
    env.add("form.html", "<form method=\"post\">{{ csrf_field() }}<input name=\"titre\" value=\"{{ form.values.titre }}\">{% if form.error('titre') %}<p class=\"erreur\">{{ form.error('titre') }}</p>{% endif %}</form>")
    app.templates = env
    env.globals["url_for"] = (n, v=null) => app.url_for(n, v)

    @app.get("/form")
    func page(req):
        return alweb.render(req, "form.html", {"form": forms.FormResult(true, {}, null, {})})

    @app.post("/articles")
    func creer(req):
        f := alweb.validate_form(req, ARTICLE)
        if not f.valid:
            return alweb.render(req, "form.html", {"form": f}, 422)
        return ({"ok": f.data}, 201)

    @app.post("/upload")
    func upload(req):
        photo := alweb.form(req).file("photo")
        try:
            t := forms.check_upload(photo, 1000, ["image/png", "image/jpeg"])
            return {"type": t, "nom": photo.safe_filename(), "unique": forms.unique_name(photo), "legende": alweb.form(req).get("legende")}
        catch e:
            return ({"erreur": e.message}, 400)

    app.post("/webhooks/x", (req) => "reçu")
    app.post("/api/x", (req) => "api")
    return app


func extraire_jeton(html):
    marque := "name=\"csrf_token\" value=\""
    i := 0
    while i < len(html) - len(marque):
        if html[i:i + len(marque)] == marque:
            j := i + len(marque)
            fin := j
            while html[fin:fin + 1] != "\"":
                fin += 1
            return html[j:fin]
        i += 1
    return null

async func test_formulaire_csrf_et_validation():
    c := at.Client(make_app())
    page := await c.get("/form")
    jeton := extraire_jeton(page.text())
    assert_true(jeton != null and len(jeton) > 20)
    r := await c.post("/articles", {"form": {"titre": "Bonjour"}})
    assert_eq(r.status, 403)                                     # sans jeton
    r = await c.post("/articles", {"form": {"titre": "Bonjour", "csrf_token": "faux.jeton"}})
    assert_eq(r.status, 403)
    r = await c.post("/articles", {"form": {"titre": "Bonjour", "vues": "12", "csrf_token": jeton}})
    assert_eq(r.status, 201)
    assert_eq(r.json_value(), {"ok": {"titre": "Bonjour", "vues": 12}})
    r = await c.post("/articles", {"form": {"titre": "<a", "csrf_token": jeton}})
    assert_eq(r.status, 422)
    assert_contains(r.text(), "value=\"&lt;a\"")               # valeur saisie réaffichée, échappée
    assert_contains(r.text(), "<p class=\"erreur\">")
    r = await c.post("/articles", {"form": {"titre": "Par en-tête"}, "headers": {"X-CSRF-Token": jeton}})
    assert_eq(r.status, 201)

async func test_jeton_d_une_autre_session_refuse():
    a := at.Client(make_app())
    b := at.Client(make_app())
    jeton_a := extraire_jeton((await a.get("/form")).text())
    await b.get("/form")
    r := await b.post("/articles", {"form": {"titre": "Bonjour", "csrf_token": jeton_a}})
    assert_eq(r.status, 403)

async func test_exemptions():
    c := at.Client(make_app())
    assert_eq((await c.post("/webhooks/x")).status, 200)
    assert_eq((await c.post("/api/x", {"headers": {"Authorization": "Bearer abc"}})).status, 200)
    assert_eq((await c.post("/api/x")).status, 403)

async func test_televersement():
    c := at.Client(make_app())
    jeton := extraire_jeton((await c.get("/form")).text())
    corps := mp.encode({"legende": "Plage", "csrf_token": jeton}, {"photo": mp.File("../../vacances.png", PNG, "image/png")})
    r := await c.post("/upload", {"body": corps[0], "headers": {"Content-Type": corps[1]}})
    assert_eq(r.status, 200)
    v := r.json_value()
    assert_eq(v["type"], "image/png")
    assert_eq(v["nom"], "vacances.png")                         # chemin retiré
    assert_true(v["unique"] != "vacances.png" and v["unique"][len(v["unique"]) - 4:len(v["unique"])] == ".png")
    assert_eq(v["legende"], "Plage")
    faux := mp.encode({"csrf_token": jeton}, {"photo": mp.File("image.png", "<script>alert(1)</script>", "image/png")})
    r = await c.post("/upload", {"body": faux[0], "headers": {"Content-Type": faux[1]}})
    assert_eq(r.status, 400)
    assert_contains(r.json_value()["erreur"], "type de fichier refusé")
    gros := mp.encode({"csrf_token": jeton}, {"photo": mp.File("g.png", PNG + "x" * 2000, "image/png")})
    r = await c.post("/upload", {"body": gros[0], "headers": {"Content-Type": gros[1]}})
    assert_contains(r.json_value()["erreur"], "trop volumineux")

func test_detection_du_type_reel():
    assert_eq(forms.sniff(s.byte_pack([255, 216, 255, 224]) + "abc"), "image/jpeg")
    assert_eq(forms.sniff("\xff\xd8\xff\xe0abc"), null)                    # caractères U+00FF..., pas des octets
    assert_eq(forms.sniff("GIF89a..."), "image/gif")
    assert_eq(forms.sniff("RIFF1234WEBPVP8 "), "image/webp")
    assert_eq(forms.sniff("%PDF-1.7"), "application/pdf")
    assert_null(forms.sniff("bonjour"))
