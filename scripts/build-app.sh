#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

rm -rf Pesa.app
mkdir -p Pesa.app/Contents/MacOS Pesa.app/Contents/Resources
cp .build/Pesa Pesa.app/Contents/MacOS/Pesa
cp Resources/Info.plist Pesa.app/Contents/Info.plist
# CI passes the release version (scripts/next-version.sh); local builds keep the
# plist's own. Stamped before codesign so the signature covers it.
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    Pesa.app/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    Pesa.app/Contents/Info.plist
fi
cp Resources/AppIcon.icns Pesa.app/Contents/Resources/AppIcon.icns
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Pesa.app/Contents/Resources/

# Sparkle: embed the framework. The app is not sandboxed, so the sandbox XPC
# services are dropped (and their symlink, which codesign --strict rejects when
# dangling).
mkdir -p Pesa.app/Contents/Frameworks
ditto .build/sparkle/Sparkle.framework Pesa.app/Contents/Frameworks/Sparkle.framework
SPARKLE_FW="Pesa.app/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE_FW/Versions/B/XPCServices" "$SPARKLE_FW/XPCServices"
# The updater stays disabled until a public key is committed.
PUBLIC_KEY="$(tr -d '[:space:]' < scripts/sparkle-public-key.txt 2>/dev/null || true)"
if [ -n "$PUBLIC_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" Pesa.app/Contents/Info.plist
else
  echo "note: scripts/sparkle-public-key.txt is empty; updater will be disabled" >&2
fi

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

# Inside-out: nested code first, then the framework, then the app.
codesign --force --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --sign "$IDENTITY" "$SPARKLE_FW"
codesign --force --sign "$IDENTITY" Pesa.app
codesign --verify --deep --strict Pesa.app

# Surface the thing that actually decides whether macOS re-prompts for Keychain
# access: the designated requirement. A certificate-based one names the cert and
# survives rebuilds, so one "Always Allow" sticks; an ad-hoc one is a cdhash of
# the code, so it changes on every build and the prompt returns.
# `codesign -d -r-` prefixes an ad-hoc requirement with "# ", so match the word
# anywhere on the line rather than anchoring.
REQUIREMENT="$(codesign -d -r- Pesa.app 2>&1 | grep -m1 'designated' || true)"
case "$REQUIREMENT" in
  *cdhash*)
    echo "warning: designated requirement is cdhash-based (ad-hoc)." >&2
    echo "  macOS will ask for Keychain access again after every rebuild." >&2
    echo "  Fix: ./scripts/make-signing-identity.sh, then rebuild." >&2
    ;;
  *certificate*)
    echo "signature: certificate-based requirement — stable across rebuilds."
    ;;
  *)
    echo "warning: could not read the designated requirement (codesign output below)" >&2
    echo "  $REQUIREMENT" >&2
    ;;
esac
