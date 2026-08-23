# ------------------------------------------------------------------------------
# APPLICATION REPLACEMENT
# ------------------------------------------------------------------------------
# Downloading and swapping a .app is the only operation here that can leave a
# user without a working application, so the rules are strict:
#
#   * DMG and ZIP only. A .pkg runs preinstall/postinstall scripts as root:
#     it cannot be sandboxed and cannot be rolled back, so it is refused.
#   * Nothing on disk is touched until every signature check has passed.
#   * The old bundle is moved aside, not deleted, and is restored on any error.
#
# Verified against real downloads: apps shipped with a "Developer ID
# Application" certificate and notarised pass all checks, while an app signed
# with a plain "Apple Development" certificate is rejected by Gatekeeper - which
# is the intended outcome, not a bug to work around.

# Process name of an app bundle (CFBundleExecutable, falling back to the name)
app_executable_name() {
    local app_path="$1"
    local exec_name=""
    exec_name=$(plist_value "$app_path/Contents/Info.plist" CFBundleExecutable) || exec_name=""
    print -r -- "${exec_name:-${${app_path:t}%.app}}"
}

app_running() {
    pgrep -x "$(app_executable_name "$1")" >/dev/null 2>&1
}

quit_running_app() {
    local app_path="$1"
    local app_name="${${app_path:t}%.app}"
    local proc_name
    proc_name=$(app_executable_name "$app_path")

    app_running "$app_path" || return 0

    echo "   Closing $app_name..."
    osascript -e "quit app \"$(applescript_escape "$app_name")\"" 2>/dev/null || true

    local waited=0
    while (( waited < 10 )); do
        app_running "$app_path" || return 0
        sleep 1
        # Same trap as load_config_safely's line counter: a post-increment
        # from 0 evaluates to 0, which zsh reports as a failed command, and
        # this loop runs under 'set -e'. The first second of waiting for an
        # app to quit would have ended the whole install.
        waited=$(( waited + 1 ))
    done

    echo "   $app_name did not quit; forcing."
    killall -- "$proc_name" 2>/dev/null || true
    sleep 1
    return 0
}

# TeamIdentifier of a signed bundle. Unsigned bundles report "not set".
codesign_team_id() {
    codesign -dv --verbose=4 "$1" 2>&1 | grep -m1 '^TeamIdentifier=' | cut -d= -f2
}

# An OpenSSL that can verify raw ed25519 signatures.
# The system binary is LibreSSL, which has no -rawin, so this looks for a
# Homebrew OpenSSL 3 before giving up.
find_ed25519_openssl() {
    local candidate
    for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                     /usr/local/opt/openssl@3/bin/openssl \
                     "${commands[openssl]}"; do
        [[ -x "$candidate" ]] || continue
        if "$candidate" pkeyutl -help 2>&1 | grep -q -- "-rawin"; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

# Sparkle's own EdDSA check over the downloaded archive.
# Returns 0 verified, 1 signature invalid (fatal), 2 not applicable.
verify_sparkle_ed_signature() {
    local installed_app="$1"
    local archive="$2"
    local signature="$3"
    local pubkey="" openssl_bin="" der_file="" sig_file=""

    pubkey=$(plist_value "$installed_app/Contents/Info.plist" SUPublicEDKey) || pubkey=""
    [[ -n "$pubkey" && -n "$signature" ]] || return 2

    openssl_bin=$(find_ed25519_openssl) || return 2

    der_file="$(mktemp "${TMPDIR:-/tmp}/edkey.XXXXXX")" || return 2
    sig_file="$(mktemp "${TMPDIR:-/tmp}/edsig.XXXXXX")" || { rm -f "$der_file"; return 2; }

    # Wrap the 32 raw key bytes in the DER prefix for an ed25519 public key
    if ! { printf '302a300506032b6570032100' | xxd -r -p > "$der_file" && \
           print -r -- "$pubkey" | base64 -d >> "$der_file" && \
           print -r -- "$signature" | base64 -d > "$sig_file"; } 2>/dev/null; then
        rm -f "$der_file" "$sig_file"
        return 2
    fi

    if "$openssl_bin" pkeyutl -verify -pubin -inkey "$der_file" -keyform DER \
        -rawin -in "$archive" -sigfile "$sig_file" >/dev/null 2>&1; then
        rm -f "$der_file" "$sig_file"
        return 0
    fi

    rm -f "$der_file" "$sig_file"
    return 1
}

# The gate. Every check must pass before anything is written to /Applications.
verify_app_replacement() {
    local installed_app="$1"
    local downloaded_app="$2"
    local expected_version="$3"
    local archive="$4"
    local ed_signature="$5"
    local old_team new_team downloaded_version ed_rc

    echo "🔐 Verifying the download..."

    # 1. Same developer. This is the check that actually proves provenance.
    old_team=$(codesign_team_id "$installed_app")
    new_team=$(codesign_team_id "$downloaded_app")

    if [[ -z "$old_team" || "$old_team" == "not set" ]]; then
        echo "❌ The installed application has no Team ID (unsigned or Apple-internal)."
        echo "   There is nothing to compare against, so it will not be replaced."
        return 1
    fi

    if [[ -z "$new_team" || "$new_team" == "not set" ]]; then
        echo "❌ The downloaded application is not signed."
        return 1
    fi

    if [[ "$old_team" != "$new_team" ]]; then
        echo "❌ Team ID mismatch."
        echo "   installed:   $old_team"
        echo "   downloaded:  $new_team"
        echo "   The download is not from the same developer. Aborting."
        return 1
    fi
    echo "   ✓ Team ID matches ($old_team)"

    # 2. The signature itself must be intact
    if ! codesign --verify "$downloaded_app" 2>/dev/null; then
        echo "❌ Code signature verification failed for the download."
        codesign --verify "$downloaded_app" 2>&1 | sed 's/^/   /'
        return 1
    fi
    echo "   ✓ Code signature is valid"

    # 3. Gatekeeper. Rejects anything not signed for distribution and notarised.
    if ! spctl -a -t open --context context:primary-signature "$downloaded_app" >/dev/null 2>&1; then
        echo "❌ Gatekeeper rejected the download."
        echo "   Typically this means the app is signed with a development"
        echo "   certificate or has not been notarised by Apple."
        echo "   Install it yourself from the publisher if you trust it."
        return 1
    fi
    echo "   ✓ Gatekeeper accepted the download"

    # 4. Sparkle's own EdDSA signature, when the app publishes a key
    verify_sparkle_ed_signature "$installed_app" "$archive" "$ed_signature"
    ed_rc=$?
    case $ed_rc in
        0) echo "   ✓ Sparkle EdDSA signature verified" ;;
        1)
            echo "❌ Sparkle EdDSA signature does NOT match the download."
            return 1
            ;;
        *) echo "   • Sparkle EdDSA signature not checked (no key, no signature, or no OpenSSL 3)" ;;
    esac

    # 5. The bundle must actually be the version the feed advertised
    downloaded_version=$(plist_value "$downloaded_app/Contents/Info.plist" CFBundleShortVersionString) || downloaded_version=""
    downloaded_version=$(normalize_version "$downloaded_version") || downloaded_version=""
    if [[ -n "$expected_version" && -n "$downloaded_version" && "$downloaded_version" != "$expected_version" ]]; then
        echo "❌ Version mismatch: feed promised $expected_version, archive contains $downloaded_version."
        return 1
    fi
    echo "   ✓ Version is $downloaded_version"

    return 0
}

