#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity in the login keychain.
#
# Why: an ad-hoc signature has a designated requirement of cdhash H"…", so the
# requirement changes whenever the compiled code changes and macOS re-prompts for
# Keychain access after every rebuild. A certificate-backed identity gives the
# app a requirement that names the certificate instead, which survives rebuilds.
#
# No admin rights, no GUI, no trust-store changes: a self-signed certificate does
# not need to be trusted for `codesign` to sign with it locally, so it stays in
# the login keychain. Touches no other keychain item.
set -euo pipefail

IDENTITY_NAME="ProviderCostController Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Idempotent: `find-identity -p codesigning` lists an identity only when its
# certificate is valid for code signing. It is shown as CSSMERR_TP_NOT_TRUSTED
# because a self-signed certificate is not in the trust store (by design: trust
# would need authorisation), and codesign still signs with it locally.
if security find-identity -p codesigning | grep -qF "$IDENTITY_NAME"; then
    echo "signing identity already exists: $IDENTITY_NAME (nothing to do)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = $IDENTITY_NAME

[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# LibreSSL's /usr/bin/openssl has no dependable -addext, so extensions come from
# the config section instead.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" -extensions v3_req >/dev/null 2>&1

P12_PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY_NAME" -out "$WORK/identity.p12" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1

# -T lets codesign use the private key without prompting. The key material lives
# in the keychain from here on; the loose files are removed by the trap.
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning | grep -qF "$IDENTITY_NAME"; then
    echo "created code-signing identity: $IDENTITY_NAME (login keychain only)"
else
    echo "error: identity created but not listed for code signing" >&2
    exit 1
fi

echo
echo "To remove it later: open Keychain Access, delete the \"$IDENTITY_NAME\""
echo "certificate and its private key, or run:"
echo "  security delete-identity -c \"$IDENTITY_NAME\""