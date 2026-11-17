#!/bin/bash
# Builds Kansio.app with SwiftPM (no Xcode needed).
#
#   Tools/build-app.sh [debug|release]      → build/app.noindex/Kansio.app, linked as build/Kansio.app
#
# The bundle lives in a folder named *.noindex so Spotlight doesn't list the development copy next to the installed
# one; build/Kansio.app is a symlink to it (every command keeps using that path). Install with Tools/install.sh.
#
# Signing: Hardened Runtime with the local identity "Kansio Local Signing" (Tools/signing-identity.sh creates it once),
# so privacy grants like Full Disk Access survive rebuilds; KANSIO_SIGN_IDENTITY overrides (e.g. "Developer ID
# Application: …" for distribution, or "-" for ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --product Kansio
bin="$(swift build -c "$config" --show-bin-path)"

app="build/app.noindex/Kansio.app"
rm -rf "$app"
[[ -L build/Kansio.app || ! -e build/Kansio.app ]] || rm -rf build/Kansio.app # the pre-.noindex bundle
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ln -sfn app.noindex/Kansio.app build/Kansio.app
cp "$bin/Kansio" "$app/Contents/MacOS/Kansio"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp App/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns" # drawn by Tools/make-icon.swift

# P2-3: 7-Zip's 7zz (built from the pinned source release, cached) and its licence (GNU LGPL + unRAR restriction).
sevenzip="$(Tools/fetch-7zip.sh)"
cp "$sevenzip" "$app/Contents/MacOS/7zz"
cp "$(dirname "$sevenzip")/../../../../../../DOC/License.txt" "$app/Contents/Resources/7-Zip License.txt"

keychain=()
if [[ -n "${KANSIO_SIGN_IDENTITY:-}" ]]; then
  identity="$KANSIO_SIGN_IDENTITY"
else
  identity="Kansio Local Signing"
  keychain=(--keychain "$(Tools/signing-identity.sh)")
fi
# Nested code is signed first (Hardened Runtime too); the app's signature then seals it.
codesign --force --options runtime --timestamp=none "${keychain[@]}" --sign "$identity" "$app/Contents/MacOS/7zz"
codesign --force --options runtime --timestamp=none "${keychain[@]}" \
  --entitlements App/Resources/Kansio.entitlements \
  --sign "$identity" "$app"
codesign --verify --strict "$app"
# Keep the development copy out of LaunchServices (Spotlight, Open With): only /Applications/Kansio.app is "the" app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true
echo "built build/Kansio.app ($config, signed: $identity, hardened runtime)"
