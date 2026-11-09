# alweb.csrf — protection contre la falsification de requêtes intersites (CSRF).
#
#   app.middleware([sessions.middleware(secret), csrf.middleware()])      # après les sessions
#
#   <form method="post" action="/articles">
#     {{ csrf_field() }}                  <!-- <input type="hidden" name="csrf_token" value="..."> -->
#     ...
#   </form>
#   fetch("/api/x", {method: "POST", headers: {"X-CSRF-Token": "{{ csrf_token() }}"}})
#
# Toute requête POST, PUT, PATCH ou DELETE doit porter un jeton valide (champ csrf_token ou en-tête
# X-CSRF-Token), sinon 403. Le jeton est lié à la session du visiteur (graine aléatoire gardée dans la session) :
# un autre site ne peut pas le deviner. Exceptions : chemins listés dans exempt (préfixes, ex. "/webhooks/"), et
# requêtes d'API sans cookie de session qui s'authentifient par un en-tête Authorization (pas d'identifiants
# envoyés automatiquement par le navigateur, donc pas de CSRF possible).

from core use len
use string as _s
use network.security as _sec
use alweb.forms as _forms
use alweb.templates as _tpl
use web.server.request_dispatch as _rd

const FIELD := "csrf_token"
const HEADER := "x-csrf-token"
const SEED_KEY := "_csrf_seed"
const UNSAFE := ["POST", "PUT", "PATCH", "DELETE"]

func middleware(exempt=null, session_cookie="alweb_session"):
    ex := exempt if exempt != null else []
    return (req, nxt) => _handle(req, nxt, ex, session_cookie)

async func _handle(req, nxt, exempt, session_cookie):
    if not ("session" in req.state):
        raise("AlwebError", "csrf : placer alweb.sessions.middleware avant alweb.csrf.middleware")
    req.state["csrf"] = true
    if req.method in UNSAFE and not _exempt(req, exempt, session_cookie):
        sent := req.header(HEADER)
        if sent == null:
            try:
                sent = _forms.form(req).get(FIELD)
            catch e:
                sent = null
        if not valid(req, sent):
            return _rd.error_response(req, 403, "jeton CSRF absent ou invalide (rechargez la page et recommencez)")
    return await nxt(req)

func _exempt(req, exempt, session_cookie):
    for p in exempt:
        if _s.starts_with(req.path(), p):
            return true
    has_cookie := req.cookie(session_cookie) != null
    return req.header("authorization") != null and not has_cookie

# Jeton CSRF de la session (crée la graine au besoin).
func token(req):
    s := req.state["session"]
    seed := s.get(SEED_KEY)
    if seed == null:
        seed = _sec.random_token(16)
        s.set(SEED_KEY, seed)
    return _sec.make_csrf_token(req.state["session_secret"], seed)

func valid(req, sent):
    if sent == null or sent == "":
        return false
    seed := req.state["session"].get(SEED_KEY)
    if seed == null:
        return false
    return _sec.check_csrf_token(sent, req.state["session_secret"], seed)

# Champ caché pour un formulaire HTML (texte sûr).
func field(req):
    return _tpl.markup("<input type=\"hidden\" name=\"" + FIELD + "\" value=\"" + _tpl.escape(token(req)) + "\">")
