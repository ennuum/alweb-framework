# Internationalisation (alweb.i18n) : catalogues (fichiers, imbriqués, repli), pluriels CLDR, nombres, montants,
# dates, temps relatif, listes, choix de la langue d'une requête (Accept-Language, ?lang, cookie, session, préfixe
# d'URL), gabarits (_, _n, filtres, langues proposées), courriels dans la langue du destinataire.
#   alexc test tests/test_i18n.al
use os
use io
use time
use alweb
use alweb.i18n as i18n
use alweb.config as conf
use alweb.sessions as sessions
use alweb.testing as at
use alweb.cli as cli
use alweb.forms as forms
use serialization.schema as sch
use string as s
use json
from testing use assert_eq, assert_true, assert_contains, assert_raises
from core use len

const NNBSP := " "
const NBSP := " "

func dossier_catalogues():
    d := "build/test_i18n/locales"
    os.mkdir_all(d)
    io.write_file(os.join(d, "fr.json"), "{\"panier\": {\"one\": \"{n} article dans le panier\", \"other\": \"{n} articles dans le panier\"}}")
    io.write_file(os.join(d, "en.json"), "{\"Bonjour {nom}\": \"Hello {nom}\", \"Se connecter\": \"Sign in\", \"panier\": {\"one\": \"{n} item in your cart\", \"other\": \"{n} items in your cart\"}, \"compte\": {\"titre\": \"Your account\", \"aide_html\": \"See <a href=\\\"/aide\\\">help</a>, {nom}\"}}")
    io.write_file(os.join(d, "de.json"), "{\"Bonjour {nom}\": \"Hallo {nom}\"}")
    return d

func test_codes_et_negociation():
    assert_eq(i18n.normalize("fr_ca"), "fr-CA")
    assert_eq(i18n.normalize("ZH-hant-tw"), "zh-Hant-TW")
    assert_eq(i18n.normalize("fr;drop"), null)
    assert_eq(i18n.normalize("x"), null)
    assert_eq(i18n.parse_accept_language("de;q=0.5, en-US, fr;q=0.9, *;q=0.1, es;q=0"), ["en-US", "fr", "de"])
    assert_eq(i18n.parse_accept_language(null), [])
    assert_eq(i18n.best_match("fr-CA", ["en", "fr"]), "fr")                   # langue de base
    assert_eq(i18n.best_match("en", ["fr", "en-GB"]), "en-GB")                # seule variante proposée
    assert_eq(i18n.best_match("EN-gb", ["fr", "en-GB"]), "en-GB")
    assert_eq(i18n.best_match("it", ["fr", "en"]), null)

func test_pluriels():
    cats := (loc, ns) => [i18n.plural_category(loc, n) for n in ns]
    assert_eq(cats("fr", [0, 1, 1.5, 2, 100]), ["one", "one", "one", "other", "other"])
    assert_eq(cats("en", [0, 1, 1.5, 2]), ["other", "one", "other", "other"])
    assert_eq(cats("ru", [1, 2, 5, 11, 21, 22, 25, 112]), ["one", "few", "many", "many", "one", "few", "many", "many"])
    assert_eq(cats("pl", [1, 2, 5, 12, 22, 25]), ["one", "few", "many", "many", "few", "many"])
    assert_eq(cats("ar", [0, 1, 2, 3, 11, 100]), ["zero", "one", "two", "few", "many", "other"])
    assert_eq(cats("ja", [1, 2]), ["other", "other"])
    assert_eq(cats("pt", [0, 1]), ["one", "one"])
    assert_eq(cats("pt-PT", [0, 1]), ["other", "one"])
    assert_eq(cats("cs", [1, 3, 5]), ["one", "few", "other"])

