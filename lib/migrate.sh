# ------------------------------------------------------------------------------
# HOMEBREW MIGRATION
# ------------------------------------------------------------------------------
# Applications that live in /Applications without Homebrew knowing about them,
# and what it would take to hand each one over to a cask.
#
# Two halves, deliberately separated:
#   - migration_scan()  answers "which apps could move, and what would happen"
#     WITHOUT running a single install command. Everything it reports is read
#     off the cask's own JSON metadata and the installed bundle's Info.plist.
#   - migrate_to_cask() is the only half that changes anything, and only for
#     the one app it was asked about.
#
# WHY setup_mac.sh KEEPS ITS OWN COPY OF THE TOKEN MATCHING.
# setup_mac.sh runs *before* the toolkit is installed - it is what creates
# $APP_DIR/lib in the first place - so it cannot source anything from lib/.
# Its cask_token_candidates()/lookup_token_override() and its
# migrate_app_to_cask() fallback are therefore duplicated here on purpose, not
# by oversight: the installer's copy has to stay standalone. When the matching
# rules change, both copies move together.
#
# What this file does NOT copy from setup_mac.sh is the sudo escalation in its
# backup path. The installer runs interactively, with a terminal to type a
# password into; this engine also runs headless (a cron tick, a GuideApp item
# run), where a sudo prompt has nothing to read from and would hang until
# something killed it. A move that needs root fails here instead, which is what
# the "needs-root" state below exists to warn about before anything is tried.

# The cask token map is written and documented by setup_mac.sh, which defines
# this path itself; the engine only ever reads it, so it defines the path only
# when nothing else already has.
: ${TOKEN_MAP_FILE:="$APP_DIR/app_token_map.conf"}

# How long one 'brew info' lookup may take. The scan makes one call per
# candidate token, so an unreachable Homebrew API would otherwise stall the
# whole scan on the first app. Same shape as MAS_QUERY_TIMEOUT (lib/utils.sh):
# a hang guard, not a pace limit.
MIGRATION_BREW_INFO_TIMEOUT=${MIGRATION_BREW_INFO_TIMEOUT:-30}

# Cache entry the scan writes. Deliberately NOT a member of any tier
# (CACHE_KEYS_UPDATES/INSTALLED/APPS/WEBSITES): a scan costs one 'brew info'
# round trip per candidate token across every unmanaged app on the machine, so
# it runs when the user asks for it and never on the background refresh.
MIGRATION_CACHE_KEY="migration_candidates"
MIGRATION_FORMAT_VERSION="v1"

# ------------------------------------------------------------------------------
# JSON READING
# ------------------------------------------------------------------------------
# plutil, for the same reason collect_cask_homepages uses it: it ships with
# macOS, reads JSON as happily as it reads plists, and asks for a key path
# rather than a regex over someone else's output format.

# One scalar at a key path, empty when it is not there. Booleans come back as
# the literal "true"/"false", numbers as digits.
#
# The key path is NOT held in a variable named 'path': that is one of zsh's
# special parameters, tied to $PATH as an array. A 'local path=...' inside a
# function replaces $PATH for the duration of that function, so every command
# it then tries to run - plutil included - is simply not found, and the
# function quietly returns nothing at all. Same trap as the read-only 'status'
# in run_mode_single (lib/run_modes.sh).
migration_json_field() {
    local file="$1" key_path="$2" value=""
    value=$(plutil -extract "$key_path" raw -o - "$file" 2>/dev/null) || return 0
    print -r -- "$value"
}

# Zero or more strings at a key path, one per line.
#
# Cask JSON uses "one or many" for most of these fields - `quit` is a string
# for a cask with one bundle id and an array for a cask with three - so asking
# plutil for the raw value is not enough on its own: on an array it returns the
# element COUNT, which would read as a perfectly plausible (and completely
# wrong) bundle id. The two shapes have to be told apart before the value is
# read, not guessed at from what came back.
#
# The xml1 form is what tells them apart, and it has to be xml1 rather than
# json: plutil's JSON writer refuses a bare scalar ("Invalid object in plist
# for JSON format") because JSON output needs a top-level container, so the
# one-bundle-id case - the common one - would fail the probe entirely. A plist
# has no such restriction and wraps a lone string in <string> just as happily
# as it wraps a list in <array>.
migration_json_values() {
    local file="$1" key_path="$2"
    local shape="" count="" idx value

    shape=$(plutil -extract "$key_path" xml1 -o - "$file" 2>/dev/null) || return 0
    [[ -n "$shape" ]] || return 0

    if [[ "$shape" == *"<array>"* ]]; then
        count=$(plutil -extract "$key_path" raw -o - "$file" 2>/dev/null) || return 0
        [[ "$count" =~ ^[0-9]+$ ]] || return 0
        for (( idx = 0; idx < count; idx++ )); do
            value=$(plutil -extract "${key_path}.${idx}" raw -o - "$file" 2>/dev/null) || continue
            [[ -n "$value" ]] && print -r -- "$value"
        done
    elif [[ "$shape" == *"<string>"* ]]; then
        value=$(plutil -extract "$key_path" raw -o - "$file" 2>/dev/null) || return 0
        [[ -n "$value" ]] && print -r -- "$value"
    fi

    return 0
}

