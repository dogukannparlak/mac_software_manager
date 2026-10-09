# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The app stopped asking to install itself, and SwiftBar is gone.

### Removed

- **SwiftBar, everywhere.** The menu bar item has belonged to
  `MacUpdaterGuide.app` since 1.5.0, which left SwiftBar as a second menu
  nobody the app was built for ever saw — and a dependency `setup_mac.sh`
  installed, added to the login items and launched on their behalf.

  What went: `lib/menu.sh` and `render_menu` (the plugin's whole 651-line menu
  draw), `swiftbar_sq_escape` in `lib/utils.sh` and its tests, every
  `swiftbar://refreshplugin` call, the `<swiftbar.*>` plugin metadata header,
  and the `change_interval` and `toggle_autostart` subcommands — the first
  scheduled by renaming the file, which only SwiftBar read, and the second
  toggled SwiftBar's own login item.

  `setup_mac.sh` no longer installs the SwiftBar cask, asks about a plugin
  directory, writes `com.ameba.SwiftBar` preferences, or touches the login
  items at all; the engine always installs into
  `~/Library/Application Support/MacSoftwareUpdater/` and normalises to
  `update_system.1h.sh`. `uninstall.sh` lost its `--plugin` and `--swiftbar`
  steps and now walks five steps rather than seven. `ToolkitPaths` no longer
  searches SwiftBar's plugin folder.

  **If you installed through SwiftBar**, its plugin script and the SwiftBar
  cask stay on your Mac and the uninstaller no longer offers to remove them.
  Delete `update_system.*.sh` from your plugin directory and
  `brew uninstall --cask swiftbar` by hand.

  Running the engine with no subcommand now prints its usage and exits `2`
  instead of drawing a menu. `AUTOSTART` stays in `settings.conf` as a legacy
  key so existing files keep parsing; nothing reads it.

### Changed

- **The engine ships inside the app and runs from there.** No install step, no
  download, no "the engine is not installed" state. `MacUpdaterGuide.app`
  carries `update_system.1h.sh`, `lib/*.sh` and `uninstall.sh` as resources and
  runs them in place with `MSU_LIB_DIR` pointed at its own bundle.

  Three properties of the engine make this work, and all three were already
  true: it writes nothing beside itself, it creates its own state directory on
  every run (`mkdir -p "$APP_DIR" "$CACHE_DIR" "$LOCK_DIR"`), and it runs on
  defaults when there is no `settings.conf`. Copying those files into
  `~/Library/Application Support` and calling it "setting up" was the app
  installing itself in front of the user — an extra step, an extra thing to go
  wrong, and a prerequisite-shaped warning before a single update had been
  checked.

  `ToolkitPaths.locateScript()` prefers the bundled engine over any installed
  copy, so the two can never disagree about what the other writes. An existing
  `setup_mac.sh` installation still works; the app just no longer needs it to
  be there. The Uninstall page falls back to the bundled `uninstall.sh` the
  same way.

- **The setup sheet now lists only what the app cannot bring with it**:
  Homebrew, and the optional `mas`. It appears only when Homebrew is missing
  and never otherwise. `Dependency` has no `engine` case, and there is nothing
  left in the app that installs an engine.

- `tools/sync_engine_resources.sh` copies the engine into the app target and
  `--check`s it; `build_release.sh` runs that check next to the version and
  checksum guards, so a release cannot ship an engine older than the tree it
  was built from.

### Added

- **An app icon.** A blue rounded square with white update arrows around a
  download arrow, in `GuideApp/Sources/MacUpdaterGuide/Assets.xcassets`; the
  source drawing is `GuideApp/Design/AppIcon.svg`.

- **`setup_mac.sh --unattended`**: installs the engine with no questions asked,
  every answer taken from the existing configuration or a safe default. It
  prints machine-readable `STEP|<id>|<state>|<text>` progress lines alongside
  its normal output, skips the migration wizard, and adds no login item. Exit
  codes are `0` success, `2` bad usage, `3` no Homebrew, `1` anything else.
  Works together with `--local`.

  This is now the *terminal* path — for scripting a fresh Mac. The app does
  not use it.

  It installs into `~/Library/Application Support/MacSoftwareUpdater/`, which
  is where the app looks for an installed copy.

### Security

