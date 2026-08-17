load "test_helper"

# trim_history_log: caps update_history.log at 500 lines by keeping the most
# recent 300. Single function shared by the bulk update, single-package
# update, and self-updating-app-install flows (previously only the bulk flow
# trimmed at all, so the other two grew the log without bound).

@test "trim_history_log does nothing when the file is missing" {
    run run_zsh_snippet 'trim_history_log; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}

@test "trim_history_log leaves a file at or under 500 lines untouched" {
    run run_zsh_snippet '
        seq 1 500 > "$HISTORY_FILE"
        trim_history_log
        wc -l < "$HISTORY_FILE" | tr -d " "
    '
    [ "$status" -eq 0 ]
    [ "$output" = "500" ]
}

@test "trim_history_log's own exit status is 0 even when nothing needed trimming" {
    # Regression-shaped test: this used to be the final statement in the
    # function and its 'success' meant nothing was trimmed - a proper if/fi
    # (unlike a bare '&&') still returns 0 here, but this locks that in.
    run run_zsh_snippet '
        set -e
        seq 1 10 > "$HISTORY_FILE"
        trim_history_log
        echo "reached"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "reached" ]
}

@test "trim_history_log trims a file over 500 lines down to the newest 300" {
    run run_zsh_snippet '
        seq 1 600 > "$HISTORY_FILE"
        trim_history_log
        wc -l < "$HISTORY_FILE" | tr -d " "
    '
    [ "$status" -eq 0 ]
    [ "$output" = "300" ]
}

@test "trim_history_log keeps the most recent lines, not the oldest" {
    run run_zsh_snippet '
        seq 1 600 > "$HISTORY_FILE"
        trim_history_log
        head -1 "$HISTORY_FILE"
        tail -1 "$HISTORY_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "301" ]
    [ "${lines[1]}" = "600" ]
}

@test "trim_history_log is called after a bulk-update-style history write" {
    # Exercises the exact call shape used in the "run all/system" flow.
    run run_zsh_snippet '
        seq 1 600 > "$HISTORY_FILE"
        printf "601|cask|foo|1.0|1.1|foo|ok\n" >> "$HISTORY_FILE"
        trim_history_log
        wc -l < "$HISTORY_FILE" | tr -d " "
    '
    [ "$status" -eq 0 ]
    [ "$output" = "300" ]
}
