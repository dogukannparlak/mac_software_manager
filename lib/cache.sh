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
# any interested reader polls it. The native Swift app parses this file
# independently (UpdateProgress.swift) - see CACHE_FORMAT.md, which both sides
# are required to stay in sync with.
#
# Format:  v1|state|phase|item|index|total
#   version = format marker; bump PROGRESS_FORMAT_VERSION on any incompatible
#             change so a stale reader fails closed instead of misparsing
#   state   = running | done | failed
#   phase   = a stable token the reader translates (brew-update, brew-upgrade,
#             mas-upgrade, verify, cleanup, install-app, refresh)
#   item    = package or application currently being worked on, may be empty
PROGRESS_FILE="$CACHE_DIR/progress"
PROGRESS_FORMAT_VERSION="v1"

progress_write() {
    local state="$1" phase="$2" item="${3:-}" index="${4:-}" total="${5:-}"
    local tmp="$PROGRESS_FILE.$$"
    print -r -- "${PROGRESS_FORMAT_VERSION}|${state}|${phase}|${item}|${index}|${total}" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$PROGRESS_FILE" 2>/dev/null || rm -f "$tmp"
}

# Runs on exit so a run that stops early - a failed integrity check, Ctrl-C,
# "nothing to do" - never leaves a reader believing work is still in progress.
progress_finalize() {
    [[ -f "$PROGRESS_FILE" ]] || return 0
    local recorded
    recorded=$(<"$PROGRESS_FILE") 2>/dev/null || return 0

    local -a fields
    fields=("${(@s:|:)recorded}")
    # Fewer than 2 fields, or a version this script does not recognise: there
    # is nothing safe to conclude about "was it running", so leave the file
    # alone rather than guess from an unversioned/old-format line.
    (( ${#fields[@]} >= 2 )) || return 0
    [[ "${fields[1]}" == "$PROGRESS_FORMAT_VERSION" ]] || return 0

    [[ "${fields[2]}" == "running" ]] && progress_write "done" "complete" "" "" ""
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
