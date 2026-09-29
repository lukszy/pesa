#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export TARGET="$(uname -m)-apple-macosx13.0"

mkdir -p .build
swiftc -O -o .build/Pesa Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  -framework UserNotifications \
  -target "$TARGET"
