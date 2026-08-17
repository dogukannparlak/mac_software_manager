load "test_helper"

# load_config_safely: strict KEY="value" parsing of settings.conf, with
# CONFIG_WARNINGS collecting anything invalid instead of failing outright.
#
# Sourcing the script always adds one baseline warning of its own ("no
# Codeberg mirror configured", since these tests never set CODEBERG_USERNAME)
# before any test-specific config is even loaded - every snippet below resets
# CONFIG_WARNINGS=() right before the load_config_safely call under test, so
# each test measures only what that call itself produced.

@test "load_config_safely accepts a valid PREFERRED_TERMINAL line" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "PREFERRED_TERMINAL=\"Warp\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "$PREFERRED_TERMINAL"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "Warp" ]
}

@test "load_config_safely rejects an unsupported terminal name and warns" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "PREFERRED_TERMINAL=\"Hyper\"\n" > "$CONFIG_FILE"
        PREFERRED_TERMINAL="Terminal"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "term=$PREFERRED_TERMINAL warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "term=Terminal warnings=1" ]
}

@test "load_config_safely accepts a valid CODEBERG_USERNAME" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "CODEBERG_USERNAME=\"my-user\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "$CODEBERG_USERNAME"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "my-user" ]
}

@test "load_config_safely treats the literal placeholder as unset, no warning" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "CODEBERG_USERNAME=\"YOUR_CODEBERG_USERNAME\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "user=[$CODEBERG_USERNAME] warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "user=[] warnings=0" ]
}

@test "load_config_safely rejects a CODEBERG_USERNAME with invalid characters" {
    # Unlike PREFERRED_TERMINAL (falls back to whatever was already set),
    # an invalid CODEBERG_USERNAME is deliberately cleared to empty (mirror
    # disabled) rather than kept - a stale/wrong value would otherwise point
    # self-update's dual-source check at a broken URL.
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "CODEBERG_USERNAME=\"not a user!\"\n" > "$CONFIG_FILE"
        CODEBERG_USERNAME="unchanged"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "user=[$CODEBERG_USERNAME] warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "user=[] warnings=1" ]
}

@test "load_config_safely warns once per malformed syntax line, does not abort the rest of the file" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "this is not valid\nMAS_ENABLED=\"0\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "mas=$MAS_ENABLED warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "mas=0 warnings=1" ]
}

@test "load_config_safely warns on an unknown key but keeps parsing" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "SOME_FUTURE_KEY=\"x\"\nCLEANUP_ENABLED=\"0\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "cleanup=$CLEANUP_ENABLED warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "cleanup=0 warnings=1" ]
}

@test "load_config_safely ignores comments and blank lines" {
    run run_zsh_snippet '
        mkdir -p "$(dirname "$CONFIG_FILE")"
        printf "# a comment\n\nMAS_ENABLED=\"0\"\n" > "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "mas=$MAS_ENABLED warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "mas=0 warnings=0" ]
}

@test "load_config_safely is a no-op when the config file does not exist" {
    run run_zsh_snippet '
        rm -f "$CONFIG_FILE"
        CONFIG_WARNINGS=()
        load_config_safely
        echo "warnings=${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "warnings=0" ]
}

@test "add_config_warning does not add the exact same warning twice" {
    run run_zsh_snippet '
        CONFIG_WARNINGS=()
        add_config_warning "dup"
        add_config_warning "dup"
        echo "${#CONFIG_WARNINGS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "sourcing the script with no Codeberg mirror configured adds exactly one warning" {
    run run_zsh_snippet 'echo "${#CONFIG_WARNINGS[@]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run run_zsh_snippet 'echo "${CONFIG_WARNINGS[1]}"'
    [[ "$output" == *"Codeberg"* ]]
}
