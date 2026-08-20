# Cache file formats

`update_system.1h.sh` (shell, the engine) writes the files under
`~/Library/Application Support/MacSoftwareUpdater/cache/`; `GuideApp` (Swift,
the UI) reads them independently. Neither side imports the other's parser, so
this file is the single place both are required to agree with. **If you
change a format below, update the writer, every reader (shell and Swift), and
this document in the same change** — nothing else will catch a mismatch for
you.

All formats are pipe (`|`) delimited, one record per line, UTF-8, no header
row unless noted. Fields never contain a literal `|` — every writer either
controls the field's content directly (an epoch timestamp, a fixed token) or
strips pipes before writing (e.g. `add_ignored` does `name="${name//|/}"`,
`collect_github_homepages`/`clean_mas_name` follow the same rule for anything
sourced from a free-form app or release name).

## Versioned formats

Only `progress` currently carries an explicit version marker (`vN|`) as its
first field. This is the convention every other format should adopt if it
ever needs a breaking change (new field, reordered fields, a field dropped):
bump to `v2`, keep the old reader path only if you need a migration window,
and make an unrecognized/missing version fail closed (return "no data",
never guess). See `tests/cache_format.bats` and
`UpdateProgressParsingTests.swift` for the pattern - both assert against the
exact same example line, so a change to one side that the other does not
match breaks a test on whichever side has the stale code.

### `progress`

Live status of the update currently running (or the last one that ran), read
by the app roughly every 700ms while a run is in flight.

