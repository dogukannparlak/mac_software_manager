# Download with Failover (GitHub -> Codeberg)
# Usage: download_with_failover "filename.sh" "output_path"
download_with_failover() {
    local file_name="$1"
    local output_path="$2"

    # Records which mirror served the file, so integrity checks know which
    # SHA256SUMS is the "same source" one.
    DOWNLOAD_SOURCE=""

    # Try Primary (GitHub)
    # -f fails on HTTP errors (404), -L follows redirects, -s silent
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 "$URL_PRIMARY_BASE/$file_name" -o "$output_path"; then
        echo "✅ GitHub available, file downloaded"
        DOWNLOAD_SOURCE="primary"
        return 0
    fi

    echo "⚠️ Primary source (Github) failed. Trying backup..."

    if [[ -z "$URL_BACKUP_BASE" ]]; then
        echo "⚠️ No Codeberg mirror configured, nothing to fall back to."
        return 1
    fi

    # Try Backup (Codeberg)
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 8 "$URL_BACKUP_BASE/$file_name" -o "$output_path"; then
        echo "✅ Codeberg available, file downloaded"
        DOWNLOAD_SOURCE="backup"
        return 0
    fi
    echo "⚠️ Secondary source (Codeberg) failed too."
    return 1
}

# Calculate SHA256 Hash
calculate_hash() {
    if [[ ! -f "$1" ]]; then return 1; fi
    shasum -a 256 "$1" | awk '{print $1}'
}

# ------------------------------------------------------------------------------
# 3e. DOWNLOAD INTEGRITY
# ------------------------------------------------------------------------------
# Self-update overwrites a script that runs on every menu refresh, so nothing is
# installed before it passes: SHA256 against the publisher's SHA256SUMS, the
# second mirror agreeing, and the file actually parsing as zsh.

# Expected SHA256 for a file according to a given source's SHA256SUMS
remote_expected_hash() {
    local base_url="$1"
    local file_name="$2"
    local sums=""

    sums=$(curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        -H "User-Agent: $USER_AGENT" "$base_url/SHA256SUMS" 2>/dev/null) || return 1

    # SHA256SUMS lines are "<64 hex>  <filename>"
    print -r -- "$sums" | awk -v target="$file_name" '
        { name = $2; sub(/^\*/, "", name) }
        name == target { print $1; found = 1; exit }
        END { exit !found }
    '
}

# Gate a downloaded script before it replaces anything on disk.
# Usage: verify_download "<remote file name>" "<local path>" ["<required header>"]
verify_download() {
    local file_name="$1"
    local file_path="$2"
    local want_header="${3:-}"
    local actual="" expected_same="" expected_other="" same_base="" other_base=""

    if [[ ! -s "$file_path" ]]; then
        echo "❌ Integrity: downloaded $file_name is empty."
        return 1
    fi

    # A truncated or tampered script usually stops parsing. 'zsh -n' only parses.
    if ! zsh -n "$file_path" 2>/dev/null; then
        echo "❌ Integrity: $file_name is not valid zsh (truncated or modified)."
        return 1
    fi

    if [[ -n "$want_header" ]] && ! grep -q "$want_header" "$file_path"; then
        echo "❌ Integrity: $file_name is missing its '$want_header' marker."
        return 1
    fi

    if [[ "$DOWNLOAD_SOURCE" == "backup" ]]; then
        same_base="$URL_BACKUP_BASE"
        other_base="$URL_PRIMARY_BASE"
    else
        same_base="$URL_PRIMARY_BASE"
        other_base="$URL_BACKUP_BASE"
    fi

    actual=$(calculate_hash "$file_path") || return 1

    if ! expected_same=$(remote_expected_hash "$same_base" "$file_name"); then
        echo "❌ Integrity: no SHA256SUMS entry for $file_name at the download source."
        echo "   Refusing to install an unverified script."
        return 1
    fi

    if [[ "$actual" != "$expected_same" ]]; then
        echo "❌ Integrity: checksum mismatch for $file_name."
        echo "   expected $expected_same"
        echo "   got      $actual"
        return 1
    fi

    # Cross-source check: a single compromised or half-pushed mirror is caught here
    if [[ -z "$other_base" ]]; then
        echo "⚠️ No Codeberg mirror configured: $file_name verified against GitHub only."
    elif expected_other=$(remote_expected_hash "$other_base" "$file_name"); then
        if [[ "$expected_other" != "$expected_same" ]]; then
            echo "❌ Integrity: GitHub and Codeberg publish different checksums for $file_name."
            echo "   Refusing to install. Retry later or update manually."
            return 1
        fi
        echo "✅ Integrity verified for $file_name (both sources agree)."
    else
        echo "⚠️ Second source unreachable: $file_name verified against one source only."
    fi

    return 0
}

