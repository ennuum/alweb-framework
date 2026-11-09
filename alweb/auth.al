# alweb.auth — authentification : mots de passe, connexion par session, gardes de routes, rôles, jetons JWT.
#
#   use alweb.auth as auth
#
#   # inscription / connexion (mots de passe hachés sur un fil : le serveur n'est pas bloqué)
#   empreinte := await auth.hash_password(mdp)
#   if await auth.verify_password(mdp, compte["mdp"]):
#       auth.login(req, compte["id"], ["auteur"])          # nouvel identifiant de session
#       return alweb.redirect(auth.next_url(req, "/"))     # retour à la page demandée (même site seulement)
#   auth.logout(req)
#
#   # utilisateur courant comme dépendance
#   app.provide("user", auth.current_user(charger_compte))  # charger_compte(req, id) -> compte ou null
#
#   # gardes (intergiciels de route)
#   @app.get("/brouillons", {"middleware": [auth.login_required()], "deps": ["user"]})
#   @app.delete("/articles/{id:int}", {"middleware": [auth.roles_required(["admin"])]})
#
#   # API : jetons JWT (HS256)
#   jeton := auth.jwt_encode({"sub": str(id), "roles": ["auteur"]}, SECRET, 3600)
#   api := app.group("/api", [auth.bearer(SECRET)])         # claims dans req.state["jwt"] ; 401 sinon
#
#   # liens envoyés par courriel (alweb.mail) : réinitialisation du mot de passe, confirmation d'adresse
#   jeton := auth.reset_token(SECRET, id, compte["mdp"]) ; auth.check_reset_token(SECRET, jeton, compte["mdp"])
#
# login_required : visiteur non connecté -> redirection vers login_url?next=<chemin> pour une page HTML,
# 401 JSON pour une API (selon Accept). roles_required : 403 si aucun des rôles. Les deux acceptent aussi un
# utilisateur authentifié par jeton (bearer) : rôles pris dans la revendication « roles ».

from core use len, type, to_int
from collections use append, keys
use string as _s
use time as _time
use json as _json
use network.security as _sec
use network.encoding as _enc
use thread.offload as _offload
use asyncio as _aio
use web.http.response as _response
use web.server.request_dispatch as _rd

const USER_KEY := "_auth_user"
const ROLES_KEY := "_auth_roles"
const CSRF_SEED_KEY := "_csrf_seed"     # alweb.csrf

# ================================================================ mots de passe

# Empreinte PBKDF2-SHA256 (600 000 itérations par défaut), calculée sur un fil ; à attendre.
func hash_password(password, iterations=null):
    return _offload.run(_sec.hash_password, [password] + ([iterations] if iterations != null else []))

# Vrai si le mot de passe correspond à l'empreinte ; calculé sur un fil ; à attendre.
func verify_password(password, encoded):
    return _offload.run(_sec.verify_password, [password, encoded])

func needs_rehash(encoded):
    return _sec.needs_rehash(encoded)

# ================================================================ session

# Connecte l'utilisateur : nouvel identifiant de session (contre la fixation) et nouveau jeton CSRF (les jetons
# émis avant la connexion ne valent plus), identifiant et rôles gardés.
func login(req, user_id, roles=null):
    s := _session(req)
    s.regenerate()
    s.pop(CSRF_SEED_KEY)
    s.set(USER_KEY, user_id)
    s.set(ROLES_KEY, roles if roles != null else [])

# Déconnecte : session vidée, nouvel identifiant.
func logout(req):
    _session(req).invalidate()

# Identifiant de l'utilisateur connecté (session, ou « sub » d'un jeton bearer), ou null.
func user_id(req):
    if "session" in req.state:
        id := req.state["session"].get(USER_KEY)
        if id != null:
            return id
    if "jwt" in req.state:
        return req.state["jwt"]["sub"] if "sub" in req.state["jwt"] else null
    return null

func roles(req):
    if "session" in req.state and req.state["session"].get(USER_KEY) != null:
        return req.state["session"].get(ROLES_KEY, [])
    if "jwt" in req.state and "roles" in req.state["jwt"]:
        return req.state["jwt"]["roles"]
    return []

func is_authenticated(req):
    return user_id(req) != null

# Fournisseur de dépendance « utilisateur courant » : loader(req, id) (async permis) -> utilisateur ou null.
func current_user(loader):
    return (req) => _load_user(req, loader)

async func _load_user(req, loader):
    id := user_id(req)
    if id == null:
        return null
    u := loader(req, id)
    if _is_future(u):
        u = await u
    return u

# URL de retour après connexion : paramètre next s'il désigne une page de ce site, sinon default.
func next_url(req, default="/"):
    n := req.query_param("next")
    if n == null and "form" in req.state:
        n = req.state["form"].get("next")
    if n != null and _sec.is_safe_redirect(n) and _s.starts_with(n, "/") and not _s.starts_with(n, "//"):
        return n
    return default

