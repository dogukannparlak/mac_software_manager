#!/bin/zsh


# ==============================================================================
# 1. GLOBAL CONFIGURATION
# ==============================================================================

# Enable colors for better terminal output visibility
autoload -U colors && colors
set -e
set -o pipefail
# Enable extended globbing to support advanced pattern matching like (#i)
setopt extended_glob

# ------------------------------------------------------------------------------
# COMMAND LINE OPTIONS
# ------------------------------------------------------------------------------
# Every file this installer puts in place normally comes from the published
# repo and has to clear download_verified first. That is the right default for
# users, but it makes developing on a checkout impossible: an unpushed fix on
# disk loses to the older published copy, which verifies fine and is installed
# straight over it. --local exists for exactly that case.
# $0 inside a function is the function's own name in zsh, so both of these are
# captured here, at top level, where $0 is still the script itself.
SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0:t}"
LOCAL_MODE=0

show_help() {
    print -r -- "Usage: ${SCRIPT_NAME} [--local] [-h|--help]

Installs the mac_software_manager update engine and runs the migration wizard.

Options:
  --local     Install the files sitting next to this script, that is from
                ${SCRIPT_DIR}
              instead of downloading them. The download and SHA256
              verification step is skipped entirely.
              Use it while developing on a checkout whose changes are not
              pushed yet: without it, an unpushed local fix is replaced by the
              older published copy, which verifies fine and therefore wins.
              Every file installed this way is reported as unverified.
  -h, --help  Show this help and exit.

Without --local nothing changes: each file is downloaded and verified against
SHA256SUMS (GitHub first, Codeberg as failover), and the copy next to this
script is used only when no verified remote source can be reached."
}

