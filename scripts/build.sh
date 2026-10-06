#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export TARGET="$(uname -m)-apple-macosx13.0"

./scripts/fetch-sparkle.sh

mkdir -p .build
# Two rpaths: the .app bundle (Contents/Frameworks) and the raw .build/Pesa
# binary, which sits next to .build/sparkle.
swiftc -O -o .build/Pesa Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement \
  -framework UserNotifications \
  -F .build/sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -rpath -Xlinker @executable_path/sparkle \
  -target "$TARGET"
