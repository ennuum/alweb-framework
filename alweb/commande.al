# Point d'entrée de la commande `alweb` (voir alweb.cli) :
#   alexc run <paquet alweb>/commande.al -- new monblog
# Les lanceurs bin/alweb (sh) et bin/alweb.cmd (Windows) du dépôt font cet appel.
use os
use alweb.cli as _cli

os.exit(_cli.main(os.args()))