func test_nombres_et_montants():
    assert_eq(i18n.format_number("fr", 1234567.891), "1" + NNBSP + "234" + NNBSP + "567,891")
    assert_eq(i18n.format_number("en", 1234567.891), "1,234,567.891")
    assert_eq(i18n.format_number("de", 1234.5), "1.234,5")
    assert_eq(i18n.format_number("es", 1234), "1234")                     # groupement à partir de 5 chiffres
    assert_eq(i18n.format_number("es", 12345), "12.345")
    assert_eq(i18n.format_number("en", -0.0004), "0")
    assert_eq(i18n.format_number("en", 2.5, 2), "2.5")
    assert_eq(i18n.format_number("fr", -1500), "-1" + NNBSP + "500")
    assert_eq(i18n.format_number("fr", "12.75"), "12,75")
    assert_eq(i18n.format_currency("fr", 1234.5, "EUR"), "1" + NNBSP + "234,50" + NBSP + "€")
    assert_eq(i18n.format_currency("en", 1234.5, "EUR"), "€1,234.50")
    assert_eq(i18n.format_currency("en-US", -9.99, "USD"), "-$9.99")
    assert_eq(i18n.format_currency("fr", 9.99, "USD"), "9,99" + NBSP + "$US")
    assert_eq(i18n.format_currency("fr", 15000, "XOF"), "15" + NNBSP + "000" + NBSP + "F" + NBSP + "CFA")
    assert_eq(i18n.format_currency("ja", 1500, "JPY"), "¥1,500")
    assert_eq(i18n.format_currency("de-CH", 1234.5, "CHF"), "CHF" + NBSP + "1’234.50")
    assert_eq(i18n.format_percent("fr", 0.256), "26" + NBSP + "%")
    assert_eq(i18n.format_percent("en", 0.256, 1), "25.6%")

func test_dates():
    t := 1794146700                                 # 2026-11-08 14:05:00 UTC, un dimanche
    assert_eq(i18n.format_date("fr", t, "short"), "08/11/2026")
    assert_eq(i18n.format_date("fr", t, "medium"), "8 nov. 2026")
    assert_eq(i18n.format_date("fr", t, "full"), "dimanche 8 novembre 2026")
    assert_eq(i18n.format_date("en", t, "short"), "11/8/2026")
    assert_eq(i18n.format_date("en", t, "long"), "November 8, 2026")
    assert_eq(i18n.format_date("en-GB", t, "full"), "Sunday 8 November 2026")
    assert_eq(i18n.format_date("de", t, "full"), "Sonntag, 8. November 2026")
    assert_eq(i18n.format_date("es", t, "long"), "8 de noviembre de 2026")
    assert_eq(i18n.format_date("ja", t, "long"), "2026-11-08")                 # pas de noms : ISO
    assert_eq(i18n.format_time("en", t), "2:05" + NNBSP + "PM")
    assert_eq(i18n.format_time("fr", t, true), "14:05:00")
    assert_eq(i18n.format_time("fr", t, false, 3600), "15:05")                  # UTC+1
    assert_eq(i18n.format_datetime("fr", t, "long"), "8 novembre 2026 à 14:05")
    assert_eq(i18n.format_datetime("en", t, "medium"), "Nov 8, 2026, 2:05" + NNBSP + "PM")
    assert_eq(i18n.format_date("fr", "2026-02-01"), "1 févr. 2026")             # texte ISO : date telle quelle
    assert_eq(i18n.format_datetime("fr", "2026-02-01 09:30:00", "short"), "01/02/2026 09:30")
    assert_eq(i18n.format_time("fr", "2026-02-01T09:30:00Z", false, 3600), "10:30")   # avec fuseau : converti
    assert_eq(i18n.format_date("fr", t, "{EEEE} {d}"), "dimanche 8")             # motif libre
    assert_eq(i18n.format_date("fr", null), "")
    assert_raises(() => i18n.format_date("fr", t, "énorme"))
    i18n.register_formats("sw", {"long": "{d} {MMMM} {yyyy}"}, {"months": ["Januari", "Februari", "Machi", "Aprili", "Mei", "Juni", "Julai", "Agosti", "Septemba", "Oktoba", "Novemba", "Desemba"], "months_abbr": ["Jan", "Feb", "Mac", "Apr", "Mei", "Jun", "Jul", "Ago", "Sep", "Okt", "Nov", "Des"], "days": ["Jumatatu", "Jumanne", "Jumatano", "Alhamisi", "Ijumaa", "Jumamosi", "Jumapili"], "days_abbr": ["Jtt", "Jnn", "Jtn", "Alh", "Iju", "Jmo", "Jpi"]})
    assert_eq(i18n.format_date("sw", t, "long"), "8 Novemba 2026")

