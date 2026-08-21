load "test_helper"

# Homebrew migration: finding apps a cask could manage, and deciding what
# handing one over would actually do (lib/migrate.sh, CACHE_FORMAT.md ->
# "migration_candidates").
#
# Same arrangement as tests/cache_format.bats: the canonical example line below
# is the one CACHE_FORMAT.md documents, and the Swift reader's test suite will
# assert against the identical string once that reader exists - so a writer or
# a reader drifting from the document fails a test on whichever side is now
# wrong.
#
# NOTHING here calls the real Homebrew. Every test that needs cask metadata
# either builds the JSON by hand and calls the decision functions directly, or
# stubs `brew` with a shell function. That is not only for speed: the states
# being asserted are properties of specific cask metadata, and a real cask is
# free to change its `auto_updates` flag or its version tomorrow.
CANONICAL_LINE="v1|AltTab|/Applications/AltTab.app|com.lwouis.alt-tab-macos|11.5.0|alt-tab|11.5.0|artifact|adoptable|https://alt-tab.app/"

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Writes a cask JSON document to $BATS_TEST_TMPDIR/cask.json.
# Takes the body of the single cask object, so each test states only what it is
# actually about.
write_cask_json() {
    mkdir -p "$BATS_TEST_TMPDIR"
    printf '{"casks":[%s]}' "$1" > "$BATS_TEST_TMPDIR/cask.json"
}

# Creates a real .app bundle with a readable Info.plist, because plist_value
# goes through `defaults read` and cannot be given a fake.
# Usage: write_app_bundle <path> <short_version> <build_version> [bundle_id]
write_app_bundle() {
    local app_path="$1" short="$2" build="$3" bundle_id="${4:-com.example.app}"
    mkdir -p "$app_path/Contents"
    cat > "$app_path/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleShortVersionString</key><string>${short}</string>
    <key>CFBundleVersion</key><string>${build}</string>
</dict>
</plist>
EOF
}

# A cask body with an app artifact targeting the given path.
# Usage: cask_body <token> <app_file> <target> <auto_updates> <short> <build>
cask_body() {
    printf '{"token":"%s","version":"1.0","homepage":"https://example.com/",' "$1"
    printf '"artifacts":[{"app":["%s"],"target":"%s"}],' "$2" "$3"
    printf '"auto_updates":%s,"deprecated":false,"disabled":false,' "$4"
    if [[ -n "$5" ]]; then
        printf '"bundle_short_version":"%s","bundle_version":"%s"}' "$5" "$6"
    else
        printf '"bundle_short_version":null,"bundle_version":null}'
    fi
}

# ------------------------------------------------------------------------------
# Format version and canonical line
# ------------------------------------------------------------------------------

@test "MIGRATION_FORMAT_VERSION matches the version this suite pins to" {
    # If the shell side bumps its version constant, this - and the Swift
    # reader's own constant once it exists - must be bumped in the same change,
    # or CACHE_FORMAT.md is describing a format nothing produces anymore.
    run run_zsh_snippet 'echo "$MIGRATION_FORMAT_VERSION"'
    [ "$status" -eq 0 ]
    [ "$output" = "v1" ]
}

@test "the canonical example from CACHE_FORMAT.md has exactly ten fields" {
    # The field count is the reader's fail-closed check, so it is part of the
    # contract rather than an incidental property of the example.
    run bash -c 'awk -F"|" "{print NF}" <<< "'"$CANONICAL_LINE"'"'
    [ "$output" = "10" ]
}

@test "the canonical example starts with the format version the engine writes" {
    run run_zsh_snippet 'echo "$MIGRATION_FORMAT_VERSION"'
    assert_matches "${output}|*" "$CANONICAL_LINE"
}

@test "migration_scan writes the exact canonical example from CACHE_FORMAT.md" {
    # The whole scan, end to end, with `brew` stubbed and the app list pointed
    # at a fixture bundle. AltTab is the app the document uses, so this is the
    # documented line produced by the real writer - not a hand-built string.
    #
    # The fixture bundle lives in the test's tmpdir but the line has to name
    # /Applications, since that is where the real one is: migration_app_paths
    # answers with the real path and the plist is read through a stubbed
    # plist_value, which is the only field that needs the bundle on disk.
    run run_zsh_snippet '
        brew() {
            [[ "$1 $2" == "info --cask" && "$4" == "alt-tab" ]] || return 1
            printf "%s" "{\"casks\":[{\"token\":\"alt-tab\",\"version\":\"11.5.0\",\"homepage\":\"https://alt-tab.app/\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"uninstall\":[{\"quit\":\"com.lwouis.alt-tab-macos\"}]},{\"app\":[\"AltTab.app\"],\"target\":\"/Applications/AltTab.app\"}]}]}"
        }
        migration_app_paths() { print -r -- "/Applications/AltTab.app"; }
        plist_value() {
            case "$2" in
                CFBundleIdentifier)          print -r -- "com.lwouis.alt-tab-macos" ;;
                CFBundleShortVersionString)  print -r -- "11.5.0" ;;
                CFBundleVersion)             print -r -- "11.5.0" ;;
            esac
        }
        migration_scan
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$CANONICAL_LINE" ]
}