- **The app never asks for your password, and never runs `sudo`.** Homebrew's
  installer needs an administrator, so that one row opens Terminal.app with
  Homebrew's official command and then polls for `brew` to appear — the prompt
  comes from macOS, in a window the user opened, with the command visible
  before it runs. A GUI application that asks for an administrator password is
  indistinguishable from one phishing for it, and this app declines to teach
  that habit.
- Shipping the engine in the bundle removes the download-and-verify path from
  the app entirely: there is no longer a remote script that has to be checked
  before it can be run, because there is no remote script.

### Fixed

- `setup_mac.sh` no longer deletes `setup_mac.sh` and `uninstall.sh` out of its
  own support folder when that folder is also the plugin directory. Only
  reachable through the new `--unattended` path, where the two can coincide.
- Runs launched in a terminal window now load the right engine library. The
  new shell never saw GuideApp's `MSU_LIB_DIR`, so the bundled script fell
  back to `$APP_DIR/lib` — an older library, or none ("Missing engine file").
  The command now carries the variable, and without it the engine looks for
  its library next to itself first.
- The self-update and "Update Channel" no longer write into the app bundle.
  Only an engine installed by `setup_mac.sh` replaces its own files; the one
  inside the app is updated with the app.
- "Update Channel" replaces the whole engine (script and `lib/`), not only
  `update_system.1h.sh`.
- A second update check answered with 304 no longer clears an update that
  the first check found and nobody has installed yet.
- App names containing `"` or `'` no longer break (or inject into) the
  AppleScript that opens Terminal or iTerm2.
- Warp now actually runs the update, through a Launch Configuration — the
  old `--args` went to Warp, not to the script. Alacritty gets `open -n`, so
  the command is not dropped when it is already running.
- CI's "Plugin renders without touching the network" step still expected the
  SwiftBar menu (`Refresh now`), which went with `lib/menu.sh`; with no
  subcommand the engine now prints its usage banner and exits 2. The step
  now checks exactly that, plus the state folder it creates.
- README, README.tr, SECURITY, CONTRIBUTING and the in-app guide describe
  which engine updates itself (a terminal install) and which is updated with
  the app. The old SwiftBar screenshots in `img/` and the never-captured
  image placeholders in both READMEs are removed.
- Ignoring or restoring a formula reports a failing `brew pin`/`unpin`
  instead of exiting silently; app installs write the eight-field history
  line; the update check rejects a download with no version header.

## [1.6.0] - 2026-08-23

Uninstalling stopped being a terminal-only job.

### Added

- **Uninstall page** in the app (Settings > Uninstall): every item the toolkit
  put on this Mac as a tick box with the exact path beside it, a dry run that
  reports without removing, and one confirmation for the whole set. It drives
  the same `uninstall.sh` the terminal does. The login item and the in-memory
  preferences are cleared in Swift instead, because only the running app can
  make either stick. When `uninstall.sh` is not installed at all — the app came
  straight from the disk image — the page moves the app to the Trash and clears
  its preferences, which is all there is to remove in that case.
- `uninstall.sh` gained a non-interactive mode: `--list`, per-step flags
  (`--plugin`, `--app`, `--login-item`, `--data`, `--prefs`, `--mas`,
  `--swiftbar`), `--all`, `--dry-run`, `--app-path`, `--quiet` and `--help`.
  Naming any step turns the `[y/N]` questions off and prints one
  `RESULT|step|outcome|detail` line per step. With no arguments it is the same
  walkthrough it has always been.
- `tools/build_release.sh` builds the `dist/` artifacts: a universal Release
  build, checked with `lipo` and `codesign`, packaged as both a `.dmg` and a
  `.zip` with a matching `SHA256SUMS.txt`. It refuses to run against a tree
  whose version strings or `SHA256SUMS` are out of date.

### Changed

- `uninstall.sh` no longer offers to uninstall Homebrew. It now removes only
  what this toolkit installed, and prints where to find Homebrew's own
  uninstall instructions instead. The script consequently downloads and runs no
  remote code at all.

### Fixed

- `uninstall.sh` re-execs from a temporary copy when it is about to delete the
  folder it lives in. zsh reads a script as it runs it, so removing
  `~/Library/Application Support/MacSoftwareUpdater` mid-run could truncate the
  rest of the uninstall.
- The preferences step now sticks when run from the app. `defaults delete`
  reaches the file on disk, but a running app writes its own copy back out on
  quit, which silently restored what had just been removed.

## [1.5.0] - 2026-08-23

