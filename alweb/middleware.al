# alweb.middleware — intergiciels async prêts à l'emploi.
#
#   use alweb
#   use alweb.middleware as mw
#   app.middleware([mw.request_id(), mw.timing(), mw.logger(), mw.security_headers(), mw.cors(["https://exemple.org"])])
#
# Écrire le sien : une fonction (req, suivant) dont `await suivant(req)` rend la Response de la suite.
#
#   async func chrono(req, suivant):
#       t0 := time.monotonic()
#       r := await suivant(req)
#       r.headers.set("X-Duree", str(time.monotonic() - t0))
#       return r
#   app.middleware(chrono)
#
# Ces versions remplacent, dans alweb, celles de web.server.request_dispatch, qui sont synchrones et ne
# peuvent pas attendre la réponse d'un gestionnaire async.

from core use len, to_int
from collections use keys, append
use string as _s
use time as _time
use json as _json
use io as _io
use web.http.response as _response
use web.http.headers as _headers
use web.http.header_value as _hv
use web.server.request_dispatch as _rd
use alweb.chain as _chain

_counter := [0]

# ---------------------------------------------------------------- identifiant de requête

# X-Request-Id : repris du client s'il est sûr, sinon généré ; rangé dans req.state["request_id"] et renvoyé.
func request_id(header="X-Request-Id"):
    return _chain.Hook((req) => _request_id_before(req, header), (req, r) => _request_id_after(req, r, header))

func _request_id_after(req, r, header):
    r.headers.set(header, req.state["request_id"])
    return r

func _request_id_before(req, header):
    id := req.headers.get(header)
    if id == null or len(id) > 128 or not _hv.is_token(id):
        _counter[0] = _counter[0] + 1
        id = str(to_int(_time.time() * 1000)) + "-" + str(_counter[0])
    req.state["request_id"] = id
    return null

# ---------------------------------------------------------------- durée

# En-tête Server-Timing (durée de traitement, en millisecondes) ; aussi dans req.state["duration_ms"].
func timing():
    return _chain.Hook(_timing_before, _timing_after)

func _timing_before(req):
    req.state["_t0"] = _time.monotonic()
    return null

func _timing_after(req, r):
    ms := (_time.monotonic() - req.state["_t0"]) * 1000.0
    req.state["duration_ms"] = ms
    r.headers.set("Server-Timing", "app;dur=" + str(to_int(ms * 100) / 100.0))
    return r

# ---------------------------------------------------------------- journal

# Journal d'accès, une ligne par requête. format : "text" (proche du Common Log Format) ou "json" (une ligne JSON
# par requête : horodatage, méthode, chemin, statut, durée, taille, identifiant de requête). sink(ligne) : sortie
# standard par défaut, vidée à chaque ligne.
func logger(format="text", sink=null):
    out := sink if sink != null else _print_now
    return _chain.Hook(_logger_before, (req, r) => _logger_after(req, r, format, out))

# print puis vidage : la ligne part tout de suite même si la sortie est un fichier ou un tube (systemd, Docker).
func _print_now(line):
    print(line)
    _io.flush()

func _logger_before(req):
    req.state["_log_t0"] = _time.monotonic()
    return null

func _logger_after(req, r, format, out):
    ms := to_int((_time.monotonic() - req.state["_log_t0"]) * 1000)
    who := req.state["client_ip"] if "client_ip" in req.state and req.state["client_ip"] != null else "-"
    size := r.body_size()
    if format == "json":
        rec := {"ts": _time.time(), "ip": who, "method": req.method, "path": req.path(), "status": r.status, "ms": ms, "bytes": size}
        if "request_id" in req.state:
            rec["request_id"] = req.state["request_id"]
        out(_json.stringify(rec))
    else:
        out(str(who) + " \"" + req.method + " " + req.target + " " + req.version + "\" " + str(r.status) + " " + (str(size) if size != null else "-") + " " + str(ms) + "ms")
    return r

# ---------------------------------------------------------------- sécurité