@test "migration_scan skips an app Homebrew already manages" {
    run run_zsh_snippet '
        print -r -- "alt-tab 11.5.0" > "$CACHE_DIR/brew_casks"
        brew() { return 1; }
        migration_app_paths() { print -r -- "/Applications/AltTab.app"; }
        plist_value() { print -r -- "com.lwouis.alt-tab-macos"; }
        migration_scan
        echo "END"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "END" ]
}

@test "migration_scan skips Apple's own apps, App Store apps and Setapp" {
    # Three different reasons, one outcome: none of them has a cask to move to,
    # and installing one over an App Store app loses the receipt that makes its
    # updates work.
    run run_zsh_snippet '
        mkdir -p "$BATS_TEST_TMPDIR/MAS.app/Contents/_MASReceipt"
        brew() { return 1; }
        migration_app_paths() {
            print -rl -- "/Applications/Safari.app" \
                         "$BATS_TEST_TMPDIR/MAS.app" \
                         "/Applications/Setapp/Something.app"
        }
        plist_value() { print -r -- "com.apple.Safari"; }
        migration_scan
        echo "END"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "END" ]
}

@test "migration_scan skips an app the user has ignored" {
    run run_zsh_snippet '
        add_ignored "sparkle" "AltTab" "AltTab"
        load_ignored_cache
        brew() { return 1; }
        migration_app_paths() { print -r -- "/Applications/AltTab.app"; }
        plist_value() { print -r -- "com.lwouis.alt-tab-macos"; }
        migration_scan
        echo "END"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "END" ]
}

@test "migration_scan strips a pipe out of an app name instead of shifting the record" {
    # Ten fields, always - the reader counts them and rejects anything else.
    run run_zsh_snippet '
        brew() {
            [[ "$1 $2" == "info --cask" ]] || return 1
            printf "{\"casks\":[{\"token\":\"%s\",\"version\":\"1.0\",\"homepage\":\"https://exa|mple.com/\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Weird.app\"],\"target\":\"/Applications/We|ird.app\"}]}]}" "$4"
        }
        migration_app_paths() { print -r -- "/Applications/We|ird.app"; }
        plist_value() { print -r -- "com.example.weird"; }
        migration_scan | awk -F"|" "{print NF}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

# ------------------------------------------------------------------------------
# Field cleaning
# ------------------------------------------------------------------------------

@test "migration_clean_field strips pipes so a name cannot shift the fields after it" {
    # Ten fields, always. A stray pipe in an app name or a homepage pushes
    # every field after it along by one, and a reader counting fields rejects
    # the whole record - the same rule result_write applies.
    run run_zsh_snippet 'migration_clean_field "We|ird|Name"'
    [ "$status" -eq 0 ]
    [ "$output" = "WeirdName" ]
}

@test "migration_clean_field folds newlines so one candidate stays one line" {
    run run_zsh_snippet '
        value="$(printf "Two\nLines")"
        migration_clean_field "$value"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "Two Lines" ]
}

@test "migration_clean_field leaves an ordinary path untouched" {
    run run_zsh_snippet 'migration_clean_field "/Applications/AltTab.app"'
    [ "$status" -eq 0 ]
    [ "$output" = "/Applications/AltTab.app" ]
}

@test "migration_clean_field handles a value that both contains a pipe and spans lines" {
    run run_zsh_snippet '
        value="$(printf "A|B\nC|D")"
        migration_clean_field "$value"
        echo "lines=$(migration_clean_field "$value" | wc -l | tr -d " ")"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "AB CD" ]
    [ "${lines[1]}" = "lines=1" ]
}

# ------------------------------------------------------------------------------
# JSON reading
# ------------------------------------------------------------------------------

@test "migration_json_values reads a one-or-many field written as a bare string" {
    # Cask JSON writes `quit` as a string for one bundle id and as an array for
    # several. Asking plutil for the raw value of an array returns the element
    # COUNT, which would read as a perfectly plausible bundle id - so the two
    # shapes have to be told apart, not guessed at.
    write_cask_json '{"token":"x","artifacts":[{"uninstall":[{"quit":"com.example.one"}]}]}'
    run run_zsh_snippet '
        migration_json_values "'"$BATS_TEST_TMPDIR"'/cask.json" "casks.0.artifacts.0.uninstall.0.quit"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "com.example.one" ]
}

@test "migration_json_values reads the same field written as an array" {
    write_cask_json '{"token":"x","artifacts":[{"uninstall":[{"quit":["com.a","com.b"]}]}]}'
    run run_zsh_snippet '
        migration_json_values "'"$BATS_TEST_TMPDIR"'/cask.json" "casks.0.artifacts.0.uninstall.0.quit"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "com.a" ]
    [ "${lines[1]}" = "com.b" ]
}

@test "migration_json_values says nothing for a key that is not there" {
    write_cask_json '{"token":"x","artifacts":[{"app":["X.app"]}]}'
    run run_zsh_snippet '
        migration_json_values "'"$BATS_TEST_TMPDIR"'/cask.json" "casks.0.artifacts.0.uninstall.0.quit"
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}

@test "migration_cask_app_target falls back to /Applications when the cask states no target" {
    write_cask_json '{"token":"x","artifacts":[{"app":["Thing.app"]}]}'
    run run_zsh_snippet '
        migration_cask_app_target "'"$BATS_TEST_TMPDIR"'/cask.json"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "Thing.app|/Applications/Thing.app" ]
}

