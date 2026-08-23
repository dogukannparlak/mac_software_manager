load "test_helper"

# Coverage for uninstall.sh: the non-interactive mode GuideApp's Uninstall
# page drives.

REPO_UNINSTALL_SCRIPT="$REPO_ROOT/uninstall.sh"

# --- Non-interactive mode -------------------------------------------------
#
# GuideApp runs this script with step flags instead of answering [y/N] on a
# terminal it does not own. Two properties have to hold or the Uninstall page
# silently removes the wrong things: a flag run must touch only the steps
# named, and it must never block waiting on an answer.

@test "uninstall.sh --list reports one ITEM line per step and removes nothing" {
    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --list --app-path "$BATS_TEST_TMPDIR/nope.app"

    [ "$status" -eq 0 ]
    for key in app login-item data prefs mas; do
        assert_matches "*ITEM|$key|*" "$output"
    done
    refute_contains "RESULT|" "$output"
}

@test "uninstall.sh with a step flag asks nothing and runs only that step" {
    mkdir -p "$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    touch "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/settings.conf"

    # No stdin at all: a stray ask_confirmation would read EOF and the run
    # would not report data as removed.
    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --data < /dev/null

    [ "$status" -eq 0 ]
    assert_contains "RESULT|data|removed|" "$output"
    [ ! -d "$TEST_HOME/Library/Application Support/MacSoftwareUpdater" ]

    # Nothing else was even considered.
    refute_contains "RESULT|app|" "$output"
    refute_contains "RESULT|prefs|" "$output"
    refute_contains "[y/N]" "$output"
}

@test "uninstall.sh --dry-run reports what it would do without removing it" {
    local data_dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$data_dir"

    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --data --dry-run < /dev/null

    [ "$status" -eq 0 ]
    assert_contains "RESULT|data|dryrun|" "$output"
    [ -d "$data_dir" ]
}

@test "uninstall.sh never offers to remove Homebrew" {
    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --help

    [ "$status" -eq 0 ]
    refute_contains "Homebrew/install" "$(cat "$REPO_UNINSTALL_SCRIPT")"
    refute_contains "uninstall Homebrew" "$output"
}

@test "uninstall.sh rejects an unknown option instead of removing anything" {
    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --nuke-everything < /dev/null

    [ "$status" -eq 2 ]
    assert_contains "Unknown option" "$output"
}