func test_relatif_et_listes():
    n := 1794146700.0
    assert_eq(i18n.format_relative("fr", n - 20, n), "à l'instant")
    assert_eq(i18n.format_relative("fr", n - 180, n), "il y a 3 minutes")
    assert_eq(i18n.format_relative("fr", n - 3600, n), "il y a 1 heure")
    assert_eq(i18n.format_relative("en", n + 2 * 86400, n), "in 2 days")
    assert_eq(i18n.format_relative("de", n - 2 * 86400, n), "vor 2 Tagen")
    assert_eq(i18n.format_relative("es", n - 400 * 86400, n), "hace 1 año")
    assert_eq(i18n.format_relative("fr", n - 60 * 86400, n), "il y a 2 mois")
    assert_eq(i18n.format_list("fr", ["Awa", "Bob", "Chen"]), "Awa, Bob et Chen")
    assert_eq(i18n.format_list("en", ["Awa", "Bob", "Chen"]), "Awa, Bob, and Chen")
    assert_eq(i18n.format_list("en", ["Awa", "Bob"], "or"), "Awa or Bob")
    assert_eq(i18n.format_list("de", ["A"]), "A")

func test_catalogues_et_repli():
    tr := i18n.I18n(null, dossier_catalogues(), {"default": "fr"})
    assert_eq([tr.locales[0], len(tr.locales), "en" in tr.locales, "de" in tr.locales], ["fr", 3, true, true])
    en := tr.translator("en-US")                    # variante absente : en
    assert_eq(en.locale, "en")
    assert_eq(en.t("Bonjour {nom}", {"nom": "Awa"}), "Hello Awa")
    assert_eq(en.t("compte.titre"), "Your account")
    assert_eq(en.n("panier", 1), "1 item in your cart")
    assert_eq(en.n("panier", 1250), "1,250 items in your cart")
    fr := tr.translator("fr")
    assert_eq(fr.t("Bonjour {nom}", {"nom": "Awa"}), "Bonjour Awa")      # clé = texte de la langue par défaut
    assert_eq(fr.n("panier", 0), "0 article dans le panier")
    assert_eq(fr.n("panier", 1250), "1" + NNBSP + "250 articles dans le panier")
    de := tr.translator("de")
    assert_eq(de.t("Se connecter"), "Se connecter")                       # absente en allemand : défaut, puis clé
    assert_true("Se connecter" in tr.missing["de"])
    assert_eq(tr.translator("it").locale, "fr")                           # langue non proposée : défaut
    assert_eq(en.t("Prix : {{ {p} }}", {"p": 3}), "Prix : { 3 }")
    assert_eq(en.t("{inconnu} reste"), "{inconnu} reste")
    h := en.markup("compte.aide_html", {"nom": "<b>Bob</b>"})
    assert_eq(str(h), "See <a href=\"/aide\">help</a>, &lt;b&gt;Bob&lt;/b&gt;")
    tr.add("en", {"nouveau": {"cle": "New key"}})
    assert_eq(en.t("nouveau.cle"), "New key")
    assert_eq(en.dir(), "ltr")
    assert_eq(tr.translator("fr").locale_name("en"), "English")

func appli(options=null):
    app := alweb.App("Multilingue")
    app.configure(conf.from_dict({"secret_key": "x" * 40}))
    app.middleware(sessions.middleware("x" * 40))
    o := {"default": "fr", "locales": ["fr", "en", "de"]}
    if options != null:
        for k in options:
            o[k] = options[k]
    i18n.I18n(app, dossier_catalogues(), o)
    app.use_templates("build/test_i18n/templates")
    app.templates.add("page.html", "<html lang=\"{{ lang }}\" dir=\"{{ lang_dir }}\">{{ _(\"Bonjour {nom}\", {\"nom\": nom}) }} | {{ _n(\"panier\", n) }} | {{ prix | currency(\"EUR\") }} | {{ quand | date(\"long\") }} | {{ \"Se connecter\" | t }} | {{ _(\"compte.aide_html\", {\"nom\": nom}) }} | {% for l in locales %}[{{ l.code }}{{ '*' if l.current }} {{ l.url }}]{% endfor %} | {{ url_for(\"profil\") }}</html>")

    @app.get("/page")
    func page(req):
        return app.render(req, "page.html", {"nom": "<Awa>", "n": 2, "prix": 1234.5, "quand": "2026-11-08"})

    @app.get("/profil", {"name": "profil"})
    func profil(req):
        tr := i18n.translator(req)
        return {"lang": tr.locale, "texte": tr.t("Se connecter")}
    return app

