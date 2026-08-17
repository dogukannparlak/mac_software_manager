#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.5.0</bitbar.version>
# <bitbar.author>YOUR_NAME</bitbar.author>
# <bitbar.author.github>dogukannparlak</bitbar.author.github>
# <bitbar.desc>Monitors Homebrew and App Store updates, tracks history and stats.</bitbar.desc>
# <bitbar.dependencies>brew,mas</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/dogukannparlak/mac_software_manager</bitbar.abouturl>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>

# ==============================================================================
# 1. GLOBAL CONFIGURATION
# ==============================================================================
SCRIPT_FILE="${0:a}"
autoload -Uz is-at-least
zmodload zsh/datetime
# -F b:zstat loads ONLY the zstat builtin: plain 'zmodload zsh/stat' would also
# define a 'stat' builtin that shadows /usr/bin/stat for the rest of the script.
zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/system 2>/dev/null

# Set standard locale to avoid parsing errors with grep or sort on different system languages
export LC_ALL=C
# Suppress mas CLI Spotlight auto-indexing warning
export MAS_NO_AUTO_INDEX=1
# Never let a read-only query (brew outdated/list) trigger an implicit 'brew update'.
# The update flow calls 'brew update' explicitly when it actually needs fresh metadata.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
umask 077

# Extract version from the first 5 lines of a file, defaults to "Unknown"
extract_version() {
    if [[ ! -f "$1" ]]; then echo "Unknown"; return 1; fi
    local ver=$(head -n 5 "$1" | grep --color=never "<bitbar.version>" | sed 's/.*<bitbar.version>\(.*\)<\/bitbar.version>.*/\1/' | tr -d 'v \n\r')
    echo "${ver:-Unknown}"
}

# Paths
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
HISTORY_FILE="$APP_DIR/update_history.log"
CONFIG_FILE="$APP_DIR/settings.conf"
ETAG_FILE="$APP_DIR/.plugin_etag"
PENDING_FLAG="$APP_DIR/.plugin_update_pending"
IGNORED_FILE="$APP_DIR/ignored_apps.conf"
TRACKED_APPS_FILE="$APP_DIR/tracked_apps.conf"
CACHE_DIR="$APP_DIR/cache"
LOCK_DIR="$APP_DIR/locks"

# Ensure directories exist
mkdir -p "$APP_DIR" "$CACHE_DIR" "$LOCK_DIR"
chmod 700 "$APP_DIR" 2>/dev/null || true

typeset -a CONFIG_WARNINGS

add_config_warning() {
    local warning="$1"
    (( ${CONFIG_WARNINGS[(Ie)$warning]} == 0 )) && CONFIG_WARNINGS+=("$warning")
}

# Validate and load configuration safely
load_config_safely() {
    [[ ! -f "$CONFIG_FILE" ]] && return 0

    local raw_line trimmed_line key value line_no=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        ((line_no++))
        trimmed_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

        [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]] && continue

        if ! printf '%s\n' "$trimmed_line" | grep -qE '^[A-Z_]+="[^"]*"$'; then
            add_config_warning "Invalid config syntax on line $line_no."
            continue
        fi

        key="${trimmed_line%%=*}"
        value="${trimmed_line#*=}"
        value="${value#\"}"
        value="${value%\"}"

        case "$key" in
            "PREFERRED_TERMINAL")
                case "$value" in
                    "Terminal"|"iTerm2"|"Warp"|"Alacritty"|"Ghostty")
                        PREFERRED_TERMINAL="$value"
                        ;;
                    *)
                        add_config_warning "Invalid PREFERRED_TERMINAL value. Using default."
                        ;;
                esac
                ;;
            "MAS_ENABLED")
                case "$value" in
                    "0"|"1")
                        MAS_ENABLED="$value"
                        ;;
                    *)
                        add_config_warning "Invalid MAS_ENABLED value. Using default."
                        ;;
                esac
                ;;
            "UPDATE_BRANCH")
                if printf '%s\n' "$value" | grep -qE '^[A-Za-z0-9._/-]+$'; then
                    UPDATE_BRANCH="$value"
                else
                    add_config_warning "Invalid UPDATE_BRANCH value. Using default."
                fi
                ;;
            "AUTOSTART")
                AUTOSTART="$value"
                ;;
            "AUTO_INSTALL_APPS")
                case "$value" in
                    "0"|"1")
                        AUTO_INSTALL_APPS="$value"
                        ;;
                    *)
                        add_config_warning "Invalid AUTO_INSTALL_APPS value. Using default."
                        ;;
                esac
                ;;
            "CLEANUP_ENABLED")
                case "$value" in
                    "0"|"1")
                        CLEANUP_ENABLED="$value"
                        ;;
                    *)
                        add_config_warning "Invalid CLEANUP_ENABLED value. Using default."
                        ;;
                esac
                ;;
            *)
                add_config_warning "Unknown config key '$key' ignored."
                ;;
        esac
    done < "$CONFIG_FILE"
}

# Load configuration
PREFERRED_TERMINAL="Terminal"  # Default to Apple Terminal
MAS_ENABLED="1"
UPDATE_BRANCH="main"
# 'brew cleanup --prune=all' deletes every cached download and old version.
# It frees a lot of disk but makes downgrading impossible without re-downloading,
# so it has to be switchable.
CLEANUP_ENABLED="1"
# Replacing a running application is the riskiest thing this tool can do, so it
# is opt-in. When off, self-updating apps only ever get a download link.
AUTO_INSTALL_APPS="0"
load_config_safely

# Extract version dynamically from the first 5 lines of the script. Needed for User-Agent and About
VERSION=$(extract_version "$SCRIPT_FILE")

# Failover & Network Config
# TODO: no Codeberg mirror set up yet - fill in YOUR_CODEBERG_USERNAME below
# once you have one, or remove the backup path entirely.
URL_PRIMARY_BASE="https://raw.githubusercontent.com/dogukannparlak/mac_software_manager/$UPDATE_BRANCH"
URL_BACKUP_BASE="https://codeberg.org/YOUR_CODEBERG_USERNAME/mac_software_manager/raw/branch/$UPDATE_BRANCH"
USER_AGENT="MacSoftwareUpdater/$VERSION"
PROJECT_URL="https://github.com/dogukannparlak/mac_software_manager"
PROJECT_URL_CB="https://codeberg.org/YOUR_CODEBERG_USERNAME/mac_software_manager"

# Colors (Light/Dark mode support)
# Format: COLOR_LIGHT,COLOR_DARK
# SwiftBar automatically switches between these based on system theme WITHOUT needing a refresh.
# Text Color: Almost Black for Light Mode, Light Gray for Dark Mode
COLOR_INFO="#333333,#B0B0B0"
# Success (Green): Deep Emerald for Light, Neon Green for Dark
COLOR_SUCCESS="#007A33,#32D74B"
# Warning (Red): Deep Red for Light, Bright Red for Dark
COLOR_WARN="#D70015,#FF453A"
# Purple: Deep Indigo for Light, Pastel Purple for Dark
COLOR_PURPLE="#5856D6,#BF5AF2"
# Blue: Deep Blue for Light, Sky Blue for Dark
COLOR_BLUE="#0040DD,#54A0FF"

# Set the path to Homebrew environment
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi

# ==============================================================================
# 2. PRE-FLIGHT CHECKS
# ==============================================================================

if ! command -v brew &> /dev/null; then
    if [[ "$1" == "run" ]]; then
        echo "❌ Error: Homebrew is not installed!"
        read -k1
        exit 1
    fi
    echo "⚠️ Brew Missing | color=red"
    echo "---"
    echo "Homebrew is strictly required | color=red"
    exit 0
fi

# ==============================================================================
# 3. HELPER FUNCTIONS
# ==============================================================================

# Escape strings for SwiftBar param usage
# Escapes single quotes in a string to ensure safe usage within SwiftBar parameters.
# This function replaces every single quote with a sequence that remains valid when wrapped in shell commands.
# Necessary for handling file paths or arguments containing special characters to prevent syntax breakage in the menu.
swiftbar_sq_escape() {
  # Build the ' -> '\'' replacement from single characters. Writing it as a
  # backslash escape inside the substitution silently produced the wrong string
  # (it only ever ran on quote-free script paths, so it went unnoticed).
  local q="'"
  local bs='\'
  local rep="${q}${bs}${q}${q}"
  print -r -- "${1//$q/$rep}"
}

# Escape a string for use inside an AppleScript double-quoted literal.
# App names reach 'display dialog' and 'display notification' directly, and a
# quote in a name (or a crafted cask token) would otherwise end the literal and
# let the rest of the string run as AppleScript.
# Backslashes must be doubled first, otherwise the escaping of quotes is undone.
applescript_escape() {
  local escaped="${1//\\/\\\\}"
  print -r -- "${escaped//\"/\\\"}"
}

# ------------------------------------------------------------------------------
# 3a. LOCKING
# ------------------------------------------------------------------------------
# Advisory file lock via zsh/system flock. The descriptor stays open for the
# lifetime of the process, so the lock is released automatically on exit
# (including crashes) - no stale lock files to clean up.
# Usage: acquire_lock "<name>" [timeout_seconds]  (default 0 = try once)
acquire_lock() {
    local name="$1"
    local timeout="${2:-0}"
    local lock_file="$LOCK_DIR/${name}.lock"
    local fd_var="LOCK_FD_${name:gs/-/_}"

    # zsh/system may be unavailable on exotic setups: degrade to "no locking"
    (( $+builtins[zsystem] )) || return 0

    : > "$lock_file" 2>/dev/null || return 1
    zsystem flock -t "$timeout" -f "$fd_var" "$lock_file" 2>/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
# 3b. CACHE LAYER
# ------------------------------------------------------------------------------
# The menu render path NEVER shells out to brew/mas/curl. It reads these cache
# files and, when they are stale, spawns a detached background refresh.
# Two tiers, because installed lists change far less often than pending updates.
CACHE_TTL_UPDATES=3600     # brew outdated / mas outdated / iTunes lookups
CACHE_TTL_INSTALLED=21600  # brew list / mas list / pinned formulae
CACHE_TTL_APPS=21600       # one HTTP request per self-updating app: keep it rare
CACHE_TTL_WEBSITES=86400   # a homepage practically never changes; check once a day

# Keys per tier (used by the refresh action and the staleness check)
typeset -a CACHE_KEYS_UPDATES CACHE_KEYS_INSTALLED CACHE_KEYS_APPS CACHE_KEYS_WEBSITES
CACHE_KEYS_UPDATES=(brew_outdated mas_outdated manual_updates)
CACHE_KEYS_INSTALLED=(brew_pinned brew_casks brew_formulae mas_list brew_status)
CACHE_KEYS_APPS=(app_updates)
CACHE_KEYS_WEBSITES=(cask_homepages github_homepages)

# Modification time of a cache entry in epoch seconds (0 when missing)
cache_mtime() {
    local -a st
    zstat -A st +mtime "$CACHE_DIR/$1" 2>/dev/null || { print -r -- 0; return; }
    print -r -- "${st[1]}"
}

# True when the entry exists and is younger than the given TTL
cache_fresh() {
    local key="$1" ttl="$2"
    [[ -f "$CACHE_DIR/$key" ]] || return 1
    local mtime=$(cache_mtime "$key")
    (( mtime > 0 )) || return 1
    (( (EPOCHSECONDS - mtime) < ttl ))
}

cache_get() {
    [[ -f "$CACHE_DIR/$1" ]] || return 1
    cat "$CACHE_DIR/$1"
}

# Atomic write so a half-finished refresh can never be read as complete data
cache_put() {
    local key="$1"
    local tmp="$CACHE_DIR/.${key}.$$"
    print -r -- "$2" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$CACHE_DIR/$key" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Refresh a single entry by running a command and storing its stdout.
# If the command fails (e.g. 'brew list --cask' aborting on an untrusted tap)
# the previous value is kept instead of blanking the menu - but it is restamped
# so the TTL clock restarts and the render path does not respawn a refresh loop.
cache_refresh_entry() {
    local key="$1"
    shift
    local output rc=0

    output=$("$@" 2>/dev/null) || rc=$?

    if (( rc != 0 )) && [[ -f "$CACHE_DIR/$key" ]]; then
        touch "$CACHE_DIR/$key"
        return 1
    fi

    cache_put "$key" "$output"
}

# Newest timestamp across the update tier: what "Last check" actually means
cache_last_check() {
    local newest=0 key mtime
    for key in "${CACHE_KEYS_UPDATES[@]}"; do
        mtime=$(cache_mtime "$key")
        (( mtime > newest )) && newest=$mtime
    done
    print -r -- "$newest"
}

# Which tiers need refreshing? Prints any of: updates installed sparkle
cache_stale_tiers() {
    local key tier_stale=0
    for key in "${CACHE_KEYS_UPDATES[@]}"; do
        cache_fresh "$key" "$CACHE_TTL_UPDATES" || tier_stale=1
    done
    (( tier_stale )) && print -r -- "updates"

    tier_stale=0
    for key in "${CACHE_KEYS_INSTALLED[@]}"; do
        cache_fresh "$key" "$CACHE_TTL_INSTALLED" || tier_stale=1
    done
    (( tier_stale )) && print -r -- "installed"

    tier_stale=0
    for key in "${CACHE_KEYS_APPS[@]}"; do
        cache_fresh "$key" "$CACHE_TTL_APPS" || tier_stale=1
    done
    (( tier_stale )) && print -r -- "apps"

    tier_stale=0
    for key in "${CACHE_KEYS_WEBSITES[@]}"; do
        cache_fresh "$key" "$CACHE_TTL_WEBSITES" || tier_stale=1
    done
    (( tier_stale )) && print -r -- "websites"
}

# Fire-and-forget background refresh. Detached so SwiftBar does not wait on it;
# refresh_cache itself takes a non-blocking lock, so extra spawns are harmless.
spawn_cache_refresh() {
    nohup "$SCRIPT_FILE" refresh_cache "${1:-auto}" >/dev/null 2>&1 &!
}

# ------------------------------------------------------------------------------
# 3b2. PROGRESS REPORTING
# ------------------------------------------------------------------------------
# An update run happens in a terminal window, but the menu bar should still be
# able to say what is going on right now. The run writes a single line here and
# any interested reader polls it.
#
# Format:  state|phase|item|index|total
#   state = running | done | failed
#   phase = a stable token the reader translates (brew-update, brew-upgrade,
#           mas-upgrade, verify, cleanup, install-app, refresh)
#   item  = package or application currently being worked on, may be empty
PROGRESS_FILE="$CACHE_DIR/progress"

progress_write() {
    local state="$1" phase="$2" item="${3:-}" index="${4:-}" total="${5:-}"
    local tmp="$PROGRESS_FILE.$$"
    print -r -- "${state}|${phase}|${item}|${index}|${total}" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$PROGRESS_FILE" 2>/dev/null || rm -f "$tmp"
}

# Runs on exit so a run that stops early - a failed integrity check, Ctrl-C,
# "nothing to do" - never leaves a reader believing work is still in progress.
progress_finalize() {
    [[ -f "$PROGRESS_FILE" ]] || return 0
    local recorded
    recorded=$(<"$PROGRESS_FILE") 2>/dev/null || return 0
    [[ "${recorded%%|*}" == "running" ]] && progress_write "done" "complete" "" "" ""
    return 0
}

# Passes a command's output straight through while watching for the lines
# Homebrew prints when it starts on a new package, so progress stays accurate
# without upgrading packages one at a time (which would be much slower).
progress_tap() {
    local phase="$1" total="${2:-}"
    local line item index=0
    while IFS= read -r line; do
        # Keep the terminal output exactly as it was
        print -r -- "$line" > /dev/tty 2>/dev/null || true

        case "$line" in
            "==> Upgrading "*|"==> Installing "*)
                # "==> Upgrading awscli 2.36.19 -> 2.36.24" becomes "awscli"
                item="${${line#==> }#* }"
                item="${item%% *}"
                (( ++index ))
                progress_write "running" "$phase" "$item" "$index" "$total"
                ;;
        esac

        # And still hand it to the caller for parsing
        print -r -- "$line"
    done
}

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
    for line in "${(@f)$(mas outdated 2>/dev/null || true)}"; do
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

typeset -A IGNORED_APPS_MAP

# Load to memory ignored apps
load_ignored_cache() {
    IGNORED_APPS_MAP=()
    if [[ -f "$IGNORED_FILE" ]]; then
        # Read type, id AND name
        while IFS='|' read -r type id name || [[ -n "$type" ]]; do
            # Aggressive cleaning for type keeps only alphanumeric characters
            # Removes BOM spaces non breaking spaces tabs
            local clean_type=$(echo "$type" | tr -cd '[:alnum:]')

            # ID sanitising depends on the source. App Store IDs are numeric,
            # but cask tokens ("cursor") and Sparkle app names ("AltTab") are
            # not: stripping everything non-numeric silently dropped every
            # cask entry, so "Ignore" never took effect for casks.
            # Note the explicit ="": a bare 'local x' on a name that already
            # holds a value makes zsh echo "x=value", which would corrupt the
            # menu output on the second loop iteration.
            local clean_id=""
            if [[ "$clean_type" == "mas" ]]; then
                clean_id=$(echo "$id" | tr -cd '0-9')
            else
                clean_id=$(echo "$id" | tr -d '\r\n|' | tr -cd '[:alnum:] ._@+-')
                # Trim surrounding whitespace
                clean_id="${clean_id#"${clean_id%%[![:space:]]*}"}"
                clean_id="${clean_id%"${clean_id##*[![:space:]]}"}"
            fi

            # Skip invalid lines
            [[ -z "$clean_type" || -z "$clean_id" ]] && continue

            # Key is type pipe id
            local clean_key="${clean_type}|${clean_id}"

            # Value in the map is now the NAME stripped of newlines
            local clean_name=$(echo "${name:-$id}" | tr -d '\r\n')

            IGNORED_APPS_MAP[$clean_key]="$clean_name"
        done < "$IGNORED_FILE"
    fi
}

# Check if an app is ignored (cask or mas)
# Usage: is_ignored "type" "identifier"
is_ignored() {
    # Check if value exists for key using string test instead of arithmetic
    [[ -n "${IGNORED_APPS_MAP[$1|$2]}" ]]
}

load_ignored_cache

# Add app to ignore list (Supports: type|id|name)
add_ignored() {
    local type="$1" id="$2" name="${3:-$id}"
    # Remove pipes from name to prevent parsing errors
    name="${name//|/}"
    if ! is_ignored "$type" "$id"; then
        echo "${type}|${id}|${name}" >> "$IGNORED_FILE"
    fi
}

# Remove app from ignore list (Matches type|id ONLY)
remove_ignored() {
    local type="$1"
    local id="$2"
    # Delete line starting with type|id followed by pipe or EOL
    # This ensures strict matching of ID regardless of whether a name suffix exists
    [[ -f "$IGNORED_FILE" ]] && sed -i '' -E "/^${type}\|${id}(\||$)/d" "$IGNORED_FILE"
}

# Launch update script in the configured terminal app
launch_in_terminal() {
    local script_path="$1"
    shift
    local args=("${@:-all}")
    local terminal="${PREFERRED_TERMINAL:-Terminal}"

    local cmd="${(qq)script_path} run ${(@qq)args}"

    case "$terminal" in
        "iTerm2")
            # iTerm2 using AppleScript
            if [[ -d "/Applications/iTerm.app" ]]; then
                osascript <<EOF
tell application "iTerm"
    if not application "iTerm" is running then
        launch
    end if
    create window with default profile command "$cmd"
    activate
end tell
EOF
            else
                osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
            fi
            ;;
        "Warp")
            # Warp terminal
            if [[ -d "/Applications/Warp.app" ]]; then
                # Force focus first
                osascript -e 'tell application "Warp" to activate'
                # Warp accepts args naturally, but constructing a clean command string is safer
                open -a Warp "$script_path" --args run "${args[@]}"
                osascript -e 'tell application "Warp" to activate'
            else
                osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
            fi
            ;;
        "Alacritty")
            # Alacritty terminal
            if [[ -d "/Applications/Alacritty.app" ]]; then
                # Force focus first
                osascript -e 'tell application "Alacritty" to activate'
                open -a Alacritty --args -e zsh -c "$cmd; exec zsh"
                osascript -e 'tell application "Alacritty" to activate'
            else
			    # Fallback to Terminal
                osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
            fi
            ;;
        "Ghostty")
            # Ghostty terminal
            if [[ -d "/Applications/Ghostty.app" ]]; then
                open -na Ghostty --args -e zsh -c "$cmd; exec zsh"
            else
			    # Fallback to Terminal
                osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
            fi
            ;;
        *)
            osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
            ;;
    esac
}

