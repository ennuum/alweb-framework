# Client de marketplace (alweb.themes.client) et signatures (alweb.themes.signing), sans serveur : les réponses
# d'une marketplace sont simulées selon docs/MARKETPLACE_PROTOCOLE.md (aucun serveur n'est fourni par alweb).
# Choix de version, téléchargement vérifié (taille, SHA-256, signature), clé de l'éditeur épinglée, reçu
# d'avis, mises à jour, publication signée, retrait, limite de débit, recherche.
#   alexc test tests/test_theme_client.al
use os
use io
use json
use string as s
use alweb.cli as cli
use alweb.themes.client as client
use alweb.themes.signing as signing
use alweb.themes.package as package
use alweb.themes.registry as registry
use web.url.form_url_encoding as form
from core use len
from collections use append, keys
from testing use assert_eq, assert_true, assert_false, assert_contains, assert_raises

const BASE := "build/test_theme_client"
const URL := "http://market.test"
CLE := signing.generate()

func neuf(d):
    if os.exists(d):
        os.rmdir(d, true)
    os.mkdir_all(d)
    return d

func erreur(f):
    try:
        f()
    catch e:
        return e.message
    return null

# Archive du thème modèle (slug, version) : octets.
func archive(slug, version, champs=null):
    d := os.join(BASE, "src-" + slug + "-" + version)
    if os.exists(d):
        os.rmdir(d, true)
    cli.create_theme(slug, {"dir": d, "modele": "alweb/modele-theme", "auteur": "Test"})
    p := os.join(d, "alweb-theme.json")
    m := json.parse(io.read_file(p))
    m["version"] = version
    if champs != null:
        for k in keys(champs):
            m[k] = champs[k]
    io.write_file(p, json.stringify(m))
    return io.read_raw(package.build(d, neuf(os.join(BASE, "dist-" + slug + "-" + version)))["path"])

# Marketplace simulée : fiche et archives comme le décrit le protocole.
class FausseMarketplace:
    func init():
        self.reponses = {}
        self.journal = []
        self.envois = []

    func publier(slug, versions, cle=null, yanked=null):
        k := cle if cle != null else CLE
        vs := []
        for v in versions:
            data := archive(slug, v[0], {"framework_version": v[1]})
            sha := package.sha256_hex(data)
            append(vs, {"version": v[0], "framework_version": v[1], "sha256": sha, "size": s.byte_len(data), "yanked": yanked != null and v[0] in yanked,
                        "signature": signing.sign(k["private"], slug, v[0], sha), "archive": "/api/v1/themes/" + slug + "/" + v[0] + "/archive"})
            self.reponses["GET " + URL + "/api/v1/themes/" + slug + "/" + v[0] + "/archive"] = {"status": 200, "headers": {"x-alweb-review-token": "recu-" + slug + "-" + v[0]}, "body": data}
        fiche := {"slug": slug, "name": slug, "versions": vs, "publisher": {"name": "ennuum", "public_key": k["public"], "fingerprint": k["fingerprint"]}}
        self.reponses["GET " + URL + "/api/v1/themes/" + slug] = {"status": 200, "headers": {}, "body": json.stringify(fiche)}
        return fiche

    func fiche(slug):
        return json.parse(self.reponses["GET " + URL + "/api/v1/themes/" + slug]["body"])

    func remplacer_fiche(slug, d):
        self.reponses["GET " + URL + "/api/v1/themes/" + slug] = {"status": 200, "headers": {}, "body": json.stringify(d)}

    func transport():
        return (method, url, body, headers) => self.repondre(method, url, body, headers)

    func repondre(method, url, body, headers):
        append(self.journal, method + " " + url)
        if method == "POST":
            append(self.envois, {"url": url, "body": body, "headers": headers})
            return {"status": 201, "headers": {}, "body": "{\"slug\": \"x\", \"version\": \"1.0.0\", \"status\": \"visible\", \"created\": true, \"deleted\": true, \"yanked\": true}"}
        k := method + " " + url
        if k in self.reponses:
            return self.reponses[k]
        i := s.find(url, "?")
        if i > 0 and (method + " " + url[0:i]) in self.reponses:
            return self.reponses[method + " " + url[0:i]]
        return {"status": 404, "headers": {}, "body": "{\"error\": \"inconnu\"}"}

