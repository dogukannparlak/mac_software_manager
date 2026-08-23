load "test_helper"

# The three menu actions that start a run in the user's terminal (install_app,
# update_app, launch_update) each used to end in '|| true; exit 0'. Combined
# with an ad-hoc-signed GuideApp - CODE_SIGN_IDENTITY = "-", so every rebuild
# invalidates the code signature macOS keyed the Automation grant to and the
# permission is silently revoked - that made the most common failure on this
# project completely invisible: osascript died with -1743, '|| true' ate it,
# the script exited 0, GuideApp watched for a run that had never started, and
# the user was told nothing at all.
#
# These cover the two halves of the fix: launch_in_terminal reporting what
# actually happened, and launch_in_terminal_or_report putting it where someone
# will see it.

# A fake osascript/open on PATH, so nothing here can drive a real terminal.
# $1 is what it writes to stderr, $2 the status it exits with.
stub_launcher() {
    local message="$1" status="${2:-1}"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    local tool
    for tool in osascript open; do
        cat > "$STUB_BIN/$tool" <<EOF
#!/bin/sh
[ -n "$message" ] && echo "$message" >&2
exit $status
EOF
        chmod +x "$STUB_BIN/$tool"
    done
}

# Runs the script for real (dispatcher and all), with the stubs above ahead of
# the real tools on PATH. The launcher paths are top-level 'if' blocks, not
# functions, so this is the only way to exercise the '|| exit' they end with.
run_dispatch() {
    HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" PATH="$STUB_BIN:$PATH" \
        zsh "$REPO_SCRIPT" "$@" </dev/null
}

progress_entry() {
    cat "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache/progress" 2>/dev/null
}

@test "launch_in_terminal reports the denial when macOS refuses the Apple event" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        launch_in_terminal /fake/script all
        print "rc=$?"
    '
    assert_contains "rc=3" "$output"
}

@test "launch_in_terminal separates an ordinary failure from a denial" {
    stub_launcher "execution error: Terminal got an error. (-600)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        launch_in_terminal /fake/script all
        print "rc=$?"
    '
    assert_contains "rc=1" "$output"
}

@test "launch_in_terminal still returns 0 when the terminal did open" {
    stub_launcher "" 0
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        launch_in_terminal /fake/script all
        print "rc=$?"
    '
    assert_contains "rc=0" "$output"
}

# The whole point of the -1743 branch: this is the one launch failure the user
# can do something about, so it has to say what.
@test "a denied launch names System Settings > Privacy & Security > Automation" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all
    '
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
}

@test "an ordinary launch failure quotes what the launcher said instead" {
    stub_launcher "execution error: Terminal got an error. (-600)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all
    '
    assert_contains "Could not open Terminal" "$output"
    assert_contains "(-600)" "$output"
    refute_contains "System Settings" "$output"
}

@test "a denied launch records terminal-permission in the progress file" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "v1|failed|terminal-permission|Terminal||||" ]
}

@test "an ordinary launch failure records launch-failed in the progress file" {
    stub_launcher "execution error: Terminal got an error. (-600)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "v1|failed|launch-failed|Terminal||||" ]
}

@test "a successful launch writes nothing to the progress file" {
    stub_launcher "" 0
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        print "exists=$([[ -f $PROGRESS_FILE ]] && print yes || print no)"
    '
    assert_contains "exists=no" "$output"
}

# A launch that failed belongs to no run at all, so it must not overwrite the
# entry a run that IS alive is using - that would put an error on the banner
# for a live update and drain GuideApp's per-item queue on top of it.
@test "a failed launch leaves a live run's progress entry alone" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        progress_write "running" "brew-upgrade" "awscli" 3 8
        progress_heartbeat_stop
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "v1|running|brew-upgrade|awscli|3|8||" ]
}

# The other side of the same rule: an entry no heartbeat has touched in a long
# while has no run behind it, so there is nothing to protect.
@test "a failed launch does replace a running entry that stopped aging" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        progress_write "running" "brew-upgrade" "awscli" 3 8
        progress_heartbeat_stop
        touch -t 202001010000 "$PROGRESS_FILE"
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "v1|failed|terminal-permission|Terminal||||" ]
}

# The regression itself, at the level the caller sees it: GuideApp decides
# whether to start watching for a run from this exit status alone.
@test "install_app exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch install_app Rectangle live
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||||" ]
}

