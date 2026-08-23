load "test_helper"

# escape_ere: literal -> ERE-safe (used to embed cask tokens/app names in a
# `sed -E` pattern without letting regex metacharacters change what matches).
# Regression coverage for a real bug fixed in this repo: an unescaped '.' or
# '+' in a cask token let remove_ignored delete/keep the wrong line.

@test "escape_ere escapes dot and plus" {
    run run_zsh_fn escape_ere 'some.app+beta'
    [ "$status" -eq 0 ]
    [ "$output" = 'some\.app\+beta' ]
}

@test "escape_ere leaves a plain alphanumeric token untouched" {
    run run_zsh_fn escape_ere 'alt-tab'
    [ "$status" -eq 0 ]
    [ "$output" = 'alt-tab' ]
}

@test "escape_ere escapes brackets, parens, braces, pipe, backslash" {
    run run_zsh_fn escape_ere 'a[b](c){d}|e\f'
    [ "$status" -eq 0 ]
    [ "$output" = 'a\[b\]\(c\)\{d\}\|e\\f' ]
}

@test "escape_ere escapes star and caret and dollar" {
    run run_zsh_fn escape_ere 'a*b^c$d'
    [ "$status" -eq 0 ]
    [ "$output" = 'a\*b\^c\$d' ]
}

@test "escape_ere output is usable as a literal sed -E pattern" {
    # End-to-end: build a pattern from the escaped output and confirm it
    # matches only the exact literal string, not a widened/narrowed regex.
    run run_zsh_snippet '
        token="some.app+beta"
        safe=$(escape_ere "$token")
        printf "cask|some.app+beta|Exact\ncask|someXappXbeta|WouldFalseMatchUnescaped\n" \
            | sed -nE "/^cask\|${safe}\|/p"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "cask|some.app+beta|Exact" ]
}

# applescript_escape: backslash-then-quote escaping for AppleScript string
# literals (display dialog / display notification).

@test "applescript_escape escapes a double quote" {
    run run_zsh_fn applescript_escape 'Say "hi"'
    [ "$status" -eq 0 ]
    [ "$output" = 'Say \"hi\"' ]
}

@test "applescript_escape doubles backslashes before escaping quotes" {
    run run_zsh_fn applescript_escape 'C:\path\to"file'
    [ "$status" -eq 0 ]
    [ "$output" = 'C:\\path\\to\"file' ]
}

@test "applescript_escape passes through plain text untouched" {
    run run_zsh_fn applescript_escape 'AltTab'
    [ "$status" -eq 0 ]
    [ "$output" = 'AltTab' ]
}