func test_signatures():
    sha := "ab" * 32
    sig := signing.sign(CLE["private"], "x-theme", "1.0.0", sha)
    assert_true(signing.verify(CLE["public"], "x-theme", "1.0.0", sha, sig))
    assert_eq(signing.sign(CLE["private"], "x-theme", "1.0.0", sha), sig)                 # RFC 6979 : déterministe
    for faux in [["y-theme", "1.0.0", sha], ["x-theme", "1.0.1", sha], ["x-theme", "1.0.0", "cd" * 32]]:
        assert_false(signing.verify(CLE["public"], faux[0], faux[1], faux[2], sig))
    assert_false(signing.verify(signing.generate()["public"], "x-theme", "1.0.0", sha, sig))
    assert_false(signing.valid_public("04" + "00" * 64))
    p := os.join(neuf(os.join(BASE, "cles")), "editeur.json")
    signing.save_key(p, CLE)
    assert_eq(signing.load_key(p)["fingerprint"], CLE["fingerprint"])
    if os.platform() != "windows":
        assert_eq(os.permissions(p) % 512, 384)
    assert_raises(() => signing.load_key(os.join(BASE, "cles", "absente.json")))

func test_choix_de_version():
    fm := FausseMarketplace()
    d := fm.publier("modern-business", [["1.0.0", ">=0.9.0"], ["1.1.0", ">=0.9.0"], ["1.2.0", ">=0.9.0"], ["2.0.0", ">=9.0.0"]], null, ["1.2.0"])
    assert_eq(client.choose(d)["version"], "1.1.0")                                     # 2.0.0 incompatible, 1.2.0 retirée
    assert_eq(client.choose(d, "~1.0.0")["version"], "1.0.0")
    assert_eq(client.choose(d, "1.2.0")["version"], "1.2.0")                           # retirée, mais demandée exactement
    assert_eq(client.choose(d, ">=3.0.0"), null)
    assert_eq(client.parse_spec("modern-business@^1.2"), ["modern-business", "^1.2"])
    assert_eq(client.parse_spec("modern-business"), ["modern-business", null])

async func test_installation_mises_a_jour_et_avis():
    fm := FausseMarketplace()
    fm.publier("modern-business", [["1.0.0", ">=0.9.0"], ["1.1.0", ">=0.9.0"]])
    c := client.Client(URL + "/", {"transport": fm.transport()})
    assert_eq(c.url, URL)
    reg := registry.Registry(neuf(os.join(BASE, "projet")))
    e := client.install(reg, c, "modern-business", "1.0.0")
    assert_eq([e["version"], e["source"], e["publisher"], e["publisher_key"], e["review_token"]], ["1.0.0", "marketplace:" + URL, "ennuum", CLE["public"], "recu-modern-business-1.0.0"])
    assert_eq(reg.active(), "modern-business")
    assert_eq(os.list_dir(os.join(reg.dir, ".telechargements")), [])
    assert_eq(client.updates(reg, c), [{"slug": "modern-business", "installed": "1.0.0", "available": "1.1.0"}])
    e = client.install(reg, c, "modern-business", "1.1.0")
    assert_eq([e["version"], e["previous"], e["review_token"]], ["1.1.0", "1.0.0", "recu-modern-business-1.1.0"])
    assert_eq(client.updates(reg, c), [])
    # avis : le reçu du verrou, envoyé avec la note
    rt := client.review_token_for(reg, c, "modern-business")
    assert_eq(rt, ["recu-modern-business-1.1.0", "1.1.0"])
    c.review("modern-business", rt[0], {"rating": 4, "title": "Bien", "body": null, "author": "Awa"}, rt[1])
    envoi := fm.envois[len(fm.envois) - 1]
    assert_eq(envoi["url"], URL + "/api/v1/themes/modern-business/reviews")
    assert_eq(envoi["headers"]["Content-Type"], "application/json")
    corps := json.parse(envoi["body"])
    assert_eq([corps["token"], corps["rating"], corps["version"], corps["author"]], ["recu-modern-business-1.1.0", 4, "1.1.0", "Awa"])
    c.delete_review("modern-business", rt[0])
    assert_eq(fm.envois[len(fm.envois) - 1]["url"], URL + "/api/v1/themes/modern-business/reviews/delete")
    assert_contains(erreur(() => client.review_token_for(reg, client.Client("http://autre.test"), "modern-business")), "n'a pas été installé depuis http://autre.test")
    assert_contains(erreur(() => client.review_token_for(reg, c, "inconnu")), "n'est pas installé")
    assert_contains(erreur(() => client.install(reg, c, "inconnu")), "introuvable")

