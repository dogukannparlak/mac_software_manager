#!/bin/zsh

autoload -U colors && colors
set -e

APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"

# ---------------------------------------------------------------------------
# Run from a copy when we are about to delete the folder we live in
# ---------------------------------------------------------------------------
# setup_mac.sh installs this script into $APP_DIR, which is exactly what the
# "data" step deletes. zsh reads a script as it executes it, so removing the
# file mid-run can truncate the rest of the run. Re-exec from a throwaway copy
# before anything else happens, and every step afterwards runs from a file
# nothing is going to delete.
if [[ -z "$MSU_UNINSTALL_RELOCATED" && "${0:A}" == "$APP_DIR"/* ]]; then
    _relocated="$(mktemp "${TMPDIR:-/tmp}/msu_uninstall.XXXXXX")" || exit 1
    cp "${0:A}" "$_relocated"
    chmod +x "$_relocated"
    MSU_UNINSTALL_RELOCATED=1 exec /bin/zsh "$_relocated" "$@"
fi
[[ -n "$MSU_UNINSTALL_RELOCATED" ]] && trap 'rm -f "${0:A}"' EXIT

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
# With no arguments this is the interactive walkthrough it has always been:
# every step asks [y/N] in the terminal before it removes anything.
#
# With step flags it removes exactly the steps named and asks nothing. That is
# how GuideApp's Uninstall page drives it: the choosing already happened in the
# UI, and a y/N prompt on a terminal nobody is looking at would just hang.
usage() {
    cat <<'USAGE'
Usage: uninstall.sh [options]

With no options, walks through every step and asks before each one.

Options:
  --list             Print what is present, one "ITEM|key|yes|no|detail" line
                     per step, and exit without removing anything.
  --all              Run every step below without asking.
  --plugin           Remove the SwiftBar plugin script.
  --app              Remove the GuideApp application bundle.
  --login-item       Remove legacy launch agents for the app.
  --data             Remove ~/Library/Application Support/MacSoftwareUpdater.
  --prefs            Remove the app's preferences (defaults domain).
  --mas              Uninstall the 'mas' Homebrew package.
  --swiftbar         Uninstall the SwiftBar Homebrew cask.
  --app-path PATH    Where the app bundle is, if not /Applications.
  --dry-run          Report what each selected step would do, remove nothing.
  --quiet            Suppress the narration; keep the RESULT| lines.
  --help             Show this.

Naming any step flag turns off the questions. Each selected step then prints
one "RESULT|key|removed|skipped|failed|dryrun|detail" line for a caller to read.

Homebrew itself is never removed: it is a system-wide package manager holding
software unrelated to this toolkit. See https://brew.sh to remove it.
USAGE
}

INTERACTIVE=1
DRY_RUN=0
QUIET=0
LIST_ONLY=0
GUIDE_APP="/Applications/MacUpdaterGuide.app"
typeset -A SELECTED

select_step() { SELECTED[$1]=1; INTERACTIVE=0 }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)        LIST_ONLY=1 ;;
        --all)         for k in plugin app login-item data prefs mas swiftbar; do select_step "$k"; done ;;
        --plugin)      select_step plugin ;;
        --app)         select_step app ;;
        --login-item)  select_step login-item ;;
        --data)        select_step data ;;
        --prefs)       select_step prefs ;;
        --mas)         select_step mas ;;
        --swiftbar)    select_step swiftbar ;;
        --app-path)    shift; GUIDE_APP="$1" ;;
        --dry-run)     DRY_RUN=1 ;;
        --quiet)       QUIET=1 ;;
        --help|-h)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Human narration. Silenced by --quiet so a caller parsing stdout gets only
# the machine-readable lines.
say() { (( QUIET )) || echo "$@" }

# One machine-readable line per step, for whoever is driving the script. Only
# in non-interactive mode: in a terminal these would just be noise next to the
# sentences a person is already reading.
report() { (( INTERACTIVE )) || echo "RESULT|$1|$2|$3" }

ask_confirmation() {
    local prompt="$1"
    echo -n "$prompt [y/N] "
    read -r response
    [[ "$response" == "y" || "$response" == "Y" ]]
}

# Whether a step runs at all. Interactive mode considers every step and asks;
# flag mode considers only what was named.
wants() {
    (( INTERACTIVE )) && return 0
    [[ -n "${SELECTED[$1]}" ]]
}

# The question, or nothing at all when the choosing already happened in a UI.
confirm() {
    (( INTERACTIVE )) || return 0
    ask_confirmation "$1"
}

# Does the removal, unless --dry-run said to only talk about it.
perform() {
    (( DRY_RUN )) && return 0
    "$@"
}

# Every step reports the same way, so --dry-run needs no special casing at
# each call site.
removed() {
    if (( DRY_RUN )); then
        report "$1" dryrun "$2"
        say "Would remove: $2"
    else
        report "$1" removed "$2"
        say "$3"
    fi
}

# --- Shared discovery, so --list and the steps themselves never disagree ---

swiftbar_plugin_dir() {
    local dir
    dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")
    echo "${dir/#\~/$HOME}"
}

# Prints one plugin script path per line; nothing when the directory is
# missing or empty. find, not a glob: under zsh's default options a glob that
# matches nothing throws "no matches found", which under `set -e` used to kill
# the whole uninstaller.
swiftbar_plugin_scripts() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -name 'update_system.*.sh' 2>/dev/null || true
}

legacy_launch_agents() {
    find "$HOME/Library/LaunchAgents" -maxdepth 1 -iname "*macupdaterguide*" 2>/dev/null || true
}

# Read from the bundle rather than hardcoded, so this keeps working if the
# identifier ever changes. Read up front rather than inside the app step: the
# preferences step needs it whether or not the bundle is being removed too.
GUIDE_BUNDLE_ID=""
if [[ -d "$GUIDE_APP" ]]; then
    GUIDE_BUNDLE_ID=$(defaults read "$GUIDE_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
fi

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
# Deliberately does not ask System Events whether a login item exists: that
# query needs Automation permission, and putting a macOS permission dialog in
# front of someone who only opened a settings page is not a fair trade for one
# checkbox. Legacy launch agent files are visible without any of that.
if (( LIST_ONLY )); then
    plugin_dir="$(swiftbar_plugin_dir)"
    plugin_scripts="$(swiftbar_plugin_scripts "$plugin_dir")"
    if [[ -n "$plugin_scripts" ]]; then
        echo "ITEM|plugin|yes|$(echo "$plugin_scripts" | tr '\n' ' ')"
    else
        echo "ITEM|plugin|no|$plugin_dir"
    fi

    if [[ -d "$GUIDE_APP" ]]; then
        echo "ITEM|app|yes|$GUIDE_APP"
    else
        echo "ITEM|app|no|$GUIDE_APP"
    fi

    agents="$(legacy_launch_agents)"
    if [[ -n "$agents" ]]; then
        echo "ITEM|login-item|yes|$(echo "$agents" | tr '\n' ' ')"
    else
        echo "ITEM|login-item|no|"
    fi

    if [[ -d "$APP_DIR" ]]; then
        echo "ITEM|data|yes|$APP_DIR"
    else
        echo "ITEM|data|no|$APP_DIR"
    fi

    if [[ -n "$GUIDE_BUNDLE_ID" ]]; then
        echo "ITEM|prefs|yes|$GUIDE_BUNDLE_ID"
    else
        echo "ITEM|prefs|no|"
    fi

    if command -v mas &> /dev/null; then
        echo "ITEM|mas|yes|mas"
    else
        echo "ITEM|mas|no|mas"
    fi

    if brew list --cask swiftbar &> /dev/null; then
        echo "ITEM|swiftbar|yes|swiftbar"
    else
        echo "ITEM|swiftbar|no|swiftbar"
    fi

    exit 0
fi

say "${fg[red]}=== Mac Software Manager: Uninstaller v1.6.0 ===${reset_color}"
(( DRY_RUN )) && say "${fg[yellow]}Dry run: nothing will actually be removed.${reset_color}"

# 1. Remove the SwiftBar Plugin
if wants plugin; then
    say ""
    say "Step 1: SwiftBar Plugin"
    # Try to find the plugin directory from SwiftBar settings
    EXPANDED_DIR="$(swiftbar_plugin_dir)"

    if [[ -d "$EXPANDED_DIR" ]]; then
        # Look for any version of the script (1h, 1d, etc.)
        FILES=()
        while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$EXPANDED_DIR" -maxdepth 1 -name 'update_system.*.sh' -print0)
        if [[ ${#FILES[@]} -gt 0 ]]; then
            say "Found plugin(s) in: $EXPANDED_DIR"
            if confirm "Delete update_system script from SwiftBar?"; then
                perform rm -f "${FILES[@]}"
                removed plugin "${FILES[*]}" "Plugin removed."
            else
                report plugin skipped "declined"
            fi
        else
            say "No update_system scripts found in $EXPANDED_DIR."
            report plugin skipped "nothing to remove"
        fi
    else
        say "Could not automatically determine SwiftBar plugin directory."
        report plugin skipped "plugin directory not found"
    fi
fi

# 2. Remove the GuideApp Application
if wants app; then
    say ""
    say "Step 2: GuideApp Application"
    if [[ -d "$GUIDE_APP" ]]; then
        if confirm "Delete $GUIDE_APP?"; then
            if perform rm -rf "$GUIDE_APP"; then
                removed app "$GUIDE_APP" "Application removed."
            else
                report app failed "could not remove $GUIDE_APP"
            fi
        else
            report app skipped "declined"
        fi
    else
        say "GuideApp not found at $GUIDE_APP."
        report app skipped "not installed"
    fi
fi

# 3. Remove Login Item / Launch Agent
if wants login-item; then
    say ""
    say "Step 3: GuideApp Login Item"
    FOUND_LOGIN_ITEM=0

    # Legacy-style LaunchAgents plist (GuideApp itself uses SMAppService, not a
    # LaunchAgent, but check defensively in case of older installs).
    while IFS= read -r plist; do
        [[ -e "$plist" ]] || continue
        FOUND_LOGIN_ITEM=1
        if confirm "Remove launch agent $plist?"; then
            perform launchctl unload "$plist" 2>/dev/null || true
            perform rm -f "$plist"
            removed login-item "$plist" "Launch agent removed."
        else
            report login-item skipped "declined"
        fi
    done < <(legacy_launch_agents)

    # Legacy-style login item added via System Events (older mechanism). Only
    # in interactive mode: this needs Automation permission, and the dialog
    # macOS puts up for it cannot be answered by a caller that is driving this
    # script headlessly. GuideApp turns its own SMAppService registration off
    # itself instead.
    if (( INTERACTIVE )); then
        if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -qi "MacUpdaterGuide"; then
            FOUND_LOGIN_ITEM=1
            if ask_confirmation "Remove GuideApp from Login Items?"; then
                perform osascript -e 'tell application "System Events" to delete every login item whose name is "MacUpdaterGuide"' 2>/dev/null || true
                say "Login item removed."
            fi
        fi

        if [[ $FOUND_LOGIN_ITEM -eq 0 ]]; then
            say "GuideApp registers as a login item via SMAppService, which can only be turned off from within the app or System Settings."
            if ask_confirmation "Open System Settings > Login Items now to disable it?"; then
                open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            fi
        fi
    elif [[ $FOUND_LOGIN_ITEM -eq 0 ]]; then
        report login-item skipped "no legacy launch agent found"
    fi
fi

# 4. Remove Data & Config
if wants data; then
    say ""
    say "Step 4: Local Data & Configuration"
    if [[ -d "$APP_DIR" ]]; then
        if confirm "Delete logs and configuration files in $APP_DIR?"; then
            if perform rm -rf "$APP_DIR"; then
                removed data "$APP_DIR" "Data removed."
            else
                report data failed "could not remove $APP_DIR"
            fi
        else
            report data skipped "declined"
        fi
    else
        say "No local data directory found."
        report data skipped "nothing to remove"
    fi
fi

# 5. Remove GuideApp Preferences (UserDefaults)
if wants prefs; then
    say ""
    say "Step 5: GuideApp Preferences"
    if [[ -n "$GUIDE_BUNDLE_ID" ]]; then
        if confirm "Delete GuideApp preferences ($GUIDE_BUNDLE_ID)?"; then
            if (( DRY_RUN )); then
                removed prefs "$GUIDE_BUNDLE_ID" ""
            elif defaults delete "$GUIDE_BUNDLE_ID" 2>/dev/null; then
                removed prefs "$GUIDE_BUNDLE_ID" "Preferences removed."
            else
                say "No preferences found for $GUIDE_BUNDLE_ID."
                report prefs skipped "no preferences stored"
            fi
        else
            report prefs skipped "declined"
        fi
    else
        say "GuideApp not found, skipping preferences cleanup."
        report prefs skipped "bundle identifier unknown"
    fi
fi

# 6. Optional Dependencies
# Only the two packages this toolkit installs for itself. Homebrew is
# deliberately left alone: it is a system-wide package manager holding software
# that has nothing to do with this project, so removing it is not this
# uninstaller's business.
if wants mas || wants swiftbar; then
    say ""
    say "Step 6: Dependencies (Optional)"
fi

if wants mas; then
    if command -v mas &> /dev/null; then
        if confirm "Uninstall 'mas' (App Store CLI)?"; then
            if perform brew uninstall mas; then
                removed mas "mas" "mas removed."
            else
                report mas failed "brew uninstall mas failed"
            fi
        else
            report mas skipped "declined"
        fi
    else
        report mas skipped "not installed"
    fi
fi

if wants swiftbar; then
    if brew list --cask swiftbar &> /dev/null; then
        if confirm "Uninstall SwiftBar app?"; then
            # Remove from login items first
            say "Removing SwiftBar from Login Items..."
            perform osascript -e 'tell application "System Events" to delete every login item whose name is "SwiftBar"' 2>/dev/null || true
            if perform brew uninstall --cask swiftbar; then
                removed swiftbar "swiftbar" "SwiftBar removed."
            else
                report swiftbar failed "brew uninstall --cask swiftbar failed"
            fi
        else
            report swiftbar skipped "declined"
        fi
    else
        report swiftbar skipped "not installed"
    fi
fi

if (( INTERACTIVE )); then
    say ""
    say "Homebrew itself is left installed, along with every other package it manages."
    say "To remove it, follow Homebrew's own uninstall instructions: https://brew.sh"
fi

say ""
say "${fg[green]}Uninstallation process finished.${reset_color}"