# How many entries the "artifacts" array of casks.0 has (0 when unreadable)
migration_artifact_count() {
    local count
    count=$(plutil -extract "casks.0.artifacts" raw -o - "$1" 2>/dev/null) || count=""
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    print -r -- "$count"
}

# ------------------------------------------------------------------------------
# CASK METADATA
# ------------------------------------------------------------------------------

# Fetch one cask's metadata into a file. Non-zero when no such cask exists -
# which is the ONLY question 'brew info' is asked here.
#
# 'brew search' is never used for this. On this machine it answers "ClearDisk"
# with "clearvpn": search is a fuzzy, human-facing tool that is allowed to
# guess, and a guess here would offer to replace one application with an
# unrelated one. 'brew info <token>' either resolves the exact token or fails.
migration_cask_fetch() {
    local token="$1" out_file="$2"

    [[ -n "$token" && -n "$out_file" ]] || return 1

    run_with_timeout "$MIGRATION_BREW_INFO_TIMEOUT" \
        brew info --cask --json=v2 "$token" > "$out_file" 2>/dev/null || return 1
    [[ -s "$out_file" ]] || return 1

    # A response that does not contain the cask we asked about is not an answer
    [[ "$(migration_json_field "$out_file" "casks.0.token")" == "$token" ]] || return 1
    return 0
}

# The cask's first app artifact as "app_file|target", non-zero when it has
# none.
#
# `target` is where Homebrew will actually put the bundle. When the cask does
# not state one, Homebrew's default is the app file's name under the app
# directory, which is /Applications unless the user overrode it - the same
# default this project assumes everywhere else it names a path.
migration_cask_app_target() {
    local file="$1"
    local count idx app_file target

    count=$(migration_artifact_count "$file")
    for (( idx = 0; idx < count; idx++ )); do
        # Only the first entry of "app" matters: a cask shipping several
        # bundles still installs the first one to the stated target, and the
        # question here is where THIS app would land.
        app_file=$(migration_json_values "$file" "casks.0.artifacts.${idx}.app" | head -n 1)
        [[ -n "$app_file" ]] || continue

        target=$(migration_json_field "$file" "casks.0.artifacts.${idx}.target")
        [[ -n "$target" ]] || target="/Applications/${app_file}"

        print -r -- "${app_file}|${target}"
        return 0
    done

    return 1
}

# Bundle identifiers the cask names for the app it manages: the ids it quits
# before uninstalling, and the launchd jobs it unloads. These are written by
# the cask author against the real application, so an id matching the installed
# bundle is evidence about the app itself rather than about its name.
migration_cask_bundle_ids() {
    local file="$1"
    local count idx un_count un_idx

    count=$(migration_artifact_count "$file")
    for (( idx = 0; idx < count; idx++ )); do
        un_count=$(plutil -extract "casks.0.artifacts.${idx}.uninstall" raw -o - "$file" 2>/dev/null) || continue
        [[ "$un_count" =~ ^[0-9]+$ ]] || continue
        for (( un_idx = 0; un_idx < un_count; un_idx++ )); do
            migration_json_values "$file" "casks.0.artifacts.${idx}.uninstall.${un_idx}.quit"
            migration_json_values "$file" "casks.0.artifacts.${idx}.uninstall.${un_idx}.launchctl"
        done
    done

    return 0
}

# True when installing this cask would need root: an installer script that
# declares sudo, which Homebrew runs with a password prompt of its own.
migration_cask_installer_needs_root() {
    local file="$1"
    local count idx in_count in_idx

    count=$(migration_artifact_count "$file")
    for (( idx = 0; idx < count; idx++ )); do
        in_count=$(plutil -extract "casks.0.artifacts.${idx}.installer" raw -o - "$file" 2>/dev/null) || continue
        [[ "$in_count" =~ ^[0-9]+$ ]] || continue
        for (( in_idx = 0; in_idx < in_count; in_idx++ )); do
            if [[ "$(migration_json_field "$file" "casks.0.artifacts.${idx}.installer.${in_idx}.script.sudo")" == "true" ]]; then
                return 0
            fi
        done
    done

    return 1
}

