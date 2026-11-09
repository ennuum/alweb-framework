# alweb.templates — gabarits HTML à la Jinja : expressions, filtres, conditions, boucles, héritage, inclusions,
# macros, échappement automatique.
#
#   use alweb.templates as tpl
#   env := tpl.Environment("templates")                    # dossier des gabarits
#   html := env.render("notes/liste.html", {"notes": notes, "titre": "Mes notes"})
#
# Syntaxe :
#   {{ expr }}                         valeur échappée (& < > " ') sauf si elle est sûre (filtre safe, macro)
#   {{ note.titre | upper }}           filtres, avec arguments : {{ texte | truncate(80) }}
#   {% if a %} … {% elif b %} … {% else %} … {% endif %}
#   {% for n in notes %} {{ loop.index }} … {% else %} (liste vide) {% endfor %}     loop : index, index0,
#                                      first, last, length, revindex ; for k, v in dict.items()
#   {% set total = notes | length %}
#   {% extends "base.html" %} … {% block contenu %} … {{ super() }} … {% endblock %}
#   {% include "partiels/pied.html" %}
#   {% macro champ(nom, valeur="") %} <input name="{{ nom }}" value="{{ valeur }}"> {% endmacro %}
#   {% import "formulaires.html" as f %}  puis  {{ f.champ("titre") }}
#   {# commentaire #}     {% raw %} {{ non interprété }} {% endraw %}     {{- … -}} / {%- … -%} : espaces retirés
#
# Expressions : littéraux ("texte", 'texte', 12, 1.5, true, false, null, [listes], {"dicts": 1}), variables,
# a.b (clé de dict ou champ d'objet), a[i], tranches a[1:3] / a[:5] / a[-2:], appels f(x), méthodes obj.m(x), opérateurs + - * / % ~ (concaténation
# de textes), == != < > <= >= in « not in », and or not, « x if cond else y ». Une variable absente vaut null et
# s'affiche vide ; a.b sur null vaut null.
#
# Une ligne vide suit rarement une balise {% %} : le premier saut de ligne après une balise est retiré (comme
# trim_blocks de Jinja). Erreurs : TemplateError « nom:ligne : message ».
#
# Environment(dossier, auto_reload) : gabarits analysés une fois puis gardés en mémoire ; auto_reload (mode
# développement) relit un gabarit dont le fichier a changé. env.globals / env.filters : ajouts (fonctions).
# Plusieurs dossiers : Environment(["templates", "themes/x/templates", ["components/", "themes/x/components"]]) ;
# consultés dans l'ordre (le premier qui a le fichier gagne : l'application peut remplacer une page d'un thème) ;
# [préfixe, dossier] : seuls les noms qui commencent par le préfixe y sont cherchés, sans lui
# (« components/nav.html » -> themes/x/components/nav.html). env.add_directory(dossier, préfixe, en_tête).
# Clé « _filters » du contexte : filtres propres à ce rendu, prioritaires (alweb.i18n : dates et nombres dans la
# langue de la requête).

from core use len, type, to_int, to_float, is_callable
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use reflection as _refl
use web.html.html_escape as _esc

# ================================================================ texte sûr

# Texte déjà sûr (HTML) : affiché tel quel par {{ }}.
class Markup:
    func init(text):
        self.text = text

    func __str__():
        return self.text

func markup(text):
    return Markup(str(text))

func escape(v):
    if isinstance(v, Markup):
        return v.text
    return _esc.escape_attribute(_to_text(v))

func _to_text(v):
    if v == null:
        return ""
    if type(v) == "str":
        return v
    if isinstance(v, Markup):
        return v.text
    if type(v) == "bool":
        return "true" if v else "false"
    return str(v)

# Position de sub dans s à partir de start, ou -1.
func _index_of(s, sub, start=0):
    if start >= len(s):
        return -1
    k := _s.find(s[start:len(s)], sub)
    return k + start if k >= 0 else -1

func _is_space(c):
    return c == " " or c == "\t" or c == "\n" or c == "\r"

func _trim_start(s):
    i := 0
    while i < len(s) and _is_space(s[i:i + 1]):
        i += 1
    return s[i:len(s)]

func _trim_end(s):
    j := len(s)
    while j > 0 and _is_space(s[j - 1:j]):
        j -= 1
    return s[0:j]

func _error(name, line, message):
    raise("TemplateError", str(name) + ":" + str(line) + " : " + message)

# ================================================================ lexeur

# Découpe le source en [genre, contenu, ligne] : genre "text", "var" ({{ }}), "tag" ({% %}).
func _lex(src, name):
    out := []
    i := 0
    n := len(src)
    line := 1
    trim_next := false
    while i < n:
        j := _find_open(src, i)
        if j < 0:
            text := src[i:n]
            if trim_next:
                text = _trim_start(text)
            if text != "":
                append(out, ["text", text, line])
            break
        text := src[i:j]
        opener := src[j:j + 2]
        strip_left := j + 2 < n and src[j + 2:j + 3] == "-"
        if trim_next:
            text = _trim_start(text)
        if strip_left:
            text = _trim_end(text)
        if text != "":
            append(out, ["text", text, line])
        line += _count_lines(src[i:j])
        closer := "}}" if opener == "{{" else ("%}" if opener == "{%" else "#}")
        start := j + (3 if strip_left else 2)
        k := _index_of(src, closer, start)
        if k < 0:
            _error(name, line, "balise « " + opener + " » non fermée")
        inner := src[start:k]
        strip_right := len(inner) > 0 and inner[len(inner) - 1:len(inner)] == "-"
        if strip_right:
            inner = inner[0:len(inner) - 1]
        tag_line := line
        line += _count_lines(src[j:k + 2])
        i = k + 2
        trim_next = strip_right
        if opener == "{#":
            continue
        inner = _s.trim(inner)
        if opener == "{{":
            append(out, ["var", inner, tag_line])
            continue
        if inner == "raw":
            e := _index_of(src, "{% endraw %}", i)
            if e < 0:
                _error(name, tag_line, "{% raw %} sans {% endraw %}")
            append(out, ["text", src[i:e], tag_line])
            line += _count_lines(src[i:e + 12])
            i = e + 12
            continue
        append(out, ["tag", inner, tag_line])
        if not strip_right and i < n and src[i:i + 1] == "\n":
            i += 1                       # trim_blocks : saut de ligne qui suit une balise
            line += 1
    return out

