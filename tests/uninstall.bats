load "test_helper"

# Regression coverage for uninstall.sh Step 1 (SwiftBar plugin removal): under
# zsh's default options, a glob that matches nothing (e.g. the SwiftBar
# plugin was already removed by hand) throws "no matches found" instead of
# expanding to zero words - and since the script runs with `set -e`, that
# used to kill the whole uninstaller. FILES is now built via `find ... -print0`
# instead of `FILES=($EXPANDED_DIR/update_system.*.sh)`, which never throws.
#
# This test extracts the literal Step 1 block from uninstall.sh (rather than
# reimplementing it) so it tracks the real script and fails if the glob
# pattern is ever reintroduced.

REPO_UNINSTALL_SCRIPT="$REPO_ROOT/uninstall.sh"

extract_uninstall_step1() {
    awk '/^# 1\. Remove the SwiftBar Plugin/,/^# 2\. Remove the GuideApp Application/' "$REPO_UNINSTALL_SCRIPT" | sed '$d'
}

@test "uninstall.sh Step 1: no update_system scripts found does not crash under set -e" {
    local step1
    step1="$(extract_uninstall_step1)"
    [ -n "$step1" ]

    EMPTY_PLUGIN_DIR="$BATS_TEST_TMPDIR/empty_swiftbar_plugins"
    mkdir -p "$EMPTY_PLUGIN_DIR"

    run zsh -c "
        set -e
        ask_confirmation() { return 1; }
        defaults() { echo '$EMPTY_PLUGIN_DIR'; }
        $step1
    "

    [ "$status" -eq 0 ]
    assert_contains "No update_system scripts found in $EMPTY_PLUGIN_DIR" "$output"
    refute_contains "no matches found" "$output"
}