The release that turned a SwiftBar plugin into a two-layer toolkit: a zsh
engine split across `lib/*.sh`, and a native SwiftUI app that reads its cache
and drives it. SwiftBar is no longer required.

### Added

- **Native companion app** (`GuideApp/`) with its own menu bar item, update
  list, installed-app inventory, history and settings, bilingual in English and
  Turkish (`650306a`, `49fd1fb`, `79ff7da`).
- **Move to Homebrew page** under Settings: finds hand-installed apps a
  Homebrew cask could manage, states how sure each pairing is and what moving
  would do, and hands them over in place (`a477259`, `5259c83`, `d572086`).
- **Hidden Debug page** for driving every screen, state and engine output by
  hand without waiting on brew, mas or the network. It injects fixtures by
  writing the same files the app normally reads, with a sidecar backup contract
  so a crash mid-injection is still recoverable (`4b6a5c5`, `9ffc26d`,
  `0ed7a2a`, `24d120c`).
- **`--local` flag for `setup_mac.sh`**, which installs the checkout it was run
  from instead of downloading and verifying the published copy over your
  unpushed changes (`8b74ceb`).
- **Single-item run results** (`results/`): a run files its own verdict, so a
  row is resolved by what the run reported rather than by a reader re-reading
  the outdated list and guessing (`b68cb05`, `6dc983d`, `3a0266b`).
- **CLI Tools as its own sidebar page**, with a category taxonomy built from
  `brew leaves` and `brew desc` (`db848cf`, `cbdf466`, `52a5a18`, `e05ef67`).
- **Concurrent single-item updates** with per-row status and a cancellable bulk
  run, plus the concurrency setting and cancel control in the UI (`22fe95f`,
  `ca87cdc`, `8e19725`, `3192266`).
- **Engine library** `lib/*.sh`: the monolithic plugin became a bootstrap and
  dispatcher that sources its functions at runtime (`4c17107`).
- **Verified self-update tooling**: `VERSION` as the single source of truth,
  `tools/sync_version.sh` and `tools/generate_checksums.sh` (`ceb008a`), later
  extended to sync the Xcode project's `MARKETING_VERSION` (`4424da7`).
- **CI**: shell syntax, version-sync and checksum checks (`b26a15b`), a
  bats-core suite for the engine (`6f3056e`), a SwiftLint job (`50e0841`,
  `b97184c`), runs on feature and fix branches (`be3b0ac`), and a localization
  audit (`facec02`).
- **Native notifications** routed through `UNUserNotificationCenter` via a
  file-based queue the engine drops events into (`2bb1bf4`).
- **Uninstaller coverage for the app**: bundle, login item and preferences
  (`5cb04ed`).
- A **real bundle identifier** for the app, and release artifacts added to
  `.gitignore` (`35dcc4b`).

### Changed

- Project renamed to **Mac Software Manager** (`6d28afb`).
- The update engine was rebuilt around a cache: the menu render never shells out
  to brew, mas or curl (`7dbcb20`).
- The installer now verifies its Homebrew downloads, sets up the Codeberg
  mirror and installs `lib/` (`ae7952d`, `2439a1a`).
- A single update refreshes only that item's cache entries, not all of them
  (`22851e3`).
- Self-update detection scans one level of `/Applications` subfolders
  (`27a4cb0`).
- `ToolkitController` and `GuideContent` were split across files by
  responsibility (`8f7e89f`, `46ad1ba`).
- SwiftLint moved off advisory: it now blocks on errors (`46ad1ba`), after the
  auto-fixable violations were cleared (`da45375`).

### Fixed

- A failed run is recorded as failed instead of a green tick, and a run with
  failed items no longer reports as finished (`15ab929`, `711cf22`).
- An unreadable progress state no longer reads as success (`0505f38`).
- A quiet run is no longer read as dead, nor a dead one as running (`a652200`),
  and the progress watch no longer fails a run that has not started
  (`e00cef6`).
- A terminal that never opened is reported instead of exiting `0` over it
  (`ca3f5ec`), and the About dialog no longer needs an Automation grant the
  user never gave (`55d2258`).
- A missing SwiftBar no longer drowns out the real error (`e13afb4`).
- Every `mas` call is behind a timeout, with the query timeout separated from
  the download timeout (`abbe9c0`, `aa99dab`).
