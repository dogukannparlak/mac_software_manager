load "test_helper"

# run_with_timeout: dependency-free timeout wrapper (macOS ships neither GNU
# coreutils' 'timeout' nor 'gtimeout'). Backs every 'mas' invocation, which has
# no built-in timeout of its own.

@test "run_with_timeout returns the wrapped command's normal exit status" {
    run run_zsh_snippet 'run_with_timeout 5 zsh -c "exit 0"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}

@test "run_with_timeout propagates a non-zero exit status" {
    run run_zsh_snippet 'run_with_timeout 5 zsh -c "exit 7"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=7" ]
}

@test "run_with_timeout captures stdout through a pipe" {
    run run_zsh_snippet 'run_with_timeout 5 printf "line1\nline2\n"'
    [ "$status" -eq 0 ]
    [ "$output" = $'line1\nline2' ]
}

@test "run_with_timeout captures stdout via command substitution" {
    run run_zsh_snippet 'out=$(run_with_timeout 5 echo "hello"); echo "[$out]"'
    [ "$status" -eq 0 ]
    [ "$output" = "[hello]" ]
}

@test "run_with_timeout kills a command that outruns the limit" {
    run run_zsh_snippet '
        start=$SECONDS
        run_with_timeout 1 sleep 30
        rc=$?
        elapsed=$((SECONDS - start))
        echo "rc=$rc elapsed_ok=$([[ $elapsed -le 5 ]] && echo yes || echo no)"
    '
    [ "$status" -eq 0 ]
    assert_matches 'rc=* elapsed_ok=yes' "$output"
    refute_matches 'rc=0*' "$output"
}

@test "run_with_timeout does not kill a command that finishes in time" {
    run run_zsh_snippet 'run_with_timeout 5 zsh -c "sleep 0.2; exit 0"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}

@test "run_with_timeout reports the timeout with \$TIMEOUT_EXIT_STATUS" {
    run run_zsh_snippet 'run_with_timeout 1 sleep 30; echo "rc=$? expected=$TIMEOUT_EXIT_STATUS"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=124 expected=124" ]
}

@test "run_with_timeout keeps a real command failure distinguishable from a timeout" {
    run run_zsh_snippet 'run_with_timeout 5 zsh -c "exit 1"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
}

@test "run_with_timeout treats a limit of 0 as no timeout" {
    run run_zsh_snippet '
        start=$SECONDS
        run_with_timeout 0 zsh -c "sleep 1.5; exit 3"
        rc=$?
        echo "rc=$rc slept=$([[ $((SECONDS - start)) -ge 1 ]] && echo yes || echo no)"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=3 slept=yes" ]
}

# The whole point of splitting the two limits: a download must not be held to
# the metadata-query limit.
@test "the mas upgrade limit is meaningfully longer than the query limit" {
    run run_zsh_snippet 'echo "$MAS_QUERY_TIMEOUT $MAS_UPGRADE_TIMEOUT"'
    [ "$status" -eq 0 ]
    query="${output%% *}"
    upgrade="${output##* }"
    [ "$query" -eq 30 ]
    [ "$upgrade" -gt "$((query * 10))" ]
}

# The watcher used to leave its 'sleep' holding the captured stdout open, so
# output=$(run_with_timeout 30 <external command>) - how every cache entry is
# filled - always took the full 30 seconds, however fast the command was.
@test "run_with_timeout returns as soon as a captured external command finishes" {
    run run_zsh_snippet '
        start=$EPOCHREALTIME
        out=$(run_with_timeout 20 /bin/echo fast)
        print "out=$out elapsed=$(( EPOCHREALTIME - start ))"
    '
    [ "$status" -eq 0 ]
    assert_contains "out=fast" "$output"
    elapsed="${output##*elapsed=}"
    [ "${elapsed%%.*}" -lt 5 ]
}
