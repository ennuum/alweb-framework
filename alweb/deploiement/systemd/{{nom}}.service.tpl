# Service systemd de {{Nom}} (généré par `alweb deploy systemd`).
#   sudo cp deploy/{{nom}}.service /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now {{nom}}
#   journalctl -u {{nom}} -f                      # journal (une ligne JSON par requête en profil prod)
# Secrets : {{dossier}}/.env (droits 600), au moins ALWEB_SECRET_KEY=... (voir deploy/env.exemple).
[Unit]
Description={{Nom}} (alweb)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{utilisateur}}
Group={{utilisateur}}
WorkingDirectory={{dossier}}
Environment=ALWEB_ENV=prod
Environment=ALWEB_SERVER__PORT={{port}}
EnvironmentFile={{dossier}}/.env
ExecStart={{alex}} run {{dossier}}/main.al
# Arrêt propre : TERM laisse finir les requêtes en cours puis lance les fonctions d'arrêt (on_shutdown).
KillSignal=SIGTERM
TimeoutStopSec=20
Restart=on-failure
RestartSec=2

# Durcissement : système en lecture seule sauf le dossier de l'application (base SQLite, cache .albc, media/).
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths={{dossier}}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
