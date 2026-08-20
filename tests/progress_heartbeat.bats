load "test_helper"

# The progress file's *age* is a signal of its own: a live run keeps it
# current (progress_heartbeat_start, lib/cache.sh) so that a "running" entry
# which has stopped aging can be read as a run that died. Both readers depend
# on that - GuideApp's banner (UpdateProgress.staleAfter(for:)) and its
# per-item queue, which parks every row behind a bulk run it believes is still
# going.
#
# The bug these cover: nothing re-stamped the file, so the only thing a reader
# could do was guess from the last phase change. A `mas upgrade` downloading
# for longer than the guess was called failed while it was still working, and
# a run that was killed mid-phase kept the UI (and the queue) waiting for the
# rest of the guess.
#
# Every test here shortens the interval to a second so the timing is visible
# without the suite sleeping through the production value.
setup() {
    TEST_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$TEST_HOME"
    export PROGRESS_HEARTBEAT_INTERVAL=1
}

@test "a running entry is re-stamped while the run is alive" {
    run run_zsh_snippet '
        progress_write "running" "mas-upgrade" "" "" ""
        before=$(stat -f %m "$PROGRESS_FILE")
        sleep 2.2
        after=$(stat -f %m "$PROGRESS_FILE")
        (( after > before )) && echo "re-stamped" || echo "NOT re-stamped"
        cat "$PROGRESS_FILE"
        progress_heartbeat_stop
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "re-stamped" ]
    # Only the modification time moves - the entry itself is untouched, so
    # this can never race with a real progress_write.
    [ "${lines[1]}" = "v1|running|mas-upgrade|||" ]
}

@test "the stamper stops as soon as the run records an ending" {
    # Otherwise the *next* run's watch would see this run's finished entry
    # touched after it started, and read it as its own result.
    run run_zsh_snippet '
        progress_write "running" "mas-upgrade" "" "" ""
        progress_write_completion 0 3
        before=$(stat -f %m "$PROGRESS_FILE")
        sleep 2.2
        after=$(stat -f %m "$PROGRESS_FILE")
        (( after == before )) && echo "left alone" || echo "STILL STAMPED"
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "left alone" ]
    [ "${lines[1]}" = "v1|done|complete|||" ]
}

@test "progress_finalize stops the stamper" {
    run run_zsh_snippet '
        progress_write "running" "brew-upgrade" "awscli" "3" "8"
        progress_finalize 1
        before=$(stat -f %m "$PROGRESS_FILE")
        sleep 2.2
        after=$(stat -f %m "$PROGRESS_FILE")
        (( after == before )) && echo "left alone" || echo "STILL STAMPED"
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "left alone" ]
    [ "${lines[1]}" = "v1|failed|brew-upgrade|awscli|3|8" ]
}

@test "the stamper does not outlive the run it belongs to" {
    # The case no trap of ours can cover: SIGKILL, a panic, a closed terminal
    # window. The stamper's own liveness check is the only thing that ends
    # it - and it has to, or the dead run's "running" entry would stay fresh
    # forever and no reader could ever call it stale.
    HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" zsh -c "
        source '$REPO_SCRIPT'
        progress_write running mas-upgrade '' '' ''
        print -r -- \$PROGRESS_HEARTBEAT_PID > \"\$HOME/hb.pid\"
        sleep 30
    " >/dev/null 2>&1 &
    local run_pid=$!

    sleep 1
    kill -9 "$run_pid"
    local stamper_pid
    stamper_pid=$(cat "$TEST_HOME/hb.pid")
    [ -n "$stamper_pid" ]

    # One interval to notice its owner is gone, plus slack.
    sleep 2.5
    run kill -0 "$stamper_pid"
    [ "$status" -ne 0 ]

    local progress_file="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache/progress"
    local before after
    before=$(stat -f %m "$progress_file")
    sleep 1.5
    after=$(stat -f %m "$progress_file")
    [ "$before" = "$after" ]
}

@test "a headless single-item run starts no stamper" {
    # GUIDEAPP_NO_SHARED_PROGRESS runs do not own the shared file (several of
    # them run at once and none of them writes it), so there is nothing for
    # them to keep fresh either.
    run run_zsh_snippet '
        GUIDEAPP_NO_SHARED_PROGRESS=1 progress_write "running" "single" "awscli" "" ""
        echo "pid=[$PROGRESS_HEARTBEAT_PID]"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "pid=[]" ]
}

@test "starting the stamper does not trip the run's errexit" {
    # progress_write runs from paths with 'set -e' on (the run dispatcher):
    # a guard of the "already stamping?" kind returning non-zero must not
    # take the whole update down with it.
    run run_zsh_snippet '
        set -e
        progress_write "running" "brew-upgrade" "awscli" "1" "8"
        progress_write "done" "complete" "" "" ""
        echo "run survived"
    '
    [ "$status" -eq 0 ]
    assert_contains "run survived" "$output"
}
