#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/fetch-sparkle.sh

mkdir -p .build
# Universal binary (Apple Silicon + Intel): one swiftc per arch, merged by lipo.
# Two rpaths: the .app bundle (Contents/Frameworks) and the raw .build/Pesa
# binary, which sits next to .build/sparkle.
for arch in arm64 x86_64; do
  swiftc -O -o ".build/Pesa-$arch" Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement \
    -framework UserNotifications \
    -F .build/sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @executable_path/sparkle \
    -target "$arch-apple-macosx13.0"
done
lipo -create -output .build/Pesa .build/Pesa-arm64 .build/Pesa-x86_64
