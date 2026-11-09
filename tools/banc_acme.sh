#!/bin/sh
# Banc ACME local : Pebble (l'autorité de test de Let's Encrypt) et son DNS de test, qui résout tous les noms vers
# 127.0.0.1. Les défis http-01 sont validés sur le port 5002 (celui des tests). Demande Go (>= 1.22) et git.
#
#   tools/banc_acme.sh            # construit au besoin dans build/pebble, puis lance (Ctrl+C pour arrêter)
#   ALWEB_TEST_ACME=https://localhost:14000/dir ALWEB_TEST_ACME_CA=build/pebble/test/certs/pebble.minica.pem \
#       alexc test tests/test_acme.al
#   (côté ALEX : ALEX_TEST_ACME / ALEX_TEST_ACME_CA, alexc run tests/stdlib2/test_acme.al)
#
# Autorité de l'annuaire : build/pebble/test/certs/pebble.minica.pem ; racine des certificats délivrés (change à
# chaque lancement) : https://localhost:15000/roots/0.
set -e
D=$(cd "$(dirname "$0")/.." && pwd)/build/pebble
if [ ! -x "$D/pebble" ] || [ ! -x "$D/challtestsrv" ]; then
    [ -d "$D/.git" ] || git clone --depth 1 https://github.com/letsencrypt/pebble "$D"
    (cd "$D" && go build -o pebble ./cmd/pebble && go build -o challtestsrv ./cmd/pebble-challtestsrv)
fi
cd "$D"
./challtestsrv -defaultIPv6 "" -dnsserver 127.0.0.1:8053 -http01 "" -https01 "" -tlsalpn01 "" -doh "" \
    -management 127.0.0.1:8055 &
DNS=$!
trap 'kill $DNS 2>/dev/null' EXIT INT TERM
PEBBLE_VA_NOSLEEP=1 ./pebble -config test/config/pebble-config.json -dnsserver 127.0.0.1:8053
