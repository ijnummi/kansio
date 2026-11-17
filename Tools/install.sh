#!/bin/bash
# Installs the built app as /Applications/Kansio.app.
#
#   Tools/install.sh
#
# Refuses a stale build (sources newer than the binary) and a running installed copy. The previous copy goes to the
# Trash (never deleted) and is unregistered from LaunchServices, so Spotlight and Open With list only one Kansio.
set -euo pipefail
cd "$(dirname "$0")/.."

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
src="build/app.noindex/Kansio.app"
dest="/Applications/Kansio.app"

[[ -d "$src" ]] || { echo "no build: run Tools/build-app.sh first" >&2; exit 1; }
stale="$(find App Packages/FileSystemKit/Sources Package.swift Tools/build-app.sh -newer "$src/Contents/MacOS/Kansio" | head -1)"
[[ -z "$stale" ]] || { echo "the build is older than $stale: run Tools/build-app.sh first" >&2; exit 1; }
if pgrep -f "^$dest/Contents/MacOS/Kansio" >/dev/null; then
  echo "Kansio is running from $dest: quit it first" >&2
  exit 1
fi

if [[ -e "$dest" ]]; then
  old="$HOME/.Trash/Kansio (replaced $(date +%Y-%m-%d\ %H.%M.%S)).app"
  mv "$dest" "$old"
  "$lsregister" -u "$old" 2>/dev/null || true
fi
ditto "$src" "$dest"
codesign --verify --deep --strict "$dest"
"$lsregister" -f "$dest" 2>/dev/null || true
"$lsregister" -u "$PWD/$src" 2>/dev/null || true
echo "installed $dest ($(codesign -dr - "$dest" 2>&1 | sed -n 's/^designated => //p'))"
