# Stockage de fichiers (alweb.storage) : clés, signature AWS V4 (exemples de la documentation d'Amazon S3),
# stockages local et en mémoire avec URL signées servies par l'application, client S3 contre un faux serveur S3
# sur un vrai port qui vérifie chaque signature (en-tête Authorization et URL présignées), enregistrement d'un
# fichier téléversé ; images (alweb.images) : vignettes par le programme natif, variantes enregistrées.
#   alexc test tests/test_storage.al
use os
use io
use time
use string as s
use json
use asyncio as aio
use alweb
use alweb.storage as storage
use alweb.images as images
use alweb.config as conf
use alweb.testing as at
use network.security as sec
use network.encoding as enc
use web.http.response as response
use network.async_client as ac
from testing use assert_eq, assert_true, assert_contains, assert_raises
from core use len
from collections use keys, append, remove

const AK := "AKIAIOSFODNN7EXAMPLE"
const SK := "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

func test_cles():
    assert_eq(storage.check_key("photos//2026/a.jpg"), "photos/2026/a.jpg")
    for faux in ["", "/etc/passwd", "a/../b", "..", "a\\b", "a/./b", "x\u0000y", 3]:
        assert_raises(() => storage.check_key(faux))
    assert_eq(storage.uri_encode("dossier/été 1+1=2.txt"), "dossier/%C3%A9t%C3%A9%201%2B1%3D2.txt")
    assert_eq(storage.uri_encode("a/b", false), "a%2Fb")

