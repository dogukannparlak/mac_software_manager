load "test_helper"

# Everything outside Homebrew and the App Store (lib/updaters.sh, 3c2): each
# package manager is replaced by a stub that prints what the real one prints,
# so these pin the parsing, the opt-out and the update gate without touching
# anything installed.

stub() {
    local tool="$1" body="$2"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\n%s\n' "$body" > "$STUB_BIN/$tool"
    chmod +x "$STUB_BIN/$tool"
}

# The engine puts Homebrew's bin folder first on PATH when it loads, which
# would put a real npm ahead of the stub - so the stubs go first again after.
run_with_stubs() {
    run run_zsh_snippet "path=('$STUB_BIN' \$path); $1"
}

@test "npm: global packages are read from 'npm ls --parseable --long'" {
    stub npm 'cat <<EOF
/opt/homebrew/lib:lib@
/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code:@anthropic-ai/claude-code@2.0.14
/opt/homebrew/lib/node_modules/npm:npm@10.9.0:undefined
EOF
exit 1'
    run_with_stubs 'collect_npm_packages'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "npm|@anthropic-ai/claude-code|2.0.14|" ]
    [ "${lines[1]}" = "npm|npm|10.9.0|" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "pipx, uv and cargo listings are parsed" {
    stub pipx 'printf "black 24.4.2\nhttpie 3.2.2\n"'
    stub uv 'printf "ruff v0.6.0\n- ruff\nwarning: something\n"'
    stub cargo 'printf "ripgrep v14.1.0:\n    rg\nfoo v0.1.0 (https://github.com/x/foo):\n    foo\n"'
    run_with_stubs 'collect_pipx_packages; collect_uv_tools; collect_cargo_packages'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "pipx|black|24.4.2|" ]
    [ "${lines[1]}" = "pipx|httpie|3.2.2|" ]
    [ "${lines[2]}" = "uv|ruff|0.6.0|" ]
    [ "${lines[3]}" = "cargo|ripgrep|14.1.0|" ]
    [ "${lines[4]}" = "cargo|foo|0.1.0|" ]
}

@test "standalone tools: version from the path, app shims attributed to the app" {
    local bin="$TEST_HOME/.local/bin"
    mkdir -p "$bin" "$TEST_HOME/.local/share/claude/versions/2.0.14" "$TEST_HOME/Fake.app/Contents/Resources"
    printf '#!/bin/sh\n' > "$TEST_HOME/.local/share/claude/versions/2.0.14/claude"
    printf '#!/bin/sh\n' > "$TEST_HOME/Fake.app/Contents/Resources/agy"
    chmod +x "$TEST_HOME/.local/share/claude/versions/2.0.14/claude" "$TEST_HOME/Fake.app/Contents/Resources/agy"
    ln -s "$TEST_HOME/.local/share/claude/versions/2.0.14/claude" "$bin/claude"
    ln -s "$TEST_HOME/Fake.app/Contents/Resources/agy" "$bin/agy"
    # A pipx-managed link is pipx's to report, not this scan's.
    mkdir -p "$TEST_HOME/.local/pipx/venvs/black/bin"
    printf '#!/bin/sh\n' > "$TEST_HOME/.local/pipx/venvs/black/bin/black"
    chmod +x "$TEST_HOME/.local/pipx/venvs/black/bin/black"
    ln -s "$TEST_HOME/.local/pipx/venvs/black/bin/black" "$bin/black"

    run run_zsh_snippet 'collect_local_tools'
    [ "$status" -eq 0 ]
    assert_contains "local|claude|2.0.14|$TEST_HOME/.local/share/claude/versions/2.0.14/claude" "$output"
    assert_contains "app|agy||$TEST_HOME/Fake.app" "$output"
    refute_contains "|black|" "$output"
}

@test "npm outdated lists current and latest" {
    stub npm 'echo "/opt/homebrew/lib/node_modules/typescript:typescript@5.6.3:typescript@5.4.5:typescript@5.6.3:global"; exit 1'
    run_with_stubs 'collect_other_outdated'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "npm|typescript|5.4.5|5.6.3" ]
}

@test "OTHER_SOURCES_ENABLED=0 turns every other source off" {
    stub npm 'echo "/x/node_modules/npm:npm@10.9.0"'
    run_with_stubs 'OTHER_SOURCES_ENABLED=0; collect_other_packages; collect_other_outdated; print end'
    [ "$status" -eq 0 ]
    [ "$output" = "end" ]
}

@test "the config key is accepted, and a bad value is warned about" {
    local cfg="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$cfg"
    printf 'OTHER_SOURCES_ENABLED="0"\n' > "$cfg/settings.conf"
    run run_zsh_snippet 'print "v=$OTHER_SOURCES_ENABLED"; print -l -- "${CONFIG_WARNINGS[@]}"'
    assert_contains "v=0" "$output"
    refute_contains "Unknown config key" "$output"

    printf 'OTHER_SOURCES_ENABLED="yes"\n' > "$cfg/settings.conf"
    run run_zsh_snippet 'print -l -- "${CONFIG_WARNINGS[@]}"'
    assert_contains "Invalid OTHER_SOURCES_ENABLED" "$output"
}

@test "run tool refuses a package the last scan did not find" {
    stub npm 'echo "npm ran" >&2; exit 0'
    run env HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" PATH="$STUB_BIN:$PATH" \
        zsh "$REPO_SCRIPT" run tool npm left-pad < /dev/null
    [ "$status" -eq 1 ]
    assert_contains "not in the last scan" "$output"
    refute_contains "npm ran" "$output"
}

@test "run tool refuses sources with no update command" {
    run env HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" \
        zsh "$REPO_SCRIPT" run tool pkg com.example.driver < /dev/null
    [ "$status" -eq 1 ]
    assert_contains "cannot be updated from here" "$output"
}

@test "run tool updates a scanned npm package with npm install -g name@latest" {
    stub npm 'echo "npm $*" >> "'"$BATS_TEST_TMPDIR"'/npm_calls"; exit 0'
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'npm|typescript|5.4.5|\n' > "$cache/other_packages"

    run_with_stubs 'run_mode_tool run tool npm typescript' < /dev/null
    [ "$status" -eq 0 ]
    assert_contains "npm install -g typescript@latest" "$(cat "$BATS_TEST_TMPDIR/npm_calls")"
}

@test "a regular file in Homebrew's bin folder is listed; Homebrew's own links are not" {
    local prefix="$TEST_HOME/brewprefix"
    mkdir -p "$prefix/bin" "$prefix/Cellar/jq/1.7/bin" "$prefix/Homebrew/bin"
    printf '#!/bin/sh\n' > "$prefix/Homebrew/bin/brew"
    printf '#!/bin/sh\n' > "$prefix/Cellar/jq/1.7/bin/jq"
    printf '#!/bin/sh\n' > "$prefix/bin/agy"
    chmod +x "$prefix/Homebrew/bin/brew" "$prefix/Cellar/jq/1.7/bin/jq" "$prefix/bin/agy"
    ln -s ../Homebrew/bin/brew "$prefix/bin/brew"
    ln -s ../Cellar/jq/1.7/bin/jq "$prefix/bin/jq"

    run run_zsh_snippet "path=('$prefix/bin' \$path); collect_local_tools"
    [ "$status" -eq 0 ]
    assert_contains "local|agy||$prefix/bin/agy" "$output"
    refute_contains "|jq|" "$output"
    refute_contains "|brew|" "$output"
}
