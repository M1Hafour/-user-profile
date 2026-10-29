#!/bin/bash
# Installs and configures nginx directly on this EC2 instance (no Docker).
# Safe to run again: use it for the first setup AND after every `git pull`
# (new frontend files, new private IPs in .env, config changes, a new certificate).
#
#   cd ~/app/deploy/nginx && cp .env.example .env && nano .env && ./install.sh
#
# It: installs nginx if missing, copies frontend/public to the web root, writes
# /etc/nginx/nginx.conf, checks it with `nginx -t` (and puts the old config back
# if the check fails), then starts/reloads nginx.
#
# HTTP or HTTPS is picked automatically:
#   - HTTPS (nginx-tls.conf.template) when DOMAIN is set in .env AND a Let's Encrypt
#     certificate for that name exists. Create one with ./get-cert.sh.
#   - HTTP (nginx.conf.template) otherwise.
set -euo pipefail

# Needs root: re-run through sudo if started as a normal user.
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/nginx.conf.template}"          # HTTP config
TLS_TEMPLATE="${TLS_TEMPLATE:-$SCRIPT_DIR/nginx-tls.conf.template}"  # HTTPS config
FRONTEND_DIR="${FRONTEND_DIR:-$SCRIPT_DIR/../../frontend/public}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
WEB_ROOT="${WEB_ROOT:-/var/www/user-profile}"
ACME_ROOT="${ACME_ROOT:-/var/www/certbot}"           # Let's Encrypt writes its check files here
LE_LIVE_DIR="${LE_LIVE_DIR:-/etc/letsencrypt/live}"  # where certbot keeps the certificates
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"    # 1 = do not install packages or touch systemd (used by tests)

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- 1. read and check the settings ---------------------------------------
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run: cp .env.example .env  and fill it in."
read_var() { grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\r"' | tr -d "'" | xargs || true; }
PRIVATE1_IP="$(read_var PRIVATE1_IP)"
PRIVATE2_IP="$(read_var PRIVATE2_IP)"
DOMAIN="$(read_var DOMAIN)"
ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
for v in PRIVATE1_IP PRIVATE2_IP; do
  [[ "${!v}" =~ $ipv4 ]] || die "$v in $ENV_FILE must be an IPv4 address like 10.0.128.10 (got '${!v}')."
done
[ "$PRIVATE1_IP" != "$PRIVATE2_IP" ] || die "PRIVATE1_IP and PRIVATE2_IP must be two different servers."
[ -f "$FRONTEND_DIR/index.html" ] || die "frontend files not found in $FRONTEND_DIR (is the repo fully cloned?)."
[ -f "$TEMPLATE" ] || die "$TEMPLATE not found."

MODE=http
if [ -n "$DOMAIN" ]; then
  domain_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ "$DOMAIN" =~ $domain_re ]] || die "DOMAIN in $ENV_FILE must be a host name such as myapp.duckdns.org (got '$DOMAIN')."
  if [ -f "$LE_LIVE_DIR/$DOMAIN/fullchain.pem" ] && [ -f "$LE_LIVE_DIR/$DOMAIN/privkey.pem" ]; then
    MODE=tls
    [ -f "$TLS_TEMPLATE" ] || die "$TLS_TEMPLATE not found."
  else
    echo "NOTE: DOMAIN=$DOMAIN is set, but there is no certificate yet, so nginx serves plain HTTP for now."
    echo "      Run ./get-cert.sh to turn on HTTPS."
  fi
fi

# ---- 2. install nginx ---------------------------------------------------------
if [ "$SKIP_SYSTEM" != 1 ] && ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  if   command -v dnf     >/dev/null 2>&1; then dnf install -y nginx
  elif command -v yum     >/dev/null 2>&1; then yum install -y nginx
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y nginx
  else die "no supported package manager found (dnf, yum or apt-get). Install nginx manually."
  fi
fi
command -v nginx >/dev/null 2>&1 || die "nginx is not installed."

