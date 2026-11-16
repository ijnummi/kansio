#!/bin/bash
# Builds Kansio.app with SwiftPM (no Xcode needed).
#
#   Tools/build-app.sh [debug|release]      → build/Kansio.app
#
# Signing: ad-hoc ("-") with Hardened Runtime, unless KANSIO_SIGN_IDENTITY is set
# (e.g. "Developer ID Application: …") for distribution/notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --product Kansio
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Kansio.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Kansio" "$app/Contents/MacOS/Kansio"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

identity="${KANSIO_SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --entitlements App/Resources/Kansio.entitlements \
  --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "built $app ($config, signed: $identity, hardened runtime)"