# ------------------------------------------------------------------------------
# Match evidence (CACHE_FORMAT.md, the `match` field)
# ------------------------------------------------------------------------------

@test "match is artifact when the cask installs a bundle with this exact file name" {
    write_cask_json '{"token":"alt-tab","artifacts":[{"app":["AltTab.app"],"target":"/Applications/AltTab.app"}]}'
    run run_zsh_snippet '
        migration_match_evidence "'"$BATS_TEST_TMPDIR"'/cask.json" "/Applications/AltTab.app" "com.lwouis.alt-tab-macos"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "artifact" ]
}

@test "match is bundle when the cask names this exact CFBundleIdentifier" {
    # The app file name does not match here - the cask ships "Renamed.app" -
    # but the bundle id it quits is the installed app's, which is evidence
    # about the application rather than about its name.
    write_cask_json '{"token":"x","artifacts":[{"uninstall":[{"quit":"com.lwouis.alt-tab-macos"}]},{"app":["Renamed.app"],"target":"/Applications/Renamed.app"}]}'
    run run_zsh_snippet '
        migration_match_evidence "'"$BATS_TEST_TMPDIR"'/cask.json" "/Applications/AltTab.app" "com.lwouis.alt-tab-macos"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "bundle" ]
}

@test "match is bundle when the id appears in the cask's launchctl list" {
    write_cask_json '{"token":"x","artifacts":[{"uninstall":[{"launchctl":["com.example.helper","com.example.app"]}]},{"app":["Other.app"],"target":"/Applications/Other.app"}]}'
    run run_zsh_snippet '
        migration_match_evidence "'"$BATS_TEST_TMPDIR"'/cask.json" "/Applications/Thing.app" "com.example.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "bundle" ]
}

@test "match is token when nothing but the name-derived guess lines up" {
    # The weakest match, and the one the UI has to mark unverified: the token
    # resolved to *a* cask and that is genuinely all that is known.
    write_cask_json '{"token":"clearvpn","artifacts":[{"uninstall":[{"quit":"com.macpaw.clearvpn"}]},{"app":["ClearVPN.app"],"target":"/Applications/ClearVPN.app"}]}'
    run run_zsh_snippet '
        migration_match_evidence "'"$BATS_TEST_TMPDIR"'/cask.json" "/Applications/ClearDisk.app" "com.macpaw.cleardisk"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "token" ]
}

@test "match does not fall back to bundle when the app has no bundle id at all" {
    # An unreadable Info.plist leaves bundle_id empty, and an empty string must
    # not be allowed to "match" a cask that also lists nothing.
    write_cask_json '{"token":"x","artifacts":[{"uninstall":[{"quit":""}]},{"app":["Other.app"],"target":"/Applications/Other.app"}]}'
    run run_zsh_snippet '
        migration_match_evidence "'"$BATS_TEST_TMPDIR"'/cask.json" "/Applications/Thing.app" ""
    '
    [ "$status" -eq 0 ]
    [ "$output" = "token" ]
}

# ------------------------------------------------------------------------------
# State (CACHE_FORMAT.md, the `state` field)
# ------------------------------------------------------------------------------
# Every one of these is decided from JSON plus Info.plist, with no command run.

@test "state is adoptable when the cask sets auto_updates" {
    # Homebrew's own rule (moved.rb:95-135): with auto_updates the bundle
    # versions are not compared at all, so a version that is nowhere near the
    # cask's is still adoptable.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json "$(cask_body thing Thing.app "$BATS_TEST_TMPDIR/Thing.app" true 9.9.9 999)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "adoptable" ]
}

@test "state is adoptable when both bundle versions match the installed plist exactly" {
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "2.4.1" "2410"
    write_cask_json "$(cask_body thing Thing.app "$BATS_TEST_TMPDIR/Thing.app" false 2.4.1 2410)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "adoptable" ]
}

@test "state is version-mismatch when the short version matches but the build does not" {
    # Homebrew compares BOTH. A build-only difference is the case a naive
    # "compare the version strings" check would wave through, and adopt would
    # then refuse at the worst possible moment.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "2.4.1" "2410"
    write_cask_json "$(cask_body thing Thing.app "$BATS_TEST_TMPDIR/Thing.app" false 2.4.1 2411)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "version-mismatch" ]
}

@test "state is version-mismatch when the short versions differ" {
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "2.4.0" "2410"
    write_cask_json "$(cask_body thing Thing.app "$BATS_TEST_TMPDIR/Thing.app" false 2.4.1 2410)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "version-mismatch" ]
}

@test "state is version-mismatch when the cask records no bundle versions to compare" {
    # Homebrew then falls back to a recursive diff of the two directories,
    # whose outcome cannot be predicted from metadata. "Adopt may well refuse"
    # is the honest answer, and being wrong about it costs nothing - a refused
    # adopt leaves the target untouched.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "2.4.1" "2410"
    write_cask_json "$(cask_body thing Thing.app "$BATS_TEST_TMPDIR/Thing.app" false "" "")"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "version-mismatch" ]
}

