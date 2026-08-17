load "test_helper"

# is_supported_terminal / detect_installed_terminals: the single source of
# truth added to replace three independently-drifting terminal name lists
# (one of which, in setup_mac.sh, had silently never detected Ghostty).

@test "is_supported_terminal accepts all five known terminals" {
    for name in Terminal iTerm2 Warp Alacritty Ghostty; do
        run run_zsh_fn is_supported_terminal "$name"
        [ "$status" -eq 0 ]
    done
}

@test "is_supported_terminal rejects an unknown name" {
    run run_zsh_fn is_supported_terminal "Hyper"
    [ "$status" -ne 0 ]
}

@test "is_supported_terminal rejects a case-mismatched name" {
    run run_zsh_fn is_supported_terminal "warp"
    [ "$status" -ne 0 ]
}

@test "detect_installed_terminals always includes Terminal" {
    run run_zsh_fn detect_installed_terminals
    [ "$status" -eq 0 ]
    [[ "$output" == *"Terminal"* ]]
}

@test "detect_installed_terminals only reports terminals with a matching /Applications bundle" {
    # No terminal apps exist under this fake, empty /Applications-less HOME
    # environment beyond what's actually installed on the runner - Terminal
    # is unconditional, nothing else should appear unless truly installed.
    run run_zsh_fn detect_installed_terminals
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "Terminal" ]; then
            continue
        fi
        case "$line" in
            iTerm2) [ -d "/Applications/iTerm.app" ] ;;
            Warp) [ -d "/Applications/Warp.app" ] ;;
            Alacritty) [ -d "/Applications/Alacritty.app" ] ;;
            Ghostty) [ -d "/Applications/Ghostty.app" ] ;;
            *) false ;;
        esac
    done <<< "$output"
}

@test "detect_installed_terminals itself exits 0 even when nothing extra is found" {
    # Regression test: the function used to end on a bare '[[ -d ... ]] &&
    # print', so its own exit status was false whenever the *last* entry in
    # TERMINAL_APP_ORDER (Ghostty) was not installed - the common case. That
    # silently aborted "Change Terminal App" under 'set -e', because zsh (unlike
    # bash) propagates a failing command substitution through errexit.
    run run_zsh_fn detect_installed_terminals
    [ "$status" -eq 0 ]
}

@test "change_terminal's array-building pattern survives under set -e" {
    # The actual production statement from the change_terminal dispatch,
    # exercised with 'set -e' active exactly as it is there.
    run run_zsh_snippet '
        set -e
        typeset -a available_terminals
        available_terminals=("${(@f)$(detect_installed_terminals)}")
        echo "count=${#available_terminals[@]}"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == count=* ]]
}

@test "detect_installed_terminals never reports an unsupported name" {
    run run_zsh_fn detect_installed_terminals
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        run run_zsh_fn is_supported_terminal "$line"
        [ "$status" -eq 0 ]
    done <<< "$output"
}
