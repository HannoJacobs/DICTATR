#!/bin/bash
# Local replacement for the old GitHub Actions workflow: run the tests and build an
# unsigned DMG in a throwaway copy of the working tree. Run it on a Mac. It cannot touch
# the repo's own DMG or build folder, or the installed app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(cd "$(mktemp -d)" && pwd -P)"
# .noindex keeps the temporary app bundle out of Spotlight.
WORK="$BASE/check.noindex"
mkdir "$WORK"

cleanup() {
    local derived
    for derived in "$HOME"/Library/Developer/Xcode/DerivedData/DICTATR-*/; do
        [ -f "$derived/info.plist" ] || continue
        # Xcode records the path without the /private prefix that pwd -P gives.
        case "$(plutil -extract WorkspacePath raw "$derived/info.plist" 2>/dev/null || true)" in
            "${WORK#/private}" | "${WORK#/private}"/*)
                derived="${derived%/}"
                rm -rf "$derived" "$(dirname "$derived")/check.noindex-${derived##*-}"
                ;;
        esac
    done
    rm -rf "$BASE"
}
trap cleanup EXIT

cd "$REPO"
git ls-files -coz --exclude-standard | while IFS= read -r -d '' path; do
    if [ -e "$path" ]; then printf '%s\0' "$path"; fi
done | tar --null -T - -cf - | tar -xf - -C "$WORK"

cd "$WORK"
swift test
DICTATR_RELEASE_CONFIG=/dev/null DICTATR_CODESIGN_MODE=adhoc DICTATR_SPCTL_EXPECT=rejected bash create-dmg.sh
echo "==> Checks passed"
