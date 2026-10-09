# Cache file formats

`update_system.1h.sh` (shell, the engine) writes the files under
`~/Library/Application Support/MacSoftwareUpdater/cache/`; `GuideApp` (Swift,
the UI) reads them independently. Neither side imports the other's parser, so
this file is the single place both are required to agree with. **If you
change a format below, update the writer, every reader (shell and Swift), and
this document in the same change** — nothing else will catch a mismatch for
you.

One reader is also a writer: GuideApp's Debug page (`Views/Debug/`, hidden
unless enabled) can write fixtures to produce UI states without running brew or
mas. It covers `brew_outdated`, `mas_outdated`, `manual_updates`,
`app_updates`, `progress`, the result records, the notification queue and
`engine` - not every format here (`migration_candidates`, `brew_status`,
`cask_homepages` and `github_homepages` have no generator; the migration panel
reads whatever the last real scan left). The page backs up whatever it
displaces, and its generators are round-tripped against the real parsers in
`DebugFixturesTests.swift` - but it is still a second writer, so a format
change has to reach `DebugFixtures.swift` along with everything else.

All formats are pipe (`|`) delimited, one record per line, UTF-8, no header
row unless noted. Fields never contain a literal `|` — every writer either
controls the field's content directly (an epoch timestamp, a fixed token) or
strips pipes before writing (e.g. `add_ignored` does `name="${name//|/}"`,
`collect_github_homepages`/`clean_mas_name` follow the same rule for anything
sourced from a free-form app or release name).

## Versioned formats

Five formats carry an explicit version marker (`vN|`) as their first field:
`progress`, `engine` and `migration_candidates` below, the notification queue,
and the single-item run results - the last two documented in their own sections
further down, since neither lives in `cache/`. This is the convention every other format should adopt if
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
v1|state|phase|item|index|total|bytes_done|bytes_total
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | state | `running` \| `done` \| `failed` | Closed set: the Swift reader rejects the whole line on any other token rather than guessing an outcome, so adding a state is an incompatible change - bump the version |
| 3 | phase | `starting`, `brew-update`, `analyze`, `brew-upgrade`, `mas-upgrade`, `cleanup`, `verify`, `install-app`, `single`, `scan-migration`, `migrate`, `complete`, `complete-with-failures`, `launch-failed`, `terminal-permission` | Free-form-ish but both sides only recognize this fixed set; `UpdateProgress.Phase` also has `process-error` (a process crash/non-zero exit was caught), `cancelled` (the user stopped this run from the app - `ToolkitController.cancelUpdate()`) and `not-started` (the run never wrote a line within `ProgressWatch.startupTimeout`), all three held in memory by the Swift side only, never written by the shell |
| 4 | item | any string, may be empty | package/app currently being worked on |
| 5 | index | integer or empty | 1-based position in the current batch; on `complete-with-failures`, how many items failed |
| 6 | total | integer or empty | size of the current batch; on `complete-with-failures`, how many were attempted |
| 7 | bytes_done | integer or empty | Real bytes downloaded so far for one cask's download (`cask_download_watch_start`, `lib/cache.sh`) - empty for every phase but `single`, and empty there too until the watcher has actually seen the download's temp file. Distinct from `index`/`total`: those already carry batch position for `brew-upgrade`/`mas-upgrade`, and a single-item run has no batch to report |
| 8 | bytes_total | integer or empty | The download's total size, HEAD-resolved from the cask's URL once, at the start of the watch - empty whenever that request failed or returned no `Content-Length` (formulae are never given a watcher at all: they mostly install from a small pre-built bottle, where a byte counter would rarely have anything to show) |

