
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
#
# 'mas' needs two very different limits, and conflating them is a bug: a query
# ('mas outdated') only fetches metadata and has no business taking more than
# seconds, while an upgrade downloads the application itself. A multi-gigabyte
# App Store title on an ordinary line legitimately runs for many minutes;
# killing it at the query limit throws away the partial download AND makes the
# post-upgrade verification see the app as "still outdated", which then lands
# in the history as a failure. Hence the upgrade limit is a hang guard, not a
# pace limit. Set MAS_UPGRADE_TIMEOUT=0 to remove the upgrade limit entirely.
MAS_QUERY_TIMEOUT=${MAS_QUERY_TIMEOUT:-30}
MAS_UPGRADE_TIMEOUT=${MAS_UPGRADE_TIMEOUT:-7200}

# Status run_with_timeout returns when it had to kill the command. 124 is what
# GNU 'timeout' uses, and no 'mas' failure reports it, so callers can tell "we
# ran out of patience" apart from "the command actually failed".
TIMEOUT_EXIT_STATUS=124

# Usage: run_with_timeout <seconds> <command> [args...]
# Returns the command's exit status, or $TIMEOUT_EXIT_STATUS if the limit was
# reached and the command had to be killed. A limit of 0 means "no timeout".
run_with_timeout() {
    local secs="$1"
    shift

    if [[ -z "$secs" || "$secs" == "0" ]]; then
        "$@"
        return $?
    fi

    # The watcher is a separate process, so it reports back through a marker
    # file, created only once the SIGTERM has actually been delivered.
    local marker
    marker="$(mktemp "${TMPDIR:-/tmp}/msu_timeout.XXXXXX")" || marker=""
    [[ -n "$marker" ]] && rm -f "$marker"

    "$@" &
    local pid=$!
    ( sleep "$secs" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null && [[ -n "$marker" ]] && : > "$marker" ) &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill -TERM "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null

    local timed_out=0
    # rc == 0 means the command beat the deadline by a hair and the watcher's
    # signal landed on an already-finished process: that is a success, not a
    # timeout. Any other status after a delivered SIGTERM is the timeout.
    [[ -n "$marker" && -e "$marker" ]] && (( rc != 0 )) && timed_out=1
    [[ -n "$marker" ]] && rm -f "$marker"

    (( timed_out )) && return $TIMEOUT_EXIT_STATUS
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

# Hand a lock back before the process exits. acquire_lock's descriptor
# normally lives as long as the process, which is the right default for a
# whole-run lock - but a caller that only needs to serialize one short step
# (collect_cache_for_item, lib/cache.sh) would otherwise keep every other
# waiter blocked through its own trailing work: the final progress line, the
# SwiftBar refresh, the closing sleep.
# Quiet no-op when there is nothing to release - the degraded no-zsystem
# path, an acquire that failed or timed out, a second release of the same
# lock - so callers never have to guard the call.
release_lock() {
    local name="$1"
    local fd_var="LOCK_FD_${name:gs/-/_}"

    (( $+builtins[zsystem] )) || return 0

    local fd="${(P)fd_var}"
    [[ -n "$fd" ]] || return 0

    zsystem flock -u "$fd" 2>/dev/null || true
    unset "$fd_var"
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

# What launch_in_terminal returns. The distinction matters: only one of these
# has a fix the user can act on, and it is the one that keeps happening -
# GuideApp is ad-hoc signed (CODE_SIGN_IDENTITY = "-"), so every rebuild
# changes the code signature macOS keyed the Automation grant to and the
# permission is revoked without a word. See launch_error_is_permission_denied.
LAUNCH_TERMINAL_OK=0
LAUNCH_TERMINAL_FAILED=1
LAUNCH_TERMINAL_DENIED=3

# Whatever the last launch attempt wrote on stderr, kept verbatim so the
# caller can classify it (and quote it) after the fact.
typeset -g LAUNCH_TERMINAL_ERROR=""

# Runs one launch command, keeping what it wrote on stderr *and* recording it
# in LAUNCH_TERMINAL_ERROR. Passing it through matters as much as capturing
# it: GuideApp reads this process's stderr and shows it verbatim when the
# process exits non-zero (ProcessOutcome.summary), so swallowing osascript's
# own words here would cost the one line that says what macOS actually
# refused.
launch_capture() {
    local rc=0
    LAUNCH_TERMINAL_ERROR=$( { "$@" 2>&1 1>&3 3>&-; } 3>&1 ) || rc=$?
    [[ -n "$LAUNCH_TERMINAL_ERROR" ]] && print -r -- "$LAUNCH_TERMINAL_ERROR" >&2
    return $rc
}

# Did macOS refuse the Apple event because this app has no Automation
# permission, rather than the launch failing for some ordinary reason?
#
# osascript reports it as error -1743 ("Not authorized to send Apple events
# to <app>"), which is the one launch failure with a concrete fix - the user
# has to re-grant the permission under System Settings - so it must not be
# reported with the same shrug as "iTerm is not installed". The numeric code
# is matched first because it is the part macOS does not localize; the text
# is a fallback for wordings that arrive without it.
launch_error_is_permission_denied() {
    local message="${1:-$LAUNCH_TERMINAL_ERROR}"
    [[ "$message" == *"-1743"* ]] && return 0
    [[ "${message:l}" == *"not authorized to send apple events"* ]] && return 0
    return 1
}

# Ask Terminal.app to run the command. Also the fallback every other branch
# below uses when the terminal the user picked turns out not to be installed.
launch_via_terminal_app() {
    local cmd="$1"
    launch_capture osascript <<EOF
tell application "Terminal"
    run
    do script "$cmd"
    activate
end tell
EOF
}

# Opens the terminal WITHOUT asking macOS for permission to control it.
#
# Every branch above drives the terminal with an Apple Event, which needs an
# Automation grant the user may never have been asked for - an app whose bundle
# carries no NSAppleEventsUsageDescription is refused outright, with no prompt
# to allow. 'open' hands a file to the terminal through LaunchServices, which
# is not an Apple Event and needs no grant at all, so this still works when the
# osascript path is refused.
#
# The cost is that the window does not come to the front by itself and the
# command arrives as a file rather than a typed line - which is why this is the
# fallback and not the first choice.
launch_via_terminal_file() {
    local cmd="$1"
    local terminal="${PREFERRED_TERMINAL:-Terminal}"
    local file=""

    # Terminal only runs a file it recognises, and what it recognises is the
    # .command extension - mktemp cannot produce one directly.
    file="$(mktemp "${TMPDIR:-/tmp}/msm-launch.XXXXXX")" || return 1
    mv -f "$file" "$file.command" 2>/dev/null || { rm -f "$file"; return 1; }
    file="$file.command"

    {
        print -r -- "#!/bin/zsh"
        print -r -- "$cmd"
        # Last act, so the window still has it while the update runs: this
        # file is a launch detail, not something to leave in the user's
        # temp directory once it has served its purpose.
        print -r -- "rm -f ${(qq)file}"
    } > "$file" 2>/dev/null || { rm -f "$file"; return 1; }

    chmod +x "$file" 2>/dev/null || { rm -f "$file"; return 1; }
    launch_capture open -a "$terminal" "$file" || { rm -f "$file"; return 1; }
    return 0
}

# Launch update script in the configured terminal app.
#
# Returns LAUNCH_TERMINAL_OK only when the terminal was actually asked to run
# the command. Callers must check: for every path that goes through here the
# real work happens in that window, so a launcher that reports success it did
# not have leaves the caller watching for a run that will never start.
launch_in_terminal() {
    local script_path="$1"
    shift
    local args=("${@:-all}")
    local terminal="${PREFERRED_TERMINAL:-Terminal}"
    local rc=0

    local cmd="${(qq)script_path} run ${(@qq)args}"

    LAUNCH_TERMINAL_ERROR=""

    case "$terminal" in
        "iTerm2")
            # iTerm2 using AppleScript
            if [[ -d "/Applications/iTerm.app" ]]; then
                launch_capture osascript <<EOF || rc=$?
tell application "iTerm"
    if not application "iTerm" is running then
        launch
    end if
    create window with default profile command "$cmd"
    activate
end tell
EOF
            else
                launch_via_terminal_app "$cmd" || rc=$?
            fi
            ;;
        "Warp")
            # Warp terminal
            if [[ -d "/Applications/Warp.app" ]]; then
                # Force focus first. Best-effort on purpose: 'open' below
                # needs no Automation permission, so a refused 'activate'
                # means the window opens without coming to the front - not a
                # failed launch, and reporting it as one would send the user
                # after a permission this branch does not need.
                osascript -e 'tell application "Warp" to activate' 2>/dev/null || true
                # Warp accepts args naturally, but constructing a clean command string is safer
                launch_capture open -a Warp "$script_path" --args run "${args[@]}" || rc=$?
                osascript -e 'tell application "Warp" to activate' 2>/dev/null || true
            else
                launch_via_terminal_app "$cmd" || rc=$?
            fi
            ;;
        "Alacritty")
            # Alacritty terminal
            if [[ -d "/Applications/Alacritty.app" ]]; then
                # Force focus first - best-effort, see the Warp branch above
                osascript -e 'tell application "Alacritty" to activate' 2>/dev/null || true
                launch_capture open -a Alacritty --args -e zsh -c "$cmd; exec zsh" || rc=$?
                osascript -e 'tell application "Alacritty" to activate' 2>/dev/null || true
            else
			    # Fallback to Terminal
                launch_via_terminal_app "$cmd" || rc=$?
            fi
            ;;
        "Ghostty")
            # Ghostty terminal
            if [[ -d "/Applications/Ghostty.app" ]]; then
                launch_capture open -na Ghostty --args -e zsh -c "$cmd; exec zsh" || rc=$?
            else
			    # Fallback to Terminal
                launch_via_terminal_app "$cmd" || rc=$?
            fi
            ;;
        *)
            launch_via_terminal_app "$cmd" || rc=$?
            ;;
    esac

    # Refused rather than broken: there is one more way in that needs no
    # permission at all, and a window that opens without being brought to the
    # front beats sending the user to System Settings for a grant they should
    # never have needed. Only tried on a denial - a terminal that failed for
    # any other reason will not open for this either.
    if (( rc != 0 )) && launch_error_is_permission_denied; then
        if launch_via_terminal_file "$cmd"; then
            rc=0
        fi
    fi

    if (( rc == 0 )); then
        LAUNCH_TERMINAL_ERROR=""
        return $LAUNCH_TERMINAL_OK
    fi

    launch_error_is_permission_denied && return $LAUNCH_TERMINAL_DENIED
    return $LAUNCH_TERMINAL_FAILED
}