async func test_requetes():
    c := at.Client(appli())
    r := await c.get("/page", {"headers": {"Accept-Language": "en-US,en;q=0.9,fr;q=0.5"}})
    h := r.text()
    assert_contains(h, "<html lang=\"en\" dir=\"ltr\">Hello &lt;Awa&gt; | 2 items in your cart | €1,234.50 | November 8, 2026 | Sign in | See <a href=\"/aide\">help</a>, &lt;Awa&gt; |")
    assert_contains(h, "[fr /page?lang=fr]")
    assert_contains(h, "[en* /page?lang=en]")
    assert_eq(r.headers.get("Content-Language"), "en")
    assert_contains(r.headers.get("Vary"), "Accept-Language")
    # sans en-tête : langue par défaut
    r = await c.get("/profil")
    assert_eq(r.json_value(), {"lang": "fr", "texte": "Se connecter"})
    # ?lang=de : retenu par cookie (et session) pour les requêtes suivantes, même avec un autre Accept-Language
    r = await c.get("/profil?lang=de")
    assert_eq(r.json_value()["lang"], "de")
    assert_eq(c.cookies["alweb_lang"], "de")
    r = await c.get("/profil", {"headers": {"Accept-Language": "en"}})
    assert_eq(r.json_value()["lang"], "de")
    assert_eq(r.headers.get("Vary"), null)
    # langue inconnue ou code piégé : ignorés
    r = await c.get("/profil?lang=xx%0D%0ASet-Cookie:a=b")
    assert_eq(r.json_value()["lang"], "de")
    d := at.Client(appli())
    d.cookies["alweb_lang"] = "en"
    assert_eq((await d.get("/profil")).json_value()["lang"], "en")
    d.cookies["alweb_lang"] = "klingon"
    assert_eq((await d.get("/profil")).json_value()["lang"], "fr")

async func test_prefixe_d_url():
    c := at.Client(appli({"prefix": true}))
    r := await c.get("/en/page")
    h := r.text()
    assert_contains(h, "lang=\"en\"")
    assert_contains(h, "[fr /page][en* /en/page][de /de/page]")
    assert_contains(h, "| /en/profil</html>")                 # url_for garde la langue
    assert_eq((await c.get("/de/profil?x=1")).json_value()["lang"], "de")
    assert_eq((await c.get("/profil")).json_value()["lang"], "fr")    # sans préfixe : langue par défaut
    assert_eq((await c.get("/it/profil")).status, 404)                # langue non proposée : chemin ordinaire
    r = await c.get("/page")
    assert_contains(r.text(), "| /profil</html>")

async func test_courriel_dans_la_langue():
    app := alweb.App("Multilingue")
    app.configure(conf.from_dict({"mail": {"url": "memory", "from": "noreply@x.test"}, "site_url": "https://x.test"}))
    i18n.I18n(app, dossier_catalogues(), {"default": "fr"})
    app.use_templates("build/test_i18n/templates")
    app.templates.add("emails/bienvenue.txt", "{{ _(\"Bonjour {nom}\", {\"nom\": nom}) }}, {{ quand | date(\"full\") }}")
    app.templates.add("emails/bienvenue.de.txt", "Willkommen {{ nom }} ({{ lang }})")
    m := app.mail()
    await m.send_template("a@x.test", "Bienvenue", "bienvenue", {"nom": "Awa", "quand": "2026-11-08"}, {"locale": "en"})
    await m.send_template("b@x.test", "Bienvenue", "bienvenue", {"nom": "Bob", "quand": "2026-11-08"})
    await m.send_template("c@x.test", "Willkommen", "bienvenue", {"nom": "Chen"}, {"locale": "de-AT"})
    boite := at.outbox(app)
    assert_eq(boite[0].text, "Hello Awa, Sunday, November 8, 2026")
    assert_contains(boite[0].raw, "Content-Language: en")
    assert_eq(boite[1].text, "Bonjour Bob, dimanche 8 novembre 2026")
    assert_eq(boite[2].text, "Willkommen Chen (de)")                       # gabarit propre à la langue

