load "test_helper"

# The app runs the engine out of its own bundle - no install step - so three
# lists of engine files have to agree, in three languages:
#
#   1. LIB_NAMES in update_system.1h.sh          - what the engine sources
#   2. ENGINE_FILES in sync_engine_resources.sh  - what is copied into the app
#   3. libraryNames in BundledEngine.swift       - what the app checks is there
#
# A file present in one and missing from another is not a build failure. The
# engine exits on the first library file it cannot read, so the app launches,
# the first run dies on line one, and nothing says why - on a machine the
# developer does not have. Hence these.

SYNC_SCRIPT="$REPO_ROOT/tools/sync_engine_resources.sh"
SWIFT_BUNDLED="$REPO_ROOT/GuideApp/Sources/MacUpdaterGuide/Toolkit/BundledEngine.swift"
RESOURCES="$REPO_ROOT/GuideApp/Sources/MacUpdaterGuide/EngineResources"

# The ENGINE_FILES array, one path per line.
shell_engine_files() {
    awk '/^ENGINE_FILES=\(/,/^\)/' "$SYNC_SCRIPT" \
        | sed -e '1d' -e '$d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$'
}

# The Swift libraryNames array, one bare name per line.
swift_library_names() {
    awk '/static let libraryNames = \[/,/^    \]/' "$SWIFT_BUNDLED" \
        | grep -oE '"[^"]+"' \
        | tr -d '"'
}

# LIB_NAMES straight out of the engine, one bare name per line.
engine_library_names() {
    grep -E '^LIB_NAMES=\(' "$REPO_ROOT/update_system.1h.sh" \
        | sed -e 's/^LIB_NAMES=(//' -e 's/)$//' \
        | tr ' ' '\n' \
        | grep -v '^$'
}

@test "the engine's LIB_NAMES and the app's libraryNames are identical" {
    local engine_list swift_list
    engine_list="$(engine_library_names)"
    swift_list="$(swift_library_names)"

    [ -n "$engine_list" ]
    [ -n "$swift_list" ]

    if [ "$engine_list" != "$swift_list" ]; then
        echo "update_system.1h.sh LIB_NAMES:" >&2
        echo "$engine_list" >&2
        echo "BundledEngine.swift libraryNames:" >&2
        echo "$swift_list" >&2
        return 1
    fi
}

@test "every lib file the engine sources is carried in the app bundle" {
    local shell_list
    shell_list="$(shell_engine_files)"

    while read -r name; do
        assert_contains "lib/${name}.sh" "$shell_list"
        [ -f "$RESOURCES/lib/${name}.sh" ]
    done <<< "$(engine_library_names)"
}

@test "the copies in the app target match the repository" {
    run zsh "$SYNC_SCRIPT" --check

    [ "$status" -eq 0 ]
    assert_contains "matches the repository" "$output"
}

@test "the bundle carries no installer - there is nothing to install" {
    # setup_mac.sh is the terminal path for SwiftBar users, not something the
    # app runs. Shipping it inside the bundle would invite exactly the "install
    # yourself first" step this design removed.
    [ ! -f "$RESOURCES/setup_mac.sh" ]
}

@test "the bundled engine runs in place, with MSU_LIB_DIR and nothing installed" {
    # Exactly what the app does: run the engine where it lies, pointing
    # MSU_LIB_DIR at the bundled library. Nothing is installed first, and the
    # support folder does not exist when this starts.
    [ ! -d "$TEST_HOME/Library/Application Support/MacSoftwareUpdater" ]

    run env HOME="$TEST_HOME" MSU_LIB_DIR="$RESOURCES/lib" \
        zsh "$RESOURCES/update_system.1h.sh" get_settings < /dev/null

    [ "$status" -eq 0 ]
    refute_contains "Missing engine file" "$output"
    # The engine created its own state directory on the way through, which is
    # what makes an install step unnecessary.
    [ -d "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache" ]
}

@test "the engine refuses to run without its library, rather than half-working" {
    run env HOME="$TEST_HOME" MSU_LIB_DIR="$BATS_TEST_TMPDIR/nothing-here" \
        zsh "$RESOURCES/update_system.1h.sh" get_settings < /dev/null

    [ "$status" -eq 1 ]
    assert_contains "Missing engine file" "$output"
}