# ------------------------------------------------------------------------------
# MATCH EVIDENCE
# ------------------------------------------------------------------------------
# How sure are we that this cask is really this application? Reported per
# candidate so the UI can say so out loud, because the weakest kind of match -
# a token derived from the app's name and nothing else - is exactly the kind
# that pairs "ClearDisk" with an unrelated cask.
#
#   artifact : the cask installs a bundle with this exact file name
#   bundle   : the cask names this exact CFBundleIdentifier
#   token    : the name-derived token resolved to *a* cask, and that is all
#
# 'override' is not decided here: a hand-written app_token_map.conf entry is
# the user stating the answer, and nothing this function computes can outrank
# it (see migration_candidate_for_app).
migration_match_evidence() {
    local file="$1" app_path="$2" bundle_id="$3"
    local app_file="" artifact="" candidate_id

    artifact=$(migration_cask_app_target "$file") || artifact=""
    app_file="${artifact%%|*}"

    if [[ -n "$app_file" && "$app_file" == "${app_path:t}" ]]; then
        print -r -- "artifact"
        return 0
    fi

    if [[ -n "$bundle_id" ]]; then
        for candidate_id in ${(f)"$(migration_cask_bundle_ids "$file")"}; do
            if [[ "$candidate_id" == "$bundle_id" ]]; then
                print -r -- "bundle"
                return 0
            fi
        done
    fi

    print -r -- "token"
    return 0
}