@test "state is no-app-artifact for a pkg or installer cask" {
    # logitech-g-hub's shape: an uninstall stanza and an installer script, and
    # no app artifact anywhere. There is no bundle for Homebrew to adopt and
    # none for a replace to put back.
    write_app_bundle "$BATS_TEST_TMPDIR/lghub.app" "1.0" "100"
    write_cask_json '{"token":"logitech-g-hub","version":"2023.3","deprecated":false,"disabled":false,"auto_updates":true,
"artifacts":[{"uninstall":[{"quit":["com.logi.ghub"],"delete":"/Applications/lghub.app"}]},
{"installer":[{"script":{"executable":"lghub_installer.app/Contents/MacOS/lghub_installer","args":["--silent"],"sudo":true}}]}]}'
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/lghub.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "no-app-artifact" ]
}

@test "state is needs-root when an installer script declares sudo" {
    # Same sudo installer as above, but this cask does ship an app artifact -
    # so the blocker is the password prompt, not the missing bundle.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json '{"token":"thing","version":"1.0","deprecated":false,"disabled":false,"auto_updates":true,
"artifacts":[{"app":["Thing.app"],"target":"'"$BATS_TEST_TMPDIR"'/Thing.app"},
{"installer":[{"script":{"executable":"setup","sudo":true}}]}]}'
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "needs-root" ]
}

@test "state is needs-root when the cask targets /Library" {
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json "$(cask_body thing Thing.app /Library/Thing.app true 1.0 100)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "needs-root" ]
}

@test "state is needs-root but NOT for a target under the user's own ~/Library" {
    # /Library needs root; ~/Library is the user's own and does not. A prefix
    # test that missed the distinction would refuse a perfectly fine migration.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    run run_zsh_snippet '
        target="$HOME/Library/Thing.app"
        printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"1.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"%s\"}]}]}" "$target" > "$BATS_TEST_TMPDIR/cask.json"
        migration_state "$BATS_TEST_TMPDIR/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    # Not needs-root; it is somewhere other than where the app is, so:
    [ "$output" = "target-mismatch" ]
}

@test "state is target-mismatch for the ~/Applications trap" {
    # The app is in ~/Applications and the cask installs to /Applications.
    # Adopting does not MOVE a bundle: it would install a second copy in
    # /Applications and leave the original exactly where it was.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json "$(cask_body thing Thing.app /Applications/Thing.app true 1.0 100)"
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "target-mismatch" ]
}

@test "state is deprecated when the cask is deprecated" {
    # Outranks everything below it: a deprecated cask is on its way out, and a
    # disabled one cannot be installed at all.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json '{"token":"thing","version":"1.0","deprecated":true,"disabled":false,"auto_updates":true,
"artifacts":[{"app":["Thing.app"],"target":"'"$BATS_TEST_TMPDIR"'/Thing.app"}]}'
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "deprecated" ]
}

@test "state is deprecated when the cask is disabled" {
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    write_cask_json '{"token":"thing","version":"1.0","deprecated":false,"disabled":true,"auto_updates":true,
"artifacts":[{"app":["Thing.app"],"target":"'"$BATS_TEST_TMPDIR"'/Thing.app"}]}'
    run run_zsh_snippet '
        migration_state "'"$BATS_TEST_TMPDIR"'/cask.json" "'"$BATS_TEST_TMPDIR"'/Thing.app"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "deprecated" ]
}

# ------------------------------------------------------------------------------
# Token candidates
# ------------------------------------------------------------------------------

@test "migration_token_candidates splits camelCase the way Homebrew writes tokens" {
    # "alttab" is not a cask; "alt-tab" is. Without the split, the app is never
    # matched at all.
    run run_zsh_snippet 'migration_token_candidates "AltTab"'
    [ "$status" -eq 0 ]
    assert_contains "alt-tab" "$output"
}

@test "migration_token_candidates offers a dot-less variant" {
    run run_zsh_snippet 'migration_token_candidates "draw.io"'
    [ "$status" -eq 0 ]
    assert_contains "drawio" "$output"
}

@test "migration_token_candidates does not truncate progressively" {
    # setup_mac.sh's copy does, because a user confirms its result in front of
    # it. This one does not: every extra variant is another chance to resolve
    # some unrelated cask and then offer it as a migration target.
    run run_zsh_snippet 'migration_token_candidates "Synology Drive Client"'
    [ "$status" -eq 0 ]
    [ "$output" = "synology-drive-client" ]
}

@test "a hand-written token override wins outright over any derived guess" {
    run run_zsh_snippet '
        print -r -- "LGHub|logitech-g-hub" > "$TOKEN_MAP_FILE"
        migration_token_override "lghub"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "logitech-g-hub" ]
}

@test "the token map ignores comments and blank lines" {
    run run_zsh_snippet '
        {
            print -r -- "# a comment|not-a-token"
            print -r -- ""
            print -r -- "Thing|thing-cask"
        } > "$TOKEN_MAP_FILE"
        migration_token_override "Thing"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "thing-cask" ]
}

# ------------------------------------------------------------------------------
# The cask lookup never trusts a fuzzy search
# ------------------------------------------------------------------------------

@test "migration_cask_fetch rejects a response for a different cask than the one asked about" {
    # The ClearDisk -> clearvpn case, made concrete. `brew search` is fuzzy and
    # is allowed to answer with something adjacent; this asks `brew info` for
    # an exact token and refuses anything that comes back naming another cask.
    run run_zsh_snippet '
        brew() { printf "{\"casks\":[{\"token\":\"clearvpn\"}]}"; }
        migration_cask_fetch "cleardisk" "$BATS_TEST_TMPDIR/out.json"
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
}

