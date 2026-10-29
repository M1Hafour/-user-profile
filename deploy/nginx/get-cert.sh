#!/bin/bash
# Gets a free, trusted HTTPS certificate from Let's Encrypt for DOMAIN, switches nginx
# to HTTPS, and sets up automatic renewal. Run it ON the nginx (public) server:
#
#   cd ~/app/deploy/nginx && nano .env      # set DOMAIN and CERT_EMAIL
#   ./get-cert.sh
#
# Before you run it, DOMAIN must already point to this server's Elastic IP
# (for example a DuckDNS name), and port 80 must be open in sg-nginx.
#
# Renewal: a systemd timer (certbot-renew.timer) runs twice a day. certbot renews only
# when the certificate is close to expiring, then reloads nginx.
set -euo pipefail

# Needs root: re-run through sudo if started as a normal user.
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
ACME_ROOT="${ACME_ROOT:-/var/www/certbot}"
LE_LIVE_DIR="${LE_LIVE_DIR:-/etc/letsencrypt/live}"
CERTBOT_VENV="${CERTBOT_VENV:-/opt/certbot}"
CERTBOT_BIN="${CERTBOT_BIN:-$CERTBOT_VENV/bin/certbot}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"   # 1 = do not install packages or touch systemd (used by tests)
CHECK_DNS="${CHECK_DNS:-1}"       # 0 = skip the DNS check (used by tests)

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- 1. settings ---------------------------------------------------------------
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run: cp .env.example .env  and fill it in."
read_var() { grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\r"' | tr -d "'" | xargs || true; }
DOMAIN="$(read_var DOMAIN)"
CERT_EMAIL="$(read_var CERT_EMAIL)"
[ -n "$DOMAIN" ] || die "set DOMAIN in $ENV_FILE first (a name that points to this server's Elastic IP, e.g. myapp.duckdns.org)."
domain_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
[[ "$DOMAIN" =~ $domain_re ]] || die "DOMAIN in $ENV_FILE must be a host name such as myapp.duckdns.org (got '$DOMAIN')."
email_re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
[ -n "$CERT_EMAIL" ] || die "set CERT_EMAIL in $ENV_FILE first (Let's Encrypt sends expiry warnings there)."
[[ "$CERT_EMAIL" =~ $email_re ]] || die "CERT_EMAIL in $ENV_FILE is not an email address (got '$CERT_EMAIL')."

# ---- 2. the name must already point to this server ------------------------------
if [ "$CHECK_DNS" = 1 ]; then
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  mine="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$resolved" ]; then
    die "$DOMAIN does not resolve yet. Set its DNS record to this server's Elastic IP, wait a few minutes, then run this again."
  elif [ -z "$mine" ]; then
    echo "WARNING: could not read this server's public IP, so the DNS match is not checked."
  elif [ "$resolved" != "$mine" ]; then
    die "$DOMAIN points to $resolved, but this server's public IP is $mine. Fix the DNS record (use the Elastic IP), wait a few minutes, then run this again."
  else
    echo "DNS OK: $DOMAIN -> $resolved (this server)"
  fi
fi

export ENV_FILE ACME_ROOT LE_LIVE_DIR SKIP_SYSTEM

# ---- 3. nginx must serve the Let's Encrypt check folder before certbot runs ----
bash "$SCRIPT_DIR/install.sh"

# ---- 4. certbot -----------------------------------------------------------------
install_certbot() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to install certbot."
  if ! python3 -m venv "$CERTBOT_VENV" >/dev/null 2>&1; then
    # Ubuntu/Debian ship venv in its own package
    command -v apt-get >/dev/null 2>&1 || die "cannot create a Python venv at $CERTBOT_VENV."
    apt-get update -y >/dev/null && apt-get install -y python3-venv >/dev/null
    python3 -m venv "$CERTBOT_VENV"
  fi
  "$CERTBOT_VENV/bin/pip" install --quiet certbot || die "installing certbot failed."
}

if [ ! -x "$CERTBOT_BIN" ]; then
  [ "$SKIP_SYSTEM" != 1 ] || die "$CERTBOT_BIN not found."
  echo "Installing certbot into $CERTBOT_VENV ..."
  install_certbot
fi

echo "Requesting the certificate for $DOMAIN ..."
"$CERTBOT_BIN" certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" -m "$CERT_EMAIL" \
  --agree-tos --no-eff-email --non-interactive --keep-until-expiring \
  || die "certbot could not get a certificate (message above). Check that DNS points here, port 80 is open in sg-nginx, and nothing else answers on port 80."
[ -f "$LE_LIVE_DIR/$DOMAIN/fullchain.pem" ] && [ -f "$LE_LIVE_DIR/$DOMAIN/privkey.pem" ] \
  || die "certbot finished but $LE_LIVE_DIR/$DOMAIN/ has no certificate files."

# ---- 5. automatic renewal ----------------------------------------------------------
cat > "$SYSTEMD_DIR/certbot-renew.service" <<EOF
[Unit]
Description=Renew the Let's Encrypt certificate (certbot)
Documentation=https://eff-certbot.readthedocs.io/

[Service]
Type=oneshot
ExecStart=$CERTBOT_BIN renew --quiet --no-random-sleep-on-renew --deploy-hook "systemctl reload nginx"
EOF

cat > "$SYSTEMD_DIR/certbot-renew.timer" <<'EOF'
[Unit]
Description=Check the Let's Encrypt certificate twice a day

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
echo "Renewal timer written: $SYSTEMD_DIR/certbot-renew.timer"

if [ "$SKIP_SYSTEM" != 1 ]; then
  systemctl daemon-reload
  systemctl enable --now certbot-renew.timer
fi

# ---- 6. switch nginx to HTTPS ---------------------------------------------------
bash "$SCRIPT_DIR/install.sh"

if [ "$SKIP_SYSTEM" != 1 ]; then
  if curl -fsS --max-time 10 "https://$DOMAIN/nginx-health" >/dev/null 2>&1; then
    echo "HTTPS is working: https://$DOMAIN"
  else
    echo "WARNING: https://$DOMAIN did not answer yet. Check DNS and sg-nginx (port 443), then run: sudo journalctl -u nginx -n 30"
  fi
fi
echo "Done. Certificate: $LE_LIVE_DIR/$DOMAIN/ (renewed automatically; check with: systemctl list-timers certbot-renew.timer)"
