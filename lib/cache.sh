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
CACHE_KEYS_INSTALLED=(brew_pinned brew_casks brew_formulae brew_leaves brew_formulae_desc brew_casks_desc mas_list brew_status)
CACHE_KEYS_APPS=(app_updates)
CACHE_KEYS_WEBSITES=(cask_homepages github_homepages)

# How long a targeted post-update refresh (collect_cache_for_item) waits for
# the "cache" lock before giving up on it. Generous enough to sit out another
# single-item run's refresh or a background tier refresh, short enough that a
# lock nobody ever releases cannot pin an update row on "Güncelleniyor".
CACHE_LOCK_WAIT=${CACHE_LOCK_WAIT:-60}

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
#
# Return contract: 0 whenever the entry is left holding usable data - freshly
# written OR the preserved previous value. Non-zero ONLY when nothing could be
# stored at all (cache_put failing on an unwritable cache dir).
# Keeping the old value is a designed fallback, not an error, and it must not
# read as one: every caller runs under 'set -e' (update_system.1h.sh section 5),
# where zsh propagates a function's non-zero return straight into the caller.
# Reporting the fallback as failure used to abort mid-refresh - killing the run
# before it could write its final progress line, so GuideApp read a half-built
# cache and showed a successful update as "failed".
cache_refresh_entry() {
    local key="$1"
    shift
    local output rc=0

    output=$("$@" 2>/dev/null) || rc=$?

    if (( rc != 0 )) && [[ -f "$CACHE_DIR/$key" ]]; then
        touch "$CACHE_DIR/$key"
        return 0
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
#             mas-upgrade, verify, cleanup, install-app, refresh, complete,
#             complete-with-failures)
#   item    = package or application currently being worked on, may be empty
#
# The file's modification time carries meaning of its own: a live run keeps it
# current (progress_heartbeat_start, below), so a "running" entry that has
# stopped aging is a run that died. Readers use that to decide when to stop
# believing an entry - never the content alone.
PROGRESS_FILE="$CACHE_DIR/progress"
PROGRESS_FORMAT_VERSION="v1"

# How often a live run re-stamps the progress file, in seconds. Keep this
# comfortably under the shortest window any reader uses to call a "running"
# entry dead (UpdateProgress.staleAfterQuick, 15 minutes).
PROGRESS_HEARTBEAT_INTERVAL=${PROGRESS_HEARTBEAT_INTERVAL:-15}
typeset -g PROGRESS_HEARTBEAT_PID=""

# Keeps the current "running" entry *fresh* for as long as this run is alive.
#
# The file is only written when a run reaches a new phase, and some phases are
# a single blocking command: `mas upgrade` may legitimately download for up to
# MAS_UPGRADE_TIMEOUT (7200s, lib/utils.sh) without a word, and one large
# `brew upgrade` package is no different. A reader cannot tell that apart from
# a run that died mid-phase, so it has to guess from the entry's age - and
# every guess is wrong for one of the two: short enough to notice a crash
# meant calling a still-downloading run failed, long enough for the download
# meant a crashed run kept the UI (and GuideApp's per-item queue) waiting on a
# process that no longer existed.
#
# This removes the guess: a background stamper touches the file every
# PROGRESS_HEARTBEAT_INTERVAL seconds, so an entry that stops aging really is
# a run that stopped running. Only the modification time changes, never the
# content - it cannot race with a real progress_write, and no reader has to
# learn a new field. See CACHE_FORMAT.md and `UpdateProgress.staleAfter(for:)`
# on the Swift side.
#
# The stamper stops itself as soon as any of these is true, so it can never
# outlive the run and hold a dead entry open:
#   - the run that started it is gone (`kill -0`), including the SIGKILL and
#     closed-terminal-window cases where no trap of ours ever runs
#   - the entry no longer says "running": the run recorded its ending, and
#     touching that ending would make the *next* run's watch read it as the
#     entry its own run just wrote
#   - the file is gone
progress_heartbeat_start() {
    # Same reasoning as progress_write below: a headless single-item run does
    # not own this file, so it has nothing to keep fresh.
    [[ -n "$GUIDEAPP_NO_SHARED_PROGRESS" ]] && return 0
    # Already stamping for this run.
    [[ -n "$PROGRESS_HEARTBEAT_PID" ]] && kill -0 "$PROGRESS_HEARTBEAT_PID" 2>/dev/null && return 0
    (( PROGRESS_HEARTBEAT_INTERVAL > 0 )) || return 0

    local owner=$$ file="$PROGRESS_FILE" every="$PROGRESS_HEARTBEAT_INTERVAL"
    local running_prefix="${PROGRESS_FORMAT_VERSION}|running|"
    # Disowned (`&!`) so nothing in the run ever waits on it, and detached
    # from the run's own stdout/stderr so it cannot hold a pipe open after the
    # run itself is done (GuideApp reads that stderr pipe to EOF; so does
    # bats' `run`).
    (
        while sleep "$every"; do
            kill -0 "$owner" 2>/dev/null || break
            [[ -f "$file" ]] || break
            [[ "$(<"$file")" == "$running_prefix"* ]] || break
            touch "$file" 2>/dev/null || break
        done
    ) >/dev/null 2>&1 &!
    PROGRESS_HEARTBEAT_PID=$!
    return 0
}

progress_heartbeat_stop() {
    [[ -n "$PROGRESS_HEARTBEAT_PID" ]] || return 0
    kill "$PROGRESS_HEARTBEAT_PID" 2>/dev/null
    PROGRESS_HEARTBEAT_PID=""
    return 0
}

progress_write() {
    # GuideApp sets this for a headless single-item run launched from its own
    # concurrency queue (Settings → General → "Aynı Anda Yapılabilecek
    # Güncelleme Sayısı") - several of those can be running at once, all
    # writing here, and none of them are what this shared file is for (the
    # one thing the whole toolkit is doing right now, e.g. "Update
    # Everything"). GuideApp already tracks each of those runs by its own
    # `Process` handle and resolves success/failure by re-checking the
    # outdated list, not by reading this file - so for that path, skip the
    # write instead of leaving whichever one of them wrote last stuck here
    # once it exits (nothing left polling it to ever clear it).
    [[ -n "$GUIDEAPP_NO_SHARED_PROGRESS" ]] && return 0

    local state="$1" phase="$2" item="${3:-}" index="${4:-}" total="${5:-}"
    local tmp="$PROGRESS_FILE.$$"
    print -r -- "${PROGRESS_FORMAT_VERSION}|${state}|${phase}|${item}|${index}|${total}" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$PROGRESS_FILE" 2>/dev/null || rm -f "$tmp"

    # A run is "alive" from its first running entry until it records an
    # ending, which is exactly the window the stamper has to cover - so the
    # state being written is also the signal to start and stop it. Every
    # ending goes through this function or progress_finalize (which stops it
    # too), so no run can leave one behind.
    if [[ "$state" == "running" ]]; then
        progress_heartbeat_start
    else
        progress_heartbeat_stop
    fi
}

# Is some other run using the progress file right now?
#
# Only the run that owns the file may write its ending there. A failure that
# belongs to no run at all - a menu action whose terminal never opened - is
# the one case that can arrive while another run is genuinely in flight, and
# writing "failed" over that run's "running" entry would report a live update
# as dead: the banner flips to an error and GuideApp's per-item queue, which
# is held behind any entry that says "running", drains on top of it.
#
# "In flight" is answered by the heartbeat, not by guesswork: a live run
# re-stamps the file every PROGRESS_HEARTBEAT_INTERVAL seconds, so a running
# entry that has been stamped within a few intervals really does have a run
# behind it. Three intervals is past "it missed a beat" and far short of the
# windows a reader uses to call a run dead (UpdateProgress.staleAfter).
progress_is_owned_by_live_run() {
    [[ -f "$PROGRESS_FILE" ]] || return 1

    integer grace=$(( PROGRESS_HEARTBEAT_INTERVAL * 3 ))
    (( grace > 0 )) || grace=45
    cache_fresh "progress" "$grace" || return 1

    local recorded
    recorded=$(<"$PROGRESS_FILE") 2>/dev/null || return 1
    [[ "$recorded" == "${PROGRESS_FORMAT_VERSION}|running|"* ]]
}

# Record a failure that is not the ending of the run currently holding the
# progress file - see progress_is_owned_by_live_run for why that distinction
# has to be made before writing. Returns non-zero when the write was skipped.
progress_write_failure() {
    local phase="$1" item="${2:-}"
    progress_is_owned_by_live_run && return 1
    progress_write "failed" "$phase" "$item" "" ""
}

# The final entry for a run that made it all the way to the end. Getting to
# the end is not the same as succeeding: a run where five packages are still
# outdated afterwards finished, but it failed for those five, and writing
# "done|complete" for it puts a green tick and "Finished" on the banner (see
# ProgressBanner.swift, which picks its icon and tint off `state` alone).
#
# So the state follows the verified failure count, and the counts ride along
# in index/total - failed and attempted - instead of a message in `item`:
# the reader words it, so it can be worded in the user's language.
progress_write_completion() {
    integer failed="${1:-0}" attempted="${2:-0}"

    if (( failed > 0 )); then
        progress_write "failed" "complete-with-failures" "" "$failed" "$attempted"
    else
        progress_write "done" "complete" "" "" ""
    fi
}

# Runs on exit so a run that stops early - a failed integrity check, Ctrl-C,
# "nothing to do" - never leaves a reader believing work is still in progress.
#
# Takes the exit status the EXIT trap caught. "Stopped early" is not the same
# as "finished": an `exit 1` used to land here as an unconditional
# "done|complete", i.e. a green tick and "Bitti" for a run that actually
# failed. So the caller has to say which it was:
#
#     trap 'progress_finalize $?' EXIT
#
# $? must be read as the *first* thing the trap does - anything before it
# (an `rm -f`, an `echo`) overwrites the status being reported. A trap that
# also has cleanup to do therefore captures it into a variable first:
#
#     trap 'rc=$?; rm -rf "$workdir"; progress_finalize $rc' EXIT
#
# Called with no argument it assumes success, so a bare `progress_finalize`
# still means what it always did.
#
# On failure only the state flips: the recorded phase/item/index/total are
# kept, so a reader can say where the run stopped ("Updating Homebrew
# packages - awscli (3 of 8)") instead of only that it stopped.
progress_finalize() {
    local exit_rc="${1:-0}"

    # Whatever this decides to write - or to leave alone - the run is over:
    # the heartbeat must not go on making its last entry look fresh.
    progress_heartbeat_stop

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

    [[ "${fields[2]}" == "running" ]] || return 0

    if [[ "$exit_rc" == "0" ]]; then
        progress_write "done" "complete" "" "" ""
    else
        progress_write "failed" "${fields[3]:-}" "${fields[4]:-}" "${fields[5]:-}" "${fields[6]:-}"
    fi
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
# 3b3. SINGLE-ITEM RUN RESULTS
# ------------------------------------------------------------------------------
# What ONE item's update run has to say about itself: which item, whether it
# updated, and if it did not, why. GuideApp reads these - see CACHE_FORMAT.md
# ("Single-item run results"), which both sides are required to stay in sync
# with.
#
# Format:  v1|epoch|kind|id|name|status|reason
#
# Why it exists: three separate things used to answer "did that item update",
# and they could disagree. The history log's ok/fail (run_mode_single), the
# shared progress file's done/failed, and - for the runs it launches itself -
# GuideApp re-reading the outdated list afterwards to see whether the item was
# still on it. Only the first two are the run's own verdict; the third is a
# guess made by a reader that never saw the run, and it is wrong whenever the
# cache was written a moment too late, or the item is legitimately still
# outdated after a partial upgrade. This is the run stating its outcome once,
# in one place, so nothing has to be inferred from a list.
#
# Deliberately NOT the progress file: several single-item runs can be in
# flight at once (GuideApp's concurrency setting), while that file describes
# the one thing the toolkit is doing right now - which is exactly why a
# headless single-item run skips it (GUIDEAPP_NO_SHARED_PROGRESS, see
# progress_write above). One file per run, like the notification queue, is
# what lets each run report its own outcome without overwriting anyone else's.
RESULTS_DIR="$APP_DIR/results"
RESULT_FORMAT_VERSION="v1"

# How long an unread result file is kept. A record is meant to be consumed by
# GuideApp as soon as the run it belongs to ends; anything still here long
# afterwards belongs to a run nobody was watching (a terminal window, a
# SwiftBar menu click) and is only taking up space.
RESULT_RETENTION_SECONDS=${RESULT_RETENTION_SECONDS:-86400}

# Drops result files past RESULT_RETENTION_SECONDS. Called from result_write,
# so the directory is tidied by the only thing that ever adds to it - no timer
# and no separate cleanup path that could quietly stop running.
result_prune() {
    local file
    local -a existing st
    existing=("$RESULTS_DIR"/result.*(N))
    (( ${#existing} )) || return 0

    for file in "${existing[@]}"; do
        zstat -A st +mtime "$file" 2>/dev/null || continue
        if (( EPOCHSECONDS - st[1] > RESULT_RETENTION_SECONDS )); then
            rm -f "$file" 2>/dev/null || true
        fi
    done
    return 0
}

# Usage: result_write <kind> <id> <name> <status> [reason]
#   kind   = brew | cask | mas | app - exactly what the run was invoked with,
#            never a re-derived one: the reader maps it back to its own item
#            identity (CACHE_FORMAT.md), and a kind it does not know is
#            ignored rather than guessed at.
#   id     = formula/cask token, App Store id, or application name
#   status = ok | fail
#   reason = a stable token the reader words in the user's language, empty
#            on ok
#
# Best-effort and never fatal: every caller runs under 'set -e', and a run
# that did update its package must not be turned into a failure because its
# report could not be filed. Written to a temp file and renamed into place so
# a reader never sees half a record.
result_write() {
    local kind="$1" id="$2" name="${3:-}" state="$4" reason="${5:-}"

    # Pipe-delimited, one line, per CACHE_FORMAT.md - id and name are the only
    # fields that come from anything free-form.
    id="${id//$'\n'/ }"; id="${id//|/}"
    name="${name//$'\n'/ }"; name="${name//|/}"

    mkdir -p "$RESULTS_DIR" 2>/dev/null || return 0
    result_prune

    local final_file="$RESULTS_DIR/result.$$.$RANDOM"
    local tmp_file="${final_file}.tmp"
    if print -r -- "${RESULT_FORMAT_VERSION}|${EPOCHSECONDS}|${kind}|${id}|${name}|${state}|${reason}" > "$tmp_file" 2>/dev/null; then
        if [[ -s "$tmp_file" ]] && mv "$tmp_file" "$final_file" 2>/dev/null; then
            return 0
        fi
    fi
    rm -f "$tmp_file" 2>/dev/null || true
    return 0
}

# ------------------------------------------------------------------------------
# ENGINE CONTRACT RECORD
# ------------------------------------------------------------------------------
# What the installed engine can be relied on to write, stated where GuideApp
# can read it. See CACHE_FORMAT.md ("Engine contract").
#
# Format:  v1|epoch|contract|release
#
# Why a number of its own instead of the release version: <bitbar.version>
# tracks releases, and two engines carrying the same one can still write
# different things. That is not hypothetical - result_write and the whole
# results/ contract were added within v1.5.0, so "v1.5.0" describes both an
# engine that files single-item results and one that cannot, and an app
# trusting the release version reads the two as identical. ENGINE_CONTRACT
# moves only when what a reader may depend on moves, which is the question
# actually being asked.
#
# Why the engine writes it at runtime instead of declaring it in a header:
# the contract is implemented in these lib files, not in the dispatcher that
# carries the header. A half-updated install - a new update_system.1h.sh over
# old libs - would have the header promising what the loaded code cannot do.
# A record written from here can only be produced by an engine that actually
# loaded this file.
#
# Bump ENGINE_CONTRACT whenever a reader becomes entitled to something an
# older engine never wrote: a new file under cache/ or a sibling directory, a
# vN bump in one of the formats in CACHE_FORMAT.md, or a new field a reader is
# allowed to require. Never for a change no reader can observe.
#
#   1  single-item run results (results/, result_write) and this record itself
ENGINE_FILE="$CACHE_DIR/engine"
ENGINE_FORMAT_VERSION="v1"
ENGINE_CONTRACT="1"

# Usage: engine_write [release]
#
# Called once per invocation from update_system.1h.sh, before any action is
# dispatched, so the record is never older than the run a reader is asking
# about. That is what makes it trustworthy in the direction that matters: a
# record left behind by a newer engine that has since been replaced by an
# older one is older than the run asking, and a reader applying the same "not
# written before the run started" rule it applies to result records reads it
# as what it is - this engine said nothing.
#
# Best-effort and never fatal, exactly like progress_write and result_write: a
# run that did update its package must not become a failure because it could
# not file a record about itself.
engine_write() {
    local release="${1:-${VERSION:-}}"
    release="${release//$'\n'/ }"; release="${release//|/}"

    mkdir -p "$CACHE_DIR" 2>/dev/null || return 0

    local tmp="$ENGINE_FILE.$$"
    if print -r -- "${ENGINE_FORMAT_VERSION}|${EPOCHSECONDS}|${ENGINE_CONTRACT}|${release}" > "$tmp" 2>/dev/null; then
        [[ -s "$tmp" ]] && mv -f "$tmp" "$ENGINE_FILE" 2>/dev/null
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 0
}

# Populate the cache. Tier is "updates", "installed", "sparkle" or "all".
# MAS entries are always written (empty when App Store support is off) so the
# staleness check cannot get stuck asking for data that will never arrive.
#
# Best-effort by design, and 'no_err_exit' is what makes that true: this runs
# from paths that enable 'set -e' (the refresh_cache action, and the run modes
# in run_modes.sh), where a single non-zero step - one unreachable brew
# command, one unwritable entry - would otherwise abort the whole script right
# here. That left the cache half-rebuilt AND skipped the caller's final
# progress_write, which is how a successful update ended up reported as
# "failed". Every entry already handles its own failure (see
# cache_refresh_entry), so collecting the remaining ones is always the right
# move. 'local_options' scopes this to the function: errexit is restored for
# the caller on return, and the explicit 'return 0' keeps a skipped tier from
# leaking a non-zero status back out.
collect_cache_data() {
    setopt local_options no_err_exit
    local tier="${1:-all}"
    local mas_outdated_raw=""

    if [[ "$tier" == "updates" || "$tier" == "all" ]]; then
        if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
            # Wrapped like every other 'mas' query in this project: 'mas' has
            # no timeout of its own, and a hung App Store backend here hangs
            # the whole refresh - including the headless single-item runs
            # GuideApp spawns, which then sit on a spinner until someone
            # cancels them (ToolkitController.cancelItemUpdate). A timeout
            # returns non-zero, which cache_refresh_entry already handles by
            # keeping - and re-stamping - the previous entry.
            cache_refresh_entry "mas_outdated" run_with_timeout "$MAS_QUERY_TIMEOUT" mas outdated
        else
            cache_put "mas_outdated" ""
        fi
        mas_outdated_raw="$(cache_get "mas_outdated")"

        cache_refresh_entry "brew_outdated"  brew_outdated_normalized
        cache_refresh_entry "manual_updates" collect_manual_updates "$mas_outdated_raw"
    fi

    if [[ "$tier" == "installed" || "$tier" == "all" ]]; then
        cache_refresh_entry "brew_pinned"        brew list --pinned
        cache_refresh_entry "brew_casks"         brew list --cask --versions
        cache_refresh_entry "brew_formulae"      brew list --formula --versions
        # Homebrew's own leaf/dependency split - which formulae the user
        # actually asked for vs. what got pulled in transitively. Drives the
        # "Libraries & Dependencies" bucket in GuideApp's CLI Tools grouping.
        cache_refresh_entry "brew_leaves"        brew leaves
        cache_refresh_entry "brew_formulae_desc" brew_formulae_desc_collect
        cache_refresh_entry "brew_casks_desc"    brew_casks_desc_collect
        cache_refresh_entry "brew_status"        collect_brew_status

        if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
            # Same hang guard as the 'mas outdated' query above: metadata
            # only, so it gets the query limit, and a timeout leaves the
            # previous entry in place rather than an empty installed list.
            cache_refresh_entry "mas_list" run_with_timeout "$MAS_QUERY_TIMEOUT" mas list
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

    return 0
}

# Refresh only what a single finished update can have changed, for one item.
#
# The alternative is collect_cache_data "all", which is what the single-item
# run mode used to call, and it costs seconds no matter how small the upgrade
# was: 'brew desc' over every installed formula and cask, a rescan of every
# self-updating app, and the websites tier - whose entries carry a 24h TTL
# (CACHE_TTL_WEBSITES) precisely because a homepage does not change. Measured
# in whole seconds on a machine with mas absent - 4.6s against a warm cache,
# ~19s when the app scan and homepage fetches have to go to the network - and
# worse again with mas installed. All of it lands AFTER the package is already
# upgraded and BEFORE the "done" progress line, and GuideApp only resolves the
# row when the process exits (ToolkitRunner.finishActiveItem) - so a 3-second
# 'brew upgrade jq' sat on "Güncelleniyor" for 7+ seconds.
#
# So: refresh the entries that decide whether this row is still pending, plus
# the installed list that shows its new version. Every other entry keeps its
# own TTL and is picked up by the next background refresh, which is exactly
# what those TTLs are for.
#
# Serialized on the "cache" lock, which the whole-cache refresh action already
# takes (update_system.1h.sh, "refresh_cache"). GuideApp runs up to
# preferences.maxConcurrentUpdates single-item updates at once (default 2,
# ToolkitSettings), and two unsynchronized writers race: run B can compute
# brew_outdated while run A's upgrade is still in flight, so it still sees A's
# package as outdated, and it writes that over the fresh entry A just wrote -
# after which A re-reads the list and reports its own success as a failure.
# The wait is bounded (CACHE_LOCK_WAIT); refreshing anyway on a timeout beats
# the alternative, which is announcing "done" over a cache that still lists
# this very item as pending.
#
# Best-effort like collect_cache_data, and for the same reason: callers run
# under 'set -e', where one unreachable brew command would otherwise abort the
# run before its history entry and final progress line ever got written.
collect_cache_for_item() {
    setopt local_options no_err_exit
    local item_type="$1"
    local item_id="$2"

    acquire_lock "cache" "$CACHE_LOCK_WAIT"

    case "$item_type" in
        "brew"|"cask")
            # The list GuideApp re-reads to decide Updated vs. Failed...
            cache_refresh_entry "brew_outdated" brew_outdated_normalized
            # ...and the installed list the row's version is read from. Only
            # the one of the two this item lives in: a cask upgrade cannot
            # change the formula list, or the other way round.
            if [[ "$item_type" == "cask" ]]; then
                cache_refresh_entry "brew_casks" brew list --cask --versions
            else
                cache_refresh_entry "brew_formulae" brew list --formula --versions
            fi
            ;;
        "mas")
            if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
                # Same hang guard as every other 'mas' query in this project.
                cache_refresh_entry "mas_outdated" run_with_timeout "$MAS_QUERY_TIMEOUT" mas outdated
            else
                cache_put "mas_outdated" ""
            fi

            # A ghost app - an Apple title 'mas outdated' never reports - is
            # pending because manual_updates says so, and GuideApp gives it
            # the same type "mas" as any other App Store row
            # (ToolkitRunner.updateSingle). Leaving that entry alone would
            # keep the row on the pending list and turn a real success into a
            # "Failed". Rebuilt only when this id is actually one of them,
            # since every ghost app costs an iTunes Lookup round trip.
            if cache_lists_manual_update "$item_id"; then
                cache_refresh_entry "manual_updates" collect_manual_updates "$(cache_get "mas_outdated")"
            fi
            ;;
    esac

    release_lock "cache"
    return 0
}

# Is this App Store id currently listed in the manual_updates entry?
# Line format: name|local_version|remote_version|app_id
cache_lists_manual_update() {
    local wanted="$1" line
    [[ -n "$wanted" ]] || return 1
    for line in ${(f)"$(cache_get "manual_updates")"}; do
        [[ "${line##*|}" == "$wanted" ]] && return 0
    done
    return 1
}