func _find_open(src, i):
    best := -1
    for o in ["{{", "{%", "{#"]:
        k := _index_of(src, o, i)
        if k >= 0 and (best < 0 or k < best):
            best = k
    return best

func _count_lines(s):
    return _s.count(s, "\n")

# ================================================================ expressions

const KEYWORDS := ["and", "or", "not", "in", "if", "else", "true", "false", "null", "none", "is"]

# Jetons d'une expression : [genre, valeur] ; genre : "name", "num", "str", "op", "end".
func _tokens(src, name, line):
    out := []
    i := 0
    n := len(src)
    while i < n:
        c := src[i:i + 1]
        if c == " " or c == "\t" or c == "\n" or c == "\r":
            i += 1
            continue
        if c == "\"" or c == "'":
            j := i + 1
            buf := ""
            while j < n and src[j:j + 1] != c:
                if src[j:j + 1] == "\\" and j + 1 < n:
                    e := src[j + 1:j + 2]
                    buf = buf + ("\n" if e == "n" else ("\t" if e == "t" else e))
                    j += 2
                    continue
                buf = buf + src[j:j + 1]
                j += 1
            if j >= n:
                _error(name, line, "chaîne non fermée dans « " + src + " »")
            append(out, ["str", buf])
            i = j + 1
            continue
        if _is_digit(c):
            j := i
            dot := false
            while j < n and (_is_digit(src[j:j + 1]) or (src[j:j + 1] == "." and not dot and j + 1 < n and _is_digit(src[j + 1:j + 2]))):
                if src[j:j + 1] == ".":
                    dot = true
                j += 1
            append(out, ["num", to_float(src[i:j]) if dot else to_int(src[i:j])])
            i = j
            continue
        if _is_ident_start(c):
            j := i
            while j < n and _is_ident(src[j:j + 1]):
                j += 1
            append(out, ["name", src[i:j]])
            i = j
            continue
        two := src[i:i + 2]
        if two in ["==", "!=", "<=", ">="]:
            append(out, ["op", two])
            i += 2
            continue
        if c in ["(", ")", "[", "]", "{", "}", ".", ",", ":", "|", "+", "-", "*", "/", "%", "~", "<", ">", "="]:
            append(out, ["op", c])
            i += 1
            continue
        _error(name, line, "caractère inattendu « " + c + " » dans « " + src + " »")
    append(out, ["end", null])
    return out

func _is_digit(c):
    return c >= "0" and c <= "9"

func _is_ident_start(c):
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"

func _is_ident(c):
    return _is_ident_start(c) or _is_digit(c)

