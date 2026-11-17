#!/bin/bash
# Runs the in-app navigation self-test (history, Up, mouse buttons 4/5, keyboard shortcuts,
# rapid navigation) against the fixtures. Read-only.
#
#   Tools/self-test.sh [--only group,group,…] [fixtures-dir]
#
# --only runs just those check groups (e.g. `--only settings`, `--only tree,favorites`) and skips the
# relaunch — for quick iteration. A name that doesn't exist fails and lists the groups. Run the whole
# thing (no --only) before committing a finished change: a group can depend on what earlier ones left.
#
# Launched through LaunchServices (`open`) so the app is activated like a normal launch —
# menu shortcuts need a key window, which a background launch from a terminal doesn't get.
# A Kansio window opens for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
only=""
if [[ "${1:-}" == "--only" ]]; then only="${2:?--only needs group names}"; shift 2; fi
tmp="${TMPDIR:-/tmp}"
fixtures="${1:-${KANSIO_FIXTURES:-${tmp%/}/kansio-fixtures}}"
[[ -d "$fixtures/deep" ]] || { echo "fixtures missing: run Tools/make-fixtures.sh" >&2; exit 1; }
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
# File-operation checks run in a scratch folder under the fixtures; "Move to Trash" goes to a
# test trash folder there too — never the user's Trash.
# Opening is recorded (KANSIO_TEST_OPENER) so the test never launches real apps. KANSIO_TEST_NETWORK makes a
# scratch folder act as a network volume (no Trash) for the Trash checks.
# View settings go to a separate defaults domain, wiped before and after, so the test starts from
# the defaults and never changes the user's own settings. A second launch checks that the settings
# the first one left behind came back (--self-test-persisted).
suite=dev.kansio.self-test
history="$HOME/Library/Application Support/Kansio/TrashHistory-$suite.json" # Kansio's trash history for this domain
defaults delete "$suite" >/dev/null 2>&1 || true
rm -f "$history"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# `open` registers the development copy with LaunchServices; unregister it afterwards (Spotlight, Open With).
trap 'rm -f "$log" "$history"; defaults delete "$suite" >/dev/null 2>&1 || true; "$lsregister" -u "$(cd build/app.noindex 2>/dev/null && pwd)/Kansio.app" 2>/dev/null || true' EXIT
run() {
  : > "$log"
  open -W -n --stdout "$log" --stderr "$log" --env "KANSIO_TEST_TRASH=$fixtures/.self-test-trash" --env KANSIO_TEST_OPENER=1 --env "KANSIO_TEST_NETWORK=$fixtures/scratch-network" \
    --env "KANSIO_DEFAULTS_SUITE=$suite" --env "KANSIO_SELF_TEST_ONLY=$only" ${KANSIO_ENV:+--env "$KANSIO_ENV"} build/Kansio.app --args "$1" "$fixtures"
  cat "$log"
  grep -q '^SELF-TEST PASSED' "$log"
}
run --self-test
[[ -z "$only" ]] || exit 0
# Rename the folder the first launch pinned while Kansio isn't running (the bookmark must find it).
[[ -d "$fixtures/scratch-pin-relaunch" ]] && mv "$fixtures/scratch-pin-relaunch" "$fixtures/scratch-pin-relaunch-moved"
run --self-test-persisted
