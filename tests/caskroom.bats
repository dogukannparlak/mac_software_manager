load "test_helper"

# Telling Homebrew-installed apps apart from hand-installed ones
# (lib/selfupdate_apps.sh: cask_app_names, load_installed_casks,
# app_is_brew_managed).
#
# The name guess (app_cask_candidates) cannot get from "Docker" to the cask
# docker-desktop, so those apps were reported as self-updating "manual" apps
# and offered for migration to Homebrew they were already in. Homebrew keeps
# the exact .app each cask installed in the Caskroom; these tests build a fake
# Caskroom and check it is read the way GuideApp's CaskIndex reads it.

# Usage: write_definition <token> <version> <timestamp> <json|rb>  (body on stdin)
write_definition() {
    local dir="$BATS_TEST_TMPDIR/Caskroom/$1/.metadata/$2/$3/Casks"
    mkdir -p "$dir"
    cat > "$dir/$1.$4"
}

load_snippet() {
    run_zsh_snippet "
        CASKROOM_DIRS=('$BATS_TEST_TMPDIR/Caskroom')
        mkdir -p \"\$CACHE_DIR\"
        print -r -- 'alt-tab 11.4.3' > \"\$CACHE_DIR/brew_casks\"
        load_installed_casks
        $1
    "
}

@test "an app whose name is nothing like its cask token is recognised" {
    write_definition docker-desktop 4.30.0 20240101120000.000 json << 'EOF'
{
  "token": "docker-desktop",
  "artifacts": [
    { "app": [ "Docker.app" ] },
    { "zap": [ { "trash": "~/Library/Containers/com.docker.docker" } ] }
  ]
}
EOF
    run load_snippet 'app_is_brew_managed Docker && print managed || print manual'
    [ "$status" -eq 0 ]
    [ "$output" = "managed" ]
}

@test "an app moved under a target name is recognised by that name" {
    write_definition renamed 1.1 20240301000000.000 json << 'EOF'
{"artifacts":[{"app":["Source Name.app",{"target":"Pretty Name.app"}]}]}
EOF
    run load_snippet 'app_is_brew_managed "Pretty Name" && print managed || print manual
                  app_is_brew_managed "Source Name" && print managed || print manual'
    [ "$status" -eq 0 ]
    [ "$output" = $'managed\nmanual' ]
}

@test "the newest recorded definition wins over an older one" {
    write_definition renamed 1.0 20230101000000.000 json << 'EOF'
{"artifacts":[{"app":["Old.app"]}]}
EOF
    write_definition renamed 1.1 20240301000000.000 json << 'EOF'
{"artifacts":[{"app":["New.app"]}]}
EOF
    run load_snippet 'print -r -- "${BREW_OWNED_APPS[new.app]:-none} ${BREW_OWNED_APPS[old.app]:-none}"'
    [ "$status" -eq 0 ]
    [ "$output" = "renamed none" ]
}

@test "a Ruby definition from a tap is read too, target included" {
    write_definition tapcask 2.0 20240101000000.000 rb << 'EOF'
cask "tapcask" do
  version "2.0"
  app "Tap Thing.app", target: "Tap Target.app"
  app "Second.app"
end
EOF
    run load_snippet 'print -r -- "${BREW_OWNED_APPS[tap target.app]} ${BREW_OWNED_APPS[second.app]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "tapcask tapcask" ]
}

@test "every Caskroom directory counts as an installed cask, cached or not" {
    mkdir -p "$BATS_TEST_TMPDIR/Caskroom/no-metadata-yet"
    run load_snippet 'print -r -- "${INSTALLED_CASK_TOKENS[no-metadata-yet]} ${INSTALLED_CASK_TOKENS[alt-tab]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "1 1" ]
}

@test "the name guess still covers casks with no readable definition" {
    run load_snippet 'app_is_brew_managed AltTab && print managed || print manual
                  app_is_brew_managed "Something Else" && print managed || print manual'
    [ "$status" -eq 0 ]
    [ "$output" = $'managed\nmanual' ]
}
