# nginx devant {{Nom}} (généré par `alweb deploy nginx`).
#   sudo cp deploy/{{nom}}.conf /etc/nginx/sites-available/ && sudo ln -s ../sites-available/{{nom}}.conf /etc/nginx/sites-enabled/
#   sudo certbot --nginx -d {{domaine}}            # certificat (remplit ssl_certificate*)
#   sudo nginx -t && sudo systemctl reload nginx
# L'application écoute sur 127.0.0.1:{{port}} ; config/prod.json fait confiance à 127.0.0.1 pour
# X-Forwarded-For (IP réelle dans les journaux et les limites de débit).

upstream {{nom}} {
    server 127.0.0.1:{{port}};
    keepalive 32;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

server {
    listen 80;
    listen [::]:80;
    server_name {{domaine}};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name {{domaine}};

    ssl_certificate     /etc/letsencrypt/live/{{domaine}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{domaine}}/privkey.pem;

    client_max_body_size 10m;          # téléversements (alignez sur vos check_upload)
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    location /static/ {
        alias {{dossier}}/static/;
        expires 1h;
        gzip_static on;                # sert site.css.gz s'il existe
    }

    location / {
        proxy_pass http://{{nom}};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 1h;
        # SSE et flux : pas de mise en tampon
        proxy_buffering off;
    }
}