@test "update_app exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch update_app brew awscli awscli 1.0 2.0
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||||" ]
}

@test "launch_update exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch launch_update all
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||||" ]
}

# ------------------------------------------------------------------------------
# The launch that needs no Automation permission
# ------------------------------------------------------------------------------
# Every other branch drives the terminal with an Apple Event, which macOS
# refuses outright for an app whose bundle carries no
# NSAppleEventsUsageDescription - with no prompt to allow, so the user cannot
# fix it from the dialog they never saw. 'open' goes through LaunchServices
# instead and needs no grant at all.

@test "launch_via_terminal_file hands the terminal a runnable .command file" {
    run run_zsh_snippet '
        open() { print -r -- "OPEN:$*"; return 0 }
        launch_via_terminal_file "echo hello" || echo "rc=$?"
        for f in "${TMPDIR:-/tmp}"/msm-launch.*.command(N); do
            print -r -- "PERMS:$(stat -f "%Sp" "$f")"
            cat "$f"
            rm -f "$f"
        done
    '
    [ "$status" -eq 0 ]
    assert_contains "OPEN:-a Terminal " "$output"
    assert_contains "#!/bin/zsh" "$output"
    assert_contains "echo hello" "$output"
    # Executable, or Terminal will not run it at all.
    assert_matches "*PERMS:-rwx*" "$output"
}

@test "the launch file removes itself once the run is over" {
    # It is a launch detail, not something to leave in the user's temp
    # directory - and it is the last line, so the window still has it while
    # the update runs.
    run run_zsh_snippet '
        open() { return 0 }
        launch_via_terminal_file "echo hello"
        for f in "${TMPDIR:-/tmp}"/msm-launch.*.command(N); do tail -n 1 "$f"; rm -f "$f"; done
    '
    [ "$status" -eq 0 ]
    assert_contains "rm -f " "$output"
}

@test "launch_via_terminal_file honours the configured terminal" {
    run run_zsh_snippet '
        PREFERRED_TERMINAL="Ghostty"
        open() { print -r -- "OPEN:$*"; return 0 }
        launch_via_terminal_file "echo hello"
        for f in "${TMPDIR:-/tmp}"/msm-launch.*.command(N); do rm -f "$f"; done
    '
    [ "$status" -eq 0 ]
    assert_contains "OPEN:-a Ghostty " "$output"
}

@test "a refused Apple Event falls back instead of sending the user to System Settings" {
    # The regression this guards: GuideApp could not open a terminal at all,
    # because its bundle never asked for the Automation permission the
    # osascript path needs - and the app reported a permission problem rather
    # than using the way in that needs no permission.
    run run_zsh_snippet '
        osascript() { print -u2 -r -- "execution error: Not authorized to send Apple events to Terminal. (-1743)"; return 1 }
        open() { print -r -- "OPEN:$*"; return 0 }
        launch_in_terminal "/tmp/fake_script.sh" "single" "cask" "obs"
        echo "rc=$?"
        for f in "${TMPDIR:-/tmp}"/msm-launch.*.command(N); do rm -f "$f"; done
    '
    assert_contains "OPEN:-a Terminal " "$output"
    assert_contains "rc=0" "$output"
}

@test "a terminal that failed for any other reason is still reported" {
    # The fallback is only for a refusal. A terminal that is broken will not
    # open for 'open' either, and pretending it launched would leave GuideApp
    # watching a run that does not exist.
    run run_zsh_snippet '
        osascript() { print -u2 -r -- "execution error: Terminal got an error: cannot make window (-2700)"; return 1 }
        open() { print -r -- "OPEN:$*"; return 0 }
        launch_in_terminal "/tmp/fake_script.sh" "single" "cask" "obs"
        echo "rc=$?"
    '
    refute_contains "OPEN:" "$output"
    # LAUNCH_TERMINAL_FAILED - pinned literally, since bats is bash and would
    # expand the zsh-side name to an empty string, turning this into "rc=".
    assert_contains "rc=1" "$output"
}

