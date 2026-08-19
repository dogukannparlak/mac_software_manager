#!/bin/zsh

autoload -U colors && colors
set -e

# Helper function for confirmations
ask_confirmation() {
    local prompt="$1"
    echo -n "$prompt [y/N] "
    read -r response
    [[ "$response" == "y" || "$response" == "Y" ]]
}

# Download the official Homebrew (un)installer over HTTPS and run it, refusing
# to execute anything empty or truncated. Same baseline as setup_mac.sh: no
# published checksum to pin against, but HTTPS+TLS1.2 is enforced, content
# actually has to be present, and it has to parse as bash before it runs.
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

echo "${fg[red]}=== Mac Software Manager: Uninstaller v1.5.0 ===${reset_color}"

# 1. Remove the SwiftBar Plugin
echo ""
echo "Step 1: SwiftBar Plugin"
# Try to find the plugin directory from SwiftBar settings
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")
EXPANDED_DIR="${PLUGIN_DIR/#\~/$HOME}"

if [[ -d "$EXPANDED_DIR" ]]; then
    # Look for any version of the script (1h, 1d, etc.)
    FILES=()
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$EXPANDED_DIR" -maxdepth 1 -name 'update_system.*.sh' -print0)
    if [[ ${#FILES[@]} -gt 0 ]]; then
        echo "Found plugin(s) in: $EXPANDED_DIR"
        if ask_confirmation "Delete update_system script from SwiftBar?"; then
            rm -f "${FILES[@]}"
            echo "Plugin removed."
        fi
    else
        echo "No update_system scripts found in $EXPANDED_DIR."
    fi
else
    echo "Could not automatically determine SwiftBar plugin directory."
fi

# 2. Remove the GuideApp Application
echo ""
echo "Step 2: GuideApp Application"
GUIDE_APP="/Applications/MacUpdaterGuide.app"
GUIDE_BUNDLE_ID=""
if [[ -d "$GUIDE_APP" ]]; then
    # Read the bundle id from the app itself rather than hardcoding it, so this
    # keeps working if the identifier ever changes.
    GUIDE_BUNDLE_ID=$(defaults read "$GUIDE_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
    if ask_confirmation "Delete $GUIDE_APP?"; then
        rm -rf "$GUIDE_APP"
        echo "Application removed."
    fi
else
    echo "GuideApp not found in /Applications."
fi

# 3. Remove Login Item / Launch Agent
echo ""
echo "Step 3: GuideApp Login Item"
FOUND_LOGIN_ITEM=0

# Legacy-style LaunchAgents plist (GuideApp itself uses SMAppService, not a
# LaunchAgent, but check defensively in case of older installs).
while IFS= read -r plist; do
    [[ -e "$plist" ]] || continue
    FOUND_LOGIN_ITEM=1
    if ask_confirmation "Remove launch agent $plist?"; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "Launch agent removed."
    fi
done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -iname "*macupdaterguide*" 2>/dev/null)

# Legacy-style login item added via System Events (older mechanism).
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -qi "MacUpdaterGuide"; then
    FOUND_LOGIN_ITEM=1
    if ask_confirmation "Remove GuideApp from Login Items?"; then
        osascript -e 'tell application "System Events" to delete every login item whose name is "MacUpdaterGuide"' 2>/dev/null || true
        echo "Login item removed."
    fi
fi

if [[ $FOUND_LOGIN_ITEM -eq 0 ]]; then
    echo "GuideApp registers as a login item via SMAppService, which can only be turned off from within the app or System Settings."
    if ask_confirmation "Open System Settings > Login Items now to disable it?"; then
        open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    fi
fi

# 4. Remove Data & Config
echo ""
echo "Step 4: Local Data & Configuration"
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
if [[ -d "$APP_DIR" ]]; then
    if ask_confirmation "Delete logs and configuration files in $APP_DIR?"; then
        rm -rf "$APP_DIR"
        echo "Data removed."
    fi
else
    echo "No local data directory found."
fi

# 5. Remove GuideApp Preferences (UserDefaults)
echo ""
echo "Step 5: GuideApp Preferences"
if [[ -n "$GUIDE_BUNDLE_ID" ]]; then
    if ask_confirmation "Delete GuideApp preferences ($GUIDE_BUNDLE_ID)?"; then
        defaults delete "$GUIDE_BUNDLE_ID" 2>/dev/null && echo "Preferences removed." || echo "No preferences found for $GUIDE_BUNDLE_ID."
    fi
else
    echo "GuideApp not found, skipping preferences cleanup."
fi

# 6. Optional Dependencies
echo ""
echo "Step 6: Dependencies (Optional)"

if command -v mas &> /dev/null; then
    if ask_confirmation "Uninstall 'mas' (App Store CLI)?"; then
        brew uninstall mas
    fi
fi

if brew list --cask swiftbar &> /dev/null; then
    if ask_confirmation "Uninstall SwiftBar app?"; then
        # Remove from login items first
        echo "Removing SwiftBar from Login Items..."
        osascript -e 'tell application "System Events" to delete every login item whose name is "SwiftBar"' 2>/dev/null || true
        brew uninstall --cask swiftbar
    fi
fi

if command -v brew &> /dev/null; then
    echo ""
    echo "${fg[yellow]}WARNING: Uninstalling Homebrew will remove ALL brew-installed packages!${reset_color}"
    if ask_confirmation "Do you want to completely uninstall Homebrew from this system?"; then
        run_homebrew_script "https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh" "uninstall" || \
            echo "${fg[red]}❌ Homebrew uninstall failed or was refused. Continuing with the rest of the cleanup.${reset_color}"
    fi
fi

echo ""
echo "${fg[green]}Uninstallation process finished.${reset_color}"
