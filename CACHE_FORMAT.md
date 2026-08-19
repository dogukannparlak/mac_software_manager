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
| 3 | phase | `starting`, `brew-update`, `analyze`, `brew-upgrade`, `mas-upgrade`, `cleanup`, `verify`, `install-app`, `single`, `complete` | Free-form-ish but both sides only recognize this fixed set; `UpdateProgress.Phase` also has `process-error`, written only by the Swift side when a process crash/non-zero-exit is caught, never by the shell |
| 4 | item | any string, may be empty | package/app currently being worked on |
| 5 | index | integer or empty | 1-based position in the current batch |
| 6 | total | integer or empty | size of the current batch |

Canonical example (used verbatim by both test suites):
```
v1|running|brew-upgrade|awscli|3|8
```

- Shell writer: `progress_write()` in `update_system.1h.sh` (~line 474);
  reader/self-check: `progress_finalize()` (~line 483, runs on EXIT and
  promotes an unfinished "running" entry to "done" so the UI never shows a
  run as stuck forever).
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

- `brew_casks`, `brew_formulae`, `mas_list`, `brew_pinned`, `mas_outdated` -
  raw `brew`/`mas` CLI output, not a format this project defines. Versioning
  them would be meaningless; both sides already treat them defensively
  (missing/empty cache → empty list, never a crash).
- `ignored_apps.conf`, `tracked_apps.conf`, `app_token_map.conf`,
  `update_history.log` - same dual-parser risk as the cache files above, but
  they live outside `cache/` (config/log files, not TTL-refreshed cache) and
  are out of scope for this document. Worth the same treatment in a follow-up.
