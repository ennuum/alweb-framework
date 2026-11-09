# alweb.pagination — pagination des API : par numéro de page (Link, X-Total-Count) ou par curseur opaque.
#
#   use alweb.pagination as pg
#
#   @app.get("/api/articles")
#   async func liste(req):
#       p := pg.params(req)                                    # ?page=2&per_page=20 -> {page, per_page, offset}
#       res := await ARTICLES.query().order_by("-id").paginate(db, p["page"], p["per_page"])
#       return pg.page(req, res)                               # {items, page, per_page, total, pages} + en-têtes
#
#   @app.get("/api/messages")
#   async func messages(req):
#       apres := pg.cursor(req)                                # valeur décodée du ?cursor=..., ou null
#       lignes := await charger(apres, 51)
#       return pg.cursor_page(req, lignes[0:50], lignes[49]["id"] if len(lignes) > 50 else null)
#
# En-tête Link (RFC 8288) : first, prev, next, last (page) ou next (curseur), avec les autres paramètres de la
# requête conservés. Paramètres invalides : 422 en JSON (comme la validation des routes).

from core use len, type, to_int
from collections use keys, append
use string as _s
use json as _json
use network.encoding as _enc
use web.http.response as _response
use web.url.form_url_encoding as _form
use alweb.errors as _err

# Page et taille demandées : {"page", "per_page", "offset"} ; per_page borné à max_per_page.
func params(req, per_page=20, max_per_page=100):
    page := _int_param(req, "page", 1)
    size := _int_param(req, "per_page", per_page)
    if page < 1 or size < 1:
        _err.abort(422, "page et per_page doivent être des entiers >= 1")
    if size > max_per_page:
        size = max_per_page
    return {"page": page, "per_page": size, "offset": (page - 1) * size}

# Réponse JSON d'une page. result : dict {items, page, per_page, total} (ORM paginate), ou items avec total,
# page et per_page donnés à part.
func page(req, result, total=null, page_no=null, per_page=null):
    d := result if type(result) == "dict" else {"items": result, "total": total, "page": page_no, "per_page": per_page}
    n := d["page"]
    size := d["per_page"]
    tot := d["total"]
    pages := (tot + size - 1) // size if size > 0 else 0
    body := {"items": d["items"], "page": n, "per_page": size, "total": tot, "pages": pages}
    r := _response.json(body)
    links := []
    if pages > 0:
        append(links, _link(req, {"page": 1, "per_page": size}, "first"))
        append(links, _link(req, {"page": pages, "per_page": size}, "last"))
    if n > 1:
        append(links, _link(req, {"page": (n - 1 if n - 1 <= pages else pages), "per_page": size}, "prev"))
    if n < pages:
        append(links, _link(req, {"page": n + 1, "per_page": size}, "next"))
    if len(links) > 0:
        r.headers.set("Link", _s.join(", ", links))
    r.headers.set("X-Total-Count", str(tot))
    return r

# Curseur opaque (JSON en base64url) : encode n'importe quelle valeur JSON (dernier id, [date, id]...).
func encode_cursor(value):
    return _strip_pad(_enc.base64_encode(_json.stringify(value), true))

func decode_cursor(text):
    try:
        pad := (4 - len(text) % 4) % 4
        return _json.parse(_enc.base64_decode(text + "=" * pad, true))
    catch e:
        _err.abort(422, "curseur invalide")

# Valeur du curseur de la requête (?cursor=...), décodée ; null pour la première page.
func cursor(req, name="cursor"):
    v := req.query_param(name)
    if v == null or v == "":
        return null
    return decode_cursor(v)

# Réponse JSON {items, next} : next est le curseur de la page suivante (null : fin), aussi dans Link rel="next".
func cursor_page(req, items, next_value, name="cursor"):
    nxt := encode_cursor(next_value) if next_value != null else null
    r := _response.json({"items": items, "next": nxt})
    if nxt != null:
        extra := {}
        extra[name] = nxt
        r.headers.set("Link", _link(req, extra, "next"))
    return r

func _int_param(req, name, default):
    v := req.query_param(name)
    if v == null or v == "":
        return default
    try:
        return to_int(v)
    catch e:
        _err.abort(422, name + " doit être un entier")

func _link(req, changes, rel):
    q := req.query().to_dict()
    for k in keys(changes):
        q[k] = str(changes[k])
    return "<" + req.path() + "?" + _form.encode(q) + ">; rel=\"" + rel + "\""

func _strip_pad(t):
    out := t
    while _s.ends_with(out, "="):
        out = out[0:len(out) - 1]
    return out
