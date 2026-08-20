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
    [ "${lines[0]}" = "v1|failed|terminal-permission|Terminal||" ]
}

@test "an ordinary launch failure records launch-failed in the progress file" {
    stub_launcher "execution error: Terminal got an error. (-600)" 1
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        notify() { :; }
        launch_in_terminal_or_report /fake/script all >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "v1|failed|launch-failed|Terminal||" ]
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
    [ "${lines[0]}" = "v1|running|brew-upgrade|awscli|3|8" ]
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
    [ "${lines[0]}" = "v1|failed|terminal-permission|Terminal||" ]
}

# The regression itself, at the level the caller sees it: GuideApp decides
# whether to start watching for a run from this exit status alone.
@test "install_app exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch install_app Rectangle live
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||" ]
}

@test "update_app exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch update_app brew awscli awscli 1.0 2.0
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||" ]
}

@test "launch_update exits non-zero when no terminal opened" {
    stub_launcher "execution error: Not authorized to send Apple events to Terminal. (-1743)" 1
    run run_dispatch launch_update all
    [ "$status" -ne 0 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
    [ "$(progress_entry)" = "v1|failed|terminal-permission|Terminal||" ]
}
