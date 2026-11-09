# alweb.storage — fichiers téléversés et produits par l'application : dossier local, mémoire (tests) ou stockage
# compatible S3 (Amazon S3, MinIO, Scaleway, Backblaze B2, Cloudflare R2, OVH, Wasabi…), avec des URL signées
# qui expirent. Le client S3 (signature AWS V4) est écrit en ALEX : il fonctionne aussi dans l'exécutable natif.
#
#   use alweb.storage as storage
#   st := storage.setup(app)                          # clé « storage » de la configuration ; pose app.storage
#   cle := await st.put("factures/2026/f-12.pdf", octets, {"content_type": "application/pdf"})
#   octets := await st.get(cle)                       # null si absent
#   lien := st.url(cle, 600, "facture.pdf")           # URL signée valable 10 min (téléchargement nommé)
#   await st.delete(cle) ; await st.list("factures/") ; await st.head(cle)
#   cle := await storage.save_upload(st, alweb.form(req).file("doc"), {"prefix": "docs/", "max_bytes": 5000000,
#                                                                       "allowed": ["application/pdf"]})
#
# Adresses (clé « storage.url », ou ALWEB_STORAGE__URL) :
#   file:dossier                  disque local ; les URL signées passent par une route de l'application
#                                 (/_fichiers/… , option « route ») ; défaut en mode debug : file:media
#   memory:                       en mémoire (tests)
#   s3://CLÉ:SECRET@hôte[:port]/seau?region=fr-par
#                                 options : region (us-east-1), secure (true ; false pour un MinIO local en
#                                 http), style (path ou virtual ; virtual par défaut chez amazonaws.com),
#                                 verify, ca_file, timeout. Les caractères spéciaux de la clé et du secret
#                                 s'écrivent en %XX (« / » -> %2F, « + » -> %2B).
# Autres clés : public_url (préfixe d'URL publique : CDN, seau public), secret (signature des URL locales ;
# défaut : secret_key de l'application).
#
# Clés : chemins relatifs (« a/b.jpg ») ; refusées : vides, absolues, « .. », caractères de contrôle, « \ ».
# Erreurs : StorageError (avec le code S3 : « NoSuchBucket », « AccessDenied »…).

from core use len, type, to_int
from collections use append, keys
use os as _os
use io as _io
use time as _time
use string as _s
use network.security as _sec
use network.encoding as _enc
use network.url as _url
use network.async_client as _ac
use network.mime as _mime
use web.http.response as _response
use alweb.errors as _err
use alweb.forms as _forms

const ROUTE := "/_fichiers"
const EMPTY_SHA256 := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

func _fail(message, code=null):
    raise("StorageError", message if code == null else code + " : " + message)

# ================================================================ clés

# Clé normalisée (« a//b » -> « a/b ») ou StorageError.
func check_key(key):
    if type(key) != "str" or key == "" or len(key) > 1024:
        _fail("clé invalide : " + str(key))
    if _s.starts_with(key, "/") or _s.contains(key, "\\"):
        _fail("clé invalide (chemin absolu ou « \\ ») : " + key)
    for ch in key:
        c := str(ch)
        if c < " " or c == "\u007f":
            _fail("clé invalide (caractère de contrôle)")
    parts := []
    for p in _s.split(key, "/"):
        if p == "." or p == "..":
            _fail("clé invalide (« " + p + " ») : " + key)
        if p != "":
            append(parts, p)
    if len(parts) == 0:
        _fail("clé invalide : " + key)
    return _s.join("/", parts)

func content_type_of(key):
    t := _mime.guess_type(key)
    return t if t != null else "application/octet-stream"

