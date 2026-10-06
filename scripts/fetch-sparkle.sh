#!/usr/bin/env bash
# Download the pinned Sparkle release, verify its SHA-256 and unpack it into
# .build/sparkle/ (Sparkle.framework + bin/ tools). Idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST=".build/sparkle"

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] \
   && [ -d "$DEST/Sparkle.framework" ]; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$TMP/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
GOT="$(shasum -a 256 "$TMP/sparkle.tar.xz" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA256" ]; then
  echo "error: Sparkle $VERSION checksum mismatch (got $GOT)" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xf "$TMP/sparkle.tar.xz" -C "$TMP"
ditto "$TMP/Sparkle.framework" "$DEST/Sparkle.framework"
ditto "$TMP/bin" "$DEST/bin"
echo "$VERSION" > "$DEST/.version"
echo "fetched Sparkle $VERSION into $DEST"