while (( $# > 0 )); do
    case "$1" in
        --local)
            LOCAL_MODE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print -r -- "Unknown option: $1" >&2
            print -r -- "Run '${SCRIPT_NAME} --help' to see the available options." >&2
            exit 1
            ;;
    esac
done

echo ""
echo "${fg[blue]}███╗   ███╗ █████╗  ██████╗ ██████╗ ███████╗${reset_color}"
echo "${fg[blue]}████╗ ████║██╔══██╗██╔════╝██╔═══██╗██╔════╝${reset_color}"
echo "${fg[blue]}██╔████╔██║███████║██║     ██║   ██║███████╗${reset_color}"
echo "${fg[blue]}██║╚██╔╝██║██╔══██║██║     ██║   ██║╚════██║${reset_color}"
echo "${fg[blue]}██║ ╚═╝ ██║██║  ██║╚██████╗╚██████╔╝███████║${reset_color}"
echo "${fg[blue]}╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${reset_color}"
echo ""
echo "${fg[cyan]}--------------------------------------------------${reset_color}"
echo "${fg[bold]}  mac_software_manager${reset_color} v1.5.0"
echo "${fg[cyan]}  Software Update & Application Migration Toolkit${reset_color}"
echo "${fg[cyan]}--------------------------------------------------${reset_color}"
echo "This script will: "
echo "1. Install necessary missing tools (Homebrew, SwiftBar and optionally mas)"
echo "2. Check and Migrate your applications to managed versions"
echo "3. Configure real-time update monitoring"
echo ""
if (( LOCAL_MODE )); then
    echo "${fg[yellow]}⚠️  --local: installing from ${SCRIPT_DIR}${reset_color}"
    echo "${fg[yellow]}    Download and SHA256 verification are deliberately disabled for this${reset_color}"
    echo "${fg[yellow]}    run - not silently skipped. Every engine file below is installed${reset_color}"
    echo "${fg[yellow]}    unverified, straight from this working tree. Development use only.${reset_color}"
    echo ""
fi

# Homebrew: never let a query command trigger an implicit 'brew update'.
# The setup flow runs 'brew update' explicitly where fresh metadata is required.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

# Failover configuration. URL_BACKUP_BASE is filled in once CODEBERG_USERNAME
# is known (existing config, or the prompt further down) - see the "Failover
# Mirror" section. Until then it stays empty, meaning "GitHub only".
URL_PRIMARY_BASE="https://raw.githubusercontent.com/dogukannparlak/mac_software_manager/main"
URL_BACKUP_BASE=""

# Paths of a possible previous installation
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
CONFIG_FILE="$APP_DIR/settings.conf"

# ==============================================================================
# 2. HELPER FUNCTIONS
# ==============================================================================

# Download with Failover (GitHub -> Codeberg)
# Usage: download_with_failover "filename.sh" "output_path"
download_with_failover() {
    local file_name="$1"
    local output_path="$2"

    # Records which mirror served the file, so the integrity check knows which
    # SHA256SUMS counts as the "same source" one.
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

# Expected SHA256 for a file according to a given source's SHA256SUMS
remote_expected_hash() {
    local base_url="$1"
    local file_name="$2"
    local sums=""

    sums=$(curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        "$base_url/SHA256SUMS" 2>/dev/null) || return 1

    # SHA256SUMS lines are "<64 hex>  <filename>"
    print -r -- "$sums" | awk -v target="$file_name" '
        { name = $2; sub(/^\*/, "", name) }
        name == target { print $1; found = 1; exit }
        END { exit !found }
    '
}

# Verify a downloaded script before it is installed:
# checksum from the source it came from, the other mirror agreeing, and the
# file actually parsing as zsh.
verify_download() {
    local file_name="$1"
    local file_path="$2"
    local want_header="${3:-}"
    local actual="" expected_same="" expected_other="" same_base="" other_base=""

    if [[ ! -s "$file_path" ]]; then
        echo "❌ Integrity: downloaded $file_name is empty."
        return 1
    fi

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
        return 1
    fi

    if [[ "$actual" != "$expected_same" ]]; then
        echo "❌ Integrity: checksum mismatch for $file_name."
        echo "   expected $expected_same"
        echo "   got      $actual"
        return 1
    fi

    if expected_other=$(remote_expected_hash "$other_base" "$file_name"); then
        if [[ "$expected_other" != "$expected_same" ]]; then
            echo "❌ Integrity: GitHub and Codeberg publish different checksums for $file_name."
            return 1
        fi
        echo "✅ Integrity verified for $file_name (both sources agree)."
    else
        echo "⚠️ Second source unreachable: $file_name verified against one source only."
    fi

    return 0
}

# Calculate SHA256 Hash
calculate_hash() {
    if [[ ! -f "$1" ]]; then return 1; fi
    shasum -a 256 "$1" | awk '{print $1}'
}

# Download to a temporary file, verify, then move into place.
# The destination is never touched unless every check passes.
download_verified() {
    local file_name="$1"
    local output_path="$2"
    local want_header="${3:-}"
    local tmp_file=""
    local rc=0

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/${file_name}.XXXXXX")" || return 1

    if download_with_failover "$file_name" "$tmp_file" && \
       verify_download "$file_name" "$tmp_file" "$want_header"; then
        mv "$tmp_file" "$output_path" || rc=1
    else
        rc=1
        rm -f "$tmp_file"
    fi

    return $rc
}

# Put one of this project's own files into place.
#
# Default: exactly as before - fetch the published copy, verify it, install it.
# --local: copy the file sitting next to this script instead, and say out loud
# that it went in unchecked. Nothing is skipped quietly here - in this mode a
# file's provenance is "whatever is in this working tree", which no published
# checksum can describe, so the guarantee is dropped on purpose and reported.
install_project_file() {
    local file_name="$1"
    local output_path="$2"
    local want_header="${3:-}"
    local src="$SCRIPT_DIR/$file_name"
    local rc=0

    if (( ! LOCAL_MODE )); then
        download_verified "$file_name" "$output_path" "$want_header" || rc=$?
        return $rc
    fi

    if [[ ! -f "$src" ]]; then
        echo "${fg[red]}❌ --local: $file_name does not exist in $SCRIPT_DIR.${reset_color}"
        return 1
    fi

    # Running the already-installed copy of this script with --local: source
    # and destination are the same file, so there is nothing to copy.
    if [[ "$src" -ef "$output_path" ]]; then
        echo "${fg[yellow]}--local: $file_name is already the installed file - left in place (unverified).${reset_color}"
        return 0
    fi

    cp "$src" "$output_path" || return 1
    echo "${fg[yellow]}--local: $file_name installed from $SCRIPT_DIR - checksum verification deliberately disabled.${reset_color}"
    return 0
}

# Read a single KEY="value" setting from an existing settings.conf.
# Returns non-zero when the file or the key is missing.
read_existing_setting() {
    local key="$1"
    local line=""

    [[ -f "$CONFIG_FILE" ]] || return 1

    line=$(grep -E "^${key}=\"[^\"]*\"$" "$CONFIG_FILE" 2>/dev/null | tail -n 1) || return 1
    [[ -n "$line" ]] || return 1

    line="${line#*=}"
    line="${line#\"}"
    line="${line%\"}"
    print -r -- "$line"
}

# ------------------------------------------------------------------------------
# CASK TOKEN MATCHING
# ------------------------------------------------------------------------------
# User-maintained overrides, one per line:  App Name|cask-token
# Some tokens cannot be derived from the app name at all ("lghub" is the cask
# "logitech-g-hub"), so there has to be a way to state the answer directly.
TOKEN_MAP_FILE="$APP_DIR/app_token_map.conf"

lookup_token_override() {
    local app_name="$1"
    local map_name map_token

    [[ -f "$TOKEN_MAP_FILE" ]] || return 1

    while IFS='|' read -r map_name map_token || [[ -n "$map_name" ]]; do
        # Trim surrounding whitespace from both fields
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

# Split camelCase / PascalCase names into kebab-case.
#   AltTab          -> alt-tab
#   BetterTouchTool -> better-touch-tool
#   HTTPServer      -> http-server
# Homebrew hyphenates where the app name does not, so the plain lowercase form
# ("alttab") misses these casks entirely.
camel_to_kebab() {
    print -r -- "$1" \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]' \
        | tr ' ' '-' \
        | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# Ordered list of plausible cask tokens for an app name, most likely first.
# A manual override wins outright - nothing is guessed after it.
cask_token_candidates() {
    local app_name="$1"
    local override="" base="" camel="" current="" variant=""
    typeset -a out

    if override=$(lookup_token_override "$app_name"); then
        print -r -- "$override"
        return 0
    fi

    base=$(print -r -- "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    camel=$(camel_to_kebab "$app_name")

    out=("$base")
    [[ -n "$camel" && "$camel" != "$base" ]] && out+=("$camel")
    out+=("${base}-app")

    # Strip a trailing version number ("Downie 4" -> "downie")
    variant=$(print -r -- "$base" | sed -E 's/-[0-9]+$//')
    [[ "$variant" != "$base" ]] && out+=("$variant")

    # Dot-less variants ("draw.io" -> "drawio")
    variant="${base//./}"
    [[ "$variant" != "$base" ]] && out+=("$variant")
    variant="${camel//./}"
    [[ -n "$camel" && "$variant" != "$camel" ]] && out+=("$variant")

    # Progressive truncation ("synology-drive-client" -> "synology-drive")
    for current in "$base" "$camel"; do
        [[ -n "$current" ]] || continue
        while [[ "$current" == *-* ]]; do
            current="${current%-*}"
            out+=("$current")
        done
    done

    # (u) keeps the first occurrence of each token and drops later duplicates
    print -rl -- "${(@u)out}"
}

# Escape a string for use inside an AppleScript double-quoted literal.
# Backslashes must be doubled first, otherwise the quote escaping is undone.
applescript_escape() {
  local escaped="${1//\\/\\\\}"
  print -r -- "${escaped//\"/\\\"}"
}

# Download the official Homebrew (un)installer over HTTPS and run it, refusing
# to execute anything empty or truncated. Homebrew's installer is a moving
# target with no published checksum to pin against, so this applies the same
# baseline every other download in this script gets: HTTPS+TLS1.2 enforced,
# content actually present, and it has to parse as bash before it runs.
run_homebrew_script() {
    local url="$1"
    local label="$2"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/homebrew_${label}.XXXXXX")" || return 1

    if ! curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 30 "$url" -o "$tmp_file"; then
        echo "${fg[red]}❌ Error: Could not download the Homebrew $label script.${reset_color}"
        rm -f "$tmp_file"
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then
        echo "${fg[red]}❌ Error: Homebrew $label script downloaded empty. Aborting.${reset_color}"
        rm -f "$tmp_file"
        return 1
    fi

    if ! bash -n "$tmp_file" 2>/dev/null; then
        echo "${fg[red]}❌ Error: Homebrew $label script failed a basic syntax check (truncated or tampered). Aborting.${reset_color}"
        rm -f "$tmp_file"
        return 1
    fi

    /bin/bash "$tmp_file"
    local rc=$?
    rm -f "$tmp_file"
    return $rc
}

# Helper function for yes/no confirmations
ask_confirmation() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        echo -n "$prompt [Y/n] "
    else
        echo -n "$prompt [y/N] "
    fi

    read -r response
    response=${response:-$default}

    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

# Actual process name of an app bundle.
# The bundle name and the executable often differ (Visual Studio Code ->
# "Electron", Ghostty -> "ghostty"), so read CFBundleExecutable and fall back
# to the bundle name.
app_process_name() {
    local app_name="$1"
    local plist="/Applications/${app_name}.app/Contents/Info.plist"
    local exec_name=""

    if [[ -f "$plist" ]]; then
        exec_name=$(defaults read "$plist" CFBundleExecutable 2>/dev/null || true)
    fi

    print -r -- "${exec_name:-$app_name}"
}

# Is this specific app running?
# 'pgrep -f' matches anywhere in the full command line, so short names like
# "Notes" or "Mail" match unrelated processes - and the killall that follows
# would then hit the wrong one. '-x' requires an exact process-name match.
app_is_running() {
    local proc_name
    proc_name=$(app_process_name "$1")
    pgrep -x "$proc_name" >/dev/null 2>&1
}

quit_app() {
    local app_name="$1"
    local proc_name
    proc_name=$(app_process_name "$app_name")

    # Basic check if running
    if app_is_running "$app_name"; then
        echo "Closing ${fg[bold]}$app_name${reset_color}..."
        # Graceful quit attempt
        osascript -e "quit app \"$(applescript_escape "$app_name")\"" 2>/dev/null || true
        # Wait up to 5 seconds
        for i in {1..5}; do
            if ! app_is_running "$app_name"; then break; fi
            sleep 1
        done

        # Force kill if still lingering
        if app_is_running "$app_name"; then
            echo "Forcing close..."
            # Prevent script exit if killall fails (e.g. permission mismatch)
            killall -- "$proc_name" 2>/dev/null || true
        fi
    fi
}

# Moves the specified .app bundle to a backup location.
# Treats the application as a directory (bundle) and attempts sudo if standard move fails.
# Sets global USED_SUDO=1 if sudo was required, 0 otherwise.
# Returns 0 on success, 1 on failure.
backup_app() {
    local app_path="$1"
    local backup_path="$2"
    USED_SUDO=0

    if [[ -d "$app_path" ]]; then
        echo "Backing up original app to '$backup_path'..."
        if ! mv "$app_path" "$backup_path" 2>/dev/null; then
            echo "Permission denied. Attempting with sudo..."
            if sudo mv "$app_path" "$backup_path"; then
                USED_SUDO=1
                return 0
            else
                echo "${fg[red]}Error: Failed to backup app even with sudo${reset_color}"
                return 1
            fi
        fi
    fi
    return 0
}

# Removes a backup directory, using sudo if needed
# Returns 0 on success, 1 on failure
remove_backup() {
    local backup_path="$1"
    local force_sudo="${2:-0}"  # Optional: 1 to force sudo, 0 to try without first

    if [[ ! -e "$backup_path" ]]; then
        return 0  # Nothing to remove
    fi

    echo "Removing backup..."
    if [[ "$force_sudo" -eq 1 ]]; then
        # Backup was created with sudo, so removal likely needs sudo too
        sudo rm -rf "$backup_path" 2>/dev/null
        return $?
    else
        # Try without sudo first
        if ! rm -rf "$backup_path" 2>/dev/null; then
            echo "Permission denied. Attempting with sudo..."
            sudo rm -rf "$backup_path" 2>/dev/null
            return $?
        fi
    fi
    return 0
}

restart_app_if_needed() {
    local app="$1"
    local was_running="$2"

    [[ "$was_running" -eq 1 ]] || return 0
    echo "Restarting ${fg[bold]}$app${reset_color}..."
    # Give the system a moment to register the new bundle
    sleep 1
    open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
}

# Bring an app that already sits in /Applications under Homebrew management.
#
# Preferred path is 'brew install --cask --adopt': Homebrew takes over the
# existing bundle instead of deleting and re-downloading it, so there is no
# window where the user has no app and nothing to roll back.
#
# Adoption requires the installed bundle to match the cask's artifacts. When it
# does not, this falls back to the previous move-aside-and-reinstall flow,
# restoring the backup if the install fails.
migrate_app_to_cask() {
    local app="$1"
    local token="$2"
    local app_path="/Applications/${app}.app"
    local backup_path="/Applications/${app}.app.bak"
    local was_running=0
    local needs_sudo=0

    app_is_running "$app" && was_running=1
    quit_app "$app"

    echo "Adopting the existing installation (no re-download)..."
    if brew install --cask --adopt "$token"; then
        echo "${fg[green]}Migration successful - adopted in place.${reset_color}"
        restart_app_if_needed "$app" "$was_running"
        return 0
    fi

    echo "${fg[yellow]}Adoption not possible. Falling back to a clean re-install...${reset_color}"

    if ! backup_app "$app_path" "$backup_path"; then
        echo "${fg[red]}Aborting: could not back up the current app.${reset_color}"
        restart_app_if_needed "$app" "$was_running"
        return 1
    fi
    needs_sudo=$USED_SUDO

    # Remove stale metadata so Homebrew re-registers the bundle cleanly
    if brew list --cask "$token" &>/dev/null; then
        echo "Unlinking existing Homebrew metadata..."
        brew uninstall --cask "$token" 2>/dev/null || true
    fi

    echo "Installing managed version via Homebrew..."
    if brew install --cask "$token"; then
        echo "${fg[green]}Migration successful!${reset_color}"
        remove_backup "$backup_path" "$needs_sudo"
        restart_app_if_needed "$app" "$was_running"
        return 0
    fi

    # FAILURE - ROLLBACK
    echo ""
    echo "${fg[red]}❌ Error: Homebrew installation failed!${reset_color}"
    echo "Restoring original application from backup..."

    if [[ -d "$app_path" ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo rm -rf "$app_path"
        else
            rm -rf "$app_path" || sudo rm -rf "$app_path"
        fi
    fi

    if [[ -d "$backup_path" ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo mv "$backup_path" "$app_path"
        else
            mv "$backup_path" "$app_path" || sudo mv "$backup_path" "$app_path"
        fi
    fi

    echo "${fg[yellow]}Original application restored. Nothing changed.${reset_color}"
    restart_app_if_needed "$app" "$was_running"
    return 1
}

# ==============================================================================
# 3. CORE LOGIC FUNCTIONS
# ==============================================================================
echo "Starting environment configuration..."

# --- Preserve an existing installation's settings -----------------------------
# Re-running setup must never silently reset the update channel, the autostart
# state or the App Store preference. Existing values become the new defaults.
EXISTING_TERMINAL=""
EXISTING_MAS=""
EXISTING_BRANCH=""
EXISTING_AUTOSTART=""
EXISTING_CLEANUP=""
EXISTING_AUTO_INSTALL=""
EXISTING_CODEBERG_USERNAME=""

if [[ -f "$CONFIG_FILE" ]]; then
    EXISTING_TERMINAL=$(read_existing_setting "PREFERRED_TERMINAL" || true)
    EXISTING_MAS=$(read_existing_setting "MAS_ENABLED" || true)
    EXISTING_BRANCH=$(read_existing_setting "UPDATE_BRANCH" || true)
    EXISTING_AUTOSTART=$(read_existing_setting "AUTOSTART" || true)
    EXISTING_CLEANUP=$(read_existing_setting "CLEANUP_ENABLED" || true)
    EXISTING_AUTO_INSTALL=$(read_existing_setting "AUTO_INSTALL_APPS" || true)
    EXISTING_CODEBERG_USERNAME=$(read_existing_setting "CODEBERG_USERNAME" || true)

    echo "${fg[green]}✓${reset_color} Existing configuration found - your settings will be kept."
    [[ -n "$EXISTING_BRANCH" ]] && echo "  Update channel : $EXISTING_BRANCH"
    [[ -n "$EXISTING_TERMINAL" ]] && echo "  Terminal       : $EXISTING_TERMINAL"
    echo ""

    # Stay on the channel the user is actually on, otherwise this re-install
    # would hand a beta user the stable plugin while the config still says develop.
    if [[ "$EXISTING_BRANCH" == "develop" ]]; then
        URL_PRIMARY_BASE="${URL_PRIMARY_BASE%/main}/develop"
        echo "${fg[yellow]}Beta channel active: components will be fetched from 'develop'.${reset_color}"
        echo ""
    fi
fi

# --- Failover Mirror (Codeberg) -------------------------------------------
# Optional: without a username here, every download in this script and in the
# installed plugin falls back to GitHub only instead of the dual-source check
# the README describes. Not a hard requirement, but left blank on purpose
# rather than guessed, and the toolkit warns about it in the menu when unset.
CODEBERG_USERNAME="$EXISTING_CODEBERG_USERNAME"
echo "Failover mirror: downloads normally come from GitHub, with an optional"
echo "Codeberg mirror as a second, independent source for integrity checks."
echo -n "Codeberg username for the mirror (leave blank to skip) [${CODEBERG_USERNAME:-none}]: "
read -r codeberg_input
if [[ -n "$codeberg_input" ]]; then
    if [[ "$codeberg_input" =~ ^[A-Za-z0-9](-?[A-Za-z0-9])*$ ]]; then
        CODEBERG_USERNAME="$codeberg_input"
    else
        echo "${fg[yellow]}'$codeberg_input' doesn't look like a valid Codeberg username - ignoring it.${reset_color}"
    fi
fi

if [[ -n "$CODEBERG_USERNAME" ]]; then
    CODEBERG_BRANCH="main"
    [[ "$EXISTING_BRANCH" == "develop" ]] && CODEBERG_BRANCH="develop"
    URL_BACKUP_BASE="https://codeberg.org/$CODEBERG_USERNAME/mac_software_manager/raw/branch/$CODEBERG_BRANCH"
    echo "${fg[green]}✓${reset_color} Codeberg mirror configured: $CODEBERG_USERNAME"
else
    URL_BACKUP_BASE=""
    echo "${fg[yellow]}No Codeberg mirror configured - downloads will be verified against GitHub only.${reset_color}"
fi
echo ""

# Default answer follows the previous choice (first install defaults to yes)
MAS_DEFAULT="y"
[[ "$EXISTING_MAS" == "0" ]] && MAS_DEFAULT="n"

MAS_ENABLED=1
if ! ask_confirmation "Do you want to enable App Store (mas) updates?" "$MAS_DEFAULT"; then
    MAS_ENABLED=0
    echo "${fg[yellow]}App Store updates will be disabled.${reset_color}"
else
    echo "${fg[green]}App Store updates enabled.${reset_color}"
fi

# Ensure Homebrew is in the PATH for the current session
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Check for Homebrew installation
if ! command -v brew &> /dev/null; then
    echo "${fg[yellow]}Homebrew not found in PATH. Starting installation...${reset_color}"
    echo "Homebrew is required to manage your packages and updates."
    echo "Note: If you believe Homebrew is already installed, please cancel (Ctrl+C) and add it to your PATH."
    run_homebrew_script "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" "install" || exit 1
    if [[ -f /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)";
    elif [[ -f /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
else
    echo "${fg[green]}Homebrew is already installed.${reset_color}"
fi

# Check for the mas CLI tool (if enabled)
if [[ "$MAS_ENABLED" == "1" ]]; then
    if ! command -v mas &> /dev/null; then
        echo "${fg[yellow]}Installing mas via Homebrew...${reset_color}"
        brew install mas
    else
        echo "${fg[green]}mas tool is present.${reset_color}"
    fi
fi

if ! brew list --cask swiftbar &> /dev/null; then
    echo "${fg[yellow]}Installing SwiftBar...${reset_color}"
    brew install --cask swiftbar
else
    echo "${fg[green]}SwiftBar is already installed.${reset_color}"
fi

echo ""

# Migration Process
if ask_confirmation "Do you want to run the application migration? (Scanning and linking to Brew/AppStore)" y; then

    if [[ "$MAS_ENABLED" == "1" ]]; then
        echo
        echo "⚠️ Warning: Migrating paid apps to the App Store may require repurchasing. Prefer Homebrew to preserve your license."
        echo
    fi

    ENABLE_VERSION_SCAN=0
    if ask_confirmation "Enable detailed version scanning? (helps migration decisions, may slow down the scan)"; then
        ENABLE_VERSION_SCAN=1
    fi

    echo
    echo "Scanning installed applications..."
    echo

    typeset -A app_sources
    typeset -A app_versions
    typeset -a app_list
    typeset -a all_app_paths

    if [[ -d "/opt/homebrew/Caskroom" ]]; then
        CASKROOM_PATH="/opt/homebrew/Caskroom"
    else
        CASKROOM_PATH="/usr/local/Caskroom"
    fi

    # Pre-fetch installed casks for robust detection
    if command -v brew &> /dev/null; then
        INSTALLED_CASKS_STR=" $(brew list --cask | tr '\n' ' ') "
    else
        INSTALLED_CASKS_STR=""
    fi

    # First, collect all app paths to count total for progress bar
    for app_path in /Applications/{,*/,*/*/}*.app(N/); do
        # Skip apps located inside other app bundles to avoid helpers or plugins
        if [[ "$app_path" == *.app/*.app* ]]; then continue; fi

        app_filename=$(basename "$app_path")
        app_name="${app_filename%.app}"

        # Exclude uninstallers and setup tools using case-insensitive globbing
        if [[ "$app_name" == (#i)*uninstall* || "$app_name" == (#i)*updater* || "$app_name" == (#i)*setup* ]]; then
            continue
        fi

        all_app_paths+=("$app_path")
    done

    # Progress bar function
    show_progress() {
        local current=$1
        local total=$2
        local app_name=$3
        local bar_width=40
        local percent=$((current * 100 / total))
        local filled=$((current * bar_width / total))
        local empty=$((bar_width - filled))

        # Build the bar
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done

        # Truncate app name if too long
        local max_name_len=25
        if [[ ${#app_name} -gt $max_name_len ]]; then
            app_name="${app_name:0:$((max_name_len-3))}..."
        fi

        # Print progress bar (using \r to overwrite the line)
        printf "\r${fg[cyan]}[%s]${reset_color} %3d%% (%d/%d) ${fg[yellow]}%-${max_name_len}s${reset_color}" \
            "$bar" "$percent" "$current" "$total" "$app_name"
    }

    total_apps=${#all_app_paths[@]}
    current_app=0

    # Scan all collected applications with progress feedback
    for app_path in "${all_app_paths[@]}"; do
        app_filename=$(basename "$app_path")
        app_name="${app_filename%.app}"

        # Update progress bar
        ((current_app++)) || true
        show_progress $current_app $total_apps "$app_name"

        app_list+=("$app_name")

        # Get local version
        if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
            app_version=$(mdls -name kMDItemVersion -raw "$app_path" 2>/dev/null | tr -d '"' || echo "")
            # Fallback to defaults read if mdls fails or returns (null) - Spotlight dependency
            if [[ -z "$app_version" || "$app_version" == "(null)" ]]; then
                app_version=$(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
            fi

            if [[ -n "$app_version" ]]; then
                 app_versions[$app_name]="$app_version"
            fi
        fi

        # Check if the app is managed by Homebrew via symlink in Caskroom
        if [[ -L "$app_path" ]]; then
            target_path=$(readlink "$app_path")
            if [[ "$target_path" == *"$CASKROOM_PATH"* ]]; then
                app_sources[$app_name]="HOMEBREW"
                continue
            fi
        fi

        # Identify App Store apps by checking for the receipt directory
        if [[ -d "$app_path/Contents/_MASReceipt" ]]; then
            app_sources[$app_name]="APP STORE"
            continue
        fi

        # 3. Fallback Check: Smart Heuristic Matching
        # Candidate tokens (manual override, camelCase split, truncations, ...)
        match_found=0
        candidates=("${(@f)$(cask_token_candidates "$app_name")}")

        # Validate candidates against the list of locally installed casks
        for candidate in "${candidates[@]}"; do
            if [[ "$INSTALLED_CASKS_STR" == *" $candidate "* ]]; then
                app_sources[$app_name]="HOMEBREW"
                match_found=1
                break
            fi
        done

        if [[ "$match_found" -eq 1 ]]; then continue; fi

        # Try to get ID, but if it fails (e.g. system app on read-only volume), default to a fake apple ID
        bundle_id=$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2>/dev/null || echo "com.apple.unknown")
        if [[ "$bundle_id" == com.apple.* ]]; then
            app_sources[$app_name]="SYSTEM"
            continue
        fi

        app_sources[$app_name]="OTHER"
    done

    # Clear progress bar line and move to next line
    printf "\r%-80s\r" " "
    echo "${fg[green]}✔ Scan complete! Found $total_apps applications.${reset_color}"
    echo ""
    echo "${fg[blue]}=== INSTALLED APPLICATIONS ===${reset_color}"

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"
        version="${app_versions[$app]}"
        color="$reset_color"
        [[ "$source" == "HOMEBREW" ]] && color="$fg[green]"
        [[ "$source" == "APP STORE" ]] && color="$fg[cyan]"
        [[ "$source" == "OTHER" ]] && color="$fg[yellow]"

        if [[ -n "$version" ]]; then
            echo "${color}[$source] $app ($version)${reset_color}"
        else
            echo "${color}[$source] $app${reset_color}"
        fi
    done

    echo ""
    echo "${fg[magenta]}=== STARTING MIGRATION PROCESS ===${reset_color}"
    STRICT_MATCH=0
    if [[ "$MAS_ENABLED" == "1" ]]; then
        if ask_confirmation "Enable Strict Matching for App Store? (Reduces false positives, but might miss apps with different store names)"; then STRICT_MATCH=1; fi
    fi

    PROCESS_ONLY_OTHER=0
    if [[ "$MAS_ENABLED" == "1" ]]; then
        prompt="Process ONLY apps not currently managed by Homebrew/App Store?"
    else
        prompt="Process ONLY apps not currently managed by Homebrew?"
    fi
    if ask_confirmation "$prompt"; then PROCESS_ONLY_OTHER=1; fi

    if [[ "$MAS_ENABLED" == "1" ]]; then
        echo "For each app choose: [A]ppStore, [B]rew, [L]eave"
    else
        echo "For each app choose: [B]rew, [L]eave"
    fi

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"

        if [[ "$app" == "SwiftBar" || "$source" == "SYSTEM" ]]; then continue; fi
        if [[ "$PROCESS_ONLY_OTHER" -eq 1 ]]; then
            if [[ "$source" == "HOMEBREW" || ( "$source" == "APP STORE" && "$MAS_ENABLED" == "1" ) ]]; then continue; fi
        fi

        echo ""
        source_color="$reset_color"
        [[ "$source" == "HOMEBREW" ]] && source_color="$fg[green]"
        [[ "$source" == "APP STORE" ]] && source_color="$fg[cyan]"
        [[ "$source" == "OTHER" ]] && source_color="$fg[yellow]"

        if [[ -n "${app_versions[$app]}" ]]; then
            echo "App: ${fg[bold]}${fg[cyan]}$app${reset_color} (Current: ${source_color}$source${reset_color}, Version: ${fg[magenta]}${app_versions[$app]}${reset_color})"
        else
            echo "App: ${fg[bold]}${fg[cyan]}$app${reset_color} (Current: ${source_color}$source${reset_color})"
        fi

        # Pre-check availability
        clean_name=$(echo "$app" | sed 's/[0-9.]*$//' | tr -d ':-')

        # Check App Store (if enabled)
        mas_check=""
        if [[ "$MAS_ENABLED" == "1" ]]; then
            # Search the App Store and ensure that a failed search doesn't kill the script
            mas_check=$(mas search "$clean_name" 2>/dev/null | head -n 1 || true)
        fi

        if [[ -n "$mas_check" ]]; then
            mas_id=$(echo "$mas_check" | awk '{print $1}')
            # Extract name: remove ID from start, remove version (...) from end, trim spaces
            mas_name=$(echo "$mas_check" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//;s/[[:space:]]+\(.*\)$//')
            mas_url="https://apps.apple.com/app/id$mas_id"
            # Strict Matching Logic
            mas_valid=1
            if [[ "$STRICT_MATCH" -eq 1 ]]; then
                norm_app=$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')
                norm_mas=$(echo "$mas_name" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')

                # Default to invalid in strict mode, prove validity
                mas_valid=0

                # Check 1: Prefix match (Store result starts with App Name)
                # Example: "Almighty" matches "Almighty - Powerful Tweaks"
                if [[ "$norm_mas" == "$norm_app"* ]]; then
                    mas_valid=1
                # Check 2: Reverse containment with length guard (Store Name is inside App Name)
                # Example: "Amazon Kindle" contains "Kindle" (length >= 5)
                elif [[ "$norm_app" == *"$norm_mas"* ]] && [[ ${#norm_mas} -ge 5 ]]; then
                    mas_valid=1
                fi
            fi
            if [[ "$mas_valid" -eq 1 ]]; then
                # Extract version from parentheses if present
                if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                    mas_version=$(echo "$mas_check" | sed -E 's/.*\(([^)]+)\)$/\1/')
                    if [[ "$mas_version" != "$mas_check" ]]; then
                        mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color} ${fg[magenta]}$mas_version${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                    else
                        mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                    fi
                else
                    mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                fi
                mas_available=1
            else
                mas_status="${fg[red]}Mismatch in Strict Mode${reset_color} (${fg[yellow]}$mas_name${reset_color})"
                mas_available=0
            fi
        else
            if [[ "$MAS_ENABLED" == "1" ]]; then
                mas_status="${fg[red]}Not found${reset_color}"
            else
                mas_status="${fg[blue]}Searching disabled${reset_color}"
            fi
            mas_available=0
        fi

        # Check Homebrew
        typeset -a token_candidates
        token_candidates=("${(@f)$(cask_token_candidates "$app")}")
        token="${token_candidates[1]}"
        brew_info_output=$(brew info --cask "$token" 2>/dev/null || true)

        if [[ -n "$brew_info_output" ]]; then
            brew_url="https://formulae.brew.sh/cask/$token"

            if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                brew_version=$(echo "$brew_info_output" | head -n 1 | awk '{print $3}')
                brew_status="${fg[green]}Available${reset_color} (${fg[cyan]}$token${reset_color} ${fg[magenta]}$brew_version${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
            else
                brew_status="${fg[green]}Available${reset_color} (${fg[cyan]}$token${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
            fi
            brew_available=1
        else
            # token_candidates already holds every variation worth trying
            # (manual override, camelCase split, dot-less, truncations)
            match_found=0
            matched_token=""
            for candidate in "${token_candidates[@]}"; do
                if brew info --cask "$candidate" &>/dev/null; then
                    matched_token="$candidate"
                    match_found=1
                    break
                fi
            done

            # If direct token attempts fail, fall back to brew search with validation
            if [[ "$match_found" -eq 0 ]]; then
                brew_search=$(brew search --cask "$clean_name" 2>/dev/null | grep -v "Warning" | head -n 1 || true)
                if [[ -n "$brew_search" ]]; then
                    # Normalize names for comparison
                    norm_app=$(echo "$clean_name" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')
                    norm_result=$(echo "$brew_search" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')

                    # Validate match using multiple criteria to reduce false positives
                    match_valid=0

                    # Check 1: Exact match after normalization
                    if [[ "$norm_result" == "$norm_app" ]]; then
                        match_valid=1
                    # Check 2: Search result is prefix of app name (e.g. "cleanshot" is prefix of "cleanshotx")
                    elif [[ "$norm_app" == "$norm_result"* ]] && [[ ${#norm_result} -ge 5 ]]; then
                        match_valid=1
                    # Check 3: App name is prefix of search result (e.g., app "Eve" matches "eve" cask)
                    elif [[ "$norm_result" == "$norm_app"* ]]; then
                        match_valid=1
                    fi

                    if [[ "$match_valid" -eq 1 ]]; then
                        matched_token="$brew_search"
                        match_found=1
                    fi
                fi
            fi

            # Display results based on what was found
            if [[ "$match_found" -eq 1 ]]; then
                token="$matched_token"
                brew_url="https://formulae.brew.sh/cask/$token"

                if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                    brew_version=$(brew info --cask "$token" 2>/dev/null | head -n 1 | awk '{print $3}')
                    brew_status="${fg[yellow]}Found as${reset_color} (${fg[cyan]}$token${reset_color} ${fg[magenta]}$brew_version${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
                else
                    brew_status="${fg[yellow]}Found as${reset_color} (${fg[cyan]}$token${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
                fi
                brew_available=1
            else
                brew_status="${fg[red]}Not found${reset_color}"
                brew_available=0
            fi
        fi

        echo "Options:"
        [[ "$MAS_ENABLED" == "1" ]] && echo "[A]pp Store : $mas_status"
        echo "[B]rew Cask : $brew_status"
        echo "[L]eave     : Keep as is"
        echo "[Q]uit      : Stop migration and continue setup"

        if [[ "$MAS_ENABLED" == "1" ]]; then
            echo -n "Choose action [a/b/l/q]: "
        else
            echo -n "Choose action [b/l/q]: "
        fi
        read -r action
        echo ""

        if [[ "$action" == "q" || "$action" == "Q" ]]; then
            echo "Stopping migration process..."
            break
        fi

        if [[ ( "$action" == "a" || "$action" == "A" ) && "$MAS_ENABLED" == "1" ]]; then
            if [[ "$mas_available" -eq 1 ]]; then
                echo "Using detected App Store match: ${mas_check%% *}"
                # mas_check format is "12345 Name", we want just the ID or just run logic with ID extraction
                mas_id=$(echo "$mas_check" | awk '{print $1}')
                if ask_confirmation "Install from App Store and overwrite current version?" y; then
                    # Check if running before closing
                    was_running=0
                    if app_is_running "$app"; then was_running=1; fi
                    quit_app "$app"

                    app_path="/Applications/${app}.app"
                    backup_path="/Applications/${app}.app.bak"
                    backup_app "$app_path" "$backup_path"
                    needs_sudo=$USED_SUDO

                    [[ "$source" == "HOMEBREW" ]] && brew uninstall --cask "$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" 2>/dev/null || true

                    if mas install "$mas_id"; then
                        echo "Migration successful!"
                        remove_backup "$backup_path" "$needs_sudo"
                        if [[ "$was_running" -eq 1 ]]; then
                            echo "Restarting ${fg[bold]}$app${reset_color}..."
                            open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                        fi
                    else
                         echo "${fg[red]}Error: App Store installation failed. Restoring original app...${reset_color}"
                        if [[ -d "$backup_path" ]]; then
                            if [[ "$needs_sudo" -eq 1 ]]; then
                                sudo mv "$backup_path" "$app_path"
                            else
                                mv "$backup_path" "$app_path" || sudo mv "$backup_path" "$app_path"
                            fi
                        fi
                    fi
                fi
            else
                echo "${fg[red]}Not available on App Store.${reset_color}"
            fi

        elif [[ "$action" == "b" || "$action" == "B" ]]; then
             if [[ "$brew_available" -eq 1 ]]; then
                 # Clarify action to the user
                 if ask_confirmation "Install '$token' via Brew Cask (Migrate to managed)?" y; then
                    # migrate_app_to_cask owns quit, adopt/backup, install and rollback
                    migrate_app_to_cask "$app" "$token" || true
                 fi
             else
                 # Manual fallback logic
                 echo "${fg[yellow]}No automatic match found.${reset_color}"
                 echo "${fg[cyan]}Tip:${reset_color} add a permanent mapping to $TOKEN_MAP_FILE"
                 echo "     in the form:  $app|correct-cask-token"
                 echo -n "Enter Cask name manually (or enter to skip): "
                 read -r user_token
                 if [[ -n "$user_token" ]]; then
                     if brew info --cask "$user_token" &> /dev/null; then
                        if ask_confirmation "Try installing '$user_token'?"; then
                            migrate_app_to_cask "$app" "$user_token" || true

                            # Remember the answer so the next run matches it directly
                            if ! lookup_token_override "$app" >/dev/null; then
                                print -r -- "$app|$user_token" >> "$TOKEN_MAP_FILE"
                                echo "${fg[green]}Saved mapping to $TOKEN_MAP_FILE${reset_color}"
                            fi
                        fi
                     else
                        echo "Skipping: '$user_token' is not a valid Cask."
                     fi
                 fi
             fi
        fi
    done
fi

echo ""
echo "${fg[green]}=== SWIFTBAR CONFIGURATION ===${reset_color}"

# Handle SwiftBar configuration safely
EXISTING_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")

if [[ -n "$EXISTING_DIR" ]]; then
    # Expand tilde if present
    EXPANDED_EXISTING="${EXISTING_DIR/#\~/$HOME}"
    echo "SwiftBar is already configured to use: ${fg[cyan]}$EXPANDED_EXISTING${reset_color}"
    if ask_confirmation "Use this existing directory for the plugin?"; then
        PLUGIN_DIR="$EXPANDED_EXISTING"
    fi
fi

if [[ -z "$PLUGIN_DIR" ]]; then
    DEFAULT_DIR="$HOME/Documents/SwiftBarPlugins"
    if ask_confirmation "Use default directory $DEFAULT_DIR?"; then
        PLUGIN_DIR="$DEFAULT_DIR"
    else
        echo "Enter full path for plugins:"
        read -r user_path
        PLUGIN_DIR="${user_path/#\~/$HOME}"
    fi
    # Only update global setting if it's different or missing
    # Use quotes for variables that might contain spaces in paths
    if [[ "$PLUGIN_DIR" != "$EXPANDED_EXISTING" ]]; then
        defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
    fi
fi

# Create plugin directory
mkdir -p "$PLUGIN_DIR"

# APP_DIR and CONFIG_FILE are defined at the top of this script, because the
# existing configuration has to be read before the first question is asked.
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" 2>/dev/null || true

# Seed the manual token map with instructions, but never overwrite the user's
if [[ ! -f "$TOKEN_MAP_FILE" ]]; then
    cat > "$TOKEN_MAP_FILE" << 'EOF'
# Manual application -> Homebrew cask token mapping.
#
# One mapping per line:   App Name|cask-token
# "App Name" is the bundle name without ".app", exactly as shown in
# /Applications. Matching is case insensitive. Lines starting with # are ignored.
#
# Use this when the automatic guess is wrong or impossible to derive, e.g.:
#   lghub|logitech-g-hub
#   Sublime Text|sublime-text
#
# A mapping always wins over the automatic guesses.
EOF
    chmod 600 "$TOKEN_MAP_FILE" 2>/dev/null || true
fi

echo ""
echo "${fg[yellow]}=== PLUGIN SETTINGS ===${reset_color}"

# Terminal App Configuration
echo ""
echo "Detecting available terminal applications..."

# Supported terminals: display name -> /Applications bundle name (only where
# they differ). Single source of truth for THIS script; update_system.1h.sh
# runs as a separate, independently downloadable script and keeps its own
# copy (TERMINAL_APP_ORDER / TERMINAL_APP_BUNDLE) in sync by hand - add a new
# terminal to both when one shows up.
typeset -a TERMINAL_APP_ORDER
TERMINAL_APP_ORDER=(Terminal iTerm2 Warp Alacritty Ghostty)
typeset -A TERMINAL_APP_BUNDLE
TERMINAL_APP_BUNDLE=(iTerm2 iTerm)

# Detect installed terminal apps
typeset -a detected_terminals
detected_terminals=("Terminal")  # Apple Terminal is always available
echo "  ${fg[green]}✓${reset_color} Terminal (Apple) available"

for candidate_terminal in "${TERMINAL_APP_ORDER[@]}"; do
    [[ "$candidate_terminal" == "Terminal" ]] && continue
    candidate_bundle="${TERMINAL_APP_BUNDLE[$candidate_terminal]:-$candidate_terminal}"
    if [[ -d "/Applications/${candidate_bundle}.app" ]]; then
        detected_terminals+=("$candidate_terminal")
        echo "  ${fg[green]}✓${reset_color} $candidate_terminal detected"
    fi
done

# Present terminal selection if user has options
SELECTED_TERMINAL="Terminal"

# Default index points at the previously configured terminal when it is still installed
DEFAULT_TERMINAL_INDEX=1
if [[ -n "$EXISTING_TERMINAL" ]]; then
    for i in {1..${#detected_terminals[@]}}; do
        if [[ "${detected_terminals[$i]}" == "$EXISTING_TERMINAL" ]]; then
            DEFAULT_TERMINAL_INDEX=$i
            break
        fi
    done
fi
SELECTED_TERMINAL="${detected_terminals[$DEFAULT_TERMINAL_INDEX]}"

if [[ ${#detected_terminals[@]} -gt 1 ]]; then
    echo ""
    echo "Select your preferred terminal app for running updates:"
    for i in {1..${#detected_terminals[@]}}; do
        echo "  [$i] ${detected_terminals[$i]}"
    done

    echo -n "Enter your choice [1-${#detected_terminals[@]}] (default: $DEFAULT_TERMINAL_INDEX - $SELECTED_TERMINAL): "
    read -r terminal_choice

    # Validate input
    if [[ -n "$terminal_choice" ]] && [[ "$terminal_choice" =~ ^[0-9]+$ ]] && \
       [[ "$terminal_choice" -ge 1 ]] && [[ "$terminal_choice" -le ${#detected_terminals[@]} ]]; then
        SELECTED_TERMINAL="${detected_terminals[$terminal_choice]}"
    fi
fi

echo ""
echo "Selected terminal: ${fg[cyan]}$SELECTED_TERMINAL${reset_color}"

# Carry over settings this wizard does not ask about, so a re-run never drops a
# user off the beta channel or silently re-enables autostart.
WRITE_BRANCH="main"
case "$EXISTING_BRANCH" in
    "main"|"develop") WRITE_BRANCH="$EXISTING_BRANCH" ;;
esac

WRITE_AUTOSTART="1"
[[ "$EXISTING_AUTOSTART" == "0" ]] && WRITE_AUTOSTART="0"

WRITE_CLEANUP="1"
[[ "$EXISTING_CLEANUP" == "0" ]] && WRITE_CLEANUP="0"

# Replacing app bundles automatically stays off unless the user turned it on
WRITE_AUTO_INSTALL="0"
[[ "$EXISTING_AUTO_INSTALL" == "1" ]] && WRITE_AUTO_INSTALL="1"

# Write configuration file
cat > "$CONFIG_FILE" << EOF
# Mac Software Manager Configuration
# Generated on $(date)

# Terminal app to use for running updates
# Valid values: Terminal, iTerm2, Warp, Alacritty, Ghostty
PREFERRED_TERMINAL="$SELECTED_TERMINAL"

# App Store Updates (1=Enabled, 0=Disabled)
MAS_ENABLED="$MAS_ENABLED"

# Update Channel (main=Stable, develop=Beta)
UPDATE_BRANCH="$WRITE_BRANCH"

# SwiftBar Autostart State (Syncs with System Events)
AUTOSTART="$WRITE_AUTOSTART"

# Run 'brew cleanup --prune=all' after each update (1=Enabled, 0=Disabled)
CLEANUP_ENABLED="$WRITE_CLEANUP"

# Replace self-updating apps (Sparkle/GitHub) directly from the menu
# (1=Enabled, 0=Disabled). Off by default: every install still verifies the
# developer Team ID and Gatekeeper, but it does replace a running application.
AUTO_INSTALL_APPS="$WRITE_AUTO_INSTALL"

# Codeberg username for the backup mirror (blank = GitHub only, no dual-source
# verification). Set from the "Failover Mirror" prompt earlier in this script.
CODEBERG_USERNAME="$CODEBERG_USERNAME"
EOF

chmod 600 "$CONFIG_FILE" 2>/dev/null || true
echo "Configuration saved to: ${fg[cyan]}$CONFIG_FILE${reset_color}"


# Install/Update the Engine Library (lib/*.sh)
# update_system.1h.sh is now a bootstrap + dispatcher that sources its actual
# functions from $APP_DIR/lib at runtime - it cannot run at all without these,
# so they have to land before the plugin file itself. Kept in $APP_DIR
# (not the SwiftBar plugin folder) for the same reason setup_mac.sh/
# uninstall.sh already are - see "Remove utility scripts from SwiftBar Plugin
# Directory" further down for the bug that taught this project that lesson.
# This list MUST match LIB_NAMES in update_system.1h.sh exactly.
echo "Fetching engine library..."
typeset -a LIB_NAMES
LIB_NAMES=(utils cache ignored history selfupdate updaters selfupdate_apps app_install run_modes menu)

mkdir -p "$APP_DIR/lib"
LIB_INSTALL_FAILED=0
for lib_name in "${LIB_NAMES[@]}"; do
    lib_file="lib/${lib_name}.sh"
    if install_project_file "$lib_file" "$APP_DIR/$lib_file"; then
        :
    elif (( ! LOCAL_MODE )) && [[ -f "./$lib_file" ]]; then
        echo "${fg[yellow]}$lib_file unavailable or unverified remotely - using the local copy from this installer.${reset_color}"
        cp "./$lib_file" "$APP_DIR/$lib_file"
    else
        echo "${fg[red]}❌ Critical Error: No verified source found for $lib_file.${reset_color}"
        LIB_INSTALL_FAILED=1
    fi
done
if [[ "$LIB_INSTALL_FAILED" == "1" ]]; then
    echo "${fg[red]}❌ One or more engine library files could not be installed. The plugin will not run correctly until this is fixed - re-run this installer.${reset_color}"
    exit 1
fi

# Install/Update the Main Plugin (Only this goes to SwiftBar folder)
echo "Fetching latest monitor plugin..."

# A previous install may use a different refresh interval (update_system.6h.sh).
# Reuse that exact file name, otherwise SwiftBar would run two copies of the
# plugin side by side - two menu bar icons, two parallel update checks.
# (Nom) = no error when nothing matches, newest modification time first, so the
# copy SwiftBar has actually been running is the one that survives.
typeset -a existing_plugins
existing_plugins=("$PLUGIN_DIR"/update_system.*.sh(Nom))

TARGET_PLUGIN="$PLUGIN_DIR/update_system.1h.sh"
if [[ ${#existing_plugins[@]} -gt 0 ]]; then
    TARGET_PLUGIN="${existing_plugins[1]}"
    echo "Existing plugin found: ${fg[cyan]}${TARGET_PLUGIN:t}${reset_color} (refresh interval kept)"
fi

# Remove every other copy so only one plugin instance survives
for stale_plugin in "${existing_plugins[@]}"; do
    if [[ "$stale_plugin" != "$TARGET_PLUGIN" ]]; then
        echo "${fg[yellow]}Removing duplicate plugin: ${stale_plugin:t}${reset_color}"
        rm -f "$stale_plugin"
    fi
done

if install_project_file "update_system.1h.sh" "$TARGET_PLUGIN" "bitbar.title"; then
    (( LOCAL_MODE )) || echo "Latest version downloaded and verified."
elif (( ! LOCAL_MODE )) && [[ -f "./update_system.1h.sh" ]]; then
    echo "${fg[yellow]}Remote copy unavailable or unverified - using the local copy from this installer.${reset_color}"
    cp "./update_system.1h.sh" "$TARGET_PLUGIN"
else
    echo "${fg[red]}❌ Critical Error: No verified source found for plugin.${reset_color}"
    exit 1
fi
chmod +x "$TARGET_PLUGIN"

# Install Uninstaller to App Support (Not Plugin Dir)
echo "Updating Uninstaller..."
if ! install_project_file "uninstall.sh" "$APP_DIR/uninstall.sh"; then
    (( ! LOCAL_MODE )) && [[ -f "./uninstall.sh" ]] && cp "./uninstall.sh" "$APP_DIR/uninstall.sh"
fi
chmod +x "$APP_DIR/uninstall.sh"

# Backup Setup Script to App Support
echo "Backing up Setup Wizard..."
cp "$0" "$APP_DIR/setup_mac.sh"
chmod +x "$APP_DIR/setup_mac.sh"

# Remove utility scripts from SwiftBar Plugin Directory if they exist (bug in previous version)
echo "Cleaning up SwiftBar Plugin Directory..."
rm -f "$PLUGIN_DIR/setup_mac.sh"
rm -f "$PLUGIN_DIR/uninstall.sh"

# Restart SwiftBar application to apply changes
echo "Refreshing SwiftBar..."
open -g "swiftbar://refreshallplugins"

# Enable autostart for SwiftBar
echo "Ensuring SwiftBar autostarts at login..."
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "SwiftBar"; then
    echo "Adding SwiftBar to Login Items..."
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1
    echo "${fg[green]}✓ SwiftBar added to Login Items.${reset_color}"
else
    echo "${fg[green]}✓ SwiftBar is already in Login Items.${reset_color}"
fi

# Launch SwiftBar if not already running
if ! pgrep -x "SwiftBar" >/dev/null; then
    echo "Starting SwiftBar..."
    open -a SwiftBar
    sleep 2  # Give SwiftBar time to start before refreshing plugins
fi

echo ""
echo "${fg[green]}Setup complete!${reset_color}"
echo "1. Plugin installed in: ${fg[cyan]}$PLUGIN_DIR${reset_color}"
echo "2. System files moved to: ${fg[cyan]}$APP_DIR${reset_color}"
echo ""
echo "You can now safely delete the Installer folder from your Downloads."