```
v1|state|phase|item|index|total
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | state | `running` \| `done` \| `failed` | |
| 3 | phase | `starting`, `brew-update`, `analyze`, `brew-upgrade`, `mas-upgrade`, `cleanup`, `verify`, `install-app`, `single`, `complete`, `complete-with-failures`, `launch-failed`, `terminal-permission` | Free-form-ish but both sides only recognize this fixed set; `UpdateProgress.Phase` also has `process-error` (a process crash/non-zero exit was caught) and `not-started` (the run never wrote a line within `ProgressWatch.startupTimeout`), both held in memory by the Swift side only, never written by the shell |
| 4 | item | any string, may be empty | package/app currently being worked on |
| 5 | index | integer or empty | 1-based position in the current batch; on `complete-with-failures`, how many items failed |
| 6 | total | integer or empty | size of the current batch; on `complete-with-failures`, how many were attempted |

Canonical example (used verbatim by both test suites):
```
v1|running|brew-upgrade|awscli|3|8
```

- A run that reaches the end writes its last entry through
  `progress_write_completion()` (`lib/cache.sh`), not `progress_write()`
  directly: reaching the end is not the same as succeeding, so a verified
  failure count above zero writes `failed|complete-with-failures` with the
  failed/attempted counts in `index`/`total` (the reader words them, so the
  wording can be localized) instead of `done|complete` - which paired a green
  tick and "Finished" with a run where packages were still outdated.
- The file's **modification time is part of the contract**, not just
  bookkeeping: a live run re-stamps it every `PROGRESS_HEARTBEAT_INTERVAL`
  seconds (`progress_heartbeat_start()`, `lib/cache.sh`) with a `touch`, so
  the content never changes and no reader needs a new field. A `running`
  entry that has stopped aging is therefore a run that died - the stamper
  stops itself when its run is gone (`kill -0`, which covers SIGKILL and a
  closed terminal window, where no EXIT trap runs), when the entry stops
  saying `running`, or when the file disappears. Without it, the only clue a
  reader had was the last phase change, and a `mas upgrade` is allowed to
  download silently for `MAS_UPGRADE_TIMEOUT` (7200s, `lib/utils.sh`).
- Readers must therefore treat a `running` entry as dead once it is older
  than `UpdateProgress.staleAfter(for:)` - 15 minutes for the phases that
  write as they step through work (`starting`, `brew-update`, `analyze`,
  `cleanup`, `verify`), 2h15m for the ones that wait on a single download or
  build (`brew-upgrade`, `mas-upgrade`, `install-app`, `single`, and any
  phase the reader does not recognize). The longer window only ever comes
  into play for a toolkit installed before the heartbeat existed; with it, a
  dead run is caught within the short one whatever phase it died in. This is
  not cosmetic: GuideApp also holds its per-item update queue behind any
  entry that says `running` (`ToolkitController.startOrQueue`).
- The last two phases are written by a *launcher*, not by a run: the three
  menu actions that start a run in the user's terminal (`install_app`,
  `update_app`, `launch_update`) go through `launch_in_terminal_or_report()`
  (`lib/utils.sh`), and when no terminal opens there is no run to write
  anything ever again. `terminal-permission` is the case with a fix - macOS
  refused the Apple event for want of Automation permission (osascript error
  `-1743`), which an ad-hoc-signed GuideApp loses on every rebuild - and
  `launch-failed` is everything else; `item` carries the terminal app's name
  in both, and the reader supplies the wording. These are the only entries
  written by something that does not own the file, so they go through
  `progress_write_failure()`, which declines to overwrite a `running` entry
  that the heartbeat has stamped within the last three intervals - a launch
  that failed must not report some *other*, live run as dead.
- Shell writer: `progress_write()` in `lib/cache.sh`; reader/self-check:
  `progress_finalize()` in the same file. It runs from the `run` dispatcher's
  EXIT trap so an unfinished "running" entry never leaves the UI showing a
  run as stuck forever, and it takes the exit status that trap caught: `0`
  resolves the entry to `done|complete`, anything else to `failed` with the
  recorded phase/item/index/total left in place, so the UI can name the step
  the run died on. Traps must read `$?` as their first command
  (`trap 'progress_finalize $?' EXIT`) - and note that a zsh EXIT trap set
  *inside a function* is function-local and reports `$?` as `0` on `exit N`,
  so only the top-level dispatcher trap may finalize; the function-local
  traps in `lib/run_modes.sh` do cleanup only.
- Swift reader: `UpdateProgress.parse(raw:modified:now:)` in
  `GuideApp/Sources/MacUpdaterGuide/Toolkit/UpdateProgress.swift`. A missing
  or unrecognized version returns `nil` (the same "no usable data" outcome as
  any other malformed line), never a guessed state - `nil` is treated by
  every caller as "nothing to show," not "success."

## Unversioned formats (documented, no marker yet)

These share the exact same risk (independent shell writer + Swift reader, no
marker), but do not carry a version field yet. Add one following the
`progress` pattern above if you need to change any of them incompatibly -
particularly `brew_outdated`, which is the highest-value target for this next
(it drives the main update list) but also the largest change: it has **four**
independent shell-side consumers of the raw field positions in addition to
the writer, so adding a version field means updating all of the following in
lockstep, not just the writer:

- Writer: `brew_outdated_normalized()` (~line 531)
- `brew_outdated_tokens()` (~line 591) - `${${(s:|:)line}[2]}`
- The "run all" update flow (~line 2884-2890) - `outdated_fields[1..5]`
- The menu-render filtering pass (~line 3148-3150) - `entry_fields[1..5]`
- The menu-render display pass (~line 3400-3403) - `entry_fields[1..4]`
- Swift reader: `UpdateSnapshot.homebrewItems()` in `UpdateSnapshot.swift`

### `brew_outdated`

```
src|token|installed_versions|current_version|pinned
```
`src` is `brew` or `cask`; `installed_versions` is comma-separated when a
formula has multiple versions installed; `pinned` is `0`/`1`. Example:
```
cask|alt-tab|11.4.3|11.4.4|0
```
- Writer: `brew_outdated_normalized()`, `update_system.1h.sh` (~line 531).
- Swift reader: `UpdateSnapshot.homebrewItems()`, `UpdateSnapshot.swift`.

### `brew_status`

```
version|last_commit_epoch
```
`last_commit_epoch` is `0` when it could not be determined (no local tap
repo, `git log` failed) - not a valid timestamp, callers must treat `0` as
"unknown," never epoch 1970. Example:
```
Homebrew 4.7.0|1755400000
```
- Writer: `collect_brew_status()`, `update_system.1h.sh` (~line 1666).
- Swift reader: `HomebrewStatus.load()`,
  `GuideApp/Sources/MacUpdaterGuide/Toolkit/LaunchAtLogin.swift`.

### `manual_updates`

Apple first-party apps `mas` regularly fails to report as outdated, checked
by hand against the iTunes Lookup API.
```
name|local_version|remote_version|app_id
```
Example:
```
Keynote|13.2|13.3|361285480
```
- Writer: `collect_manual_updates()`, `update_system.1h.sh` (~line 1039).
- Swift reader: `UpdateSnapshot.manualItems()`, `UpdateSnapshot.swift`.

### `app_updates`

Self-updating apps discovered via a Sparkle appcast or GitHub releases.
```
method|name|local_version|remote_version|url|signature
```
`method` is `sparkle` or `github`; `url` is the release/download page;
`signature` is the Sparkle EdDSA signature when the feed provides one, empty
otherwise. Example:
```
sparkle|AltTab|6.18.0|6.19.0|https://github.com/lwouis/alt-tab-macos/releases/tag/v6.19.0|
```
- Writer: `collect_app_updates()`, `update_system.1h.sh` (~line 1570).
- Swift reader: `UpdateSnapshot.selfUpdatingItems()`, `UpdateSnapshot.swift`.

### `cask_homepages`

```
token|homepage|repo
```
`repo` (`owner/repo`) is blank when the cask does not download from a GitHub
release asset - never guessed. Example:
```
alt-tab|https://alt-tab-macos.netlify.app/|lwouis/alt-tab-macos
```
- Writer: `collect_cask_homepages()`, `update_system.1h.sh` (~line 1429).
- Swift reader: `InstalledInventory.caskMetadataByToken()`,
  `GuideApp/Sources/MacUpdaterGuide/Toolkit/InstalledApps.swift`.

### `github_homepages`

Homepage for apps traced to a GitHub repo but *not* managed by Homebrew (the
cask case is covered by `cask_homepages` above).
```
name|homepage
```
Example:
```
SomeApp|https://example.com
```
- Writer: `collect_github_homepages()`, `update_system.1h.sh` (~line 1482).
- Swift reader: `InstalledInventory.websiteMap()`, `InstalledApps.swift`.

## Notification queue (`notifications/`)

Not a cache - each file is a one-shot event, not TTL-refreshed state - but
the same dual-parser risk as everything above, so it follows the same `vN|`
convention rather than starting a new one. Lives at
`$APP_DIR/notifications/` (a sibling of `cache/`, not inside it).

The shell engine can run headless - cron, SwiftBar, a terminal - with no
guarantee GuideApp is even running, so it cannot call into the app directly.
Instead, whenever GuideApp is running (checked with `pgrep -x
MacUpdaterGuide`) it drops one file per notification into this directory;
GuideApp watches the directory and turns each into a native
`UNUserNotificationCenter` alert, deleting the file once read. When GuideApp
is not running, or the file cannot be written, the shell falls back to a
plain `osascript display notification` (shows up labeled "Script Editor",
no action button) instead of queuing anything.

One file per notification, named `notify.<pid>.<random>` (the name carries
no meaning - readers must not parse it, only iterate the directory).
Written via a temp file + atomic rename into place, so the directory watcher
never observes a partially-written file.

```
v1|title|subtitle|body
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | title | any string, may be empty | always `Mac Software Manager` today |
| 3 | subtitle | any string, may be empty | |
| 4 | body | any string, may be empty | the notification's main text |

Canonical example (used verbatim by both test suites):
```
v1|Mac Software Manager|Update Complete|3 package(s) updated successfully.
```

- Shell writer: `notify()` in `lib/utils.sh`.
- Swift reader: `NotificationBridge` in
  `GuideApp/Sources/MacUpdaterGuide/Toolkit/NotificationBridge.swift`.

## Explicitly out of scope

- `brew_casks`, `brew_formulae`, `brew_leaves`, `brew_formulae_desc`,
  `brew_casks_desc`, `mas_list`, `brew_pinned`, `mas_outdated` - raw
  `brew`/`mas` CLI output, not a format this project defines. Versioning them
  would be meaningless; both sides already treat them defensively
  (missing/empty cache → empty list, never a crash). `brew_formulae_desc` and
  `brew_casks_desc` are `brew desc`'s own `token: description` output, one
  formula/cask per line.
- `ignored_apps.conf`, `tracked_apps.conf`, `app_token_map.conf`,
  `update_history.log` - same dual-parser risk as the cache files above, but
  they live outside `cache/` (config/log files, not TTL-refreshed cache) and
  are out of scope for this document. Worth the same treatment in a follow-up.
