import Foundation

/// The installer half of `AppUpdater`, kept apart from the class body: the
/// script that swaps the bundle after the app has quit.
extension AppUpdater {

    /// Run detached after this app has asked to quit.
    ///
    /// Arguments: pid, installed app, staged new app, where to keep the old
    /// one, log file. Every step that can fail leaves a working app in the
    /// original place: the old one is only moved aside, never deleted, and
    /// moved back if the new one cannot take its place.
    static let helperScript = #"""
    #!/bin/zsh
    pid="$1" current="$2" staged="$3" previous="$4" log="$5"
    exec >>"$log" 2>&1
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') installing $staged"

    # Up to 30 s for the app to finish quitting.
    for i in {1..150}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "The app did not quit; nothing was changed."
        exit 1
    fi

    if [[ ! -d "$staged" ]]; then
        echo "The downloaded app is gone; nothing was changed."
        /usr/bin/open "$current"
        exit 1
    fi

    mkdir -p "${previous:h}"
    rm -rf "$previous"
    if ! mv "$current" "$previous"; then
        echo "Could not move the installed app aside; nothing was changed."
        /usr/bin/open "$current"
        exit 1
    fi

    if ! mv "$staged" "$current"; then
        echo "Could not move the new app into place; restoring the previous one."
        rm -rf "$current"
        mv "$previous" "$current"
        /usr/bin/open "$current"
        exit 1
    fi

    echo "Installed. Previous version kept at $previous"
    /usr/bin/open "$current"
    """#
}