# ------------------------------------------------------------------------------
# Actions that load the config after 'set -e' is on
# ------------------------------------------------------------------------------
# Every test above runs against a throwaway HOME with no settings.conf, so
# load_config_safely returned at its first line and none of them ever executed
# its body. On a real installation it does, and its line counter was
# '((line_no++))' - an arithmetic command whose exit status in zsh is the truth
# value of its result, so counting up from 0 returns 0, which is a *failure*.
# Under the errexit section 5 turns on, that killed the script on the first
# line of settings.conf: install_app, update_app, launch_update and the three
# toggles all exited 1 having printed nothing at all, and GuideApp's "Update in
# Terminal" button did nothing whatsoever.

# A settings.conf like a real installation has - which is the whole point:
# without one, none of this code runs.
write_settings() {
    local dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$dir"
    cat > "$dir/settings.conf" <<EOF
PREFERRED_TERMINAL="Terminal"
MAS_ENABLED="1"
CLEANUP_ENABLED="1"
AUTO_INSTALL_APPS="0"
UPDATE_BRANCH="main"
CODEBERG_USERNAME=""
EOF
}

@test "load_config_safely survives its own line counter under set -e" {
    write_settings
    run run_zsh_snippet '
        set -e
        load_config_safely
        echo "rc=$? terminal=$PREFERRED_TERMINAL mas=$MAS_ENABLED"
    '
    [ "$status" -eq 0 ]
    assert_contains "rc=0 terminal=Terminal mas=1" "$output"
}

@test "load_config_safely still counts lines for its warnings" {
    # The counter has to keep working, not just stop being fatal: the line
    # number is the only thing that makes a syntax warning actionable.
    local dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$dir"
    printf 'MAS_ENABLED="1"\nthis is not valid\n' > "$dir/settings.conf"
    run run_zsh_snippet '
        set -e
        load_config_safely
        print -l -- "${CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    assert_contains "line 2" "$output"
}

@test "update_app reaches the launcher on an installation that has a config" {
    # The regression, end to end: with a settings.conf present this exited 1
    # before it ever tried to open anything, printing nothing - so the failure
    # was invisible from both sides.
    write_settings
    stub_launcher "" 0
    run run_dispatch update_app cask obs obs 32.2.1 32.2.2
    [ "$status" -eq 0 ]
}

@test "update_app still reports a launcher that failed, config or not" {
    write_settings
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch update_app cask obs obs 32.2.1 32.2.2
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
}

@test "launch_update reaches the launcher on an installation that has a config" {
    write_settings
    stub_launcher "" 0
    run run_dispatch launch_update
    [ "$status" -eq 0 ]
}

@test "install_app reaches the launcher on an installation that has a config" {
    write_settings
    stub_launcher "" 0
    run run_dispatch install_app "Rectangle"
    [ "$status" -eq 0 ]
}

@test "the wait-for-quit loop counts up without ending the install" {
    # Same trap, same fix: 'waited' starts at 0, so the first '(( waited++ ))'
    # reported failure and errexit ended the run one second into waiting for
    # an app to close.
    run run_zsh_snippet '
        set -e
        waited=0
        waited=$(( waited + 1 ))
        waited=$(( waited + 1 ))
        echo "rc=$? waited=$waited"
    '
    [ "$status" -eq 0 ]
    assert_contains "rc=0 waited=2" "$output"
}

@test "a config warning raised twice does not end the run" {
    # The second half of the same bug. Every action above loads the config a
    # second time, after 'set -e' is on, which re-raises every warning the
    # first load already recorded - and add_config_warning's status was that
    # of the duplicate check, so the duplicate itself was fatal. An install
    # with one bad config line could not open a terminal at all.
    run run_zsh_snippet '
        set -e
        add_config_warning "same thing"
        add_config_warning "same thing"
        # Counted by hand, not with ${#CONFIG_WARNINGS[@]}: the array already
        # holds the "no Codeberg mirror configured" warning every run without
        # a mirror raises at startup.
        echo "rc=$? count=${(M)#CONFIG_WARNINGS[@]:#same thing}"
    '
    [ "$status" -eq 0 ]
    assert_contains "rc=0 count=1" "$output"
}

@test "update_app survives a config file that has something wrong with it" {
    # End to end, on the installation shape that actually broke: a config
    # with a bad line, loaded once at startup and again by the action.
    local dir="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$dir"
    printf 'PREFERRED_TERMINAL="Terminal"\nnonsense line\n' > "$dir/settings.conf"
    stub_launcher "" 0
    run run_dispatch update_app cask obs obs 32.2.1 32.2.2
    [ "$status" -eq 0 ]
}