# `alweb i18n` : clés extraites du code et des gabarits, manquantes par langue, ajout avec --update.
func test_commande_i18n():
    assert_eq(cli.extract_i18n_keys("{{ _(\"Bonjour {nom}\", {\"nom\": n}) }} {{ _n('panier', 3) }} {{ \"Se connecter\" | t }} {{ \"x\" | title }}"), [["Bonjour {nom}", false], ["panier", true], ["Se connecter", false]])
    assert_eq(cli.extract_i18n_keys("tr.t(\"compte.titre\")\nmsg := tr.n( \"articles\", k)\ns := \"pas une clé\"\nf(\"non\")"), [["compte.titre", false], ["articles", true]])
    p := "build/test_i18n/projet"
    if os.exists(p):
        os.rmdir(p, true)
    os.mkdir_all(os.join(p, "templates"))
    os.mkdir_all(os.join(p, "locales"))
    io.write_file(os.join(p, "alex.toml"), "[package]\nname = \"projet\"\n")
    io.write_file(os.join(p, "application.al"), "func f(tr):\n    return tr.t(\"compte.titre\")\n")
    io.write_file(os.join(p, "templates", "page.html"), "{{ _(\"Bonjour {nom}\", {\"nom\": n}) }} {{ _n(\"panier\", 2) }} {{ _(\"alweb.error.home\") }}")
    io.write_file(os.join(p, "locales", "en.json"), "{\"Bonjour {nom}\": \"Hello {nom}\", \"ancienne\": \"Old\"}")
    io.write_file(os.join(p, "locales", "fr.json"), "{}")
    d := cli.project_i18n(p)
    assert_eq(d["keys"], 4)                                                   # alweb.error.home : fourni par alweb
    assert_eq(d["locales"]["en"]["missing"], ["compte.titre", "panier"])
    assert_eq(d["locales"]["en"]["unused"], ["ancienne"])
    assert_eq(d["locales"]["fr"]["missing"], ["compte.titre", "panier"])      # langue par défaut : pas les textes
    assert_contains(cli.format_i18n(d), "en : 2 manquante(s), 1 non trouvée(s) dans le code")
    d = cli.project_i18n(p, true)
    assert_eq(d["updated"], ["locales/en.json", "locales/fr.json"] if d["updated"][0] == "locales/en.json" else ["locales/fr.json", "locales/en.json"])
    en := json.parse(io.read_file(os.join(p, "locales", "en.json")))
    assert_eq([en["panier"], en["compte.titre"], en["Bonjour {nom}"]], [{"one": "", "other": ""}, "", "Hello {nom}"])
    assert_eq(cli.project_i18n(p)["total_missing"], 4)                        # vides : toujours à traduire

# Messages des formulaires : rédigés pour le visiteur, dans sa langue (codes et détails techniques gardés).
func test_messages_de_formulaire():
    assert_eq(forms.describe("$.titre : champ obligatoire absent"), ["titre", "required", {}])
    assert_eq(forms.describe("$.titre : longueur 2 < 3"), ["titre", "too_short", {"n": 3}])
    assert_eq(forms.describe("$.titre : longueur 300 > 120"), ["titre", "too_long", {"n": 120}])
    assert_eq(forms.describe("$.age : entier attendu (obtenu str)"), ["age", "not_integer", {}])
    assert_eq(forms.describe("$.age : 3 < 18"), ["age", "too_small", {"min": "18"}])
    assert_eq(forms.describe("$.tags : 0 éléments < 1"), ["tags", "too_few", {"n": 1}])
    assert_eq(forms.describe("$.etat : x n'est pas parmi [a, b]"), ["etat", "invalid_choice", {}])
    assert_eq(forms.describe("titre : 60 caractères au plus"), ["titre", "too_long", {"n": 60}])
    assert_eq(forms.describe("$.code : déjà pris"), ["code", "custom", {"message": "déjà pris"}])
    assert_eq(forms.message(null, "too_short", {"n": 1}), "Au moins 1 caractère.")
    assert_eq(forms.message(null, "too_short", {"n": 3}), "Au moins 3 caractères.")
    tr := i18n.I18n(null, null, {"default": "fr", "locales": ["fr", "en", "de", "es"]})
    assert_eq(forms.message(tr.translator("en"), "too_short", {"n": 3}), "At least 3 characters.")
    assert_eq(forms.message(tr.translator("de"), "required"), "Dieses Feld ist erforderlich.")
    assert_eq(forms.message(tr.translator("es"), "too_large", {"max": 10}), "Debe ser como máximo 10.")
    tr.add("en", {"déjà pris": "already taken", "alweb.form.required": "Please fill in this field."})
    assert_eq(forms.message(tr.translator("en"), "custom", {"message": "déjà pris"}), "already taken")
    assert_eq(forms.message(tr.translator("en"), "required"), "Please fill in this field.")   # l'application remplace alweb
    assert_eq(tr.missing, {})                                                                # textes d'alweb : rien ne manque

