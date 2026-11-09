# Caddy devant {{Nom}} (généré par `alweb deploy caddy`) : certificat HTTPS automatique (Let's Encrypt),
# HTTP/2 et HTTP/3 vers les navigateurs, WebSocket et SSE transmis sans réglage.
#   sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
# L'application écoute sur 127.0.0.1:{{port}} ; config/prod.json fait confiance à 127.0.0.1 pour
# X-Forwarded-For (IP réelle dans les journaux et les limites de débit).
{{domaine}} {
	encode zstd gzip

	# Fichiers statiques servis directement par Caddy (facultatif : alweb sait aussi les servir).
	handle_path /static/* {
		root * {{dossier}}/static
		file_server
		header Cache-Control "public, max-age=3600"
	}

	handle {
		reverse_proxy 127.0.0.1:{{port}} {
			# SSE : chaque événement part aussitôt.
			flush_interval -1
		}
	}

	log {
		output file /var/log/caddy/{{nom}}.log
	}
}