async func test_archives_alterees_et_cles():
    fm := FausseMarketplace()
    fm.publier("modern-business", [["1.0.0", ">=0.9.0"]])
    c := client.Client(URL, {"transport": fm.transport()})
    url := "GET " + URL + "/api/v1/themes/modern-business/1.0.0/archive"
    bon := fm.reponses[url]
    reg := registry.Registry(neuf(os.join(BASE, "projet-alteration")))
    fm.reponses[url] = {"status": 200, "headers": {}, "body": bon["body"] + "x"}
    assert_contains(erreur(() => client.install(reg, c, "modern-business")), "taille reçue")
    octets := s.byte_unpack(bon["body"])
    octets[100] = (octets[100] + 1) % 256
    fm.reponses[url] = {"status": 200, "headers": {}, "body": s.byte_pack(octets)}
    assert_contains(erreur(() => client.install(reg, c, "modern-business")), "empreinte SHA-256 différente")
    fm.reponses[url] = {"status": 429, "headers": {"retry-after": "42"}, "body": "{}"}
    assert_contains(erreur(() => client.install(reg, c, "modern-business")), "réessayez dans 42 s")
    fm.reponses[url] = bon
    # signature qui ne correspond pas à la clé annoncée
    d := fm.fiche("modern-business")
    d["versions"][0]["signature"] = "3045" + "00" * 69
    fm.remplacer_fiche("modern-business", d)
    assert_contains(erreur(() => client.install(reg, c, "modern-business")), "signature de l'éditeur invalide")
    assert_false(os.isdir(os.join(reg.dir, "modern-business")))                           # rien d'installé
    # première installation : la clé est épinglée ; une autre clé annoncée ensuite est refusée
    fm.publier("modern-business", [["1.0.0", ">=0.9.0"]])
    client.install(reg, c, "modern-business")
    pirate := signing.generate()
    fm.publier("modern-business", [["1.0.1", ">=0.9.0"]], pirate)
    assert_contains(erreur(() => client.install(reg, c, "modern-business")), "la clé de l'éditeur a changé")
    assert_eq(client.install(reg, c, "modern-business", null, false, true)["publisher_key"], pirate["public"])   # --nouvelle-cle
    # archive d'un autre thème servie sous ce nom
    fm.publier("autre-theme", [["1.0.0", ">=0.9.0"]])
    fm.reponses["GET " + URL + "/api/v1/themes/autre-theme/1.0.0/archive"] = fm.reponses["GET " + URL + "/api/v1/themes/modern-business/1.0.1/archive"]
    d = fm.fiche("autre-theme")
    data := fm.reponses["GET " + URL + "/api/v1/themes/autre-theme/1.0.0/archive"]["body"]
    d["versions"][0]["sha256"] = package.sha256_hex(data)
    d["versions"][0]["size"] = s.byte_len(data)
    d["versions"][0]["signature"] = signing.sign(CLE["private"], "autre-theme", "1.0.0", package.sha256_hex(data))
    fm.remplacer_fiche("autre-theme", d)
    assert_contains(erreur(() => client.install(registry.Registry(neuf(os.join(BASE, "projet-autre"))), c, "autre-theme")), "archive incohérente")

func test_publication_retrait_et_recherche():
    fm := FausseMarketplace()
    c := client.Client(URL, {"transport": fm.transport(), "token": "alwt_jeton"})
    data := archive("theme-publie", "1.0.0")
    p := os.join(BASE, "theme-publie-1.0.0.alwt")
    io.write_file(p, data)
    c.publish(p, CLE)
    e := fm.envois[0]
    assert_eq([e["url"], e["headers"]["Authorization"], e["headers"]["X-Alweb-Public-Key"], e["headers"]["Content-Type"]],
              [URL + "/api/v1/themes", "Bearer alwt_jeton", CLE["public"], "application/vnd.alweb.theme+zip"])
    assert_true(signing.verify(CLE["public"], "theme-publie", "1.0.0", package.sha256_hex(data), e["headers"]["X-Alweb-Signature"]))
    assert_eq(e["body"], data)
    c.yank("theme-publie", "1.0.0")
    c.yank("theme-publie", "1.0.0", true)
    assert_eq([x["url"] for x in fm.envois[1:3]], [URL + "/api/v1/themes/theme-publie/1.0.0/yank", URL + "/api/v1/themes/theme-publie/1.0.0/unyank"])
    assert_contains(erreur(() => client.Client(URL, {"transport": fm.transport(), "token": ""}).publish(p, CLE)), "jeton d'éditeur absent")
    # recherche : paramètres transmis
    fm.reponses["GET " + URL + "/api/v1/themes"] = {"status": 200, "headers": {}, "body": "{\"items\": [{\"slug\": \"a\"}], \"total\": 1}"}
    assert_eq(c.search("vitrine pro", "business", "0.9.0", "rating"), [{"slug": "a"}])
    assert_eq(fm.journal[len(fm.journal) - 1], "GET " + URL + "/api/v1/themes?" + form.encode({"q": "vitrine pro", "sort": "rating", "category": "business", "alweb": "0.9.0"}))
    assert_contains(erreur(() => client.Client("ftp://x")), "adresse de marketplace invalide")