class ExprParser:
    func init(src, name, line):
        self.toks = _tokens(src, name, line)
        self.pos = 0
        self.src = src
        self.name = name
        self.line = line

    func peek():
        return self.toks[self.pos]

    func next():
        t := self.toks[self.pos]
        self.pos += 1
        return t

    func is_op(v):
        t := self.peek()
        return t[0] == "op" and t[1] == v

    func is_name(v):
        t := self.peek()
        return t[0] == "name" and t[1] == v

    func expect_op(v):
        t := self.next()
        if t[0] != "op" or t[1] != v:
            self.fail("« " + v + " » attendu")
        return t

    func fail(message):
        _error(self.name, self.line, message + " dans « " + self.src + " »")

    func at_end():
        return self.peek()[0] == "end"

    # expression complète, y compris « a if c else b »
    func expression():
        e := self.or_expr()
        if self.is_name("if"):
            self.next()
            cond := self.or_expr()
            other := ["lit", null]
            if self.is_name("else"):
                self.next()
                other = self.expression()
            return ["cond", cond, e, other]
        return e

    func or_expr():
        e := self.and_expr()
        while self.is_name("or"):
            self.next()
            e = ["or", e, self.and_expr()]
        return e

    func and_expr():
        e := self.not_expr()
        while self.is_name("and"):
            self.next()
            e = ["and", e, self.not_expr()]
        return e

    func not_expr():
        if self.is_name("not"):
            self.next()
            return ["not", self.not_expr()]
        return self.compare()

    func compare():
        e := self.concat()
        while true:
            t := self.peek()
            if t[0] == "op" and t[1] in ["==", "!=", "<", ">", "<=", ">="]:
                self.next()
                e = ["bin", t[1], e, self.concat()]
            elif self.is_name("in"):
                self.next()
                e = ["bin", "in", e, self.concat()]
            elif self.is_name("not") and self.toks[self.pos + 1][0] == "name" and self.toks[self.pos + 1][1] == "in":
                self.next()
                self.next()
                e = ["not", ["bin", "in", e, self.concat()]]
            elif self.is_name("is"):
                self.next()
                neg := false
                if self.is_name("not"):
                    self.next()
                    neg = true
                test := self.next()
                if test[0] != "name":
                    self.fail("test attendu après « is »")
                r := ["test", test[1], e]
                e = ["not", r] if neg else r
            else:
                return e

    func concat():
        e := self.additive()
        while self.is_op("~"):
            self.next()
            e = ["bin", "~", e, self.additive()]
        return e

    func additive():
        e := self.term()
        while self.is_op("+") or self.is_op("-"):
            op := self.next()[1]
            e = ["bin", op, e, self.term()]
        return e

    func term():
        e := self.unary()
        while self.is_op("*") or self.is_op("/") or self.is_op("%"):
            op := self.next()[1]
            e = ["bin", op, e, self.unary()]
        return e

    func unary():
        if self.is_op("-"):
            self.next()
            return ["neg", self.unary()]
        return self.postfix()

    func postfix():
        e := self.primary()
        while true:
            if self.is_op("."):
                self.next()
                t := self.next()
                if t[0] != "name":
                    self.fail("nom attendu après « . »")
                e = ["attr", e, t[1]]
            elif self.is_op("["):
                self.next()
                lo := null
                if not self.is_op(":"):
                    lo = self.expression()
                if self.is_op(":"):
                    self.next()
                    hi := null
                    if not self.is_op("]"):
                        hi = self.expression()
                    self.expect_op("]")
                    e = ["slice", e, lo, hi]
                else:
                    self.expect_op("]")
                    e = ["index", e, lo]
            elif self.is_op("("):
                self.next()
                e = ["call", e, self.arguments()]
            elif self.is_op("|"):
                self.next()
                t := self.next()
                if t[0] != "name":
                    self.fail("nom de filtre attendu après « | »")
                args := []
                if self.is_op("("):
                    self.next()
                    args = self.arguments()
                e = ["filter", t[1], e, args]
            else:
                return e

    # arguments jusqu'à « ) » (déjà ouverte)
    func arguments():
        args := []
        if self.is_op(")"):
            self.next()
            return args
        while true:
            append(args, self.expression())
            if self.is_op(","):
                self.next()
                continue
            self.expect_op(")")
            return args

    func primary():
        t := self.next()
        if t[0] == "num" or t[0] == "str":
            return ["lit", t[1]]
        if t[0] == "name":
            v := t[1]
            if v == "true":
                return ["lit", true]
            if v == "false":
                return ["lit", false]
            if v == "null" or v == "none":
                return ["lit", null]
            return ["name", v]
        if t[0] == "op" and t[1] == "(":
            e := self.expression()
            self.expect_op(")")
            return e
        if t[0] == "op" and t[1] == "[":
            items := []
            while not self.is_op("]"):
                append(items, self.expression())
                if self.is_op(","):
                    self.next()
            self.next()
            return ["list", items]
        if t[0] == "op" and t[1] == "{":
            pairs := []
            while not self.is_op("}"):
                k := self.expression()
                self.expect_op(":")
                append(pairs, [k, self.expression()])
                if self.is_op(","):
                    self.next()
            self.next()
            return ["dict", pairs]
        self.fail("expression attendue")

func _parse_expr(src, name, line):
    p := ExprParser(src, name, line)
    e := p.expression()
    if not p.at_end():
        p.fail("texte inattendu après l'expression")
    return e

# ================================================================ instructions

# Nœuds : ["text", s] ["out", expr, ligne] ["if", [[cond, corps]...], sinon] ["for", vars, expr, corps, sinon, ligne]
# ["set", nom, expr] ["block", nom] ["include", expr, ligne] ["macro", nom, params, corps] ["import", expr, nom]
class Parser:
    func init(tokens, name):
        self.toks = tokens
        self.pos = 0
        self.name = name
        self.blocks = {}
        self.parent = null
        self.macros = {}

    func parse():
        body := self.body([])
        if self.pos < len(self.toks):
            t := self.toks[self.pos]
            _error(self.name, t[2], "balise inattendue « " + t[1] + " »")
        return body

    # Lit des nœuds jusqu'à une balise dont le premier mot est dans stops (laissée en place).
    func body(stops):
        out := []
        while self.pos < len(self.toks):
            t := self.toks[self.pos]
            if t[0] == "text":
                append(out, ["text", t[1]])
                self.pos += 1
                continue
            if t[0] == "var":
                append(out, ["out", _parse_expr(t[1], self.name, t[2]), t[2]])
                self.pos += 1
                continue
            word := _first_word(t[1])
            if word in stops:
                return out
            self.pos += 1
            append(out, self.statement(word, _rest(t[1]), t[2]))
        if len(stops) > 0:
            _error(self.name, self.toks[len(self.toks) - 1][2] if len(self.toks) > 0 else 1, "« {% " + stops[len(stops) - 1] + " %} » manquant")
        return out

    func expect_end(word, line):
        if self.pos >= len(self.toks) or _first_word(self.toks[self.pos][1]) != word:
            _error(self.name, line, "« {% " + word + " %} » attendu")
        self.pos += 1

    func statement(word, rest, line):
        if word == "if":
            branches := [[_parse_expr(rest, self.name, line), self.body(["elif", "else", "endif"])]]
            other := null
            while true:
                t := self.toks[self.pos]
                w := _first_word(t[1])
                self.pos += 1
                if w == "elif":
                    append(branches, [_parse_expr(_rest(t[1]), self.name, t[2]), self.body(["elif", "else", "endif"])])
                elif w == "else":
                    other = self.body(["endif"])
                    self.expect_end("endif", line)
                    return ["if", branches, other]
                else:
                    return ["if", branches, other]
        if word == "for":
            k := _index_of(rest, " in ")
            if k < 0:
                _error(self.name, line, "« for x in liste » attendu")
            names := []
            for v in _s.split(rest[0:k], ","):
                append(names, _s.trim(v))
            seq := _parse_expr(rest[k + 4:len(rest)], self.name, line)
            body := self.body(["else", "endfor"])
            other := null
            t := self.toks[self.pos]
            self.pos += 1
            if _first_word(t[1]) == "else":
                other = self.body(["endfor"])
                self.expect_end("endfor", line)
            return ["for", names, seq, body, other, line]
        if word == "set":
            k := _index_of(rest, "=")
            if k < 0:
                _error(self.name, line, "« set nom = valeur » attendu")
            return ["set", _s.trim(rest[0:k]), _parse_expr(rest[k + 1:len(rest)], self.name, line)]
        if word == "block":
            bname := _s.trim(rest)
            body := self.body(["endblock"])
            self.pos += 1
            if bname in self.blocks:
                _error(self.name, line, "bloc « " + bname + " » défini deux fois")
            self.blocks[bname] = body
            return ["block", bname]
        if word == "extends":
            if self.parent != null:
                _error(self.name, line, "un seul « extends » par gabarit")
            self.parent = _parse_expr(rest, self.name, line)
            return ["text", ""]
        if word == "include":
            return ["include", _parse_expr(rest, self.name, line), line]
        if word == "macro":
            k := _index_of(rest, "(")
            if k < 0 or rest[len(rest) - 1:len(rest)] != ")":
                _error(self.name, line, "« macro nom(paramètres) » attendu")
            mname := _s.trim(rest[0:k])
            params := []
            inner := _s.trim(rest[k + 1:len(rest) - 1])
            if inner != "":
                for part in _split_top(inner):
                    eq := _index_of(part, "=")
                    if eq >= 0:
                        append(params, [_s.trim(part[0:eq]), _parse_expr(part[eq + 1:len(part)], self.name, line)])
                    else:
                        append(params, [_s.trim(part), null])
            body := self.body(["endmacro"])
            self.pos += 1
            self.macros[mname] = [params, body]
            return ["macro", mname, params, body]
        if word == "import":
            k := _index_of(rest, " as ")
            if k < 0:
                _error(self.name, line, "« import \"fichier\" as nom » attendu")
            return ["import", _parse_expr(rest[0:k], self.name, line), _s.trim(rest[k + 4:len(rest)]), line]
        _error(self.name, line, "instruction inconnue « " + word + " »")

