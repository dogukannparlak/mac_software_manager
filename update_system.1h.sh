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

# ------------------------------------------------------------------------------
# SUPPORTED TERMINALS
# ------------------------------------------------------------------------------
# Single source of truth for every terminal-related list in this script:
# config validation (load_config_safely) and detection ("Change Terminal App").
# Adding a new terminal is one line here. setup_mac.sh runs as a separate,
# independently downloadable script and keeps its own copy in sync by hand.
typeset -a TERMINAL_APP_ORDER
TERMINAL_APP_ORDER=(Terminal iTerm2 Warp Alacritty Ghostty)

# Display name -> /Applications bundle name to check for (only where they differ)
typeset -A TERMINAL_APP_BUNDLE
TERMINAL_APP_BUNDLE=(iTerm2 iTerm)

# True when $1 is one of the supported terminal display names
is_supported_terminal() {
    local name="$1" candidate
    for candidate in "${TERMINAL_APP_ORDER[@]}"; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

# Display names, in TERMINAL_APP_ORDER, that are actually installed.
# Terminal.app ships with macOS, so it is always included.
detect_installed_terminals() {
    local name bundle
    for name in "${TERMINAL_APP_ORDER[@]}"; do
        if [[ "$name" == "Terminal" ]]; then
            print -r -- "$name"
            continue
        fi
        bundle="${TERMINAL_APP_BUNDLE[$name]:-$name}"
        [[ -d "/Applications/${bundle}.app" ]] && print -r -- "$name"
    done
    # Without this, the function's own exit status is whatever the last
    # '[[ -d ... ]] && print' evaluated to - false whenever the last entry in
    # TERMINAL_APP_ORDER (Ghostty) is not installed, which is the common case.
    # That would abort "Change Terminal App" under 'set -e' via
    # 'available_terminals=("${(@f)$(detect_installed_terminals)}")', since
    # zsh (unlike bash) propagates a failing command substitution through
    # errexit. This is an enumeration, not a pass/fail check: it must always
    # succeed.
    return 0
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
                if is_supported_terminal "$value"; then
                    PREFERRED_TERMINAL="$value"
                else
                    add_config_warning "Invalid PREFERRED_TERMINAL value. Using default."
                fi
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
            "CODEBERG_USERNAME")
                if [[ -z "$value" || "$value" == "YOUR_CODEBERG_USERNAME" ]]; then
                    CODEBERG_USERNAME=""
                elif printf '%s\n' "$value" | grep -qE '^[A-Za-z0-9](-?[A-Za-z0-9])*$'; then
                    CODEBERG_USERNAME="$value"
                else
                    CODEBERG_USERNAME=""
                    add_config_warning "Invalid CODEBERG_USERNAME value. Ignoring."
                fi
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
# Codeberg username for the backup mirror. Empty means no mirror is configured
# (set via setup_mac.sh or the "CODEBERG_USERNAME" key in settings.conf) - the
# single source of truth every consumer (this script, setup_mac.sh, the native
# app) reads from, so the three can never disagree about the mirror address.
CODEBERG_USERNAME=""
load_config_safely

# Extract version dynamically from the first 5 lines of the script. Needed for User-Agent and About
VERSION=$(extract_version "$SCRIPT_FILE")

# Failover & Network Config
URL_PRIMARY_BASE="https://raw.githubusercontent.com/dogukannparlak/mac_software_manager/$UPDATE_BRANCH"
USER_AGENT="MacSoftwareUpdater/$VERSION"
PROJECT_URL="https://github.com/dogukannparlak/mac_software_manager"

if [[ -n "$CODEBERG_USERNAME" ]]; then
    URL_BACKUP_BASE="https://codeberg.org/$CODEBERG_USERNAME/mac_software_manager/raw/branch/$UPDATE_BRANCH"
    PROJECT_URL_CB="https://codeberg.org/$CODEBERG_USERNAME/mac_software_manager"
else
    # No mirror configured: every dual-source check below degrades to
    # GitHub-only and says so explicitly, instead of silently downgrading the
    # integrity guarantee. Surfaced in the menu via CONFIG_WARNINGS.
    URL_BACKUP_BASE=""
    PROJECT_URL_CB=""
    add_config_warning "No Codeberg mirror configured (CODEBERG_USERNAME) - downloads and self-update are verified against GitHub only."
fi

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
# 3. ENGINE LIBRARY
# ==============================================================================
# Everything this script used to define inline (cache I/O, brew/mas state,
# Sparkle/GitHub detection, app-bundle replacement, the run-mode handlers, the
# menu renderer) now lives in lib/*.sh, sourced from $APP_DIR/lib so this file
# stays a bootstrap + dispatcher. LIB_NAMES is also the exact list self-update
# downloads and verifies as one atomic set (see run_mode_plugin in
# lib/run_modes.sh) - the two must never drift apart. See CACHE_FORMAT.md and
# the doc comment on each lib file for what lives where.
typeset -a LIB_NAMES
LIB_NAMES=(utils cache ignored history selfupdate updaters selfupdate_apps app_install run_modes menu)

# MSU_LIB_DIR overrides where libs are sourced from - used by the bats test
# suite (tests/test_helper.bash) to point straight at the repo's lib/
# directory instead of a real install. Production never sets it, so this is
# always $APP_DIR/lib there - deliberately NOT the SwiftBar plugin directory
# (see "Cleaning up SwiftBar Plugin Directory" further down in this file for
# why extra files do not belong there).
LIB_DIR="${MSU_LIB_DIR:-$APP_DIR/lib}"
for lib_name in "${LIB_NAMES[@]}"; do
    lib_path="$LIB_DIR/${lib_name}.sh"
    if [[ ! -r "$lib_path" ]]; then
        echo "❌ Missing engine file: $lib_path"
        echo "   Re-run setup_mac.sh to reinstall the toolkit."
        exit 1
    fi
    source "$lib_path"
done

# ==============================================================================
# 5. ACTION HANDLING (ARGUMENTS)
# ==============================================================================
# Everything above this line is pure function/variable definitions (plus the
# harmless config load and pre-flight brew check). A test suite that wants
# those functions without triggering a real run - 'source'-ing this file from
# a zsh subshell instead of executing it - stops right here. $ZSH_EVAL_CONTEXT
# ends in ":file" only when sourced, never on direct execution, so this is a
# no-op for every normal invocation of the script.
[[ "$ZSH_EVAL_CONTEXT" == *:file ]] && return 0

# Every action below is a one-shot command (change a setting, run an update,
# refresh the cache) that does its work and exits - unlike section 6, nothing
# here has to keep going in the face of a broken step. From here through the
# end of "run"/"brew_update", a failing command aborts instead of being
# silently absorbed, so a real bug shows up as a visible failure. Section 6
# (the cache-backed menu draw, which runs on every SwiftBar tick and must
# never go blank over one bad entry) opts back out with its own 'set +e'.
set -e
set -o pipefail

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
            # '|| true': cache_stale_tiers legitimately returns non-zero when
            # nothing is stale (its last '(( )) && print' evaluates false) -
            # that is the normal "up to date" case, not a failure.
            stale_tiers="$(cache_stale_tiers)" || true
            [[ -z "$stale_tiers" ]] && exit 0
            [[ "$stale_tiers" == *"updates"* ]]   && collect_cache_data "updates"
            [[ "$stale_tiers" == *"installed"* ]] && collect_cache_data "installed"
            [[ "$stale_tiers" == *"apps"* ]]      && collect_cache_data "apps"
            [[ "$stale_tiers" == *"websites"* ]]  && collect_cache_data "websites"
            ;;
    esac

    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
        notify "Update frequency changed to $SELECTION."
        sleep 2
        open -g "swiftbar://refreshallplugins" || true
    else
         notify "Frequency is already set to $SELECTION."
    fi
    exit 0
fi

# Toggle Autostart (SwiftBar)
if [[ "$1" == "toggle_autostart" ]]; then
    # Verify actual system state via AppleScript
    if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "SwiftBar"; then
        # '|| true': a race between this check and the actual delete (the user
        # removed it by hand in between) is not a bug worth aborting the toggle
        # over - the config update right below still has to happen.
        osascript -e 'tell application "System Events" to delete login item "SwiftBar"' || true
        NEW_STATE="0"
        MSG="SwiftBar removed from Login Items."
    else
        osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1 || true
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

    notify "$MSG"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    exit 0
fi

# Change Terminal App
if [[ "$1" == "change_terminal" ]]; then
    # Detect available terminals
    typeset -a available_terminals
    available_terminals=("${(@f)$(detect_installed_terminals)}")

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
        notify "Terminal is already set to $SELECTION."
    else
        notify "Terminal changed to $SELECTION."
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
        notify "Already on $SELECTION channel."
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
    if [[ -n "$CODEBERG_USERNAME" ]]; then
        URL_BACKUP_BASE="https://codeberg.org/$CODEBERG_USERNAME/mac_software_manager/raw/branch/$NEW_BRANCH"
    else
        URL_BACKUP_BASE=""
    fi

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

        notify "Switched to $SELECTION channel."
        open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    else
        echo "❌ Error: Could not install the $NEW_BRANCH version. Reverting config."
        notify "Channel switch failed. Config reverted."
        sed -i '' "s/^UPDATE_BRANCH=.*/UPDATE_BRANCH=\"$CURRENT\"/" "$CONFIG_FILE"
    fi
    exit 0
fi

# Install a self-updating app (Sparkle / GitHub) in the user's terminal.
# param2 = app name, param3 = "dry" for a dry run
if [[ "$1" == "install_app" ]]; then
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "install" "$2" "${3:-live}" || true
    exit 0
fi

# Update Single App (launches in user's configured terminal via launch_in_terminal)
if [[ "$1" == "update_app" ]]; then
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "single" "$2" "$3" "$4" "$5" "$6" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    exit 0
fi

# About Dialog
if [[ "$1" == "about_dialog" ]]; then
    TERM_APP="/System/Applications/Utilities/Terminal.app"

    BUTTON=$(osascript -e 'on run {ver, termPath}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Manager" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." with title "About" buttons {"Visit Codeberg", "Visit GitHub", "Close"} default button "Close" cancel button "Close" with icon POSIX file (termPath & "/Contents/Resources/Terminal.icns")' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION" "$TERM_APP")

    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$PROJECT_URL"
    elif [[ "$BUTTON" == "Visit Codeberg" ]]; then
        if [[ -n "$PROJECT_URL_CB" ]]; then
            open "$PROJECT_URL_CB"
        else
            notify "No Codeberg mirror is configured for this install."
        fi
    fi
    exit 0
fi

# Launch Update in Terminal
if [[ "$1" == "launch_update" ]]; then
    # Force reload config to ensure latest terminal choice is used
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "$2" || true
    exit 0
fi

# Manual Update Check
if [[ "$1" == "check_updates" ]]; then
    check_for_updates_manual
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
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

    # Each mode is a function in lib/run_modes.sh. install/single read the
    # script's own positional parameters ($3 onward), so they MUST be called
    # with "$@" - a zsh function gets its own positional parameters from how
    # it is invoked, it does not inherit the caller's. plugin/system read
    # none, so they are always called bare.
    case "$MODE" in
        install) run_mode_install "$@" ;;
        single)  run_mode_single "$@" ;;
        plugin)  run_mode_plugin ;;
        system)  run_mode_system ;;
        all)     run_mode_plugin; run_mode_system ;;
        *)       echo "❌ Unknown mode: $MODE"; exit 1 ;;
    esac
fi

# ==============================================================================
# 6. MENU RENDER
# ==============================================================================
# Nothing above matched $1, so this is a plain SwiftBar draw. render_menu
# (lib/menu.sh) reads only the cache and never shells out to brew/mas/curl.
render_menu