func _session(req):
    if not ("session" in req.state):
        raise("AlwebError", "auth : ajouter l'intergiciel alweb.sessions.middleware(secret)")
    return req.state["session"]

# ================================================================ gardes

# Intergiciel de route : utilisateur connecté exigé.
func login_required(login_url="/connexion"):
    return (req, nxt) => _require(req, nxt, login_url, null)

# Intergiciel de route : l'un des rôles exigé (et utilisateur connecté).
func roles_required(wanted, login_url="/connexion"):
    return (req, nxt) => _require(req, nxt, login_url, wanted)

async func _require(req, nxt, login_url, wanted):
    if user_id(req) == null:
        if _wants_html(req):
            return _response.redirect(login_url + "?next=" + _quote(req.target), 303)
        r := _rd.error_response(req, 401, "authentification requise")
        r.headers.set("WWW-Authenticate", "Bearer")
        return r
    if wanted != null:
        mine := roles(req)
        ok := false
        for w in wanted:
            if w in mine:
                ok = true
        if not ok:
            return _rd.error_response(req, 403, "droits insuffisants")
    return await nxt(req)

func _wants_html(req):
    a := req.header("accept", "")
    return _s.contains(a, "text/html") and req.header("authorization") == null

func _quote(s):
    out := ""
    i := 0
    n := _s.byte_len(s)
    while i < n:
        b := _s.byte_at(s, i)
        i += 1
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 95 or b == 46 or b == 126 or b == 47:
            out = out + _s.byte_char(b)
        else:
            h := "0123456789ABCDEF"
            out = out + "%" + h[b // 16:b // 16 + 1] + h[b % 16:b % 16 + 1]
    return out

# ================================================================ jetons envoyés par courriel
#
# Liens « mot de passe oublié » et « confirmer votre adresse » : jetons signés (HMAC-SHA256 sous la clé secrète),
# liés à un usage (purpose) et datés. Pas de table : tout est dans le jeton.
#
#   jeton := auth.reset_token(secret, u["id"], u["mdp"])           # valable 1 h, une seule fois
#   id := auth.reset_token_user(secret, jeton)                       # null : faux, expiré
#   if id != null and auth.check_reset_token(secret, jeton, u["mdp"]): ...   # faux s'il a déjà servi
#   jeton := auth.confirm_token(secret, u["id"], u["courriel"])      # valable 3 jours
#   c := auth.read_confirm_token(secret, jeton)                      # {"id", "email"} ou null
#
# Le jeton de réinitialisation porte une empreinte du mot de passe haché du moment : une fois le mot de passe
# changé, il ne vaut plus (usage unique, sans rien enregistrer). Celui de confirmation porte l'adresse : il ne
# confirme que celle à laquelle il a été envoyé.

const RESET_TTL := 3600
const CONFIRM_TTL := 259200

# Jeton signé pour un usage : data (valeur JSON), valable expires_in secondes (null : sans fin).
func signed_token(secret, purpose, data, expires_in=3600, now=null):
    _check_secret(secret)
    t := to_int(now if now != null else _time.time())
    claims := {"p": purpose, "d": data}
    if expires_in != null:
        claims["e"] = t + expires_in
    body := _b64(_json.stringify(claims))
    return body + "." + _token_sig(secret, purpose, body)

# data d'un jeton valide pour cet usage ; null sinon (signature, usage, expiration, forme).
func read_token(secret, purpose, token, now=null):
    if type(token) != "str" or len(token) > 4096:
        return null
    parts := _s.split(token, ".")
    if len(parts) != 2:
        return null
    if not _sec.constant_time_equals(_token_sig(secret, purpose, parts[0]), parts[1]):
        return null
    claims := null
    try:
        claims = _json.parse(_unb64(parts[0]))
    catch e:
        return null
    if type(claims) != "dict" or not ("p" in claims) or claims["p"] != purpose:
        return null
    t := now if now != null else _time.time()
    if "e" in claims and t > claims["e"]:
        return null
    return claims["d"] if "d" in claims else null

func _token_sig(secret, purpose, body):
    return _strip_pad(_enc.base64_encode(_sec.hmac(secret, "alweb.token:" + purpose + "." + body, "sha256"), true))

func _check_secret(secret):
    if type(secret) != "str" or len(secret) < 16:
        raise("ConfigError", "jetons : clé secrète d'au moins 16 caractères requise (configuration secret_key)")

func _state(secret, password_hash):
    return _sec.hmac_sign(secret, "alweb.reset:" + str(password_hash))[0:16]

# Réinitialisation du mot de passe : jeton lié à l'utilisateur et à son mot de passe haché actuel.
func reset_token(secret, user_id, password_hash, expires_in=RESET_TTL, now=null):
    return signed_token(secret, "reset", {"u": user_id, "s": _state(secret, password_hash)}, expires_in, now)

# Utilisateur d'un jeton de réinitialisation valide (signature, date) ; null sinon.
func reset_token_user(secret, token, now=null):
    d := read_token(secret, "reset", token, now)
    if type(d) != "dict" or not ("u" in d):
        return null
    return d["u"]

# Vrai si le jeton est valide et que le mot de passe n'a pas changé depuis son envoi.
func check_reset_token(secret, token, password_hash, now=null):
    d := read_token(secret, "reset", token, now)
    return type(d) == "dict" and "s" in d and _sec.constant_time_equals(d["s"], _state(secret, password_hash))

# Confirmation d'adresse : jeton lié à l'utilisateur et à l'adresse envoyée.
func confirm_token(secret, user_id, email, expires_in=CONFIRM_TTL, now=null):
    return signed_token(secret, "confirm", {"u": user_id, "m": _s.lower(email)}, expires_in, now)

# {"id", "email"} d'un jeton de confirmation valide ; null sinon.
func read_confirm_token(secret, token, now=null):
    d := read_token(secret, "confirm", token, now)
    if type(d) != "dict" or not ("u" in d) or not ("m" in d):
        return null
    return {"id": d["u"], "email": d["m"]}

# ================================================================ JWT (HS256)

# Jeton signé HS256 : payload (dict) + iat, et exp si expires_in (secondes).
func jwt_encode(payload, secret, expires_in=null, now=null):
    t := to_int(now if now != null else _time.time())
    claims := {}
    for k in keys(payload):
        claims[k] = payload[k]
    claims["iat"] = t
    if expires_in != null:
        claims["exp"] = t + expires_in
    head := _b64(_json.stringify({"alg": "HS256", "typ": "JWT"}))
    body := _b64(_json.stringify(claims))
    sig := _enc.base64_encode(_sec.hmac(secret, head + "." + body, "sha256"), true)
    return head + "." + body + "." + _strip_pad(sig)

# Revendications d'un jeton valide ; JWTError sinon (signature, algorithme autre que HS256, expiré, pas encore
# valide). leeway : tolérance d'horloge en secondes.
func jwt_decode(token, secret, leeway=30, now=null):
    if type(token) != "str":
        raise("JWTError", "jeton absent")
    parts := _s.split(token, ".")
    if len(parts) != 3:
        raise("JWTError", "jeton mal formé")
    head := null
    claims := null
    try:
        head = _json.parse(_unb64(parts[0]))
        claims = _json.parse(_unb64(parts[1]))
    catch e:
        raise("JWTError", "jeton illisible")
    if type(head) != "dict" or type(claims) != "dict":
        raise("JWTError", "jeton mal formé")
    if not ("alg" in head) or head["alg"] != "HS256":
        raise("JWTError", "algorithme refusé (HS256 seulement)")
    expected := _strip_pad(_enc.base64_encode(_sec.hmac(secret, parts[0] + "." + parts[1], "sha256"), true))
    if not _sec.constant_time_equals(expected, _strip_pad(parts[2])):
        raise("JWTError", "signature invalide")
    t := now if now != null else _time.time()
    if "exp" in claims and t > claims["exp"] + leeway:
        raise("JWTError", "jeton expiré")
    if "nbf" in claims and t < claims["nbf"] - leeway:
        raise("JWTError", "jeton pas encore valide")
    return claims

# Intergiciel : en-tête « Authorization: Bearer <jwt> » exigé (optional : absent accepté) ; revendications dans
# req.state["jwt"] ; 401 sinon.
func bearer(secret, optional=false):
    return (req, nxt) => _bearer(req, nxt, secret, optional)

async func _bearer(req, nxt, secret, optional):
    h := req.header("authorization")
    if h == null or not _s.starts_with(_s.lower(h), "bearer "):
        if optional:
            return await nxt(req)
        return _unauthorized(req, "jeton Bearer requis")
    try:
        req.state["jwt"] = jwt_decode(_s.trim(h[7:len(h)]), secret)
    catch e:
        return _unauthorized(req, str(e.message))
    return await nxt(req)

func _unauthorized(req, why):
    r := _rd.error_response(req, 401, why)
    r.headers.set("WWW-Authenticate", "Bearer error=\"invalid_token\"")
    return r

func _b64(text):
    return _strip_pad(_enc.base64_encode(text, true))

func _unb64(text):
    pad := (4 - len(text) % 4) % 4
    return _enc.base64_decode(text + "=" * pad, true)

func _strip_pad(s):
    out := s
    while len(out) > 0 and out[len(out) - 1:len(out)] == "=":
        out = out[0:len(out) - 1]
    return out

func _is_future(v):
    return _aio.is_future(v)