func _first_word(s):
    k := _index_of(s, " ")
    return s if k < 0 else s[0:k]

func _rest(s):
    k := _index_of(s, " ")
    return "" if k < 0 else _s.trim(s[k + 1:len(s)])

# Découpe « a, b="x, y", c » aux virgules de premier niveau.
func _split_top(s):
    out := []
    depth := 0
    quote := ""
    cur := ""
    for ch in s:
        c := str(ch)
        if quote != "":
            if c == quote:
                quote = ""
        elif c == "\"" or c == "'":
            quote = c
        elif c == "(" or c == "[" or c == "{":
            depth += 1
        elif c == ")" or c == "]" or c == "}":
            depth -= 1
        elif c == "," and depth == 0:
            append(out, cur)
            cur = ""
            continue
        cur = cur + c
    if _s.trim(cur) != "":
        append(out, cur)
    return out

# ================================================================ gabarit compilé

class Template:
    func init(env, name, source):
        self.env = env
        self.name = name
        p := Parser(_lex(source, name), name)
        self.body = p.parse()
        self.blocks = p.blocks
        self.parent = p.parent
        self.macros = p.macros
        # compilation en fermetures (voir « compilation »)
        self.cbody = _compile_nodes(self, self.body)
        self.cprelude = []
        for node in self.body:
            if node[0] == "set" or node[0] == "import":
                append(self.cprelude, _compile_node(self, node))
        self.cblocks = {}
        for k in keys(self.blocks):
            self.cblocks[k] = _compile_nodes(self, self.blocks[k])
        self.cmacros = {}
        for k in keys(self.macros):
            m := self.macros[k]
            params := []
            for prm in m[0]:
                append(params, [prm[0], _compile_expr(self, prm[1], 0) if prm[1] != null else null])
            self.cmacros[k] = [params, _compile_nodes(self, m[1])]
        self.cparent = _compile_expr(self, self.parent, 1) if self.parent != null else null

    # Rend le gabarit avec un dict de variables ; rend une chaîne.
    func render(context=null):
        ctx := Context(self.env, self.name)
        ctx.push(self.env.globals)
        ctx.push(context if context != null else {})
        if context != null and "_filters" in context:
            ctx.filters = context["_filters"]
        out := []
        _render_template(self, ctx, out, {})
        return _s.join("", out)

class Context:
    func init(env, name):
        self.env = env
        self.name = name
        self.scopes = []
        self.blocks = {}                 # nom -> pile [enfant, parent...] de [gabarit, corps]
        self.filters = null              # filtres propres à ce rendu (clé « _filters » du contexte : langue de la requête)

    func push(d):
        append(self.scopes, d)

    func pop():
        self.scopes = self.scopes[0:len(self.scopes) - 1]

    func lookup(name):
        i := len(self.scopes) - 1
        while i >= 0:
            s := self.scopes[i]
            if name in s:
                return s[name]
            i -= 1
        if name in self.env.globals:
            return self.env.globals[name]
        return null

    func set(name, value):
        self.scopes[len(self.scopes) - 1][name] = value

# Rend un gabarit en tenant compte de l'héritage : les blocs de l'enfant remplacent ceux du parent.
func _render_template(t, ctx, out, child_blocks):
    blocks := {}
    for k in keys(child_blocks):
        blocks[k] = child_blocks[k]
    for k in keys(t.cblocks):
        chain := blocks[k] if k in blocks else []
        blocks[k] = chain + [[t, t.cblocks[k]]]
    for k in keys(t.cmacros):
        ctx.scopes[0][k] = _macro_value(t, ctx, k)
    if t.cparent != null:
        # le corps de l'enfant n'est pas rendu (sauf ses « set », imports et macros, pour les blocs)
        _run(t.cprelude, ctx, out)
        pname := t.cparent(ctx)
        parent := t.env.get(pname)
        _render_template(parent, ctx, out, blocks)
        return
    saved := ctx.blocks
    ctx.blocks = blocks
    _run(t.cbody, ctx, out)
    ctx.blocks = saved

