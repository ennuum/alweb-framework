# Image Docker de {{Nom}} (générée par `alweb deploy docker`).
#   docker build -f deploy/Dockerfile --build-arg ALEX_DIST_URL=https://.../alex-<version>-linux-x86_64.tar.gz -t {{nom}} .
#   docker run -p {{port}}:{{port}} -e ALWEB_SECRET_KEY=... -v {{nom}}-donnees:/donnees {{nom}}
# ALEX_DIST_URL : archive Linux produite par `make package` dans le dépôt d'ALEX (ALEX 1.4.0 ou plus récent).
# Les dépendances (alex_packages/) doivent être installées avant la construction : `alexc pkg install`.
FROM debian:bookworm-slim

ARG ALEX_DIST_URL
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libsqlite3-0 libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && test -n "$ALEX_DIST_URL" || { echo "--build-arg ALEX_DIST_URL=... requis"; exit 1; } \
 && curl -fsSL "$ALEX_DIST_URL" -o /tmp/alex.tar.gz \
 && mkdir -p /tmp/alex && tar -xzf /tmp/alex.tar.gz -C /tmp/alex --strip-components=1 \
 && sh /tmp/alex/install.sh /usr/local && rm -rf /tmp/alex /tmp/alex.tar.gz \
 && useradd --system --create-home --home-dir /srv/app --shell /usr/sbin/nologin app \
 && mkdir -p /donnees && chown app:app /donnees

WORKDIR /srv/app
COPY --chown=app:app . .
USER app
# Vérifie le code (syntaxe, modules, types) dès la construction de l'image.
RUN alex check main.al

ENV ALWEB_ENV=prod \
    ALWEB_SERVER__HOST=0.0.0.0 \
    ALWEB_SERVER__PORT={{port}} \
    ALWEB_DATABASE__URL=sqlite:/donnees/{{nom}}.db
EXPOSE {{port}}
VOLUME ["/donnees"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD curl -fsS http://127.0.0.1:{{port}}/sante || exit 1
STOPSIGNAL SIGTERM
CMD ["alex", "run", "main.al"]