# The user nginx's workers run as: 'nginx' on Amazon Linux / RHEL, 'www-data' on Ubuntu.
if   id nginx    >/dev/null 2>&1; then NGINX_USER=nginx
elif id www-data >/dev/null 2>&1; then NGINX_USER=www-data
else die "found neither an 'nginx' nor a 'www-data' user."
fi

# ---- 3. frontend files and certificate-check folder ---------------------------
install -d -m 755 "$WEB_ROOT"
find "$WEB_ROOT" -mindepth 1 -delete
cp -r "$FRONTEND_DIR"/. "$WEB_ROOT"/
chmod -R a+rX "$WEB_ROOT"
echo "Frontend files copied to $WEB_ROOT"
install -d -m 755 "$ACME_ROOT"

# ---- 4. nginx config (with automatic rollback) ----------------------------------
install -d "$(dirname "$NGINX_CONF")"
BACKUP=""
if [ -f "$NGINX_CONF" ]; then
  # keep the distribution's original once, and a copy of the current one for rollback
  [ -f "$NGINX_CONF.orig" ] || cp -p "$NGINX_CONF" "$NGINX_CONF.orig"
  BACKUP="$(mktemp)"; cp -p "$NGINX_CONF" "$BACKUP"
fi

if [ "$MODE" = tls ]; then
  TEMPLATE_USED="$TLS_TEMPLATE"
  SED_ARGS=(-e "s|__DOMAIN__|$DOMAIN|g"
            -e "s|__CERT_FULLCHAIN__|$LE_LIVE_DIR/$DOMAIN/fullchain.pem|g"
            -e "s|__CERT_KEY__|$LE_LIVE_DIR/$DOMAIN/privkey.pem|g")
else
  TEMPLATE_USED="$TEMPLATE"
  SED_ARGS=()
fi
sed -e "s|__NGINX_USER__|$NGINX_USER|g" \
    -e "s|__PRIVATE1_IP__|$PRIVATE1_IP|g" \
    -e "s|__PRIVATE2_IP__|$PRIVATE2_IP|g" \
    -e "s|__WEB_ROOT__|$WEB_ROOT|g" \
    -e "s|__ACME_ROOT__|$ACME_ROOT|g" \
    ${SED_ARGS[@]+"${SED_ARGS[@]}"} \
    "$TEMPLATE_USED" > "$NGINX_CONF"
chmod 644 "$NGINX_CONF"

if grep -q '__[A-Z0-9_]*__' "$NGINX_CONF"; then
  echo "Unfilled placeholders left in the config:" >&2; grep -n '__[A-Z0-9_]*__' "$NGINX_CONF" >&2
  [ -n "$BACKUP" ] && cp -p "$BACKUP" "$NGINX_CONF"
  die "config not installed."
fi

if ! nginx -t -c "$NGINX_CONF"; then
  if [ -n "$BACKUP" ]; then cp -p "$BACKUP" "$NGINX_CONF"; echo "The previous config was put back." >&2; fi
  die "nginx rejected the new config (see the message above)."
fi
[ -z "$BACKUP" ] || rm -f "$BACKUP"
if [ "$MODE" = tls ]; then
  echo "nginx config OK: $NGINX_CONF (HTTPS for $DOMAIN, app servers: $PRIVATE1_IP and $PRIVATE2_IP, port 3000)"
else
  echo "nginx config OK: $NGINX_CONF (HTTP only; app servers: $PRIVATE1_IP and $PRIVATE2_IP, port 3000)"
fi

# ---- 5. start / reload ---------------------------------------------------------------
if [ "$SKIP_SYSTEM" != 1 ]; then
  systemctl enable nginx >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
  sleep 1
  systemctl is-active --quiet nginx || die "nginx is not running. See: sudo journalctl -u nginx -n 30"
  echo "nginx is running. Check it: curl -s http://localhost/nginx-health"
fi