# ================================================================ compilation
#
# Chaque nœud de l'arbre devient une fermeture (ctx, out) et chaque expression une fermeture (ctx) -> valeur,
# une fois, au chargement du gabarit : le rendu n'examine plus le type des nœuds ni les opérateurs.

func _run(fns, ctx, out):
    for f in fns:
        f(ctx, out)

func _compile_nodes(t, nodes):
    out := []
    for node in nodes:
        f := _compile_node(t, node)
        if f != null:
            append(out, f)
    return out

func _compile_node(t, node):
    kind := node[0]
    if kind == "text":
        txt := node[1]
        if txt == "":
            return null
        return (ctx, out) => append(out, txt)
    if kind == "out":
        ex := _compile_expr(t, node[1], node[2])
        line := node[2]
        if t.env.autoescape:
            return (ctx, out) => _n_out_escaped(t, ex, ctx, out, line)
        return (ctx, out) => _n_out_raw(t, ex, ctx, out, line)
    if kind == "if":
        branches := []
        for br in node[1]:
            append(branches, [_compile_expr(t, br[0], 0), _compile_nodes(t, br[1])])
        other := _compile_nodes(t, node[2]) if node[2] != null else null
        return (ctx, out) => _n_if(branches, other, ctx, out)
    if kind == "for":
        seq := _compile_expr(t, node[2], node[5])
        body := _compile_nodes(t, node[3])
        other := _compile_nodes(t, node[4]) if node[4] != null else null
        names := node[1]
        return (ctx, out) => _n_for(names, seq, body, other, ctx, out)
    if kind == "set":
        name := node[1]
        ex := _compile_expr(t, node[2], 0)
        return (ctx, out) => ctx.set(name, ex(ctx))
    if kind == "block":
        bname := node[1]
        return (ctx, out) => _render_block(bname, 0, ctx, out, t)
    if kind == "include":
        ex := _compile_expr(t, node[1], node[2])
        return (ctx, out) => _n_include(t, ex, ctx, out)
    if kind == "macro":
        mname := node[1]
        return (ctx, out) => ctx.set(mname, _macro_value(t, ctx, mname))
    if kind == "import":
        ex := _compile_expr(t, node[1], node[3])
        alias := node[2]
        return (ctx, out) => _n_import(t, ex, alias, ctx)
    _error(t.name, 0, "nœud inconnu « " + str(kind) + " »")

func _n_out_escaped(t, ex, ctx, out, line):
    v := null
    try:
        v = ex(ctx)
    catch e:
        _rethrow(t, line, e)
    if type(v) == "str":
        append(out, _escape_str(v))
    else:
        append(out, escape(v))

# Échappement HTML (texte et attributs) d'une str, sans appel intermédiaire : la plupart des valeurs n'ont rien
# à échapper.
func _escape_str(t):
    if not (_s.contains(t, "&") or _s.contains(t, "<") or _s.contains(t, ">") or _s.contains(t, "\"") or _s.contains(t, "'")):
        return t
    return _esc.escape_attribute(t)

func _n_out_raw(t, ex, ctx, out, line):
    v := null
    try:
        v = ex(ctx)
    catch e:
        _rethrow(t, line, e)
    append(out, _to_text(v))

func _n_if(branches, other, ctx, out):
    for br in branches:
        if _truthy(br[0](ctx)):
            _run(br[1], ctx, out)
            return
    if other != null:
        _run(other, ctx, out)

func _n_for(names, seq, body, other, ctx, out):
    items := _iterable(seq(ctx))
    n := len(items)
    if n == 0:
        if other != null:
            _run(other, ctx, out)
        return
    single := len(names) == 1
    first_name := names[0]
    i := 0
    scope := {}
    ctx.push(scope)
    for item in items:
        if single:
            scope[first_name] = item
        else:
            j := 0
            while j < len(names):
                scope[names[j]] = item[j]
                j += 1
        scope["loop"] = {"index": i + 1, "index0": i, "first": i == 0, "last": i == n - 1, "length": n, "revindex": n - i}
        for f in body:
            f(ctx, out)
        i += 1
    ctx.pop()

func _n_include(t, ex, ctx, out):
    inc := t.env.get(ex(ctx))
    ctx.push({})
    _run(inc.cbody, ctx, out)
    ctx.pop()

func _n_import(t, ex, alias, ctx):
    other := t.env.get(ex(ctx))
    ns := {}
    for mname in keys(other.cmacros):
        ns[mname] = _macro_value(other, ctx, mname)
    ctx.set(alias, ns)

func _render_block(name, level, ctx, out, t):
    chain := ctx.blocks[name] if name in ctx.blocks else null
    if chain == null or level >= len(chain):
        return
    entry := chain[level]
    ctx.push({"super": () => markup(_block_text(name, level + 1, ctx, entry[0]))})
    _run(entry[1], ctx, out)
    ctx.pop()

func _block_text(name, level, ctx, t):
    out := []
    _render_block(name, level, ctx, out, t)
    return _s.join("", out)

func _iterable(v):
    if v == null:
        return []
    tv := type(v)
    if tv == "list" or tv == "tuple":
        return v
    if tv == "dict":
        return keys(v)
    if tv == "str":
        out := []
        for ch in v:
            append(out, str(ch))
        return out
    out := []
    for x in v:
        append(out, x)
    return out

