load "test_helper"

# clean_mas_name: strips the leading App Store ID and trailing "(version)".

@test "clean_mas_name strips the leading id and trailing version" {
    run run_zsh_fn clean_mas_name "497799835 Xcode (16.2)"
    [ "$status" -eq 0 ]
    [ "$output" = "Xcode" ]
}

@test "clean_mas_name copes with a multi-word app name" {
    run run_zsh_fn clean_mas_name "361285480 Keynote for Mac (13.2)"
    [ "$status" -eq 0 ]
    [ "$output" = "Keynote for Mac" ]
}

@test "clean_mas_name leaves a name with no version parens alone" {
    run run_zsh_fn clean_mas_name "123456789 SomeApp"
    [ "$status" -eq 0 ]
    [ "$output" = "SomeApp" ]
}

# app_cask_candidates: plausible cask tokens for an app display name.

@test "app_cask_candidates lowercases and hyphenates a spaced name" {
    run run_zsh_fn app_cask_candidates "Sublime Text"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sublime-text"* ]]
}

@test "app_cask_candidates splits camelCase into kebab-case" {
    run run_zsh_fn app_cask_candidates "AltTab"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alt-tab"* ]]
}

@test "app_cask_candidates offers a dot-less variant" {
    run run_zsh_fn app_cask_candidates "draw.io"
    [ "$status" -eq 0 ]
    [[ "$output" == *"drawio"* ]]
}

@test "app_cask_candidates never emits duplicate lines" {
    run run_zsh_snippet '
        app_cask_candidates "AltTab" | sort | uniq -d
    '
    [ "$output" = "" ]
}

# cask_repo_from_url: owner/repo, only for an actual GitHub releases URL.

@test "cask_repo_from_url extracts owner/repo from a releases asset URL" {
    run run_zsh_fn cask_repo_from_url "https://github.com/lwouis/alt-tab-macos/releases/download/v7.0.0/AltTab.zip"
    [ "$status" -eq 0 ]
    [ "$output" = "lwouis/alt-tab-macos" ]
}

@test "cask_repo_from_url rejects a non-GitHub URL" {
    run run_zsh_fn cask_repo_from_url "https://example.com/downloads/app.dmg"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "cask_repo_from_url rejects a GitHub URL that is not a releases asset" {
    run run_zsh_fn cask_repo_from_url "https://github.com/lwouis/alt-tab-macos"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
