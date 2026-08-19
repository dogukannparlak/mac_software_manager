
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

# Escape ERE metacharacters so a literal value can be embedded in a `sed -E`
# pattern without being read as regex syntax. Cask tokens and app names can
# contain '.', '+', '*' etc. (e.g. "some.app+beta") which would otherwise widen
# or narrow the match unpredictably.
escape_ere() {
    print -r -- "$1" | sed -E 's/[].^$*+?(){}|\[]/\\&/g'
}

# ------------------------------------------------------------------------------
# NOTIFICATIONS
# ------------------------------------------------------------------------------
# GuideApp watches $APP_DIR/notifications for one-shot request files and turns
# each into a native UNUserNotificationCenter alert (title "Mac Software
# Manager", an "Open" action) - see CACHE_FORMAT.md ("Notification queue") for
# the file format both sides agree on. That only works while GuideApp is
# actually running to pick the file up, so a bare 'osascript display
# notification' (shows up labeled "Script Editor", no action button) remains
# the fallback whenever it is not, or whenever the handoff fails for any
# other reason.
NOTIFY_DIR="$APP_DIR/notifications"

# Usage: notify <body> [subtitle]
# Never aborts the caller: every fallible step here is guarded, so this is
# safe to call under 'set -e'.
notify() {
    local title="Mac Software Manager"
    local body="$1"
    local subtitle="${2:-}"

    # Pipe-delimited, one line per CACHE_FORMAT.md convention: strip anything
    # that would break either rule.
    body="${body//$'\n'/ }"; body="${body//|/}"
    subtitle="${subtitle//$'\n'/ }"; subtitle="${subtitle//|/}"

    if pgrep -x "MacUpdaterGuide" > /dev/null 2>&1; then
        mkdir -p "$NOTIFY_DIR" 2>/dev/null || true
        local final_file="$NOTIFY_DIR/notify.$$.$RANDOM"
        local tmp_file="${final_file}.tmp"
        if print -r -- "v1|$title|$subtitle|$body" > "$tmp_file" 2>/dev/null; then
            if [[ -s "$tmp_file" ]] && mv "$tmp_file" "$final_file" 2>/dev/null; then
                return 0
            fi
        fi
        rm -f "$tmp_file" 2>/dev/null || true
    fi

    if [[ -n "$subtitle" ]]; then
        osascript -e "display notification \"$(applescript_escape "$body")\" with title \"$(applescript_escape "$title")\" subtitle \"$(applescript_escape "$subtitle")\"" 2>/dev/null || true
    else
        osascript -e "display notification \"$(applescript_escape "$body")\" with title \"$(applescript_escape "$title")\"" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 3a1. PROCESS TIMEOUT
# ------------------------------------------------------------------------------
# Every curl call in this script has its own --connect-timeout/--max-time, but
# 'mas' talks to the App Store through its own private channel and has no
# built-in timeout at all: if that backend hangs, the whole update run hangs
# with it. macOS ships neither GNU coreutils' 'timeout' nor 'gtimeout' by
# default, so this rolls a minimal, dependency-free equivalent from zsh job
# control: a background watcher sends SIGTERM if the command outruns the limit.
MAS_TIMEOUT=30

# Usage: run_with_timeout <seconds> <command> [args...]
# Returns the command's exit status, or a non-zero "killed" status on timeout.
run_with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local pid=$!
    ( sleep "$secs" 2>/dev/null; kill -TERM "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill -TERM "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $rc
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

# Helper: Clean App Store Name (Removes leading ID/whitespace and trailing version info)
clean_mas_name() {
    # 1. Remove leading ID (digits + space), handling potential leading whitespace (^[[:space:]]*)
    # 2. Remove trailing version info (last parenthesis group)
    # 3. Trim whitespace via xargs
    echo "$1" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]*\([^)]+\)$//' | xargs
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