# Une macro devient une fonction qui rend du texte sûr.
func _macro_value(t, ctx, name):
    m := t.cmacros[name]
    return (*args) => _call_macro(t, ctx, m, args)

func _call_macro(t, ctx, m, args):
    params := m[0]
    scope := {}
    i := 0
    while i < len(params):
        p := params[i]
        if i < len(args):
            scope[p[0]] = args[i]
        else:
            scope[p[0]] = p[1](ctx) if p[1] != null else null
        i += 1
    ctx.push(scope)
    out := []
    _run(m[1], ctx, out)
    ctx.pop()
    return markup(_s.join("", out))

# ---------------------------------------------------------------- expressions

func _compile_expr(t, e, line):
    k := e[0]
    if k == "lit":
        v := e[1]
        return (ctx) => v
    if k == "name":
        name := e[1]
        return (ctx) => ctx.lookup(name)
    if k == "attr":
        o := _compile_expr(t, e[1], line)
        name := e[2]
        return (ctx) => _get_attr(o(ctx), name)
    if k == "index":
        o := _compile_expr(t, e[1], line)
        key := _compile_expr(t, e[2], line)
        return (ctx) => _get_index(o(ctx), key(ctx))
    if k == "slice":
        o := _compile_expr(t, e[1], line)
        lo := _compile_expr(t, e[2], line) if e[2] != null else (ctx) => null
        hi := _compile_expr(t, e[3], line) if e[3] != null else (ctx) => null
        return (ctx) => _get_slice(o(ctx), lo(ctx), hi(ctx))
    if k == "filter":
        fname := e[1]
        base := _compile_expr(t, e[2], line)
        args := []
        for a in e[3]:
            append(args, _compile_expr(t, a, line))
        if len(args) == 0:
            return (ctx) => _filter(t, fname, line, ctx)(base(ctx))
        if len(args) == 1:
            a0 := args[0]
            return (ctx) => _filter(t, fname, line, ctx)(base(ctx), a0(ctx))
        return (ctx) => _apply_filter(t, fname, line, base(ctx), [a(ctx) for a in args], ctx)
    if k == "call":
        args := []
        for a in e[2]:
            append(args, _compile_expr(t, a, line))
        target := e[1]
        if target[0] == "attr":
            obj := _compile_expr(t, target[1], line)
            mname := target[2]
            return (ctx) => _call_method(t, obj(ctx), mname, [a(ctx) for a in args], line)
        fn := _compile_expr(t, target, line)
        return (ctx) => _call_value(t, fn(ctx), [a(ctx) for a in args], line)
    if k == "and":
        a := _compile_expr(t, e[1], line)
        b := _compile_expr(t, e[2], line)
        return (ctx) => _and(a, b, ctx)
    if k == "or":
        a := _compile_expr(t, e[1], line)
        b := _compile_expr(t, e[2], line)
        return (ctx) => _or(a, b, ctx)
    if k == "not":
        a := _compile_expr(t, e[1], line)
        return (ctx) => not _truthy(a(ctx))
    if k == "neg":
        a := _compile_expr(t, e[1], line)
        return (ctx) => -a(ctx)
    if k == "cond":
        c := _compile_expr(t, e[1], line)
        a := _compile_expr(t, e[2], line)
        b := _compile_expr(t, e[3], line)
        return (ctx) => a(ctx) if _truthy(c(ctx)) else b(ctx)
    if k == "list":
        items := []
        for x in e[1]:
            append(items, _compile_expr(t, x, line))
        return (ctx) => [f(ctx) for f in items]
    if k == "dict":
        pairs := []
        for p in e[1]:
            append(pairs, [_compile_expr(t, p[0], line), _compile_expr(t, p[1], line)])
        return (ctx) => _make_dict(pairs, ctx)
    if k == "test":
        v := _compile_expr(t, e[2], line)
        test := e[1]
        if test == "defined":
            return (ctx) => v(ctx) != null
        if test == "none" or test == "null":
            return (ctx) => v(ctx) == null
        if test == "even":
            return (ctx) => v(ctx) % 2 == 0
        if test == "odd":
            return (ctx) => v(ctx) % 2 == 1
        _error(t.name, line, "test inconnu « " + test + " »")
    if k == "bin":
        op := e[1]
        a := _compile_expr(t, e[2], line)
        b := _compile_expr(t, e[3], line)
        if op == "~":
            return (ctx) => _to_text(a(ctx)) + _to_text(b(ctx))
        if op == "==":
            return (ctx) => a(ctx) == b(ctx)
        if op == "!=":
            return (ctx) => a(ctx) != b(ctx)
        if not (op in BINARY_OPS):
            _error(t.name, line, "opérateur inconnu « " + op + " »")
        return (ctx) => _binary(t, op, a(ctx), b(ctx), line)
    _error(t.name, line, "expression invalide")

const BINARY_OPS := ["in", "<", ">", "<=", ">=", "+", "-", "*", "/", "%"]

# Filtre cherché au rendu (un filtre ajouté à l'environnement après le chargement du gabarit est vu) ; ceux du
# contexte (« _filters », par exemple les dates et nombres dans la langue de la requête) passent avant.
func _filter(t, name, line, ctx=null):
    if ctx != null and ctx.filters != null and name in ctx.filters:
        return ctx.filters[name]
    fs := t.env.filters
    if not (name in fs):
        _error(t.name, line, "filtre inconnu « " + name + " »")
    return fs[name]

func _apply_filter(t, fname, line, v, rest, ctx=null):
    return _filter(t, fname, line, ctx)(*([v] + rest))

func _call_method(t, obj, mname, args, line):
    if obj != null and type(obj) != "dict" and _refl.has_method(obj, mname):
        return _refl.bound(obj, mname)(*args)
    return _call_value(t, _get_attr(obj, mname), args, line)

