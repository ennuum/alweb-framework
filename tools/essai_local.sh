#!/bin/sh
# Essai local d'alweb, sur votre machine, en quelques minutes :
#   1. ALEX trouvé, en version 1.4.0 ou plus récente (sinon : comment le mettre à jour) ;
#   2. tests rapides du dépôt (--complet : toute la suite, une dizaine de minutes) ;
#   3. un projet neuf (alweb new) : ses tests et ses routes ;
#   4. un thème : create, validate, package, install dans le projet, check ;
#   5. un récapitulatif, et les commandes pour essayer à la main (site vitrine, projet).
#
#   sh tools/essai_local.sh               depuis la racine du dépôt alweb
#   sh tools/essai_local.sh --complet     avec toute la suite de tests
#   sh tools/essai_local.sh --garder      garde le dossier d'essai (sinon effacé à la fin)
# Variable : ALEXC (compilateur, défaut : alexc du PATH).
# Rien n'est installé ni modifié en dehors du dossier d'essai temporaire. Aucun serveur lancé, aucune
# compilation native : l'essai reste léger.

set -u
ICI=$(cd "$(dirname "$0")/.." && pwd)
COMPLET=0
GARDER=0
for a in "$@"; do
  case "$a" in
    --complet) COMPLET=1 ;;
    --garder) GARDER=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "option inconnue : $a (--complet, --garder)"; exit 2 ;;
  esac
done

REUSSIS=0
ECHECS=0
LISTE_ECHECS=""
etape() { printf '\n== %s\n' "$1"; }
ok() { REUSSIS=$((REUSSIS + 1)); printf '  [ok] %s\n' "$1"; }
echec() { ECHECS=$((ECHECS + 1)); LISTE_ECHECS="$LISTE_ECHECS\n  - $1"; printf '  [ÉCHEC] %s\n' "$1"; }
# lance une commande, garde sa sortie dans $JOURNAL ; ok / échec selon son code de sortie
essai() {
  libelle="$1"; shift
  if "$@" > "$JOURNAL" 2>&1; then ok "$libelle"; else echec "$libelle (voir $JOURNAL_DIR/$(basename "$JOURNAL"))"; tail -n 15 "$JOURNAL" | sed 's/^/      /'; fi
  JOURNAL="$JOURNAL_DIR/$(date +%s%N 2>/dev/null || date +%s).log"
}

# ---------------------------------------------------------------- 1. ALEX
etape "1. ALEX"
ALEXC=${ALEXC:-$(command -v alexc 2>/dev/null || true)}
if [ -z "$ALEXC" ] || [ ! -x "$ALEXC" ]; then
  echo "  alexc introuvable. Installez ALEX 1.4.0 ou plus récent (voir docs/ESSAI_LOCAL.md, étape 1), puis :"
  echo "    export PATH=\"/chemin/vers/alex-lang/alex-public:\$PATH\"     # ou ALEXC=/chemin/vers/alexc"
  exit 1
fi
export PATH="$(dirname "$ALEXC"):$PATH"
ok "alexc : $ALEXC ($("$ALEXC" --version 2>/dev/null | head -n 1))"

ESSAI=$(mktemp -d "${TMPDIR:-/tmp}/alweb-essai.XXXXXX")
JOURNAL_DIR="$ESSAI/journaux"
mkdir -p "$JOURNAL_DIR"
JOURNAL="$JOURNAL_DIR/debut.log"
nettoyer() {
  if [ "$GARDER" -eq 0 ] && [ "$ECHECS" -eq 0 ]; then rm -rf "$ESSAI"; fi
}
trap nettoyer EXIT INT TERM

# Des modules arrivés avec ALEX 1.4.0 : s'il en manque un, ALEX est trop ancien (image.encode ne se charge
# qu'en natif : il n'est pas vérifié ici).
cat > "$ESSAI/verif.al" <<'EOF'
use web.server.workers
use thread.offload
use database.async_database
use network.tls13
use network.acme
use crypto.ec
use crypto.x509
print("alex 1.4 : ok")
EOF
if "$ALEXC" check "$ESSAI/verif.al" > "$JOURNAL" 2>&1; then
  ok "ALEX 1.4.0 ou plus récent"