func appli_formulaire(avec_i18n):
    app := alweb.App("Formulaires")
    if avec_i18n:
        i18n.I18n(app, null, {"default": "fr", "locales": ["fr", "en", "de"]})
    app.use_templates("build/test_i18n/templates")
    app.templates.add("errors/418.html", "x")

    @app.post("/inscription")
    func inscription(req):
        f := alweb.validate_form(req, sch.object({"nom": sch.string(3, 20), "age": sch.integer(18, 130)}, ["nom", "age"]))
        return {"errors": f.errors, "codes": f.codes}

    @app.get("/interdit")
    func interdit(req):
        alweb.abort(403, "réservé aux membres")

    @app.get("/panne")
    func panne(req):
        raise("Bogue", "détail interne")
    return app

async func test_formulaires_et_pages_d_erreur():
    c := at.Client(appli_formulaire(true), {"Accept-Language": "en"})
    d := (await c.post("/inscription", {"form": {"nom": "Al", "age": "douze"}})).json_value()
    assert_eq(d["errors"], {"nom": "At least 3 characters.", "age": "Enter a whole number."})
    assert_eq(d["codes"]["nom"], ["too_short", {"n": 3}])
    d = (await at.Client(appli_formulaire(true)).post("/inscription", {"form": {"age": "12"}})).json_value()
    assert_eq(d["errors"], {"nom": "Ce champ est obligatoire.", "age": "La valeur doit être au moins 18."})
    d = (await at.Client(appli_formulaire(false)).post("/inscription", {"form": {"nom": "Al", "age": "40"}})).json_value()
    assert_eq(d["errors"], {"nom": "Au moins 3 caractères."})                # sans i18n : français d'alweb
    # pages d'erreur dans la langue du navigateur ; JSON inchangé pour les API
    html := {"Accept": "text/html,application/xhtml+xml", "Accept-Language": "de"}
    r := await c.get("/rien", {"headers": html})
    assert_eq(r.status, 404)
    assert_contains(r.text(), "<html lang=\"de\" dir=\"ltr\">")
    assert_contains(r.text(), "<h1>Seite nicht gefunden</h1>")
    assert_contains(r.text(), "Zur Startseite")
    r = await c.get("/interdit", {"headers": {"Accept": "text/html"}})
    assert_eq(r.status, 403)
    assert_contains(r.text(), "<h1>Access denied</h1>")
    assert_contains(r.text(), "réservé aux membres")                          # message du développeur, échappé
    r = await c.get("/panne", {"headers": {"Accept": "text/html"}})
    assert_eq(r.status, 500)
    assert_contains(r.text(), "Something went wrong on our side.")
    assert_true(not s.contains(r.text(), "détail interne"))                   # pas de détail hors mode debug
    r = await c.get("/rien", {"headers": {"Accept": "application/json"}})
    assert_eq([r.status, r.json_value()["status"]], [404, 404])
    # gabarit de l'application : errors/404.html
    app := appli_formulaire(true)
    app.templates.add("errors/404.html", "<p lang=\"{{ lang }}\">{{ status }} — {{ title }} — <a href=\"{{ home }}\">{{ _(\"alweb.error.home\") }}</a></p>")
    r = await at.Client(app).get("/rien", {"headers": {"Accept": "text/html", "Accept-Language": "es"}})
    assert_eq([r.status, r.text()], [404, "<p lang=\"fr\">404 — Page introuvable — <a href=\"/\">Retour à l&#39;accueil</a></p>"])
    # un gestionnaire déclaré par l'application passe avant
    app2 := appli_formulaire(true)
    app2.error_handler(404, (req, st, msg) => alweb.html("<p>perdu</p>", 404))
    assert_eq((await at.Client(app2).get("/rien", {"headers": {"Accept": "text/html"}})).text(), "<p>perdu</p>")
