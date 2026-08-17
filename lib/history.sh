# ------------------------------------------------------------------------------
# 3f. HISTORY LOG
# ------------------------------------------------------------------------------

# Keep the history log from growing without bound. Called after every append
# to it - the bulk system update, a single package update, and a self-updating
# app install all go through this one function, so the 500/300 line policy
# cannot silently apply to only one of those code paths.
trim_history_log() {
    [[ -f "$HISTORY_FILE" ]] || return 0
    if [[ $(wc -l < "$HISTORY_FILE") -gt 500 ]]; then
        tail -n 300 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
}
