#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

rm -rf ProviderCostController.app
mkdir -p ProviderCostController.app/Contents/MacOS
cp .build/ProviderCostController ProviderCostController.app/Contents/MacOS/ProviderCostController
cp Resources/Info.plist ProviderCostController.app/Contents/Info.plist
# Prefer a caller-provided identity, then the stable default, else fall back to
# ad-hoc so a fresh machine still builds. `find-identity -p codesigning` lists an
# untrusted identity too (CSSMERR_TP_NOT_TRUSTED), which is exactly what
# scripts/make-signing-identity.sh creates: a self-signed cert not in the trust
# store. That is not an error — codesign signs with it locally and the app's
# designated requirement is certificate-based, so it is stable across rebuilds.
IDENTITY="${SIGNING_IDENTITY:-ProviderCostController Signing}"
if [ "$IDENTITY" != "-" ] && ! security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  echo "warning: signing identity \"$IDENTITY\" is not in the login keychain" >&2
  echo "  run ./scripts/make-signing-identity.sh once for a stable identity" >&2
  IDENTITY="-"
fi
if [ "$IDENTITY" = "-" ]; then
  echo "signing ad-hoc (unstable across rebuilds)"
elif ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "note: \"$IDENTITY\" is self-signed and not in the trust store"
  echo "  (CSSMERR_TP_NOT_TRUSTED); expected, and harmless for local signing."
fi

codesign --force --sign "$IDENTITY" ProviderCostController.app

# Surface the thing that actually decides whether macOS re-prompts for Keychain
# access: the designated requirement. A certificate-based one names the cert and
# survives rebuilds, so one "Always Allow" sticks; an ad-hoc one is a cdhash of
# the code, so it changes on every build and the prompt returns.
# `codesign -d -r-` prefixes an ad-hoc requirement with "# ", so match the word
# anywhere on the line rather than anchoring.
REQUIREMENT="$(codesign -d -r- ProviderCostController.app 2>&1 | grep -m1 'designated' || true)"
case "$REQUIREMENT" in
  *cdhash*)
    echo "warning: designated requirement is cdhash-based (ad-hoc)." >&2
    echo "  macOS will ask for Keychain access again after every rebuild." >&2
    echo "  Fix: ./scripts/make-signing-identity.sh, then rebuild." >&2
    ;;
  *certificate*)
    echo "signature: certificate-based requirement — stable across rebuilds."
    echo "  On the first Keychain prompt click Always Allow and it will stick."
    ;;
  *)
    echo "warning: could not read the designated requirement (codesign output below)" >&2
    echo "  $REQUIREMENT" >&2
    ;;
esac
