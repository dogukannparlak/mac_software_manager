# ------------------------------------------------------------------------------
# 3c. HOMEBREW STATE (STRUCTURED)
# ------------------------------------------------------------------------------
# 'brew outdated --json=v2' is a documented, stable interface; the human
# readable output is not (its "(old) != new" shape has changed before and breaks
# on versions containing spaces or parentheses).
#
# Everything downstream consumes this one normalized form:
#     src|token|installed_versions|current_version|pinned
# src is "brew" or "cask", installed_versions is comma separated, pinned is 1/0.
#
# Two categories are dropped here - in a single place, so the menu and the
# update run can never disagree about what counts as outdated:
#   - font-* casks (hundreds of entries, pure noise)
#   - casks pinned to the literal version "latest" (they update themselves)
brew_outdated_normalized() {
    local json_file kind src count idx name current pinned versions
    local inst_count inst_idx inst_ver

    json_file="$(mktemp "${TMPDIR:-/tmp}/brew_outdated.XXXXXX")" || return 1

    if ! brew outdated --json=v2 --greedy > "$json_file" 2>/dev/null; then
        rm -f "$json_file"
        return 1
    fi

    for kind in formulae casks; do
        src="brew"
        [[ "$kind" == "casks" ]] && src="cask"

        count=$(plutil -extract "$kind" raw -o - "$json_file" 2>/dev/null) || continue
        [[ "$count" =~ ^[0-9]+$ ]] || continue

        for (( idx = 0; idx < count; idx++ )); do
            name=$(plutil -extract "${kind}.${idx}.name" raw -o - "$json_file" 2>/dev/null) || continue
            [[ -n "$name" ]] || continue
            [[ "$name" == font-* ]] && continue

            current=$(plutil -extract "${kind}.${idx}.current_version" raw -o - "$json_file" 2>/dev/null) || current=""

            versions=""
            inst_count=$(plutil -extract "${kind}.${idx}.installed_versions" raw -o - "$json_file" 2>/dev/null) || inst_count=0
            [[ "$inst_count" =~ ^[0-9]+$ ]] || inst_count=0

            for (( inst_idx = 0; inst_idx < inst_count; inst_idx++ )); do
                inst_ver=$(plutil -extract "${kind}.${idx}.installed_versions.${inst_idx}" raw -o - "$json_file" 2>/dev/null) || continue
                [[ -n "$versions" ]] && versions+=", "
                versions+="$inst_ver"
            done
            [[ -z "$versions" ]] && versions="?"

            [[ "$src" == "cask" && "$versions" == "latest" && "$current" == "latest" ]] && continue

            pinned=0
            [[ "$(plutil -extract "${kind}.${idx}.pinned" raw -o - "$json_file" 2>/dev/null)" == "true" ]] && pinned=1

            print -r -- "${src}|${name}|${versions}|${current}|${pinned}"
        done
    done

    rm -f "$json_file"
    return 0
}

# ------------------------------------------------------------------------------
# 3d. UPDATE VERIFICATION
# ------------------------------------------------------------------------------
# An upgrade command can exit 0 and still leave a package outdated (partial
# failures, quarantined casks, apps that refuse to close). History is only
# trustworthy if it records what the package manager reports afterwards.

# Tokens Homebrew currently reports as outdated, one per line
brew_outdated_tokens() {
    local line
    for line in "${(@f)$(brew_outdated_normalized)}"; do
        [[ -n "$line" ]] && print -r -- "${${(s:|:)line}[2]}"
    done
}

# App Store IDs currently reported as outdated, one per line
mas_outdated_ids() {
    command -v mas &> /dev/null || return 0
    local line trimmed
    for line in "${(@f)$(run_with_timeout "$MAS_TIMEOUT" mas outdated 2>/dev/null || true)}"; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" =~ ^[0-9]+ ]] || continue
        print -r -- "${trimmed%% *}"
    done
}

# Exact-match lookups (no regex: brew tokens contain '+', '.' and '@')
brew_is_outdated() {
    local target="$1" tok
    for tok in "${(@f)$(brew_outdated_tokens)}"; do
        [[ "$tok" == "$target" ]] && return 0
    done
    return 1
}

mas_is_outdated() {
    local target="$1" app_id
    for app_id in "${(@f)$(mas_outdated_ids)}"; do
        [[ "$app_id" == "$target" ]] && return 0
    done
    return 1
}

# Pulls the latest Homebrew + tap metadata, retrying through the lockfile
# contention that a plain 'brew update' occasionally hits (another brew
# process, a flaky connection). Shared by the full update run and the
# standalone "check Homebrew now" action, so both retry the same way.
# Prints brew's own output as it goes; returns 1 only after every retry fails.
brew_update_with_retry() {
    local max_retries=6
    local retry_count=0
    local update_output

    while (( retry_count < max_retries )); do
        if update_output=$(brew update 2>&1); then
            echo "$update_output"
            return 0
        fi

        echo "$update_output"
        if echo "$update_output" | grep -q "Failed to download"; then
            echo "⚠️ Network error detected. Waiting 10 seconds before retrying..."
            sleep 10
        else
            echo "⚠️ Homebrew update failed. Waiting 5 seconds before retrying..."
            sleep 5
        fi
        ((++retry_count))
    done

    return 1
}

