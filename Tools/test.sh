#!/bin/bash
# Runs the FileSystemKit unit tests (swift-testing).
#
# With only the Command Line Tools installed (no Xcode), SwiftPM doesn't find the
# swift-testing macro plugin on its own, so we point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")/.."

extra=()
dev_dir="$(xcode-select -p)"
plugin_dir="$dev_dir/usr/lib/swift/host/plugins/testing"
if [[ "$dev_dir" == *CommandLineTools* && -d "$plugin_dir" ]]; then
  extra+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
fi

swift test --package-path Packages/FileSystemKit ${extra[@]+"${extra[@]}"} "$@"
