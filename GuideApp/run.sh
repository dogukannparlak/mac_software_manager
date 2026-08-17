#!/bin/zsh
#
# Build and launch MacUpdaterGuide without opening Xcode.
#
#   ./run.sh              build (Debug) and launch
#   ./run.sh -n           launch what is already built, no rebuild
#   ./run.sh -r           build Release instead of Debug
#   ./run.sh --install    build Release and copy into /Applications
#   ./run.sh --clean      throw the build folder away first
#
# xcodebuild prints hundreds of lines even when everything is fine, so its
# output is kept quiet and only surfaced when the build actually fails.

set -e
set -o pipefail

APP_NAME="MacUpdaterGuide"
PROJECT_DIR="${0:a:h}"
PROJECT="$PROJECT_DIR/$APP_NAME.xcodeproj"
DERIVED="$PROJECT_DIR/DerivedData"

CONFIGURATION="Debug"
DO_BUILD=1
DO_INSTALL=0
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--no-build)  DO_BUILD=0 ;;
        -r|--release)   CONFIGURATION="Release" ;;
        --install)      CONFIGURATION="Release"; DO_INSTALL=1 ;;
        --clean)        DO_CLEAN=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1  (try --help)"
            exit 1
            ;;
    esac
    shift
done

if ! command -v xcodebuild > /dev/null 2>&1; then
    echo "❌ xcodebuild not found. Install Xcode, then run:"
    echo "   sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

APP_PATH="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME.app"

if (( DO_CLEAN )); then
    echo "🧹 Removing $DERIVED"
    rm -rf "$DERIVED"
fi

if (( DO_BUILD )); then
    echo "🔨 Building $APP_NAME ($CONFIGURATION)..."
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/macupdaterguide-build.XXXXXX")"

    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$APP_NAME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED" \
        build > "$BUILD_LOG" 2>&1; then
        echo ""
        echo "❌ Build failed:"
        # Compiler diagnostics only - the rest is noise
        grep -E "error:|warning:.*(deprecated|unused)" "$BUILD_LOG" | head -30 || tail -30 "$BUILD_LOG"
        echo ""
        echo "Full log: $BUILD_LOG"
        exit 1
    fi

    rm -f "$BUILD_LOG"
    echo "✅ Build succeeded."
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ Not built yet: $APP_PATH"
    echo "   Run without -n to build it first."
    exit 1
fi

# A second copy would put two icons in the menu bar
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "⏹  Stopping the running copy..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
fi

if (( DO_INSTALL )); then
    TARGET="/Applications/$APP_NAME.app"
    echo "📦 Installing to $TARGET"
    rm -rf "$TARGET"
    cp -R "$APP_PATH" "$TARGET"
    APP_PATH="$TARGET"
    echo "   Launch at login works properly from /Applications."
fi

echo "🚀 Launching $APP_PATH"
open "$APP_PATH"

sleep 2
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo ""
    echo "Running. Look for the icon in the menu bar."
    echo "  Menu bar panel  : click the icon"
    echo "  Settings        : Cmd+, (or Settings… in the panel)"
    echo "  Stop it         : pkill -x $APP_NAME"
else
    echo "⚠️  It did not stay running. Start it in the foreground to see why:"
    echo "   $APP_PATH/Contents/MacOS/$APP_NAME"
fi
