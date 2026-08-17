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
