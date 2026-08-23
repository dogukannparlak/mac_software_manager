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
    assert_contains "updates" "$output"
    assert_contains "installed" "$output"
    assert_contains "apps" "$output"
    assert_contains "websites" "$output"
}

@test "cache_stale_tiers omits a tier whose keys are all fresh" {
    run run_zsh_snippet '
        for key in brew_outdated mas_outdated manual_updates; do
            cache_put "$key" ""
        done
        cache_stale_tiers
    '
    [ "$status" -eq 0 ]
    refute_contains "updates" "$output"
    assert_contains "installed" "$output"
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

# The 'set -e' contract. Every caller of these two runs with errexit on
# (update_system.1h.sh section 5), and zsh propagates a function's non-zero
# return into the caller - so a cache entry that cannot be refreshed used to
# abort the entire script mid-run.

@test "cache_refresh_entry keeping the old value does not abort a 'set -e' caller" {
    run run_zsh_snippet '
        set -e
        set -o pipefail
        cache_put "mykey" "old value"
        cache_refresh_entry "mykey" zsh -c "exit 1"
        echo "SURVIVED"
    '
    assert_contains "SURVIVED" "$output"
    [ "$status" -eq 0 ]
}

@test "collect_cache_data keeps refreshing the remaining entries after one fails" {
    # cache_refresh_entry is stubbed out so no brew/mas/network call happens:
    # the only question here is what collect_cache_data does when one entry
    # reports failure - it must carry on to the rest of the tier, because the
    # caller writes its final progress line only after this returns
    # (lib/run_modes.sh, run_mode_single).
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cache_refresh_entry() {
            print -r -- "$1" >> "$CACHE_DIR/.calls"
            [[ "$1" == "brew_outdated" ]] && return 1
            cache_put "$1" "stub"
        }

        set -e
        set -o pipefail
        collect_cache_data "updates"
        echo "SURVIVED rc=$?"
        echo "CALLS: $(tr "\n" " " < "$CACHE_DIR/.calls")"
        echo "MANUAL: $(cache_get manual_updates)"

        # local_options must not leak errexit-off back out to the caller.
        false
        echo "LEAKED"
    '
    # The failing entry is reached, the one after it still runs and lands.
    assert_contains "brew_outdated" "$output"
    assert_contains "manual_updates" "$output"
    assert_contains "MANUAL: stub" "$output"
    assert_contains "SURVIVED rc=0" "$output"
    refute_contains "LEAKED" "$output"
    [ "$status" -eq 1 ]
}

@test "collect_cache_data runs 'mas outdated' under the query timeout" {
    # 'mas' has no timeout of its own and talks to a backend that can hang
    # (see run_with_timeout, lib/utils.sh). Every other mas call site in the
    # project wraps its query; this one did not, and a hang here hung the
    # whole refresh - including the headless single-item runs GuideApp
    # spawns, which then showed a spinner nothing could stop.
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR/bin"
        printf "#!/bin/sh\nexit 0\n" > "$CACHE_DIR/bin/mas"
        chmod +x "$CACHE_DIR/bin/mas"
        PATH="$CACHE_DIR/bin:$PATH"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=7

        cache_refresh_entry() {
            print -r -- "ENTRY: $*"
            cache_put "$1" ""
        }

        collect_cache_data "updates"
    '
    assert_contains "ENTRY: mas_outdated run_with_timeout 7 mas outdated" "$output"
}

@test "collect_cache_data runs 'mas list' under the query timeout" {
    # The installed tier's own unguarded 'mas' call - same hang, same fix as
    # the 'mas outdated' one above.
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR/bin"
        printf "#!/bin/sh\nexit 0\n" > "$CACHE_DIR/bin/mas"
        chmod +x "$CACHE_DIR/bin/mas"
        PATH="$CACHE_DIR/bin:$PATH"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=7

        cache_refresh_entry() {
            print -r -- "ENTRY: $*"
            cache_put "$1" ""
        }

        collect_cache_data "installed"
    '
    assert_contains "ENTRY: mas_list run_with_timeout 7 mas list" "$output"
}

# collect_cache_for_item: the post-update refresh a single-item run does.
#
# It used to be collect_cache_data "all", which re-fetched the whole cache -
# including the websites tier, whose 24h TTL exists precisely because those
# entries do not change - while GuideApp's row sat on "Güncelleniyor" waiting
# for the process to exit (ToolkitRunner.finishActiveItem).

@test "collect_cache_for_item refreshes only the brew entries a formula can change" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cache_refresh_entry() {
            print -r -- "ENTRY: $*"
            cache_put "$1" "stub"
        }

        collect_cache_for_item "brew" "jq"
    '
    assert_contains "ENTRY: brew_outdated brew_outdated_normalized" "$output"
    assert_contains "ENTRY: brew_formulae brew list --formula --versions" "$output"
    # The cask list cannot have changed, and the expensive tiers are left to
    # their own TTLs: no descriptions, no app scan, no homepage lookups.
    refute_contains "brew_casks" "$output"
    refute_contains "_desc" "$output"
    refute_contains "app_updates" "$output"
    refute_contains "homepages" "$output"
}

