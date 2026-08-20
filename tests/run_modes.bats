load "test_helper"

# Regression coverage for the exact risk flagged when the ~530-line 'run'
# dispatch block (update_system.1h.sh, formerly one giant `if`) was split into
# lib/run_modes.sh functions: a zsh function gets its OWN positional
# parameters from how it is called - it does not inherit the caller's $1 $2
# $3... So the dispatcher (the `case "$MODE" in ...` in update_system.1h.sh)
# MUST call run_mode_install/run_mode_single as `run_mode_install "$@"` /
# `run_mode_single "$@"`. Calling either bare would silently leave
# target_app/type/id empty. These tests exercise both functions far enough to
# distinguish "argument arrived" from "argument was empty", without going far
# enough to touch brew/mas for real.

@test "run_mode_install correctly reads target_app from \$3 when called with \"\$@\"" {
    run run_zsh_snippet '
        set -- run install myapp dry
        run_mode_install "$@"
    '
    [ "$status" -eq 1 ]
    [[ "$output" == *"Preparing update for myapp"* ]]
    [[ "$output" == *"No pending update recorded for myapp"* ]]
    [[ "$output" != *"No application specified"* ]]
}

@test "run_mode_install regression: calling it bare loses \$3 (target_app)" {
    # This is the exact bug the dispatcher's "$@" forwarding exists to avoid -
    # locked in so a future refactor that drops it fails loudly here instead
    # of silently breaking every 'Install'/'Dry run' menu click.
    run run_zsh_snippet '
        set -- run install myapp dry
        run_mode_install
    '
    [ "$status" -eq 1 ]
    [[ "$output" == *"No application specified"* ]]
}

@test "run_mode_single correctly reads type/id/name from \$3-\$5 when called with \"\$@\"" {
    run run_zsh_snippet '
        # Stub out anything that would touch the real system - this test is
        # only about whether the positional parameters arrived, not about
        # actually upgrading a package.
        brew() { echo "STUB brew $*"; return 1; }
        collect_cache_data() { :; }
        open() { :; }

        set -- run single brew my-fake-token MyFakeName 1.0 2.0
        run_mode_single "$@"
    '
    [[ "$output" == *"Updating MyFakeName (1.0 -> 2.0)"* ]]
    [[ "$output" == *"STUB brew upgrade my-fake-token"* ]]
}

@test "run_mode_single regression: calling it bare loses \$3-\$5 (type/id/name)" {
    run run_zsh_snippet '
        brew() { echo "STUB brew $*"; return 1; }
        collect_cache_data() { :; }
        open() { :; }

        set -- run single brew my-fake-token MyFakeName 1.0 2.0
        run_mode_single
    '
    # With no arguments, $3/$4 are empty: type is empty (matches neither
    # "brew|cask" nor "mas" in the case), so update_rc stays 0 and the stub
    # brew() is never even called - name falls back to the empty id.
    [[ "$output" != *"STUB brew"* ]]
    [[ "$output" == *"Updating  (? -> ?)"* ]]
}

@test "run_mode_single reaches the history log and a final progress state on success" {
    # Everything below the 'brew upgrade' call used to be unreachable: the
    # history line was built with a variable named 'status', which is a
    # read-only special parameter in zsh, so the assignment was a fatal error
    # that killed the function on the spot - no history entry, no cache
    # rebuild, and progress left stuck on "running" forever.
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        brew() { return 0; }
        brew_is_outdated() { return 1; }   # upgraded, no longer outdated
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -- run single brew my-fake-token MyFakeName 1.0 2.0
        ( run_mode_single "$@" )
        echo "HISTORY: $(cat "$HISTORY_FILE")"
        echo "PROGRESS: $(cat "$PROGRESS_FILE")"
    '
    [[ "$output" == *"Added to history log (ok)"* ]]
    [[ "$output" == *"HISTORY: "*"|brew|MyFakeName|1.0|2.0|my-fake-token|ok"* ]]
    [[ "$output" == *"PROGRESS: v1|done|single|MyFakeName||"* ]]
}

@test "run_mode_single logs a failed upgrade as failed" {
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        brew() { return 1; }
        brew_is_outdated() { return 0; }
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -- run single brew my-fake-token MyFakeName 1.0 2.0
        ( run_mode_single "$@" )
        echo "HISTORY: $(cat "$HISTORY_FILE")"
        echo "PROGRESS: $(cat "$PROGRESS_FILE")"
    '
    [[ "$output" == *"Added to history log (fail)"* ]]
    [[ "$output" == *"|my-fake-token|fail"* ]]
    [[ "$output" == *"PROGRESS: v1|failed|single|MyFakeName||"* ]]
}
