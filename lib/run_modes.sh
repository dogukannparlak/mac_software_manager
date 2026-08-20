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
    # Cleanup only - progress_finalize deliberately is NOT called here. In zsh
    # an EXIT trap set inside a function is local to that function, and on
    # `exit N` from within the function it runs with $? == 0, not N: finalizing
    # here would stamp "done" on every early `exit 1` below. The dispatcher's
    # trap (update_system.1h.sh, `run` section) is restored the moment this one
    # has run and does see the real status, so it owns the finalize.
    trap 'rm -rf "$workdir"' EXIT

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

    echo "✅ $target_app updated to $app_remote."

    if (( was_running )); then
        echo "   Restarting $target_app..."
        sleep 1
        open -a "$target_app" 2>/dev/null || echo "   Could not restart automatically."
    fi

    echo "🗂️ Refreshing cached data..."
    collect_cache_data "apps"

    # Written after the cache refresh above, not before it: a reader that
    # treats "done" as "safe to re-check the pending-updates list now"
    # (GuideApp does, to show a per-row Updated/Failed result) must never
    # read that list while collect_cache_data is still mid-write - it would
    # still show this app as pending and misreport a real success as failed.
    progress_write "done" "install-app" "$target_app" "" ""

    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    sleep 2
    exit 0
}

