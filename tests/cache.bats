load "test_helper"

# cache_put / cache_get: atomic write + read round-trip.

@test "cache_put then cache_get round-trips a value" {
    run run_zsh_snippet '
        cache_put "mykey" "hello world"
        cache_get "mykey"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "cache_get fails for a key that was never written" {
    run run_zsh_snippet 'cache_get "nosuchkey"'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "cache_put leaves no leftover temp file behind" {
    # grep -c exits 1 on zero matches (the expected, correct outcome here),
    # so the snippet neutralises that with '|| true' rather than asserting on $status.
    run run_zsh_snippet '
        cache_put "mykey" "v1"
        ls "$CACHE_DIR" | grep -c "^\.mykey\." || true
    '
    [ "$output" = "0" ]
}

# cache_mtime / cache_fresh: TTL logic, using fabricated mtimes so the test
# does not have to wait real wall-clock time.

@test "cache_mtime is 0 for a missing entry" {
    run run_zsh_snippet 'cache_mtime "nosuchkey"'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cache_fresh is false for a missing entry" {
    run run_zsh_snippet 'cache_fresh "nosuchkey" 3600 && echo fresh || echo stale'
    [ "$status" -eq 0 ]
    [ "$output" = "stale" ]
}

@test "cache_fresh is true for an entry just written (within TTL)" {
    run run_zsh_snippet '
        cache_put "mykey" "v1"
        cache_fresh "mykey" 3600 && echo fresh || echo stale
    '
    [ "$status" -eq 0 ]
    [ "$output" = "fresh" ]
}

@test "cache_fresh is false once the entry is older than its TTL" {
    run run_zsh_snippet '
        cache_put "mykey" "v1"
        # Back-date the file well past a 1-second TTL.
        touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$CACHE_DIR/mykey"
        cache_fresh "mykey" 3600 && echo fresh || echo stale
    '
    [ "$status" -eq 0 ]
    [ "$output" = "stale" ]
}

# cache_refresh_entry: keep the previous value (restamped) on failure instead
# of blanking the menu, per the comment on this function.

@test "cache_refresh_entry stores a successful command's output" {
    run run_zsh_snippet '
        cache_refresh_entry "mykey" echo "fresh output"
        cache_get "mykey"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "fresh output" ]
}

@test "cache_refresh_entry keeps the old value when the command fails and an entry already exists" {
    run run_zsh_snippet '
        cache_put "mykey" "old value"
        cache_refresh_entry "mykey" zsh -c "exit 1"
        cache_get "mykey"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "old value" ]
}

@test "cache_refresh_entry restamps the entry even when the command fails" {
    run run_zsh_snippet '
        cache_put "mykey" "old value"
        touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$CACHE_DIR/mykey"
        cache_refresh_entry "mykey" zsh -c "exit 1"
        cache_fresh "mykey" 3600 && echo fresh || echo stale
    '
    [ "$status" -eq 0 ]
    [ "$output" = "fresh" ]
}

@test "cache_refresh_entry writes empty when the command fails and no entry existed yet" {
    run run_zsh_snippet '
        cache_refresh_entry "mykey" zsh -c "exit 1"
        cache_get "mykey"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# cache_stale_tiers: reports each tier by name only when at least one of its
# keys is missing/expired.

@test "cache_stale_tiers reports every tier when the cache is empty" {
    run run_zsh_snippet 'cache_stale_tiers'
    [ "$status" -eq 0 ]
    [[ "$output" == *"updates"* ]]
    [[ "$output" == *"installed"* ]]
    [[ "$output" == *"apps"* ]]
    [[ "$output" == *"websites"* ]]
}

@test "cache_stale_tiers omits a tier whose keys are all fresh" {
    run run_zsh_snippet '
        for key in brew_outdated mas_outdated manual_updates; do
            cache_put "$key" ""
        done
        cache_stale_tiers
    '
    [ "$status" -eq 0 ]
    [[ "$output" != *"updates"* ]]
    [[ "$output" == *"installed"* ]]
}

@test "cache_stale_tiers reports nothing (and exits 0) once every tier is fresh" {
    # Regression-shaped test: the function's last statement is a bare
    # '(( )) && print', which is false (and would look like "failure") once
    # nothing is stale - it must not abort a 'set -e' caller.
    run run_zsh_snippet '
        set -e
        for key in brew_outdated mas_outdated manual_updates brew_pinned brew_casks brew_formulae brew_leaves brew_formulae_desc brew_casks_desc mas_list brew_status app_updates cask_homepages github_homepages; do
            cache_put "$key" ""
        done
        stale="$(cache_stale_tiers)" || true
        echo "[$stale]"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}
