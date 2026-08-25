#!/bin/sh
set -eu

CTID=212
CERT_DOMAIN=tor-sm2124bt-htr-5-4-pve.tail039078.ts.net
CERT_DIR=/etc/mqvpn-ts-cert

umask 077
install -d -m 700 "$CERT_DIR"
cert_tmp="$CERT_DIR/server.crt.new.$$"
key_tmp="$CERT_DIR/server.key.new.$$"
trap 'rm -f "$cert_tmp" "$key_tmp"' EXIT HUP INT TERM

tailscale cert \
  --min-validity=720h \
  --cert-file="$cert_tmp" \
  --key-file="$key_tmp" \
  "$CERT_DOMAIN"

openssl x509 -in "$cert_tmp" -checkend 604800 -noout
if cmp -s "$cert_tmp" "$CERT_DIR/server.crt" && \
   cmp -s "$key_tmp" "$CERT_DIR/server.key"; then
  exit 0
fi

install -m 600 "$cert_tmp" "$CERT_DIR/server.crt"
install -m 600 "$key_tmp" "$CERT_DIR/server.key"
pct push "$CTID" "$CERT_DIR/server.crt" /etc/mqvpn/server.crt \
  --user root --group root --perms 0600
pct push "$CTID" "$CERT_DIR/server.key" /etc/mqvpn/server.key \
  --user root --group root --perms 0600
pct exec "$CTID" -- systemctl restart mqvpn-server
pct exec "$CTID" -- systemctl is-active --quiet mqvpn-server