# --- SINGLE APP UPDATE ---
# Everything that explains a failure goes to stderr, everything else to
# stdout. That split is what GuideApp reads: a headless single-item run has
# its stdout nulled and its stderr kept (ToolkitController.startProcess), and
# that stderr is the only thing the failed row has to show for a reason. On
# stdout these lines were written and thrown away, so a row that said
# "Güncelleme başarısız" could not say why. Terminal mode is unaffected - the
# window shows both streams either way.
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
            echo "⚠️ $id is still reported as outdated after the upgrade." >&2
            update_rc=1
        fi
        ;;
    "mas")
        if [[ "$MAS_ENABLED" != "1" ]]; then
            echo "❌ Error: App Store updates are disabled." >&2
            exit 1
        fi
        # Every other mas call site in this project guards on this; without
        # it, a machine with MAS_ENABLED=1 but no mas installed dies here on
        # exit 127 with nothing said about why.
        if ! command -v mas &> /dev/null; then
            echo "❌ Error: 'mas' is not installed, so App Store apps cannot be updated." >&2
            echo "   Install it with: brew install mas" >&2
            exit 1
        fi
        # Use upgrade instead of install to force update for existing apps.
        # mas_is_installed reads the whole list and matches in the shell: the
        # old 'mas list | awk | grep -q' pipeline let grep exit at the first
        # match, killing mas and awk with SIGPIPE, and 'run' runs under
        # 'set -o pipefail' - so a FOUND app produced status 141, the
        # condition read false, and 'mas install' ran on an app that was
        # already installed.
        # Both branches download the app itself, so both get the upgrade
        # limit - a hang guard, never a pace limit (MAS_UPGRADE_TIMEOUT,
        # lib/utils.sh). This is the path GuideApp's headless single-item
        # runs take, and an unguarded 'mas' here is what left one of them
        # running with no end in sight.
        if mas_is_installed "$id"; then
            run_with_timeout "$MAS_UPGRADE_TIMEOUT" mas upgrade "$id" || update_rc=$?
        else
            run_with_timeout "$MAS_UPGRADE_TIMEOUT" mas install "$id" || update_rc=$?
        fi
        # Said out loud, the way the bulk path says it: without this the run
        # just lands in the history as a plain failure, with nothing to
        # separate "we ran out of patience" from "the App Store said no".
        if (( update_rc == TIMEOUT_EXIT_STATUS )); then
            echo "⏱️ Timed out after ${MAS_UPGRADE_TIMEOUT}s: updating $name was killed mid-download." >&2
        fi
        if (( update_rc == 0 )) && mas_is_outdated "$id"; then
            echo "⚠️ $name is still reported as outdated after the upgrade." >&2
            update_rc=1
        fi
        ;;
    esac

    # Log the real outcome to history.
    # NOT named 'status': that is a read-only special parameter in zsh (a
    # synonym for $?), and assigning to it is a fatal error that killed this
    # function right here - before the history entry, the cache rebuild and
    # the final progress line below ever ran.
    timestamp=$(date +%s)
    entry_status="ok"
    (( update_rc == 0 )) || entry_status="fail"

    # Format: timestamp|source|name|old_ver|new_ver|id|status
    if echo "$timestamp|$type|$name|$old_ver|$new_ver|$id|$entry_status" >> "$HISTORY_FILE"; then
        trim_history_log
        echo "📝 Added to history log ($entry_status)."
    fi

    # Menu data is cached, so it must be rebuilt before the refresh below -
    # and before the "done"/"failed" progress line below it, so a reader
    # that treats "done" as "safe to re-check the outdated list now"
    # (GuideApp does, to show a per-row Updated/Failed result) never reads a
    # still-stale cache and reports a real success as a failure.
    #
    # Scoped to this item's own entries, not the whole cache: everything
    # between the upgrade finishing and the "done" line below is time the row
    # spends on "Güncelleniyor" with the work already done, and a full
    # collect_cache_data spent most of it re-fetching things one package
    # cannot have changed - homepages included. See collect_cache_for_item
    # (lib/cache.sh) for what it does refresh, and why it holds the "cache"
    # lock while it writes.
    collect_cache_for_item "$type" "$id"

    progress_write "$( (( update_rc == 0 )) && print done || print failed )" "single" "$name" "" ""

    echo "---------------------------"
    if (( update_rc == 0 )); then
        echo "✅ Update Complete!"
    else
        echo "❌ Update FAILED for $name (exit $update_rc). Logged as failed." >&2
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

        # Cleanup only, for the same reason as run_mode_install above: this
        # trap is function-local, so it cannot see the status an `exit 1`
        # below is exiting with. The dispatcher's trap finalizes.
        trap '
            for f in "${engine_files[@]}"; do rm -f "${engine_temp[$f]}"; done
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
                notify "Plugin update failed integrity check."
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
		notify "Homebrew failed to refresh after several retries - the update did not run." "Update Failed"
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
		raw_mas_outdated=$(run_with_timeout "$MAS_QUERY_TIMEOUT" mas outdated 2>/dev/null || true)
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
                if ! uninstall_err=$(brew uninstall --cask "$old_cask" 2>&1); then
                    echo "⚠️ Could not uninstall $old_cask before migrating: $uninstall_err"
                fi
                if ! install_err=$(brew install --cask "$new_cask" 2>&1); then
                    echo "❌ Migration failed: $old_cask → $new_cask. Will retry on next run."
                    echo "   $install_err"
                fi
            fi
        done
        # Re-run upgrade to catch anything else. Same '2>&1 | progress_tap'
        # capture as the first attempt above - without it, Homebrew's own
        # stderr (its "==>" status lines) leaks straight into this process's
        # real stderr, and if anything later in the run fails, that leaked
        # noise - not the actual error - is what Swift shows in the failure
        # banner.
        echo "📦 Re-running upgrade after migration..."
        if [[ ${#brew_targets[@]} -gt 0 ]]; then
             brew upgrade --greedy "${brew_targets[@]}" 2>&1 | progress_tap "brew-upgrade" "${#brew_targets[@]}" || true
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
			run_with_timeout "$MAS_QUERY_TIMEOUT" mas outdated 2>/dev/null | while read -r line; do
				[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
				app_id=${line%% *}
				# Skip if this app is in our ignore list
				if grep -qE "^mas\|${app_id}(\||$)" "$IGNORED_FILE" 2>/dev/null; then
					continue
				fi
				progress_write "running" "mas-upgrade" "$(clean_mas_name "$line")" "" "$count_mas_pending"
				# A bare '|| true' here would hide both real errors and the
				# timeout; the verification step below decides pass/fail, so
				# the run still continues - it just says what went wrong.
				integer mas_rc=0
				run_with_timeout "$MAS_UPGRADE_TIMEOUT" mas upgrade "$app_id" || mas_rc=$?
				if (( mas_rc == TIMEOUT_EXIT_STATUS )); then
					echo "⏱️ Timed out after ${MAS_UPGRADE_TIMEOUT}s: 'mas upgrade $app_id' was killed mid-download."
				elif (( mas_rc != 0 )); then
					echo "⚠️ 'mas upgrade $app_id' failed (exit $mas_rc)."
				fi
			done || true
		else
			# No ignored apps, use faster bulk upgrade
			integer mas_rc=0
			run_with_timeout "$MAS_UPGRADE_TIMEOUT" mas upgrade || mas_rc=$?
			if (( mas_rc == TIMEOUT_EXIT_STATUS )); then
				echo "⏱️ Timed out after ${MAS_UPGRADE_TIMEOUT}s: bulk 'mas upgrade' was killed mid-download."
				echo "   Apps left unfinished stay on the outdated list and are retried on the next run."
			elif (( mas_rc != 0 )); then
				echo "⚠️ 'mas upgrade' failed (exit $mas_rc)."
			fi
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

    # Not unconditionally "done": count_failed items were still outdated when
    # the verify pass re-checked them, and a green tick for that is a lie.
    progress_write_completion "$count_failed" "$(( count_brew_pending + count_mas_pending ))"

    echo "---------------------------"
    integer count_updated=$(( count_brew_pending + count_mas_pending - count_failed ))
    if (( count_failed > 0 )); then
        echo "⚠️ Update finished with $count_failed failed item(s). See history for details."
        notify "$count_failed item(s) failed to update. See History in the menu for details." "Update Finished With Errors"
    elif (( count_updated > 0 )); then
        echo "✅ Update Complete!"
        notify "$count_updated package(s) updated successfully." "Update Complete"
    else
        echo "✅ Update Complete!"
        notify "Everything was already up to date." "Update Complete"
    fi
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")" || true
    echo "Done!"
    sleep 1
    exit 0
}