Canonical example (used verbatim by both test suites):
```
v1|running|brew-upgrade|awscli|3|8||
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
  `cleanup`, `verify`, `scan-migration`, `migrate`), 2h15m for the ones that
  wait on a single download or build (`brew-upgrade`, `mas-upgrade`,
  `install-app`, `single`, and any phase the reader does not recognize). Both
  migration phases take the short window deliberately: the scan steps from app
  to app and a migration is one `brew install --cask --adopt` that Homebrew
  reports on, so neither sits silent on a long download. Before they were
  named they fell through to `unknown` and inherited the 2h15m window, which
  left a dead scan looking live for hours. The longer window only ever comes
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
**every** invocation of the engine - a cache refresh, a bulk run, a headless
single-item run - before any action is dispatched.

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
v1|1755400000|2|1.5.0
```

| Contract | The reader may rely on |
|---|---|
| `1` | Single-item run results (`results/`, `result_write`) and this record itself |
| `2` | Migration candidates (`migration_candidates`, the `scan_migration` action) and the `migrate_app` / `migrate_app_in_terminal` actions, including the `migrate` result kind and its reasons |

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

### `migration_candidates`

Applications sitting in `/Applications` (or `~/Applications`) that Homebrew
does not manage but could, and what would happen to each if it were handed
over. Written **only** by the user-triggered `scan_migration` action - see the
note on cost below.

```
v1|app_name|app_path|bundle_id|installed_version|token|cask_version|match|state|homepage
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | version | `v1` | Bump on any incompatible change to the fields below |
| 2 | app_name | any string | Bundle name without `.app`, as it appears on disk. This is the id the `migrate_app` action is invoked with |
| 3 | app_path | absolute path | Where the bundle actually is. `~/Applications` entries are normal here and are exactly what the `target-mismatch` state below is about |
| 4 | bundle_id | any string, may be empty | `CFBundleIdentifier` from the installed `Info.plist`; empty when the plist could not be read |
| 5 | installed_version | any string, may be empty | `CFBundleShortVersionString` from the installed `Info.plist`, raw and un-normalized |
| 6 | token | cask token | The candidate cask. Never a `brew search` result - see below |
| 7 | cask_version | any string, may be empty | The cask's `version` field, i.e. what migrating would move the app to |
| 8 | match | `override` \| `artifact` \| `bundle` \| `token` | How the app was tied to the cask, strongest first - see the table below |
| 9 | state | `adoptable` \| `version-mismatch` \| `no-app-artifact` \| `needs-root` \| `target-mismatch` \| `deprecated` | What migrating would do, decided without running anything - see the table below |
| 10 | homepage | `https://` URL or empty | The cask's `homepage`, blank unless it is an https URL |

Canonical example (used verbatim by both test suites):
```
v1|AltTab|/Applications/AltTab.app|com.lwouis.alt-tab-macos|11.5.0|alt-tab|11.5.0|artifact|adoptable|https://alt-tab.app/
```

**`match` - how sure the pairing is.** Only the middle two are evidence about
the application itself. The UI is expected to mark anything other than
`artifact` and `bundle` as unverified, because the weakest kind of match is
exactly the kind that pairs an app with an unrelated cask.

| Value | Means |
|---|---|
| `override` | A hand-written `app_token_map.conf` entry. The user stated the answer; nothing is guessed after it |
| `artifact` | The cask installs a bundle whose file name is exactly the installed `.app`'s |
| `bundle` | The cask names this exact `CFBundleIdentifier` in its `uninstall` `quit`/`launchctl` list - written by the cask author against the real application |
| `token` | A token derived from the app's name resolved to *a* cask, and that is all that is known. The weakest match, and the one to show as unverified |

**`state` - what migrating would do.** Computed from the cask's JSON metadata
and the installed `Info.plist` alone: nothing is run, nothing is downloaded,
nothing on disk is touched. Listed in the order they are decided, since a
blocker outranks a warning.

