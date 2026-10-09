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
    # Logged like any other update: source, name, versions, status.
    assert_matches "*|npm|typescript|5.4.5|*|typescript|ok|" \
        "$(tail -n 1 "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/update_history.log")"
}

@test "a failed tool update is logged as failed" {
    stub pipx 'exit 3'
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'pipx|black|24.4.2|\n' > "$cache/other_packages"

    run_with_stubs 'run_mode_tool run tool pipx black' < /dev/null
    [ "$status" -eq 3 ]
    assert_matches "*|pipx|black|24.4.2|*|black|fail|command-failed" \
        "$(tail -n 1 "$TEST_HOME/Library/Application Support/MacSoftwareUpdater/update_history.log")"
}

@test "a regular file in Homebrew's bin folder is listed; Homebrew's own links are not" {
    local prefix="$TEST_HOME/brewprefix"
    mkdir -p "$prefix/bin" "$prefix/Cellar/jq/1.7/bin" "$prefix/Homebrew/bin"
    printf '#!/bin/sh\n' > "$prefix/Homebrew/bin/brew"
    printf '#!/bin/sh\n' > "$prefix/Cellar/jq/1.7/bin/jq"
    printf '#!/bin/sh\n' > "$prefix/bin/agy"
    printf '#!/bin/sh\n' > "$prefix/bin/agy.1791553591174963000.old"
    chmod +x "$prefix/Homebrew/bin/brew" "$prefix/Cellar/jq/1.7/bin/jq" "$prefix/bin/agy" "$prefix/bin/agy.1791553591174963000.old"
    ln -s ../Homebrew/bin/brew "$prefix/bin/brew"
    ln -s ../Cellar/jq/1.7/bin/jq "$prefix/bin/jq"

    run run_zsh_snippet "path=('$prefix/bin' \$path); collect_local_tools"
    [ "$status" -eq 0 ]
    assert_contains "local|agy||$prefix/bin/agy" "$output"
    refute_contains "|jq|" "$output"
    refute_contains "|brew|" "$output"
    refute_contains ".old" "$output"
}

@test "OTHER_SOURCES_LIST limits which sources are scanned" {
    stub npm 'echo "/x/node_modules/typescript:typescript@5.4.5"'
    stub pipx 'printf "black 24.4.2\n"'
    run_with_stubs 'OTHER_SOURCES_LIST=pipx; collect_other_packages'
    [ "$status" -eq 0 ]
    assert_contains "pipx|black|24.4.2|" "$output"
    refute_contains "npm|" "$output"
}

@test "an invalid OTHER_SOURCES_LIST is warned about and ignored" {
    local cfg="$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
    mkdir -p "$cfg"
    printf 'OTHER_SOURCES_LIST="npm,brew"\n' > "$cfg/settings.conf"
    run run_zsh_snippet 'print "list=[$OTHER_SOURCES_LIST]"; print -l -- "${CONFIG_WARNINGS[@]}"'
    assert_contains "list=[]" "$output"
    assert_contains "Invalid OTHER_SOURCES_LIST" "$output"
}

# Registry lookups: curl is stubbed to write a body, plutil to answer with the
# version, so this pins the comparison rather than the network.
stub_registry() {
    local latest="$1"
    stub curl 'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { echo "{}" > "$2"; exit 0; }; shift; done; exit 1'
    stub plutil "echo $latest"
}

@test "pipx, uv, cargo and self-updating tools are checked against their registries" {
    stub_registry 25.1.0
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'pipx|black|24.4.2|\nuv|ruff|0.6.0|\ncargo|ripgrep|14.1.0|\nlocal|claude|2.0.14|/x/claude\nlocal|hf||/x/hf\npkg|com.x|1.0|/\n' > "$cache/other_packages"

    run_with_stubs 'OTHER_SOURCES_LIST=pipx,uv,cargo,local; collect_other_outdated'
    [ "$status" -eq 0 ]
    assert_contains "pipx|black|24.4.2|25.1.0" "$output"
    assert_contains "uv|ruff|0.6.0|25.1.0" "$output"
    assert_contains "cargo|ripgrep|14.1.0|25.1.0" "$output"
    assert_contains "local|claude|2.0.14|25.1.0" "$output"
    # No updater known for it, and .pkg receipts are never checked.
    refute_contains "|hf|" "$output"
    refute_contains "pkg|" "$output"
}

@test "a tool already ahead of its registry is not reported as outdated" {
    stub_registry 1.0.0
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'pipx|black|24.4.2|\n' > "$cache/other_packages"
    run_with_stubs 'OTHER_SOURCES_LIST=pipx; collect_other_outdated; print end'
    [ "$status" -eq 0 ]
    [ "$output" = "end" ]
}

@test "run tool updates claude with its own 'update' command, from the scanned file" {
    local fake="$BATS_TEST_TMPDIR/claude-bin"
    printf '#!/bin/sh\necho "claude $*" >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$fake"
    chmod +x "$fake"
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'local|claude|2.0.14|%s\n' "$fake" > "$cache/other_packages"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN"

    run_with_stubs 'run_mode_tool run tool local claude' < /dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/calls")" = "claude update" ]
}

@test "run tool refuses a standalone tool with no known updater" {
    local cache="$TEST_HOME/Library/Application Support/MacSoftwareUpdater/cache"
    mkdir -p "$cache"
    printf 'local|hf||/x/hf\n' > "$cache/other_packages"
    run run_zsh_snippet 'run_mode_tool run tool local hf' < /dev/null
    [ "$status" -eq 1 ]
    assert_contains "cannot be updated from here" "$output"
}