# ------------------------------------------------------------------------------
# HOMEBREW ITSELF
# ------------------------------------------------------------------------------
# Homebrew has no versioned releases the way an app does - 'brew update' just
# pulls the latest commits, so there is no "4.7.0 is out" to check for. What is
# worth surfacing instead is when that pull last happened: 'brew outdated'
# above is only as accurate as this timestamp, so a stale one is a real signal,
# not trivia.
# Emits: version|last_updated_epoch
collect_brew_status() {
    local version repo last_commit=0

    version=$(brew --version 2>/dev/null | head -n 1) || return 1
    [[ -n "$version" ]] || return 1

    repo=$(brew --repo 2>/dev/null) || repo=""
    if [[ -n "$repo" && -d "$repo/.git" ]]; then
        last_commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || last_commit=0
        [[ "$last_commit" =~ ^[0-9]+$ ]] || last_commit=0
    fi

    print -r -- "${version}|${last_commit}"
}

# Manual application version check via iTunes Lookup API
# Redundant check: tries mdls first, falls back to defaults read (Info.plist)
check_manual_app_version() {
    local app_name="$1"
    local app_id="$2"
    local local_path="/Applications/$app_name.app"

    # Skip if application does not exist locally
    if [[ ! -d "$local_path" ]]; then return; fi

    # Try mdls (Spotlight metadata) as primary source
    local local_ver=$(mdls -name kMDItemVersion -raw "$local_path" 2>/dev/null)

    # Fallback to defaults read (Info.plist) if mdls is empty, null or fails
    if [[ -z "$local_ver" || "$local_ver" == "(null)" ]]; then
        local_ver=$(defaults read "$local_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    fi

    # Final validation of local version string
    if [[ -z "$local_ver" || "$local_ver" == "(null)" ]]; then return; fi

    # Auto-detect system region (e.g., 'en_US' -> 'us', 'pl_PL' -> 'pl')
    # fallback to 'us' if detection fails
    local store_region=$(defaults read NSGlobalDomain AppleLocale 2>/dev/null | cut -d'_' -f2 | tr '[:upper:]' '[:lower:]')
    if [[ -z "$store_region" || ${#store_region} -ne 2 ]]; then
        store_region="us"
    fi

    # Retrieve remote version from iTunes Lookup API
    # curl fetches JSON with dynamic country code
    # plutil extracts 'results.0.version' safely
    local remote_ver=$(curl -sL --max-time 3 "https://itunes.apple.com/lookup?id=$app_id&country=$store_region" \
        | plutil -extract results.0.version raw -o - - 2>/dev/null)

    # Validate if version was retrieved
    if [[ -z "$remote_ver" ]]; then return; fi

    # Compare versions using zsh is-at-least function
    if [[ "$local_ver" != "$remote_ver" ]]; then
        if ! is-at-least "$remote_ver" "$local_ver"; then
            echo "$app_name|$local_ver|$remote_ver|$app_id"
        fi
    fi
}

# Ghost apps: Apple first-party titles the mas CLI regularly fails to report.
# Each one costs an iTunes Lookup API round trip, which is exactly why this runs
# in the background refresh and never in the render path.
# Usage: collect_manual_updates "<raw mas outdated output>"
collect_manual_updates() {
    local known_outdated="$1"
    local result=""

    [[ "$MAS_ENABLED" == "1" ]] || return 0

    typeset -A ghost_apps
    ghost_apps=(
        "Keynote"                         "361285480"
        "Pages"                           "361309726"
        "Numbers"                         "361304891"
        "Pixelmator Pro"                  "6746662575"
        "Final Cut Pro"                   "1631624924"
        "Logic Pro"                       "1615087040"
        "iMovie"                          "408981434"
        "GarageBand"                      "682658836"
        "Xcode"                           "497799835"
        "Motion"                          "434290957"
        "Compressor"                      "424390742"
        "MainStage"                       "634159523"
    )

    local app_name app_id target_app app_result
    for app_name in ${(k)ghost_apps}; do
        app_id=$ghost_apps[$app_name]

        # Prevent duplicate checks if mas CLI already detected the update
        if print -r -- "$known_outdated" | grep -q "$app_id"; then
            continue
        fi

        # Respect ignore list for Ghost Apps too (saves a network round trip)
        if is_ignored "mas" "$app_id"; then
            continue
        fi

        target_app="$app_name"
        if [[ -d "/Applications/${app_name} Creator Studio.app" ]]; then
            target_app="${app_name} Creator Studio"
        elif [[ ! -d "/Applications/${app_name}.app" ]]; then
            continue
        fi

        app_result=$(check_manual_app_version "$target_app" "$app_id")
        if [[ -n "$app_result" ]]; then
            result+="$app_result"$'\n'
        fi
    done

    print -rn -- "$result"
}
