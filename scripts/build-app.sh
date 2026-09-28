#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

rm -rf ProviderCostController.app
mkdir -p ProviderCostController.app/Contents/MacOS
cp .build/ProviderCostController ProviderCostController.app/Contents/MacOS/ProviderCostController
cp Resources/Info.plist ProviderCostController.app/Contents/Info.plist
# Prefer a caller-provided identity, then the stable default, else fall back to
# ad-hoc so a fresh machine still builds. An identity that is not in the keychain
# (or a typo) also falls back, with a hint.
IDENTITY="${SIGNING_IDENTITY:-ProviderCostController Signing}"
if [ "$IDENTITY" != "-" ] && ! security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  IDENTITY="-"
  echo "signing ad-hoc (unstable across code changes); run scripts/make-signing-identity.sh once for a stable identity"
fi
codesign --force --sign "$IDENTITY" ProviderCostController.app
