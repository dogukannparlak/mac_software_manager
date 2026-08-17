typeset -A IGNORED_APPS_MAP

# Load to memory ignored apps
load_ignored_cache() {
    IGNORED_APPS_MAP=()
    if [[ -f "$IGNORED_FILE" ]]; then
        # Read type, id AND name
        while IFS='|' read -r type id name || [[ -n "$type" ]]; do
            # Aggressive cleaning for type keeps only alphanumeric characters
            # Removes BOM spaces non breaking spaces tabs
            local clean_type=$(echo "$type" | tr -cd '[:alnum:]')

            # ID sanitising depends on the source. App Store IDs are numeric,
            # but cask tokens ("cursor") and Sparkle app names ("AltTab") are
            # not: stripping everything non-numeric silently dropped every
            # cask entry, so "Ignore" never took effect for casks.
            # Note the explicit ="": a bare 'local x' on a name that already
            # holds a value makes zsh echo "x=value", which would corrupt the
            # menu output on the second loop iteration.
            local clean_id=""
            if [[ "$clean_type" == "mas" ]]; then
                clean_id=$(echo "$id" | tr -cd '0-9')
            else
                clean_id=$(echo "$id" | tr -d '\r\n|' | tr -cd '[:alnum:] ._@+-')
                # Trim surrounding whitespace
                clean_id="${clean_id#"${clean_id%%[![:space:]]*}"}"
                clean_id="${clean_id%"${clean_id##*[![:space:]]}"}"
            fi

            # Skip invalid lines
            [[ -z "$clean_type" || -z "$clean_id" ]] && continue

            # Key is type pipe id
            local clean_key="${clean_type}|${clean_id}"

            # Value in the map is now the NAME stripped of newlines
            local clean_name=$(echo "${name:-$id}" | tr -d '\r\n')

            IGNORED_APPS_MAP[$clean_key]="$clean_name"
        done < "$IGNORED_FILE"
    fi
}

# Check if an app is ignored (cask or mas)
# Usage: is_ignored "type" "identifier"
is_ignored() {
    # Check if value exists for key using string test instead of arithmetic
    [[ -n "${IGNORED_APPS_MAP[$1|$2]}" ]]
}

# Add app to ignore list (Supports: type|id|name)
add_ignored() {
    local type="$1" id="$2" name="${3:-$id}"
    # Remove pipes from name to prevent parsing errors
    name="${name//|/}"
    if ! is_ignored "$type" "$id"; then
        echo "${type}|${id}|${name}" >> "$IGNORED_FILE"
    fi
}

# Remove app from ignore list (Matches type|id ONLY)
remove_ignored() {
    local type="$1"
    local id="$2"
    local safe_type safe_id
    safe_type=$(escape_ere "$type")
    safe_id=$(escape_ere "$id")
    # Delete line starting with type|id followed by pipe or EOL
    # This ensures strict matching of ID regardless of whether a name suffix exists
    [[ -f "$IGNORED_FILE" ]] && sed -i '' -E "/^${safe_type}\|${safe_id}(\||$)/d" "$IGNORED_FILE"
}

# Populated once, immediately, so is_ignored() has data as soon as this file
# is sourced - callers never have to remember to load it themselves.
load_ignored_cache