# Download + verify in one step, leaving the target untouched on any failure
download_verified() {
    local file_name="$1"
    local output_path="$2"
    local want_header="${3:-}"

    download_with_failover "$file_name" "$output_path" || return 1
    verify_download "$file_name" "$output_path" "$want_header" || return 1
    return 0
}


check_for_updates_manual() {
    echo "Checking for updates..."

    local temp_headers="$(mktemp "${TMPDIR:-/tmp}/update_headers.XXXXXX")"
    local temp_body="$(mktemp "${TMPDIR:-/tmp}/update_body.XXXXXX")"

    trap 'rm -f "$temp_headers" "$temp_body"' EXIT

    local local_etag=""

    [[ -f "$ETAG_FILE" ]] && local_etag=$(cat "$ETAG_FILE")

    # Check ETag (Primary Source)
    # '|| true' keeps a network hiccup here (DNS, timeout) from tripping set -e
    # before the existing http_code checks below get a chance to handle it.
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -D "$temp_headers" \
        -H "If-None-Match: $local_etag" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout 5 \
        "$URL_PRIMARY_BASE/update_system.1h.sh" || true)

    if [[ "$http_code" == "304" ]]; then
        echo "✅ Status 304: No changes."
        rm -f "$PENDING_FLAG" "$temp_headers" "$temp_body"
        osascript -e "display notification \"Plugin is up to date.\" with title \"Mac Software Manager\""
        return 0
    fi

    # Download (Failover Logic)
    local source_verified="false"

    if [[ "$http_code" == "200" ]]; then
        if curl -s -o "$temp_body" "$URL_PRIMARY_BASE/update_system.1h.sh"; then
            # '|| true': a response without an ETag header is normal, not fatal.
            grep -i "etag:" "$temp_headers" | awk '{print $2}' | tr -d '"\r\n' > "$ETAG_FILE" || true
            source_verified="true"
        fi
    fi

    if [[ "$source_verified" == "false" ]]; then
        if [[ -z "$URL_BACKUP_BASE" ]]; then
            echo "⚠️ Primary failed (HTTP $http_code). No Codeberg mirror configured to fall back to."
        else
            echo "⚠️ Primary failed (HTTP $http_code). Downloading from Backup..."
            if curl -fLsS --connect-timeout 8 "$URL_BACKUP_BASE/update_system.1h.sh" -o "$temp_body"; then
                source_verified="true"
            fi
        fi
    fi

    if [[ "$source_verified" != "true" ]]; then
        echo "❌ Error: Update connection to GitHub and Codeberg failed."
        osascript -e "display notification \"Update connection to Github and Codeberg failed.\" with title \"Mac Software Manager\""
        return 1
    fi

    # Verify & Compare
    local local_ver="${VERSION//v/}"
    local remote_ver=$(extract_version "$temp_body")
    local local_hash=$(calculate_hash "$SCRIPT_FILE")
    local remote_hash=$(calculate_hash "$temp_body")

    echo "Verify: Local v$local_ver vs Remote v$remote_ver"

    if [[ -z "$local_ver" ]]; then
        echo "❌ Critical Error: Could not determine local version."
        return 1
    fi

    if [[ "$local_hash" == "$remote_hash" ]]; then
        echo "ℹ️ Files are identical."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"You have the latest version (v$local_ver).\" with title \"Mac Software Manager\""

    elif [[ "$local_ver" == "$remote_ver" ]]; then
        echo "ℹ️ Version matches, but hashes not. Ignoring. Verify local and remote version, probably cosmetical changes..."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Up to date (v$local_ver).\" with title \"Mac Software Manager\""

    elif is-at-least "$remote_ver" "$local_ver"; then
        echo "⚠️ Remote version (v$remote_ver) is OLDER than local (v$local_ver)."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Server has older version (v$remote_ver).\" with title \"Mac Software Manager\" subtitle \"Keeping local v$local_ver.\""

    else
        echo "✅ Valid Update: v$remote_ver > v$local_ver"
        touch "$PENDING_FLAG"
        osascript -e "display notification \"New version v$remote_ver available!\" with title \"Mac Software Manager\" subtitle \"Click 'Update All' to install.\""
    fi
}
