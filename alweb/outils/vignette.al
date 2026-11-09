# alex: native
# Programme natif des vignettes d'alweb.images (compilé une fois par alweb : alexc build --native), lancé dans un
# processus à part : une image malformée ou énorme ne peut pas faire tomber le serveur, et le décodage tourne en
# code natif (image.encode, ALEX >= 1.4.0).
#
#   vignette <entrée> <sortie> <largeur> <hauteur> <fit|cover|none> <jpeg|png|auto> <qualité>
#
# Écrit <sortie> et <sortie>.info (« largeur hauteur largeur_vignette hauteur_vignette format » : dimensions de
# l'image redressée et de la vignette). Mode « none » : seulement l'.info (dimensions). Image illisible : code 2
# et le message dans <sortie>.err.
use io
use os
use image.encode as enc
use image.raster as rs
from image.raster use Raster
from core use len, to_int

const MAX_PIXELS := 50000000

func main():
    a := os.args()
    if len(a) != 7:
        print("usage : vignette <entrée> <sortie> <largeur> <hauteur> <fit|cover|none> <jpeg|png|auto> <qualité>")
        os.exit(1)
    try:
        work(a)
    catch e:
        io.write_file(a[1] + ".err", e.type + " : " + e.message)
        os.exit(2)

func work(a: list[str]):
    src: Raster := enc.load(io.read_file(a[0]))
    if src.width * src.height > MAX_PIXELS:
        raise("ImageError", "image trop grande (" + str(src.width) + "x" + str(src.height) + ")")
    info := str(src.width) + " " + str(src.height)
    if a[4] == "none":
        io.write_file(a[1] + ".info", info + " 0 0 none")
        return
    small: Raster := enc.resize(src, to_int(a[2]), to_int(a[3]), a[4])
    fmt := a[5]
    if fmt == "auto":
        fmt = "png" if enc.has_alpha(small) else "jpeg"
    io.write_file(a[1], enc.encode(small, fmt, to_int(a[6])))
    io.write_file(a[1] + ".info", info + " " + str(small.width) + " " + str(small.height) + " " + fmt)

main()
