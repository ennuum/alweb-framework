# Coût du rendu de gabarits.  alexc run bench/templates.al
use time
use alweb.templates as tpl

env := tpl.Environment()
env.add("base.html", "<!DOCTYPE html><title>{% block titre %}{% endblock %}</title><main>{% block contenu %}{% endblock %}</main>")
env.add("liste.html", "{% extends \"base.html\" %}{% block titre %}{{ titre }}{% endblock %}{% block contenu %}<table>\n{% for n in notes %}\n<tr class=\"{{ 'pair' if loop.index is even else 'impair' }}\"><td>{{ n.id }}</td><td>{{ n.titre | title }}</td><td>{{ n.texte | truncate(40) }}</td></tr>\n{% endfor %}\n</table>{% endblock %}")
for taille in [10, 100, 500]:
    notes := [{"id": i, "titre": "note numéro " + str(i), "texte": "un texte <un peu> long pour la note " + str(i)} for i in range(taille)]
    env.render("liste.html", {"titre": "Notes", "notes": notes})
    n := 20 if taille < 500 else 5
    t0 := time.monotonic()
    i := 0
    html := ""
    while i < n:
        html = env.render("liste.html", {"titre": "Notes", "notes": notes})
        i += 1
    dt := (time.monotonic() - t0) / n
    print(str(taille) + " lignes : " + str(dt * 1000.0) + " ms par rendu (" + str(len(html)) + " caractères)")
