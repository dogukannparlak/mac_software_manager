# ------------------------------------------------------------------------------
# MENU RENDERING
# ------------------------------------------------------------------------------
# render_menu is what SwiftBar actually calls on every draw: no argument
# matched any action in section 5's dispatch, so the main script falls
# through to this. It used to be two numbered top-level sections
# ("6. BACKGROUND CHECKS & STATS" and "7. UI RENDERING") that just ran in
# sequence; wrapping them in one function did not change what runs or in
# what order, only that it is now named and callable.
#
# SwiftBar re-runs this path on every menu draw, so it must not touch the
# network or shell out to brew/mas. Everything comes from the cache; stale
# tiers are rebuilt by a detached background process that refreshes the menu
# when it finishes. Ignore-list filtering stays here because it is free and
# must react immediately.
#
# One bad cache entry or a missing file must never blank the whole menu, so
# this function deliberately opts back out of the strict error handling
# turned on in section 5: 'set +e' here is a real, global shell option change
# (zsh functions do not get their own option scope unless LOCAL_OPTIONS is
# set, which this script does not use) - a failure here is swallowed and
# rendering continues with whatever data is available, rather than the user
# losing the menu entirely.
render_menu() {
set +e

# Check pending flag
update_available=0
[[ -f "$PENDING_FLAG" ]] && update_available=1

cache_stale="$(cache_stale_tiers)"
cache_ts=$(cache_last_check)
[[ -n "$cache_stale" ]] && spawn_cache_refresh "auto"

# Pinned formulae (native brew pin) as an array - empty lines dropped
typeset -a pinned_arr
for cache_line in ${(f)"$(cache_get "brew_pinned")"}; do
    [[ -n "$cache_line" ]] && pinned_arr+=("$cache_line")
done

# Homebrew updates from the normalized cache: src|token|old|new|pinned
# Pinned formulae and ignored casks are dropped by exact token match - no
# regex over free-form text, so a '+' or '.' in a token cannot misfire.
typeset -a brew_entries entry_fields
brew_entries=()
for cache_line in ${(f)"$(cache_get "brew_outdated")"}; do
    [[ -n "$cache_line" ]] || continue
    entry_fields=("${(@s:|:)cache_line}")
    (( ${#entry_fields[@]} >= 5 )) || continue

    # entry_fields: 1=src 2=token 3=old 4=new 5=pinned
    [[ "${entry_fields[5]}" == "1" ]] && continue
    [[ ${pinned_arr[(Ie)${entry_fields[2]}]} -gt 0 ]] && continue
    [[ "${entry_fields[1]}" == "cask" ]] && is_ignored "cask" "${entry_fields[2]}" && continue

    brew_entries+=("$cache_line")
done

count_brew=${#brew_entries[@]}

# Check App Store for updates (filter ignored MAS apps)
list_mas=""
count_mas=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    list_mas=$(cache_get "mas_outdated" || true)

    # OPTIMIZED: Filter out ignored MAS apps using memory cache
    typeset -a ignored_mas_patterns
    for key in ${(k)IGNORED_APPS_MAP}; do
        if [[ "$key" == mas\|* ]]; then
            # Match ID at start of line + TRAILING SPACE to avoid partial ID matches
            # e.g. ensure ID "123" doesn't match "12345"
            ignored_mas_patterns+=("^[[:space:]]*${key#mas|}[[:space:]]")
        fi
    done

    if [[ ${#ignored_mas_patterns[@]} -gt 0 ]]; then
        # Use <<< for safety and || true to prevent exit code 1 if all updates are ignored
        list_mas=$(grep -vE "${(j:|:)ignored_mas_patterns}" <<< "$list_mas" || true)
    fi

    count_mas=$(echo "$list_mas" | grep -E '^[[:space:]]*[0-9]+' | wc -l | tr -d ' ')
fi

# MANUAL CHECK FOR GHOST APPS
# Apple titles the mas CLI regularly misses. The iTunes Lookup calls happen in
# the background refresh (collect_manual_updates); here we only read the result.
# Line format: name|local_version|remote_version|app_id
manual_updates_list=""
count_manual=0

if [[ "$MAS_ENABLED" == "1" ]]; then
    for cache_line in ${(f)"$(cache_get "manual_updates")"}; do
        [[ -n "$cache_line" ]] || continue
        manual_id="${cache_line##*|}"
        # The ignore list can change between refreshes: honour it at render time
        is_ignored "mas" "$manual_id" && continue
        manual_updates_list+="$cache_line"$'\n'
        ((++count_manual))
    done
fi

# SELF-UPDATING APPS (Sparkle appcast / GitHub releases)
# Detection only: the menu links to the publisher's download, it never installs.
# Line format: method|name|local_version|remote_version|url|signature
app_updates_list=""
count_apps=0

for cache_line in ${(f)"$(cache_get "app_updates")"}; do
    [[ -n "$cache_line" ]] || continue
    entry_fields=("${(@s:|:)cache_line}")
    (( ${#entry_fields[@]} >= 4 )) || continue
    is_ignored "sparkle" "${entry_fields[2]}" && continue
    app_updates_list+="$cache_line"$'\n'
    ((++count_apps))
done

# Aggregate total updates count
total=$((count_brew + count_mas + count_manual + count_apps))

# Collect installed stats
# Casks
raw_casks=$(cache_get "brew_casks" || true)
count_casks=$(echo -n "$raw_casks" | grep -c -- '[^[:space:]]' || true)

# Formulae
raw_formulae=$(cache_get "brew_formulae" || true)
count_formulae=$(echo -n "$raw_formulae" | grep -c -- '[^[:space:]]' || true)

# MAS (App Store)
installed_mas=""
count_mas_installed=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    installed_mas=$(cache_get "mas_list" || true)
    count_mas_installed=$(echo -n "$installed_mas" | grep -c -- '[^[:space:]]' || true)
fi
total_installed=$((count_casks + count_formulae + count_mas_installed))

# History Stats
count_7d=0
count_30d=0
history_7d=""
history_30d=""
# Track last printed date for grouping headers
last_date_7d=""
last_date_30d=""
current_time=$(date +%s)

if [[ -f "$HISTORY_FILE" ]]; then
    # Read file in reverse order (newest first) using sed
    # Records written before v1.5 have no status field; those are treated as "ok"
    while IFS='|' read -r log_time log_src log_name log_old log_new log_id log_status; do

        # Skip legacy entries, invalid timestamps
        if [[ -z "$log_time" || ! "$log_time" =~ ^[0-9]+$ ]]; then continue; fi
        if [[ -z "$log_name" || -z "$log_new" ]]; then continue; fi

        # Calculate age of the update
        diff=$((current_time - log_time))

        # Stop processing if older than 30 days (optimization)
        if [[ $diff -gt 2592000 ]]; then break; fi

        # Determine Icon
        icon="terminal"
        [[ "$log_src" == "cask" ]] && icon="square.stack.3d.up"
        [[ "$log_src" == "mas" ]] && icon="bag"
        [[ "$log_src" == "sparkle" ]] && icon="sparkles"
        [[ "$log_src" == "github" ]] && icon="chevron.left.forwardslash.chevron.right"

        # Failed attempts are kept in the log but must not read as successes
        entry_failed=0
        if [[ "$log_status" == "fail" ]]; then
            entry_failed=1
            icon="xmark.circle"
        fi

        # Clean up log_name for display (fixes corrupted entries with IDs or versions)
        clean_name=$(clean_mas_name "$log_name")

        # Truncate versions
        short_old=$(truncate_ver "$log_old")
        short_new=$(truncate_ver "$log_new")
        strftime -s log_date_str "%d %b" "$log_time"
        local link_param=""
        case "$log_src" in
            "brew") link_param=" href='https://formulae.brew.sh/formula/${log_name}'" ;;
            "cask") link_param=" href='https://formulae.brew.sh/cask/${log_name}'" ;;
            "mas")
                # Checks if ID exists for backward compatibility
                if [[ -n "$log_id" ]]; then
                    link_param=" href='https://apps.apple.com/app/id${log_id}'"
                else
                    link_param=" href='https://apps.apple.com/search?term=${clean_name// /%20}'"
                fi
                ;;
        esac

        # Format date header line
        header_line="---- ${log_date_str}: | color=$COLOR_INFO size=11 sfimage=calendar"

        # Format item line with visual indentation (spaces) instead of date
        # Use clean_name instead of raw log_name
        if (( entry_failed )); then
            item_line="----    ${clean_name} [${short_old} → ${short_new}] FAILED | size=11 sfimage=$icon font=Monaco color=$COLOR_WARN${link_param}"
        else
            item_line="----    ${clean_name} [${short_old} → ${short_new}] | size=11 sfimage=$icon font=Monaco${link_param}"
        fi

        # Populate 7 Days Bucket
        if [[ $diff -le 604800 ]]; then
            if [[ "$log_date_str" != "$last_date_7d" ]]; then
                history_7d+="${header_line}"$'\n'
                last_date_7d="$log_date_str"
            fi
            history_7d+="${item_line}"$'\n'
            # Counters report successful updates only
            (( entry_failed )) || ((++count_7d))
        fi

        # Populate 30 Days Bucket (includes 7 days items)
        if [[ $diff -le 2592000 ]]; then
            if [[ "$log_date_str" != "$last_date_30d" ]]; then
                history_30d+="${header_line}"$'\n'
                last_date_30d="$log_date_str"
            fi
            history_30d+="${item_line}"$'\n'
            (( entry_failed )) || ((++count_30d))
        fi

    done < <(tail -r "$HISTORY_FILE")
fi

# Prepare script path for buttons
script_path="$(swiftbar_sq_escape "$SCRIPT_FILE")"

# Freshness label: the menu shows cached data, so report when it was collected
if (( cache_ts > 0 )); then
    strftime -s cache_time_str "%H:%M" "$cache_ts"
    last_check_label="Last check: $cache_time_str"
else
    last_check_label="Last check: collecting data..."
fi
[[ -n "$cache_stale" ]] && last_check_label+=" (refreshing...)"

# Main Bar Icon
if [[ $update_available -eq 1 ]]; then
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.down.circle.fill color=$COLOR_PURPLE"
    else
        echo " ! | sfimage=arrow.down.circle.fill color=$COLOR_BLUE"
    fi
else
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.triangle.2.circlepath.circle color=$COLOR_WARN"
    elif (( cache_ts == 0 )); then
        # No cache yet: do not claim the system is up to date
        echo " | sfimage=hourglass"
    else
        echo " | sfimage=checkmark.circle"
    fi
fi
echo "---"

# Render Plugin Update Notification
if [[ $update_available -eq 1 ]]; then
    echo "Plugin Update Available (Click to Install) | color=$COLOR_BLUE sfimage=arrow.down.circle.fill bash='$script_path' param1=launch_update param2=plugin terminal=false refresh=true"
    echo "---"
fi

# Show update details
if [[ ${#CONFIG_WARNINGS[@]} -gt 0 ]]; then
    echo "Config Warnings (${#CONFIG_WARNINGS[@]}) | color=$COLOR_WARN size=11 sfimage=exclamationmark.triangle"
    for warning in "${CONFIG_WARNINGS[@]}"; do
        echo "-- $warning | color=$COLOR_WARN size=10 trim=true"
    done
    echo "---"
fi

if [[ $total -eq 0 ]]; then
    if (( cache_ts == 0 )); then
        echo "Collecting update data... | color=$COLOR_INFO sfimage=hourglass"
    elif [[ $update_available -eq 1 ]]; then
        echo "Local apps are up to date | color=$COLOR_INFO size=10"
    else
        echo "System is up to date | color=$COLOR_SUCCESS sfimage=checkmark.shield"
    fi
    echo "$last_check_label | size=10 color=$COLOR_INFO"
else
    # System Updates Header (Clickable)
    if [[ $((count_brew + count_mas)) -gt 0 ]]; then
        echo "Update System Apps ($((count_brew + count_mas))) | color=$COLOR_INFO size=12 sfimage=arrow.triangle.2.circlepath bash='$script_path' param1=launch_update param2=system terminal=false refresh=true"
        echo "$last_check_label | size=10 color=$COLOR_INFO"
    fi

    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=$COLOR_INFO size=12 sfimage=shippingbox"
        for cache_line in "${brew_entries[@]}"; do
            entry_fields=("${(@s:|:)cache_line}")
            pkg_type="${entry_fields[1]}"
            name="${entry_fields[2]}"
            old_ver_clean=$(clean_version "${entry_fields[3]}")
            new_ver_clean=$(clean_version "${entry_fields[4]}")

            # Every value below reaches a shell command line via SwiftBar params
            safe_name=$(swiftbar_sq_escape "$name")
            safe_old=$(swiftbar_sq_escape "$old_ver_clean")
            safe_new=$(swiftbar_sq_escape "$new_ver_clean")

            if [[ "$pkg_type" == "cask" ]]; then
                display_line="$name ($old_ver_clean) != $new_ver_clean"
            else
                display_line="$name ($old_ver_clean) < $new_ver_clean"
            fi

            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            echo "-- Update $name | bash='$script_path' param1=update_app param2=$pkg_type param3='$safe_name' param4='$safe_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle"
            echo "-- Ignore $name | bash='$script_path' param1=ignore_app param2=$pkg_type param3='$safe_name' param4='$safe_name' terminal=false refresh=true sfimage=eye.slash"
        done
        echo "---"
    fi

    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=$COLOR_INFO size=12 sfimage=bag"
        echo "$list_mas" | while read -r line; do
            app_id=${line%% *}
            # Clean display line: remove ID, clean extra spaces
            display_line=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]{2,}/ /g')

            # Extract app name (remove version info in parentheses)
            app_name=$(echo "$display_line" | sed -E 's/[[:space:]]*\([^)]+\)$//')

            # Extract versions for history logging
            # Format usually: Name (OldVer -> NewVer)
            ver_info=$(echo "$display_line" | sed -E 's/.*\(//; s/\)$//')
            if [[ "$ver_info" == *"->"* ]]; then
                old_ver=${ver_info%% ->*}
                new_ver=${ver_info##*-> }
            else
                old_ver="?"
                new_ver="$ver_info"
            fi

            # App Store names routinely contain apostrophes, and every value
            # here ends up on a shell command line built by SwiftBar
            safe_id=$(swiftbar_sq_escape "$app_id")
            safe_app_name=$(swiftbar_sq_escape "$app_name")
            safe_old=$(swiftbar_sq_escape "$old_ver")
            safe_new=$(swiftbar_sq_escape "$new_ver")

            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            # Added param5 and param6 for version logging
            echo "-- Update $app_name | bash='$script_path' param1=update_app param2=mas param3='$safe_id' param4='$safe_app_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle"
            echo "-- Ignore $app_name | bash='$script_path' param1=ignore_app param2=mas param3='$safe_id' param4='$safe_app_name' terminal=false refresh=true sfimage=eye.slash"
        done
    fi

    # Manual updates: App Store ghosts plus self-updating (Sparkle) apps.
    # Neither can be installed from here, so both link out instead.
    if [[ $((count_manual + count_apps)) -gt 0 ]]; then
        echo "Manual Update Required ($((count_manual + count_apps))): | color=$COLOR_WARN size=12 sfimage=exclamationmark.triangle"
        echo "$manual_updates_list" | while IFS='|' read -r name ver_local ver_remote id; do
            if [[ -n "$name" ]]; then
			    # Link directs to App Store or web, as these are manual
                safe_name=$(swiftbar_sq_escape "$name")
                safe_id=$(swiftbar_sq_escape "$id")
                safe_old=$(swiftbar_sq_escape "$ver_local")
                safe_new=$(swiftbar_sq_escape "$ver_remote")
                echo "-- Update $name ($ver_local -> $ver_remote) | bash='$script_path' param1=update_app param2=mas param3='$safe_id' param4='$safe_name' param5='$safe_old' param6='$safe_new' terminal=false refresh=true sfimage=arrow.down.circle color=$COLOR_WARN"
            fi
        done

        # Self-updating apps: link out to the publisher, never install from here
        if [[ $count_apps -gt 0 ]]; then
            print -rn -- "$app_updates_list" | while IFS='|' read -r sp_method sp_name sp_local sp_remote sp_url sp_sig; do
                [[ -n "$sp_name" ]] || continue
                safe_name=$(swiftbar_sq_escape "$sp_name")
                safe_url=$(swiftbar_sq_escape "$sp_url")

                if [[ "$sp_method" == "github" ]]; then
                    sp_icon="chevron.left.forwardslash.chevron.right"
                    sp_action="Open release page"
                else
                    sp_icon="sparkles"
                    sp_action="Download $sp_remote"
                fi

                echo "-- $sp_name ($sp_local -> $sp_remote) | color=$COLOR_WARN size=12 font=Monaco sfimage=$sp_icon"
                if [[ -n "$sp_url" ]]; then
                    echo "---- $sp_action | href='$safe_url' sfimage=arrow.down.circle"
                fi

                # Automatic replacement is opt-in and only ever offered for a
                # direct DMG/ZIP download (see AUTO_INSTALL_APPS).
                if [[ "$AUTO_INSTALL_APPS" == "1" && ( "$sp_url" == *.dmg || "$sp_url" == *.zip ) ]]; then
                    echo "---- Install $sp_remote | bash='$script_path' param1=install_app param2='$safe_name' param3=live terminal=false refresh=false sfimage=square.and.arrow.down.on.square"
                    echo "---- Dry run (no changes) | bash='$script_path' param1=install_app param2='$safe_name' param3=dry terminal=false refresh=false sfimage=testtube.2"
                fi
                echo "---- Ignore $sp_name | bash='$script_path' param1=ignore_app param2=sparkle param3='$safe_name' param4='$safe_name' terminal=false refresh=true sfimage=eye.slash"
            done
        fi

        echo "---"
    fi

fi

# Statistics Submenu
echo "---"
echo "Monitored: $total_installed items | color=$COLOR_INFO size=12 sfimage=chart.bar.xaxis"

ignored_casks_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == cask\|* ]] && ignored_casks_list+=("${key#cask|}")
done
ignored_casks="${ignored_casks_list[*]}"

# Casks submenu with versions (Truncated to 20 chars)
echo "-- Apps (Brew Cask): $count_casks | color=$COLOR_INFO size=11 sfimage=square.stack.3d.up"
if [[ -n "$raw_casks" ]]; then
    # Pass ignored_casks generated from memory, not file
    echo "$raw_casks" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_casks" '
    # Every value below lands inside a single-quoted shell argument built by
    # SwiftBar. Turn each embedded quote into the '"'"' sequence.
    # ("\\" is one backslash in awk source; macOS awk passes it through gsub.)
    function sq(s) { gsub(q, q "\\" q q, s); return s }
    {
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
        action = is_ignored ? "Unignore" : "Ignore";
        param1 = is_ignored ? "unignore_app" : "ignore_app";
        safe_token = sq(token);

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/cask/" safe_token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=cask param3=" q safe_token q " param4=" q safe_token q " terminal=false refresh=true sfimage=eye";
    }'
fi

pinned_formulae_list="${pinned_arr[*]}"

# Brew Formulae
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=$COLOR_INFO size=11 sfimage=terminal"
if [[ -n "$raw_formulae" ]]; then
    echo "$raw_formulae" | awk -v q="'" -v sp="$script_path" -v ign="$pinned_formulae_list" '
    function sq(s) { gsub(q, q "\\" q q, s); return s }
    {
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";

        action = is_ignored ? "Unignore" : "Ignore";

        param1 = is_ignored ? "unignore_app" : "ignore_app";
        safe_token = sq(token);

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/formula/" safe_token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=brew param3=" q safe_token q " param4=" q safe_token q " terminal=false refresh=true sfimage=eye";
    }'
fi

ignored_mas_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == mas\|* ]] && ignored_mas_list+=("${key#mas|}")
done
ignored_mas="${ignored_mas_list[*]}"

# App Store
if [[ "$MAS_ENABLED" == "1" ]]; then
	echo "-- App Store: $count_mas_installed | color=$COLOR_INFO size=11 sfimage=bag"
	if [[ -n "$installed_mas" ]]; then
	    echo "$installed_mas" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_mas" '
	    function sq(s) { gsub(q, q "\\" q q, s); return s }
	    {
	        id=$1;
	        $1="";
	        name=$0;
	        gsub(/^[ \t]+|[ \t]+$/, "", name);

	        is_ignored = (index(" " ign " ", " " id " ") > 0);
	        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
	        action = is_ignored ? "Unignore" : "Ignore";
	        param1 = is_ignored ? "unignore_app" : "ignore_app";
	        safe_id = sq(id);
	        safe_name = sq(name);

	        print "---- " name " | href=" q "https://apps.apple.com/app/id" safe_id q " size=11 font=Monaco trim=true" color_str;
	        print "------ " action " | bash=" q sp q " param1=" param1 " param2=mas param3=" q safe_id q " param4=" q safe_name q " terminal=false refresh=true sfimage=eye";
	    }'
	fi
else
    echo "-- App Store: Disabled | color=#808080 size=11"
fi
echo "History: | color=$COLOR_INFO size=12 sfimage=clock.arrow.circlepath"

# Render the menus
echo "-- Past 7 days: $count_7d updates | color=$COLOR_INFO size=11 sfimage=calendar"
echo -n "$history_7d"
echo "-- Past 30 days: $count_30d updates | color=$COLOR_INFO size=11 sfimage=calendar.badge.clock"
echo -n "$history_30d"

# Footer & Controls
echo "---"
if [[ $total -gt 0 || $update_available -eq 1 ]]; then
    echo "Update Everything | bash='$script_path' param1=launch_update param2=all terminal=false refresh=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=$COLOR_INFO sfimage=checkmark.circle"
fi

# Forces a full cache rebuild, then refreshes the menu when it completes
echo "Refresh now | bash='$script_path' param1=refresh_cache param2=force terminal=false refresh=true sfimage=arrow.clockwise"

echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"

# Autostart Logic check (Configuration based for performance)
if [[ "${AUTOSTART:-0}" == "1" ]]; then
    as_label="Disable Autostart"
    as_icon="autostartstop.slash"
else
    as_label="Enable Autostart"
    as_icon="autostartstop"
fi
echo "-- $as_label | bash='$script_path' param1=toggle_autostart terminal=false refresh=true sfimage=$as_icon"

echo "-- Change Terminal App | bash='$script_path' param1=change_terminal terminal=false refresh=false sfimage=terminal"
echo "-- Edit Tracked Apps | bash='open' param1='-t' param2='$(swiftbar_sq_escape "$TRACKED_APPS_FILE")' terminal=false refresh=false sfimage=list.bullet.rectangle"

# App Store Toggle Logic
if [[ "$MAS_ENABLED" == "1" ]]; then
    MAS_ICON="bag.fill"
    MAS_LABEL="Disable App Store Updates"
else
    MAS_ICON="bag"
    MAS_LABEL="Enable App Store Updates"
fi
echo "-- $MAS_LABEL | bash='$script_path' param1=toggle_mas terminal=false refresh=true sfimage=$MAS_ICON"

# Homebrew cleanup toggle
if [[ "$CLEANUP_ENABLED" == "1" ]]; then
    CLEANUP_ICON="trash.fill"
    CLEANUP_LABEL="Disable Cleanup After Update"
else
    CLEANUP_ICON="trash.slash"
    CLEANUP_LABEL="Enable Cleanup After Update"
fi
echo "-- $CLEANUP_LABEL | bash='$script_path' param1=toggle_cleanup terminal=false refresh=true sfimage=$CLEANUP_ICON"

# Automatic replacement of self-updating apps (off by default)
if [[ "$AUTO_INSTALL_APPS" == "1" ]]; then
    AUTOINST_ICON="square.and.arrow.down.on.square.fill"
    AUTOINST_LABEL="Disable App Installation"
else
    AUTOINST_ICON="square.and.arrow.down.on.square"
    AUTOINST_LABEL="Enable App Installation"
fi
echo "-- $AUTOINST_LABEL | bash='$script_path' param1=toggle_auto_install terminal=false refresh=true sfimage=$AUTOINST_ICON"

# Pinned items come from the cache (see section 6)
pinned_list="${(F)pinned_arr}"
has_ignored=false
[[ -n "$pinned_list" ]] && has_ignored=true
# Check memory map instead of file size
[[ ${#IGNORED_APPS_MAP} -gt 0 ]] && has_ignored=true

if [[ "$has_ignored" == "true" ]]; then
    # Parent menu item (Active)
    echo "-- Manage Ignored Apps | sfimage=eye.slash"

    # List Pinned Brew Formulae
    if [[ -n "$pinned_list" ]]; then
        echo "---- Formulae (Pinned) | color=$COLOR_INFO size=11"
        echo "$pinned_list" | while read -r pin_name; do
             echo "----   $pin_name | size=11 font=Monaco"
             echo "------   Unignore | bash='$script_path' param1=unignore_app param2=brew param3='$pin_name' param4='$pin_name' terminal=false refresh=true sfimage=eye"
        done
    fi

    # OPTIMIZED: Generate Cask and Mas lists from memory map
    typeset -a sorted_keys
    sorted_keys=("${(@k)IGNORED_APPS_MAP}")
    sorted_keys=("${(@o)sorted_keys}")

    local menu_casks=""
    local menu_mas=""

    for key in "${sorted_keys[@]}"; do

        local ig_type="${key%%|*}"
        local ig_id="${key#*|}"

        # Get name stored in map value
        local display_name="${IGNORED_APPS_MAP[$key]}"
        # Fallback for safety
        [[ -z "$display_name" ]] && display_name="$ig_id"

        # Single line definition to prevent indentation bugs
        safe_name=$(swiftbar_sq_escape "$display_name")
        safe_id=$(swiftbar_sq_escape "$ig_id")
        local item="----   $display_name | size=11 font=Monaco"$'\n'"------   Unignore | bash='$script_path' param1=unignore_app param2=$ig_type param3='$safe_id' param4='$safe_name' terminal=false refresh=true sfimage=eye"

        if [[ "$ig_type" == "cask" ]]; then
            menu_casks+="$item"$'\n'
        elif [[ "$ig_type" == "mas" ]]; then
            menu_mas+="$item"$'\n'
        fi
    done

    # Use echo -n strictly because $item already contains newlines
    if [[ -n "$menu_casks" ]]; then
        echo "---- Casks (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_casks"
    fi

    if [[ -n "$menu_mas" ]]; then
        echo "---- App Store (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_mas"
    fi

else
    # Parent menu item (Disabled/Grayed out)
    echo "-- Manage Ignored Apps (Empty) | color=#808080 sfimage=eye.slash"
fi
# Branch selection menu item
CURRENT_CHANNEL="Stable"
BRANCH_ICON="network"

if [[ "$UPDATE_BRANCH" == "develop" ]]; then
    CURRENT_CHANNEL="Beta/Dev"
    BRANCH_ICON="hammer.fill"
fi

echo "-- Change Channel (Current: $CURRENT_CHANNEL) | bash='$script_path' param1=change_branch terminal=false refresh=true sfimage=$BRANCH_ICON"

echo "-----"
echo "-- Check for Plugin Update | bash='$script_path' param1=check_updates terminal=false refresh=true sfimage=sparkles"
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"
echo "---"
echo "Quit | bash='osascript' param1=-e param2='quit app \"SwiftBar\"' terminal=false sfimage=power"
}