| Value | Means |
|---|---|
| `deprecated` | The cask is deprecated or disabled. A disabled cask cannot be installed at all, so nothing below it matters |
| `no-app-artifact` | The cask installs no `.app` (a pkg or installer cask such as `logitech-g-hub`). There is nothing to adopt and nothing to put back: not migratable |
| `needs-root` | An installer script declaring `sudo`, or a target under `/Library`. The engine does not escalate - see the header of `lib/migrate.sh` for why a headless run must not reach a password prompt |
| `target-mismatch` | The cask installs somewhere other than `app_path`. This is the `~/Applications` trap: adopting does not *move* a bundle, it installs a second copy at the cask's target and leaves the original where it was |
| `version-mismatch` | There is an app artifact, but the versions do not line up, so `--adopt` will refuse. A `replace` would work |
| `adoptable` | `brew install --cask --adopt` should succeed |

- **The adoptable rule is Homebrew's own**, from `Cask::Artifact::Moved#move`
  (`moved.rb:95-135`): with `auto_updates` the bundle versions are not compared
  at all, and without it **both** the short version and the build version of the
  incoming bundle must equal the installed one. What the scan compares is the
  cask's recorded `bundle_short_version`/`bundle_version` rather than the
  download itself - that metadata is generated from that very download, so it is
  the closest thing to the answer available without fetching it. A cask
  recording neither makes Homebrew fall back to a recursive `diff` whose outcome
  cannot be predicted from here; that reports as `version-mismatch`, since
  "adopt may well refuse" is the honest answer. Being wrong about it is cheap:
  a refused adopt leaves the target untouched.
- **`brew search` is never used to find the token.** It is a fuzzy, human-facing
  tool that is allowed to guess, and on the machine this was developed against
  it answers "ClearDisk" with "clearvpn". Every candidate token is resolved with
  `brew info --cask --json=v2 <token>`, which either matches the exact token or
  fails.
- **Not a cache tier.** This key is deliberately absent from
  `CACHE_KEYS_UPDATES`/`INSTALLED`/`APPS`/`WEBSITES`: a scan costs one
  `brew info` round trip per candidate token across every unmanaged app on the
  machine. It is written when the user asks for it (`scan_migration`) and never
  by the background refresh, so it carries no TTL and readers must treat it as
  a snapshot of whenever it was last taken, not as current state.
- Shell writer: `migration_scan()` in `lib/migrate.sh`, via the `scan_migration`
  action in section 5 of `update_system.1h.sh`. The act of migrating is a
  separate action (`migrate_app <name> <token> <adopt|replace|dry>`), which
  re-derives the state from a fresh `brew info` rather than trusting this entry
  - the entry may be days old, and the decision writes to `/Applications`.
  `migrate_app_in_terminal` takes the same arguments and does the same work in
  the user's terminal (via `launch_in_terminal_or_report`, so it arrives as
  `run migrate`): the headless path never runs `sudo`, having no tty to prompt
  on, and this is where Homebrew can ask for a password when it needs one to
  write over a root-owned bundle. Both were added under contract `2`; neither
  is a separate contract, because they ship in the same release.
- Swift reader: `MigrationCandidate.parse(raw:)` and `MigrationCandidateStore`
  in `GuideApp/Sources/MacUpdaterGuide/Toolkit/MigrationCandidate.swift`,
  rendered by `MigrateToHomebrewPage`. A missing or unrecognized version, a
  line without exactly 10 fields, an empty app name or token, or an unknown
  `match` all return `nil` - the same fail-closed rule everything else here
  follows. `match` and `state` differ on purpose: an unknown **match** rejects
  the record (it says nothing about whether the pairing was verified, and both
  guesses are wrong in a way the user pays for), while an unknown **state**
  falls back to a non-actionable `unknown` rather than dropping an app the user
  can see on disk. Either way an unrecognized value is never read as
  `adoptable`. `MigrationCandidate.parseAll` skips only the lines it cannot
  read, so one record from a newer engine does not empty the page.
- Reading the entry is gated on the engine contract, not just on the file being
  there: the page checks `EngineContract.migrationContract` (2) before it
  offers to scan. That threshold is deliberately separate from
  `EngineContract.required`, which is the baseline every surface needs -
  raising the baseline over one page would put the "engine is out of date"
  banner in front of users whose updates work fine.

## Unversioned formats (documented, no marker yet)

