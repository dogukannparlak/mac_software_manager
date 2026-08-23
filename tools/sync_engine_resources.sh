#!/bin/zsh
#
# Copy the engine into the app target, so MacUpdaterGuide.app runs the toolkit
# out of its own bundle instead of installing a copy of it first.
#
#   ./tools/sync_engine_resources.sh          refresh the copies
#   ./tools/sync_engine_resources.sh --check  fail if they are out of date
#
# Why a copy at all. The engine's source of truth is the repository root -
# that is what SHA256SUMS describes, what setup_mac.sh publishes and what the
# bats suite tests. But an .app can only ship files that are inside the target
# directory when it is built, and neither SwiftPM nor Xcode's synchronized
# groups will reach outside it. A symlink is not an option either: code
# signing follows it and a signed bundle with a link pointing out of itself
# does not verify.
#
# So the copies are real, committed, and checked. --check runs in
# build_release.sh next to the version and checksum guards, for the same
# reason those exist: a release that ships an engine older than the one in
# this tree is a bug nobody notices until a user hits it.

set -e
set -o pipefail

autoload -U colors && colors

REPO_ROOT="${0:a:h:h}"
DEST="$REPO_ROOT/GuideApp/Sources/MacUpdaterGuide/EngineResources"

# Exactly what the app runs out of its own bundle: the engine, its library,
# and the uninstaller the Uninstall page drives. Keep the lib list in step with
# LIB_NAMES in update_system.1h.sh - the engine refuses to start without all of
# them. setup_mac.sh is deliberately absent: the app no longer installs
# anything, and that script is now only the terminal path for SwiftBar users.
typeset -a ENGINE_FILES
ENGINE_FILES=(
    uninstall.sh
    update_system.1h.sh
    lib/utils.sh
    lib/cache.sh
    lib/ignored.sh
    lib/history.sh
    lib/selfupdate.sh
    lib/updaters.sh
    lib/selfupdate_apps.sh
    lib/app_install.sh
    lib/migrate.sh
    lib/run_modes.sh
    lib/menu.sh
)

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

if (( CHECK_ONLY )); then
    stale=0
    for file in "${ENGINE_FILES[@]}"; do
        if [[ ! -f "$DEST/$file" ]]; then
            echo "${fg[red]}❌ missing from the app bundle: $file${reset_color}"
            stale=1
        elif ! cmp -s "$REPO_ROOT/$file" "$DEST/$file"; then
            echo "${fg[red]}❌ out of date in the app bundle: $file${reset_color}"
            stale=1
        fi
    done
    if (( stale )); then
        echo "Run ./tools/sync_engine_resources.sh and commit the result."
        exit 1
    fi
    echo "${fg[green]}✅ Bundled engine matches the repository.${reset_color}"
    exit 0
fi

mkdir -p "$DEST/lib"
for file in "${ENGINE_FILES[@]}"; do
    cp "$REPO_ROOT/$file" "$DEST/$file"
done
# Executable in the tree it is copied from, and the installer chmods what it
# installs - but a resource that arrives with its bit already set is one less
# thing depending on the copier.
chmod +x "$DEST/uninstall.sh" "$DEST/update_system.1h.sh"

echo "${fg[green]}✅ Bundled engine refreshed (${#ENGINE_FILES[@]} files) in${reset_color}"
echo "   $DEST"
