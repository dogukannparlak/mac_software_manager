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

Four formats carry an explicit version marker (`vN|`) as their first field:
`progress` and `engine` below, the notification queue, and the single-item run
results - the last two documented in their own sections further down, since
neither lives in `cache/`. This is the convention every other format should adopt if
it ever needs a breaking change (new field, reordered fields, a field
dropped): bump to `v2`, keep the old reader path only if you need a
migration window, and make an unrecognized/missing version fail closed
(return "no data", never guess). See `tests/cache_format.bats` and
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
| 2 | state | `running` \| `done` \| `failed` | Closed set: the Swift reader rejects the whole line on any other token rather than guessing an outcome, so adding a state is an incompatible change - bump the version |
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
  every caller as "nothing to show," not "success." An unrecognized **state**
  (field 2) returns `nil` for the same reason: the version marker only catches
  a writer that changed the layout, so a v1 line carrying a state token the
  app does not know - a newer toolkit adding one without a bump - would
  otherwise be read as a finished, successful run. An unrecognized *phase* is
  the one field that does fall back (`unknown`), because a phase is only a
  label to print, not a verdict on the run.

### `engine`

What the installed engine declares it can be relied on to write. Rewritten by
**every** invocation of the engine - the SwiftBar menu draw, a cache refresh, a
bulk run, a headless single-item run - before any action is dispatched.

