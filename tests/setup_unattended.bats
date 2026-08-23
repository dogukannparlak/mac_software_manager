load "test_helper"

# Coverage for setup_mac.sh --unattended: the mode MacUpdaterGuide.app runs
# from its setup sheet.
#
# The app has no terminal to answer a question on and no way to show one. So
# the property that matters more than any individual step is that this mode
# never blocks: every test below closes stdin, and a single surviving `read`
# turns into a hang rather than a wrong answer. Bats would kill it eventually;
# a user would just watch a spinner forever.
#
# The second property is that the app can read what happened. The STEP lines
# are the contract (see the `step()` helper in the script and SetupStep.parse
# in the app) - the prose around them is written for a person and is free to
# change, so nothing here asserts on it.

REPO_SETUP_SCRIPT="$REPO_ROOT/setup_mac.sh"

# --- Usage ----------------------------------------------------------------

@test "setup_mac.sh --help documents --unattended and its exit codes" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --help

    [ "$status" -eq 0 ]
    assert_contains "--unattended" "$output"
    assert_contains "STEP|" "$output"
    assert_contains "Exit codes:" "$output"
}

@test "setup_mac.sh rejects an unknown option with the bad-usage code" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --not-an-option < /dev/null

    [ "$status" -eq 2 ]
    assert_contains "Unknown option" "$output"
}

# --- No Homebrew ----------------------------------------------------------
#
# The script deliberately prepends /opt/homebrew/bin and /usr/local/bin to
# PATH before looking, so a test cannot hide the real Homebrew from it by
# setting PATH - and every machine this suite runs on has one. The block
# itself is extracted and run against an empty PATH instead, the same
# technique tests/uninstall.bats uses for its Step 1 glob: the assertion
# tracks the real script rather than a re-implementation of it, and fails if
# the exit code or the refusal is ever dropped.

extract_homebrew_check() {
    awk '/^# Check for Homebrew installation/,/^# Check for the mas CLI tool/' "$REPO_SETUP_SCRIPT" | sed '$d'
}

@test "setup_mac.sh --unattended refuses to install Homebrew and exits 3" {
    local block
    block="$(extract_homebrew_check)"
    [ -n "$block" ]

    local empty_bin="$BATS_TEST_TMPDIR/empty_bin"
    mkdir -p "$empty_bin"

    run zsh -c "
        set -e
        autoload -U colors && colors
        UNATTENDED=1
        step() { print -r -- \"STEP|\$1|\$2|\$3\"; }
        run_homebrew_script() { echo 'INSTALLER RAN'; return 0; }
        PATH='$empty_bin'
        $block
    " < /dev/null

    [ "$status" -eq 3 ]
    assert_contains "STEP|homebrew|fail|" "$output"
    assert_contains "https://brew.sh" "$output"
    # The whole point: it must not have reached for the installer, which asks
    # for an administrator password on a terminal that does not exist here.
    refute_contains "INSTALLER RAN" "$output"
}

@test "setup_mac.sh without --unattended still offers to install Homebrew" {
    local block
    block="$(extract_homebrew_check)"

    local empty_bin="$BATS_TEST_TMPDIR/empty_bin2"
    mkdir -p "$empty_bin"

    run zsh -c "
        set -e
        autoload -U colors && colors
        UNATTENDED=0
        step() { :; }
        run_homebrew_script() { echo 'INSTALLER RAN'; return 0; }
        PATH='$empty_bin'
        $block
    " < /dev/null

    [ "$status" -eq 0 ]
    assert_contains "INSTALLER RAN" "$output"
}

# --- A full local install -------------------------------------------------
#
# --local so the run touches no network and installs this working tree, which
# is also the combination the app uses when it is launched from a checkout.

@test "setup_mac.sh --local --unattended installs the engine without asking anything" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]

    # No question was printed, in either of the two shapes the script asks in.
    refute_contains "[y/N]" "$output"
    refute_contains "[Y/n]" "$output"
    refute_contains "Enter your choice" "$output"
    refute_contains "Codeberg username for the mirror" "$output"

    local app_dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    [ -x "$app_dir/update_system.1h.sh" ]
    [ -x "$app_dir/uninstall.sh" ]
    [ -f "$app_dir/settings.conf" ]
    [ -f "$app_dir/lib/utils.sh" ]
}

@test "setup_mac.sh --local --unattended reports its progress as STEP lines" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]
    assert_contains "STEP|homebrew|ok|" "$output"
    assert_contains "STEP|config|ok|" "$output"
    assert_contains "STEP|lib|ok|" "$output"
    assert_contains "STEP|plugin|ok|" "$output"
    assert_contains "STEP|done|ok|" "$output"

    # Every line claiming to be one has all four fields - a short record is
    # dropped by the app, so a step it reported would silently never appear.
    run bash -c "printf '%s\n' \"\$1\" | grep '^STEP|' | grep -vcE '^STEP\|[^|]+\|(start|ok|fail|skip)\|'" _ "$output"
    [ "$output" = "0" ]
}

@test "setup_mac.sh --local --unattended installs into the support folder" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]
    # ToolkitPaths.locateScript() looks here, and this is the only place the
    # engine is ever installed.
    [ -x "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/update_system.1h.sh" ]
    # ...and no plugin folder was invented anywhere else.
    [ ! -d "$TEST_HOME/Documents/SwiftBarPlugins" ]
}

@test "setup_mac.sh --local --unattended skips login items and the migration wizard" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]
    assert_contains "STEP|migration|skip|" "$output"
    assert_contains "STEP|login-item|skip|" "$output"
    refute_contains "Login Items" "$output"
    refute_contains "Scanning installed applications" "$output"
}

@test "setup_mac.sh --unattended keeps an existing configuration instead of asking again" {
    local app_dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$app_dir"
    # PREFERRED_TERMINAL is "Terminal" and not something more distinctive on
    # purpose: the default only follows the existing value while that terminal
    # is still installed, which is the same rule the interactive run uses and
    # not something --unattended changes. Apple's Terminal is the one that is
    # always there.
    cat > "$app_dir/settings.conf" << 'EOF'
PREFERRED_TERMINAL="Terminal"
MAS_ENABLED="0"
UPDATE_BRANCH="main"
AUTOSTART="0"
CLEANUP_ENABLED="0"
AUTO_INSTALL_APPS="1"
CODEBERG_USERNAME="someone"
EOF

    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]
    run cat "$app_dir/settings.conf"
    assert_contains 'PREFERRED_TERMINAL="Terminal"' "$output"
    assert_contains 'MAS_ENABLED="0"' "$output"
    assert_contains 'AUTOSTART="0"' "$output"
    assert_contains 'CLEANUP_ENABLED="0"' "$output"
    assert_contains 'AUTO_INSTALL_APPS="1"' "$output"
    assert_contains 'CODEBERG_USERNAME="someone"' "$output"
}

@test "setup_mac.sh --unattended never prints the interactive banner" {
    run env HOME="$TEST_HOME" zsh "$REPO_SETUP_SCRIPT" --local --unattended < /dev/null

    [ "$status" -eq 0 ]
    refute_contains "Software Update & Application Migration Toolkit" "$output"
}
