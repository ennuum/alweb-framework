# Moteur de gabarits : expressions, filtres, échappement, conditions, boucles, héritage, inclusions, macros,
# espaces, erreurs avec ligne, chargement depuis un dossier et rechargement.
use os
use io
use time
use alweb.templates as tpl
use alweb as alweb_mod
use alweb.testing as at
from testing use assert_eq, assert_true, assert_contains

class Auteur:
    func init(nom):
        self.nom = nom

    func initiales():
        return self.nom[0:1] + "."

func rend(src, ctx=null):
    return tpl.Environment().from_string(src).render(ctx)

func test_expressions_et_echappement():
    assert_eq(rend("Bonjour {{ nom }} !", {"nom": "Zoé"}), "Bonjour Zoé !")
    assert_eq(rend("{{ x }}", {"x": "<b>\"a\" & 'b'</b>"}), "&lt;b&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/b&gt;")
    assert_eq(rend("{{ x | safe }}", {"x": "<b>ok</b>"}), "<b>ok</b>")
    assert_eq(rend("{{ absent }}|{{ absent.champ.autre }}|{{ n }}", {"n": 0}), "||0")
    assert_eq(rend("{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 7 % 3 }} {{ -n }}", {"n": 4}), "7 9 1 -4")
    assert_eq(rend("{{ \"a\" ~ n ~ 'b' }}", {"n": 5}), "a5b")
    assert_eq(rend("{{ d.a.b }} {{ l[1] }} {{ l[-1] }} {{ d['a']['b'] }}", {"d": {"a": {"b": "x"}}, "l": [1, 2, 3]}), "x 2 3 x")
    assert_eq(rend("{{ a.nom }} {{ a.initiales() }}", {"a": Auteur("Awa")}), "Awa A.")
    assert_eq(rend("{{ 'oui' if ok else 'non' }} {{ 'oui' if ko else 'non' }}", {"ok": true, "ko": false}), "oui non")
    assert_eq(rend("{{ 2 in l }} {{ 9 not in l }} {{ 'b' in 'abc' }} {{ x is none }} {{ 3 is odd }}", {"l": [1, 2]}), "true true true true true")
    assert_eq(rend("{{ [1, 2] | length }} {{ {'a': 1}.a }}"), "2 1")

func test_filtres():
    assert_eq(rend("{{ s | upper }} {{ s | title }} {{ s | capitalize }}", {"s": "bonjour le monde"}), "BONJOUR LE MONDE Bonjour Le Monde Bonjour le monde")
    assert_eq(rend("{{ v | default('—') }} {{ l | join(', ') }} {{ t | truncate(9) }}", {"l": ["<a>", "b"], "t": "un texte assez long"}), "— &lt;a&gt;, b un texte…")
    assert_eq(rend("{{ t | nl2br }}", {"t": "a\n<b>"}), "a<br>\n&lt;b&gt;")
    assert_eq(rend("{% for x in p.items %}{{ x }}{% endfor %} {% for kv in d.items() %}{{ kv[0] }}{% endfor %}", {"p": {"items": [1, 2]}, "d": {"a": 1}}), "12 a")    # clé avant méthode
    assert_eq(rend("{{ l | first }} {{ l | last }} {{ l | reverse | join('') }} {{ 3.14159 | round(2) }}", {"l": [1, 2, 3]}), "1 3 321 3.14")
    assert_eq(rend("{{ q | urlencode }}", {"q": "été & co"}), "%C3%A9t%C3%A9%20%26%20co")
    assert_eq(rend("<script>var d = {{ d | tojson }};</script>", {"d": {"x": "</script>"}}), "<script>var d = {\"x\":\"\\u003c/script\\u003e\"};</script>")
    assert_eq(rend("{% for n in l | sort('age') %}{{ n.nom }}{% endfor %}", {"l": [{"nom": "B", "age": 30}, {"nom": "A", "age": 20}]}), "AB")
    env := tpl.Environment()
    env.filters["double"] = (v) => v * 2
    assert_eq(env.from_string("{{ 21 | double }}").render(), "42")

func test_conditions_et_boucles():
    src := "{% if n > 10 %}grand{% elif n > 5 %}moyen{% else %}petit{% endif %}"
    assert_eq(rend(src, {"n": 12}), "grand")
    assert_eq(rend(src, {"n": 7}), "moyen")
    assert_eq(rend(src, {"n": 1}), "petit")
    assert_eq(rend("{% for x in l %}{{ loop.index }}:{{ x }}{% if not loop.last %},{% endif %}{% endfor %}", {"l": ["a", "b", "c"]}), "1:a,2:b,3:c")
    assert_eq(rend("{% for x in l %}{{ x }}{% else %}vide{% endfor %}", {"l": []}), "vide")
    assert_eq(rend("{% for k, v in d.items() %}{{ k }}={{ v }};{% endfor %}", {"d": {"a": 1, "b": 2}}), "a=1;b=2;")
    assert_eq(rend("{% for i in range(3) %}{{ i }}{% endfor %}"), "012")
    assert_eq(rend("{% set total = l | length %}{{ total }} éléments", {"l": [1, 2]}), "2 éléments")

func test_espaces():
    assert_eq(rend("<ul>\n{% for x in l %}\n  <li>{{ x }}</li>\n{% endfor %}\n</ul>", {"l": [1, 2]}), "<ul>\n  <li>1</li>\n  <li>2</li>\n</ul>")
    assert_eq(rend("a   {{- x -}}   b", {"x": "X"}), "aXb")
    assert_eq(rend("{# commentaire #}x{% raw %}{{ brut }}{% endraw %}"), "x{{ brut }}")

