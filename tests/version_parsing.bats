load "test_helper"

# normalize_version: strip decoration, keep the dotted numeric core.

@test "normalize_version strips a leading v" {
    run run_zsh_fn normalize_version "v1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "normalize_version strips a leading release- prefix" {
    run run_zsh_fn normalize_version "release-2.0"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "normalize_version drops a trailing beta suffix" {
    run run_zsh_fn normalize_version "1.39.5.1 beta"
    [ "$status" -eq 0 ]
    [ "$output" = "1.39.5.1" ]
}

@test "normalize_version strips a leading Version word" {
    run run_zsh_fn normalize_version "Version 3.6"
    [ "$status" -eq 0 ]
    [ "$output" = "3.6" ]
}

@test "normalize_version fails (empty, non-zero) on a string with no digits" {
    run run_zsh_fn normalize_version "not-a-version"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# is_prerelease_version: anything that names itself a prerelease.

@test "is_prerelease_version flags beta" {
    run run_zsh_fn is_prerelease_version "3.4.0-beta"
    [ "$status" -eq 0 ]
}

@test "is_prerelease_version flags alpha, rc, nightly, canary" {
    for label in "2.0-alpha" "2.0rc1" "2.0-rc.1" "nightly-2024" "canary build"; do
        run run_zsh_fn is_prerelease_version "$label"
        [ "$status" -eq 0 ]
    done
}

@test "is_prerelease_version does not flag a plain stable version" {
    run run_zsh_fn is_prerelease_version "3.6.8"
    [ "$status" -ne 0 ]
}

@test "is_prerelease_version does not flag a normal release title" {
    run run_zsh_fn is_prerelease_version "AltTab 6.19.0"
    [ "$status" -ne 0 ]
}

# clean_version: strip a trailing 40-hex-char commit hash, keep everything else.

@test "clean_version strips a 40-char commit hash suffix" {
    run run_zsh_fn clean_version "1.2.3,a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "clean_version leaves a comma-suffix that is not 40 hex chars alone" {
    run run_zsh_fn clean_version "1.2.3,notahash"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3,notahash" ]
}

@test "clean_version leaves a version with no comma alone" {
    run run_zsh_fn clean_version "1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

# truncate_ver: limit a version string for menu display, with a ".." marker.

@test "truncate_ver passes a short version through unchanged" {
    run run_zsh_fn truncate_ver "1.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "truncate_ver truncates a version longer than the default limit (10)" {
    run run_zsh_fn truncate_ver "2026.1.3.8-quail3-extra-long"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 10 ]
    [[ "$output" == *".." ]]
}

@test "truncate_ver honours a custom limit argument" {
    run run_zsh_fn truncate_ver "1234567890" 5
    [ "$status" -eq 0 ]
    [ "$output" = "123.." ]
}