@test "collect_cache_for_item refreshes the cask list, not the formula list, for a cask" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cache_refresh_entry() {
            print -r -- "ENTRY: $*"
            cache_put "$1" "stub"
        }

        collect_cache_for_item "cask" "firefox"
    '
    assert_contains "ENTRY: brew_outdated brew_outdated_normalized" "$output"
    assert_contains "ENTRY: brew_casks brew list --cask --versions" "$output"
    refute_contains "brew_formulae" "$output"
    refute_contains "homepages" "$output"
}

@test "collect_cache_for_item refreshes 'mas outdated' under the query timeout" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR/bin"
        printf "#!/bin/sh\nexit 0\n" > "$CACHE_DIR/bin/mas"
        chmod +x "$CACHE_DIR/bin/mas"
        PATH="$CACHE_DIR/bin:$PATH"
        MAS_ENABLED=1
        MAS_QUERY_TIMEOUT=7

        cache_refresh_entry() {
            print -r -- "ENTRY: $*"
            cache_put "$1" ""
        }

        collect_cache_for_item "mas" "497799835"
    '
    assert_contains "ENTRY: mas_outdated run_with_timeout 7 mas outdated" "$output"
    # Nothing here touches Homebrew, and an App Store app is not a ghost app
    # unless manual_updates says so - no iTunes Lookup round trips.
    refute_contains "brew_" "$output"
    refute_contains "manual_updates" "$output"
}

@test "collect_cache_for_item rebuilds manual_updates for a ghost app" {
    # Apple titles 'mas outdated' never reports are pending because
    # manual_updates says so, and GuideApp sends them through as type "mas"
    # like any other App Store row (ToolkitRunner.updateSingle). Leaving that
    # entry stale keeps the row on the pending list, which finishActiveItem
    # reads back as a failed update.
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        MAS_ENABLED=1
        cache_put "manual_updates" "Xcode|14.2|15.0|497799835"

        cache_refresh_entry() {
            print -r -- "ENTRY: $1"
            cache_put "$1" ""
        }

        collect_cache_for_item "mas" "497799835"
    '
    assert_contains "ENTRY: manual_updates" "$output"
}

@test "collect_cache_for_item survives a failing entry and leaks no errexit" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cache_refresh_entry() {
            [[ "$1" == "brew_outdated" ]] && return 1
            cache_put "$1" "stub"
        }

        set -e
        set -o pipefail
        collect_cache_for_item "brew" "jq"
        echo "SURVIVED rc=$?"
        echo "FORMULAE: $(cache_get brew_formulae)"

        false
        echo "LEAKED"
    '
    # The entry after the failing one still runs, and the caller keeps its
    # errexit - it needs both to reach its own final progress line.
    assert_contains "SURVIVED rc=0" "$output"
    assert_contains "FORMULAE: stub" "$output"
    refute_contains "LEAKED" "$output"
    [ "$status" -eq 1 ]
}