@test "migration_cask_fetch accepts a response naming the exact token asked about" {
    run run_zsh_snippet '
        brew() { printf "{\"casks\":[{\"token\":\"alt-tab\",\"version\":\"11.5.0\"}]}"; }
        migration_cask_fetch "alt-tab" "$BATS_TEST_TMPDIR/out.json"
        echo "rc=$?"
        migration_json_field "$BATS_TEST_TMPDIR/out.json" "casks.0.version"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0" ]
    [ "${lines[1]}" = "11.5.0" ]
}

@test "migration_cask_fetch treats an empty answer as no such cask" {
    run run_zsh_snippet '
        brew() { return 1; }
        migration_cask_fetch "no-such-cask" "$BATS_TEST_TMPDIR/out.json"
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
}

# ------------------------------------------------------------------------------
# Candidate selection
# ------------------------------------------------------------------------------

@test "a later candidate with real evidence beats an earlier one that merely resolved" {
    # Both tokens exist. The first one derived from the name resolves to a cask
    # that has nothing to do with this app; the camelCase split resolves to the
    # one that actually installs its bundle. Stopping at the first hit would
    # pick the wrong cask.
    run run_zsh_snippet '
        brew() {
            case "$4" in
                "alttab")  printf "{\"casks\":[{\"token\":\"alttab\",\"artifacts\":[{\"app\":[\"Unrelated.app\"],\"target\":\"/Applications/Unrelated.app\"}]}]}" ;;
                "alt-tab") printf "{\"casks\":[{\"token\":\"alt-tab\",\"artifacts\":[{\"app\":[\"AltTab.app\"],\"target\":\"/Applications/AltTab.app\"}]}]}" ;;
                *) return 1 ;;
            esac
        }
        migration_candidate_for_app "AltTab" "/Applications/AltTab.app" "com.lwouis.alt-tab-macos"
    '
    [ "$status" -eq 0 ]
    assert_matches "alt-tab|artifact|*" "$output"
}

@test "a token-only hit is still reported when nothing stronger turns up" {
    run run_zsh_snippet '
        brew() {
            [[ "$4" == "thing" ]] || return 1
            printf "{\"casks\":[{\"token\":\"thing\",\"artifacts\":[{\"app\":[\"Different.app\"],\"target\":\"/Applications/Different.app\"}]}]}"
        }
        migration_candidate_for_app "Thing" "/Applications/Thing.app" "com.example.thing"
    '
    [ "$status" -eq 0 ]
    assert_matches "thing|token|*" "$output"
}

@test "an override is reported as override, not re-derived into weaker evidence" {
    # The user stated the answer. Even though nothing about the cask's app file
    # name or bundle ids lines up, the match is not downgraded to "token".
    run run_zsh_snippet '
        print -r -- "LGHub|logitech-g-hub" > "$TOKEN_MAP_FILE"
        brew() {
            [[ "$4" == "logitech-g-hub" ]] || return 1
            printf "{\"casks\":[{\"token\":\"logitech-g-hub\",\"artifacts\":[{\"app\":[\"lghub.app\"],\"target\":\"/Applications/lghub.app\"}]}]}"
        }
        migration_candidate_for_app "LGHub" "/Applications/LGHub.app" "com.logi.ghub"
    '
    [ "$status" -eq 0 ]
    assert_matches "logitech-g-hub|override|*" "$output"
}

@test "an app whose candidates resolve to nothing is reported as no candidate at all" {
    run run_zsh_snippet '
        brew() { return 1; }
        migration_candidate_for_app "Nothing Like This" "/Applications/Nothing Like This.app" "com.example.nothing"
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
}

@test "candidate selection leaves no temp JSON behind for the tokens it rejected" {
    # One mktemp per candidate token, and only the winner's file is handed to
    # the caller. A scan over a machineful of apps would otherwise fill TMPDIR.
    run run_zsh_snippet '
        export TMPDIR="$BATS_TEST_TMPDIR/tmp"
        mkdir -p "$TMPDIR"
        brew() {
            case "$4" in
                "alttab")  printf "{\"casks\":[{\"token\":\"alttab\",\"artifacts\":[{\"app\":[\"Unrelated.app\"]}]}]}" ;;
                "alt-tab") printf "{\"casks\":[{\"token\":\"alt-tab\",\"artifacts\":[{\"app\":[\"AltTab.app\"],\"target\":\"/Applications/AltTab.app\"}]}]}" ;;
                *) return 1 ;;
            esac
        }
        candidate=$(migration_candidate_for_app "AltTab" "/Applications/AltTab.app" "com.lwouis.alt-tab-macos")
        rm -f "${${(@s:|:)candidate}[3]}"
        leftovers=("$TMPDIR"/msu_cask.*(N))
        echo "${#leftovers}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ------------------------------------------------------------------------------
# Migrating: the states that refuse before anything runs
# ------------------------------------------------------------------------------
# These assert that no brew install command is reached at all - the stub counts
# every invocation, so a refusal that still shelled out would fail here.

