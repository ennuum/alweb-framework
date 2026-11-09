#!/bin/sh
# Lance la suite d'alweb contre un serveur ALEX DB jetable : les tests qui ont une variante « base partagée »
# (ORM, limites, salons, blog, messagerie, ouvriers) tournent sur ALEX DB au lieu de SQLite.
#
#   ALWEB_ALEXDB_HOME=/chemin/vers/AlexDB tools/test_alexdb.sh [fichiers de test...]
#
# Le serveur est initialisé dans un dossier temporaire (compte admin, mot de passe tiré au hasard), écoute sur un
# port libre de 127.0.0.1, puis est arrêté et son dossier supprimé à la fin, même en cas d'échec.
set -eu
: "${ALWEB_ALEXDB_HOME:?ALWEB_ALEXDB_HOME : dossier du projet AlexDB (celui d'alexdb.al)}"
ALEXC=${ALEXC:-alexc}
ICI=$(cd "$(dirname "$0")/.." && pwd)
DATA=$(mktemp -d)
MDP="t$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
JOURNAL="$DATA.log"
SORTIE="$DATA.out"
PID=""
fin() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null || true
    rm -rf "$DATA" "$JOURNAL" "$SORTIE"
}
trap fin EXIT INT TERM
cd "$ALWEB_ALEXDB_HOME"
ALEX_QUIET_RUN=1 "$ALEXC" run alexdb.al -- init --data "$DATA" --user admin --password "$MDP" > /dev/null
ALEX_QUIET_RUN=1 "$ALEXC" run alexdb.al -- serve --data "$DATA" --port 0 --log "$JOURNAL" > "$SORTIE" 2>&1 &
PID=$!
PORT=""
i=0
while [ -z "$PORT" ] && [ $i -lt 600 ]; do
    PORT=$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$SORTIE" | head -1)
    [ -z "$PORT" ] && { kill -0 "$PID" 2>/dev/null || { cat "$SORTIE"; exit 1; }; sleep 0.2; }
    i=$((i + 1))
done
[ -n "$PORT" ] || { echo "serveur ALEX DB non démarré"; cat "$SORTIE"; exit 1; }
echo "ALEX DB sur 127.0.0.1:$PORT"
export ALWEB_TEST_ALEXDB="alexdb://admin:$MDP@127.0.0.1:$PORT/alexdb"
cd "$ICI"
if [ $# -eq 0 ]; then
    set -- tests docs/tutoriel/blog/tests
fi
"$ALEXC" test "$@"
