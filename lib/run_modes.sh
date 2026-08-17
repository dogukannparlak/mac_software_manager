# ------------------------------------------------------------------------------
# RUN MODES
# ------------------------------------------------------------------------------
# What `update_system.1h.sh run <mode>` actually does, one function per mode.
# The dispatcher in the main script (section 5) owns the shared setup - lock
# acquisition, progress_write "starting", the EXIT trap - and calls exactly
# one of these via a `case`. Each function was, until this file existed, the
# body of an `if [[ "$MODE" == "..." ]]` inside one 538-line block; splitting
# it up did not change what any of them do.
#
# IMPORTANT: run_mode_install and run_mode_single read the script's own
# positional parameters directly ($3, $4, ...) - the dispatcher MUST call them
# as `run_mode_install "$@"` / `run_mode_single "$@"`, never bare. A zsh
# function gets its own $1 $2 $3... from how it was invoked; it does not
# inherit the caller's. Calling either bare would leave $3 (target_app / type)
# silently empty. run_mode_plugin and run_mode_system read no positional
# parameters (only $MODE, already captured in a variable) and are always
# called bare.

# --- SELF-UPDATING APP INSTALL (Sparkle / GitHub) ---
run_mode_install() {
    target_app="$3"
    run_kind="${4:-live}"
    DRY_RUN=0
    [[ "$run_kind" == "dry" || "$run_kind" == "--dry-run" ]] && DRY_RUN=1

    if [[ -z "$target_app" ]]; then
        echo "❌ No application specified."
        sleep 3
        exit 1
    fi

    if (( DRY_RUN )); then
        echo "🧪 DRY RUN - every step runs except the replacement itself."
    fi
    progress_write "running" "install-app" "$target_app" "" ""
    echo "🚀 Preparing update for $target_app..."
    echo "---------------------------"

    # Look the entry up in the cache instead of trusting menu parameters
    entry=""
    for cache_line in ${(f)"$(cache_get "app_updates")"}; do
        [[ -n "$cache_line" ]] || continue
        [[ "${${(@s:|:)cache_line}[2]}" == "$target_app" ]] || continue
        entry="$cache_line"
        break
    done

    if [[ -z "$entry" ]]; then
        echo "❌ No pending update recorded for $target_app."
        echo "   Refresh the menu and try again."
        sleep 4
        exit 1
    fi

    entry_fields=("${(@s:|:)entry}")
    app_method="${entry_fields[1]}"
    app_local="${entry_fields[3]}"
    app_remote="${entry_fields[4]}"
    app_url="${entry_fields[5]}"
    app_sig="${entry_fields[6]}"
    installed_path="/Applications/${target_app}.app"

    echo "   Method:  $app_method"
    echo "   Version: $app_local -> $app_remote"

    if [[ ! -d "$installed_path" ]]; then
        echo "❌ $installed_path does not exist."
        sleep 4
        exit 1
    fi

    # Setapp keeps its own copies in sync; replacing them breaks Setapp
    if [[ "$installed_path" == /Applications/Setapp/* ]]; then
        echo "❌ Setapp manages this application. Use Setapp to update it."
        sleep 4
        exit 1
    fi

    if [[ "$app_method" == "github" || "$app_url" != *.dmg && "$app_url" != *.zip ]]; then
        echo "ℹ️ No direct DMG or ZIP download is available for this app."
        [[ "$app_url" == *.pkg ]] && echo "   .pkg installers are not installed automatically: they run"
        [[ "$app_url" == *.pkg ]] && echo "   scripts as root and cannot be rolled back."
        echo "   Opening the download page instead."
        [[ -n "$app_url" ]] && open "$app_url"
        sleep 4
        exit 0
    fi

    workdir="$(mktemp -d "${TMPDIR:-/tmp}/msu_install.XXXXXX")" || exit 1
    trap 'rm -rf "$workdir"; progress_finalize' EXIT

    archive_name="${app_url:t}"
    archive_path="$workdir/${archive_name}"

    echo "⬇️ Downloading $archive_name..."
    if ! curl -fL --progress-bar --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 600 \
        -H "User-Agent: $USER_AGENT" "$app_url" -o "$archive_path"; then
        echo "❌ Download failed."
        sleep 4
        exit 1
    fi

    echo "📦 Extracting..."
    if ! new_app=$(extract_app_from_archive "$archive_path" "$workdir"); then
        echo "❌ Could not find exactly one application bundle in the archive."
        sleep 4
        exit 1
    fi
    echo "   Found: ${new_app:t}"

    if ! verify_app_replacement "$installed_path" "$new_app" "$app_remote" "$archive_path" "$app_sig"; then
        echo ""
        progress_write "failed" "install-app" "$target_app" "" ""
        echo "🛑 Verification failed. Nothing was changed."
        echo "   $target_app is still at version $app_local."
        sleep 6
        exit 1
    fi

    if (( DRY_RUN )); then
        echo ""
        echo "🧪 DRY RUN complete. All checks passed; no files were modified."
        echo "   Would have replaced: $installed_path"
        sleep 5
        exit 0
    fi

    was_running=0
    app_running "$installed_path" && was_running=1
    quit_running_app "$installed_path"

    echo "🔄 Replacing $target_app..."
    if ! replace_app_bundle "$installed_path" "$new_app"; then
        echo "🛑 Update failed. The previous version has been restored."
        (( was_running )) && open -a "$target_app" 2>/dev/null || true
        sleep 6
        exit 1
    fi

    # Record the outcome the same way Homebrew and App Store updates are
    timestamp=$(date +%s)
    echo "$timestamp|$app_method|$target_app|$app_local|$app_remote|$target_app|ok" >> "$HISTORY_FILE"
    trim_history_log

    progress_write "done" "install-app" "$target_app" "" ""
    echo "✅ $target_app updated to $app_remote."

    if (( was_running )); then
        echo "   Restarting $target_app..."
        sleep 1
        open -a "$target_app" 2>/dev/null || echo "   Could not restart automatically."
    fi

    echo "🗂️ Refreshing cached data..."
    collect_cache_data "apps"

    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    sleep 2
    exit 0
}

# --- SINGLE APP UPDATE ---
run_mode_single() {
    type="$3"  # brew, cask, or mas
    id="$4"    # package name or app ID
    name="${5:-$id}"  # display name (fallback to id)
    old_ver="${6:-?}"
    new_ver="${7:-?}"

    progress_write "running" "single" "$name" "" ""
    echo "🚀 Updating $name ($old_ver -> $new_ver)..."
    echo "---------------------------"

    update_rc=0
    case "$type" in
        "brew"|"cask")
        brew upgrade "$id" || update_rc=$?
        # Exit code alone is not proof: verify the package left the outdated list
        if (( update_rc == 0 )) && brew_is_outdated "$id"; then
            echo "⚠️ $id is still reported as outdated after the upgrade."
            update_rc=1
        fi
        ;;
    "mas")
        # Use upgrade instead of install to force update for existing apps
        if [[ "$MAS_ENABLED" == "1" ]]; then
            if mas list | awk '{print $1}' | grep -q "^${id}$"; then
                mas upgrade "$id" || update_rc=$?
            else
                mas install "$id" || update_rc=$?
            fi
            if (( update_rc == 0 )) && mas_is_outdated "$id"; then
                echo "⚠️ $name is still reported as outdated after the upgrade."
                update_rc=1
            fi
        else
            echo "❌ Error: App Store updates are disabled."
            exit 1
        fi
        ;;
    esac

    # Log the real outcome to history
    timestamp=$(date +%s)
    status="ok"
    (( update_rc == 0 )) || status="fail"

    # Format: timestamp|source|name|old_ver|new_ver|id|status
    if echo "$timestamp|$type|$name|$old_ver|$new_ver|$id|$status" >> "$HISTORY_FILE"; then
        trim_history_log
        echo "📝 Added to history log ($status)."
    fi

    progress_write "$( (( update_rc == 0 )) && print done || print failed )" "single" "$name" "" ""

    # Menu data is cached, so it must be rebuilt before the refresh below
    collect_cache_data "all"

    echo "---------------------------"
    if (( update_rc == 0 )); then
        echo "✅ Update Complete!"
    else
        echo "❌ Update FAILED for $name (exit $update_rc). Logged as failed."
    fi
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    echo "Done!"
    sleep 1
    exit 0
}

# --- PLUGIN UPDATE SECTION ---
# Replaces the running engine: the main script plus every file in LIB_NAMES.
# These have to move together or not at all - a new main script paired with a
# stale lib file (or vice versa) can silently break the moment a function
# signature changes between versions. So every file is downloaded and
# verified into a temp location FIRST; only once every single one has passed
# does anything get moved into place. setup_mac.sh/uninstall.sh are handled
# separately and best-effort, since a stale copy of either does not affect
# the engine that is actually running right now.
run_mode_plugin() {
    if [[ -f "$PENDING_FLAG" ]]; then
        echo "🚀 Updating toolkit components..."

        for component in "setup_mac.sh" "uninstall.sh"; do
            COMPONENT_TMP="$(mktemp "${TMPDIR:-/tmp}/${component}.XXXXXX")"
            if download_verified "$component" "$COMPONENT_TMP"; then
                mv "$COMPONENT_TMP" "$APP_DIR/$component" && chmod +x "$APP_DIR/$component"
            else
                echo "⚠️ Skipping $component: keeping the currently installed copy."
                rm -f "$COMPONENT_TMP"
            fi
        done

        typeset -a engine_files
        engine_files=("update_system.1h.sh")
        for lib_name in "${LIB_NAMES[@]}"; do
            engine_files+=("lib/${lib_name}.sh")
        done

        typeset -A engine_temp
        engine_ok=1
        for f in "${engine_files[@]}"; do
            engine_temp[$f]="$(mktemp "${TMPDIR:-/tmp}/${f:t}.XXXXXX")"
            want_header=""
            [[ "$f" == "update_system.1h.sh" ]] && want_header="bitbar.title"
            download_verified "$f" "${engine_temp[$f]}" "$want_header" || engine_ok=0
        done

        trap '
            for f in "${engine_files[@]}"; do rm -f "${engine_temp[$f]}"; done
            progress_finalize
        ' EXIT

        if (( engine_ok )); then
            mkdir -p "$APP_DIR/lib"
            for f in "${engine_files[@]}"; do
                if [[ "$f" == "update_system.1h.sh" ]]; then
                    mv "${engine_temp[$f]}" "$SCRIPT_FILE" && chmod +x "$SCRIPT_FILE"
                else
                    mv "${engine_temp[$f]}" "$APP_DIR/$f" && chmod +x "$APP_DIR/$f"
                fi
            done
            rm -f "$PENDING_FLAG"
            echo "✅ Toolkit updated successfully."

            # If only updating plugin, refresh and exit
            if [[ "$MODE" == "plugin" ]]; then
                echo "🔄 Refreshing SwiftBar..."
                open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
                echo "Done!"
                sleep 1
                exit 0
            else
                echo "➡️ Proceeding with system apps..."
            fi
        else
            for f in "${engine_files[@]}"; do rm -f "${engine_temp[$f]}"; done
            echo "❌ Plugin update aborted: not every engine file passed verification. The running version was left untouched."
            if [[ "$MODE" == "plugin" ]]; then
                osascript -e "display notification \"Plugin update failed integrity check.\" with title \"Mac Software Manager\"" 2>/dev/null || true
                sleep 2
                exit 1
            fi
            echo "➡️ Proceeding with system apps..."
        fi
    elif [[ "$MODE" == "plugin" ]]; then
        echo "ℹ️ No pending plugin updates found."
        sleep 1
        exit 0
    fi
}

# --- SYSTEM UPDATE SECTION ---
run_mode_system() {
	echo "🚀 Starting System Update (Homebrew & MAS)..."
	echo "---------------------------"

	progress_write "running" "brew-update" "" "" ""
	echo "📦 Updating Homebrew Database..."
	if ! brew_update_with_retry; then
		echo "❌ Error: Homebrew update failed after multiple retries."
		osascript -e 'display notification "Homebrew failed to refresh after several retries - the update did not run." with title "Mac Software Manager" subtitle "Update Failed"' 2>/dev/null || true
		exit 1
	fi

	# Analyze pending updates to create a snapshot before upgrading
	progress_write "running" "analyze" "" "" ""
	echo "🔍 Analyzing pending updates..."
	typeset -a update_log_buffer
	integer count_brew_pending=0
    integer count_mas_pending=0
	timestamp=$(date +%s)

	# Structured 'brew outdated --json=v2' data: src|token|old|new|pinned
    typeset -a brew_targets
    typeset -a outdated_fields
	for line in "${(@f)$(brew_outdated_normalized)}"; do
		[[ -n "$line" ]] || continue
		outdated_fields=("${(@s:|:)line}")
		(( ${#outdated_fields[@]} >= 5 )) || continue

		src="${outdated_fields[1]}"
		name="${outdated_fields[2]}"
		old_ver="${outdated_fields[3]}"
		new_ver="${outdated_fields[4]}"

		# Pinned formulae must never be upgraded
		if [[ "${outdated_fields[5]}" == "1" ]]; then
			echo "📌 Skipping pinned formula: $name"
			continue
		fi

		# Check if ignored (skip adding to updates)
		if [[ "$src" == "cask" ]] && is_ignored "cask" "$name"; then
			 echo "🚫 Skipping ignored cask: $name"
			 continue
		fi

		brew_targets+=("$name")
		# 6th field mirrors the token so the post-upgrade check can key on it
		update_log_buffer+=("$timestamp|$src|$name|$old_ver|$new_ver|$name")
		((++count_brew_pending))
	done

	# Parse 'mas outdated' output
	if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
		# Redirect stderr to /dev/null to suppress warnings completely
		raw_mas_outdated=$(run_with_timeout "$MAS_TIMEOUT" mas outdated 2>/dev/null || true)
		for line in "${(@f)raw_mas_outdated}"; do
			# Ignore non-application lines. Valid lines MUST start with a number (App ID)
			[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
			[[ -z "$line" ]] && continue

			# Extract ID (First word) - safe string manipulation
			app_id=${line%% *}

			# Skip ignored apps before adding to log buffer
			if is_ignored "mas" "$app_id"; then
				continue
			fi

			# Extract Version Info (Content inside the LAST parentheses)
			# Uses printf for safety against special chars, greedily removes up to last open paren
			ver_info=$(printf '%s\n' "$line" | sed -E 's/.*\(//; s/\)$//')

			# Clean Name using shared function
			app_name=$(clean_mas_name "$line")
			# History records are pipe-delimited: a name may not contain one
			app_name="${app_name//|/}"

			# Split Versions (Old -> New)
			if [[ "$ver_info" == *"->"* ]]; then
				old_ver=${ver_info%% ->*}
				new_ver=${ver_info##*-> }
			else
				old_ver="?"
				new_ver="$ver_info"
			fi

			# Add to buffer
			update_log_buffer+=("$timestamp|mas|$app_name|$old_ver|$new_ver|$app_id")
			((++count_mas_pending))
		done
	fi

	# Execute updates
	echo "🍺 Upgrading Homebrew Formulae and Casks ($count_brew_pending pending)..."

    # Capture brew upgrade output to detect renamed casks
    brew_upgrade_rc=0
    if [[ ${#brew_targets[@]} -gt 0 ]]; then
        # 'exit ${pipestatus[1]}' propagates brew's status instead of tee's,
        # and '|| brew_upgrade_rc=$?' keeps 'set -e' from killing the run.
        progress_write "running" "brew-upgrade" "" "0" "${#brew_targets[@]}"
        upgrade_output=$(brew upgrade --greedy "${brew_targets[@]}" 2>&1 | progress_tap "brew-upgrade" "${#brew_targets[@]}"; exit ${pipestatus[1]}) || brew_upgrade_rc=$?
        if (( brew_upgrade_rc != 0 )); then
            echo "⚠️ 'brew upgrade' exited with status $brew_upgrade_rc. Verifying package by package..."
        fi
    else
        echo "✨ No Homebrew updates to install (ignored apps skipped)."
        upgrade_output=""
    fi

    # Check for renamed cask pattern and auto-migrate
    if echo "$upgrade_output" | grep -q "was renamed to"; then
        echo "🔄 Detected renamed cask(s), attempting auto-migration..."
        echo "$upgrade_output" | grep "was renamed to" | while read -r line; do
            old_cask=$(echo "$line" | sed -E "s/.*Cask ([^ ]+) was renamed to.*/\1/")
            new_cask=$(echo "$line" | sed -E "s/.*was renamed to ([^.]+).*/\1/")
            if [[ -n "$old_cask" && -n "$new_cask" ]]; then
                echo "  Migrating: $old_cask → $new_cask"
                brew uninstall --cask "$old_cask" 2>/dev/null || true
                brew install --cask "$new_cask" 2>/dev/null || true
            fi
        done
        # Re-run upgrade to catch anything else
        echo "📦 Re-running upgrade after migration..."
        if [[ ${#brew_targets[@]} -gt 0 ]]; then
             brew upgrade --greedy "${brew_targets[@]}" || true
        fi
    fi

	if [[ "$CLEANUP_ENABLED" == "1" ]]; then
		progress_write "running" "cleanup" "" "" ""
		echo "🧹 Cleaning up..."
		brew cleanup --prune=all || true
	else
		echo "⏭️ Skipping cleanup (disabled in preferences)."
	fi

	if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
		progress_write "running" "mas-upgrade" "" "" "$count_mas_pending"
		echo "🍎 Updating App Store Applications ($count_mas_pending pending)..."

		# Check if we have any ignored MAS apps
		has_ignored_mas=false
		if [[ -f "$IGNORED_FILE" ]] && grep -q "^mas|" "$IGNORED_FILE" 2>/dev/null; then
			has_ignored_mas=true
		fi

		if [[ "$has_ignored_mas" == "true" ]]; then
			# Update each non-ignored app individually to respect ignore list
			echo "   (Updating apps individually to respect ignore list)"
			run_with_timeout "$MAS_TIMEOUT" mas outdated 2>/dev/null | while read -r line; do
				[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
				app_id=${line%% *}
				# Skip if this app is in our ignore list
				if grep -qE "^mas\|${app_id}(\||$)" "$IGNORED_FILE" 2>/dev/null; then
					continue
				fi
				progress_write "running" "mas-upgrade" "$(clean_mas_name "$line")" "" "$count_mas_pending"
				run_with_timeout "$MAS_TIMEOUT" mas upgrade "$app_id" || true
			done || true
		else
			# No ignored apps, use faster bulk upgrade
			run_with_timeout "$MAS_TIMEOUT" mas upgrade || true
		fi
	fi

	# Verify the outcome before writing history.
	# Anything still on the outdated list did NOT update, whatever brew/mas returned.
	integer count_failed=0
	if [[ ${#update_log_buffer[@]} -gt 0 ]]; then
		progress_write "running" "verify" "" "" ""
		echo "🔎 Verifying results..."

		# NOTE: the map key must be built in a variable first. An unquoted
		# '|' inside an assignment subscript is parsed as a pipe by zsh.
		typeset -A still_outdated
		typeset map_key=""
		for tok in "${(@f)$(brew_outdated_tokens)}"; do
			[[ -n "$tok" ]] || continue
			map_key="brew|$tok"
			still_outdated[$map_key]=1
		done
		if [[ "$MAS_ENABLED" == "1" ]]; then
			for verify_id in "${(@f)$(mas_outdated_ids)}"; do
				[[ -n "$verify_id" ]] || continue
				map_key="mas|$verify_id"
				still_outdated[$map_key]=1
			done
		fi

		typeset -a verified_log
		typeset -a entry_fields
		for entry in "${update_log_buffer[@]}"; do
			entry_fields=("${(@s:|:)entry}")
			entry_src="${entry_fields[2]}"
			entry_name="${entry_fields[3]}"
			entry_id="${entry_fields[6]}"
			entry_status="ok"

			case "$entry_src" in
				"brew"|"cask") map_key="brew|$entry_id" ;;
				"mas")         map_key="mas|$entry_id" ;;
				*)             map_key="" ;;
			esac
			[[ -n "$map_key" && -n "${still_outdated[$map_key]}" ]] && entry_status="fail"

			if [[ "$entry_status" == "fail" ]]; then
				((++count_failed))
				echo "   ❌ $entry_name is still outdated - recording as failed."
			fi

			# Format: timestamp|source|name|old_ver|new_ver|id|status
			verified_log+=("$entry|$entry_status")
		done

		mkdir -p "$(dirname "$HISTORY_FILE")"

        # Use 'printf' instead of 'print' to avoid "bad output format" errors
		if printf "%s\n" "${verified_log[@]}" >> "$HISTORY_FILE"; then
		    echo "📝 Logged ${#verified_log[@]} updates ($((${#verified_log[@]} - count_failed)) ok, $count_failed failed)."
			trim_history_log
        else
            echo "❌ Failed to write to history file."
        fi
    fi

    # Menu data is cached: rebuild it so the refresh below shows the new state
    echo "🗂️ Refreshing cached data..."
    collect_cache_data "all"

    progress_write "done" "complete" "" "" ""

    echo "---------------------------"
    integer count_updated=$(( count_brew_pending + count_mas_pending - count_failed ))
    if (( count_failed > 0 )); then
        echo "⚠️ Update finished with $count_failed failed item(s). See history for details."
        osascript -e "display notification \"$count_failed item(s) failed to update. See History in the menu for details.\" with title \"Mac Software Manager\" subtitle \"Update Finished With Errors\"" 2>/dev/null || true
    elif (( count_updated > 0 )); then
        echo "✅ Update Complete!"
        osascript -e "display notification \"$count_updated package(s) updated successfully.\" with title \"Mac Software Manager\" subtitle \"Update Complete\"" 2>/dev/null || true
    else
        echo "✅ Update Complete!"
        osascript -e 'display notification "Everything was already up to date." with title "Mac Software Manager" subtitle "Update Complete"' 2>/dev/null || true
    fi
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    echo "Done!"
    sleep 1
    exit 0
}
