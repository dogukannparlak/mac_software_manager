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
    assert_matches "${PROGRESS_FORMAT_VERSION:-v1}|*" "$output"
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

@test "progress_write_completion records a clean run as done|complete" {
    run run_zsh_snippet '
        progress_write_completion 0 8
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|done|complete|||" ]
}

@test "progress_write_completion records a run with failed items as failed, not done" {
    # The bug this guards: the full update run wrote done|complete
    # unconditionally, so a run where 5 packages were still outdated
    # afterwards showed a green tick and "Bitti" in the app.
    run run_zsh_snippet '
        progress_write_completion 5 12
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|failed|complete-with-failures||5|12" ]
}

@test "progress_write_completion defaults to a clean completion when called with no counts" {
    run run_zsh_snippet '
        progress_write_completion
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|done|complete|||" ]
}

@test "progress_finalize leaves a completion with failures alone" {
    # The run exits 0 even when individual items failed, so the EXIT trap
    # must not overwrite the failure entry the run just wrote.
    run run_zsh_snippet '
        progress_write_completion 5 12
        progress_finalize 0
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|failed|complete-with-failures||5|12" ]
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

# ------------------------------------------------------------------------------
# Single-item run results (CACHE_FORMAT.md, "Single-item run results")
# ------------------------------------------------------------------------------
# The one machine-readable place a single-item run says how it went. Same
# arrangement as the progress tests above: this file and
# GuideApp/Tests/MacUpdaterGuideTests/ItemRunResultParsingTests.swift assert
# against the identical canonical line, so a writer or reader that drifts from
# the document fails a test on whichever side is now wrong.
#
# The timestamp is the one field a test cannot pin (it is the clock), so it is
# swapped for the document's own before comparing - see canonical_result below.
CANONICAL_RESULT="v1|1755400000|cask|alt-tab|AltTab|fail|still-outdated"

# Replaces the epoch in a real record with the canonical one, so the rest of
# the line can be compared exactly rather than by glob.
canonical_result() {
    printf 'v1|1755400000|%s' "${1#v1|*|}"
}

@test "result_write produces the exact canonical example from CACHE_FORMAT.md" {
    run run_zsh_snippet '
        result_write "cask" "alt-tab" "AltTab" "fail" "still-outdated"
        cat "$RESULTS_DIR"/result.*
    '
    [ "$status" -eq 0 ]
    [ "$(canonical_result "$output")" = "$CANONICAL_RESULT" ]
}

@test "RESULT_FORMAT_VERSION matches the version this suite pins to" {
    # Bumping it means bumping ItemRunResult.formatVersion on the Swift side
    # and CACHE_FORMAT.md in the same change, or the document now describes a
    # format nothing produces.
    run run_zsh_snippet 'echo "$RESULT_FORMAT_VERSION"'
    [ "$status" -eq 0 ]
    [ "$output" = "v1" ]
}

@test "result_write stamps the record with the current time" {
    # The timestamp is what tells this run's record from one an earlier run of
    # the same item left behind - a reader drops anything older than the run
    # asking, so a wrong or missing stamp silently loses every result.
    run run_zsh_snippet '
        now=$EPOCHSECONDS
        result_write "brew" "awscli" "awscli" "ok" ""
        recorded="$(cut -d"|" -f2 "$RESULTS_DIR"/result.*)"
        (( recorded >= now && recorded <= now + 5 )) && echo "in range" || echo "out of range: $recorded vs $now"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "in range" ]
}

@test "result_write leaves the reason empty on a successful run" {
    run run_zsh_snippet '
        result_write "brew" "awscli" "awscli" "ok" ""
        cat "$RESULTS_DIR"/result.*
    '
    [ "$status" -eq 0 ]
    [ "$(canonical_result "$output")" = "v1|1755400000|brew|awscli|awscli|ok|" ]
}

@test "result_write strips pipes and newlines from the free-form fields" {
    # id and name are the only fields sourced from anything free-form, and a
    # stray pipe in either would shift every field after it - the reader
    # counts fields, so the record would be rejected outright.
    run run_zsh_snippet '
        name="$(printf "Two\nLines|Here")"
        result_write "app" "We|ird" "$name" "fail" "download-failed"
        wc -l < "$RESULTS_DIR"/result.*
        cat "$RESULTS_DIR"/result.*
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]// /}" = "1" ]
    [ "$(canonical_result "${lines[1]}")" = "v1|1755400000|app|Weird|Two LinesHere|fail|download-failed" ]
}

@test "result_write leaves no temp file behind for a reader to trip over" {
    # Records are written to "<name>.tmp" and renamed into place so nobody
    # ever reads half a line; readers skip .tmp entries, and a finished write
    # must not leave one lying there for the retention window.
    run run_zsh_snippet '
        result_write "brew" "awscli" "awscli" "ok" ""
        print -l -- "$RESULTS_DIR"/*(N:t)
    '
    [ "$status" -eq 0 ]
    assert_matches 'result.*' "$output"
    refute_matches '*.tmp' "$output"
}

@test "result_write keeps one record per run instead of overwriting the last one" {
    # Several single-item runs can be in flight at once (GuideApp's
    # concurrency setting) - the reason these are files in a directory rather
    # than one shared entry like progress. Two runs reporting must leave two
    # records.
    run run_zsh_snippet '
        result_write "brew" "awscli" "awscli" "ok" ""
        result_write "cask" "alt-tab" "AltTab" "fail" "still-outdated"
        print -l -- "$RESULTS_DIR"/result.*(N) | wc -l
    '
    [ "$status" -eq 0 ]
    [ "${output// /}" = "2" ]
}

@test "result_prune drops records past the retention window and keeps the rest" {
    # Records are meant to be consumed by GuideApp as the run ends; the ones
    # still here long after belong to runs nobody was watching (a terminal
    # window, a SwiftBar click) and would otherwise pile up forever.
    run run_zsh_snippet '
        mkdir -p "$RESULTS_DIR"
        print -r -- "v1|1|brew|old|old|ok|" > "$RESULTS_DIR/result.1.old"
        touch -t 202001010000 "$RESULTS_DIR/result.1.old"
        print -r -- "v1|2|brew|new|new|ok|" > "$RESULTS_DIR/result.1.new"
        result_prune
        print -l -- "$RESULTS_DIR"/result.*(N:t)
    '
    [ "$status" -eq 0 ]
    [ "$output" = "result.1.new" ]
}

@test "result_write survives a results directory it cannot create" {
    # Best-effort by contract: every caller runs under 'set -e', and a run
    # that did update its package must not be turned into a failure because
    # its report could not be filed.
    run run_zsh_snippet '
        rm -rf "$RESULTS_DIR"
        : > "$RESULTS_DIR"   # a file where the directory should be
        result_write "brew" "awscli" "awscli" "ok" ""
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}
