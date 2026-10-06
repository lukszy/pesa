#!/usr/bin/env bash
# Sign the release zip and write dist/appcast.xml. Needs VERSION and
# SPARKLE_ED_PRIVATE_KEY (the key exported by `generate_keys -x`).
set -euo pipefail

cd "$(dirname "$0")/.."

: "${VERSION:?VERSION is required}"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"

./scripts/fetch-sparkle.sh

ZIP="$(ls dist/Pesa-"$VERSION"-*.zip | head -1)"
# generate_appcast scans a whole folder; give it only the zip so the dmg is not
# listed as a second copy of the same version.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$ZIP" "$STAGE/"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | ./.build/sparkle/bin/generate_appcast \
  --ed-key-file - \
  --download-url-prefix "https://github.com/lukszy/pesa/releases/download/v$VERSION/" \
  "$STAGE"

# An unsigned appcast would strand installed copies, so refuse to publish one.
grep -q 'sparkle:edSignature' "$STAGE/appcast.xml" || {
  echo "error: appcast.xml has no sparkle:edSignature" >&2
  exit 1
}

cp "$STAGE/appcast.xml" dist/appcast.xml
echo "wrote dist/appcast.xml"
