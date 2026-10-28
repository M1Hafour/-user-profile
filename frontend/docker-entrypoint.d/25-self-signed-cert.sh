#!/bin/sh
# Create a self-signed TLS certificate on first start, unless one is already there.
#
#   * The certificate and key live in a volume (/etc/nginx/certs), never in the
#     image, so the private key is not shipped with the image pushed to Docker Hub.
#   * To use your own certificate, put it in that volume as tls.crt / tls.key.
#     A certificate this script did not create is never modified or replaced.
#   * Certificates created here are regenerated when within 30 days of expiry.
#
# Optional environment variables:
#   TLS_SAN               extra subjectAltName entries, e.g. "DNS:myserver.local,IP:192.168.1.20"
#   TLS_SELF_SIGNED_DAYS  validity of generated certificates (default 365)
#   TLS_CERT_DIR          certificate directory (default /etc/nginx/certs)

set -eu

CERT_DIR="${TLS_CERT_DIR:-/etc/nginx/certs}"
CRT="$CERT_DIR/tls.crt"
KEY="$CERT_DIR/tls.key"
MARK="$CERT_DIR/.self-signed.sha256"
DAYS="${TLS_SELF_SIGNED_DAYS:-365}"
SAN="DNS:localhost,IP:127.0.0.1,IP:::1"
if [ -n "${TLS_SAN:-}" ]; then
    SAN="$SAN,$TLS_SAN"
fi
LOG="25-self-signed-cert.sh:"

fingerprint() {
    openssl x509 -in "$CRT" -noout -fingerprint -sha256
}

generate() {
    # openssl prints a cosmetic "-----" banner; show its output only if it fails.
    if ! out=$(openssl req -x509 -nodes -days "$DAYS" \
        -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY" -out "$CRT" \
        -subj "/CN=localhost" \
        -addext "subjectAltName=$SAN" \
        -addext "extendedKeyUsage=serverAuth" 2>&1); then
        echo "$LOG ERROR: openssl failed:" >&2
        echo "$out" >&2
        exit 1
    fi
    chmod 600 "$KEY"
    # Remember which certificate is ours, so a certificate you add later is left alone.
    fingerprint > "$MARK"
    echo "$LOG generated a self-signed certificate valid $DAYS days for: $SAN"
}

mkdir -p "$CERT_DIR"

if [ -f "$CRT" ] && [ -f "$KEY" ]; then
    if [ -f "$MARK" ] && [ "$(fingerprint)" = "$(cat "$MARK")" ] \
        && ! openssl x509 -in "$CRT" -noout -checkend 2592000 >/dev/null; then
        echo "$LOG self-signed certificate expires within 30 days, regenerating"
        generate
    else
        echo "$LOG using existing certificate in $CERT_DIR"
    fi
elif [ -f "$CRT" ] || [ -f "$KEY" ]; then
    echo "$LOG ERROR: only one of tls.crt / tls.key exists in $CERT_DIR; provide both or remove the leftover file" >&2
    exit 1
else
    generate
fi