# Unpack a DMG or ZIP and print the path of the single .app inside it
extract_app_from_archive() {
    local archive="$1"
    local workdir="$2"
    local extract_dir="$workdir/extract"
    local mountpoint="$workdir/mnt"
    typeset -a found

    mkdir -p "$extract_dir" || return 1

    case "${archive:l}" in
        *.zip)
            # ditto keeps extended attributes and resource forks intact,
            # which unzip does not - and a mangled bundle fails codesign.
            ditto -x -k "$archive" "$extract_dir" 2>/dev/null || return 1
            ;;
        *.dmg)
            mkdir -p "$mountpoint" || return 1
            hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mountpoint" \
                "$archive" >/dev/null 2>&1 || return 1

            found=("$mountpoint"/*.app(N))
            if (( ${#found[@]} == 1 )); then
                ditto "${found[1]}" "$extract_dir/${found[1]:t}" 2>/dev/null
            fi

            hdiutil detach "$mountpoint" -quiet 2>/dev/null \
                || hdiutil detach "$mountpoint" -force -quiet 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac

    found=("$extract_dir"/*.app(N) "$extract_dir"/*/*.app(N))
    (( ${#found[@]} == 1 )) || return 1

    print -r -- "${found[1]}"
}

# Swap the bundle, keeping the old one until the new one is in place
replace_app_bundle() {
    local installed_app="$1"
    local downloaded_app="$2"
    local backup="${installed_app}.msu-backup"

    rm -rf "$backup" 2>/dev/null || true

    if ! mv "$installed_app" "$backup" 2>/dev/null; then
        echo "❌ Could not move the current application aside (permissions?)."
        return 1
    fi

    if ! ditto "$downloaded_app" "$installed_app" 2>/dev/null; then
        echo "❌ Copy failed. Restoring the previous version..."
        rm -rf "$installed_app" 2>/dev/null || true
        mv "$backup" "$installed_app" 2>/dev/null || true
        return 1
    fi

    # Sanity check before the backup is dropped
    if [[ ! -d "$installed_app/Contents/MacOS" ]]; then
        echo "❌ The installed bundle looks incomplete. Restoring..."
        rm -rf "$installed_app" 2>/dev/null || true
        mv "$backup" "$installed_app" 2>/dev/null || true
        return 1
    fi

    # Already assessed by Gatekeeper above, so clear the quarantine flag the
    # download left behind - otherwise macOS re-prompts on first launch.
    xattr -dr com.apple.quarantine "$installed_app" 2>/dev/null || true

    rm -rf "$backup" 2>/dev/null || true
    return 0
}
