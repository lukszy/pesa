#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

rm -rf ProviderCostController.app
mkdir -p ProviderCostController.app/Contents/MacOS
cp .build/ProviderCostController ProviderCostController.app/Contents/MacOS/ProviderCostController
cp Resources/Info.plist ProviderCostController.app/Contents/Info.plist
codesign -s - --force ProviderCostController.app
