load "test_helper"

# Where the engine finds its library when nobody tells it (MSU_LIB_DIR unset),
# and which engines are allowed to replace their own files.
#
# Both come from the same change: GuideApp runs the engine out of its own
# bundle and points MSU_LIB_DIR at the bundled library, but a run launched in
# the user's terminal starts in a fresh shell without that variable - and the
# self-update/channel switch used to write into that bundle.

RESOURCES="$REPO_ROOT/GuideApp/Sources/MacUpdaterGuide/EngineResources"

support_dir() {
    echo "$TEST_HOME/Library/Application Support/MacSoftwareUpdater"
}

# An engine laid out the way setup_mac.sh installs it: the script and lib/
# under the support folder.
install_engine() {
    local app_dir
    app_dir="$(support_dir)"
    mkdir -p "$app_dir/lib"
    cp "$REPO_SCRIPT" "$app_dir/update_system.1h.sh"
    cp "$REPO_LIB_DIR"/*.sh "$app_dir/lib/"
}

# Sources <script> with MSU_LIB_DIR removed from the environment, then runs
# <snippet>.
run_unpinned() {
    local script="$1" snippet="$2"
    env -u MSU_LIB_DIR HOME="$TEST_HOME" PATH="${STUB_BIN:+$STUB_BIN:}$PATH" \
        zsh -c "source '$script'; $snippet"
}

@test "without MSU_LIB_DIR the bundled engine loads the library beside it" {
    run run_unpinned "$RESOURCES/update_system.1h.sh" 'print -r -- "lib=$LIB_DIR"'
    [ "$status" -eq 0 ]
    refute_contains "Missing engine file" "$output"
    assert_contains "lib=$RESOURCES/lib" "$output"
}

@test "without MSU_LIB_DIR a flattened bundle (Xcode) loads the library from its own folder" {
    local flat="$BATS_TEST_TMPDIR/Resources"
    mkdir -p "$flat"
    cp "$REPO_SCRIPT" "$REPO_LIB_DIR"/*.sh "$flat/"

    run run_unpinned "$flat/update_system.1h.sh" 'print -r -- "lib=$LIB_DIR"'
    [ "$status" -eq 0 ]
    assert_contains "lib=$flat" "$output"
}

@test "an explicit MSU_LIB_DIR still wins" {
    run run_zsh_snippet 'print -r -- "lib=$LIB_DIR"'
    [ "$status" -eq 0 ]
    assert_contains "lib=$REPO_LIB_DIR" "$output"
}

@test "only an engine installed in the support folder may update itself" {
    install_engine
    run run_unpinned "$(support_dir)/update_system.1h.sh" \
        'engine_is_self_updatable && print installed=yes || print installed=no'
    assert_contains "installed=yes" "$output"

    run run_unpinned "$RESOURCES/update_system.1h.sh" \
        'engine_is_self_updatable && print bundled=yes || print bundled=no'
    assert_contains "bundled=no" "$output"
}

@test "'run plugin' on the bundled engine leaves the bundle alone and clears the flag" {
    mkdir -p "$(support_dir)"
    touch "$(support_dir)/.plugin_update_pending"
    local copy="$BATS_TEST_TMPDIR/bundle"
    cp -R "$RESOURCES" "$copy"
    local before
    before="$(cksum < "$copy/update_system.1h.sh")"

    run env -u MSU_LIB_DIR HOME="$TEST_HOME" zsh "$copy/update_system.1h.sh" run plugin < /dev/null
    [ "$status" -eq 0 ]
    assert_contains "updated with the app" "$output"
    [ "$(cksum < "$copy/update_system.1h.sh")" = "$before" ]
    [ ! -f "$(support_dir)/.plugin_update_pending" ]
    [ ! -d "$(support_dir)/lib" ]
}

@test "a 304 keeps an update that was found earlier and not yet installed" {
    install_engine
    touch "$(support_dir)/.plugin_update_pending"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\nprintf 304\n' > "$STUB_BIN/curl"
    chmod +x "$STUB_BIN/curl"

    run run_unpinned "$(support_dir)/update_system.1h.sh" \
        'notify() { print -r -- "notify: $1"; }; check_for_updates_manual'
    [ "$status" -eq 0 ]
    assert_contains "still waiting" "$output"
    [ -f "$(support_dir)/.plugin_update_pending" ]
}

# osascript is stubbed to save the script it was handed, so the AppleScript
# that would have run can be inspected.
stub_osascript_capture() {
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/osascript" <<EOF
#!/bin/sh
cat > "$BATS_TEST_TMPDIR/applescript"
exit 0
EOF
    chmod +x "$STUB_BIN/osascript"
}

@test "a double quote in an app name cannot end the AppleScript string" {
    stub_osascript_capture
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        launch_in_terminal /fake/script install "Evil\" & (do shell script \"x\") & \"" live
        print "rc=$?"
    '
    assert_contains "rc=0" "$output"
    local sent
    sent="$(cat "$BATS_TEST_TMPDIR/applescript")"
    # Every quote from the name arrives escaped; none of them closes the literal.
    assert_contains 'Evil\"' "$sent"
    refute_contains 'Evil" &' "$sent"
}

@test "the terminal command carries the library location with it" {
    stub_osascript_capture
    PATH="$STUB_BIN:$PATH" run run_zsh_snippet '
        launch_in_terminal /fake/script all
    '
    [ "$status" -eq 0 ]
    assert_contains "/usr/bin/env MSU_LIB_DIR='$REPO_LIB_DIR'" "$(cat "$BATS_TEST_TMPDIR/applescript")"
}
