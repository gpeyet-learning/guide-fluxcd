FROM caddy:2-alpine

COPY Caddyfile /etc/Caddyfile
COPY public/ /var/www/

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/ || exit 1

USER caddy