# ------------------------------------------------------------------------------
# MIGRATABILITY
# ------------------------------------------------------------------------------
# What would happen if this app were handed to this cask, decided from JSON and
# Info.plist alone - no command is run, nothing is downloaded, nothing on disk
# is touched. One token, in the order a blocker outranks a warning:
#
#   deprecated       the cask is deprecated or disabled. A disabled cask cannot
#                    be installed at all and a deprecated one is on its way
#                    out, so nothing below it matters.
#   no-app-artifact  the cask installs no .app (a pkg/installer cask such as
#                    logitech-g-hub). There is no bundle for Homebrew to adopt
#                    and no bundle for a replace to put back: not migratable.
#   needs-root       an installer script declaring sudo, or a target under
#                    /Library. See the file header for why this engine will not
#                    escalate.
#   target-mismatch  the cask would install somewhere other than where the app
#                    already is. This is the ~/Applications trap: adopting does
#                    not move the bundle, it installs a SECOND copy in
#                    /Applications and leaves the original where it was.
#   version-mismatch there is an app artifact, but the versions do not line up,
#                    so 'brew install --cask --adopt' will refuse. A replace
#                    would work.
#   adoptable        adopt should succeed.
#
# The adoptable rule is Homebrew's own, from Cask::Artifact::Moved#move
# (moved.rb:95-135): with auto_updates the bundle versions are not compared at
# all, and without it BOTH the short version and the build version of the
# incoming bundle must equal the installed one. What is compared here is the
# cask's recorded bundle_short_version/bundle_version rather than the download
# itself - that metadata is generated from that very download, so it is the
# closest thing to the answer available without fetching it.
#
# A cask that records neither (they are null for casks Homebrew never unpacked
# a bundle from) makes Homebrew fall back to a recursive diff of the two
# directories, whose outcome cannot be predicted from here. That reports as
# version-mismatch: "adopt may well refuse" is the honest answer, and the
# refusal itself is harmless - see migrate_to_cask.
migration_state() {
    local file="$1" app_path="$2"
    local artifact="" target=""
    local cask_short cask_build installed_short installed_build

    if [[ "$(migration_json_field "$file" "casks.0.deprecated")" == "true" || \
          "$(migration_json_field "$file" "casks.0.disabled")" == "true" ]]; then
        print -r -- "deprecated"
        return 0
    fi

    if ! artifact=$(migration_cask_app_target "$file"); then
        print -r -- "no-app-artifact"
        return 0
    fi
    target="${artifact#*|}"

    if migration_cask_installer_needs_root "$file" || [[ "$target" == /Library/* ]]; then
        print -r -- "needs-root"
        return 0
    fi

    if [[ "$target" != "$app_path" ]]; then
        print -r -- "target-mismatch"
        return 0
    fi

    if [[ "$(migration_json_field "$file" "casks.0.auto_updates")" == "true" ]]; then
        print -r -- "adoptable"
        return 0
    fi

    cask_short=$(migration_json_field "$file" "casks.0.bundle_short_version")
    cask_build=$(migration_json_field "$file" "casks.0.bundle_version")
    installed_short=$(plist_value "$app_path/Contents/Info.plist" CFBundleShortVersionString) || installed_short=""
    installed_build=$(plist_value "$app_path/Contents/Info.plist" CFBundleVersion) || installed_build=""

    if [[ -n "$cask_short" && -n "$cask_build" && \
          "$cask_short" == "$installed_short" && "$cask_build" == "$installed_build" ]]; then
        print -r -- "adoptable"
    else
        print -r -- "version-mismatch"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# TOKEN MATCHING
# ------------------------------------------------------------------------------
# A copy of setup_mac.sh's matching, minus its progressive truncation - see the
# file header for why the installer keeps its own copy.

# The user's hand-written answer for an app, when there is one. Some tokens
# cannot be derived from a name at all ("lghub" is the cask "logitech-g-hub"),
# which is what this file is for.
migration_token_override() {
    local app_name="$1"
    local map_name map_token

    [[ -f "$TOKEN_MAP_FILE" ]] || return 1

    while IFS='|' read -r map_name map_token || [[ -n "$map_name" ]]; do
        map_name="${map_name#"${map_name%%[![:space:]]*}"}"
        map_name="${map_name%"${map_name##*[![:space:]]}"}"
        [[ -z "$map_name" || "$map_name" == \#* ]] && continue

        map_token="${map_token#"${map_token%%[![:space:]]*}"}"
        map_token="${map_token%"${map_token##*[![:space:]]}"}"
        [[ -z "$map_token" ]] && continue

        if [[ "${map_name:l}" == "${app_name:l}" ]]; then
            print -r -- "$map_token"
            return 0
        fi
    done < "$TOKEN_MAP_FILE"

    return 1
}

# Plausible cask tokens for an app name, most likely first: the plain kebab
# form, the camelCase split ("AltTab" -> "alt-tab", which is how Homebrew
# writes it and "alttab" is not), and the dot-less variant of each ("draw.io"
# -> "drawio").
#
# setup_mac.sh's copy also truncates progressively ("synology-drive-client" ->
# "synology-drive" -> "synology"), which is left out here for the same reason
# app_cask_candidates (lib/selfupdate_apps.sh) leaves it out: that runs with a
# user confirming the result in front of them, and this does not. Every extra
# variant is another chance to resolve *some* cask that has nothing to do with
# the app, and the candidate would then be offered as a migration target.
migration_token_candidates() {
    local app_name="$1"
    local base="" camel="" variant=""
    typeset -a out

    base=$(print -r -- "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    camel=$(print -r -- "$app_name" \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]' \
        | tr ' ' '-' \
        | sed -E 's/-+/-/g; s/^-//; s/-$//')

    out=("$base")
    [[ -n "$camel" && "$camel" != "$base" ]] && out+=("$camel")

    variant="${base//./}"
    [[ "$variant" != "$base" ]] && out+=("$variant")
    variant="${camel//./}"
    [[ -n "$camel" && "$variant" != "$camel" ]] && out+=("$variant")

    # (u) keeps the first occurrence of each token and drops later duplicates
    print -rl -- "${(@u)out}"
}

# ------------------------------------------------------------------------------
# SCANNING
# ------------------------------------------------------------------------------

# Strip everything that would shift a field boundary, the same rule
# result_write applies to the fields it does not control. A stray pipe in an
# app name or a homepage would push every field after it along by one, and a
# reader counting fields rejects the whole record.
migration_clean_field() {
    local value="${1//$'\n'/ }"
    print -r -- "${value//|/}"
}

# The best candidate cask for one app, or nothing.
# Prints: token|match|json_file  - the caller owns (and removes) json_file.
#
# A hand-written override is taken as given and nothing else is tried: the user
# already answered the question. Otherwise the derived tokens are tried in
# order and the search stops at the first one backed by real evidence
# (artifact/bundle). A token-only hit is remembered but not settled for until
# every candidate has had its turn, so "the third guess actually names this
# app's bundle" beats "the first guess resolved to something".
migration_candidate_for_app() {
    local app_name="$1" app_path="$2" bundle_id="$3"
    local token override evidence json_file
    local weak_token="" weak_file=""

    if override=$(migration_token_override "$app_name"); then
        json_file="$(mktemp "${TMPDIR:-/tmp}/msu_cask.XXXXXX")" || return 1
        if migration_cask_fetch "$override" "$json_file"; then
            print -r -- "${override}|override|${json_file}"
            return 0
        fi
        rm -f "$json_file"
        return 1
    fi

    for token in ${(f)"$(migration_token_candidates "$app_name")"}; do
        [[ -n "$token" ]] || continue

        json_file="$(mktemp "${TMPDIR:-/tmp}/msu_cask.XXXXXX")" || continue
        if ! migration_cask_fetch "$token" "$json_file"; then
            rm -f "$json_file"
            continue
        fi

        evidence=$(migration_match_evidence "$json_file" "$app_path" "$bundle_id")
        if [[ "$evidence" != "token" ]]; then
            [[ -n "$weak_file" ]] && rm -f "$weak_file"
            print -r -- "${token}|${evidence}|${json_file}"
            return 0
        fi

        if [[ -z "$weak_token" ]]; then
            weak_token="$token"
            weak_file="$json_file"
        else
            rm -f "$json_file"
        fi
    done

    if [[ -n "$weak_token" ]]; then
        print -r -- "${weak_token}|token|${weak_file}"
        return 0
    fi

    return 1
}

# Every application bundle worth considering, one path per line: the two
# directories a Mac keeps applications in, each one level deep as well, which
# is how collect_app_updates walks /Applications.
#
# Its own function so the scan can be exercised against a fixture directory
# instead of whatever happens to be installed on the machine running the tests
# - the set of apps in /Applications is the one input a test can neither
# control nor depend on.
migration_app_paths() {
    print -rl -- /Applications/*.app(N) /Applications/*/*.app(N) \
                 "$HOME"/Applications/*.app(N) "$HOME"/Applications/*/*.app(N)
}

# Every application that is not managed by Homebrew but could be, one per line:
#
#   v1|app_name|app_path|bundle_id|installed_version|token|cask_version|match|state|homepage
#
# Detection only - see the file header. The expensive part is one 'brew info'
# per candidate token, which is why this is never part of a background tier.
#
# 'no_err_exit' for the same reason collect_cache_data has it: this is called
# through cache_refresh_entry from paths that enable 'set -e', where one
# unreadable plist or one unreachable brew call would abort the whole scan
# instead of skipping the app it belongs to.
migration_scan() {
    setopt local_options no_err_exit

    local app_path app_name bundle_id installed_ver
    local candidate token match json_file cask_version homepage state
    local cask_line=""
    local result=""

    # Installed cask tokens, for the "already managed" check - the same source
    # collect_app_updates reads it from.
    typeset -gA INSTALLED_CASK_TOKENS
    INSTALLED_CASK_TOKENS=()
    for cask_line in "${(@f)$(cache_get "brew_casks")}"; do
        [[ -n "$cask_line" ]] && INSTALLED_CASK_TOKENS[${cask_line%% *}]=1
    done

    for app_path in ${(f)"$(migration_app_paths)"}; do
        [[ -n "$app_path" ]] || continue
        app_name="${${app_path:t}%.app}"

        # Setapp manages its own catalogue; handing one of its copies to
        # Homebrew breaks Setapp's bookkeeping for it.
        [[ "$app_path" == /Applications/Setapp/* ]] && continue

        # App Store apps are updated through the App Store, and a cask
        # installed over one loses the receipt that makes that work.
        [[ -d "$app_path/Contents/_MASReceipt" ]] && continue

        bundle_id=$(plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier) || bundle_id=""

        # Apple's own apps ship with the OS and have no cask at all
        [[ "$bundle_id" == com.apple.* ]] && continue

        # Already a cask: there is nothing to migrate
        app_is_brew_managed "$app_name" && continue

        # The ignore list, under the key that means "this application" rather
        # than "this package": "sparkle" is what the app scan and the menu
        # already use for an app-name-keyed entry, so an app the user silenced
        # there stays silent here too. "migrate" is honoured as well, for an
        # entry that hides the migration offer without also hiding the app's
        # own updates.
        is_ignored "sparkle" "$app_name" && continue
        is_ignored "migrate" "$app_name" && continue

        candidate=$(migration_candidate_for_app "$app_name" "$app_path" "$bundle_id") || continue
        token="${${(@s:|:)candidate}[1]}"
        match="${${(@s:|:)candidate}[2]}"
        json_file="${${(@s:|:)candidate}[3]}"

        installed_ver=$(plist_value "$app_path/Contents/Info.plist" CFBundleShortVersionString) || installed_ver=""
        cask_version=$(migration_json_field "$json_file" "casks.0.version")
        homepage=$(migration_json_field "$json_file" "casks.0.homepage")
        [[ "$homepage" == https://* ]] || homepage=""
        state=$(migration_state "$json_file" "$app_path")

        rm -f "$json_file"

        result+="${MIGRATION_FORMAT_VERSION}"
        result+="|$(migration_clean_field "$app_name")"
        result+="|$(migration_clean_field "$app_path")"
        result+="|$(migration_clean_field "$bundle_id")"
        result+="|$(migration_clean_field "$installed_ver")"
        result+="|$(migration_clean_field "$token")"
        result+="|$(migration_clean_field "$cask_version")"
        result+="|${match}|${state}"
        result+="|$(migration_clean_field "$homepage")"
        result+=$'\n'
    done

    print -rn -- "$result"
    return 0
}

# The recorded candidate line for an app, from the last scan. Empty when the
# app was never scanned - which is not an error: migrate_to_cask re-derives
# everything it acts on anyway, and only uses this for the app's path.
migration_candidate_line() {
    local wanted="$1" line
    for line in ${(f)"$(cache_get "$MIGRATION_CACHE_KEY")"}; do
        [[ -n "$line" ]] || continue
        [[ "${${(@s:|:)line}[2]}" == "$wanted" ]] || continue
        print -r -- "$line"
        return 0
    done
    return 1
}

# Where an application actually is: what the last scan recorded, otherwise the
# two places this project looks for a bundle.
migration_app_path() {
    local app_name="$1" line="" recorded=""

    if line=$(migration_candidate_line "$app_name"); then
        recorded="${${(@s:|:)line}[3]}"
        [[ -d "$recorded" ]] && { print -r -- "$recorded"; return 0; }
    fi

    [[ -d "/Applications/${app_name}.app" ]] && { print -r -- "/Applications/${app_name}.app"; return 0; }
    [[ -d "$HOME/Applications/${app_name}.app" ]] && { print -r -- "$HOME/Applications/${app_name}.app"; return 0; }

    return 1
}

# ------------------------------------------------------------------------------
# MIGRATING
# ------------------------------------------------------------------------------

# Move a bundle aside. No sudo - see the file header.
migration_backup() {
    local app_path="$1" backup_path="$2"

    rm -rf "$backup_path" 2>/dev/null || true
    mv "$app_path" "$backup_path" 2>/dev/null || return 1
    return 0
}

# Put a moved-aside bundle back where it was, over whatever a failed install
# left behind.
migration_restore() {
    local app_path="$1" backup_path="$2"

    [[ -d "$backup_path" ]] || return 1
    [[ -e "$app_path" ]] && rm -rf "$app_path" 2>/dev/null
    mv "$backup_path" "$app_path" 2>/dev/null || return 1
    return 0
}

# Hand one application over to Homebrew.
#
# Usage: migrate_to_cask <app_name> <token> <mode>
#   dry      run 'brew install --cask --adopt --dry-run' and report what it
#            says. Nothing is quit, nothing is moved, nothing is installed.
#   adopt    'brew install --cask --adopt'. Homebrew takes over the bundle that
#            is already there instead of downloading a replacement, and when it
#            will not, it says so and leaves the target untouched - so a failed
#            adopt costs nothing but the attempt. This is the default.
#   replace  the move-aside-and-reinstall path from setup_mac.sh's
#            migrate_app_to_cask: back the bundle up, drop Homebrew's stale
#            metadata, install fresh, and put the backup back if the install
#            fails. This is the only destructive path here and it is NEVER
#            reached by falling out of a failed adopt - the caller has to ask
#            for it, because "adopt refused" usually means the installed copy
#            and the cask's copy are genuinely different, and only the user can
#            say whether replacing theirs is acceptable.
#
# Returns 0 when the app ended up under Homebrew management, non-zero
# otherwise. Every path files a result record (CACHE_FORMAT.md, "Single-item
# run results") under kind "migrate" so the row that asked for this learns the
# outcome from the run itself rather than by guessing from a list afterwards.
migrate_to_cask() {
    setopt local_options no_err_exit

    local app_name="$1" token="$2" mode="${3:-adopt}"
    local app_path json_file state was_running=0
    local backup_path installed_ver cask_version adopt_reason

    if [[ -z "$app_name" || -z "$token" ]]; then
        echo "❌ Migration needs an application name and a cask token." >&2
        return 1
    fi

    case "$mode" in
        dry|adopt|replace) ;;
        *)
            echo "❌ Unknown migration mode: $mode (expected dry, adopt or replace)." >&2
            return 1
            ;;
    esac

    if ! app_path=$(migration_app_path "$app_name"); then
        echo "❌ No application bundle found for $app_name." >&2
        result_write "migrate" "$token" "$app_name" "fail" "cask-not-found"
        return 1
    fi

    # Re-derived from a fresh 'brew info' rather than taken from the scan's
    # cache entry: the cache may be days old, and the decision about to be
    # made writes to /Applications.
    json_file="$(mktemp "${TMPDIR:-/tmp}/msu_migrate.XXXXXX")" || return 1
    if ! migration_cask_fetch "$token" "$json_file"; then
        rm -f "$json_file"
        echo "❌ No cask named '$token' exists." >&2
        result_write "migrate" "$token" "$app_name" "fail" "cask-not-found"
        return 1
    fi

    state=$(migration_state "$json_file" "$app_path")
    cask_version=$(migration_json_field "$json_file" "casks.0.version")
    installed_ver=$(plist_value "$app_path/Contents/Info.plist" CFBundleShortVersionString) || installed_ver=""
    rm -f "$json_file"

    echo "🔎 $app_name -> cask '$token' ($state)"

    # The three states nothing can be done about, refused before any mode runs
    # - including the dry run, since telling the user "nothing would happen" is
    # exactly what they asked it for.
    case "$state" in
        "no-app-artifact")
            echo "❌ The cask '$token' installs no application bundle (it is a pkg or installer cask)." >&2
            echo "   There is nothing for Homebrew to adopt, so $app_name cannot be migrated." >&2
            migration_report "$app_name" "$token" "$mode" "fail" "no-app-artifact" "$installed_ver" "$cask_version"
            return 1
            ;;
        "needs-root")
            echo "❌ Installing '$token' requires administrator rights, which this toolkit will not ask for." >&2
            echo "   Install it yourself with: brew install --cask $token" >&2
            migration_report "$app_name" "$token" "$mode" "fail" "needs-root" "$installed_ver" "$cask_version"
            return 1
            ;;
        "target-mismatch")
            echo "❌ The cask installs to a different location than $app_path." >&2
            echo "   Migrating would leave a second copy behind instead of taking this one over." >&2
            migration_report "$app_name" "$token" "$mode" "fail" "target-mismatch" "$installed_ver" "$cask_version"
            return 1
            ;;
    esac

    if [[ "$mode" == "dry" ]]; then
        echo "🧪 DRY RUN - asking Homebrew what it would do, changing nothing."
        if brew install --cask --adopt --dry-run "$token"; then
            migration_report "$app_name" "$token" "$mode" "ok" "" "$installed_ver" "$cask_version"
            return 0
        fi
        # A dry run that fails is the answer, not an accident: report it under
        # the state that predicted it so the wording can say which.
        if [[ "$state" == "version-mismatch" ]]; then
            migration_report "$app_name" "$token" "$mode" "fail" "adopt-version-mismatch" "$installed_ver" "$cask_version"
        else
            migration_report "$app_name" "$token" "$mode" "fail" "install-failed" "$installed_ver" "$cask_version"
        fi
        return 1
    fi

    # Homebrew moves the bundle out from under a running app either way, and a
    # process still holding its old executable is how a half-migrated app ends
    # up crashing minutes later.
    app_running "$app_path" && was_running=1
    quit_running_app "$app_path"

    if [[ "$mode" == "adopt" ]]; then
        echo "📦 Adopting the existing installation (no re-download)..."
        if brew install --cask --adopt "$token"; then
            echo "✅ $app_name is now managed by Homebrew as '$token'."
            migration_finish "$app_name" "$token" "$mode" "ok" "" "$installed_ver" "$cask_version" "$was_running" "$app_path"
            return 0
        fi

        # Nothing was moved: a refused adopt leaves the target exactly as it
        # was, which is the whole reason this is the default mode.
        if [[ "$state" == "version-mismatch" ]]; then
            echo "❌ Homebrew refused to adopt: the installed copy is not the version the cask ships." >&2
            echo "   Nothing was changed. A replace would install the cask's version instead." >&2
            adopt_reason="adopt-version-mismatch"
        else
            echo "❌ Homebrew could not adopt $app_name. Nothing was changed." >&2
            adopt_reason="install-failed"
        fi
        migration_finish "$app_name" "$token" "$mode" "fail" "$adopt_reason" "$installed_ver" "$cask_version" "$was_running" "$app_path"
        return 1
    fi

    # --- replace ---
    backup_path="${app_path}.msu-migrate-backup"

    echo "🗄️ Backing up $app_name..."
    if ! migration_backup "$app_path" "$backup_path"; then
        echo "❌ Could not move $app_path aside (permissions?). Nothing was changed." >&2
        migration_finish "$app_name" "$token" "$mode" "fail" "install-failed" "$installed_ver" "$cask_version" "$was_running" "$app_path"
        return 1
    fi

    # Stale metadata from an earlier install would make Homebrew treat this as
    # an upgrade of something it no longer has on disk
    if brew list --cask "$token" &>/dev/null; then
        echo "🧹 Removing stale Homebrew metadata for '$token'..."
        brew uninstall --cask "$token" 2>/dev/null || true
    fi

    echo "⬇️ Installing '$token' via Homebrew..."
    if brew install --cask "$token"; then
        echo "✅ $app_name is now managed by Homebrew as '$token'."
        rm -rf "$backup_path" 2>/dev/null || true
        migration_finish "$app_name" "$token" "$mode" "ok" "" "$installed_ver" "$cask_version" "$was_running" "$app_path"
        return 0
    fi

    echo "❌ The Homebrew installation failed. Restoring the original application..." >&2
    if migration_restore "$app_path" "$backup_path"; then
        echo "↩️ $app_name was restored. Nothing changed." >&2
        migration_finish "$app_name" "$token" "$mode" "fail" "restored-after-failure" "$installed_ver" "$cask_version" "$was_running" "$app_path"
    else
        echo "⚠️ The original could not be restored automatically. It is at:" >&2
        echo "   $backup_path" >&2
        migration_finish "$app_name" "$token" "$mode" "fail" "install-failed" "$installed_ver" "$cask_version" "$was_running" "$app_path"
    fi
    return 1
}

# --- TERMINAL-MODE MIGRATION ---
# `update_system.1h.sh run migrate <app> <token> [mode]`, which is what the
# `migrate_app_in_terminal` action launches through launch_in_terminal_or_report
# (that helper always builds "<script> run <args...>", so a terminal migration
# has to arrive as a run mode like install and single do).
#
# The whole point of it is the tty: `migrate_to_cask` deliberately never runs
# sudo, because the headless path has nowhere to prompt - but Homebrew itself
# may still need a password to write over a root-owned bundle, and in a real
# terminal window it has somewhere to ask. Same work, somewhere the user can
# answer.
#
# IMPORTANT: reads the script's own positional parameters ($3, $4, $5), so the
# dispatcher MUST call it as `run_mode_migrate "$@"` - see the note at the top
# of lib/run_modes.sh for why a bare call would silently blank them.
run_mode_migrate() {
    local app_name="$3" token="$4" mode="${5:-adopt}"

    if [[ -z "$app_name" || -z "$token" ]]; then
        echo "❌ No application and cask token given to migrate." >&2
        sleep 3
        exit 1
    fi

    # This run owns the shared progress file: unlike the headless path it was
    # not started with GUIDEAPP_NO_SHARED_PROGRESS, because a terminal
    # migration is single-flight and is exactly the one thing the banner
    # should be naming. The dispatcher's EXIT trap resolves the entry from the
    # exit status below.
    progress_write "running" "migrate" "$app_name" "" ""

    echo "🚀 Moving $app_name to Homebrew..."
    echo "---------------------------"

    migrate_to_cask "$app_name" "$token" "$mode" || {
        echo "---------------------------"
        echo "❌ $app_name could not be moved." >&2
        sleep 5
        exit 1
    }

    echo "---------------------------"
    echo "Done!"
    sleep 2
    exit 0
}

# The record every ending goes through: history first, then the run's own
# result record, in the order run_mode_single uses and for the same reasons.
#
# A dry run writes no history entry - it changed nothing, and the log is a log
# of changes - but it DOES write a result record, unlike run_mode_install's dry
# path. The difference is who is waiting: GuideApp fires an install dry run
# fire-and-forget with no row attached, while a migration dry run IS the answer
# the user asked for and something has to carry it back.
migration_report() {
    local app_name="$1" token="$2" mode="$3" state="$4" reason="$5"
    local old_ver="${6:-?}" new_ver="${7:-?}"
    local timestamp

    if [[ "$mode" != "dry" ]]; then
        timestamp=$(date +%s)
        # Format: timestamp|source|name|old_ver|new_ver|id|status|reason
        if echo "$timestamp|migrate|$app_name|${old_ver:-?}|${new_ver:-?}|$token|$state|$reason" >> "$HISTORY_FILE"; then
            trim_history_log
            echo "📝 Added to history log ($state)."
        fi
    fi

    result_write "migrate" "$token" "$app_name" "$state" "$reason"
    return 0
}

# Everything a finished live migration owes its caller, in the one order that
# works: refresh this item's cache entries FIRST, so a reader taking the result
# record as "now go look at the installed list" finds the app already listed as
# a cask, then file the record. Same ordering, same reasoning, as
# run_mode_single.
migration_finish() {
    local app_name="$1" token="$2" mode="$3" state="$4" reason="$5"
    local old_ver="$6" new_ver="$7" was_running="$8" app_path="$9"

    # Only on success: a failed migration changed nothing, and re-running two
    # brew queries to confirm that is time the row spends waiting.
    if [[ "$state" == "ok" ]]; then
        echo "🗂️ Refreshing cached data..."
        collect_cache_for_item "cask" "$token"
    fi

    migration_report "$app_name" "$token" "$mode" "$state" "$reason" "$old_ver" "$new_ver"

    if (( was_running )); then
        echo "   Restarting $app_name..."
        sleep 1
        open -a "$app_name" 2>/dev/null || echo "   Could not restart $app_name automatically."
    fi

    return 0
}