# Exemples de « Signature Version 4 » de la documentation d'Amazon S3 (seau examplebucket, 24 mai 2013).
func test_signature_v4_exemples_aws():
    date := "20130524T000000Z"
    vide := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    # GET avec en-tête Range
    sig := storage.signature_v4("GET", "/test.txt", {}, {"host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": vide, "x-amz-date": date}, vide, date, "us-east-1", AK, SK)
    assert_eq(sig[0], "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    assert_eq(sig[1], "host;range;x-amz-content-sha256;x-amz-date")
    # PUT d'un objet (clé « test$file.text », corps « Welcome to Amazon S3. »)
    corps := "Welcome to Amazon S3."
    h := enc.hex_encode(sec.digest(corps, "sha256"))
    assert_eq(h, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    sig = storage.signature_v4("PUT", "/" + storage.uri_encode("test$file.text"), {}, {"date": "Fri, 24 May 2013 00:00:00 GMT", "host": "examplebucket.s3.amazonaws.com", "x-amz-date": date, "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": h}, h, date, "us-east-1", AK, SK)
    assert_eq(sig[0], "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    # URL présignée, valable 24 h
    st := storage.S3Storage("https://s3.amazonaws.com", "examplebucket", AK, SK)
    assert_eq(st.presign("test.txt", 86400, null, 1369353600), "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")

# Liens d'une heure ou plus : les mêmes pendant toute l'heure (cache des navigateurs), toujours valables assez.
func test_liens_stables():
    st := storage.S3Storage("https://s3.amazonaws.com", "examplebucket", AK, SK)
    st.clock = () => 1369353600.0 + 60
    u1 := st.url("a.jpg", 86400)
    st.clock = () => 1369353600.0 + 3000
    assert_eq(st.url("a.jpg", 86400), u1)
    assert_contains(u1, "X-Amz-Date=20130524T000000Z&X-Amz-Expires=90000")
    assert_true(st.url("a.jpg", 300) != st.url("a.jpg", 301))           # liens courts : pas d'arrondi
    m := storage.open("memory:", {"secret": "x" * 32})
    m.clock = () => 1000.0
    v1 := m.url("a.jpg", 7200)
    m.clock = () => 3500.0
    assert_eq(m.url("a.jpg", 7200), v1)
    assert_contains(v1, "?e=10800&")

func test_adresses():
    s3 := storage.open("s3://CLE:se%2Fcret%2B@s3.fr-par.scw.cloud/mon-seau?region=fr-par")
    assert_eq([s3.kind, s3.scheme, s3.host, s3.bucket, s3.access_key, s3.secret_key, s3.region, s3.style], ["s3", "https", "s3.fr-par.scw.cloud", "mon-seau", "CLE", "se/cret+", "fr-par", "path"])
    m := storage.open("s3://a:b@127.0.0.1:9000/b?secure=false&style=virtual")
    assert_eq([m.scheme, m.host, m.style], ["http", "127.0.0.1:9000", "virtual"])
    assert_eq(storage.open("s3://a:b@s3.eu-west-3.amazonaws.com/x").style, "virtual")
    assert_eq(storage.open("file:media").root, "media")
    for faux in ["ftp://x", "s3://hôte/seau", "s3://a:b@hôte", "file:"]:
        assert_raises(() => storage.open(faux))

func appli(adresse):
    app := alweb.App("Fichiers")
    app.configure(conf.from_dict({"secret_key": "s" * 40}))
    st := storage.setup(app, adresse)

    @app.post("/envoi")
    async func envoi(req):
        k := await storage.save_upload(st, alweb.form(req).file("doc"), {"prefix": "docs/", "max_bytes": 1000, "allowed": ["image/png", "application/pdf"]})
        return {"cle": k}
    return app

async func verifier_stockage(st, app):
    assert_eq(await st.put("a/b.txt", "bonjour"), "a/b.txt")
    await st.put("a/c.bin", "\u0000\u0001ÿ")
    await st.put("z.txt", "fin")
    assert_eq(await st.get("a/b.txt"), "bonjour")
    assert_eq(await st.get("absent.txt"), null)
    assert_eq((await st.head("a/b.txt"))["size"], 7)
    assert_eq([x["key"] for x in await st.list("a/")], ["a/b.txt", "a/c.bin"])
    assert_eq(len(await st.list()), 3)
    # URL signée servie par l'application
    c := at.Client(app)
    u := st.url("a/b.txt", 60)
    r := await c.get(u)
    assert_eq([r.status, r.text()], [200, "bonjour"])
    assert_true(s.starts_with(r.headers.get("Content-Type"), "text/plain"))
    r = await c.get(st.url("a/b.txt", 60, "Rapport final.txt"))
    assert_contains(r.headers.get("Content-Disposition"), "attachment; filename=\"Rapport final.txt\"")
    assert_eq((await c.get(s.replace(u, "a/b.txt", "a/c.bin"))).status, 403)        # autre clé : signature fausse
    assert_eq((await c.get(u[0:len(u) - 2] + "00")).status, 403)
    assert_eq((await c.get("/_fichiers/a/b.txt")).status, 403)
    st.clock = () => time.time() + 120
    assert_eq((await c.get(u)).status, 403)                                           # expirée
    st.clock = () => time.time()
    assert_eq((await c.get("/_fichiers/..%2Fsecret?e=9999999999&s=x")).status, 404)
    await st.delete("a/b.txt")
    assert_eq(await st.get("a/b.txt"), null)
    assert_eq((await c.get(st.url("a/b.txt", 60))).status, 404)
    # téléversement : type réel vérifié, nom aléatoire
    png := s.byte_pack([137, 80, 78, 71, 13, 10, 26, 10]) + "reste"
    r = await c.post("/envoi", {"body": multipart("doc", "photo.png", png), "headers": {"Content-Type": "multipart/form-data; boundary=XYZ"}})
    k := r.json_value()["cle"]
    assert_true(s.starts_with(k, "docs/") and s.ends_with(k, ".png") and len(k) == 5 + 32 + 4, k)
    assert_eq(await st.get(k), png)
    r = await c.post("/envoi", {"body": multipart("doc", "x.png", "pas une image"), "headers": {"Content-Type": "multipart/form-data; boundary=XYZ"}})
    assert_eq(r.status, 400)

func multipart(champ, nom, octets):
    return "--XYZ\r\nContent-Disposition: form-data; name=\"" + champ + "\"; filename=\"" + nom + "\"\r\nContent-Type: application/octet-stream\r\n\r\n" + octets + "\r\n--XYZ--\r\n"

async func test_memoire():
    app := appli("memory:")
    await verifier_stockage(app.storage, app)

async func test_disque():
    d := "build/test_storage/disque"
    if os.exists(d):
        os.rmdir(d, true)
    app := appli("file:" + d)
    await verifier_stockage(app.storage, app)
    assert_true(os.isfile(os.join(d, "a", "c.bin")))
    assert_eq(io.read_raw(os.join(d, "a", "c.bin")), "\u0000\u0001ÿ")

# ---------------------------------------------------------------- faux serveur S3

func faux_s3(region):
    app := alweb.App("faux-s3", true)
    objets := {}
    vus := []

    func refus(code, message, statut):
        return response.Response(statut, "<?xml version=\"1.0\"?><Error><Code>" + code + "</Code><Message>" + message + "</Message></Error>")

    func verifier(req):
        hs := {}
        q := {}
        for k in req.query().names():
            q[k] = req.query().get(k)
        if "X-Amz-Signature" in q:                       # URL présignée
            attendu := q["X-Amz-Signature"]
            sans := {}
            for k in keys(q):
                if k != "X-Amz-Signature":
                    sans[k] = q[k]
            sig := storage.signature_v4(req.method, req.raw_path(), sans, {"host": req.header("host")}, "UNSIGNED-PAYLOAD", q["X-Amz-Date"], region, AK, SK)
            return sig[0] == attendu
        auth := req.header("authorization")
        if auth == null:
            return false
        signes := s.split(s.split(s.split(auth, "SignedHeaders=")[1], ",")[0], ";")
        for n in signes:
            hs[n] = req.header(n)
        corps := req.body
        if enc.hex_encode(sec.digest(corps, "sha256")) != req.header("x-amz-content-sha256"):
            return false
        sig := storage.signature_v4(req.method, req.raw_path(), q, hs, req.header("x-amz-content-sha256"), req.header("x-amz-date"), region, AK, SK)
        return s.contains(auth, "Signature=" + sig[0])

    @app.any("/{chemin:path}")
    func s3(req):
        append_vu(vus, req.method + " " + req.raw_path())
        if not verifier(req):
            return refus("SignatureDoesNotMatch", "signature fausse", 403)
        parts := s.split(req.params["chemin"], "/")
        if parts[0] != "seau":
            return refus("NoSuchBucket", "seau inconnu", 404)
        cle := s.join("/", parts[1:len(parts)])
        if cle == "":
            pre := req.query_param("prefix", "")
            xml := "<ListBucketResult><IsTruncated>false</IsTruncated>"
            ks := [k for k in keys(objets) if s.starts_with(k, pre)]
            for k in tri(ks):
                xml = xml + "<Contents><Key>" + k + "</Key><Size>" + str(s.byte_len(objets[k][0])) + "</Size><LastModified>2026-11-08T10:00:00.000Z</LastModified></Contents>"
            return response.Response(200, xml + "</ListBucketResult>")
        if req.method == "PUT":
            objets[cle] = [req.body, req.header("content-type")]
            return response.Response(200, "")
        if req.method == "DELETE":
            if cle in objets:
                remove(objets, cle)
            return response.Response(204, "")
        if not (cle in objets):
            return refus("NoSuchKey", "clé absente", 404)
        r := response.Response(200, objets[cle][0])       # HEAD : le serveur garde la longueur, retire le corps
        r.headers.set("Content-Type", objets[cle][1])
        if req.query_param("response-content-disposition") != null:
            r.headers.set("Content-Disposition", req.query_param("response-content-disposition"))
        return r
    return [app, objets, vus]

func append_vu(vus, x):
    append(vus, x)

func tri(xs):
    return storage._sort(xs)

async func servir(srv, fin):
    while not fin[0]:
        await srv.serve_for_async(0.01)

async func test_client_s3():
    f := faux_s3("fr-par")
    srv := f[0].server("127.0.0.1", 0).start()
    fin := [false]
    tache := servir(srv, fin)
    try:
        st := storage.open("s3://" + AK + ":" + s.replace(SK, "/", "%2F") + "@127.0.0.1:" + str(srv.port()) + "/seau?secure=false&region=fr-par")
        assert_eq(await st.put("photos/été 1.jpg", "\u0000octetsÿ", {"content_type": "image/jpeg"}), "photos/été 1.jpg")
        await st.put("photos/b.png", "png")
        await st.put("notes.txt", "n")
        assert_eq(f[1]["photos/été 1.jpg"], ["\u0000octetsÿ", "image/jpeg"])
        assert_eq(await st.get("photos/été 1.jpg"), "\u0000octetsÿ")
        assert_eq(await st.get("absent"), null)
        h := await st.head("photos/b.png")
        assert_eq([h["size"], h["content_type"]], [3, "image/png"])
        assert_eq(await st.head("absent"), null)
        l := await st.list("photos/")
        assert_eq([x["key"] for x in l], ["photos/b.png", "photos/été 1.jpg"])
        assert_eq(l[0]["modified"], 1794132000)
        await st.delete("notes.txt")
        assert_eq(len(await st.list()), 2)
        # URL présignée : utilisable telle quelle (vérifiée par le faux serveur)
        r := await alweb_get(st.url("photos/été 1.jpg", 300, "Ma photo.jpg"))
        assert_eq([r.status, r.body], [200, "\u0000octetsÿ"])
        assert_contains(r.headers.get("content-disposition"), "filename=\"Ma photo.jpg\"")
        u := st.url("photos/b.png", 300)
        assert_eq((await alweb_get(s.replace(u, "photos/b.png", "photos/autre.png"))).status, 403)
        # mauvais secret : erreur S3 rendue lisible
        faux := storage.open("s3://" + AK + ":mauvais@127.0.0.1:" + str(srv.port()) + "/seau?secure=false&region=fr-par")
        try:
            await faux.put("x", "y")
            assert_true(false, "signature fausse acceptée")
        catch e:
            assert_eq(e.type, "StorageError")
            assert_contains(e.message, "SignatureDoesNotMatch : signature fausse")
        assert_true("PUT /seau/photos/%C3%A9t%C3%A9%201.jpg" in f[2])
    catch e:
        fin[0] = true
        await tache
        srv.close()
        raise(e.type, e.message)
    fin[0] = true
    await tache
    srv.close()

async func alweb_get(url):
    return await ac.request("GET", url, null, null, null, 10.0, true, null, 0)

# ---------------------------------------------------------------- images

func photo():
    return io.read_raw("tests/fixtures/photo.jpg")

async func test_vignettes():
    d := photo()
    v := await images.thumbnail(d, 160, 160)
    assert_eq([v["width"], v["height"], v["format"], v["content_type"], v["source_width"], v["source_height"]], [160, 120, "jpeg", "image/jpeg", 640, 480])
    assert_true(s.starts_with(v["data"], s.byte_pack([255, 216, 255])))
    c := await images.thumbnail(d, 100, 100, {"mode": "cover", "format": "png"})
    assert_eq([c["width"], c["height"], c["format"]], [100, 100, "png"])
    assert_eq(await images.info(io.read_raw("tests/fixtures/portrait_exif6.jpg")), {"width": 24, "height": 48})
    try:
        await images.thumbnail("pas une image", 10, 10)
        assert_true(false, "image fausse acceptée")
    catch e:
        assert_eq(e.type, "ImageError")
        assert_contains(e.message, "image illisible : ImageError : format d'image inconnu")
    assert_eq([images._valid_name("../x"), images._valid_name("vignette_2")], [false, true])
    # plusieurs vignettes en même temps : le serveur n'attend pas, le programme n'est construit qu'une fois
    t0 := time.monotonic()
    ts := [images.thumbnail(d, 64 + i, 64, {"mode": "cover"}) for i in [0, 1, 2, 3]]
    tailles := []
    for t in ts:
        append(tailles, (await t)["width"])
    assert_eq(tailles, [64, 65, 66, 67])

async func test_images_enregistrees():
    st := storage.open("memory:")
    r := await images.store(st, photo(), {"prefix": "photos/", "sizes": {"vignette": [200, 200, "cover"], "moyenne": [400, 400]}})
    assert_eq([r["width"], r["height"], r["content_type"]], [640, 480, "image/jpeg"])
    assert_true(s.starts_with(r["key"], "photos/") and s.ends_with(r["key"], ".jpg"))
    assert_eq(r["variants"]["vignette"], s.replace(r["key"], ".jpg", "-vignette.jpg"))
    assert_eq(len(await st.list("photos/")), 3)
    assert_eq(await st.get(r["key"]), photo())
    await images.remove(st, r)
    assert_eq(len(await st.list()), 0)
    try:
        await images.store(st, "pas une image", {"sizes": {"v": [10, 10]}})
        assert_true(false, "image fausse enregistrée")
    catch e:
        assert_eq(e.type, "UploadError")
    assert_eq(len(await st.list()), 0)                           # rien n'est resté

# Vrai stockage S3 (MinIO, Scaleway, Amazon…) : ALWEB_TEST_S3=s3://CLÉ:SECRET@hôte:port/seau?region=…&secure=false
# Le seau doit exister ; tout est écrit sous un préfixe aléatoire, effacé à la fin.
async func test_vrai_s3():
    adresse := os.getenv("ALWEB_TEST_S3")
    if adresse == null or adresse == "":
        print("  (ALWEB_TEST_S3 absent : pas de vrai stockage S3)")
        return
    st := storage.open(adresse)
    pre := "alweb-test-" + sec.random_hex(6) + "/"
    try:
        binaire := "\u0000\u0001ÿ" + s.repeat("é", 2000)
        await st.put(pre + "dossier/été 1.bin", binaire, {"content_type": "application/octet-stream"})
        await st.put(pre + "b.txt", "bonjour", {"content_type": "text/plain"})
        await st.put(pre + "c.jpg", photo())
        assert_eq(await st.get(pre + "dossier/été 1.bin"), binaire)
        assert_eq(await st.get(pre + "absent"), null)
        h := await st.head(pre + "b.txt")
        assert_eq([h["size"], s.starts_with(h["content_type"], "text/plain")], [7, true])
        assert_eq([x["key"] for x in await st.list(pre)], [pre + "b.txt", pre + "c.jpg", pre + "dossier/été 1.bin"])
        assert_eq(len(await st.list(pre, 2)), 2)
        r := await alweb_get(st.url(pre + "c.jpg", 120, "Ma photo.jpg"))
        assert_eq([r.status, r.body == photo()], [200, true])
        assert_contains(r.headers.get("content-disposition"), "Ma photo.jpg")
        assert_eq((await alweb_get(st.url(pre + "b.txt", 86400))).body, "bonjour")       # lien stable d'une heure
        u := st.url(pre + "b.txt", 120)
        assert_eq((await alweb_get(s.replace(u, "b.txt", "c.jpg"))).status, 403)        # signature d'une autre clé
        im := await images.store(st, photo(), {"prefix": pre + "photos/", "sizes": {"vignette": [100, 100, "cover"]}})
        assert_eq(len(await st.list(pre + "photos/")), 2)
        await images.remove(st, im)
        print("  vrai S3 : " + st.host + "/" + st.bucket + " (" + st.style + ")")
    catch e:
        for x in await st.list(pre):
            await st.delete(x["key"])
        raise(e.type, e.message)
    for x in await st.list(pre):
        await st.delete(x["key"])
    assert_eq(len(await st.list(pre)), 0)