@test "collect_cache_for_item holds the cache lock while it writes, and releases it after" {
    # Two single-item runs can be in flight at once (GuideApp's
    # maxConcurrentUpdates, default 2). Without the lock, the second one can
    # compute brew_outdated while the first one's upgrade is still running
    # and write that stale list over the fresh entry - after which the first
    # run re-reads it and reports its own success as a failure.
    #
    # flock is advisory per-process, so "another run" has to be a real
    # subprocess trying for the same lock file.
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        other_run_can_lock() {
            [[ -f "$LOCK_DIR/cache.lock" ]] || { print -r -- "NOLOCKFILE"; return }
            zsh -c "zmodload zsh/system && zsystem flock -t 0 \"$LOCK_DIR/cache.lock\" && echo FREE || echo BUSY" 2>/dev/null
        }

        cache_refresh_entry() {
            [[ "$1" == "brew_outdated" ]] && print -r -- "DURING: $(other_run_can_lock)"
            cache_put "$1" "stub"
        }

        collect_cache_for_item "brew" "jq"
        print -r -- "AFTER: $(other_run_can_lock)"
    '
    assert_contains "DURING: BUSY" "$output"
    assert_contains "AFTER: FREE" "$output"
}

@test "collect_cache_for_item refreshes anyway when the cache lock never frees up" {
    # A lock nobody releases must not pin the row on "Güncelleniyor" forever:
    # the wait is bounded by CACHE_LOCK_WAIT, and refreshing without the lock
    # beats announcing "done" over a cache that still lists this item.
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR" "$LOCK_DIR"
        CACHE_LOCK_WAIT=1
        cache_refresh_entry() { cache_put "$1" "stub" }

        # A subprocess that takes the lock and sits on it past the wait.
        : > "$LOCK_DIR/cache.lock"
        zsh -c "zmodload zsh/system && zsystem flock \"$LOCK_DIR/cache.lock\" && sleep 10" &
        holder=$!
        # Give it a moment to actually hold the lock before we try.
        while zsh -c "zmodload zsh/system && zsystem flock -t 0 \"$LOCK_DIR/cache.lock\"" 2>/dev/null; do
            sleep 0.1
        done

        started=$EPOCHSECONDS
        collect_cache_for_item "brew" "jq"
        print -r -- "OUTDATED: $(cache_get brew_outdated)"
        print -r -- "WAITED: $(( EPOCHSECONDS - started ))"
        kill $holder 2>/dev/null
    '
    # It gave up on the lock and wrote anyway, without waiting out the
    # holder's full 10 seconds.
    assert_contains "OUTDATED: stub" "$output"
    [ "${output##*WAITED: }" -lt 5 ]
}

# --- Cask download progress ---
#
# Real byte progress for a cask's download, watched from outside Homebrew
# rather than parsed from its (tty-only) progress bar. brew and curl are both
# stubbed - this suite must never make a real network call - so what is
# actually under test is the file-size polling and the HEAD-derived total,
# not Homebrew or the network.

@test "cask_download_watch_start reports bytes against a HEAD-derived total" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cache_path="$BATS_TEST_TMPDIR/fake-cask.dmg"

        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "%s" "{\"casks\":[{\"url\":\"https://example.invalid/fake.dmg\"}]}"
            elif [[ "$1" == "--cache" ]]; then
                print -r -- "$cache_path"
            fi
        }
        curl() { print -r -- "content-length: 1000"; }

        printf "%0.sX" {1..250} > "${cache_path}.incomplete"

        cask_download_watch_start "fake-token" "FakeApp"
        sleep 1.3
        cat "$(cask_download_progress_file $$)"
        echo "---"
        cask_download_watch_stop
        [[ -f "$(cask_download_progress_file $$)" ]] && echo "file remains" || echo "file cleaned up"
    '
    [ "$status" -eq 0 ]
    assert_matches "250|1000*" "$output"
    assert_contains "file cleaned up" "$output"
}

@test "cask_download_watch_start writes nothing when the cask has no resolvable url" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "%s" "{\"casks\":[{}]}"
            fi
        }

        cask_download_watch_start "no-url-token" "FakeApp"
        sleep 1.3
        [[ -f "$(cask_download_progress_file $$)" ]] && echo "wrote a file" || echo "wrote nothing"
        cask_download_watch_stop
    '
    [ "$status" -eq 0 ]
    assert_contains "wrote nothing" "$output"
}

@test "cask_download_watch_stop cleans up even when nothing was ever written" {
    run run_zsh_snippet '
        mkdir -p "$CACHE_DIR"
        cask_download_watch_stop
        echo "survived"
        [[ -n "$CASK_DOWNLOAD_WATCH_PID" ]] && echo "pid left set" || echo "pid cleared"
    '
    [ "$status" -eq 0 ]
    assert_contains "survived" "$output"
    assert_contains "pid cleared" "$output"
}