func test_heritage_inclusion_macros():
    env := tpl.Environment()
    env.add("base.html", "<title>{% block titre %}Site{% endblock %}</title>\n<main>{% block contenu %}{% endblock %}</main>\n{% include \"pied.html\" %}")
    env.add("pied.html", "<footer>{{ annee }}</footer>")
    env.add("page.html", "{% extends \"base.html\" %}\n{% block titre %}{{ super() }} — {{ nom }}{% endblock %}\n{% block contenu %}<p>{{ texte }}</p>{% endblock %}")
    out := env.render("page.html", {"nom": "Accueil", "texte": "<salut>", "annee": 2026})
    assert_eq(out, "<title>Site — Accueil</title>\n<main><p>&lt;salut&gt;</p></main>\n<footer>2026</footer>")
    env.add("forms.html", "{% macro champ(nom, valeur=\"\", type=\"text\") %}<input type=\"{{ type }}\" name=\"{{ nom }}\" value=\"{{ valeur }}\">{% endmacro %}")
    env.add("form.html", "{% import \"forms.html\" as f %}{{ f.champ(\"titre\", v) }}{{ f.champ(\"mdp\", \"\", \"password\") }}")
    assert_eq(env.render("form.html", {"v": "\"x\""}), "<input type=\"text\" name=\"titre\" value=\"&quot;x&quot;\"><input type=\"password\" name=\"mdp\" value=\"\">")
    env.add("local.html", "{% macro b(t) %}<b>{{ t }}</b>{% endmacro %}{{ b('x') }}{{ b('<y>') }}")
    assert_eq(env.render("local.html"), "<b>x</b><b>&lt;y&gt;</b>")

func test_erreurs_avec_ligne():
    env := tpl.Environment()
    cas := [["a\n{% if x %}\nb", "endif"], ["a\nb\n{{ x | inconnu }}", "filtre inconnu"], ["{{ 'non fermée }}", "chaîne"], ["\n\n{% boucle %}", "instruction inconnue"], ["{{ x", "non fermée"]]
    for c in cas:
        try:
            env.from_string(c[0], "t.html").render({"x": 1})
            assert_true(false, "erreur attendue pour " + c[0])
        catch e:
            assert_eq(e.type, "TemplateError")
            assert_contains(e.message, c[1])
            assert_contains(e.message, "t.html:")
    try:
        env.from_string("l1\nl2\n{{ x.y + 1 }}", "calc.html").render({"x": {"y": null}})
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "calc.html:3")
    try:
        env.get("../secret.txt")
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "refusé")

func test_dossier_cache_et_rechargement():
    d := os.join(os.tmp_dir(), "alweb_tpl_" + str(os.pid()))
    os.mkdir_all(os.join(d, "partiels"))
    io.write_file(os.join(d, "page.html"), "v1 {% include \"partiels/x.html\" %}")
    io.write_file(os.join(d, "partiels/x.html"), "[{{ n }}]")
    env := tpl.Environment(d)
    assert_eq(env.render("page.html", {"n": 1}), "v1 [1]")
    t1 := env.get("page.html")
    assert_true(env.get("page.html") == t1)                 # gardé en mémoire
    time.sleep(1.1)
    io.write_file(os.join(d, "page.html"), "v2 {% include \"partiels/x.html\" %}")
    assert_eq(env.render("page.html", {"n": 1}), "v1 [1]")  # sans auto_reload : version en mémoire
    dev := tpl.Environment(d, true)
    assert_eq(dev.render("page.html", {"n": 2}), "v2 [2]")
    time.sleep(1.1)
    io.write_file(os.join(d, "page.html"), "v3")
    assert_eq(dev.render("page.html"), "v3")                # auto_reload : relu
    os.rmdir(d, true)

async func test_rendu_dans_l_application():
    d := os.join(os.tmp_dir(), "alweb_tpl_app_" + str(os.pid()))
    os.mkdir_all(d)
    io.write_file(os.join(d, "note.html"), "<h1>{{ note.titre }}</h1><a href=\"{{ url_for('note', {'id': note.id}) }}\">lien</a> {{ request.path() }} {{ app_name }} {{ visiteur }}")
    app := alweb_mod.App("blog")
    app.use_templates(d)

    @app.context_processor
    func visiteur(req):
        return {"visiteur": req.header("x-nom", "anonyme")}

    @app.get("/notes/{id:int}", {"name": "note"})
    func voir(req):
        return alweb_mod.render(req, "note.html", {"note": {"id": req.params["id"], "titre": "<Été>"}})

    r := await at.Client(app).get("/notes/4", {"headers": {"X-Nom": "Awa"}})
    assert_eq(r.status, 200)
    assert_contains(r.headers.get("content-type"), "text/html")
    assert_eq(r.text(), "<h1>&lt;Été&gt;</h1><a href=\"/notes/4\">lien</a> /notes/4 blog Awa")
    os.rmdir(d, true)

func test_tranches():
    ctx := {"l": [1, 2, 3, 4, 5], "t": "Bonjour", "a": Auteur("Awa Diallo")}
    assert_eq(rend("{{ l[1:3] }} {{ l[:2] }} {{ l[3:] }} {{ l[-2:] }} {{ l[:-4] }}", ctx), "[2, 3] [1, 2] [4, 5] [4, 5] [1]")
    assert_eq(rend("{{ t[0:3] }}|{{ t[10:20] }}|{{ a.nom[0:1] }}|{% for x in l[0:2] %}{{ x }};{% endfor %}", ctx), "Bon||A|1;2;")
    assert_eq(rend("{{ (l[1:])[0] }}{{ l[0:2] | length }}", ctx), "22")