- A found App Store app no longer reads as missing (`cd37930`).
- One unrefreshable cache entry no longer kills the whole run (`cf5ff3b`).
- Cask migration install and uninstall failures are surfaced rather than
  silenced (`29f218b`, `9aefa29`, `493420b`).
- `uninstall.sh` no longer crashes when no SwiftBar plugin scripts remain
  (`557ea01`).
- A run's stderr is read while it runs, not once it is over (`f25b0d4`).
- Premature exit in the brew update retry loop (`0bd0384`).

## [1.4.3] - 2026-03-24

### Changed

- Version bump and comment cleanup (`34f31fd`, `3d32c8e`).

## [1.4.2] - 2026-03-23

### Added

- Retry logic for `brew update`, with improved App Store app handling
  (`3991f98`).
- Final Cut Pro and Logic Pro App Store IDs (`371ef3a`).

### Fixed

- Opening the About dialog no longer launches Terminal (`f769a48`).
- Running an update no longer opens multiple terminal windows (`7d97493`,
  `b3127dc`), and Ghostty no longer starts a second instance (`e3ab3b0`).
- Homebrew formula versions are captured in the update history (`019be11`).
- Ignored apps detection and history logging (`2f94e3b`, `c3d9f31`).
- awk record variables mistakenly replaced during a path refactor (`b6f3301`).

### Changed

- Migrated to `$SCRIPT_FILE` with tighter shell quoting (`6ebcc62`).
- Hybrid SwiftBar autostart toggle (`37533be`).

## [1.4.0] - 2026-02-16

### Added

- **Update channel switching** between stable and beta (`a53f83b`).
- **App Store toggle** in both setup and the SwiftBar menu (`0337b32`).
- **Per-app ignore/update actions** with persistent storage (`2dbe11c`), and
  ignored apps surfaced in the statistics submenu (`eb331a7`).
- Direct Mac App Store links by app ID (`f7ebfe6`).

### Changed

- Sourced settings replaced with strict key parsing; validation warnings moved
  to a submenu (`af51bf1`).
- Ignore filtering optimized and the security posture hardened (`3bb588f`).
- UI/UX refinements (`06c2048`).

### Fixed

- Ignored casks are excluded from the bulk `brew upgrade` (`f49f6cb`), and
  ignored App Store apps from bulk updates (`c7fc76a`).
- Ghost app updates are gated by `MAS_ENABLED` (`4dc4236`).
- `mas upgrade` is used for a single app during a full update, avoiding the
  "already installed" warning (`48dacd9`).
- Cask version display strips commit hashes (`a2603af`).
- The `mas` Spotlight auto-indexing warning is suppressed, and the app name is
  shown instead of the ID in terminal output (`8a2ccde`).

## [1.3.8] - 2026-02-04

### Changed

- `mas` parsing overhauled and `brew` output streamed (`338919d`).

## [1.3.7] - 2026-02-04

### Fixed

- `mas outdated` parsing, corrupted history display, and a zsh pattern error
  (`ee3039a`).

## [1.3.6] - 2026-02-01

### Added

- Auto-migration for renamed casks (`9fef3b8`).
- Detailed update logging with a date-grouped history view (`f94c9f9`).

### Fixed

- Silent script exit caused by zsh arithmetic evaluation (`bd12583`).
- Statistics counting (`9fef3b8`).

## [1.3.4] - 2026-01-30

### Added

- Granular update modes — system versus plugin — with UI improvements
  (`150183e`).
- Creator Studio support, and a more reliable version check (`e251910`).

## [1.3.2] - 2026-01-28

### Added

- **Terminal app selection** (iTerm2, Warp, Alacritty) in setup and preferences
  (`3d13707`).
- SwiftBar autostart via Login Items (`0041cae`), and launching SwiftBar when
  it is not already running (`39c98fa`).
- A custom Quit button in the plugin menu (`85d8c8f`).
- Intelligent sudo permission detection for app migration (`b233c0c`).
- Local app version scanning (`be0dbe1`), with a progress bar during the setup
  scan (`88c6996`).

### Fixed

- Cask detection using token variations and smart prefix validation
  (`8c9246b`).
- App Store update counting when `mas` output carries leading whitespace
  (`61b93a9`, `6304930`).
- Script termination during app migration caused by osascript and brew failures
  (`11ecfca`).
- A `defaults` fallback for local app version scanning (`df97816`).

## [1.3.0] - 2026-01-22

Earliest release covered by this changelog.
