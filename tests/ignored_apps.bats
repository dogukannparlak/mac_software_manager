load "test_helper"

# load_ignored_cache / is_ignored / add_ignored / remove_ignored: the ignore
# list round-trip. Exercises the escape_ere fix end-to-end (a '.'/'+' in a
# cask token must not let remove_ignored touch the wrong line) and the
# historical cask/mas ID-sanitising bug documented in the source ("stripping
# everything non-numeric silently dropped every cask entry").

@test "add_ignored then load_ignored_cache makes is_ignored true" {
    run run_zsh_snippet '
        add_ignored "cask" "alt-tab" "AltTab"
        load_ignored_cache
        is_ignored "cask" "alt-tab" && echo "ignored" || echo "not-ignored"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "ignored" ]
}

@test "is_ignored is false before load_ignored_cache is refreshed" {
    # add_ignored only appends to disk; the in-memory map used by is_ignored
    # is not updated until load_ignored_cache runs again.
    run run_zsh_snippet '
        add_ignored "cask" "alt-tab" "AltTab"
        is_ignored "cask" "alt-tab" && echo "ignored" || echo "not-ignored"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "not-ignored" ]
}

@test "add_ignored does not duplicate an entry across two script invocations" {
    # add_ignored only checks the in-memory map, which a real invocation
    # always loads fresh at startup (each menu click is a separate process) -
    # so the realistic duplicate-prevention scenario is add -> reload -> add
    # again, not two adds in the same process with no reload in between.
    run run_zsh_snippet '
        add_ignored "cask" "alt-tab" "AltTab"
        load_ignored_cache
        add_ignored "cask" "alt-tab" "AltTab"
        wc -l < "$IGNORED_FILE" | tr -d " "
    '
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "a cask token with regex metacharacters ignores only itself" {
    # Regression test for the escape_ere fix: 'some.app+beta' as an
    # unescaped ERE would also match 'someXappXbeta'.
    run run_zsh_snippet '
        printf "cask|some.app+beta|Exact\ncask|someXappXbeta|WouldFalseMatch\n" > "$IGNORED_FILE"
        remove_ignored "cask" "some.app+beta"
        cat "$IGNORED_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "cask|someXappXbeta|WouldFalseMatch" ]
}

@test "remove_ignored matches on type|id exactly, not a prefix" {
    run run_zsh_snippet '
        printf "cask|alt-tab|AltTab\ncask|alt-tab-pro|AltTabPro\n" > "$IGNORED_FILE"
        remove_ignored "cask" "alt-tab"
        cat "$IGNORED_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "cask|alt-tab-pro|AltTabPro" ]
}

@test "load_ignored_cache keeps a non-numeric cask token (not stripped to empty)" {
    # Historical bug: sanitising every ID as if it were a numeric App Store ID
    # dropped every cask entry, so Ignore silently never took effect for casks.
    run run_zsh_snippet '
        printf "cask|cursor|Cursor\n" > "$IGNORED_FILE"
        load_ignored_cache
        is_ignored "cask" "cursor" && echo "ignored" || echo "not-ignored"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "ignored" ]
}

@test "load_ignored_cache keeps a numeric mas id" {
    run run_zsh_snippet '
        printf "mas|361285480|Keynote\n" > "$IGNORED_FILE"
        load_ignored_cache
        is_ignored "mas" "361285480" && echo "ignored" || echo "not-ignored"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "ignored" ]
}

@test "load_ignored_cache skips a malformed line (missing id)" {
    run run_zsh_snippet '
        printf "cask|\nmas|123|App\n" > "$IGNORED_FILE"
        load_ignored_cache
        is_ignored "mas" "123" && echo "second-line-ok" || echo "second-line-missing"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "second-line-ok" ]
}
