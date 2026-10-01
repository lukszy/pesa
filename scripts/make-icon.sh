#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the 1024x1024 master PNG.
#
# macOS reads a single .icns from the bundle (CFBundleIconFile); an asset
# catalog is not available on a Command Line Tools-only install. Keep the
# master PNG as the source of truth and derive every iconset size from it, so
# there is one file to replace when the art changes.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-Resources/logo_1024x1024.png}"
OUT="Resources/AppIcon.icns"

if [ ! -f "$SRC" ]; then
  echo "error: master icon not found: $SRC" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

# iconutil expects exactly these names; @2x is the retina variant.
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$SRC" --out "$SET/icon_${n}x${n}.png" >/dev/null
  d=$((n * 2))
  sips -z "$d" "$d" "$SRC" --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT"