func _call_value(t, fn, args, line):
    if fn == null or not is_callable(fn):
        _error(t.name, line, "appel d'une valeur qui n'est pas une fonction")
    return fn(*args)

func _and(a, b, ctx):
    x := a(ctx)
    return b(ctx) if _truthy(x) else x

func _or(a, b, ctx):
    x := a(ctx)
    return x if _truthy(x) else b(ctx)

func _make_dict(pairs, ctx):
    d := {}
    for p in pairs:
        d[p[0](ctx)] = p[1](ctx)
    return d

func _rethrow(t, line, e):
    if e.type == "TemplateError":
        raise(e.type, e.message)
    _error(t.name, line, str(e.type) + " : " + str(e.message))

# ================================================================ évaluation

func _truthy(v):
    if v == null or v == false or v == 0 or v == "":
        return false
    tv := type(v)
    if (tv == "list" or tv == "dict" or tv == "tuple") and len(v) == 0:
        return false
    if isinstance(v, Markup):
        return v.text != ""
    return true

func _binary(t, op, a, b, line):
    if op == "~":
        return _to_text(a) + _to_text(b)
    if op == "==":
        return a == b
    if op == "!=":
        return a != b
    if op == "in":
        if b == null:
            return false
        if type(b) == "str":
            return _s.contains(b, _to_text(a))
        return a in b
    if a == null or b == null:
        _error(t.name, line, "opération « " + op + " » sur une valeur nulle")
    if op == "<":
        return a < b
    if op == ">":
        return a > b
    if op == "<=":
        return a <= b
    if op == ">=":
        return a >= b
    if op == "+":
        return a + b
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "/":
        return a / b
    if op == "%":
        return a % b
    _error(t.name, line, "opérateur inconnu « " + op + " »")

func _get_attr(obj, name):
    if obj == null:
        return null
    tv := type(obj)
    if tv == "dict":
        if name in obj:                  # une clé l'emporte sur les méthodes items / keys / values
            return obj[name]
        if name == "items":
            return () => [[k, obj[k]] for k in keys(obj)]
        if name == "keys":
            return () => keys(obj)
        if name == "values":
            return () => [obj[k] for k in keys(obj)]
        return obj[name] if name in obj else null
    if tv == "list" or tv == "str" or tv == "tuple":
        if name == "length":
            return len(obj)
        return null
    if _refl.has_field(obj, name):
        return _refl.get(obj, name)
    if _refl.has_method(obj, name):
        return _refl.bound(obj, name)
    return null

func _get_index(obj, key):
    if obj == null:
        return null
    tv := type(obj)
    if tv == "dict":
        return obj[key] if key in obj else null
    if tv == "list" or tv == "tuple" or tv == "str":
        n := len(obj)
        i := key if key >= 0 else n + key
        if i < 0 or i >= n:
            return null
        return obj[i] if tv != "str" else obj[i:i + 1]
    return _get_attr(obj, str(key))

# Tranche [début:fin] d'une liste ou d'un texte (bornes facultatives, négatives depuis la fin, comme Python).
func _get_slice(obj, lo, hi):
    if obj == null:
        return null
    tv := type(obj)
    if tv != "list" and tv != "tuple" and tv != "str":
        return null
    n := len(obj)
    a := 0 if lo == null else to_int(lo)
    b := n if hi == null else to_int(hi)
    if a < 0:
        a = n + a if n + a > 0 else 0
    if b < 0:
        b = n + b if n + b > 0 else 0
    if a > n:
        a = n
    if b > n:
        b = n
    if b < a:
        b = a
    return obj[a:b]

# ================================================================ filtres

func _f_default(v, d="", boolean=false):
    if v == null or (boolean and not _truthy(v)):
        return d
    return v

func _f_length(v):
    return len(v) if v != null else 0

func _f_join(v, sep=""):
    parts := []
    for x in _iterable(v):
        append(parts, escape(x))
    return markup(_s.join(escape(sep), parts))

func _f_truncate(v, n=255, end="…"):
    s := _to_text(v)
    if len(s) <= n:
        return s
    return _trim_end(s[0:n]) + end

# Majuscule en tête de chaque mot (aussi après « - » et « ' »), le reste en minuscules.
func _f_title(v):
    t := _s.title(_to_text(v))
    for sep in ["-", "'"]:
        if _s.contains(t, sep):
            parts := _s.split(t, sep)
            fixed := [parts[0]]
            i := 1
            while i < len(parts):
                p := parts[i]
                append(fixed, _s.upper(p[0:1]) + p[1:len(p)])
                i += 1
            t = _s.join(sep, fixed)
    return t

func _f_capitalize(v):
    s := _to_text(v)
    return _s.upper(s[0:1]) + _s.lower(s[1:len(s)]) if len(s) > 0 else s

func _f_nl2br(v):
    return markup(_s.replace(escape(v), "\n", "<br>\n"))

func _f_first(v):
    items := _iterable(v)
    return items[0] if len(items) > 0 else null

func _f_last(v):
    items := _iterable(v)
    return items[len(items) - 1] if len(items) > 0 else null

func _f_round(v, digits=0):
    if v == null:
        return null
    f := 1
    i := 0
    while i < digits:
        f = f * 10
        i += 1
    r := to_int(v * f + (0.5 if v >= 0 else -0.5))
    return r / (f * 1.0) if digits > 0 else r

