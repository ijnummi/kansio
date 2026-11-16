#!/bin/bash
# Runs the in-app navigation self-test (history, Up, mouse buttons 4/5, keyboard shortcuts,
# rapid navigation) against the fixtures. Read-only.
#
#   Tools/self-test.sh [fixtures-dir]
#
# Launched through LaunchServices (`open`) so the app is activated like a normal launch —
# menu shortcuts need a key window, which a background launch from a terminal doesn't get.
# A Kansio window opens for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="${TMPDIR:-/tmp}"
fixtures="${1:-${KANSIO_FIXTURES:-${tmp%/}/kansio-fixtures}}"
[[ -d "$fixtures/deep" ]] || { echo "fixtures missing: run Tools/make-fixtures.sh" >&2; exit 1; }
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
# File-operation checks run in a scratch folder under the fixtures; "Move to Trash" goes to a
# test trash folder there too — never the user's Trash.
open -W -n --stdout "$log" --stderr "$log" --env "KANSIO_TEST_TRASH=$fixtures/.self-test-trash" \
  ${KANSIO_ENV:+--env "$KANSIO_ENV"} build/Kansio.app --args --self-test "$fixtures"
cat "$log"
grep -q '^SELF-TEST PASSED' "$log" # exit status = result
