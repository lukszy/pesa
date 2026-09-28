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
if security find-identity -p codesigning | grep -qF "\"$IDENTITY_NAME\""; then
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

# The certificate's SHA-1, as `security find-identity` prints it. Used to
# remove exactly this identity if the import does not produce a usable one, and
# to give the user an unambiguous removal command when several certificates share
# the common name.
SHA1="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 \
    | sed 's/^.*=//; s/://g')"

# The key and certificate are imported as PEM, so there is no .p12 step and
# therefore no passphrase to expose. A passphrase would have to appear on the
# `security import` command line and would be briefly visible in `ps`. A .p12
# cannot avoid that: an empty passphrase is rejected with "MAC verification
# failed during PKCS12 import", and `-nomac` is a flag of `openssl pkcs12
# -export`, not of `security import` (which has no such flag). Verified on this
# machine in a throwaway keychain that importing key+cert as PEM yields a usable
# code-signing identity.
cat "$WORK/key.pem" "$WORK/cert.pem" > "$WORK/identity.pem"

# -T lets codesign use the private key without prompting. The key material lives
# in the keychain from here on; the loose PEM files are removed by the trap.
security import "$WORK/identity.pem" \
    -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning | grep -qF "\"$IDENTITY_NAME\""; then
    echo "created code-signing identity: $IDENTITY_NAME (login keychain only)"
else
    # Leave nothing behind: this identity is the one just imported, and the
    # exact certificate is known by SHA-1, so remove only it. Only claim the
    # removal when it actually succeeded.
    if security delete-identity -Z "$SHA1" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "error: identity created but not listed for code signing; removed it again" >&2
    else
        echo "error: identity created but not listed for code signing, and cleanup failed." >&2
        echo "A certificate and private key for \"$IDENTITY_NAME\" (SHA-1 $SHA1) may" >&2
        echo "remain in your login keychain. Check with:" >&2
        echo "  security find-identity -p codesigning" >&2
        echo "Remove it with:" >&2
        echo "  security delete-identity -Z $SHA1" >&2
    fi
    exit 1
fi

echo
echo "To remove it later: open Keychain Access, delete the \"$IDENTITY_NAME\""
echo "certificate and its private key, or run:"
echo "  security delete-identity -c \"$IDENTITY_NAME\""
echo "If more than one certificate shares that common name, delete by hash"
echo "instead. Its SHA-1 is the one `security find-identity -p codesigning`"
echo "prints next to the name:"
echo "  security delete-identity -Z <SHA-1>"
