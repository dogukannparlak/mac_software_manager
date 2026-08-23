#!/bin/zsh
#
# Build the release artifacts into dist/ - the two files GitHub Releases
# carries, plus the checksum file people verify them against.
#
#   ./tools/build_release.sh            build the version in ./VERSION
#   ./tools/build_release.sh --keep-old leave older versions in dist/ alone
#                                       (the default is to leave them alone;
#                                        pass --clean to remove them instead)
#   ./tools/build_release.sh --clean    empty dist/ first
#
# Both archives are the same universal .app: the .dmg for drag-and-drop, the
# .zip because it is about 20% smaller. dist/ is gitignored - these are built
# from a tag and uploaded, never committed.

set -e
set -o pipefail

autoload -U colors && colors

REPO_ROOT="${0:a:h:h}"
APP_NAME="MacUpdaterGuide"
PROJECT="$REPO_ROOT/GuideApp/$APP_NAME.xcodeproj"
DERIVED="$REPO_ROOT/GuideApp/DerivedData-release"
DIST="$REPO_ROOT/dist"
VERSION="$(<"$REPO_ROOT/VERSION")"
BASENAME="$APP_NAME-$VERSION-macOS-universal"

DO_CLEAN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)    DO_CLEAN=1 ;;
        --keep-old) DO_CLEAN=0 ;;
        -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "Unknown option: $1  (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if ! command -v xcodebuild > /dev/null 2>&1; then
    echo "${fg[red]}❌ xcodebuild not found. Install Xcode, then run:${reset_color}"
    echo "   sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

# A release built from a tree whose version strings disagree ships a binary
# saying one thing and an engine saying another, and self-update verifies
# against a SHA256SUMS that no longer describes the files. Cheaper to catch
# here than after upload.
echo "${fg[blue]}▸ Checking version strings and checksums${reset_color}"
"$REPO_ROOT/tools/sync_version.sh" --check
"$REPO_ROOT/tools/generate_checksums.sh" --check

echo "${fg[blue]}▸ Building $APP_NAME $VERSION (Release, universal)${reset_color}"
rm -rf "$DERIVED"
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/macupdaterguide-release.XXXXXX")"
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build > "$BUILD_LOG" 2>&1; then
    echo "${fg[red]}❌ Build failed:${reset_color}"
    grep -E "error:" "$BUILD_LOG" | head -30 || tail -30 "$BUILD_LOG"
    echo "Full log: $BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "${fg[red]}❌ Not where expected: $APP${reset_color}"; exit 1; }

# "universal" is in the filename people download, so it is worth being a fact
# rather than an intention: a machine with only one slice installed will
# happily produce a single-architecture build otherwise.
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "  architectures: $ARCHS_BUILT"
for want in arm64 x86_64; do
    if [[ "$ARCHS_BUILT" != *"$want"* ]]; then
        echo "${fg[red]}❌ Not universal - $want is missing.${reset_color}"
        exit 1
    fi
done

# Ad-hoc, by design (CODE_SIGN_IDENTITY = "-"). Not a Developer ID signature,
# but a broken one would make the app refuse to launch at all, so check it.
codesign --verify --deep --strict "$APP"
echo "  signature: $(codesign -dv "$APP" 2>&1 | grep -m1 'Signature=' || echo 'ad-hoc')"

if (( DO_CLEAN )); then
    echo "${fg[blue]}▸ Emptying $DIST${reset_color}"
    rm -rf "$DIST"
fi
mkdir -p "$DIST"

echo "${fg[blue]}▸ Packaging $BASENAME.zip${reset_color}"
# ditto, not zip: it is the one that keeps symlinks, resource forks and the
# signature intact, and an archive that breaks the signature is an app macOS
# refuses to open.
rm -f "$DIST/$BASENAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$BASENAME.zip"

echo "${fg[blue]}▸ Packaging $BASENAME.dmg${reset_color}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/macupdaterguide-dmg.XXXXXX")"
ditto "$APP" "$STAGING/$APP_NAME.app"
# The drag-and-drop target. Without it the disk image opens onto an app with
# nowhere obvious to go.
ln -s /Applications "$STAGING/Applications"
rm -f "$DIST/$BASENAME.dmg"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$DIST/$BASENAME.dmg"
rm -rf "$STAGING"

echo "${fg[blue]}▸ Writing SHA256SUMS.txt${reset_color}"
# Every archive in dist/, not just the two just built: the file is what
# someone checks a download against, and it has to describe the folder they
# are looking at rather than one build of it.
(
    cd "$DIST"
    rm -f SHA256SUMS.txt
    shasum -a 256 *.dmg *.zip > SHA256SUMS.txt
)

echo ""
echo "${fg[green]}✅ $APP_NAME $VERSION built.${reset_color}"
ls -lh "$DIST"
echo ""
cat "$DIST/SHA256SUMS.txt"
