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
    [[ "$output" == rc=*" elapsed_ok=yes" ]]
    [[ "$output" != "rc=0"* ]]
}

@test "run_with_timeout does not kill a command that finishes in time" {
    run run_zsh_snippet 'run_with_timeout 5 zsh -c "sleep 0.2; exit 0"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}
