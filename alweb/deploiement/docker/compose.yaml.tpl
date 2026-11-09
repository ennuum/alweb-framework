# {{Nom}} avec Docker Compose (généré par `alweb deploy docker`) : l'application et Caddy (HTTPS automatique).
#   ALEX_DIST_URL=https://.../alex-<version>-linux-x86_64.tar.gz ALWEB_SECRET_KEY=$(alweb secret) \
#     docker compose -f deploy/compose.yaml up -d --build
services:
  app:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
      args:
        ALEX_DIST_URL: ${ALEX_DIST_URL:?archive Linux d'ALEX}
    environment:
      ALWEB_SECRET_KEY: ${ALWEB_SECRET_KEY:?clé secrète (alweb secret)}
      # Caddy est sur le réseau interne de Compose (adresses 172.x par défaut) : ses en-têtes
      # X-Forwarded-For sont crus. Préfixes au format de web.server : « 172. », IP exactes ou « * ».
      ALWEB_SERVER__TRUSTED_PROXIES: '["172.", "10."]'
    volumes:
      - donnees:/donnees
    restart: unless-stopped

  caddy:
    image: caddy:2
    command: caddy reverse-proxy --from {{domaine}} --to app:{{port}}
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - caddy:/data
    restart: unless-stopped

volumes:
  donnees:
  caddy:
