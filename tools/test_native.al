# Lance la suite de tests compilée en natif (alexc build --native), depuis la racine du dépôt :
#   alexc run tools/test_native.al [tests/test_x.al ...]
# Les fichiers de tests « test_* » sont réunis dans un seul exécutable (une compilation) ; les fichiers qui sont
# des programmes (if thread.is_main(): / workers.is_worker()) sont compilés et lancés un par un. Variables :
#   ALEXC                compilateur (défaut : alexc trouvé dans PATH)
#   ALWEB_NATIVE_SKIP    fichiers à ignorer, séparés par des virgules (ex. tests qui demandent TLS ou SQLite, que
#                        l'exécutable natif ne fournit pas)
# Code de sortie : 0 si tout passe.
from core use len
from collections use append
use os
use io
use string as s
use process as pr

func lister(args):
    if len(args) > 0:
        return args
    out := []
    for n in os.list_dir("tests"):
        if s.starts_with(n, "test_") and s.ends_with(n, ".al"):
            append(out, "tests/" + n)
    return sorted(out)

func sorted(xs):
    out := xs + []
    i := 1
    while i < len(out):
        j := i
        while j > 0 and out[j - 1] > out[j]:
            t := out[j]
            out[j] = out[j - 1]
            out[j - 1] = t
            j -= 1
        i += 1
    return out

func est_programme(texte):
    return s.contains(texte, "\nif thread.is_main():") or s.contains(texte, "\nif workers.is_worker():")

func fonctions_de_test(texte):
    out := []
    for ligne in s.split(texte, "\n"):
        l := ligne
        if s.starts_with(l, "async func test_"):
            l = s.substring(l, 6, len(l))
        if s.starts_with(l, "func test_"):
            k := s.find(l, "(")
            append(out, s.substring(l, 5, k))
    return out

func module_de(chemin):
    return s.replace(s.replace(chemin, ".al", ""), "/", ".")

func compiler(alexc, source, sortie):
    env := {"ALEX_PATH": os.cwd()}
    r := pr.run(alexc, ["build", source, "--native", "-o", sortie], null, 1800.0, null, env)
    if r.code != 0:
        print(r.stdout + r.stderr)
        return false
    return true

args := os.args()
alexc := os.getenv("ALEXC")
if alexc == null or alexc == "":
    alexc = pr.which("alexc")
skip := []
sk := os.getenv("ALWEB_NATIVE_SKIP")
if sk != null and sk != "":
    for x in s.split(sk, ","):
        append(skip, s.trim(x))
dossier := "build/native-tests"
if not os.exists("build"):
    os.mkdir("build")
if not os.exists(dossier):
    os.mkdir(dossier)

modules := []
programmes := []
for f in lister(args):
    if f in skip:
        print("ignoré : " + f)
        continue
    t := io.read_file(f)
    if est_programme(t):
        append(programmes, f)
    else:
        append(modules, [f, fonctions_de_test(t)])

# exécutable unique pour les fichiers de fonctions test_*
src := ["# généré par tools/test_native.al", "use asyncio as aio", "use os", "from collections use append", ""]
i := 0
for m in modules:
    append(src, "use " + module_de(m[0]) + " as m" + str(i))
    i += 1
append(src, "")
append(src, "async func appeler(f):")
append(src, "    r := f()")
append(src, "    if aio.is_future(r):")
append(src, "        await r")
append(src, "")
append(src, "TESTS := [")
i = 0
for m in modules:
    for fn in m[1]:
        append(src, "    [\"" + m[0] + " :: " + fn + "\", m" + str(i) + "." + fn + "],")
    i += 1
append(src, "]")
append(src, "echecs := []")
append(src, "ignores := []")
append(src, "for t in TESTS:")
append(src, "    try:")
append(src, "        await appeler(t[1])")
append(src, "        print(\"  ✓ \" + t[0])")
append(src, "    catch e:")
append(src, "        if e.type == \"SkipTest\":")
append(src, "            print(\"  ○ \" + t[0] + \" : \" + str(e.message))")
append(src, "            append(ignores, t[0])")
append(src, "        else:")
append(src, "            print(\"  ✗ \" + t[0] + \" : \" + str(e.type) + \" : \" + str(e.message))")
append(src, "            append(echecs, t[0])")
append(src, "print(str(len(TESTS) - len(echecs) - len(ignores)) + \" réussi(s), \" + str(len(echecs)) + \" échec(s), \" + str(len(ignores)) + \" ignoré(s)\")")
append(src, "os.exit(1 if len(echecs) > 0 else 0)")
io.write_file(dossier + "/runner.al", s.join("\n", src) + "\n")

total_ok := 0
total := 0
echecs := []
if len(modules) > 0:
    print("compilation native de " + str(len(modules)) + " fichier(s) de tests…")
    if not compiler(alexc, dossier + "/runner.al", dossier + "/runner"):
        print("ÉCHEC de la compilation")
        os.exit(1)
    r := pr.run(dossier + "/runner", [], null, 1800.0)
    print(r.stdout + r.stderr)
    n := 0
    for m in modules:
        n += len(m[1])
    ignores := 0
    for ligne in s.split(r.stdout, "\n"):
        if s.starts_with(ligne, "  ○ "):
            ignores += 1
        elif r.code != 0 and s.starts_with(ligne, "  ✗ "):
            append(echecs, ligne)
    total += n - ignores
    total_ok += n - ignores - len(echecs)
for f in programmes:
    nom := s.replace(s.replace(f, "tests/", ""), ".al", "")
    sortie := dossier + "/" + nom
    print("compilation native de " + f + "…")
    total += 1
    if not compiler(alexc, f, sortie):
        append(echecs, f + " (compilation)")
        continue
    r := pr.run(sortie, [], null, 600.0)
    if r.code == 0:
        total_ok += 1
        print("  ✓ " + f)
    else:
        append(echecs, f)
        print("  ✗ " + f + "\n" + r.stdout + r.stderr)
print("")
print("natif : " + str(total_ok) + " réussi(s) sur " + str(total))
for e in echecs:
    print("  " + e)
os.exit(0 if len(echecs) == 0 else 1)