# Encodage d'URI d'AWS : A-Z a-z 0-9 - _ . ~ gardés ; « / » gardé si slash ; le reste en %XX (majuscules).
func uri_encode(text, slash=true):
    out := ""
    h := "0123456789ABCDEF"
    i := 0
    n := _s.byte_len(text)
    while i < n:
        b := _s.byte_at(text, i)
        i += 1
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 45 or b == 95 or b == 46 or b == 126 or (slash and b == 47):
            out = out + _s.byte_char(b)
        else:
            out = out + "%" + h[b // 16:b // 16 + 1] + h[b % 16:b % 16 + 1]
    return out

func _hexv(b):
    if b >= 48 and b <= 57:
        return b - 48
    if b >= 65 and b <= 70:
        return b - 55
    if b >= 97 and b <= 102:
        return b - 87
    _fail("%XX invalide dans l'adresse de stockage")

func _pct_decode(text):
    if not _s.contains(text, "%"):
        return text
    bs := []
    i := 0
    n := _s.byte_len(text)
    while i < n:
        b := _s.byte_at(text, i)
        if b == 37 and i + 2 < n:
            append(bs, _hexv(_s.byte_at(text, i + 1)) * 16 + _hexv(_s.byte_at(text, i + 2)))
            i += 3
        else:
            append(bs, b)
            i += 1
    return _s.byte_pack(bs)

# ================================================================ URL signées (stockages local et mémoire)

func _local_sig(secret, key, exp, name):
    return _enc.hex_encode(_sec.hmac(secret, "alweb.storage:" + key + ":" + str(exp) + ":" + (name if name != null else ""), "sha256"))[0:32]

# Liens d'une heure ou plus : expiration arrondie à l'heure suivante, si bien que le lien reste le même pendant
# l'heure (le navigateur garde l'image en cache au lieu de la recharger à chaque page).
func _signed_local_url(base, secret, key, expires, name, clock):
    exp := to_int(clock()) + to_int(expires)
    if to_int(expires) >= 3600:
        exp = (exp + 3599) // 3600 * 3600
    u := base + "/" + uri_encode(key) + "?e=" + str(exp) + "&s=" + _local_sig(secret, key, exp, name)
    if name != null:
        u = u + "&n=" + uri_encode(name, false)
    return u

# Vérifie une URL signée locale : [clé, nom de téléchargement] ou null (fausse, expirée).
func verify_local(secret, key, e, s, name, now):
    if e == null or s == null:
        return null
    exp := 0
    try:
        exp = to_int(e)
    catch err:
        return null
    if exp < now:
        return null
    if not _sec.constant_time_equals(_local_sig(secret, key, exp, name), s):
        return null
    return [key, name]

func _disposition(name):
    safe := ""
    for ch in name:
        c := str(ch)
        safe = safe + ("_" if c == "\"" or c == "\\" or c < " " else c)
    return "attachment; filename=\"" + safe + "\"; filename*=UTF-8''" + uri_encode(name, false)

# ================================================================ disque local

class LocalStorage:
    func init(root, secret=null, route=ROUTE, public_url=null):
        self.kind = "file"
        self.root = root
        self.secret = secret
        self.route = route
        self.public_url = public_url
        self.clock = () => _time.time()

    func path(key):
        return _os.join(self.root, check_key(key))

    async func put(key, data, options=null):
        k := check_key(key)
        p := _os.join(self.root, k)
        _os.mkdir_all(_os.dirname(p))
        tmp := p + ".part-" + _sec.random_hex(6)
        _io.write_file(tmp, data)
        _os.move(tmp, p)
        return k

    async func get(key):
        p := self.path(key)
        if not _os.isfile(p):
            return null
        return _io.read_raw(p)

    async func head(key):
        p := self.path(key)
        if not _os.isfile(p):
            return null
        return {"key": check_key(key), "size": _os.size(p), "content_type": content_type_of(key), "modified": _os.mtime(p)}

    async func delete(key):
        p := self.path(key)
        if _os.isfile(p):
            _os.remove(p)
        return true

    async func list(prefix="", limit=1000):
        out := []
        if _os.isdir(self.root):
            _walk(self.root, "", prefix, out, limit)
        return out

    func url(key, expires=3600, name=null):
        if self.secret == null:
            _fail("URL signée : pas de secret (secret_key de l'application ou storage.secret)")
        return _signed_local_url(self.route, self.secret, check_key(key), expires, name, self.clock)

    func public(key):
        if self.public_url == null:
            _fail("pas de public_url : utiliser url(clé) (lien signé)")
        return self.public_url + "/" + uri_encode(check_key(key))

    # Réponse d'une URL signée (route installée par setup).
    func serve(req):
        k := null
        try:
            k = check_key(req.params["key"])
        catch e:
            _err.abort(404)
        ok := verify_local(self.secret, k, req.query_param("e"), req.query_param("s"), req.query_param("n"), to_int(self.clock()))
        if ok == null:
            _err.abort(403, "lien expiré ou invalide")
        p := _os.join(self.root, k)
        if not _os.isfile(p):
            _err.abort(404)
        r := _response.file(p, content_type_of(k))
        r.headers.set("Cache-Control", "private, max-age=300")
        r.headers.set("X-Content-Type-Options", "nosniff")
        if ok[1] != null:
            r.headers.set("Content-Disposition", _disposition(ok[1]))
        return r

func _walk(root, rel, prefix, out, limit):
    d := root if rel == "" else _os.join(root, rel)
    names := _os.list_dir(d)
    _sort(names)
    for n in names:
        if len(out) >= limit:
            return
        r := n if rel == "" else rel + "/" + n
        p := _os.join(root, r)
        if _os.isdir(p):
            if _s.starts_with(r + "/", prefix) or _s.starts_with(prefix, r + "/"):
                _walk(root, r, prefix, out, limit)
        elif _s.starts_with(r, prefix) and not _s.contains(n, ".part-"):
            append(out, {"key": r, "size": _os.size(p), "modified": _os.mtime(p)})

func _sort(xs):
    i := 1
    while i < len(xs):
        x := xs[i]
        j := i - 1
        while j >= 0 and xs[j] > x:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = x
        i += 1
    return xs

# ================================================================ mémoire (tests)

class MemoryStorage:
    func init(secret=null, route=ROUTE, public_url=null):
        self.kind = "memory"
        self.objects = {}                # clé -> [octets, type, date]
        self.secret = secret
        self.route = route
        self.public_url = public_url
        self.clock = () => _time.time()

    async func put(key, data, options=null):
        k := check_key(key)
        o := options if options != null else {}
        self.objects[k] = [data, o["content_type"] if "content_type" in o else content_type_of(k), self.clock()]
        return k

    async func get(key):
        k := check_key(key)
        return self.objects[k][0] if k in self.objects else null

    async func head(key):
        k := check_key(key)
        if not (k in self.objects):
            return null
        o := self.objects[k]
        return {"key": k, "size": _s.byte_len(o[0]), "content_type": o[1], "modified": o[2]}

    async func delete(key):
        k := check_key(key)
        if k in self.objects:
            rest := {}
            for x in keys(self.objects):
                if x != k:
                    rest[x] = self.objects[x]
            self.objects = rest
        return true

    async func list(prefix="", limit=1000):
        ks := _sort([k for k in keys(self.objects) if _s.starts_with(k, prefix)])
        return [{"key": k, "size": _s.byte_len(self.objects[k][0]), "modified": self.objects[k][2]} for k in ks[0:limit if limit < len(ks) else len(ks)]]

    func url(key, expires=3600, name=null):
        if self.secret == null:
            _fail("URL signée : pas de secret")
        return _signed_local_url(self.route, self.secret, check_key(key), expires, name, self.clock)

    func public(key):
        if self.public_url == null:
            _fail("pas de public_url : utiliser url(clé) (lien signé)")
        return self.public_url + "/" + uri_encode(check_key(key))

    func serve(req):
        k := null
        try:
            k = check_key(req.params["key"])
        catch e:
            _err.abort(404)
        ok := verify_local(self.secret, k, req.query_param("e"), req.query_param("s"), req.query_param("n"), to_int(self.clock()))
        if ok == null:
            _err.abort(403, "lien expiré ou invalide")
        if not (k in self.objects):
            _err.abort(404)
        r := _response.Response(200, self.objects[k][0])
        r.headers.set("Content-Type", self.objects[k][1])
        r.headers.set("X-Content-Type-Options", "nosniff")
        if ok[1] != null:
            r.headers.set("Content-Disposition", _disposition(ok[1]))
        return r

# ================================================================ S3 (signature AWS V4)

func _amz_date(t):
    f := _time.gmtime(to_int(t))
    two := (v) => ("0" + str(v)) if v < 10 else str(v)
    return str(f["year"]) + two(f["month"]) + two(f["day"]) + "T" + two(f["hour"]) + two(f["minute"]) + two(f["second"]) + "Z"

func _hex_sha256(data):
    return _enc.hex_encode(_sec.digest(data, "sha256"))

func _canonical_query(query):
    pairs := []
    for k in keys(query):
        append(pairs, [uri_encode(k, false), uri_encode(str(query[k]), false)])
    # tri par clé encodée
    i := 1
    while i < len(pairs):
        x := pairs[i]
        j := i - 1
        while j >= 0 and pairs[j][0] > x[0]:
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = x
        i += 1
    return _s.join("&", [p[0] + "=" + p[1] for p in pairs])

func signing_key(secret_key, date, region, service="s3"):
    k := _sec.hmac("AWS4" + secret_key, date, "sha256")
    k = _sec.hmac(k, region, "sha256")
    k = _sec.hmac(k, service, "sha256")
    return _sec.hmac(k, "aws4_request", "sha256")

# Signature AWS V4 d'une requête : [signature (hex), en-têtes signés « a;b », portée]. path : déjà encodé ;
# headers : {nom en minuscules: valeur} (tous signés) ; payload_hash : SHA-256 hex du corps ou
# « UNSIGNED-PAYLOAD ».
func signature_v4(method, path, query, headers, payload_hash, amz_date, region, access_key, secret_key, service="s3"):
    names := _sort([_s.lower(k) for k in keys(headers)])
    low := {}
    for k in keys(headers):
        low[_s.lower(k)] = headers[k]
    ch := ""
    for n in names:
        ch = ch + n + ":" + _s.trim(str(low[n])) + "\n"
    signed := _s.join(";", names)
    creq := method + "\n" + path + "\n" + _canonical_query(query) + "\n" + ch + "\n" + signed + "\n" + payload_hash
    date := amz_date[0:8]
    scope := date + "/" + region + "/" + service + "/aws4_request"
    sts := "AWS4-HMAC-SHA256\n" + amz_date + "\n" + scope + "\n" + _hex_sha256(creq)
    sig := _enc.hex_encode(_sec.hmac(signing_key(secret_key, date, region, service), sts, "sha256"))
    return [sig, signed, scope]

func authorization(access_key, sig):
    return "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + sig[2] + ", SignedHeaders=" + sig[1] + ", Signature=" + sig[0]

func _xml_text(body, tag):
    a := _s.find(body, "<" + tag + ">")
    if a < 0:
        return null
    rest := body[a + len(tag) + 2:len(body)]
    b := _s.find(rest, "</" + tag + ">")
    return _xml_unescape(rest[0:b]) if b >= 0 else null

func _xml_unescape(t):
    return _s.replace(_s.replace(_s.replace(_s.replace(_s.replace(t, "&lt;", "<"), "&gt;", ">"), "&quot;", "\""), "&apos;", "'"), "&amp;", "&")

func _xml_blocks(body, tag):
    out := []
    rest := body
    while true:
        a := _s.find(rest, "<" + tag + ">")
        if a < 0:
            return out
        rest = rest[a + len(tag) + 2:len(rest)]
        b := _s.find(rest, "</" + tag + ">")
        if b < 0:
            return out
        append(out, rest[0:b])
        rest = rest[b + len(tag) + 3:len(rest)]

func _iso_to_ts(t):
    if t == null:
        return null
    try:
        f := _time.parse_iso(t)
        return _time.timegm(f) - (f["utc_offset"] if f["utc_offset"] != null else 0)
    catch e:
        return null

class S3Storage:
    # endpoint : « https://hôte[:port] » ; style : "path" (seau dans le chemin) ou "virtual" (seau.hôte).
    func init(endpoint, bucket, access_key, secret_key, region="us-east-1", style=null, public_url=null, verify=true, ca_file=null, timeout=30.0):
        self.kind = "s3"
        u := _url.parse(endpoint)
        if u.scheme != "http" and u.scheme != "https":
            _fail("point d'accès S3 invalide : " + endpoint)
        if bucket == null or bucket == "" or _s.contains(bucket, "/"):
            _fail("seau S3 invalide : " + str(bucket))
        self.scheme = u.scheme
        self.host = u.netloc()
        self.bucket = bucket
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region
        self.style = style if style != null else ("virtual" if _s.ends_with(u.host, "amazonaws.com") else "path")
        self.public_url = public_url
        self.verify = verify
        self.ca_file = ca_file
        self.timeout = timeout
        self.clock = () => _time.time()

    # [hôte, chemin encodé] d'une clé (null : le seau lui-même).
    func _target(key):
        if self.style == "virtual":
            return [self.bucket + "." + self.host, "/" + (uri_encode(key) if key != null else "")]
        return [self.host, "/" + self.bucket + ("/" + uri_encode(key) if key != null else "")]

    async func _call(method, key, query=null, body=null, extra=null, ok=null):
        t := self._target(key)
        q := query if query != null else {}
        data := body if body != null else ""
        ph := _hex_sha256(data) if body != null else EMPTY_SHA256
        amz := _amz_date(self.clock())
        hs := {"host": t[0], "x-amz-date": amz, "x-amz-content-sha256": ph}
        if extra != null:
            for k in keys(extra):
                hs[_s.lower(k)] = extra[k]
        sig := signature_v4(method, t[1], q, hs, ph, amz, self.region, self.access_key, self.secret_key)
        send := {}
        for k in keys(hs):
            send[k] = hs[k]
        send["Authorization"] = authorization(self.access_key, sig)
        qs := _canonical_query(q)
        url := self.scheme + "://" + t[0] + t[1] + ("?" + qs if qs != "" else "")
        r := await _ac.request(method, url, body, null, send, self.timeout, self.verify, self.ca_file, 0)
        good := ok if ok != null else [200, 204]
        if not (r.status in good):
            b := r.body if r.body != null else ""
            code := _xml_text(b, "Code")
            msg := _xml_text(b, "Message")
            raise("StorageError", (code if code != null else "HTTP " + str(r.status)) + " : " + (msg if msg != null else method + " " + (key if key != null else self.bucket) + ((" : " + b[0:300]) if _s.byte_len(b) > 0 else "")))
        return r

    async func put(key, data, options=null):
        k := check_key(key)
        o := options if options != null else {}
        extra := {"content-type": o["content_type"] if "content_type" in o else content_type_of(k)}
        if "cache_control" in o:
            extra["cache-control"] = o["cache_control"]
        await self._call("PUT", k, null, data, extra)
        return k

    async func get(key):
        k := check_key(key)
        r := await self._call("GET", k, null, null, null, [200, 404])
        return r.body if r.status == 200 else null

    async func head(key):
        k := check_key(key)
        r := await self._call("HEAD", k, null, null, null, [200, 404])
        if r.status == 404:
            return null
        mod := r.headers.get("last-modified")
        return {"key": k, "size": to_int(r.headers.get("content-length", "0")), "content_type": r.headers.get("content-type"),
                "etag": r.headers.get("etag"), "modified": mod}

    async func delete(key):
        await self._call("DELETE", check_key(key), null, null, null, [200, 204, 404])
        return true

    async func list(prefix="", limit=1000):
        out := []
        token := null
        while len(out) < limit:
            q := {"list-type": "2", "max-keys": str(1000 if limit - len(out) > 1000 else limit - len(out))}
            if prefix != "":
                q["prefix"] = prefix
            if token != null:
                q["continuation-token"] = token
            r := await self._call("GET", null, q)
            b := r.body
            for blk in _xml_blocks(b, "Contents"):
                append(out, {"key": _xml_text(blk, "Key"), "size": to_int(_xml_text(blk, "Size")), "modified": _iso_to_ts(_xml_text(blk, "LastModified"))})
            if _xml_text(b, "IsTruncated") != "true":
                break
            token = _xml_text(b, "NextContinuationToken")
            if token == null:
                break
        return out[0:limit] if len(out) > limit else out

    # URL présignée (GET), valable expires secondes (7 jours au plus) ; name : téléchargement sous ce nom. D'une
    # heure ou plus : la même URL pendant toute l'heure (signée au début de l'heure, valable une heure de plus).
    func url(key, expires=3600, name=null):
        k := check_key(key)
        e := to_int(expires)
        if e < 1 or e > 604800:
            _fail("durée d'une URL présignée : 1 s à 7 jours")
        now := to_int(self.clock())
        if e >= 3600 and e <= 604800 - 3600:
            # lien stable pendant l'heure (cache des navigateurs) : signé au début de l'heure, valable une heure de plus
            now = now // 3600 * 3600
            e = e + 3600
        return self.presign(k, e, name, now)

    # URL présignée brute : signée à l'instant now (secondes), valable expires secondes.
    func presign(key, expires, name, now):
        k := check_key(key)
        t := self._target(k)
        amz := _amz_date(now)
        q := {"X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": self.access_key + "/" + amz[0:8] + "/" + self.region + "/s3/aws4_request",
              "X-Amz-Date": amz, "X-Amz-Expires": str(to_int(expires)), "X-Amz-SignedHeaders": "host"}
        if name != null:
            q["response-content-disposition"] = _disposition(name)
        sig := signature_v4("GET", t[1], q, {"host": t[0]}, "UNSIGNED-PAYLOAD", amz, self.region, self.access_key, self.secret_key)
        return self.scheme + "://" + t[0] + t[1] + "?" + _canonical_query(q) + "&X-Amz-Signature=" + sig[0]

    func public(key):
        if self.public_url == null:
            _fail("pas de public_url : utiliser url(clé) (URL présignée)")
        return self.public_url + "/" + uri_encode(check_key(key))

# ================================================================ ouverture

# Stockage d'après son adresse (voir l'en-tête). options : secret, public_url, route.
func open(address, options=null):
    o := options if options != null else {}
    secret := o["secret"] if "secret" in o else null
    pub := o["public_url"] if "public_url" in o else null
    route := o["route"] if "route" in o else ROUTE
    if address == "memory:" or address == "memory":
        return MemoryStorage(secret, route, pub)
    if _s.starts_with(address, "file:"):
        d := address[5:len(address)]
        if _s.starts_with(d, "//"):
            d = d[2:len(d)]
        if d == "":
            _fail("file: : dossier manquant")
        return LocalStorage(d, secret, route, pub)
    if _s.starts_with(address, "s3://"):
        rest := address[5:len(address)]
        at := _s.find(rest, "@")
        if at < 0:
            _fail("s3:// : identifiants manquants (s3://CLÉ:SECRET@hôte/seau)")
        cred := rest[0:at]
        rest = rest[at + 1:len(rest)]
        c := _s.find(cred, ":")
        if c < 0:
            _fail("s3:// : « CLÉ:SECRET » attendu")
        params := {}
        qi := _s.find(rest, "?")
        if qi >= 0:
            for part in _s.split(rest[qi + 1:len(rest)], "&"):
                if part != "":
                    eq := _s.find(part, "=")
                    params[part if eq < 0 else part[0:eq]] = "" if eq < 0 else _pct_decode(part[eq + 1:len(part)])
            rest = rest[0:qi]
        sl := _s.find(rest, "/")
        if sl < 0:
            _fail("s3:// : seau manquant (s3://CLÉ:SECRET@hôte/seau)")
        host := rest[0:sl]
        bucket := rest[sl + 1:len(rest)]
        if _s.ends_with(bucket, "/"):
            bucket = bucket[0:len(bucket) - 1]
        secure := not ("secure" in params and params["secure"] == "false")
        return S3Storage(("https://" if secure else "http://") + host, bucket, _pct_decode(cred[0:c]), _pct_decode(cred[c + 1:len(cred)]),
                         params["region"] if "region" in params else "us-east-1", params["style"] if "style" in params else null,
                         pub if pub != null else (params["public_url"] if "public_url" in params else null),
                         not ("verify" in params and params["verify"] == "false"), params["ca_file"] if "ca_file" in params else null,
                         to_int(params["timeout"]) * 1.0 if "timeout" in params else 30.0)
    _fail("adresse de stockage inconnue : " + str(address) + " (file:dossier, memory:, s3://…)")

# Stockage de l'application d'après sa configuration (clé « storage ») ; pose app.storage et, pour un stockage
# local ou en mémoire, la route des URL signées. address : remplace storage.url.
func setup(app, address=null, options=null):
    cfg := app.config
    sc := cfg.get("storage", {}) if cfg != null else {}
    if sc == null:
        sc = {}
    o := {}
    for k in keys(sc):
        o[k] = sc[k]
    if options != null:
        for k in keys(options):
            o[k] = options[k]
    a := address if address != null else (o["url"] if "url" in o else null)
    if a == null:
        if not app.debug:
            _fail("storage.url manquant (file:dossier, s3://… ; ALWEB_STORAGE__URL)")
        a = "file:media"
    if not ("secret" in o) and cfg != null:
        o["secret"] = cfg.get("secret_key", null)
    st := open(a, o)
    if st.kind == "file" or st.kind == "memory":
        app.get(st.route + "/{key:path}", (req) => st.serve(req), {"hidden": true, "name": "alweb_storage"})
    app.storage = st
    return st

# Enregistre un fichier téléversé (alweb.form(req).file(nom)) sous un nom unique et sûr : prefix + aléa +
# extension du type réel. options : prefix, max_bytes, allowed (types réels permis : « image/png »…). Rend la clé.
async func save_upload(st, file, options=null):
    o := options if options != null else {}
    real := _forms.check_upload(file, o["max_bytes"] if "max_bytes" in o else null, o["allowed"] if "allowed" in o else null)
    key := (o["prefix"] if "prefix" in o else "") + _forms.unique_name(file)
    return await st.put(key, file.data, {"content_type": real if real != null else content_type_of(key)})
