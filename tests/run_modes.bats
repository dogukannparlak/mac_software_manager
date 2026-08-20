load "test_helper"

# `run --separate-stderr` (used by the stderr-split tests at the bottom of
# this file) is a bats 1.5+ flag; without this line bats warns and ignores it.
bats_require_minimum_version 1.5.0

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
    assert_contains "Preparing update for myapp" "$output"
    assert_contains "No pending update recorded for myapp" "$output"
    refute_contains "No application specified" "$output"
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
    assert_contains "No application specified" "$output"
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
    assert_contains "Updating MyFakeName (1.0 -> 2.0)" "$output"
    assert_contains "STUB brew upgrade my-fake-token" "$output"
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
    refute_contains "STUB brew" "$output"
    assert_contains "Updating  (? -> ?)" "$output"
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
    assert_contains "Added to history log (ok)" "$output"
    assert_matches '*HISTORY: *|brew|MyFakeName|1.0|2.0|my-fake-token|ok*' "$output"
    assert_contains "PROGRESS: v1|done|single|MyFakeName||" "$output"
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
    assert_contains "Added to history log (fail)" "$output"
    assert_contains "|my-fake-token|fail" "$output"
    assert_contains "PROGRESS: v1|failed|single|MyFakeName||" "$output"
}

@test "run_mode_single still reports 'done' when a cache entry cannot be refreshed" {
    # The reported bug, end to end: 'run' turns errexit on
    # (update_system.1h.sh section 5), so a single failing cache entry inside
    # collect_cache_data used to abort the run right there - the cache stayed
    # half-rebuilt and the final progress line was never written, leaving
    # GuideApp to read the stale cache and show this successful update as
    # "failed" while history had already logged it "ok".
    #
    # Only cache_refresh_entry is stubbed (failing for one key, succeeding for
    # the rest); the real collect_cache_data runs.
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        brew() { return 0; }
        brew_is_outdated() { return 1; }   # upgraded, no longer outdated
        open() { :; }
        sleep() { :; }

        cache_refresh_entry() {
            [[ "$1" == "brew_outdated" ]] && return 1
            cache_put "$1" "stub"
        }

        set -e
        set -o pipefail
        set -- run single brew my-fake-token MyFakeName 1.0 2.0
        ( run_mode_single "$@" )
        echo "PROGRESS: $(cat "$PROGRESS_FILE")"
        echo "HISTORY: $(cat "$HISTORY_FILE")"
        echo "LEAVES: $(cache_get brew_leaves)"
    '
    # History and progress agree, and the entries after the failing one were
    # still collected.
    assert_contains "|my-fake-token|ok" "$output"
    assert_contains "LEAVES: stub" "$output"
    assert_contains "PROGRESS: v1|done|single|MyFakeName||" "$output"
    [ "$status" -eq 0 ]
}

# --- 'single' mode, App Store apps ---
#
# Reported on a real machine: clicking Update on an already-installed App
# Store app ran 'mas install' instead of 'mas upgrade'. The install/upgrade
# choice was made by 'mas list | awk | grep -q "^$id$"', and 'run' executes
# under 'set -o pipefail' (update_system.1h.sh section 5): grep -q exits at
# the FIRST match, mas and awk then die of SIGPIPE, and pipefail reports the
# pipeline as 141 - so finding the app made the condition read false.

@test "run_mode_single upgrades an installed App Store app even when 'mas list' is long" {
    # The list has to be bigger than the pipe buffer for SIGPIPE to land, so
    # this stub prints the target first and then ~20k filler lines - exactly
    # the shape (a real 'mas list') that made the old pipeline misfire.
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=0
        mas() {
            case "$1" in
                list)
                    echo "497799835  Xcode  (14.2)"
                    repeat 20000; do echo "9000001  Filler App  (1.0)"; done
                    ;;
                outdated) ;;
                *) echo "STUB mas $*" ;;
            esac
            return 0
        }
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -o pipefail
        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
        echo "HISTORY: $(cat "$HISTORY_FILE")"
    '
    assert_contains "STUB mas upgrade 497799835" "$output"
    refute_contains "STUB mas install" "$output"
    assert_contains "|497799835|ok" "$output"
}

@test "run_mode_single still installs an App Store app that is not in 'mas list'" {
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=0
        mas() {
            case "$1" in
                list) echo "111111111  Some Other App  (1.0)" ;;
                outdated) ;;
                *) echo "STUB mas $*" ;;
            esac
            return 0
        }
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -o pipefail
        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
    '
    assert_contains "STUB mas install 497799835" "$output"
    refute_contains "STUB mas upgrade" "$output"
}

@test "run_mode_single reports a missing 'mas' instead of dying with exit 127" {
    # Every other mas call site pairs MAS_ENABLED with 'command -v mas';
    # run_mode_single did not, so MAS_ENABLED=1 without mas installed ran a
    # command that does not exist.
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=1
        PATH=/usr/bin:/bin
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
        echo "RC: $?"
    '
    assert_contains "is not installed" "$output"
    assert_contains "RC: 1" "$output"
    refute_contains "RC: 127" "$output"
}

@test "run_mode_single still refuses App Store updates when MAS_ENABLED is 0" {
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=0
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
        echo "RC: $?"
    '
    assert_contains "App Store updates are disabled" "$output"
    assert_contains "RC: 1" "$output"
}

@test "run_mode_single kills a hanging 'mas upgrade' instead of running forever" {
    # 'mas' has no timeout of its own, and this is the path GuideApp's
    # headless single-item runs take - an unguarded call here left the app
    # showing a spinner for a run that was never going to end.
    run run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=0
        MAS_UPGRADE_TIMEOUT=1
        mas() {
            case "$1" in
                list) echo "497799835  Xcode  (14.1)" ;;
                outdated) ;;
                *) sleep 30 ;;
            esac
            return 0
        }
        collect_cache_data() { :; }
        open() { :; }

        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
        echo "HISTORY: $(cat "$HISTORY_FILE")"
    '
    assert_contains "Timed out after 1s" "$output"
    assert_contains "|497799835|fail" "$output"
}

@test "run_mode_single writes its failure reason to stderr, not stdout" {
    # GuideApp nulls a headless run's stdout and keeps its stderr
    # (ToolkitController.startProcess), and that stderr is the only account a
    # failed row has of why it failed. On stdout these lines went nowhere.
    run --separate-stderr run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=0
        MAS_UPGRADE_TIMEOUT=1
        mas() {
            case "$1" in
                list) echo "497799835  Xcode  (14.1)" ;;
                outdated) ;;
                *) sleep 30 ;;
            esac
            return 0
        }
        collect_cache_data() { :; }
        open() { :; }

        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
    '
    assert_contains "Timed out after 1s" "$stderr"
    assert_contains "Update FAILED for Xcode" "$stderr"
    refute_contains "Timed out after 1s" "$output"
    refute_contains "Update FAILED for Xcode" "$output"
    # The narration itself stays on stdout - this is a split, not a move.
    assert_contains "Updating Xcode" "$output"
}

@test "run_mode_single reports a disabled or missing 'mas' on stderr" {
    run --separate-stderr run_zsh_snippet '
        mkdir -p "${HISTORY_FILE:h}" "$CACHE_DIR"
        MAS_ENABLED=0
        collect_cache_data() { :; }
        open() { :; }
        sleep() { :; }

        set -- run single mas 497799835 Xcode 14.1 14.2
        ( run_mode_single "$@" )
    '
    assert_contains "App Store updates are disabled" "$stderr"
    refute_contains "App Store updates are disabled" "$output"
}
