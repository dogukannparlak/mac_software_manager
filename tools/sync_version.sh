#!/bin/zsh
#
# Propagates the version in ./VERSION into every file that carries one.
#
# The scripts are distributed standalone (each is installed as its own file),
# so each one has to embed its own version string.
# ./VERSION is the single source of truth; this script keeps the copies in sync.
#
# Usage: ./tools/sync_version.sh [--check]
#   --check  report drift without writing anything (used by CI)

set -e
set -o pipefail

REPO_ROOT="${0:a:h:h}"
cd "$REPO_ROOT"

if [[ ! -f VERSION ]]; then
    echo "❌ VERSION file is missing."
    exit 1
fi

VERSION=$(< VERSION)
VERSION="${VERSION//[[:space:]]/}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ VERSION must look like 1.5.0 (got '$VERSION')."
    exit 1
fi

CHECK_ONLY=0
[[ "$1" == "--check" ]] && CHECK_ONLY=1

DRIFT=0

# Replace a pattern in a file, reporting whether it changed.
# Usage: apply <file> <sed expression> <grep expression for the expected result> [count]
#
# <count> is the number of lines the grep expression must match. It defaults to
# "at least one", which is right for the files that carry a single version
# string. project.pbxproj carries one per build configuration, so it passes an
# exact count - otherwise a half-updated file would look in sync.
apply() {
    local file="$1" expression="$2" expected="$3" count="${4:-}"

    if [[ ! -f "$file" ]]; then
        echo "❌ Missing file: $file"
        exit 1
    fi

    local matched
    matched=$(grep -cE "$expected" "$file" || true)

    if [[ -n "$count" ]]; then
        if (( matched == count )); then
            echo "  ✓ $file"
            return 0
        fi
    elif (( matched > 0 )); then
        echo "  ✓ $file"
        return 0
    fi

    DRIFT=1

    if (( CHECK_ONLY )); then
        echo "  ✗ $file is out of sync"
        return 0
    fi

    sed -i '' -E "$expression" "$file"
    echo "  → $file updated"
}

echo "Target version: $VERSION"

apply "update_system.1h.sh" \
    "s|<bitbar\.version>v[0-9.]+</bitbar\.version>|<bitbar.version>v${VERSION}</bitbar.version>|" \
    "<bitbar\.version>v${VERSION}</bitbar\.version>"

apply "setup_mac.sh" \
    "s|(mac_software_manager\\\$\{reset_color\} )v[0-9.]+|\1v${VERSION}|" \
    "mac_software_manager\\\$\{reset_color\} v${VERSION}\"?$"

apply "uninstall.sh" \
    "s|(Uninstaller )v[0-9.]+|\1v${VERSION}|" \
    "Uninstaller v${VERSION} "

apply "README.md" \
    "s|badge/version-[0-9.]+-blue|badge/version-${VERSION}-blue|" \
    "badge/version-${VERSION}-blue"

apply "README.tr.md" \
    "s|badge/version-[0-9.]+-blue|badge/version-${VERSION}-blue|" \
    "badge/version-${VERSION}-blue"

# Two build configurations (Debug and Release) each carry their own copy.
apply "GuideApp/MacUpdaterGuide.xcodeproj/project.pbxproj" \
    "s|(MARKETING_VERSION = )[0-9.]+;|\1${VERSION};|" \
    "MARKETING_VERSION = ${VERSION};" \
    2

if (( CHECK_ONLY )); then
    if (( DRIFT )); then
        echo "❌ Version strings are out of sync. Run ./tools/sync_version.sh and commit."
        exit 1
    fi
    echo "✅ All version strings match VERSION ($VERSION)."
    exit 0
fi

echo "✅ Version $VERSION applied."
echo "ℹ️  Remember to run ./tools/generate_checksums.sh afterwards."
