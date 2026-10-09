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

# First field of every 'mas <subcommand>' line that starts with a numeric App
# Store ID, one per line. Reads the whole output before matching on purpose:
# piping mas into a short-circuiting reader (grep -q, head) kills it with
# SIGPIPE, and under this script's 'set -o pipefail' that failure is
# indistinguishable from "no match".
mas_ids_from() {
    command -v mas &> /dev/null || return 0
    local line trimmed
    for line in "${(@f)$(run_with_timeout "$MAS_QUERY_TIMEOUT" mas "$1" 2>/dev/null || true)}"; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" =~ ^[0-9]+ ]] || continue
        print -r -- "${trimmed%% *}"
    done
}

# App Store IDs currently reported as outdated, one per line
mas_outdated_ids() {
    mas_ids_from outdated
}

# App Store IDs currently installed, one per line
mas_installed_ids() {
    mas_ids_from list
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

mas_is_installed() {
    local target="$1" app_id
    for app_id in "${(@f)$(mas_installed_ids)}"; do
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

# One-line descriptions for every installed formula, used by the GuideApp UI
# to group the CLI Tools list into categories. 'brew desc' reads Homebrew's
# own description index - offline, no network call, as long as that index
# already exists (it is populated the same way 'brew outdated' data is: by a
# plain 'brew update'). Output: "token: description", one per line.
brew_formulae_desc_collect() {
    local -a tokens
    tokens=(${(f)"$(brew list --formula 2>/dev/null)"})
    (( ${#tokens[@]} > 0 )) || return 0
    brew desc "${tokens[@]}" 2>/dev/null
}

# Same as brew_formulae_desc_collect above, for installed casks - drives
# category grouping for apps in the same "token: description" shape.
brew_casks_desc_collect() {
    local -a tokens
    tokens=(${(f)"$(brew list --cask 2>/dev/null)"})
    (( ${#tokens[@]} > 0 )) || return 0
    brew desc --cask "${tokens[@]}" 2>/dev/null
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

# ------------------------------------------------------------------------------
# 3c2. EVERYTHING ELSE ON THE MAC (OTHER PACKAGE MANAGERS)
# ------------------------------------------------------------------------------
# Homebrew is the primary source and stays that way: every brew-specific path
# above is untouched by this section. What lives here is the rest of what a
# Mac collects over time - npm/pipx/uv/cargo/go installs, installer packages
# (.pkg) and standalone tools dropped into ~/.local/bin and friends (Claude
# Code installs itself there, for one) - so the CLI Tools page can list
# everything, not just formulae.
#
# Opt-out through OTHER_SOURCES_ENABLED="0" in settings.conf: with it off,
# both entries below are written empty.
#
# Line format, one package per line (CACHE_FORMAT.md, "other_packages"):
#     source|name|version|location
# source is one of npm pipx uv cargo go pkg app local; version and location
# may be empty. location is what a source needs to be acted on: the module
# path for go (what 'go install' takes), the bundle for an app's command line
# shim, the resolved file for a standalone tool, the install location for a
# .pkg receipt.
#
# Nothing here ever executes the tools it finds - only the package managers'
# own listing commands and 'go version -m', which reads build info from the
# binary without running it. Every query gets the same hang guard 'mas' does.
OTHER_QUERY_TIMEOUT=${OTHER_QUERY_TIMEOUT:-30}

# Every source this section knows. OTHER_SOURCES_LIST in settings.conf picks
# a subset (comma separated); unset means all of them.
OTHER_SOURCES_ALL="npm,pipx,uv,cargo,go,local,app,pkg"

# Is this source switched on? Both the master switch and the list have to say
# yes.
other_source_enabled() {
    [[ "${OTHER_SOURCES_ENABLED:-1}" == "1" ]] || return 1
    [[ ",${OTHER_SOURCES_LIST:-$OTHER_SOURCES_ALL}," == *",$1,"* ]]
}

# The first dotted-numeric component of a path ("…/versions/2.0.14" -> 2.0.14),
# which is how most self-installing tools lay out their versions.
version_from_path() {
    local part
    for part in "${(@s:/:)1}"; do
        if [[ "$part" =~ '^v?[0-9]+(\.[0-9]+)+([-+._][A-Za-z0-9.]+)?$' ]]; then
            print -r -- "${part#v}"
            return 0
        fi
    done
    return 1
}

collect_npm_packages() {
    command -v npm &> /dev/null || return 0
    local out line spec name ver
    # 'npm ls' exits non-zero over a single extraneous or invalid package
    # while still printing the whole list, so the status is not the verdict.
    out=$(run_with_timeout "$OTHER_QUERY_TIMEOUT" npm ls -g --depth=0 --parseable --long 2>/dev/null) || true
    for line in "${(@f)out}"; do
        # <path>:<name>@<version>[:<extra>]. Only paths under node_modules
        # are packages: the first line is the global prefix itself, and npm
        # can write it with a spec of its own ("…/lib:lib@"), which read as a
        # package called "lib".
        [[ "${line%%:*}" == */node_modules/* ]] || continue
        spec="${line#*:}"
        spec="${spec%%:*}"
        [[ "$spec" == ?*@* ]] || continue
        name="${spec%@*}"
        ver="${spec##*@}"
        [[ -n "$name" ]] && print -r -- "npm|$name|$ver|"
    done
    return 0
}

collect_pipx_packages() {
    command -v pipx &> /dev/null || return 0
    local out line
    out=$(run_with_timeout "$OTHER_QUERY_TIMEOUT" pipx list --short 2>/dev/null) || return 0
    for line in "${(@f)out}"; do
        local -a f=(${=line})
        (( ${#f} >= 2 )) && print -r -- "pipx|${f[1]}|${f[2]}|"
    done
    return 0
}

collect_uv_tools() {
    command -v uv &> /dev/null || return 0
    local out line
    out=$(run_with_timeout "$OTHER_QUERY_TIMEOUT" uv tool list 2>/dev/null) || return 0
    for line in "${(@f)out}"; do
        # "ruff v0.6.0" heads each tool; its executables follow as "- ruff".
        [[ "$line" =~ '^[A-Za-z0-9][A-Za-z0-9._-]* v[0-9]' ]] || continue
        local -a f=(${=line})
        print -r -- "uv|${f[1]}|${f[2]#v}|"
    done
    return 0
}

collect_cargo_packages() {
    command -v cargo &> /dev/null || return 0
    local out line ver
    out=$(run_with_timeout "$OTHER_QUERY_TIMEOUT" cargo install --list 2>/dev/null) || return 0
    for line in "${(@f)out}"; do
        # "ripgrep v14.1.0:" (or "foo v0.1.0 (https://…):"); binaries follow
        # indented.
        [[ "$line" == [A-Za-z0-9]* ]] || continue
        local -a f=(${=line})
        (( ${#f} >= 2 )) || continue
        ver="${f[2]%:}"
        print -r -- "cargo|${f[1]}|${ver#v}|"
    done
    return 0
}

collect_go_binaries() {
    command -v go &> /dev/null || return 0
    local bindir bin info pkg ver
    bindir=$(go env GOBIN 2>/dev/null)
    [[ -n "$bindir" ]] || bindir="$(go env GOPATH 2>/dev/null | cut -d: -f1)/bin"
    [[ -d "$bindir" ]] || return 0
    for bin in "$bindir"/*(N.*); do
        info=$(run_with_timeout 10 go version -m "$bin" 2>/dev/null) || continue
        # "\tpath\t<package>" names what 'go install' takes; "\tmod\t<module>\t<version>"
        # carries the version.
        pkg=$(print -r -- "$info" | awk -F'\t' '$2 == "path" { print $3; exit }')
        ver=$(print -r -- "$info" | awk -F'\t' '$2 == "mod" { print $4; exit }')
        [[ -n "$pkg" ]] || continue
        print -r -- "go|${bin:t}|${ver#v}|$pkg"
    done
    return 0
}

# Installer package receipts, minus Apple's own. These are what a .pkg
# download leaves behind - drivers, runtimes, apps that ship as installers.
collect_pkg_receipts() {
    command -v pkgutil &> /dev/null || return 0
    local out id info ver location
    out=$(run_with_timeout "$OTHER_QUERY_TIMEOUT" pkgutil --pkgs 2>/dev/null) || return 0
    for id in "${(@f)out}"; do
        [[ -n "$id" && "$id" != com.apple.* ]] || continue
        info=$(pkgutil --pkg-info "$id" 2>/dev/null) || continue
        ver=$(print -r -- "$info" | awk -F': ' '$1 == "version" { print $2; exit }')
        location=$(print -r -- "$info" | awk -F': ' '$1 == "location" { print $2; exit }')
        print -r -- "pkg|$id|$ver|$location"
    done
    return 0
}

# Standalone executables in the usual per-user bin folders - and in
# /usr/local/bin when that is not Homebrew's own prefix (Apple Silicon).
# Anything another collector already accounts for (Homebrew, pipx, uv, npm,
# cargo) is skipped; a shim into an application bundle is reported as that
# app's ("app"), since it updates with the app.
#
# Homebrew's own bin folder is scanned too, for what other installers drop
# there because it is on PATH (Antigravity's 'agy' is a plain 178 MB binary
# in /opt/homebrew/bin). Homebrew itself only ever puts symlinks into that
# folder, so a symlink resolving inside the prefix is Homebrew's and is
# skipped, while a regular file there is somebody else's.
collect_local_tools() {
    local brew_prefix="" dir f target name ver app
    typeset -A seen
    typeset -a dirs
    # <prefix>/bin/brew -> <prefix>. Not resolved through the symlink: that
    # lands in <prefix>/Homebrew, which is not where formulae link into.
    command -v brew &> /dev/null && brew_prefix="${$(command -v brew):h:h}"

    dirs=("$HOME/.local/bin" "$HOME/bin" "$HOME/.bun/bin" "$HOME/.deno/bin")
    [[ "$brew_prefix" != "/usr/local" ]] && dirs+=("/usr/local/bin")
    [[ -n "$brew_prefix" ]] && dirs+=("$brew_prefix/bin")

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        # (N-*): executables, following symlinks to judge the target
        for f in "$dir"/*(N-*); do
            name="${f:t}"
            [[ -z "${seen[$name]}" ]] || continue
            # Leftovers, not tools: what an updater keeps of the previous
            # version ("agy.1791553591174963000.old") and editor backups.
            case "$name" in
                *.old|*.bak|*.orig|*.backup|*.tmp|*.swp|*~) continue ;;
            esac
            target="${f:A}"
            case "$target" in
                */Cellar/*|*/Caskroom/*|*/pipx/*|*/uv/tools/*|*/node_modules/*|*/.cargo/*) continue ;;
            esac
            [[ -n "$brew_prefix" && -L "$f" && "$target" == "$brew_prefix"/* ]] && continue
            seen[$name]=1

            if [[ "$target" == *.app/Contents/* ]]; then
                other_source_enabled app || continue
                app="${target%%.app/Contents/*}.app"
                ver=$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString) || ver=""
                print -r -- "app|$name|$ver|$app"
            else
                other_source_enabled local || continue
                ver=$(version_from_path "$target") || ver=""
                print -r -- "local|$name|$ver|$target"
            fi
        done
    done
    return 0
}

collect_other_packages() {
    other_source_enabled npm   && collect_npm_packages
    other_source_enabled pipx  && collect_pipx_packages
    other_source_enabled uv    && collect_uv_tools
    other_source_enabled cargo && collect_cargo_packages
    other_source_enabled go    && collect_go_binaries
    { other_source_enabled local || other_source_enabled app; } && collect_local_tools
    other_source_enabled pkg   && collect_pkg_receipts
    return 0
}

# Standalone tools that know how to update themselves, by the name they are
# installed under. Kept in step with OtherPackage.selfUpdatingTools in the app.
# Only these are offered an update; any other standalone tool is listed and
# left alone.
local_tool_is_updatable() {
    case "$1" in
        claude|uv|bun|deno|rustup) return 0 ;;
    esac
    return 1
}

# Whether this package has an update command here at all.
other_package_is_updatable() {
    local source="$1" name="$2"
    case "$source" in
        npm|pipx|uv|cargo|go) return 0 ;;
        local) local_tool_is_updatable "$name" ;;
        *) return 1 ;;
    esac
}

# GET a JSON document and print the value at one key path (plutil syntax,
# "info.version"). Non-zero when the request or the key fails.
json_url_value() {
    local url="$1" key="$2" file value=""
    file="$(mktemp "${TMPDIR:-/tmp}/msu_json.XXXXXX")" || return 1
    if curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 15 \
        -H "User-Agent: $USER_AGENT" "$url" -o "$file" 2>/dev/null; then
        value=$(plutil -extract "$key" raw -o - "$file" 2>/dev/null) || value=""
    fi
    rm -f "$file"
    [[ -n "$value" ]] || return 1
    print -r -- "$value"
}

# The newest published version of one package, from its registry - or
# non-zero when the source has no registry to ask.
other_latest_version() {
    local source="$1" name="$2"
    case "$source" in
        pipx|uv) json_url_value "https://pypi.org/pypi/${name}/json" "info.version" ;;
        cargo)   json_url_value "https://crates.io/api/v1/crates/${name}" "crate.max_stable_version" ;;
        local)
            case "$name" in
                claude) json_url_value "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" "version" ;;
                uv)     json_url_value "https://pypi.org/pypi/uv/json" "info.version" ;;
                bun)    json_url_value "https://registry.npmjs.org/bun/latest" "version" ;;
                *)      return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# What has a newer version waiting: source|name|current|latest.
#
# npm answers for all its packages in one call. pipx, uv, cargo and the
# self-updating standalone tools are looked up one by one in their public
# registries (PyPI, crates.io, npm), from the last scan. Three failed lookups
# in a row mean the network is not there, and the rest are skipped rather
# than each waiting out its own timeout.
collect_other_outdated() {
    local out line current latest source name failures=0

    if other_source_enabled npm && command -v npm &> /dev/null; then
        # Exits 1 whenever something IS outdated - that is the answer, not an error.
        out=$(run_with_timeout 60 npm outdated -g --parseable --depth=0 2>/dev/null) || true
        for line in "${(@f)out}"; do
            # <path>:<name>@<wanted>:<name>@<current>:<name>@<latest>[:…]
            local -a f=("${(@s/:/)line}")
            (( ${#f} >= 4 )) || continue
            current="${f[3]##*@}"
            latest="${f[4]##*@}"
            [[ -n "$latest" && "$current" != "$latest" ]] || continue
            print -r -- "npm|${f[4]%@*}|$current|$latest"
        done
    fi

    for line in "${(@f)$(cache_get other_packages 2>/dev/null)}"; do
        (( failures < 3 )) || break
        local -a f=("${(@s:|:)line}")
        source="${f[1]}"; name="${f[2]}"; current="${f[3]#v}"
        case "$source" in
            pipx|uv|cargo) ;;
            local) local_tool_is_updatable "$name" || continue ;;
            *) continue ;;
        esac
        other_source_enabled "$source" || continue
        [[ -n "$name" && -n "$current" ]] || continue

        if ! latest=$(other_latest_version "$source" "$name"); then
            failures=$(( failures + 1 ))
            continue
        fi
        failures=0
        latest="${latest#v}"
        # Newer only: a tool ahead of its registry (a prerelease, a local
        # build) is not "outdated".
        [[ "$latest" != "$current" ]] || continue
        is-at-least "$latest" "$current" && continue
        print -r -- "$source|$name|$current|$latest"
    done
    return 0
}

# Update one package. A fixed command per source - or, for a self-updating
# standalone tool, that tool's own update command, run from the file the scan
# found - run directly, never through eval. The caller has already checked
# the package against the last scan (other_package_line).
run_other_package_update() {
    local source="$1" name="$2" location="$3"
    case "$source" in
        npm)   npm install -g "${name}@latest" ;;
        pipx)  pipx upgrade "$name" ;;
        uv)    uv tool upgrade "$name" ;;
        # Reinstalls only when crates.io has something newer.
        cargo) cargo install "$name" ;;
        go)    [[ -n "$location" ]] || return 1
               go install "${location}@latest" ;;
        local)
            [[ -n "$location" && -x "$location" ]] || return 1
            case "$name" in
                claude) "$location" update ;;
                uv)     "$location" self update ;;
                bun)    "$location" upgrade ;;
                deno)   "$location" upgrade ;;
                rustup) "$location" update ;;
                *)      return 1 ;;
            esac
            ;;
        *)     return 1 ;;
    esac
}

# The cached line for one package, or non-zero when the last scan has no such
# package.
other_package_line() {
    local source="$1" name="$2" line
    for line in "${(@f)$(cache_get other_packages 2>/dev/null)}"; do
        [[ "${line%%|*}" == "$source" ]] || continue
        local -a f=("${(@s:|:)line}")
        [[ "${f[2]}" == "$name" ]] && { print -r -- "$line"; return 0; }
    done
    return 1
}