@test "migrate_to_cask refuses a pkg cask with no-app-artifact and installs nothing" {
    run run_zsh_snippet '
        : > "'"$BATS_TEST_TMPDIR"'/calls"
        brew() {
            print -r -- "$@" >> "'"$BATS_TEST_TMPDIR"'/calls"
            [[ "$1 $2" == "info --cask" ]] || return 1
            printf "{\"casks\":[{\"token\":\"logitech-g-hub\",\"version\":\"1.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"installer\":[{\"script\":{\"executable\":\"x\",\"sudo\":true}}]}]}]}"
        }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/LGHub.app"; }
        migrate_to_cask "LGHub" "logitech-g-hub" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
        grep -c "^install" "'"$BATS_TEST_TMPDIR"'/calls" || true
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "no-app-artifact" ]
    [ "${lines[2]}" = "0" ]
}

@test "migrate_to_cask refuses a needs-root cask rather than reaching a sudo prompt" {
    # A headless run has nothing to type a password into, so this must fail
    # before Homebrew ever asks - see the header of lib/migrate.sh.
    run run_zsh_snippet '
        mkdir -p "$BATS_TEST_TMPDIR/Thing.app/Contents"
        brew() {
            print -r -- "$@" >> "'"$BATS_TEST_TMPDIR"'/calls"
            [[ "$1 $2" == "info --cask" ]] || return 1
            printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"1.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"/Library/Thing.app\"}]}]}"
        }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        : > "'"$BATS_TEST_TMPDIR"'/calls"
        migrate_to_cask "Thing" "thing" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
        grep -c "^install" "'"$BATS_TEST_TMPDIR"'/calls" || true
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "needs-root" ]
    [ "${lines[2]}" = "0" ]
}

@test "migrate_to_cask refuses target-mismatch instead of installing a second copy" {
    run run_zsh_snippet '
        mkdir -p "$BATS_TEST_TMPDIR/Thing.app/Contents"
        brew() {
            print -r -- "$@" >> "'"$BATS_TEST_TMPDIR"'/calls"
            [[ "$1 $2" == "info --cask" ]] || return 1
            printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"1.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"/Applications/Thing.app\"}]}]}"
        }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        : > "'"$BATS_TEST_TMPDIR"'/calls"
        migrate_to_cask "Thing" "thing" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
        grep -c "^install" "'"$BATS_TEST_TMPDIR"'/calls" || true
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "target-mismatch" ]
    [ "${lines[2]}" = "0" ]
}

@test "migrate_to_cask reports cask-not-found for a token no cask answers to" {
    run run_zsh_snippet '
        mkdir -p "$BATS_TEST_TMPDIR/Thing.app/Contents"
        brew() { return 1; }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        migrate_to_cask "Thing" "no-such-cask" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "cask-not-found" ]
}

@test "migrate_to_cask rejects a mode it does not know rather than picking one" {
    run run_zsh_snippet '
        migrate_to_cask "Thing" "thing" "yolo"
        echo "rc=$?"
    '
    assert_contains "rc=1" "$output"
}

# ------------------------------------------------------------------------------
# Migrating: reporting
# ------------------------------------------------------------------------------

@test "a successful adopt files a migrate result and a history entry" {
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    run run_zsh_snippet '
        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"2.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"'"$BATS_TEST_TMPDIR"'/Thing.app\"}]}]}"
                return 0
            fi
            return 0
        }
        app_running() { return 1; }
        quit_running_app() { return 0; }
        collect_cache_for_item() { return 0; }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        migrate_to_cask "Thing" "thing" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f3,4,5,6 "$RESULTS_DIR"/result.*
        cut -d"|" -f2,3,6,7 "$HISTORY_FILE"
    '
    [ "${lines[0]}" = "rc=0" ]
    [ "${lines[1]}" = "migrate|thing|Thing|ok" ]
    [ "${lines[2]}" = "migrate|Thing|thing|ok" ]
}

@test "a refused adopt on a version-mismatch says so instead of a bare install-failed" {
    # The difference between "we ran out of patience" and "the App Store said
    # no", applied here: "adopt refused because the copies differ" is
    # actionable (a replace would work), "install failed" is not.
    write_app_bundle "$BATS_TEST_TMPDIR/Thing.app" "1.0" "100"
    run run_zsh_snippet '
        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"2.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":false,\"bundle_short_version\":\"2.0\",\"bundle_version\":\"200\",\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"'"$BATS_TEST_TMPDIR"'/Thing.app\"}]}]}"
                return 0
            fi
            return 1
        }
        app_running() { return 1; }
        quit_running_app() { return 0; }
        collect_cache_for_item() { return 0; }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        migrate_to_cask "Thing" "thing" "adopt" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "adopt-version-mismatch" ]
}

@test "a dry run touches nothing and writes no history entry" {
    # The log is a log of changes, and a dry run made none. It DOES file a
    # result record, unlike run_mode_install's dry path: there, GuideApp fires
    # the run with no row attached, while here the dry run IS the answer the
    # user asked for and something has to carry it back.
    run run_zsh_snippet '
        mkdir -p "$BATS_TEST_TMPDIR/Thing.app/Contents"
        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"2.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"'"$BATS_TEST_TMPDIR"'/Thing.app\"}]}]}"
                return 0
            fi
            print -r -- "$@" >> "'"$BATS_TEST_TMPDIR"'/calls"
            return 0
        }
        quit_running_app() { print -r -- "QUIT" >> "'"$BATS_TEST_TMPDIR"'/calls"; }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        : > "'"$BATS_TEST_TMPDIR"'/calls"
        migrate_to_cask "Thing" "thing" "dry" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f3,6 "$RESULTS_DIR"/result.*
        [[ -f "$HISTORY_FILE" ]] && echo "history exists" || echo "no history"
        grep -c -- "--dry-run" "'"$BATS_TEST_TMPDIR"'/calls" || true
        grep -c "QUIT" "'"$BATS_TEST_TMPDIR"'/calls" || true
    '
    [ "${lines[0]}" = "rc=0" ]
    [ "${lines[1]}" = "migrate|ok" ]
    [ "${lines[2]}" = "no history" ]
    # The dry run asked Homebrew, and quit nothing.
    [ "${lines[3]}" = "1" ]
    [ "${lines[4]}" = "0" ]
}

