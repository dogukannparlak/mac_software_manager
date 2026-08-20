load "test_helper"

# Cross-language format agreement for the `progress` cache file (see
# CACHE_FORMAT.md). This file and
# GuideApp/Tests/MacUpdaterGuideTests/UpdateProgressParsingTests.swift both
# assert against the exact same canonical example line - if a future change
# to the shell writer or the Swift reader ever drifts from CACHE_FORMAT.md,
# whichever side is now wrong fails its own test, regardless of which side
# changed.
CANONICAL_LINE="v1|running|brew-upgrade|awscli|3|8"

@test "progress_write produces the exact canonical example from CACHE_FORMAT.md" {
    run run_zsh_snippet '
        progress_write "running" "brew-upgrade" "awscli" "3" "8"
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$CANONICAL_LINE" ]
}

@test "progress_write prefixes every write with the current format version" {
    run run_zsh_snippet '
        progress_write "done" "complete" "" "" ""
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == "${PROGRESS_FORMAT_VERSION:-v1}|"* ]]
}

@test "PROGRESS_FORMAT_VERSION matches the version this suite pins to" {
    # If the shell side ever bumps its version constant, this - and the
    # Swift side's UpdateProgress.formatVersion - must be bumped in the same
    # change, or this test (and CACHE_FORMAT.md) is now describing a format
    # nothing produces anymore.
    run run_zsh_snippet 'echo "$PROGRESS_FORMAT_VERSION"'
    [ "$status" -eq 0 ]
    [ "$output" = "v1" ]
}

@test "progress_finalize recognises its own versioned output and promotes running to done" {
    run run_zsh_snippet '
        progress_write "running" "brew-upgrade" "awscli" "3" "8"
        progress_finalize
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|done|complete|||" ]
}

@test "progress_finalize records a non-zero exit status as failed, not done" {
    # The bug this guards: every early "exit 1" used to reach progress_finalize
    # and be written out as done|complete - a green tick for a failed run.
    run run_zsh_snippet '
        progress_write "running" "brew-upgrade" "awscli" "3" "8"
        progress_finalize 1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|failed|brew-upgrade|awscli|3|8" ]
}

@test "progress_finalize propagates the exit status a real EXIT trap catches" {
    # zsh only reports the exiting status to a trap that reads $? as its very
    # first command, so this exercises the wiring, not just the function.
    run run_zsh_snippet '
        (
            trap "progress_finalize \$?" EXIT
            progress_write "running" "install-app" "Rectangle" "" ""
            exit 1
        )
        cat "$PROGRESS_FILE"
    '
    [ "$output" = "v1|failed|install-app|Rectangle||" ]
}

@test "progress_finalize does nothing to a state that is already done" {
    run run_zsh_snippet '
        progress_write "done" "complete" "" "" ""
        progress_finalize
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|done|complete|||" ]
}

@test "progress_finalize leaves an unversioned (pre-marker) line alone rather than misreading it" {
    # Regression test for the exact bug this task fixes: before the version
    # marker, an old-format line's first field ("running") was compared
    # directly - a format change could have made this compare against
    # something that happens to also read as "running" incorrectly, or vice
    # versa. Now: no recognised version -> untouched, not "fixed up".
    run run_zsh_snippet '
        print -r -- "running|complete||1|1" > "$PROGRESS_FILE"
        progress_finalize
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "running|complete||1|1" ]
}

@test "progress_finalize leaves a line with an unrecognised future version alone" {
    run run_zsh_snippet '
        print -r -- "v2|running|complete" > "$PROGRESS_FILE"
        progress_finalize
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v2|running|complete" ]
}

@test "progress_finalize is a no-op when the progress file does not exist" {
    run run_zsh_snippet '
        rm -f "$PROGRESS_FILE"
        progress_finalize
        echo "rc=$?"
        [[ -f "$PROGRESS_FILE" ]] && echo "file exists" || echo "no file"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0" ]
    [ "${lines[1]}" = "no file" ]
}