```
v1|epoch|contract|release
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | epoch | integer | When the engine wrote the record (`EPOCHSECONDS`, whole seconds). This is what attributes the record to a run - same rule, and same one second of slack, as the result records below |
| 3 | contract | integer | What the engine writes, as a single monotonic number. `ENGINE_CONTRACT` in `lib/cache.sh` |
| 4 | release | any string, may be empty | The engine's `<bitbar.version>`, for diagnostics only. **Never** part of the decision |

Canonical example (used verbatim by both test suites):
```
v1|1755400000|1|1.5.0
```

| Contract | The reader may rely on |
|---|---|
| `1` | Single-item run results (`results/`, `result_write`) and this record itself |

- **Why a number of its own and not the release version.** The two answer
  different questions. `<bitbar.version>` is stamped from `VERSION` by
  `tools/sync_version.sh` and tracks releases; two engines carrying the same
  one can still write different things. That is not hypothetical - the entire
  `results/` contract was added *within* v1.5.0, so "v1.5.0" describes both an
  engine that files single-item results and one that cannot, and an app
  trusting the release version reads the two as identical. This is exactly the
  mismatch that produced the incident in the results section below. `contract`
  moves only when what a reader may depend on moves.
- **Why the engine writes it at runtime instead of declaring it in a header.**
  The contract is implemented in `lib/*.sh`, not in the dispatcher that carries
  the header. A half-updated install - a new `update_system.1h.sh` over old
  libs - would have the header promising what the loaded code cannot do. A
  record written from `lib/cache.sh` can only be produced by an engine that
  actually loaded that file.
- **Why it is written before dispatch.** It makes absence conclusive. A run
  that has just finished has necessarily left a current record *if it was new
  enough to write one at all*, so a reader asking straight after a run can tell
  "this engine cannot report that" from "this engine has not run yet" - which a
  record written by the action itself, or only at install time, could not.
- **Reading it.** Take the record only when its timestamp is not older than the
  run being asked about (one second of slack, as above). That is also what
  closes the downgrade case: a record left by a newer engine that has since
  been replaced by an older one is older than the run asking, and is correctly
  read as "this engine said nothing" rather than vouching for an engine that is
  no longer installed. `contract >= required` passes; contracts are additive,
  so an engine *ahead* of the reader is always acceptable.
- **Bump `ENGINE_CONTRACT`** whenever a reader becomes entitled to something an
  older engine never wrote: a new file under `cache/` or a sibling directory, a
  `vN` bump in one of the formats here, or a new field a reader may require.
  Never for a change no reader can observe. Bump `EngineContract.required` in
  the same change that starts depending on it - the two are not the same edit,
  and only the second one is a promise the app is making.
- Shell writer: `engine_write()` in `lib/cache.sh`, called from section 5 of
  `update_system.1h.sh`. Best-effort and never fatal, like `progress_write` and
  `result_write`.
- Swift reader: `EngineContract.parse(raw:)` and `EngineContractStore` in
  `GuideApp/Sources/MacUpdaterGuide/Toolkit/EngineContract.swift`, consumed by
  `ToolkitController.reportEngineContract(forRunStartedAt:)`. A missing or
  unrecognized version, a short or long line, an undateable timestamp or a
  non-numeric contract all return `nil` - the same fail-closed rule everything
  else here follows, and the same thing a pre-contract engine produces.

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

## Single-item run results (`results/`)

How one item's update run went: which item, whether it updated, and if it did
not, why. Like the notification queue these are one-shot reports of something
that happened rather than TTL-refreshed state, so they live at
`$APP_DIR/results/` (a sibling of `cache/`, not inside it) and follow the same
`vN|` convention.

This is what GuideApp reads to resolve a row it launched. It exists because
three separate mechanisms used to answer "did that item update", and they
could disagree:

1. the `ok`/`fail` `run_mode_single` appends to `update_history.log`,
2. the `done`/`failed` written to `cache/progress` - which a headless
   single-item run does not write at all (`GUIDEAPP_NO_SHARED_PROGRESS`),
   because that file describes the one thing the toolkit is doing right now
   and several of those runs can be in flight at once,
3. GuideApp re-reading the outdated list once the run was over and calling
   the row failed if the item was still on it.

Only the first two are the run's own verdict. The third is a guess made by a
reader that never saw the run: it reads a real success as a failure whenever
the cache refresh lands a moment late, it cannot tell "still outdated" from
"the App Store refused it" or "the download outran the timeout", and it has
nothing to show for the failure it reports. The record replaces that guess.
(1) and (2) stay exactly what they were - the user-facing log, and the shared
banner for the run everyone can see.

One file per finished run, named `result.<pid>.<random>` (the name carries no
meaning - readers must not parse it, only iterate the directory). Written via
a temp file + atomic rename, so a reader never sees a partially-written
record. The temp file is the final name plus `.tmp`: readers must skip `.tmp`
entries and leave them alone, since one belongs to a write still in progress.

```
v1|epoch|kind|id|name|status|reason
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | epoch | integer | When the run wrote the record (`EPOCHSECONDS`, whole seconds). This is what attributes a record to a run - see "Reading them" below |
| 3 | kind | `brew` \| `cask` \| `mas` \| `app` | Exactly what the run was invoked with, never re-derived: `run single`'s type, or `app` for the Sparkle/GitHub `run install` path. A kind the reader does not know matches no row and is left alone |
| 4 | id | any string | Formula/cask token, App Store id, or application name - again as the run received it |
| 5 | name | any string, may be empty | Display name, for logs and diagnostics; never part of the verdict |
| 6 | status | `ok` \| `fail` | Closed set: the Swift reader rejects the whole record on any other token rather than guess an outcome, so adding a status is an incompatible change - bump the version |
| 7 | reason | a token from the table below, empty on `ok` | Unlike `status` this *does* fall back (`unknown`) in the reader: a reason is a label to print, not a verdict on the run - the same rule `progress`'s `phase` follows |

Canonical example (used verbatim by both test suites):
```
v1|1755400000|cask|alt-tab|AltTab|fail|still-outdated
```

| Reason | Written by | Means |
|---|---|---|
| *(empty)* | both | `status` is `ok`; there is nothing to explain |
| `still-outdated` | `run single` | The upgrade command reported success, but the item is still on the outdated list afterwards - the shell verifies, it never trusts an exit code |
| `timeout` | `run single` | `mas` was killed at `MAS_UPGRADE_TIMEOUT` (`lib/utils.sh`) - a hang guard tripping, not the App Store refusing |
| `command-failed` | `run single` | brew/mas exited non-zero; what it printed is the detail |
| `mas-disabled` | `run single` | App Store support is turned off |
| `mas-missing` | `run single` | `mas` is not installed |
| `not-pending` | `run install` | No pending update was recorded for the app |
| `not-installed` | `run install` | No bundle at `/Applications/<app>.app` |
| `setapp-managed` | `run install` | Setapp owns the app; replacing its copy breaks Setapp |
| `no-direct-download` | `run install` | Only a `.pkg` or a download page was on offer, so the page was opened |
| `download-failed` | `run install` | The download did not complete |
| `extract-failed` | `run install` | The archive did not contain exactly one application bundle |
| `verify-failed` | `run install` | The downloaded app failed verification; nothing was changed |
| `replace-failed` | `run install` | The replacement failed and the previous version was restored |

- There is deliberately no third status for "nothing was done, but nothing
  went wrong". `ok` means the item was updated and `fail` means it was not,
  which is exactly the question the row is asking; the nuance rides in the
  reason. `no-direct-download` is the case that makes this concrete: the run
  exits `0` having opened a browser page, and a row that read that as
  "Updated" would be claiming an update only the user can perform.
- **Writing them.** A record is written on every path that ends a run a row
  could be waiting on, including the early ones (`mas-disabled`,
  `not-pending`). Two paths deliberately write none: a dry run (nothing was
  going to be installed, and GuideApp runs those fire-and-forget with no item
  attached), and `run install` with no application named at all, which has no
  identity to file the record under. Within a run the record goes **after**
  that item's cache refresh (a reader may take it as "now go look at the
  list") and **before** the final `progress_write` (a terminal-mode run is
  resolved off that line, and the record has to be there when it is).
- **Reading them.** Match on `kind`+`id`: `brew`/`cask` map to GuideApp's
  `brew:<token>`, `app` to `app:<name>`, and `mas` to *either* `mas:<id>` or
  `manual:<id>` - one shell kind covers both sources, since an Apple app the
  `mas` CLI misses is still updated by the same command with the same id.
  Then check the timestamp: a record older than the run asking belongs to an
  earlier run of the same item that nobody consumed (one started from a
  terminal window, one cancelled after it had already reported), and must not
  answer for this one. Allow one second of slack - the stamp is whole
  seconds, the run's start is not. A reader deletes **only** the record it
  matched: a scan on one row must never consume another row's report.
- **When there is no record**, the reader falls back to its old check - is
  the item still on the outdated list - and never to "failed". GuideApp can
  be pointed at an engine older than this contract, which will never write
  one; "no record" is the same "no usable data" outcome a malformed line
  gets. That fallback is no longer *silent*: it is a guess made by a reader
  that never saw the run, and the reader now says so. Against an engine that
  did not declare contract 1 (see "Engine contract" above), GuideApp raises a
  `FailureBanner` naming the mismatch instead of letting the guess speak for
  the run. This is the incident that produced the record: a successful
  `brew upgrade` on an engine with no `result_write` was reported as "failed",
  because the guess re-read a cache the dead run had never refreshed, and
  nothing anywhere said the two halves disagreed.
- Unread records are pruned by age on every write (`result_prune`,
  `RESULT_RETENTION_SECONDS`, 24h). Anything still there by then belongs to a
  run nobody was watching - a terminal window, a SwiftBar menu click - and
  the directory must not grow without bound.
- Shell writer: `result_write()` in `lib/cache.sh`; call sites are
  `run_mode_single()` and `run_mode_install()` in `lib/run_modes.sh` (the
  latter through its `install_result` helper, which is also what skips the
  dry run).
- Swift reader: `ItemRunResult.parse(raw:)` and `ItemRunResultStore.consume(itemID:since:)`
  in `GuideApp/Sources/MacUpdaterGuide/Toolkit/ItemRunResult.swift`, consumed
  by `ToolkitController.finishActiveItem` (headless runs) and
  `resolveActiveSingleItem` (terminal-mode runs). A missing or unrecognized
  version, a short line, an undateable timestamp or an unknown `status` all
  return `nil` - the same fail-closed rule `UpdateProgress` follows.

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