else
  echec "ALEX trop ancien (1.4.0 ou plus récent requis)"
  sed 's/^/      /' "$JOURNAL" | head -n 5
  echo "  Mettez ALEX à jour dans votre dépôt puis reconstruisez :"
  echo "    cd /chemin/vers/alex-lang/alex-public && git pull && make alex"
  exit 1
fi
if "$ALEXC" run "$ESSAI/verif.al" 2>/dev/null | grep -q "alex 1.4 : ok"; then :; fi
if printf 'use database.database as d\nprint("sqlite" in d.backends())\n' > "$ESSAI/sqlite.al" && "$ALEXC" run "$ESSAI/sqlite.al" 2>/dev/null | grep -q true; then
  ok "SQLite disponible"
  SQLITE=1
else
  echo "  [remarque] SQLite indisponible (paquet libsqlite3) : les projets utiliseront une base en mémoire"
  SQLITE=0
fi

# ---------------------------------------------------------------- 2. tests du dépôt
etape "2. Tests du dépôt"
cd "$ICI"
if [ "$COMPLET" -eq 1 ]; then
  essai "suite complète (tests/ et blog du tutoriel)" "$ALEXC" test tests docs/tutoriel/blog/tests
else
  essai "application, gabarits, formulaires et CSRF, thèmes, Apparence, client de marketplace, exemple vitrine" \
    "$ALEXC" test tests/test_templates.al tests/test_forms_csrf.al tests/test_app.al tests/test_themes.al tests/test_apparence.al tests/test_theme_client.al tests/test_vitrine_example.al
fi
grep -E "^(OK|ÉCHEC) :" "$JOURNAL_DIR"/*.log 2>/dev/null | tail -n 1 | sed 's/^[^:]*:/      /'

# ---------------------------------------------------------------- 3. projet
etape "3. Un projet neuf"
ALWEB="$ICI/bin/alweb"
chmod +x "$ALWEB" 2>/dev/null
essai "alweb new essai" "$ALWEB" new essai --dir "$ESSAI/essai"
cd "$ESSAI/essai" 2>/dev/null && {
  essai "alweb test (dans le projet)" "$ALWEB" test
  essai "alweb routes" "$ALWEB" routes
  essai "alweb check" "$ALWEB" check
  cd "$ICI"
}

# ---------------------------------------------------------------- 4. thème
etape "4. Un thème"
essai "alweb theme create mon-theme" "$ALWEB" theme create mon-theme --dir "$ESSAI/mon-theme" --auteur "Essai local"
essai "alweb theme validate" "$ALWEB" theme validate "$ESSAI/mon-theme"
essai "alweb theme package" "$ALWEB" theme package "$ESSAI/mon-theme" --out "$ESSAI/dist"
if [ -d "$ESSAI/essai" ]; then
  cd "$ESSAI/essai"
  essai "alweb theme install (archive locale)" "$ALWEB" theme install "$ESSAI/dist/mon-theme-0.1.0.alwt"
  essai "alweb theme check" "$ALWEB" theme check
  essai "alweb theme list" "$ALWEB" theme list
  cd "$ICI"
fi

# ---------------------------------------------------------------- 5. récapitulatif
etape "Récapitulatif"
echo "  $REUSSIS réussi(s), $ECHECS échec(s)"
if [ "$ECHECS" -gt 0 ]; then
  printf "  Échecs :$LISTE_ECHECS\n"
  echo "  Journaux gardés dans $ESSAI (voir aussi docs/ESSAI_LOCAL.md, « En cas de problème »)."
else
  [ "$GARDER" -eq 1 ] && echo "  Dossier d'essai gardé : $ESSAI"
fi
cat <<EOF

À essayer à la main (Ctrl+C pour arrêter chaque serveur) :
  alexc run examples/vitrine.al          site avec le thème, http://127.0.0.1:8000/
                                          puis /admin/_apparence (mot de passe : vitrine-locale)
  bin/alweb new monsite && cd monsite && ../bin/alweb run      votre projet, http://127.0.0.1:8000/
EOF
[ "$ECHECS" -eq 0 ]