These share the exact same risk (independent shell writer + Swift reader, no
marker), but do not carry a version field yet. Add one following the
`progress` pattern above if you need to change any of them incompatibly -
particularly `brew_outdated`, which is the highest-value target for this next
(it drives the main update list) but also the largest change: it has **four**
independent shell-side consumers of the raw field positions in addition to
the writer, so adding a version field means updating all of the following in
lockstep, not just the writer:

- Writer: `brew_outdated_normalized()` (`lib/updaters.sh`)
- `brew_outdated_tokens()` (`lib/updaters.sh`) - `${${(s:|:)line}[2]}`
- The system update flow (`run_mode_system`, `lib/run_modes.sh`) - `outdated_fields[1..5]`
- The menu-render filtering pass (`render_menu`, `lib/menu.sh`) - `entry_fields[1..5]`
- The menu-render display pass (`lib/menu.sh`, the monitored-items submenu) - `entry_fields[1..4]`
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
- Writer: `brew_outdated_normalized()`, `lib/updaters.sh`.
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
- Writer: `collect_brew_status()`, `lib/updaters.sh`.
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
- Writer: `collect_manual_updates()`, `lib/updaters.sh`.
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
- Writer: `collect_app_updates()`, `lib/selfupdate_apps.sh`.
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
- Writer: `collect_cask_homepages()`, `lib/selfupdate_apps.sh`.
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
- Writer: `collect_github_homepages()`, `lib/selfupdate_apps.sh`.
- Swift reader: `InstalledInventory.websiteMap()`, `InstalledApps.swift`.

### `other_packages`

Everything outside Homebrew and the App Store, one package per line. Written
empty when `OTHER_SOURCES_ENABLED="0"`.
```
source|name|version|location
```
`source` is one of `npm`, `pipx`, `uv`, `cargo`, `go`, `app` (a command line
shim inside an application bundle), `local` (a standalone executable in
`~/.local/bin` and the like) or `pkg` (an installer package receipt).
`version` and `location` may be empty. `location` is what the source needs to
act on the package: the module path for `go` (what `go install` takes), the
bundle for `app`, the resolved file for `local`, the install location for
`pkg`. Example:
```
npm|@anthropic-ai/claude-code|2.0.14|
local|claude|2.0.14|/Users/me/.local/share/claude/versions/2.0.14/claude
go|gopls|0.16.2|golang.org/x/tools/gopls
```
A reader skips sources it does not know, so a newer engine can add one.
- Writer: `collect_other_packages()`, `lib/updaters.sh`.
- Shell reader: `other_package_line()` (`run_mode_tool` only acts on a
  package listed here).
- Swift reader: `OtherPackage.parse(packages:outdated:)`, `OtherPackage.swift`.

### `other_outdated`

```
source|name|current|latest
```
`npm` answers in one call (`npm outdated -g`); `pipx`, `uv`, `cargo` and the
self-updating standalone tools (`claude`, `uv`, `bun`) are looked up one by
one in PyPI, crates.io or the npm registry, from the last `other_packages`
scan. Only a strictly newer version is written. Example:
```
npm|typescript|5.4.5|5.6.3
local|claude|2.1.290|2.1.295
```
- Writer: `collect_other_outdated()`, `lib/updaters.sh`.
- Swift reader: `OtherPackage.parse(packages:outdated:)`, `OtherPackage.swift`.

## Notification queue (`notifications/`)

Not a cache - each file is a one-shot event, not TTL-refreshed state - but
the same dual-parser risk as everything above, so it follows the same `vN|`
convention rather than starting a new one. Lives at
`$APP_DIR/notifications/` (a sibling of `cache/`, not inside it).