# Download with Failover (GitHub -> Codeberg)
# Usage: download_with_failover "filename.sh" "output_path"
download_with_failover() {
    local file_name="$1"
    local output_path="$2"

    # Records which mirror served the file, so integrity checks know which
    # SHA256SUMS is the "same source" one.
    DOWNLOAD_SOURCE=""

    # Try Primary (GitHub)
    # -f fails on HTTP errors (404), -L follows redirects, -s silent
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 "$URL_PRIMARY_BASE/$file_name" -o "$output_path"; then
        echo "✅ GitHub available, file downloaded"
        DOWNLOAD_SOURCE="primary"
        return 0
    fi

    echo "⚠️ Primary source (Github) failed. Trying backup..."

    # Try Backup (Codeberg)
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 8 "$URL_BACKUP_BASE/$file_name" -o "$output_path"; then
        echo "✅ Codeberg available, file downloaded"
        DOWNLOAD_SOURCE="backup"
        return 0
    fi
    echo "⚠️ Secondary source (Codeberg) failed too."
    return 1
}

# Calculate SHA256 Hash
calculate_hash() {
    if [[ ! -f "$1" ]]; then return 1; fi
    shasum -a 256 "$1" | awk '{print $1}'
}

# ------------------------------------------------------------------------------
# 3e. DOWNLOAD INTEGRITY
# ------------------------------------------------------------------------------
# Self-update overwrites a script that runs on every menu refresh, so nothing is
# installed before it passes: SHA256 against the publisher's SHA256SUMS, the
# second mirror agreeing, and the file actually parsing as zsh.

# Expected SHA256 for a file according to a given source's SHA256SUMS
remote_expected_hash() {
    local base_url="$1"
    local file_name="$2"
    local sums=""

    sums=$(curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "$base_url/SHA256SUMS" 2>/dev/null) || return 1

    # SHA256SUMS lines are "<64 hex>  <filename>"
    print -r -- "$sums" | awk -v target="$file_name" '
        { name = $2; sub(/^\*/, "", name) }
        name == target { print $1; found = 1; exit }
        END { exit !found }
    '
}

# Gate a downloaded script before it replaces anything on disk.
# Usage: verify_download "<remote file name>" "<local path>" ["<required header>"]
verify_download() {
    local file_name="$1"
    local file_path="$2"
    local want_header="${3:-}"
    local actual="" expected_same="" expected_other="" same_base="" other_base=""

    if [[ ! -s "$file_path" ]]; then
        echo "❌ Integrity: downloaded $file_name is empty."
        return 1
    fi

    # A truncated or tampered script usually stops parsing. 'zsh -n' only parses.
    if ! zsh -n "$file_path" 2>/dev/null; then
        echo "❌ Integrity: $file_name is not valid zsh (truncated or modified)."
        return 1
    fi

    if [[ -n "$want_header" ]] && ! grep -q "$want_header" "$file_path"; then
        echo "❌ Integrity: $file_name is missing its '$want_header' marker."
        return 1
    fi

    if [[ "$DOWNLOAD_SOURCE" == "backup" ]]; then
        same_base="$URL_BACKUP_BASE"
        other_base="$URL_PRIMARY_BASE"
    else
        same_base="$URL_PRIMARY_BASE"
        other_base="$URL_BACKUP_BASE"
    fi

    actual=$(calculate_hash "$file_path") || return 1

    if ! expected_same=$(remote_expected_hash "$same_base" "$file_name"); then
        echo "❌ Integrity: no SHA256SUMS entry for $file_name at the download source."
        echo "   Refusing to install an unverified script."
        return 1
    fi

    if [[ "$actual" != "$expected_same" ]]; then
        echo "❌ Integrity: checksum mismatch for $file_name."
        echo "   expected $expected_same"
        echo "   got      $actual"
        return 1
    fi

    # Cross-source check: a single compromised or half-pushed mirror is caught here
    if expected_other=$(remote_expected_hash "$other_base" "$file_name"); then
        if [[ "$expected_other" != "$expected_same" ]]; then
            echo "❌ Integrity: GitHub and Codeberg publish different checksums for $file_name."
            echo "   Refusing to install. Retry later or update manually."
            return 1
        fi
        echo "✅ Integrity verified for $file_name (both sources agree)."
    else
        echo "⚠️ Second source unreachable: $file_name verified against one source only."
    fi

    return 0
}

# Download + verify in one step, leaving the target untouched on any failure
download_verified() {
    local file_name="$1"
    local output_path="$2"
    local want_header="${3:-}"

    download_with_failover "$file_name" "$output_path" || return 1
    verify_download "$file_name" "$output_path" "$want_header" || return 1
    return 0
}