# En-têtes de sécurité recommandés (ceux déjà posés par le gestionnaire sont gardés) ; HSTS en HTTPS seulement.
# Les valeurs sont validées une fois, à la création de l'intergiciel (pas à chaque requête). csp=false : pas de CSP.
func security_headers(csp="default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'", hsts_seconds=31536000):
    pairs := [["X-Content-Type-Options", "nosniff"], ["X-Frame-Options", "DENY"], ["Referrer-Policy", "strict-origin-when-cross-origin"], ["Cross-Origin-Opener-Policy", "same-origin"]]
    if csp != null and csp != false:
        append(pairs, ["Content-Security-Policy", csp])
    hsts := null
    if hsts_seconds != false and hsts_seconds != null:
        hsts = ["Strict-Transport-Security", "max-age=" + str(hsts_seconds)]
    checked := _validated_pairs(pairs + ([hsts] if hsts != null else []))
    plain := checked[0:len(pairs)]
    hsts_pair := checked[len(pairs)] if hsts != null else null
    return _chain.Hook(null, (req, r) => _security(req, r, plain, hsts_pair))

func _security(req, r, pairs, hsts_pair):
    present := _lower_names(r.headers)
    framed := "alweb_frame" in req.state and req.state["alweb_frame"] == "self"   # aperçu d'un thème (alweb.themes)
    for p in pairs:
        if not (p[2] in present):
            if framed and p[2] == "x-frame-options":
                append(r.headers.entries, [p[0], "SAMEORIGIN", p[2]])
            elif framed and p[2] == "content-security-policy":
                append(r.headers.entries, [p[0], _s.replace(p[1], "frame-ancestors 'none'", "frame-ancestors 'self'"), p[2]])
            else:
                append(r.headers.entries, p)
    secure := req.secure or ("scheme" in req.state and req.state["scheme"] == "https")
    if secure and hsts_pair != null and not ("strict-transport-security" in present):
        append(r.headers.entries, hsts_pair)
    return r

# Valide des paires [nom, valeur] (CR / LF / caractères interdits refusés) en passant par Headers ; rend les
# entrées telles que Headers les range ([nom, valeur, nom en minuscules]).
func _validated_pairs(pairs):
    h := _headers.Headers()
    for p in pairs:
        h.add(p[0], p[1])
    out := []
    for e in h.entries:
        append(out, [e[0], e[1], e[2]])
    return out

# Noms d'en-têtes présents, en minuscules (une seule passe ; Headers les garde déjà en minuscules, correctif 0009).
func _lower_names(headers):
    out := {}
    for e in headers.entries:
        out[e[2]] = true
    return out

# ---------------------------------------------------------------- CORS

# origins : liste d'origines autorisées, ou ["*"] ; les requêtes de pré-vérification sont traitées ici.
func cors(origins=null, methods=null, headers=null, credentials=false, max_age=600, expose=null):
    o := origins if origins != null else ["*"]
    ms := methods if methods != null else ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]
    hs := headers if headers != null else ["Content-Type", "Authorization"]
    return _chain.Hook((req) => _cors_preflight(req, o, ms, hs, credentials, max_age), (req, r) => _cors_after(req, r, o, credentials, expose))

func _cors_preflight(req, origins, methods, headers, credentials, max_age):
    origin := req.headers.get("origin")
    if origin == null:
        return null
    allowed := "*" in origins or origin in origins
    value := origin if credentials or not ("*" in origins) else "*"
    if req.method == "OPTIONS" and req.headers.has("access-control-request-method"):
        r := _response.no_content()
        if allowed:
            r.headers.set("Access-Control-Allow-Origin", value)
            r.headers.set("Access-Control-Allow-Methods", _s.join(", ", methods))
            r.headers.set("Access-Control-Allow-Headers", _s.join(", ", headers))
            r.headers.set("Access-Control-Max-Age", str(max_age))
            if credentials:
                r.headers.set("Access-Control-Allow-Credentials", "true")
        r.headers.add("Vary", "Origin")
        return r
    return null

func _cors_after(req, r, origins, credentials, expose):
    origin := req.headers.get("origin")
    if origin == null or (req.method == "OPTIONS" and req.headers.has("access-control-request-method")):
        return r
    allowed := "*" in origins or origin in origins
    value := origin if credentials or not ("*" in origins) else "*"
    if allowed:
        r.headers.set("Access-Control-Allow-Origin", value)
        if credentials:
            r.headers.set("Access-Control-Allow-Credentials", "true")
        if expose != null:
            r.headers.set("Access-Control-Expose-Headers", _s.join(", ", expose))
        r.headers.add("Vary", "Origin")
    return r
