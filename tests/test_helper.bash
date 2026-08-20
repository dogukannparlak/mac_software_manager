# Shared bats setup for the zsh function tests in this directory.
#
# The script under test is zsh, not bash/POSIX sh - it uses '${(@f)...}',
# 'typeset -A', etc. that bash cannot parse. bats itself is bash, so tests
# never 'source' the script directly; they shell out to a real zsh subprocess
# that sources it (which the script's own $ZSH_EVAL_CONTEXT guard turns into
# "load the function definitions and stop", see update_system.1h.sh section 5)
# and then calls the function being tested.
#
# update_system.1h.sh is now a bootstrap + dispatcher that sources its actual
# functions from lib/*.sh under $MSU_LIB_DIR (production default: $APP_DIR/lib
# - see the "3. ENGINE LIBRARY" comment in the script). Tests point that env
# var straight at this repo's own lib/ directory, so they always exercise the
# current, uninstalled source - never a stale "installed" copy - with no setup
# step required.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REPO_SCRIPT="$REPO_ROOT/update_system.1h.sh"
REPO_LIB_DIR="$REPO_ROOT/lib"

setup() {
    # A throwaway HOME per test: the script derives APP_DIR/CACHE_DIR/etc.
    # from $HOME, so this keeps every test isolated from the real
    # ~/Library/Application Support/MacSoftwareUpdater and from each other.
    TEST_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$TEST_HOME"
}

# Usage: run run_zsh_fn <function_name> [args...]
# Sources the script (functions only, per the guard) under a fake HOME, then
# calls <function_name> with the given args and prints whatever it prints.
run_zsh_fn() {
    local fn="$1"
    shift
    HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" zsh -c "source '$REPO_SCRIPT'; \"\$@\"" -- "$fn" "$@"
}

# Usage: run run_zsh_snippet 'zsh code that can call any function/variable
# from the script'. For tests that need more than a single function call
# (multiple statements, checking a variable, a loop).
run_zsh_snippet() {
    local snippet="$1"
    HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" zsh -c "source '$REPO_SCRIPT'; $snippet"
}

# Assertions that actually fail the test.
#
# bats runs under macOS' /bin/bash 3.2, where a failing '[[ ]]' does NOT trip
# errexit inside a function - so a bare '[[ ... ]]' assertion anywhere but the
# LAST line of a test is silently ignored and the test passes regardless. That
# is not theoretical: it hid a broken cache fix in this very suite. A function
# returning non-zero (like the four below) is a plain command failure, which
# bats does catch wherever it appears - so use these, not bare '[[ ]]', for
# every string assertion. Plain '[ ... ]' is caught too and stays fine for
# $status / equality / file checks.
#
# assert_contains/refute_contains take a LITERAL substring; the _matches pair
# takes a glob pattern ('*' and friends are live, everything else literal).
assert_contains() {
    if [[ "$2" == *"$1"* ]]; then
        return 0
    fi
    echo "expected output to contain: $1" >&2
    echo "actual output: $2" >&2
    return 1
}

refute_contains() {
    if [[ "$2" != *"$1"* ]]; then
        return 0
    fi
    echo "expected output NOT to contain: $1" >&2
    echo "actual output: $2" >&2
    return 1
}

assert_matches() {
    if [[ "$2" == $1 ]]; then
        return 0
    fi
    echo "expected output to match: $1" >&2
    echo "actual output: $2" >&2
    return 1
}

refute_matches() {
    if [[ "$2" != $1 ]]; then
        return 0
    fi
    echo "expected output NOT to match: $1" >&2
    echo "actual output: $2" >&2
    return 1
}