@test "a failed replace puts the original application back and says so" {
    run run_zsh_snippet '
        app_path="$BATS_TEST_TMPDIR/Thing.app"
        mkdir -p "$app_path/Contents/MacOS"
        print -r -- "original" > "$app_path/Contents/MacOS/marker"
        brew() {
            if [[ "$1 $2" == "info --cask" ]]; then
                printf "{\"casks\":[{\"token\":\"thing\",\"version\":\"2.0\",\"deprecated\":false,\"disabled\":false,\"auto_updates\":true,\"artifacts\":[{\"app\":[\"Thing.app\"],\"target\":\"%s\"}]}]}" "'"$BATS_TEST_TMPDIR"'/Thing.app"
                return 0
            fi
            # list --cask: no stale metadata. install --cask: fails.
            return 1
        }
        app_running() { return 1; }
        quit_running_app() { return 0; }
        collect_cache_for_item() { return 0; }
        migration_app_path() { print -r -- "'"$BATS_TEST_TMPDIR"'/Thing.app"; }
        migrate_to_cask "Thing" "thing" "replace" >/dev/null 2>&1
        echo "rc=$?"
        cut -d"|" -f7 "$RESULTS_DIR"/result.*
        cat "$app_path/Contents/MacOS/marker" 2>/dev/null || echo "MISSING"
        backups=("$BATS_TEST_TMPDIR"/*.msu-migrate-backup(N))
        echo "${#backups}"
    '
    [ "${lines[0]}" = "rc=1" ]
    [ "${lines[1]}" = "restored-after-failure" ]
    [ "${lines[2]}" = "original" ]
    [ "${lines[3]}" = "0" ]
}

# ------------------------------------------------------------------------------
# Cache wiring
# ------------------------------------------------------------------------------

@test "migration_candidates is not a member of any background cache tier" {
    # The scan costs one 'brew info' round trip per candidate token across
    # every unmanaged app on the machine. Adding the key to a tier would put
    # that on SwiftBar's timer.
    run run_zsh_snippet '
        print -l -- "${CACHE_KEYS_UPDATES[@]}" "${CACHE_KEYS_INSTALLED[@]}" \
                    "${CACHE_KEYS_APPS[@]}" "${CACHE_KEYS_WEBSITES[@]}"
    '
    [ "$status" -eq 0 ]
    refute_contains "migration_candidates" "$output"
}

@test "the scan writes its candidates under the documented cache key" {
    run run_zsh_snippet '
        echo "$MIGRATION_CACHE_KEY"
        migration_scan() { print -r -- "'"$CANONICAL_LINE"'"; }
        cache_refresh_entry "$MIGRATION_CACHE_KEY" migration_scan
        cat "$CACHE_DIR/$MIGRATION_CACHE_KEY"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "migration_candidates" ]
    [ "${lines[1]}" = "$CANONICAL_LINE" ]
}

@test "migration_candidate_line finds an app by name in the recorded scan" {
    run run_zsh_snippet '
        print -r -- "'"$CANONICAL_LINE"'" > "$CACHE_DIR/$MIGRATION_CACHE_KEY"
        migration_candidate_line "AltTab"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$CANONICAL_LINE" ]
}

@test "migration_candidate_line reports nothing for an app that was never scanned" {
    run run_zsh_snippet '
        print -r -- "'"$CANONICAL_LINE"'" > "$CACHE_DIR/$MIGRATION_CACHE_KEY"
        migration_candidate_line "Some Other App"
        echo "rc=$?"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]
}

@test "the migrate action is dispatched and does not fall through to the menu draw" {
    # A real invocation: an unknown cask fails, and the run must report that
    # failure rather than printing a SwiftBar menu.
    run bash -c '
        HOME="'"$TEST_HOME"'" MSU_LIB_DIR="'"$REPO_LIB_DIR"'" \
            zsh "'"$REPO_SCRIPT"'" migrate_app "Nothing" "no-such-cask-xyz" dry 2>&1
        echo "exit=$?"
    '
    assert_contains "exit=1" "$output"
    refute_contains "Brew Missing" "$output"
}

# ------------------------------------------------------------------------------
# Migrating in the user's terminal
# ------------------------------------------------------------------------------
# The headless `migrate_app` deliberately never runs sudo - a background run
# has no tty to prompt on. `migrate_app_in_terminal` is the same work somewhere
# Homebrew can ask for a password, and it gets there through the launcher the
# other two terminal actions already use rather than a run path of its own.

# A fake osascript/open on PATH that records the command it was handed, so a
# test can assert what would have been run without driving a real terminal.
# Same shape as tests/launch_in_terminal.bats' stub_launcher.
stub_recording_launcher() {
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    local tool
    for tool in osascript open; do
        cat > "$STUB_BIN/$tool" <<EOF
#!/bin/sh
{ echo "\$@"; cat 2>/dev/null; } >> "$BATS_TEST_TMPDIR/launched"
exit 0
EOF
        chmod +x "$STUB_BIN/$tool"
    done
    : > "$BATS_TEST_TMPDIR/launched"
}

run_dispatch() {
    HOME="$TEST_HOME" MSU_LIB_DIR="$REPO_LIB_DIR" PATH="$STUB_BIN:$PATH" \
        zsh "$REPO_SCRIPT" "$@" </dev/null
}

@test "migrate_app_in_terminal launches the run mode with the app, token and mode" {
    # The launcher always builds "<script> run <args...>", which is why a
    # terminal migration arrives as `run migrate` rather than as a second
    # entry point of its own.
    #
    # launch_in_terminal quotes every argument separately, so the command it
    # builds reads: <script> run 'migrate' 'AltTab' 'alt-tab' 'adopt'. Asserted
    # in that form rather than as a loose substring - the quoting is what keeps
    # an app name with a space in it from arriving as two arguments.
    stub_recording_launcher
    run run_dispatch migrate_app_in_terminal "AltTab" "alt-tab" "adopt"
    [ "$status" -eq 0 ]
    assert_contains "run 'migrate' 'AltTab' 'alt-tab' 'adopt'" "$(cat "$BATS_TEST_TMPDIR/launched")"
}

@test "migrate_app_in_terminal keeps an app name with a space in one argument" {
    stub_recording_launcher
    run run_dispatch migrate_app_in_terminal "Google Chrome" "google-chrome" "adopt"
    [ "$status" -eq 0 ]
    assert_contains "run 'migrate' 'Google Chrome' 'google-chrome' 'adopt'" "$(cat "$BATS_TEST_TMPDIR/launched")"
}

@test "migrate_app_in_terminal defaults to the non-destructive adopt mode" {
    # Same default as migrate_to_cask: the caller has to ask for `replace`,
    # because only the user can say whether replacing their copy is acceptable.
    stub_recording_launcher
    run run_dispatch migrate_app_in_terminal "AltTab" "alt-tab"
    [ "$status" -eq 0 ]
    assert_contains "'alt-tab' 'adopt'" "$(cat "$BATS_TEST_TMPDIR/launched")"
    refute_contains "replace" "$(cat "$BATS_TEST_TMPDIR/launched")"
}

@test "migrate_app_in_terminal passes replace through when it is asked for" {
    stub_recording_launcher
    run run_dispatch migrate_app_in_terminal "AltTab" "alt-tab" "replace"
    [ "$status" -eq 0 ]
    assert_contains "'alt-tab' 'replace'" "$(cat "$BATS_TEST_TMPDIR/launched")"
}

@test "migrate_app_in_terminal reports a terminal that never opened instead of exiting 0" {
    # The bug the whole launch_in_terminal_or_report contract exists for: a
    # launcher that quietly exits 0 leaves the app watching for a run that will
    # never write a line. GuideApp reads this exit status.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    for tool in osascript open; do
        printf '#!/bin/sh\necho "execution error: Not authorized to send Apple events to Terminal. (-1743)" >&2\nexit 1\n' > "$STUB_BIN/$tool"
        chmod +x "$STUB_BIN/$tool"
    done
    run run_dispatch migrate_app_in_terminal "AltTab" "alt-tab" "adopt"
    [ "$status" -eq 1 ]
    assert_contains "System Settings > Privacy & Security > Automation" "$output"
}

@test "run migrate refuses without both an application and a token" {
    # Reads the script's own $3/$4, so a dispatcher calling it bare would leave
    # them empty - this is what catches that.
    run run_zsh_snippet '
        ( run_mode_migrate run migrate "" "" ) 2>&1
        echo "rc=$?"
    '
    assert_contains "rc=1" "$output"
}

@test "run migrate names the app in the shared progress file" {
    # Unlike the headless path this run OWNS that file - it was not started
    # with GUIDEAPP_NO_SHARED_PROGRESS - so the banner can name what is moving.
    run run_zsh_snippet '
        migrate_to_cask() { return 0; }
        open() { :; }
        ( run_mode_migrate run migrate "AltTab" "alt-tab" "adopt" ) >/dev/null 2>&1
        cat "$PROGRESS_FILE"
    '
    [ "$status" -eq 0 ]
    assert_matches "v1|running|migrate|AltTab|*" "${lines[0]}"
}

@test "run migrate exits non-zero when the migration itself failed" {
    # What the dispatcher's EXIT trap turns into failed|migrate|<app>.
    run run_zsh_snippet '
        migrate_to_cask() { return 1; }
        open() { :; }
        ( run_mode_migrate run migrate "AltTab" "alt-tab" "adopt" ) >/dev/null 2>&1
        echo "rc=$?"
    '
    assert_contains "rc=1" "$output"
}

@test "the migrate run mode is dispatched rather than falling through to the menu" {
    run bash -c '
        HOME="'"$TEST_HOME"'" MSU_LIB_DIR="'"$REPO_LIB_DIR"'" \
            zsh "'"$REPO_SCRIPT"'" run migrate "" "" 2>&1
        echo "exit=$?"
    '
    assert_contains "exit=1" "$output"
    refute_contains "Unknown mode" "$output"
}