# Truncate version string to a given limit (default 10) for menu readability
truncate_ver() {
    local ver="$1"
    local limit="${2:-10}"
    if [[ ${#ver} -gt $limit ]]; then
        # Subtract 2 for the dots
        echo "${ver:0:$((limit-2))}.."
    else
        echo "$ver"
    fi
}

# Clean version string by removing commit hashes (40-char hex after comma)
clean_version() {
    local ver="$1"
    if [[ "$ver" == *,* ]]; then
        local suffix="${ver#*,}"
        if [[ ${#suffix} -eq 40 && "$suffix" =~ ^[0-9a-fA-F]+$ ]]; then
            echo "${ver%%,*}"
            return
        fi
    fi
    echo "$ver"
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



# Helper: Clean App Store Name (Removes leading ID/whitespace and trailing version info)
clean_mas_name() {
    # 1. Remove leading ID (digits + space), handling potential leading whitespace (^[[:space:]]*)
    # 2. Remove trailing version info (last parenthesis group)
    # 3. Trim whitespace via xargs
    echo "$1" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]*\([^)]+\)$//' | xargs
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
# SPARKLE APPCAST DETECTION
# ------------------------------------------------------------------------------
# Apps that neither Homebrew nor the App Store manage usually ship Sparkle, the
# de-facto macOS updater framework. Their Info.plist points at an "appcast" RSS
# feed listing available builds.
#
# This DETECTS and REPORTS only - nothing is downloaded or installed.
#
# Two things real feeds get wrong if handled naively, both verified against
# live data:
#   1. Items are not sorted. AppCleaner's feed lists 3.4 before 3.6, so
#      "take the first item" reports an ancient version as the newest.
#   2. The first item is often a beta. DockDoor's newest entry carries
#      <sparkle:channel>beta</sparkle:channel>; following it would silently move
#      the user onto a prerelease channel.
# So every item is parsed, prereleases are dropped, and the maximum remains.

# Strip decoration from a version string and keep the dotted numeric core.
#   "v1.2.3"          -> 1.2.3
#   "release-2.0"     -> 2.0
#   "1.39.5.1 beta"   -> 1.39.5.1
#   "Version 3.6"     -> 3.6
# Prints nothing when there is no usable numeric version.
normalize_version() {
    local raw="$1"
    local cleaned

    # Keep the first dotted-numeric run found anywhere in the string
    cleaned=$(print -r -- "$raw" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//; s/\.+/./g; s/^\.//; s/\.$//')

    [[ "$cleaned" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    print -r -- "$cleaned"
}

# Does this version string advertise itself as a prerelease?
is_prerelease_version() {
    local haystack="${1:l}"
    case "$haystack" in
        *beta*|*alpha*|*"rc"[0-9]*|*-rc*|*dev*|*preview*|*nightly*|*canary*|*insider*|*snapshot*|*eap*|*pre-release*|*prerelease*)
            return 0
            ;;
    esac
    return 1
}

# Read one Info.plist key, tolerating apps whose plist is binary or unreadable
plist_value() {
    local plist="$1"
    local key="$2"
    [[ -f "$plist" ]] || return 1
    defaults read "$plist" "$key" 2>/dev/null
}

# The appcast URL for an app bundle.
# Falls back to the user defaults domain, because some apps (AltTab among them)
# set SUFeedURL at runtime instead of shipping it in Info.plist.
sparkle_feed_url() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local feed="" bundle_id=""

    feed=$(plist_value "$plist" "SUFeedURL") || feed=""
    if [[ -z "$feed" ]]; then
        bundle_id=$(plist_value "$plist" "CFBundleIdentifier") || bundle_id=""
        if [[ -n "$bundle_id" ]]; then
            feed=$(defaults read "$bundle_id" SUFeedURL 2>/dev/null) || feed=""
        fi
    fi

    # Only https feeds are followed
    [[ "$feed" == https://* ]] || return 1
    print -r -- "$feed"
}

# Flatten an appcast into one line per item:
#   elemShort|attrShort|elemVersion|attrVersion|channel|url|edSignature|title
# xsltproc ships with macOS and handles the sparkle: namespace properly, which
# regex over XML does not.
SPARKLE_XSLT='<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="text"/>
<xsl:template match="/">
<xsl:for-each select="//*[local-name()=&apos;item&apos;]">
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;shortVersionString&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;shortVersionString&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;version&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;version&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;channel&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@url),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;enclosure&apos;]/@*[local-name()=&apos;edSignature&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;title&apos;]),&apos;|&apos;,&apos;/&apos;)"/>
<xsl:text>&#10;</xsl:text>
</xsl:for-each>
</xsl:template>
</xsl:stylesheet>'

# Best stable release in an appcast.
# Prints "version|url|edSignature", or nothing when the feed has no usable
# stable entry.
sparkle_best_release() {
    local feed_url="$1"
    local xml_file xsl_file line
    local elem_short attr_short elem_ver attr_ver channel url edsig title
    local candidate best_version="" best_url="" best_sig=""

    xml_file="$(mktemp "${TMPDIR:-/tmp}/appcast.XXXXXX")" || return 1
    xsl_file="$(mktemp "${TMPDIR:-/tmp}/appcast_xsl.XXXXXX")" || { rm -f "$xml_file"; return 1; }

    print -r -- "$SPARKLE_XSLT" > "$xsl_file"

    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "$feed_url" -o "$xml_file" 2>/dev/null; then
        rm -f "$xml_file" "$xsl_file"
        return 1
    fi

    for line in "${(@f)$(xsltproc "$xsl_file" "$xml_file" 2>/dev/null)}"; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r elem_short attr_short elem_ver attr_ver channel url edsig title <<< "$line"

        # A named channel means anything other than the default stable one
        [[ -n "$channel" ]] && continue

        # Prefer the human version; fall back to the build number
        candidate="${elem_short:-$attr_short}"
        [[ -z "$candidate" ]] && candidate="${elem_ver:-$attr_ver}"
        [[ -z "$candidate" ]] && candidate="$title"

        # Drop prereleases however they are labelled
        is_prerelease_version "$candidate" && continue
        is_prerelease_version "$title" && continue

        candidate=$(normalize_version "$candidate") || continue

        if [[ -z "$best_version" ]] || ! is-at-least "$candidate" "$best_version"; then
            best_version="$candidate"
            best_url="$url"
            best_sig="$edsig"
        fi
    done

    rm -f "$xml_file" "$xsl_file"

    [[ -n "$best_version" ]] || return 1
    print -r -- "${best_version}|${best_url}|${best_sig}"
}

# Cask tokens plausibly matching an app name, used to skip Homebrew-managed
# apps.
#
# Deliberately narrower than the matching in setup_mac.sh: that one runs
# interactively and the user confirms the result, while this one silently hides
# an app from the menu. Progressive truncation ("alt-tab" -> "alt") is therefore
# left out - a wrong match here means an update is never reported at all.
app_cask_candidates() {
    local app_name="$1"
    local base="" camel=""
    typeset -a out

    base=$(print -r -- "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    camel=$(print -r -- "$app_name" \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    out=("$base")
    [[ -n "$camel" && "$camel" != "$base" ]] && out+=("$camel")
    out+=("${base//./}")
    [[ -n "$camel" ]] && out+=("${camel//./}")

    print -rl -- "${(@u)out}"
}

# Is this app already managed by a Homebrew cask?
# Reported Sparkle updates for cask apps would contradict the Homebrew section
# and, if acted on, desynchronise brew's metadata.
app_is_brew_managed() {
    local app_name="$1"
    local candidate

    (( ${#INSTALLED_CASK_TOKENS} > 0 )) || return 1

    for candidate in "${(@f)$(app_cask_candidates "$app_name")}"; do
        [[ -n "$candidate" ]] || continue
        [[ -n "${INSTALLED_CASK_TOKENS[$candidate]}" ]] && return 0
    done

    return 1
}

# ------------------------------------------------------------------------------
# GITHUB RELEASES
# ------------------------------------------------------------------------------
# releases.atom instead of api.github.com: the API allows 60 unauthenticated
# requests per hour, which a scan of /Applications burns through immediately.
# The atom feed has no such limit and needs no token.

# Flatten releases.atom into "tag|title" per entry.
# The tag comes from <id> (".../Repository/<n>/<tag>"), which is stable; the
# title is free-form release naming and is only used to spot prereleases.
GITHUB_ATOM_XSLT='<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="text"/>
<xsl:template match="/">
<xsl:for-each select="//*[local-name()=&apos;entry&apos;]">
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;id&apos;]),&apos;|&apos;,&apos;/&apos;)"/><xsl:text>|</xsl:text>
<xsl:value-of select="translate(normalize-space(*[local-name()=&apos;title&apos;]),&apos;|&apos;,&apos;/&apos;)"/>
<xsl:text>&#10;</xsl:text>
</xsl:for-each>
</xsl:template>
</xsl:stylesheet>'

# Newest stable release of a GitHub repository.
# Prints "version|release_page_url", or nothing when there is no usable release.
github_best_release() {
    local repo="$1"
    local atom_file xsl_file line entry_id title tag candidate
    local best_version="" best_tag=""

    [[ "$repo" == */* ]] || return 1

    atom_file="$(mktemp "${TMPDIR:-/tmp}/releases.XXXXXX")" || return 1
    xsl_file="$(mktemp "${TMPDIR:-/tmp}/releases_xsl.XXXXXX")" || { rm -f "$atom_file"; return 1; }

    print -r -- "$GITHUB_ATOM_XSLT" > "$xsl_file"

    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "https://github.com/${repo}/releases.atom" \
        -o "$atom_file" 2>/dev/null; then
        rm -f "$atom_file" "$xsl_file"
        return 1
    fi

    for line in "${(@f)$(xsltproc "$xsl_file" "$atom_file" 2>/dev/null)}"; do
        [[ -n "$line" ]] || continue
        entry_id="${line%%|*}"
        title="${line#*|}"
        tag="${entry_id##*/}"

        [[ -n "$tag" ]] || continue

        # releases.atom does not flag prereleases, so tag and title text is all
        # there is to go on. Anything that names itself a prerelease is dropped.
        is_prerelease_version "$tag" && continue
        is_prerelease_version "$title" && continue

        candidate=$(normalize_version "$tag") || continue

        if [[ -z "$best_version" ]] || ! is-at-least "$candidate" "$best_version"; then
            best_version="$candidate"
            best_tag="$tag"
        fi
    done

    rm -f "$atom_file" "$xsl_file"

    [[ -n "$best_version" ]] || return 1
    print -r -- "${best_version}|https://github.com/${repo}/releases/tag/${best_tag}"
}

# Derive "owner/repo" for an app, in decreasing order of confidence:
#   1. a GitHub host in the Sparkle feed URL (the feed is served by that repo)
#   2. a com.github.<owner>.<repo> bundle identifier
# Anything less certain is left to tracked_apps.conf rather than guessed.
github_repo_for_app() {
    local app_path="$1"
    local feed="" bundle_id="" owner="" repo=""

    feed=$(sparkle_feed_url "$app_path" 2>/dev/null) || feed=""
    if [[ -n "$feed" ]]; then
        case "$feed" in
            https://raw.githubusercontent.com/*|https://github.com/*|https://*.github.io/*)
                if [[ "$feed" == https://*.github.io/* ]]; then
                    # https://owner.github.io/Repo/appcast.xml
                    owner="${${feed#https://}%%.github.io/*}"
                    repo="${${feed#https://*.github.io/}%%/*}"
                else
                    owner="${${feed#https://*/}%%/*}"
                    repo="${${feed#https://*/${owner}/}%%/*}"
                fi
                if [[ -n "$owner" && -n "$repo" ]]; then
                    print -r -- "${owner}/${repo}"
                    return 0
                fi
                ;;
        esac
    fi

    bundle_id=$(plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier) || bundle_id=""
    if [[ "$bundle_id" == com.github.*.* ]]; then
        owner="${${bundle_id#com.github.}%%.*}"
        repo="${${bundle_id#com.github.${owner}.}%%.*}"
        if [[ -n "$owner" && -n "$repo" ]]; then
            print -r -- "${owner}/${repo}"
            return 0
        fi
    fi

    return 1
}

# ------------------------------------------------------------------------------
# OFFICIAL WEBSITES & GITHUB REPOSITORIES
# ------------------------------------------------------------------------------
# Where these come from, entirely from data already sitting on disk or given by
# an authoritative API - no guessing, no per-app LLM call:
#   - Homepage: 'homepage' is a mandatory field in every Homebrew cask
#     definition, so 'brew info --cask --json=v2' gives it for free, from the
#     local tap. For non-cask apps, the GitHub API's own 'homepage' field on
#     the repo (see below), cached for a day since it never changes.
#   - GitHub repo: a cask's *download URL* is frequently a GitHub release
#     asset (https://github.com/owner/repo/releases/download/...) - that is
#     exactly where the installed copy came from, not an inference. For
#     non-cask apps, the same Sparkle-feed / bundle-id derivation used for
#     self-update checking.
# An app with neither simply has no entry - "if it's known", not "always".

# Owner/repo when a cask's download URL is a GitHub release asset - which it
# is for most indie Mac apps, since that is where `brew audit` steers cask
# authors. This is exact, not a guess: it is literally where the running copy
# was downloaded from.
cask_repo_from_url() {
    local url="$1"
    [[ "$url" == https://github.com/*/*/releases/* ]] || return 1

    local rest="${url#https://github.com/}"
    local owner="${rest%%/*}"
    rest="${rest#*/}"
    local repo="${rest%%/*}"

    [[ -n "$owner" && -n "$repo" ]] || return 1
    print -r -- "${owner}/${repo}"
}

# Homepage and (when derivable) GitHub repo for every installed cask, from a
# single 'brew info' call. Emits: token|homepage|repo
# 'repo' is blank when the cask does not download from GitHub releases (its own
# CDN, SourceForge, a JetBrains/Microsoft/etc. server) - nothing is guessed at.
collect_cask_homepages() {
    typeset -a casks
    casks=("${(@f)$(brew list --cask 2>/dev/null)}")
    (( ${#casks[@]} > 0 )) || return 0

    local json_file
    json_file="$(mktemp "${TMPDIR:-/tmp}/cask_homepages.XXXXXX")" || return 1

    if ! brew info --cask --json=v2 "${casks[@]}" > "$json_file" 2>/dev/null; then
        rm -f "$json_file"
        return 1
    fi

    local count idx token homepage download_url repo result=""
    count=$(plutil -extract casks raw -o - "$json_file" 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        rm -f "$json_file"
        return 1
    fi

    for (( idx = 0; idx < count; idx++ )); do
        token=$(plutil -extract "casks.${idx}.token" raw -o - "$json_file" 2>/dev/null) || continue
        [[ -n "$token" ]] || continue

        homepage=$(plutil -extract "casks.${idx}.homepage" raw -o - "$json_file" 2>/dev/null) || homepage=""
        [[ "$homepage" == https://* ]] || homepage=""

        download_url=$(plutil -extract "casks.${idx}.url" raw -o - "$json_file" 2>/dev/null) || download_url=""
        repo=$(cask_repo_from_url "$download_url") || repo=""

        result+="${token}|${homepage}|${repo}"$'\n'
    done

    rm -f "$json_file"
    print -rn -- "$result"
}

# The 'homepage' field on a GitHub repository, when the repo (and GitHub) says
# there is one. Empty result is normal, not an error - most repos leave it blank.
github_repo_homepage() {
    local repo="$1"
    local json homepage

    json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 10 \
        -H "User-Agent: $USER_AGENT" "https://api.github.com/repos/${repo}" 2>/dev/null) || return 1

    homepage=$(print -r -- "$json" | plutil -extract homepage raw -o - - 2>/dev/null) || return 1
    [[ "$homepage" == https://* ]] || return 1
    print -r -- "$homepage"
}

# Homepage for every installed app whose GitHub repo could be derived and is
# not already covered by a cask homepage. Emits: AppName|homepage
collect_github_homepages() {
    local app_path app_name repo homepage cask_line
    local result=""

    typeset -gA INSTALLED_CASK_TOKENS
    INSTALLED_CASK_TOKENS=()
    for cask_line in "${(@f)$(cache_get "brew_casks")}"; do
        [[ -n "$cask_line" ]] && INSTALLED_CASK_TOKENS[${cask_line%% *}]=1
    done

    for app_path in /Applications/*.app(N); do
        app_name="${${app_path:t}%.app}"

        [[ "$app_path" == /Applications/Setapp/* ]] && continue
        [[ -d "$app_path/Contents/_MASReceipt" ]] && continue
        app_is_brew_managed "$app_name" && continue

        repo=$(github_repo_for_app "$app_path") || continue
        homepage=$(github_repo_homepage "$repo") || continue

        result+="${app_name}|${homepage}"$'\n'
    done

    print -rn -- "$result"
}

# ------------------------------------------------------------------------------
# TRACKED APPS
# ------------------------------------------------------------------------------
# User-editable overrides for how an app is checked:
#   AppName|method|identifier
# method: sparkle (identifier = appcast URL)
#         github  (identifier = owner/repo)
#         homebrew(identifier = cask token; the Homebrew section owns it)
#         skip    (never check this app)
# Automatic detection only applies to apps with no entry here.
tracked_app_entry() {
    local app_name="$1"
    local entry_name entry_method entry_id

    [[ -f "$TRACKED_APPS_FILE" ]] || return 1

    while IFS='|' read -r entry_name entry_method entry_id || [[ -n "$entry_name" ]]; do
        entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
        entry_name="${entry_name%"${entry_name##*[![:space:]]}"}"
        [[ -z "$entry_name" || "$entry_name" == \#* ]] && continue

        entry_method="${entry_method#"${entry_method%%[![:space:]]*}"}"
        entry_method="${entry_method%"${entry_method##*[![:space:]]}"}"
        entry_id="${entry_id#"${entry_id%%[![:space:]]*}"}"
        entry_id="${entry_id%"${entry_id##*[![:space:]]}"}"

        if [[ "${entry_name:l}" == "${app_name:l}" ]]; then
            print -r -- "${entry_method:l}|${entry_id}"
            return 0
        fi
    done < "$TRACKED_APPS_FILE"

    return 1
}

# Create the file with instructions on first use, never overwrite it
ensure_tracked_apps_file() {
    [[ -f "$TRACKED_APPS_FILE" ]] && return 0

    cat > "$TRACKED_APPS_FILE" << 'EOF'
# How to check individual applications for updates.
#
# One entry per line:   App Name|method|identifier
#   sparkle  | identifier = appcast URL          e.g. MyApp|sparkle|https://example.com/appcast.xml
#   github   | identifier = owner/repo           e.g. MyApp|github|owner/MyApp
#   homebrew | identifier = cask token           e.g. MyApp|homebrew|my-app
#   skip     | identifier unused                 e.g. MyApp|skip|
#
# "App Name" is the bundle name without ".app", matched case insensitively.
# Apps without an entry here are detected automatically: a Sparkle feed in
# Info.plist, otherwise a GitHub repository derived from that feed or from a
# com.github.owner.repo bundle identifier.
#
# Homebrew casks and App Store apps are already covered by their own sections
# and are skipped automatically - add a "skip" entry only to silence something.
EOF
    chmod 600 "$TRACKED_APPS_FILE" 2>/dev/null || true
}

# Scan /Applications for apps that update themselves, and report newer stable
# releases. Detection only: nothing is downloaded or installed.
# Emits: method|AppName|localVersion|remoteVersion|url|signature
collect_app_updates() {
    local app_path app_name feed release remote_ver local_ver url edsig repo
    local tracked tracked_method tracked_id method
    local result=""
    local cask_line=""

    ensure_tracked_apps_file

    # Installed cask tokens, for the "managed elsewhere" check
    typeset -gA INSTALLED_CASK_TOKENS
    INSTALLED_CASK_TOKENS=()
    for cask_line in "${(@f)$(cache_get "brew_casks")}"; do
        [[ -n "$cask_line" ]] && INSTALLED_CASK_TOKENS[${cask_line%% *}]=1
    done

    for app_path in /Applications/*.app(N); do
        app_name="${${app_path:t}%.app}"
        method=""
        feed=""
        repo=""

        # Setapp manages its own catalogue; touching those apps breaks it
        [[ "$app_path" == /Applications/Setapp/* ]] && continue

        # App Store apps are covered by the mas section
        [[ -d "$app_path/Contents/_MASReceipt" ]] && continue

        # Respect the ignore list (keyed by app name for this source)
        is_ignored "sparkle" "$app_name" && continue

        local_ver=$(plist_value "$app_path/Contents/Info.plist" CFBundleShortVersionString) || continue
        local_ver=$(normalize_version "$local_ver") || continue

        # An explicit entry always wins over detection
        if tracked=$(tracked_app_entry "$app_name"); then
            tracked_method="${tracked%%|*}"
            tracked_id="${tracked#*|}"

            case "$tracked_method" in
                "skip"|"homebrew") continue ;;
                "sparkle")
                    [[ -n "$tracked_id" ]] || continue
                    method="sparkle"
                    feed="$tracked_id"
                    ;;
                "github")
                    [[ -n "$tracked_id" ]] || continue
                    method="github"
                    repo="$tracked_id"
                    ;;
                *) continue ;;
            esac
        else
            # Homebrew casks are covered by the Homebrew section
            app_is_brew_managed "$app_name" && continue

            if feed=$(sparkle_feed_url "$app_path"); then
                method="sparkle"
            elif repo=$(github_repo_for_app "$app_path"); then
                method="github"
            else
                continue
            fi
        fi

        if [[ "$method" == "sparkle" ]]; then
            release=$(sparkle_best_release "$feed") || continue
            remote_ver="${release%%|*}"
            url="${${release#*|}%|*}"
            edsig="${release##*|}"
        else
            release=$(github_best_release "$repo") || continue
            remote_ver="${release%%|*}"
            url="${release#*|}"
            edsig=""
        fi

        # Only report a genuine forward step
        [[ -n "$remote_ver" ]] || continue
        is-at-least "$remote_ver" "$local_ver" && continue

        result+="${method}|${app_name}|${local_ver}|${remote_ver}|${url}|${edsig}"$'\n'
    done

    print -rn -- "$result"
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

# Populate the cache. Tier is "updates", "installed", "sparkle" or "all".
# MAS entries are always written (empty when App Store support is off) so the
# staleness check cannot get stuck asking for data that will never arrive.
collect_cache_data() {
    local tier="${1:-all}"
    local mas_outdated_raw=""

    if [[ "$tier" == "updates" || "$tier" == "all" ]]; then
        if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
            cache_refresh_entry "mas_outdated" mas outdated
        else
            cache_put "mas_outdated" ""
        fi
        mas_outdated_raw="$(cache_get "mas_outdated")"

        cache_refresh_entry "brew_outdated"  brew_outdated_normalized
        cache_refresh_entry "manual_updates" collect_manual_updates "$mas_outdated_raw"
    fi

    if [[ "$tier" == "installed" || "$tier" == "all" ]]; then
        cache_refresh_entry "brew_pinned"   brew list --pinned
        cache_refresh_entry "brew_casks"    brew list --cask --versions
        cache_refresh_entry "brew_formulae" brew list --formula --versions
        cache_refresh_entry "brew_status"   collect_brew_status

        if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
            cache_refresh_entry "mas_list" mas list
        else
            cache_put "mas_list" ""
        fi
    fi

    if [[ "$tier" == "apps" || "$tier" == "all" ]]; then
        # Depends on brew_casks to skip Homebrew-managed apps, so make sure
        # that entry exists before scanning.
        [[ -f "$CACHE_DIR/brew_casks" ]] || cache_refresh_entry "brew_casks" brew list --cask --versions
        cache_refresh_entry "app_updates" collect_app_updates
    fi

    if [[ "$tier" == "websites" || "$tier" == "all" ]]; then
        [[ -f "$CACHE_DIR/brew_casks" ]] || cache_refresh_entry "brew_casks" brew list --cask --versions
        cache_refresh_entry "cask_homepages"   collect_cask_homepages
        cache_refresh_entry "github_homepages" collect_github_homepages
    fi
}

# ------------------------------------------------------------------------------
# APPLICATION REPLACEMENT
# ------------------------------------------------------------------------------
# Downloading and swapping a .app is the only operation here that can leave a
# user without a working application, so the rules are strict:
#
#   * DMG and ZIP only. A .pkg runs preinstall/postinstall scripts as root:
#     it cannot be sandboxed and cannot be rolled back, so it is refused.
#   * Nothing on disk is touched until every signature check has passed.
#   * The old bundle is moved aside, not deleted, and is restored on any error.
#
# Verified against real downloads: apps shipped with a "Developer ID
# Application" certificate and notarised pass all checks, while an app signed
# with a plain "Apple Development" certificate is rejected by Gatekeeper - which
# is the intended outcome, not a bug to work around.

# Process name of an app bundle (CFBundleExecutable, falling back to the name)
app_executable_name() {
    local app_path="$1"
    local exec_name=""
    exec_name=$(plist_value "$app_path/Contents/Info.plist" CFBundleExecutable) || exec_name=""
    print -r -- "${exec_name:-${${app_path:t}%.app}}"
}

app_running() {
    pgrep -x "$(app_executable_name "$1")" >/dev/null 2>&1
}

quit_running_app() {
    local app_path="$1"
    local app_name="${${app_path:t}%.app}"
    local proc_name
    proc_name=$(app_executable_name "$app_path")

    app_running "$app_path" || return 0

    echo "   Closing $app_name..."
    osascript -e "quit app \"$(applescript_escape "$app_name")\"" 2>/dev/null || true

    local waited=0
    while (( waited < 10 )); do
        app_running "$app_path" || return 0
        sleep 1
        (( waited++ ))
    done

    echo "   $app_name did not quit; forcing."
    killall -- "$proc_name" 2>/dev/null || true
    sleep 1
    return 0
}

# TeamIdentifier of a signed bundle. Unsigned bundles report "not set".
codesign_team_id() {
    codesign -dv --verbose=4 "$1" 2>&1 | grep -m1 '^TeamIdentifier=' | cut -d= -f2
}

# An OpenSSL that can verify raw ed25519 signatures.
# The system binary is LibreSSL, which has no -rawin, so this looks for a
# Homebrew OpenSSL 3 before giving up.
find_ed25519_openssl() {
    local candidate
    for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                     /usr/local/opt/openssl@3/bin/openssl \
                     "${commands[openssl]}"; do
        [[ -x "$candidate" ]] || continue
        if "$candidate" pkeyutl -help 2>&1 | grep -q -- "-rawin"; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

# Sparkle's own EdDSA check over the downloaded archive.
# Returns 0 verified, 1 signature invalid (fatal), 2 not applicable.
verify_sparkle_ed_signature() {
    local installed_app="$1"
    local archive="$2"
    local signature="$3"
    local pubkey="" openssl_bin="" der_file="" sig_file=""

    pubkey=$(plist_value "$installed_app/Contents/Info.plist" SUPublicEDKey) || pubkey=""
    [[ -n "$pubkey" && -n "$signature" ]] || return 2

    openssl_bin=$(find_ed25519_openssl) || return 2

    der_file="$(mktemp "${TMPDIR:-/tmp}/edkey.XXXXXX")" || return 2
    sig_file="$(mktemp "${TMPDIR:-/tmp}/edsig.XXXXXX")" || { rm -f "$der_file"; return 2; }

    # Wrap the 32 raw key bytes in the DER prefix for an ed25519 public key
    if ! { printf '302a300506032b6570032100' | xxd -r -p > "$der_file" && \
           print -r -- "$pubkey" | base64 -d >> "$der_file" && \
           print -r -- "$signature" | base64 -d > "$sig_file"; } 2>/dev/null; then
        rm -f "$der_file" "$sig_file"
        return 2
    fi

    if "$openssl_bin" pkeyutl -verify -pubin -inkey "$der_file" -keyform DER \
        -rawin -in "$archive" -sigfile "$sig_file" >/dev/null 2>&1; then
        rm -f "$der_file" "$sig_file"
        return 0
    fi

    rm -f "$der_file" "$sig_file"
    return 1
}

# The gate. Every check must pass before anything is written to /Applications.
verify_app_replacement() {
    local installed_app="$1"
    local downloaded_app="$2"
    local expected_version="$3"
    local archive="$4"
    local ed_signature="$5"
    local old_team new_team downloaded_version ed_rc

    echo "🔐 Verifying the download..."

    # 1. Same developer. This is the check that actually proves provenance.
    old_team=$(codesign_team_id "$installed_app")
    new_team=$(codesign_team_id "$downloaded_app")

    if [[ -z "$old_team" || "$old_team" == "not set" ]]; then
        echo "❌ The installed application has no Team ID (unsigned or Apple-internal)."
        echo "   There is nothing to compare against, so it will not be replaced."
        return 1
    fi

    if [[ -z "$new_team" || "$new_team" == "not set" ]]; then
        echo "❌ The downloaded application is not signed."
        return 1
    fi

    if [[ "$old_team" != "$new_team" ]]; then
        echo "❌ Team ID mismatch."
        echo "   installed:   $old_team"
        echo "   downloaded:  $new_team"
        echo "   The download is not from the same developer. Aborting."
        return 1
    fi
    echo "   ✓ Team ID matches ($old_team)"

    # 2. The signature itself must be intact
    if ! codesign --verify "$downloaded_app" 2>/dev/null; then
        echo "❌ Code signature verification failed for the download."
        codesign --verify "$downloaded_app" 2>&1 | sed 's/^/   /'
        return 1
    fi
    echo "   ✓ Code signature is valid"

    # 3. Gatekeeper. Rejects anything not signed for distribution and notarised.
    if ! spctl -a -t open --context context:primary-signature "$downloaded_app" >/dev/null 2>&1; then
        echo "❌ Gatekeeper rejected the download."
        echo "   Typically this means the app is signed with a development"
        echo "   certificate or has not been notarised by Apple."
        echo "   Install it yourself from the publisher if you trust it."
        return 1
    fi
    echo "   ✓ Gatekeeper accepted the download"

    # 4. Sparkle's own EdDSA signature, when the app publishes a key
    verify_sparkle_ed_signature "$installed_app" "$archive" "$ed_signature"
    ed_rc=$?
    case $ed_rc in
        0) echo "   ✓ Sparkle EdDSA signature verified" ;;
        1)
            echo "❌ Sparkle EdDSA signature does NOT match the download."
            return 1
            ;;
        *) echo "   • Sparkle EdDSA signature not checked (no key, no signature, or no OpenSSL 3)" ;;
    esac

    # 5. The bundle must actually be the version the feed advertised
    downloaded_version=$(plist_value "$downloaded_app/Contents/Info.plist" CFBundleShortVersionString) || downloaded_version=""
    downloaded_version=$(normalize_version "$downloaded_version") || downloaded_version=""
    if [[ -n "$expected_version" && -n "$downloaded_version" && "$downloaded_version" != "$expected_version" ]]; then
        echo "❌ Version mismatch: feed promised $expected_version, archive contains $downloaded_version."
        return 1
    fi
    echo "   ✓ Version is $downloaded_version"

    return 0
}

# Unpack a DMG or ZIP and print the path of the single .app inside it
extract_app_from_archive() {
    local archive="$1"
    local workdir="$2"
    local extract_dir="$workdir/extract"
    local mountpoint="$workdir/mnt"
    typeset -a found

    mkdir -p "$extract_dir" || return 1

    case "${archive:l}" in
        *.zip)
            # ditto keeps extended attributes and resource forks intact,
            # which unzip does not - and a mangled bundle fails codesign.
            ditto -x -k "$archive" "$extract_dir" 2>/dev/null || return 1
            ;;
        *.dmg)
            mkdir -p "$mountpoint" || return 1
            hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mountpoint" \
                "$archive" >/dev/null 2>&1 || return 1

            found=("$mountpoint"/*.app(N))
            if (( ${#found[@]} == 1 )); then
                ditto "${found[1]}" "$extract_dir/${found[1]:t}" 2>/dev/null
            fi

            hdiutil detach "$mountpoint" -quiet 2>/dev/null \
                || hdiutil detach "$mountpoint" -force -quiet 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac

    found=("$extract_dir"/*.app(N) "$extract_dir"/*/*.app(N))
    (( ${#found[@]} == 1 )) || return 1

    print -r -- "${found[1]}"
}

# Swap the bundle, keeping the old one until the new one is in place
replace_app_bundle() {
    local installed_app="$1"
    local downloaded_app="$2"
    local backup="${installed_app}.msu-backup"

    rm -rf "$backup" 2>/dev/null || true

    if ! mv "$installed_app" "$backup" 2>/dev/null; then
        echo "❌ Could not move the current application aside (permissions?)."
        return 1
    fi

    if ! ditto "$downloaded_app" "$installed_app" 2>/dev/null; then
        echo "❌ Copy failed. Restoring the previous version..."
        rm -rf "$installed_app" 2>/dev/null || true
        mv "$backup" "$installed_app" 2>/dev/null || true
        return 1
    fi

    # Sanity check before the backup is dropped
    if [[ ! -d "$installed_app/Contents/MacOS" ]]; then
        echo "❌ The installed bundle looks incomplete. Restoring..."
        rm -rf "$installed_app" 2>/dev/null || true
        mv "$backup" "$installed_app" 2>/dev/null || true
        return 1
    fi

    # Already assessed by Gatekeeper above, so clear the quarantine flag the
    # download left behind - otherwise macOS re-prompts on first launch.
    xattr -dr com.apple.quarantine "$installed_app" 2>/dev/null || true

    rm -rf "$backup" 2>/dev/null || true
    return 0
}

# ==============================================================================
# 4. MENU SUB FUNCTIONS
# ==============================================================================

check_for_updates_manual() {
    echo "Checking for updates..."

    local temp_headers="$(mktemp "${TMPDIR:-/tmp}/update_headers.XXXXXX")"
    local temp_body="$(mktemp "${TMPDIR:-/tmp}/update_body.XXXXXX")"

    trap 'rm -f "$temp_headers" "$temp_body"' EXIT

    local local_etag=""

    [[ -f "$ETAG_FILE" ]] && local_etag=$(cat "$ETAG_FILE")

    # Check ETag (Primary Source)
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -D "$temp_headers" \
        -H "If-None-Match: $local_etag" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout 5 \
        "$URL_PRIMARY_BASE/update_system.1h.sh")

    if [[ "$http_code" == "304" ]]; then
        echo "✅ Status 304: No changes."
        rm -f "$PENDING_FLAG" "$temp_headers" "$temp_body"
        osascript -e "display notification \"Plugin is up to date.\" with title \"Mac Software Manager\""
        return 0
    fi

    # Download (Failover Logic)
    local source_verified="false"

    if [[ "$http_code" == "200" ]]; then
        if curl -s -o "$temp_body" "$URL_PRIMARY_BASE/update_system.1h.sh"; then
            grep -i "etag:" "$temp_headers" | awk '{print $2}' | tr -d '"\r\n' > "$ETAG_FILE"
            source_verified="true"
        fi
    fi

    if [[ "$source_verified" == "false" ]]; then
        echo "⚠️ Primary failed (HTTP $http_code). Downloading from Backup..."
        if curl -fLsS --connect-timeout 8 "$URL_BACKUP_BASE/update_system.1h.sh" -o "$temp_body"; then
            source_verified="true"
        fi
    fi

    if [[ "$source_verified" != "true" ]]; then
        echo "❌ Error: Update connection to GitHub and Codeberg failed."
        osascript -e "display notification \"Update connection to Github and Codeberg failed.\" with title \"Mac Software Manager\""
        return 1
    fi

    # Verify & Compare
    local local_ver="${VERSION//v/}"
    local remote_ver=$(extract_version "$temp_body")
    local local_hash=$(calculate_hash "$SCRIPT_FILE")
    local remote_hash=$(calculate_hash "$temp_body")

    echo "Verify: Local v$local_ver vs Remote v$remote_ver"

    if [[ -z "$local_ver" ]]; then
        echo "❌ Critical Error: Could not determine local version."
        return 1
    fi

    if [[ "$local_hash" == "$remote_hash" ]]; then
        echo "ℹ️ Files are identical."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"You have the latest version (v$local_ver).\" with title \"Mac Software Manager\""

    elif [[ "$local_ver" == "$remote_ver" ]]; then
        echo "ℹ️ Version matches, but hashes not. Ignoring. Verify local and remote version, probably cosmetical changes..."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Up to date (v$local_ver).\" with title \"Mac Software Manager\""

    elif is-at-least "$remote_ver" "$local_ver"; then
        echo "⚠️ Remote version (v$remote_ver) is OLDER than local (v$local_ver)."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Server has older version (v$remote_ver).\" with title \"Mac Software Manager\" subtitle \"Keeping local v$local_ver.\""

    else
        echo "✅ Valid Update: v$remote_ver > v$local_ver"
        touch "$PENDING_FLAG"
        osascript -e "display notification \"New version v$remote_ver available!\" with title \"Mac Software Manager\" subtitle \"Click 'Update All' to install.\""
    fi
}

# ==============================================================================
# 5. ACTION HANDLING (ARGUMENTS)
# ==============================================================================

# Background Cache Refresh
# "auto" (default) refreshes only the stale tiers, "force" refreshes everything.
if [[ "$1" == "refresh_cache" ]]; then
    # Non-blocking: if a refresh is already running, this invocation is redundant.
    acquire_lock "cache" 0 || exit 0

    case "${2:-auto}" in
        "force"|"all")
            collect_cache_data "all"
            ;;
        *)
            stale_tiers="$(cache_stale_tiers)"
            [[ -z "$stale_tiers" ]] && exit 0
            [[ "$stale_tiers" == *"updates"* ]]   && collect_cache_data "updates"
            [[ "$stale_tiers" == *"installed"* ]] && collect_cache_data "installed"
            [[ "$stale_tiers" == *"apps"* ]]      && collect_cache_data "apps"
            [[ "$stale_tiers" == *"websites"* ]]  && collect_cache_data "websites"
            ;;
    esac

    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Change Interval
if [[ "$1" == "change_interval" ]]; then
    SELECTION=$(osascript -e 'choose from list {"1 hour", "2 hours", "6 hours", "12 hours", "1 day"} with title "Update Frequency" with prompt "Select how often to check for updates:" default items "1 hour"')

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi

    NEW_SUFFIX=""
    case "$SELECTION" in
        "1 hour")   NEW_SUFFIX="1h" ;;
        "2 hours")  NEW_SUFFIX="2h" ;;
        "6 hours")  NEW_SUFFIX="6h" ;;
        "12 hours") NEW_SUFFIX="12h" ;;
        "1 day")    NEW_SUFFIX="1d" ;;
        *)          exit 1 ;;
    esac

    DIR=$(dirname "$SCRIPT_FILE")
    # Clean current name and apply new suffix
    NEW_PATH="$DIR/update_system.${NEW_SUFFIX}.sh"

    if [[ "$SCRIPT_FILE" != "$NEW_PATH" ]]; then
        mv "$SCRIPT_FILE" "$NEW_PATH" && chmod +x "$NEW_PATH"
        osascript -e "display notification \"Update frequency changed to $SELECTION.\" with title \"Mac Software Manager\""
        sleep 2
        open -g "swiftbar://refreshallplugins"
    else
         osascript -e "display notification \"Frequency is already set to $SELECTION.\" with title \"Mac Software Manager\""
    fi
    exit 0
fi

# Toggle Autostart (SwiftBar)
if [[ "$1" == "toggle_autostart" ]]; then
    # Verify actual system state via AppleScript
    if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "SwiftBar"; then
        osascript -e 'tell application "System Events" to delete login item "SwiftBar"'
        NEW_STATE="0"
        MSG="SwiftBar removed from Login Items."
    else
        osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1
        NEW_STATE="1"
        MSG="SwiftBar added to Login Items."
    fi

    # Update configuration file to reflect new state
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "AUTOSTART=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^AUTOSTART=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^AUTOSTART=.*/AUTOSTART=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "AUTOSTART=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    osascript -e "display notification \"$MSG\" with title \"Mac Software Manager\""
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Change Terminal App
if [[ "$1" == "change_terminal" ]]; then
    # Detect available terminals
    typeset -a available_terminals
    available_terminals=("Terminal")

    [[ -d "/Applications/iTerm.app" ]] && available_terminals+=("iTerm2")
    [[ -d "/Applications/Warp.app" ]] && available_terminals+=("Warp")
    [[ -d "/Applications/Alacritty.app" ]] && available_terminals+=("Alacritty")
    [[ -d "/Applications/Ghostty.app" ]] && available_terminals+=("Ghostty")

    # Build AppleScript list
    terminal_list=$(printf '"%s", ' "${available_terminals[@]}" | sed 's/, $//')

    # Show selection dialog with current selection as default
    CURRENT="${PREFERRED_TERMINAL:-Terminal}"
    SELECTION=$(osascript -e "choose from list {$terminal_list} with title \"Terminal App Selection\" with prompt \"Select your preferred terminal for running updates:\" default items \"$CURRENT\"")

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi

    # Update config file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        cat > "$CONFIG_FILE" << EOF
# Mac Software Manager Configuration
# Generated on $(date)

# Terminal app to use for running updates
# Valid values: Terminal, iTerm2, Warp, Alacritty, Ghostty
PREFERRED_TERMINAL="$SELECTION"
EOF
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    else
        # Update existing config
        if grep -q "^PREFERRED_TERMINAL=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^PREFERRED_TERMINAL=.*/PREFERRED_TERMINAL=\"$SELECTION\"/" "$CONFIG_FILE"
        else
            echo "PREFERRED_TERMINAL=\"$SELECTION\"" >> "$CONFIG_FILE"
        fi
    fi

    if [[ "$SELECTION" == "$CURRENT" ]]; then
        osascript -e "display notification \"Terminal is already set to $SELECTION.\" with title \"Mac Software Manager\""
    else
        osascript -e "display notification \"Terminal changed to $SELECTION.\" with title \"Mac Software Manager\""
    fi

    exit 0
fi

# Change Update Branch (Stable/Beta)
if [[ "$1" == "change_branch" ]]; then
    # Detect current state for default selection
    CURRENT="${UPDATE_BRANCH:-main}"
    DEFAULT_ITEM="Stable (Main)"
    if [[ "$CURRENT" == "develop" ]]; then
        DEFAULT_ITEM="Beta (Develop)"
    fi

    # Show selection dialog
    SELECTION=$(osascript -e "choose from list {\"Stable (Main)\", \"Beta (Develop)\"} with title \"Update Channel\" with prompt \"Select update source:\" default items \"$DEFAULT_ITEM\"")

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi

    # Map selection to branch name
    NEW_BRANCH="main"
    if [[ "$SELECTION" == "Beta (Develop)" ]]; then
        NEW_BRANCH="develop"
    fi

    # Check if change is actually needed
    if [[ "$NEW_BRANCH" == "$CURRENT" ]]; then
        osascript -e "display notification \"Already on $SELECTION channel.\" with title \"Mac Software Manager\""
        exit 0
    fi

    echo "⚙️ Switching to: $SELECTION..."

    # Update Configuration File
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "UPDATE_BRANCH=\"$NEW_BRANCH\"" > "$CONFIG_FILE"
    else
        if grep -q "^UPDATE_BRANCH=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^UPDATE_BRANCH=.*/UPDATE_BRANCH=\"$NEW_BRANCH\"/" "$CONFIG_FILE"
        else
            echo "UPDATE_BRANCH=\"$NEW_BRANCH\"" >> "$CONFIG_FILE"
        fi
    fi

    # Update URLs in memory immediately
    URL_PRIMARY_BASE="https://raw.githubusercontent.com/dogukannparlak/mac_software_manager/$NEW_BRANCH"
    URL_BACKUP_BASE="https://codeberg.org/YOUR_CODEBERG_USERNAME/mac_software_manager/raw/branch/$NEW_BRANCH"

    # Force Download and Overwrite
    TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.branch_switch.XXXXXX")"
    trap 'rm -f "$TEMP_TARGET"; progress_finalize' EXIT

    echo "⬇️ Downloading version from $NEW_BRANCH..."

    # Same integrity gate as self-update: checksum from the target branch,
    # cross-checked against the other mirror, plus a zsh parse check.
    if download_verified "update_system.1h.sh" "$TEMP_TARGET" "bitbar.title"; then
        mv "$TEMP_TARGET" "$SCRIPT_FILE" && chmod +x "$SCRIPT_FILE"

        # Clean up flags and stale cached data from the old channel
        rm -f "$PENDING_FLAG"
        rm -f "$ETAG_FILE"
        spawn_cache_refresh "force"

        osascript -e "display notification \"Switched to $SELECTION channel.\" with title \"Mac Software Manager\""
        open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    else
        echo "❌ Error: Could not install the $NEW_BRANCH version. Reverting config."
        osascript -e "display notification \"Channel switch failed. Config reverted.\" with title \"Mac Software Manager\""
        sed -i '' "s/^UPDATE_BRANCH=.*/UPDATE_BRANCH=\"$CURRENT\"/" "$CONFIG_FILE"
    fi
    exit 0
fi

# Install a self-updating app (Sparkle / GitHub) in the user's terminal.
# param2 = app name, param3 = "dry" for a dry run
if [[ "$1" == "install_app" ]]; then
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "install" "$2" "${3:-live}"
    exit 0
fi

# Update Single App (launches in user's configured terminal via launch_in_terminal)
if [[ "$1" == "update_app" ]]; then
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "single" "$2" "$3" "$4" "$5" "$6"
    exit 0
fi

# Ignore App
if [[ "$1" == "ignore_app" ]]; then
    type="$2"  # brew, cask, or mas
    id="$3"    # package name or app ID
    name="${4:-$id}"  # display name (fallback to id)

    case "$type" in
        "brew")
            brew pin "$id" 2>/dev/null
            ;;
        "cask"|"mas"|"sparkle")
            add_ignored "$type" "$id" "$name"
            ;;
    esac
    safe_dialog_name=$(applescript_escape "$name")
    osascript -e "display dialog \"$safe_dialog_name has been ignored.\" & return & return & \"It will no longer appear in the updates list.\" buttons {\"OK\"} default button \"OK\" with title \"App Ignored\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Unignore App
if [[ "$1" == "unignore_app" ]]; then
    type="$2"
    id="$3"
    name="${4:-$id}"  # display name (fallback to id)

    case "$type" in
        "brew")
            brew unpin "$id" 2>/dev/null
            ;;
        "cask"|"mas"|"sparkle")
            remove_ignored "$type" "$id"
            # Ghost-app checks skip ignored IDs at collect time, so a restored
            # App Store app only reappears after the cache is rebuilt.
            [[ "$type" == "mas" ]] && spawn_cache_refresh "force"
            ;;
    esac
    safe_dialog_name=$(applescript_escape "$name")
    osascript -e "display dialog \"$safe_dialog_name has been restored.\" & return & return & \"It will now appear in the updates list.\" buttons {\"OK\"} default button \"OK\" with title \"App Restored\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Toggle App Store Updates
if [[ "$1" == "toggle_mas" ]]; then
    # Force reload config
    load_config_safely

    CURRENT_STATE="${MAS_ENABLED:-1}"

    if [[ "$CURRENT_STATE" == "1" ]]; then
        NEW_STATE="0"
        MSG="App Store updates DISABLED."
    else
        NEW_STATE="1"
        MSG="App Store updates ENABLED."
    fi

    # Update Config File
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "MAS_ENABLED=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^MAS_ENABLED=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^MAS_ENABLED=.*/MAS_ENABLED=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "MAS_ENABLED=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    # App Store data is cached; rebuild it so the menu matches the new setting
    spawn_cache_refresh "force"

    osascript -e "display dialog \"$MSG\" & return & return & \"The plugin will now refresh to reflect this change.\" buttons {\"OK\"} default button \"OK\" with title \"App Store updates\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Toggle automatic replacement of self-updating apps
if [[ "$1" == "toggle_auto_install" ]]; then
    load_config_safely

    if [[ "${AUTO_INSTALL_APPS:-0}" == "1" ]]; then
        NEW_STATE="0"
        MSG="Automatic app installation DISABLED."
        DETAIL="Self-updating apps will only show a download link."
    else
        NEW_STATE="1"
        MSG="Automatic app installation ENABLED."
        DETAIL="An Install option appears for apps with a direct DMG or ZIP download. Every install verifies the developer Team ID and Gatekeeper first, and restores the old version if anything fails."
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "AUTO_INSTALL_APPS=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^AUTO_INSTALL_APPS=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^AUTO_INSTALL_APPS=.*/AUTO_INSTALL_APPS=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "AUTO_INSTALL_APPS=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    osascript -e "display dialog \"$MSG\" & return & return & \"$DETAIL\" buttons {\"OK\"} default button \"OK\" with title \"App Installation\" with icon note giving up after 8"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Toggle Homebrew Cleanup
if [[ "$1" == "toggle_cleanup" ]]; then
    load_config_safely

    if [[ "${CLEANUP_ENABLED:-1}" == "1" ]]; then
        NEW_STATE="0"
        MSG="Homebrew cleanup DISABLED."
        DETAIL="Old versions and cached downloads will be kept."
    else
        NEW_STATE="1"
        MSG="Homebrew cleanup ENABLED."
        DETAIL="'brew cleanup --prune=all' runs after each update."
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "CLEANUP_ENABLED=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^CLEANUP_ENABLED=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^CLEANUP_ENABLED=.*/CLEANUP_ENABLED=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "CLEANUP_ENABLED=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    osascript -e "display dialog \"$MSG\" & return & return & \"$DETAIL\" buttons {\"OK\"} default button \"OK\" with title \"Homebrew Cleanup\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# About Dialog
if [[ "$1" == "about_dialog" ]]; then
    TERM_APP="/System/Applications/Utilities/Terminal.app"

    BUTTON=$(osascript -e 'on run {ver, termPath}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Manager" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." with title "About" buttons {"Visit Codeberg", "Visit GitHub", "Close"} default button "Close" cancel button "Close" with icon POSIX file (termPath & "/Contents/Resources/Terminal.icns")' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION" "$TERM_APP")

    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$PROJECT_URL"
    elif [[ "$BUTTON" == "Visit Codeberg" ]]; then
        open "$PROJECT_URL_CB"
    fi
    exit 0
fi

# Launch Update in Terminal
if [[ "$1" == "launch_update" ]]; then
    # Force reload config to ensure latest terminal choice is used
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "$2"
    exit 0
fi

# Manual Update Check
if [[ "$1" == "check_updates" ]]; then
    check_for_updates_manual
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Manual Homebrew Database Check
# Homebrew has no version to check for the way an app does - this is the
# equivalent of that check for Homebrew itself: pull the latest metadata,
# without upgrading anything. Same lock as a full run, since running this
# alongside "Update Everything" would just make both fight the same lockfile.
if [[ "$1" == "brew_update" ]]; then
    if ! acquire_lock "update" 20; then
        echo "⏳ Another update is already running."
        sleep 3
        exit 1
    fi

    progress_write "running" "brew-update" "" "" ""
    trap 'progress_finalize' EXIT

    echo "📦 Checking Homebrew for updates..."
    if ! brew_update_with_retry; then
        echo "❌ Error: Homebrew update failed after multiple retries."
        exit 1
    fi

    # Refresh what that pull actually changes: the outdated list and
    # Homebrew's own freshness timestamp.
    progress_write "running" "analyze" "" "" ""
    cache_refresh_entry "brew_outdated" brew_outdated_normalized
    cache_refresh_entry "brew_status"   collect_brew_status

    echo "✅ Homebrew database is up to date."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Main Update Execution (Run)
if [[ "$1" == "run" ]]; then
    MODE="${2:-all}"

    set -e
    set -o pipefail

    # Two update runs at once fight over Homebrew's lock files and can corrupt
    # the history log. Wait a short while for a run in progress, then give up
    # instead of racing it. Held for the lifetime of this process.
    if ! acquire_lock "update" 20; then
        echo "⏳ Another update is already running."
        echo "   Wait for it to finish, then start this one again."
        sleep 4
        exit 1
    fi

    progress_write "running" "starting" "" "" ""
    trap 'progress_finalize' EXIT

    # --- SELF-UPDATING APP INSTALL (Sparkle / GitHub) ---
    if [[ "$MODE" == "install" ]]; then
        target_app="$3"
        run_kind="${4:-live}"
        DRY_RUN=0
        [[ "$run_kind" == "dry" || "$run_kind" == "--dry-run" ]] && DRY_RUN=1

        if [[ -z "$target_app" ]]; then
            echo "❌ No application specified."
            sleep 3
            exit 1
        fi

        if (( DRY_RUN )); then
            echo "🧪 DRY RUN - every step runs except the replacement itself."
        fi
        progress_write "running" "install-app" "$target_app" "" ""
        echo "🚀 Preparing update for $target_app..."
        echo "---------------------------"

        # Look the entry up in the cache instead of trusting menu parameters
        entry=""
        for cache_line in ${(f)"$(cache_get "app_updates")"}; do
            [[ -n "$cache_line" ]] || continue
            [[ "${${(@s:|:)cache_line}[2]}" == "$target_app" ]] || continue
            entry="$cache_line"
            break
        done

        if [[ -z "$entry" ]]; then
            echo "❌ No pending update recorded for $target_app."
            echo "   Refresh the menu and try again."
            sleep 4
            exit 1
        fi

        entry_fields=("${(@s:|:)entry}")
        app_method="${entry_fields[1]}"
        app_local="${entry_fields[3]}"
        app_remote="${entry_fields[4]}"
        app_url="${entry_fields[5]}"
        app_sig="${entry_fields[6]}"
        installed_path="/Applications/${target_app}.app"

        echo "   Method:  $app_method"
        echo "   Version: $app_local -> $app_remote"

        if [[ ! -d "$installed_path" ]]; then
            echo "❌ $installed_path does not exist."
            sleep 4
            exit 1
        fi

        # Setapp keeps its own copies in sync; replacing them breaks Setapp
        if [[ "$installed_path" == /Applications/Setapp/* ]]; then
            echo "❌ Setapp manages this application. Use Setapp to update it."
            sleep 4
            exit 1
        fi

        if [[ "$app_method" == "github" || "$app_url" != *.dmg && "$app_url" != *.zip ]]; then
            echo "ℹ️ No direct DMG or ZIP download is available for this app."
            [[ "$app_url" == *.pkg ]] && echo "   .pkg installers are not installed automatically: they run"
            [[ "$app_url" == *.pkg ]] && echo "   scripts as root and cannot be rolled back."
            echo "   Opening the download page instead."
            [[ -n "$app_url" ]] && open "$app_url"
            sleep 4
            exit 0
        fi

        workdir="$(mktemp -d "${TMPDIR:-/tmp}/msu_install.XXXXXX")" || exit 1
        trap 'rm -rf "$workdir"; progress_finalize' EXIT

        archive_name="${app_url:t}"
        archive_path="$workdir/${archive_name}"

        echo "⬇️ Downloading $archive_name..."
        if ! curl -fL --progress-bar --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 600 \
            -H "User-Agent: $USER_AGENT" "$app_url" -o "$archive_path"; then
            echo "❌ Download failed."
            sleep 4
            exit 1
        fi

        echo "📦 Extracting..."
        if ! new_app=$(extract_app_from_archive "$archive_path" "$workdir"); then
            echo "❌ Could not find exactly one application bundle in the archive."
            sleep 4
            exit 1
        fi
        echo "   Found: ${new_app:t}"

        if ! verify_app_replacement "$installed_path" "$new_app" "$app_remote" "$archive_path" "$app_sig"; then
            echo ""
            progress_write "failed" "install-app" "$target_app" "" ""
            echo "🛑 Verification failed. Nothing was changed."
            echo "   $target_app is still at version $app_local."
            sleep 6
            exit 1
        fi

        if (( DRY_RUN )); then
            echo ""
            echo "🧪 DRY RUN complete. All checks passed; no files were modified."
            echo "   Would have replaced: $installed_path"
            sleep 5
            exit 0
        fi

        was_running=0
        app_running "$installed_path" && was_running=1
        quit_running_app "$installed_path"

        echo "🔄 Replacing $target_app..."
        if ! replace_app_bundle "$installed_path" "$new_app"; then
            echo "🛑 Update failed. The previous version has been restored."
            (( was_running )) && open -a "$target_app" 2>/dev/null || true
            sleep 6
            exit 1
        fi

        # Record the outcome the same way Homebrew and App Store updates are
        timestamp=$(date +%s)
        echo "$timestamp|$app_method|$target_app|$app_local|$app_remote|$target_app|ok" >> "$HISTORY_FILE"

        progress_write "done" "install-app" "$target_app" "" ""
        echo "✅ $target_app updated to $app_remote."

        if (( was_running )); then
            echo "   Restarting $target_app..."
            sleep 1
            open -a "$target_app" 2>/dev/null || echo "   Could not restart automatically."
        fi

        echo "🗂️ Refreshing cached data..."
        collect_cache_data "apps"

        echo "🔄 Refreshing SwiftBar..."
        open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
        sleep 2
        exit 0
    fi

    # --- SINGLE APP UPDATE ---
    if [[ "$MODE" == "single" ]]; then
        type="$3"  # brew, cask, or mas
        id="$4"    # package name or app ID
        name="${5:-$id}"  # display name (fallback to id)
        old_ver="${6:-?}"
        new_ver="${7:-?}"

        progress_write "running" "single" "$name" "" ""
        echo "🚀 Updating $name ($old_ver -> $new_ver)..."
        echo "---------------------------"

        update_rc=0
        case "$type" in
            "brew"|"cask")
            brew upgrade "$id" || update_rc=$?
            # Exit code alone is not proof: verify the package left the outdated list
            if (( update_rc == 0 )) && brew_is_outdated "$id"; then
                echo "⚠️ $id is still reported as outdated after the upgrade."
                update_rc=1
            fi
            ;;
        "mas")
            # Use upgrade instead of install to force update for existing apps
            if [[ "$MAS_ENABLED" == "1" ]]; then
                if mas list | awk '{print $1}' | grep -q "^${id}$"; then
                    mas upgrade "$id" || update_rc=$?
                else
                    mas install "$id" || update_rc=$?
                fi
                if (( update_rc == 0 )) && mas_is_outdated "$id"; then
                    echo "⚠️ $name is still reported as outdated after the upgrade."
                    update_rc=1
                fi
            else
                echo "❌ Error: App Store updates are disabled."
                exit 1
            fi
            ;;
        esac

        # Log the real outcome to history
        timestamp=$(date +%s)
        status="ok"
        (( update_rc == 0 )) || status="fail"

        # Format: timestamp|source|name|old_ver|new_ver|id|status
        if echo "$timestamp|$type|$name|$old_ver|$new_ver|$id|$status" >> "$HISTORY_FILE"; then
            echo "📝 Added to history log ($status)."
        fi

        progress_write "$( (( update_rc == 0 )) && print done || print failed )" "single" "$name" "" ""

        # Menu data is cached, so it must be rebuilt before the refresh below
        collect_cache_data "all"

        echo "---------------------------"
        if (( update_rc == 0 )); then
            echo "✅ Update Complete!"
        else
            echo "❌ Update FAILED for $name (exit $update_rc). Logged as failed."
        fi
        echo "🔄 Refreshing SwiftBar..."
        open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
        echo "Done!"
        sleep 1
        exit 0
    fi

    # --- PLUGIN UPDATE SECTION ---
    if [[ "$MODE" == "all" || "$MODE" == "plugin" ]]; then
        if [[ -f "$PENDING_FLAG" ]]; then
            echo "🚀 Updating toolkit components..."

            # Helper scripts: download to a temp file and verify BEFORE replacing
            # the installed copy, so a failed check cannot corrupt what works.
            for component in "setup_mac.sh" "uninstall.sh"; do
                COMPONENT_TMP="$(mktemp "${TMPDIR:-/tmp}/${component}.XXXXXX")"
                if download_verified "$component" "$COMPONENT_TMP"; then
                    mv "$COMPONENT_TMP" "$APP_DIR/$component" && chmod +x "$APP_DIR/$component"
                else
                    echo "⚠️ Skipping $component: keeping the currently installed copy."
                    rm -f "$COMPONENT_TMP"
                fi
            done

            TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.selfupdate.XXXXXX")"

            trap 'rm -f "$TEMP_TARGET"; progress_finalize' EXIT

            if download_verified "update_system.1h.sh" "$TEMP_TARGET" "bitbar.title"; then
                mv "$TEMP_TARGET" "$SCRIPT_FILE" && chmod +x "$SCRIPT_FILE"
                rm -f "$PENDING_FLAG"
                echo "✅ Toolkit updated successfully."

                # If only updating plugin, refresh and exit
                if [[ "$MODE" == "plugin" ]]; then
                    echo "🔄 Refreshing SwiftBar..."
                    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
                    echo "Done!"
                    sleep 1
                    exit 0
                else
                    echo "➡️ Proceeding with system apps..."
                fi
            else
                echo "❌ Plugin update aborted. The running version was left untouched."
                if [[ "$MODE" == "plugin" ]]; then
                    osascript -e "display notification \"Plugin update failed integrity check.\" with title \"Mac Software Manager\"" 2>/dev/null || true
                    sleep 2
                    exit 1
                fi
                echo "➡️ Proceeding with system apps..."
            fi
        elif [[ "$MODE" == "plugin" ]]; then
            echo "ℹ️ No pending plugin updates found."
            sleep 1
            exit 0
        fi
    fi

    # --- SYSTEM UPDATE SECTION ---
    if [[ "$MODE" == "all" || "$MODE" == "system" ]]; then

		echo "🚀 Starting System Update (Homebrew & MAS)..."
		echo "---------------------------"

		progress_write "running" "brew-update" "" "" ""
		echo "📦 Updating Homebrew Database..."
		if ! brew_update_with_retry; then
			echo "❌ Error: Homebrew update failed after multiple retries."
			exit 1
		fi

		# Analyze pending updates to create a snapshot before upgrading
		progress_write "running" "analyze" "" "" ""
		echo "🔍 Analyzing pending updates..."
		typeset -a update_log_buffer
		integer count_brew_pending=0
        integer count_mas_pending=0
		timestamp=$(date +%s)

		# Structured 'brew outdated --json=v2' data: src|token|old|new|pinned
        typeset -a brew_targets
        typeset -a outdated_fields
		for line in "${(@f)$(brew_outdated_normalized)}"; do
			[[ -n "$line" ]] || continue
			outdated_fields=("${(@s:|:)line}")
			(( ${#outdated_fields[@]} >= 5 )) || continue

			src="${outdated_fields[1]}"
			name="${outdated_fields[2]}"
			old_ver="${outdated_fields[3]}"
			new_ver="${outdated_fields[4]}"

			# Pinned formulae must never be upgraded
			if [[ "${outdated_fields[5]}" == "1" ]]; then
				echo "📌 Skipping pinned formula: $name"
				continue
			fi

			# Check if ignored (skip adding to updates)
			if [[ "$src" == "cask" ]] && is_ignored "cask" "$name"; then
				 echo "🚫 Skipping ignored cask: $name"
				 continue
			fi

			brew_targets+=("$name")
			# 6th field mirrors the token so the post-upgrade check can key on it
			update_log_buffer+=("$timestamp|$src|$name|$old_ver|$new_ver|$name")
			((++count_brew_pending))
		done

		# Parse 'mas outdated' output
		if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
			# Redirect stderr to /dev/null to suppress warnings completely
			raw_mas_outdated=$(mas outdated 2>/dev/null || true)
			for line in "${(@f)raw_mas_outdated}"; do
				# Ignore non-application lines. Valid lines MUST start with a number (App ID)
				[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
				[[ -z "$line" ]] && continue

				# Extract ID (First word) - safe string manipulation
				app_id=${line%% *}

				# Skip ignored apps before adding to log buffer
				if is_ignored "mas" "$app_id"; then
					continue
				fi

				# Extract Version Info (Content inside the LAST parentheses)
				# Uses printf for safety against special chars, greedily removes up to last open paren
				ver_info=$(printf '%s\n' "$line" | sed -E 's/.*\(//; s/\)$//')

				# Clean Name using shared function
				app_name=$(clean_mas_name "$line")
				# History records are pipe-delimited: a name may not contain one
				app_name="${app_name//|/}"

				# Split Versions (Old -> New)
				if [[ "$ver_info" == *"->"* ]]; then
					old_ver=${ver_info%% ->*}
					new_ver=${ver_info##*-> }
				else
					old_ver="?"
					new_ver="$ver_info"
				fi

				# Add to buffer
				update_log_buffer+=("$timestamp|mas|$app_name|$old_ver|$new_ver|$app_id")
				((++count_mas_pending))
			done
		fi

		# Execute updates
		echo "🍺 Upgrading Homebrew Formulae and Casks ($count_brew_pending pending)..."

        # Capture brew upgrade output to detect renamed casks
        brew_upgrade_rc=0
        if [[ ${#brew_targets[@]} -gt 0 ]]; then
            # 'exit ${pipestatus[1]}' propagates brew's status instead of tee's,
            # and '|| brew_upgrade_rc=$?' keeps 'set -e' from killing the run.
            progress_write "running" "brew-upgrade" "" "0" "${#brew_targets[@]}"
            upgrade_output=$(brew upgrade --greedy "${brew_targets[@]}" 2>&1 | progress_tap "brew-upgrade" "${#brew_targets[@]}"; exit ${pipestatus[1]}) || brew_upgrade_rc=$?
            if (( brew_upgrade_rc != 0 )); then
                echo "⚠️ 'brew upgrade' exited with status $brew_upgrade_rc. Verifying package by package..."
            fi
        else
            echo "✨ No Homebrew updates to install (ignored apps skipped)."
            upgrade_output=""
        fi

        # Check for renamed cask pattern and auto-migrate
        if echo "$upgrade_output" | grep -q "was renamed to"; then
            echo "🔄 Detected renamed cask(s), attempting auto-migration..."
            echo "$upgrade_output" | grep "was renamed to" | while read -r line; do
                old_cask=$(echo "$line" | sed -E "s/.*Cask ([^ ]+) was renamed to.*/\1/")
                new_cask=$(echo "$line" | sed -E "s/.*was renamed to ([^.]+).*/\1/")
                if [[ -n "$old_cask" && -n "$new_cask" ]]; then
                    echo "  Migrating: $old_cask → $new_cask"
                    brew uninstall --cask "$old_cask" 2>/dev/null || true
                    brew install --cask "$new_cask" 2>/dev/null || true
                fi
            done
            # Re-run upgrade to catch anything else
            echo "📦 Re-running upgrade after migration..."
            if [[ ${#brew_targets[@]} -gt 0 ]]; then
                 brew upgrade --greedy "${brew_targets[@]}" || true
            fi
        fi

		if [[ "$CLEANUP_ENABLED" == "1" ]]; then
			progress_write "running" "cleanup" "" "" ""
			echo "🧹 Cleaning up..."
			brew cleanup --prune=all || true
		else
			echo "⏭️ Skipping cleanup (disabled in preferences)."
		fi

		if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
			progress_write "running" "mas-upgrade" "" "" "$count_mas_pending"
			echo "🍎 Updating App Store Applications ($count_mas_pending pending)..."

			# Check if we have any ignored MAS apps
			has_ignored_mas=false
			if [[ -f "$IGNORED_FILE" ]] && grep -q "^mas|" "$IGNORED_FILE" 2>/dev/null; then
				has_ignored_mas=true
			fi

			if [[ "$has_ignored_mas" == "true" ]]; then
				# Update each non-ignored app individually to respect ignore list
				echo "   (Updating apps individually to respect ignore list)"
				mas outdated 2>/dev/null | while read -r line; do
					[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
					app_id=${line%% *}
					# Skip if this app is in our ignore list
					if grep -qE "^mas\|${app_id}(\||$)" "$IGNORED_FILE" 2>/dev/null; then
						continue
					fi
					progress_write "running" "mas-upgrade" "$(clean_mas_name "$line")" "" "$count_mas_pending"
					mas upgrade "$app_id" || true
				done
			else
				# No ignored apps, use faster bulk upgrade
				mas upgrade || true
			fi
		fi

		# Verify the outcome before writing history.
		# Anything still on the outdated list did NOT update, whatever brew/mas returned.
		integer count_failed=0
		if [[ ${#update_log_buffer[@]} -gt 0 ]]; then
			progress_write "running" "verify" "" "" ""
			echo "🔎 Verifying results..."

			# NOTE: the map key must be built in a variable first. An unquoted
			# '|' inside an assignment subscript is parsed as a pipe by zsh.
			typeset -A still_outdated
			typeset map_key=""
			for tok in "${(@f)$(brew_outdated_tokens)}"; do
				[[ -n "$tok" ]] || continue
				map_key="brew|$tok"
				still_outdated[$map_key]=1
			done
			if [[ "$MAS_ENABLED" == "1" ]]; then
				for verify_id in "${(@f)$(mas_outdated_ids)}"; do
					[[ -n "$verify_id" ]] || continue
					map_key="mas|$verify_id"
					still_outdated[$map_key]=1
				done
			fi

			typeset -a verified_log
			typeset -a entry_fields
			for entry in "${update_log_buffer[@]}"; do
				entry_fields=("${(@s:|:)entry}")
				entry_src="${entry_fields[2]}"
				entry_name="${entry_fields[3]}"
				entry_id="${entry_fields[6]}"
				entry_status="ok"

				case "$entry_src" in
					"brew"|"cask") map_key="brew|$entry_id" ;;
					"mas")         map_key="mas|$entry_id" ;;
					*)             map_key="" ;;
				esac
				[[ -n "$map_key" && -n "${still_outdated[$map_key]}" ]] && entry_status="fail"

				if [[ "$entry_status" == "fail" ]]; then
					((++count_failed))
					echo "   ❌ $entry_name is still outdated - recording as failed."
				fi

				# Format: timestamp|source|name|old_ver|new_ver|id|status
				verified_log+=("$entry|$entry_status")
			done

			mkdir -p "$(dirname "$HISTORY_FILE")"

            # Use 'printf' instead of 'print' to avoid "bad output format" errors
			if printf "%s\n" "${verified_log[@]}" >> "$HISTORY_FILE"; then
			    echo "📝 Logged ${#verified_log[@]} updates ($((${#verified_log[@]} - count_failed)) ok, $count_failed failed)."
            else
                echo "❌ Failed to write to history file."
            fi

			# Keep file size manageable
			if [[ $(wc -l < "$HISTORY_FILE") -gt 500 ]]; then
				 tail -n 300 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
			fi
        fi
    fi

    # Menu data is cached: rebuild it so the refresh below shows the new state
    echo "🗂️ Refreshing cached data..."
    collect_cache_data "all"

    progress_write "done" "complete" "" "" ""

    echo "---------------------------"
    if (( count_failed > 0 )); then
        echo "⚠️ Update finished with $count_failed failed item(s). See history for details."
    else
        echo "✅ Update Complete!"
    fi
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    echo "Done!"
    sleep 1
    exit 0
fi

# ==============================================================================
# 6. BACKGROUND CHECKS & STATS (CACHE-BACKED)
# ==============================================================================
# SwiftBar re-runs this path on every menu draw, so it must not touch the
# network or shell out to brew/mas. Everything comes from the cache; stale
# tiers are rebuilt by a detached background process that refreshes the menu
# when it finishes. Ignore-list filtering stays here because it is free and
# must react immediately.

# Check pending flag
update_available=0
[[ -f "$PENDING_FLAG" ]] && update_available=1

cache_stale="$(cache_stale_tiers)"
cache_ts=$(cache_last_check)
[[ -n "$cache_stale" ]] && spawn_cache_refresh "auto"

# Pinned formulae (native brew pin) as an array - empty lines dropped
typeset -a pinned_arr
for cache_line in ${(f)"$(cache_get "brew_pinned")"}; do
    [[ -n "$cache_line" ]] && pinned_arr+=("$cache_line")
done

# Homebrew updates from the normalized cache: src|token|old|new|pinned
# Pinned formulae and ignored casks are dropped by exact token match - no
# regex over free-form text, so a '+' or '.' in a token cannot misfire.
typeset -a brew_entries entry_fields
brew_entries=()
for cache_line in ${(f)"$(cache_get "brew_outdated")"}; do
    [[ -n "$cache_line" ]] || continue
    entry_fields=("${(@s:|:)cache_line}")
    (( ${#entry_fields[@]} >= 5 )) || continue

    # entry_fields: 1=src 2=token 3=old 4=new 5=pinned
    [[ "${entry_fields[5]}" == "1" ]] && continue
    [[ ${pinned_arr[(Ie)${entry_fields[2]}]} -gt 0 ]] && continue
    [[ "${entry_fields[1]}" == "cask" ]] && is_ignored "cask" "${entry_fields[2]}" && continue

    brew_entries+=("$cache_line")
done

count_brew=${#brew_entries[@]}

# Check App Store for updates (filter ignored MAS apps)
list_mas=""
count_mas=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    list_mas=$(cache_get "mas_outdated" || true)

    # OPTIMIZED: Filter out ignored MAS apps using memory cache
    typeset -a ignored_mas_patterns
    for key in ${(k)IGNORED_APPS_MAP}; do
        if [[ "$key" == mas\|* ]]; then
            # Match ID at start of line + TRAILING SPACE to avoid partial ID matches
            # e.g. ensure ID "123" doesn't match "12345"
            ignored_mas_patterns+=("^[[:space:]]*${key#mas|}[[:space:]]")
        fi
    done

    if [[ ${#ignored_mas_patterns[@]} -gt 0 ]]; then
        # Use <<< for safety and || true to prevent exit code 1 if all updates are ignored
        list_mas=$(grep -vE "${(j:|:)ignored_mas_patterns}" <<< "$list_mas" || true)
    fi

    count_mas=$(echo "$list_mas" | grep -E '^[[:space:]]*[0-9]+' | wc -l | tr -d ' ')
fi

# MANUAL CHECK FOR GHOST APPS
# Apple titles the mas CLI regularly misses. The iTunes Lookup calls happen in
# the background refresh (collect_manual_updates); here we only read the result.
# Line format: name|local_version|remote_version|app_id
manual_updates_list=""
count_manual=0

if [[ "$MAS_ENABLED" == "1" ]]; then
    for cache_line in ${(f)"$(cache_get "manual_updates")"}; do
        [[ -n "$cache_line" ]] || continue
        manual_id="${cache_line##*|}"
        # The ignore list can change between refreshes: honour it at render time
        is_ignored "mas" "$manual_id" && continue
        manual_updates_list+="$cache_line"$'\n'
        ((++count_manual))
    done
fi

# SELF-UPDATING APPS (Sparkle appcast / GitHub releases)
# Detection only: the menu links to the publisher's download, it never installs.
# Line format: method|name|local_version|remote_version|url|signature
app_updates_list=""
count_apps=0

for cache_line in ${(f)"$(cache_get "app_updates")"}; do
    [[ -n "$cache_line" ]] || continue
    entry_fields=("${(@s:|:)cache_line}")
    (( ${#entry_fields[@]} >= 4 )) || continue
    is_ignored "sparkle" "${entry_fields[2]}" && continue
    app_updates_list+="$cache_line"$'\n'
    ((++count_apps))
done

# Aggregate total updates count
total=$((count_brew + count_mas + count_manual + count_apps))

# Collect installed stats
# Casks
raw_casks=$(cache_get "brew_casks" || true)
count_casks=$(echo -n "$raw_casks" | grep -c -- '[^[:space:]]' || true)

# Formulae
raw_formulae=$(cache_get "brew_formulae" || true)
count_formulae=$(echo -n "$raw_formulae" | grep -c -- '[^[:space:]]' || true)

# MAS (App Store)
installed_mas=""
count_mas_installed=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    installed_mas=$(cache_get "mas_list" || true)
    count_mas_installed=$(echo -n "$installed_mas" | grep -c -- '[^[:space:]]' || true)
fi
total_installed=$((count_casks + count_formulae + count_mas_installed))

# History Stats
count_7d=0
count_30d=0
history_7d=""
history_30d=""
# Track last printed date for grouping headers
last_date_7d=""
last_date_30d=""
current_time=$(date +%s)

if [[ -f "$HISTORY_FILE" ]]; then
    # Read file in reverse order (newest first) using sed
    # Records written before v1.5 have no status field; those are treated as "ok"
    while IFS='|' read -r log_time log_src log_name log_old log_new log_id log_status; do

        # Skip legacy entries, invalid timestamps
        if [[ -z "$log_time" || ! "$log_time" =~ ^[0-9]+$ ]]; then continue; fi
        if [[ -z "$log_name" || -z "$log_new" ]]; then continue; fi

        # Calculate age of the update
        diff=$((current_time - log_time))

        # Stop processing if older than 30 days (optimization)
        if [[ $diff -gt 2592000 ]]; then break; fi

        # Determine Icon
        icon="terminal"
        [[ "$log_src" == "cask" ]] && icon="square.stack.3d.up"
        [[ "$log_src" == "mas" ]] && icon="bag"
        [[ "$log_src" == "sparkle" ]] && icon="sparkles"
        [[ "$log_src" == "github" ]] && icon="chevron.left.forwardslash.chevron.right"

        # Failed attempts are kept in the log but must not read as successes
        entry_failed=0
        if [[ "$log_status" == "fail" ]]; then
            entry_failed=1
            icon="xmark.circle"
        fi

        # Clean up log_name for display (fixes corrupted entries with IDs or versions)
        clean_name=$(clean_mas_name "$log_name")

        # Truncate versions
        short_old=$(truncate_ver "$log_old")
        short_new=$(truncate_ver "$log_new")
        strftime -s log_date_str "%d %b" "$log_time"
        local link_param=""
        case "$log_src" in
            "brew") link_param=" href='https://formulae.brew.sh/formula/${log_name}'" ;;
            "cask") link_param=" href='https://formulae.brew.sh/cask/${log_name}'" ;;
            "mas")
                # Checks if ID exists for backward compatibility
                if [[ -n "$log_id" ]]; then
                    link_param=" href='https://apps.apple.com/app/id${log_id}'"
                else
                    link_param=" href='https://apps.apple.com/search?term=${clean_name// /%20}'"
                fi
                ;;
        esac

        # Format date header line
        header_line="---- ${log_date_str}: | color=$COLOR_INFO size=11 sfimage=calendar"

        # Format item line with visual indentation (spaces) instead of date
        # Use clean_name instead of raw log_name
        if (( entry_failed )); then
            item_line="----    ${clean_name} [${short_old} → ${short_new}] FAILED | size=11 sfimage=$icon font=Monaco color=$COLOR_WARN${link_param}"
        else
            item_line="----    ${clean_name} [${short_old} → ${short_new}] | size=11 sfimage=$icon font=Monaco${link_param}"
        fi

        # Populate 7 Days Bucket
        if [[ $diff -le 604800 ]]; then
            if [[ "$log_date_str" != "$last_date_7d" ]]; then
                history_7d+="${header_line}"$'\n'
                last_date_7d="$log_date_str"
            fi
            history_7d+="${item_line}"$'\n'
            # Counters report successful updates only
            (( entry_failed )) || ((++count_7d))
        fi

        # Populate 30 Days Bucket (includes 7 days items)
        if [[ $diff -le 2592000 ]]; then
            if [[ "$log_date_str" != "$last_date_30d" ]]; then
                history_30d+="${header_line}"$'\n'
                last_date_30d="$log_date_str"
            fi
            history_30d+="${item_line}"$'\n'
            (( entry_failed )) || ((++count_30d))
        fi

    done < <(tail -r "$HISTORY_FILE")
fi

# ==============================================================================
# 7. UI RENDERING
# ==============================================================================

# Prepare script path for buttons
script_path="$(swiftbar_sq_escape "$SCRIPT_FILE")"

# Freshness label: the menu shows cached data, so report when it was collected
if (( cache_ts > 0 )); then
    strftime -s cache_time_str "%H:%M" "$cache_ts"
    last_check_label="Last check: $cache_time_str"
else
    last_check_label="Last check: collecting data..."
fi
[[ -n "$cache_stale" ]] && last_check_label+=" (refreshing...)"

# Main Bar Icon
if [[ $update_available -eq 1 ]]; then
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.down.circle.fill color=$COLOR_PURPLE"
    else
        echo " ! | sfimage=arrow.down.circle.fill color=$COLOR_BLUE"
    fi
else
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.triangle.2.circlepath.circle color=$COLOR_WARN"
    elif (( cache_ts == 0 )); then
        # No cache yet: do not claim the system is up to date
        echo " | sfimage=hourglass"
    else
        echo " | sfimage=checkmark.circle"
    fi
fi
echo "---"

# Render Plugin Update Notification
if [[ $update_available -eq 1 ]]; then
    echo "Plugin Update Available (Click to Install) | color=$COLOR_BLUE sfimage=arrow.down.circle.fill bash='$script_path' param1=launch_update param2=plugin terminal=false refresh=true"
    echo "---"
fi

# Show update details
if [[ ${#CONFIG_WARNINGS[@]} -gt 0 ]]; then
    echo "Config Warnings (${#CONFIG_WARNINGS[@]}) | color=$COLOR_WARN size=11 sfimage=exclamationmark.triangle"
    for warning in "${CONFIG_WARNINGS[@]}"; do
        echo "-- $warning | color=$COLOR_WARN size=10 trim=true"
    done
    echo "---"
fi

if [[ $total -eq 0 ]]; then
    if (( cache_ts == 0 )); then
        echo "Collecting update data... | color=$COLOR_INFO sfimage=hourglass"
    elif [[ $update_available -eq 1 ]]; then
        echo "Local apps are up to date | color=$COLOR_INFO size=10"
    else
        echo "System is up to date | color=$COLOR_SUCCESS sfimage=checkmark.shield"
    fi
    echo "$last_check_label | size=10 color=$COLOR_INFO"
else
    # System Updates Header (Clickable)
    if [[ $((count_brew + count_mas)) -gt 0 ]]; then
        echo "Update System Apps ($((count_brew + count_mas))) | color=$COLOR_INFO size=12 sfimage=arrow.triangle.2.circlepath bash='$script_path' param1=launch_update param2=system terminal=false refresh=true"
        echo "$last_check_label | size=10 color=$COLOR_INFO"
    fi

    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=$COLOR_INFO size=12 sfimage=shippingbox"
        for cache_line in "${brew_entries[@]}"; do
            entry_fields=("${(@s:|:)cache_line}")
            pkg_type="${entry_fields[1]}"
            name="${entry_fields[2]}"
            old_ver_clean=$(clean_version "${entry_fields[3]}")
            new_ver_clean=$(clean_version "${entry_fields[4]}")

            # Every value below reaches a shell command line via SwiftBar params
            safe_name=$(swiftbar_sq_escape "$name")
            safe_old=$(swiftbar_sq_escape "$old_ver_clean")
            safe_new=$(swiftbar_sq_escape "$new_ver_clean")

            if [[ "$pkg_type" == "cask" ]]; then
                display_line="$name ($old_ver_clean) != $new_ver_clean"
            else
                display_line="$name ($old_ver_clean) < $new_ver_clean"
            fi

            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            echo "-- Update $name | bash='$script_path' param1=update_app param2=$pkg_type param3='$safe_name' param4='$safe_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle"
            echo "-- Ignore $name | bash='$script_path' param1=ignore_app param2=$pkg_type param3='$safe_name' param4='$safe_name' terminal=false refresh=true sfimage=eye.slash"
        done
        echo "---"
    fi

    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=$COLOR_INFO size=12 sfimage=bag"
        echo "$list_mas" | while read -r line; do
            app_id=${line%% *}
            # Clean display line: remove ID, clean extra spaces
            display_line=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]{2,}/ /g')

            # Extract app name (remove version info in parentheses)
            app_name=$(echo "$display_line" | sed -E 's/[[:space:]]*\([^)]+\)$//')

            # Extract versions for history logging
            # Format usually: Name (OldVer -> NewVer)
            ver_info=$(echo "$display_line" | sed -E 's/.*\(//; s/\)$//')
            if [[ "$ver_info" == *"->"* ]]; then
                old_ver=${ver_info%% ->*}
                new_ver=${ver_info##*-> }
            else
                old_ver="?"
                new_ver="$ver_info"
            fi

            # App Store names routinely contain apostrophes, and every value
            # here ends up on a shell command line built by SwiftBar
            safe_id=$(swiftbar_sq_escape "$app_id")
            safe_app_name=$(swiftbar_sq_escape "$app_name")
            safe_old=$(swiftbar_sq_escape "$old_ver")
            safe_new=$(swiftbar_sq_escape "$new_ver")

            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            # Added param5 and param6 for version logging
            echo "-- Update $app_name | bash='$script_path' param1=update_app param2=mas param3='$safe_id' param4='$safe_app_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle"
            echo "-- Ignore $app_name | bash='$script_path' param1=ignore_app param2=mas param3='$safe_id' param4='$safe_app_name' terminal=false refresh=true sfimage=eye.slash"
        done
    fi

    # Manual updates: App Store ghosts plus self-updating (Sparkle) apps.
    # Neither can be installed from here, so both link out instead.
    if [[ $((count_manual + count_apps)) -gt 0 ]]; then
        echo "Manual Update Required ($((count_manual + count_apps))): | color=$COLOR_WARN size=12 sfimage=exclamationmark.triangle"
        echo "$manual_updates_list" | while IFS='|' read -r name ver_local ver_remote id; do
            if [[ -n "$name" ]]; then
			    # Link directs to App Store or web, as these are manual
                safe_name=$(swiftbar_sq_escape "$name")
                safe_id=$(swiftbar_sq_escape "$id")
                safe_old=$(swiftbar_sq_escape "$ver_local")
                safe_new=$(swiftbar_sq_escape "$ver_remote")
                echo "-- Update $name ($ver_local -> $ver_remote) | bash='$script_path' param1=update_app param2=mas param3='$safe_id' param4='$safe_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle color=$COLOR_WARN"
            fi
        done

        # Self-updating apps: link out to the publisher, never install from here
        if [[ $count_apps -gt 0 ]]; then
            print -rn -- "$app_updates_list" | while IFS='|' read -r sp_method sp_name sp_local sp_remote sp_url sp_sig; do
                [[ -n "$sp_name" ]] || continue
                safe_name=$(swiftbar_sq_escape "$sp_name")
                safe_url=$(swiftbar_sq_escape "$sp_url")

                if [[ "$sp_method" == "github" ]]; then
                    sp_icon="chevron.left.forwardslash.chevron.right"
                    sp_action="Open release page"
                else
                    sp_icon="sparkles"
                    sp_action="Download $sp_remote"
                fi

                echo "-- $sp_name ($sp_local -> $sp_remote) | color=$COLOR_WARN size=12 font=Monaco sfimage=$sp_icon"
                if [[ -n "$sp_url" ]]; then
                    echo "---- $sp_action | href='$safe_url' sfimage=arrow.down.circle"
                fi

                # Automatic replacement is opt-in and only ever offered for a
                # direct DMG/ZIP download (see AUTO_INSTALL_APPS).
                if [[ "$AUTO_INSTALL_APPS" == "1" && ( "$sp_url" == *.dmg || "$sp_url" == *.zip ) ]]; then
                    echo "---- Install $sp_remote | bash='$script_path' param1=install_app param2='$safe_name' param3=live terminal=false refresh=false sfimage=square.and.arrow.down.on.square"
                    echo "---- Dry run (no changes) | bash='$script_path' param1=install_app param2='$safe_name' param3=dry terminal=false refresh=false sfimage=testtube.2"
                fi
                echo "---- Ignore $sp_name | bash='$script_path' param1=ignore_app param2=sparkle param3='$safe_name' param4='$safe_name' terminal=false refresh=true sfimage=eye.slash"
            done
        fi

        echo "---"
    fi

fi

# Statistics Submenu
echo "---"
echo "Monitored: $total_installed items | color=$COLOR_INFO size=12 sfimage=chart.bar.xaxis"

ignored_casks_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == cask\|* ]] && ignored_casks_list+=("${key#cask|}")
done
ignored_casks="${ignored_casks_list[*]}"

# Casks submenu with versions (Truncated to 20 chars)
echo "-- Apps (Brew Cask): $count_casks | color=$COLOR_INFO size=11 sfimage=square.stack.3d.up"
if [[ -n "$raw_casks" ]]; then
    # Pass ignored_casks generated from memory, not file
    echo "$raw_casks" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_casks" '
    # Every value below lands inside a single-quoted shell argument built by
    # SwiftBar. Turn each embedded quote into the '"'"' sequence.
    # ("\\" is one backslash in awk source; macOS awk passes it through gsub.)
    function sq(s) { gsub(q, q "\\" q q, s); return s }
    {
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
        action = is_ignored ? "Unignore" : "Ignore";
        param1 = is_ignored ? "unignore_app" : "ignore_app";
        safe_token = sq(token);

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/cask/" safe_token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=cask param3=" q safe_token q " param4=" q safe_token q " terminal=false refresh=true sfimage=eye";
    }'
fi

pinned_formulae_list="${pinned_arr[*]}"

# Brew Formulae
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=$COLOR_INFO size=11 sfimage=terminal"
if [[ -n "$raw_formulae" ]]; then
    echo "$raw_formulae" | awk -v q="'" -v sp="$script_path" -v ign="$pinned_formulae_list" '
    function sq(s) { gsub(q, q "\\" q q, s); return s }
    {
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";

        action = is_ignored ? "Unignore" : "Ignore";

        param1 = is_ignored ? "unignore_app" : "ignore_app";
        safe_token = sq(token);

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/formula/" safe_token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=brew param3=" q safe_token q " param4=" q safe_token q " terminal=false refresh=true sfimage=eye";
    }'
fi

ignored_mas_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == mas\|* ]] && ignored_mas_list+=("${key#mas|}")
done
ignored_mas="${ignored_mas_list[*]}"

# App Store
if [[ "$MAS_ENABLED" == "1" ]]; then
	echo "-- App Store: $count_mas_installed | color=$COLOR_INFO size=11 sfimage=bag"
	if [[ -n "$installed_mas" ]]; then
	    echo "$installed_mas" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_mas" '
	    function sq(s) { gsub(q, q "\\" q q, s); return s }
	    {
	        id=$1;
	        $1="";
	        name=$0;
	        gsub(/^[ \t]+|[ \t]+$/, "", name);

	        is_ignored = (index(" " ign " ", " " id " ") > 0);
	        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
	        action = is_ignored ? "Unignore" : "Ignore";
	        param1 = is_ignored ? "unignore_app" : "ignore_app";
	        safe_id = sq(id);
	        safe_name = sq(name);

	        print "---- " name " | href=" q "https://apps.apple.com/app/id" safe_id q " size=11 font=Monaco trim=true" color_str;
	        print "------ " action " | bash=" q sp q " param1=" param1 " param2=mas param3=" q safe_id q " param4=" q safe_name q " terminal=false refresh=true sfimage=eye";
	    }'
	fi
else
    echo "-- App Store: Disabled | color=#808080 size=11"
fi
echo "History: | color=$COLOR_INFO size=12 sfimage=clock.arrow.circlepath"

# Render the menus
echo "-- Past 7 days: $count_7d updates | color=$COLOR_INFO size=11 sfimage=calendar"
echo -n "$history_7d"
echo "-- Past 30 days: $count_30d updates | color=$COLOR_INFO size=11 sfimage=calendar.badge.clock"
echo -n "$history_30d"

# Footer & Controls
echo "---"
if [[ $total -gt 0 || $update_available -eq 1 ]]; then
    echo "Update Everything | bash='$script_path' param1=launch_update param2=all terminal=false refresh=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=$COLOR_INFO sfimage=checkmark.circle"
fi

# Forces a full cache rebuild, then refreshes the menu when it completes
echo "Refresh now | bash='$script_path' param1=refresh_cache param2=force terminal=false refresh=true sfimage=arrow.clockwise"

echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"

# Autostart Logic check (Configuration based for performance)
if [[ "${AUTOSTART:-0}" == "1" ]]; then
    as_label="Disable Autostart"
    as_icon="autostartstop.slash"
else
    as_label="Enable Autostart"
    as_icon="autostartstop"
fi
echo "-- $as_label | bash='$script_path' param1=toggle_autostart terminal=false refresh=true sfimage=$as_icon"

echo "-- Change Terminal App | bash='$script_path' param1=change_terminal terminal=false refresh=false sfimage=terminal"
echo "-- Edit Tracked Apps | bash='open' param1='-t' param2='$(swiftbar_sq_escape "$TRACKED_APPS_FILE")' terminal=false refresh=false sfimage=list.bullet.rectangle"

# App Store Toggle Logic
if [[ "$MAS_ENABLED" == "1" ]]; then
    MAS_ICON="bag.fill"
    MAS_LABEL="Disable App Store Updates"
else
    MAS_ICON="bag"
    MAS_LABEL="Enable App Store Updates"
fi
echo "-- $MAS_LABEL | bash='$script_path' param1=toggle_mas terminal=false refresh=true sfimage=$MAS_ICON"

# Homebrew cleanup toggle
if [[ "$CLEANUP_ENABLED" == "1" ]]; then
    CLEANUP_ICON="trash.fill"
    CLEANUP_LABEL="Disable Cleanup After Update"
else
    CLEANUP_ICON="trash.slash"
    CLEANUP_LABEL="Enable Cleanup After Update"
fi
echo "-- $CLEANUP_LABEL | bash='$script_path' param1=toggle_cleanup terminal=false refresh=true sfimage=$CLEANUP_ICON"

# Automatic replacement of self-updating apps (off by default)
if [[ "$AUTO_INSTALL_APPS" == "1" ]]; then
    AUTOINST_ICON="square.and.arrow.down.on.square.fill"
    AUTOINST_LABEL="Disable App Installation"
else
    AUTOINST_ICON="square.and.arrow.down.on.square"
    AUTOINST_LABEL="Enable App Installation"
fi
echo "-- $AUTOINST_LABEL | bash='$script_path' param1=toggle_auto_install terminal=false refresh=true sfimage=$AUTOINST_ICON"

# Pinned items come from the cache (see section 6)
pinned_list="${(F)pinned_arr}"
has_ignored=false
[[ -n "$pinned_list" ]] && has_ignored=true
# Check memory map instead of file size
[[ ${#IGNORED_APPS_MAP} -gt 0 ]] && has_ignored=true

if [[ "$has_ignored" == "true" ]]; then
    # Parent menu item (Active)
    echo "-- Manage Ignored Apps | sfimage=eye.slash"

    # List Pinned Brew Formulae
    if [[ -n "$pinned_list" ]]; then
        echo "---- Formulae (Pinned) | color=$COLOR_INFO size=11"
        echo "$pinned_list" | while read -r pin_name; do
             echo "----   $pin_name | size=11 font=Monaco"
             echo "------   Unignore | bash='$script_path' param1=unignore_app param2=brew param3='$pin_name' param4='$pin_name' terminal=false refresh=true sfimage=eye"
        done
    fi

    # OPTIMIZED: Generate Cask and Mas lists from memory map
    typeset -a sorted_keys
    sorted_keys=("${(@k)IGNORED_APPS_MAP}")
    sorted_keys=("${(@o)sorted_keys}")

    local menu_casks=""
    local menu_mas=""

    for key in "${sorted_keys[@]}"; do

        local ig_type="${key%%|*}"
        local ig_id="${key#*|}"

        # Get name stored in map value
        local display_name="${IGNORED_APPS_MAP[$key]}"
        # Fallback for safety
        [[ -z "$display_name" ]] && display_name="$ig_id"

        # Single line definition to prevent indentation bugs
        safe_name=$(swiftbar_sq_escape "$display_name")
        safe_id=$(swiftbar_sq_escape "$ig_id")
        local item="----   $display_name | size=11 font=Monaco"$'\n'"------   Unignore | bash='$script_path' param1=unignore_app param2=$ig_type param3='$safe_id' param4='$safe_name' terminal=false refresh=true sfimage=eye"

        if [[ "$ig_type" == "cask" ]]; then
            menu_casks+="$item"$'\n'
        elif [[ "$ig_type" == "mas" ]]; then
            menu_mas+="$item"$'\n'
        fi
    done

    # Use echo -n strictly because $item already contains newlines
    if [[ -n "$menu_casks" ]]; then
        echo "---- Casks (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_casks"
    fi

    if [[ -n "$menu_mas" ]]; then
        echo "---- App Store (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_mas"
    fi

else
    # Parent menu item (Disabled/Grayed out)
    echo "-- Manage Ignored Apps (Empty) | color=#808080 sfimage=eye.slash"
fi
# Branch selection menu item
CURRENT_CHANNEL="Stable"
BRANCH_ICON="network"

if [[ "$UPDATE_BRANCH" == "develop" ]]; then
    CURRENT_CHANNEL="Beta/Dev"
    BRANCH_ICON="hammer.fill"
fi

echo "-- Change Channel (Current: $CURRENT_CHANNEL) | bash='$script_path' param1=change_branch terminal=false refresh=true sfimage=$BRANCH_ICON"

echo "-----"
echo "-- Check for Plugin Update | bash='$script_path' param1=check_updates terminal=false refresh=true sfimage=sparkles"
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"
echo "---"
echo "Quit | bash='osascript' param1=-e param2='quit app \"SwiftBar\"' terminal=false sfimage=power"