The shell engine can run headless - cron, a terminal - with no
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
| 3 | kind | `brew` \| `cask` \| `mas` \| `app` \| `migrate` | Exactly what the run was invoked with, never re-derived: `run single`'s type, `app` for the Sparkle/GitHub `run install` path, or `migrate` for the `migrate_app` action (whose `id` is the cask token it was migrating to). Unlike `status`, this is **open**: a kind the reader does not know matches no row and is left alone, which is what let `migrate` be added without a version bump |
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
| `cask-not-found` | `migrate_app` | No cask by that token exists, or the application bundle is not where it was recorded |
| `no-app-artifact` | `migrate_app` | The cask installs no `.app` (a pkg/installer cask). There is nothing to adopt and nothing to put back |
| `needs-root` | `migrate_app` | The cask needs administrator rights - an installer script declaring `sudo`, or a target under `/Library`. The engine will not escalate; see `lib/migrate.sh` |
| `target-mismatch` | `migrate_app` | The cask installs somewhere other than where the app already is, so migrating would leave a second copy behind rather than take this one over |
| `adopt-version-mismatch` | `migrate_app` | `brew install --cask --adopt` refused because the installed bundle is not the version the cask ships. Nothing was changed; a `replace` would install the cask's version |
| `install-failed` | `migrate_app` | Homebrew could not install the cask, and nothing had been moved aside (or the backup could not be put back - the message names where it is) |
| `restored-after-failure` | `migrate_app` | A `replace` failed and the original application was moved back into place. Nothing changed |

- There is deliberately no third status for "nothing was done, but nothing
  went wrong". `ok` means the item was updated and `fail` means it was not,
  which is exactly the question the row is asking; the nuance rides in the
  reason. `no-direct-download` is the case that makes this concrete: the run
  exits `0` having opened a browser page, and a row that read that as
  "Updated" would be claiming an update only the user can perform.
- **Writing them.** A record is written on every path that ends a run a row
  could be waiting on, including the early ones (`mas-disabled`,
  `not-pending`). Two paths deliberately write none: a `run install` dry run
  (nothing was going to be installed, and GuideApp fires those off with no
  item attached), and `run install` with no application named at all, which
  has no identity to file the record under. A **migration** dry run does
  write one, unlike those two: it is itself the answer the user asked for,
  and a row is waiting on it - see `migration_report()` in `lib/migrate.sh`,
  which skips only the history entry (a dry run changed nothing, and the log
  is a log of changes). Within a run the record goes **after** that item's
  cache refresh (a reader may take it as "now go look at the list") and
  **before** the final `progress_write` (a terminal-mode run is resolved off
  that line, and the record has to be there when it is).
- **Reading them.** Match on `kind`+`id`: `brew`/`cask` map to GuideApp's
  `brew:<token>`, `app` to `app:<name>`, `migrate` to `migrate:<token>` (the
  cask the app was being moved *to* - `ToolkitController.migrationItemPrefix`
  is the one place that prefix is spelled), and `mas` to *either* `mas:<id>`
  or `manual:<id>` - one shell kind covers both sources, since an Apple app
  the `mas` CLI misses is still updated by the same command with the same id.
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
  run nobody was watching - a terminal window, a cron tick - and
  the directory must not grow without bound.
- Shell writer: `result_write()` in `lib/cache.sh`; call sites are
  `run_mode_single()` and `run_mode_install()` in `lib/run_modes.sh` (the
  latter through its `install_result` helper, which is also what skips the
  dry run), and `migrate_to_cask()`/`migration_report()` in `lib/migrate.sh`
  for the `migrate` kind.
- Swift reader: `ItemRunResult.parse(raw:)` and `ItemRunResultStore.consume(itemID:since:)`
  in `GuideApp/Sources/MacUpdaterGuide/Toolkit/ItemRunResult.swift`, consumed
  by `ToolkitController.finishActiveItem` (headless runs),
  `finishMigration` (the headless `migrate_app` path, which resolves a
  `migrate:<token>` row on the Move to Homebrew page) and
  `resolveActiveSingleItem` (terminal-mode runs, `migrate_app_in_terminal`
  included). A missing or unrecognized version, a short line, an undateable
  timestamp or an unknown `status` all return `nil` - the same fail-closed
  rule `UpdateProgress` follows.

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