# Launch a run in the user's terminal and, when no terminal opened, say so
# everywhere a caller can hear it.
#
# The three menu actions that start a run this way (install_app, update_app,
# launch_update) each used to end with '|| true; exit 0', so a launcher that
# never opened a window still exited 0 and GuideApp went on to watch for a run
# that did not exist. Getting the status right is only half of it - the status
# alone says "something failed", and the failure that actually happens here
# has a specific fix - so the reason goes out on three channels at once:
#
#   - stderr, which GuideApp quotes verbatim for a non-zero exit
#     (ProcessOutcome.summary) and which is all a terminal user ever sees
#   - the progress file, so the banner names the problem in the user's own
#     language instead of quoting shell English (see CACHE_FORMAT.md)
#   - a notification, the only one of the three that carries the full
#     instruction untruncated, and the only one left when the run was started
#     from the SwiftBar menu rather than GuideApp
#
# Arguments are passed straight to launch_in_terminal, and its status is
# returned unchanged. The recorded phase names the failure rather than the
# action that hit it: which menu item was pressed is not what the user has to
# do something about.
launch_in_terminal_or_report() {
    local rc=0
    launch_in_terminal "$@" || rc=$?
    (( rc == 0 )) && return 0

    local terminal="${PREFERRED_TERMINAL:-Terminal}"
    local reason detail

    if (( rc == LAUNCH_TERMINAL_DENIED )); then
        reason="macOS blocked Mac Software Manager from controlling $terminal."
        detail="Allow it under System Settings > Privacy & Security > Automation, then try again."
        progress_write_failure "terminal-permission" "$terminal"
    else
        reason="Could not open $terminal to run the update."
        detail="${LAUNCH_TERMINAL_ERROR:-The terminal did not start.}"
        progress_write_failure "launch-failed" "$terminal"
    fi

    print -u2 -r -- "❌ $reason"
    print -u2 -r -- "   $detail"
    notify "$reason $detail"

    return $rc
}
