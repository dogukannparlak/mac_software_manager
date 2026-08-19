load "test_helper"

# notify(): routes through GuideApp's UNUserNotificationCenter bridge (a
# queued request file under $APP_DIR/notifications, see CACHE_FORMAT.md
# "Notification queue") when GuideApp is running, and falls back to a plain
# 'osascript display notification' otherwise. GuideApp is never actually
# running in this test environment, so "is it running" is faked by stubbing
# pgrep - the only thing notify() asks the system about.
CANONICAL_LINE="v1|Mac Software Manager|Update Complete|3 package(s) updated successfully."

@test "notify falls back to osascript when GuideApp is not running" {
    run run_zsh_snippet '
        pgrep() { return 1; }
        osascript() { echo "STUB osascript $*"; }
        notify "Hello there." "A Subtitle"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB osascript -e display notification"* ]]
    [[ "$output" == *"Hello there."* ]]
    [[ "$output" == *"A Subtitle"* ]]
    [[ "$output" == *"Mac Software Manager"* ]]
}

@test "notify omits the subtitle clause from the osascript fallback when none is given" {
    run run_zsh_snippet '
        pgrep() { return 1; }
        osascript() { echo "STUB osascript $*"; }
        notify "Just a plain message."
    '
    [ "$status" -eq 0 ]
    [[ "$output" != *"subtitle"* ]]
}

@test "notify writes a request file for GuideApp instead of calling osascript when GuideApp is running" {
    run run_zsh_snippet '
        pgrep() { return 0; }
        osascript() { echo "STUB osascript $*"; }
        notify "3 package(s) updated successfully." "Update Complete"
        cat "$NOTIFY_DIR"/notify.* 2>/dev/null
    '
    [ "$status" -eq 0 ]
    [[ "$output" != *"STUB osascript"* ]]
    [ "$output" = "$CANONICAL_LINE" ]
}

@test "notify's queued request file matches the canonical CACHE_FORMAT.md example exactly" {
    run run_zsh_snippet '
        pgrep() { return 0; }
        notify "3 package(s) updated successfully." "Update Complete"
        cat "$NOTIFY_DIR"/notify.* 2>/dev/null
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$CANONICAL_LINE" ]
}

@test "notify strips a pipe from the body and subtitle so the record stays 4 fields" {
    run run_zsh_snippet '
        pgrep() { return 0; }
        notify "Failed: brew|cask install" "Update|Failed"
        cat "$NOTIFY_DIR"/notify.* 2>/dev/null
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|Mac Software Manager|UpdateFailed|Failed: brewcask install" ]
}

@test "notify collapses embedded newlines to a single line" {
    run run_zsh_snippet '
        pgrep() { return 0; }
        notify $'"'"'Line one\nLine two'"'"'
        cat "$NOTIFY_DIR"/notify.* 2>/dev/null
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v1|Mac Software Manager||Line one Line two" ]
}

@test "notify falls back to osascript when the request file cannot be written" {
    # GuideApp looks like it is running, but the notifications directory is
    # unwritable - notify() must still reach the user, not just give up.
    run run_zsh_snippet '
        pgrep() { return 0; }
        osascript() { echo "STUB osascript $*"; }
        mkdir -p "$NOTIFY_DIR"
        chmod 000 "$NOTIFY_DIR"
        notify "Could not queue this one."
        rc=$?
        chmod 755 "$NOTIFY_DIR"
        exit $rc
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB osascript"* ]]
    [[ "$output" == *"Could not queue this one."* ]]
}

@test "notify survives under set -e when the request directory cannot be created" {
    # Mirrors how notify() is actually called: inside update_system.1h.sh's
    # action-handling path, which runs the whole script under 'set -e'.
    run run_zsh_snippet '
        set -e
        pgrep() { return 0; }
        osascript() { echo "STUB osascript $*"; }
        # Make the parent itself unwritable so mkdir -p "$NOTIFY_DIR" fails.
        chmod 000 "$APP_DIR"
        notify "Still here."
        rc=$?
        chmod 755 "$APP_DIR"
        exit $rc
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB osascript"* ]]
}
