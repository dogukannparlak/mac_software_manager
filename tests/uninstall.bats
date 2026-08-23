load "test_helper"

# Coverage for uninstall.sh: the Step 1 glob regression, and the
# non-interactive mode GuideApp's Uninstall page drives.
#
# The Step 1 regression: under zsh's default options, a glob that matches
# nothing (e.g. the SwiftBar plugin was already removed by hand) throws "no
# matches found" instead of expanding to zero words - and since the script
# runs with `set -e`, that used to kill the whole uninstaller. FILES is now
# built via `find ... -print0` instead of `FILES=($EXPANDED_DIR/update_system.*.sh)`,
# which never throws.
#
# The Step 1 test extracts the literal block from uninstall.sh (rather than
# reimplementing it) so it tracks the real script and fails if the glob
# pattern is ever reintroduced.

REPO_UNINSTALL_SCRIPT="$REPO_ROOT/uninstall.sh"

extract_uninstall_step1() {
    awk '/^# 1\. Remove the SwiftBar Plugin/,/^# 2\. Remove the GuideApp Application/' "$REPO_UNINSTALL_SCRIPT" | sed '$d'
}

# The helpers the extracted block calls, stubbed to the "interactive user says
# no" behaviour. Keeps the extraction to one step instead of half the script.
STEP_HELPERS='
    say() { echo "$@"; }
    report() { :; }
    wants() { return 0; }
    confirm() { return 1; }
    perform() { "$@"; }
    removed() { :; }
    swiftbar_plugin_dir() { echo "$PLUGIN_DIR_STUB"; }
'

@test "uninstall.sh Step 1: no update_system scripts found does not crash under set -e" {
    local step1
    step1="$(extract_uninstall_step1)"
    [ -n "$step1" ]

    EMPTY_PLUGIN_DIR="$BATS_TEST_TMPDIR/empty_swiftbar_plugins"
    mkdir -p "$EMPTY_PLUGIN_DIR"

    run zsh -c "
        set -e
        PLUGIN_DIR_STUB='$EMPTY_PLUGIN_DIR'
        $STEP_HELPERS
        $step1
    "

    [ "$status" -eq 0 ]
    assert_contains "No update_system scripts found in $EMPTY_PLUGIN_DIR" "$output"
    refute_contains "no matches found" "$output"
}

# --- Non-interactive mode -------------------------------------------------
#
# GuideApp runs this script with step flags instead of answering [y/N] on a
# terminal it does not own. Two properties have to hold or the Uninstall page
# silently removes the wrong things: a flag run must touch only the steps
# named, and it must never block waiting on an answer.

@test "uninstall.sh --list reports one ITEM line per step and removes nothing" {
    run env HOME="$TEST_HOME" zsh "$REPO_UNINSTALL_SCRIPT" --list --app-path "$BATS_TEST_TMPDIR/nope.app"

    [ "$status" -eq 0 ]
    for key in plugin app login-item data prefs mas swiftbar; do
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
    refute_contains "RESULT|plugin|" "$output"
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
