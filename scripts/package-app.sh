#!/usr/bin/env bash
# Package the assembled Pesa.app into distributable artifacts under dist/.
#
# Produces a zipped bundle (ditto, which preserves the signature's extended
# attributes — plain `zip` does not) and a drag-to-Applications .dmg. Run
# scripts/build-app.sh first; CI calls this after it.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d Pesa.app ]; then
  echo "error: Pesa.app not found; run ./scripts/build-app.sh first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Pesa.app/Contents/Info.plist)"
ARCH="$(uname -m)"
NAME="Pesa-$VERSION-$ARCH"

mkdir -p dist
rm -f "dist/$NAME.zip" "dist/$NAME.dmg"

ditto -c -k --keepParent Pesa.app "dist/$NAME.zip"

# Stage the app next to an /Applications symlink so the mounted disk image is a
# normal drag-to-install layout.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R Pesa.app "$STAGE/Pesa.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pesa $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "dist/$NAME.dmg" >/dev/null

echo "wrote dist/$NAME.zip and dist/$NAME.dmg"