func _f_urlencode(v):
    out := ""
    text := _to_text(v)
    i := 0
    n := _s.byte_len(text)
    while i < n:
        b := _s.byte_at(text, i)
        i += 1
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 95 or b == 46 or b == 126:
            out = out + _s.byte_char(b)
        else:
            h := "0123456789ABCDEF"
            out = out + "%" + h[b // 16:b // 16 + 1] + h[b % 16:b % 16 + 1]
    return out

func _f_tojson(v):
    # sûr dans un <script> : < > & échappés en \u
    s := _json.stringify(v)
    s = _s.replace(_s.replace(_s.replace(s, "<", "\\u003c"), ">", "\\u003e"), "&", "\\u0026")
    return markup(s)

func _f_sort(v, attribute=null, reverse=false):
    items := [x for x in _iterable(v)]
    n := len(items)
    i := 1
    while i < n:                         # tri par insertion (stable)
        x := items[i]
        kx := _get_attr(x, attribute) if attribute != null else x
        j := i - 1
        while j >= 0:
            kj := _get_attr(items[j], attribute) if attribute != null else items[j]
            if (kj > kx) != reverse and kj != kx:
                items[j + 1] = items[j]
                j -= 1
            else:
                break
        items[j + 1] = x
        i += 1
    return items

func default_filters():
    return {"escape": (v) => markup(escape(v)), "e": (v) => markup(escape(v)), "safe": (v) => markup(_to_text(v)),
            "upper": (v) => _s.upper(_to_text(v)), "lower": (v) => _s.lower(_to_text(v)), "trim": (v) => _s.trim(_to_text(v)),
            "title": _f_title, "capitalize": _f_capitalize, "length": _f_length, "count": _f_length, "default": _f_default,
            "d": _f_default, "join": _f_join, "truncate": _f_truncate, "replace": (v, a, b) => _s.replace(_to_text(v), a, b),
            "nl2br": _f_nl2br, "first": _f_first, "last": _f_last, "round": _f_round, "int": (v) => to_int(v),
            "float": (v) => to_float(v), "string": (v) => _to_text(v), "urlencode": _f_urlencode, "tojson": _f_tojson,
            "sort": _f_sort, "reverse": _reversed, "list": (v) => [x for x in _iterable(v)]}

func _reversed(v):
    items := _iterable(v)
    out := []
    i := len(items) - 1
    while i >= 0:
        append(out, items[i])
        i -= 1
    return out

# ================================================================ environnement

class Environment:
    # directory : dossier des gabarits (null : gabarits en mémoire seulement, add) ; auto_reload : relire un
    # gabarit dont le fichier a changé (développement).
    func init(directory=null, auto_reload=false, autoescape=true):
        self.directories = []            # [[préfixe, dossier], ...] dans l'ordre de recherche
        if type(directory) == "list":
            for d in directory:
                if type(d) == "list":
                    self.add_directory(d[1], d[0])
                else:
                    self.add_directory(d)
        elif directory != null:
            self.add_directory(directory)
        self.directory = self.directories[0][1] if len(self.directories) > 0 else null
        self.auto_reload = auto_reload
        self.autoescape = autoescape
        self.cache = {}                  # nom -> [Template, date de modification]
        self.sources = {}                # gabarits en mémoire (add)
        self.globals = {"range": _range}
        self.filters = default_filters()

    # Ajoute un dossier de gabarits (à la fin, ou en tête si first) ; prefix : voir l'en-tête.
    func add_directory(directory, prefix="", first=false):
        if prefix != "" and not _s.ends_with(prefix, "/"):
            prefix = prefix + "/"
        e := [prefix, directory]
        self.directories = [e] + self.directories if first else self.directories + [e]
        if len(self.directories) == 1 or first:
            self.directory = self.directories[0][1]
        self.cache = {}
        return self

    # Chemin du fichier d'un gabarit (premier dossier qui l'a), ou null.
    func path_of(name):
        for e in self.directories:
            if e[0] == "" or _s.starts_with(name, e[0]):
                p := _os.join(e[1], name[len(e[0]):len(name)])
                if _os.isfile(p):
                    return p
        return null

    # Le gabarit existe-t-il (en mémoire ou dans un dossier) ?
    func exists(name):
        return name in self.sources or self.path_of(name) != null

    # Ajoute un gabarit en mémoire (tests, gabarits fournis par une bibliothèque).
    func add(name, source):
        self.sources[name] = source
        self.cache = _without(self.cache, name)
        return self

    func from_string(source, name="<texte>"):
        return Template(self, name, source)

    func get(name):
        if type(name) != "str" or name == "" or _s.contains(name, "..") or _s.starts_with(name, "/") or _s.contains(name, "\\"):
            raise("TemplateError", "nom de gabarit refusé : " + str(name))
        if name in self.sources:
            if not (name in self.cache):
                self.cache[name] = [Template(self, name, self.sources[name]), 0, null]
            return self.cache[name][0]
        if len(self.directories) == 0:
            raise("TemplateError", "gabarit introuvable : " + name)
        if name in self.cache and not self.auto_reload:
            return self.cache[name][0]
        path := self.path_of(name)
        if path == null:
            raise("TemplateError", "gabarit introuvable : " + name + " (dans " + _s.join(", ", [(e[0] + " -> " if e[0] != "" else "") + e[1] for e in self.directories]) + ")")
        m := _os.mtime(path)
        if name in self.cache and self.cache[name][1] == m and self.cache[name][2] == path:
            return self.cache[name][0]
        t := Template(self, name, _io.read_file(path))
        self.cache[name] = [t, m, path]
        return t

    func render(name, context=null):
        return self.get(name).render(context)

func _range(a, b=null, step=1):
    start := 0 if b == null else a
    stop := a if b == null else b
    out := []
    i := start
    while (step > 0 and i < stop) or (step < 0 and i > stop):
        append(out, i)
        i += step
    return out

func _without(d, key):
    out := {}
    for k in keys(d):
        if k != key:
            out[k] = d[k]
    return out
