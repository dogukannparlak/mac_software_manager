<div align="center" markdown="1">

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.6.0-blue)](https://github.com/dogukannparlak/mac_software_manager/releases)

![Engine](https://img.shields.io/badge/engine-zsh%20%2B%20Homebrew-blue?logo=homebrew&logoColor=white)
![App](https://img.shields.io/badge/app-macOS%2014.0%2B-blue?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/binary-Apple%20Silicon%20%2B%20Intel-blue?logo=apple&logoColor=white)

</div>

# Mac Software Manager

🇹🇷 Türkçe: [README.tr.md](README.tr.md)

Mac Software Manager keeps track of every application and command line tool on
your Mac — where each one came from, whether an update is waiting, and whether
Homebrew could be managing it instead of you. It updates them from one place,
in the background, and can hand hand-installed apps over to Homebrew without
losing their settings.

<!-- Image 1 : img/app_menubar_panel.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_menubar_panel.png" alt="The app's menu bar panel" width="100%">
  <br><sub>The menu bar item belongs to MacUpdaterGuide itself.</sub>
</p>
-->

## Requirements

The two halves have different requirements, and you can use either one without
the other:

| Part | Needs |
| --- | --- |
| **Shell engine** (`update_system.1h.sh`, `lib/*.sh`, `setup_mac.sh`) | `zsh` and **Homebrew** — the engine refuses to run without `brew` (pre-flight check in `update_system.1h.sh`). `mas` is optional, for App Store apps. |
| **MacUpdaterGuide.app** (`GuideApp/`) | **macOS 14.0 or later** — `MACOSX_DEPLOYMENT_TARGET = 14.0` in `GuideApp/MacUpdaterGuide.xcodeproj/project.pbxproj` and `.macOS(.v14)` in [GuideApp/Package.swift](GuideApp/Package.swift). Universal binary: Apple Silicon and Intel. |

## How it is put together

Two layers, one state directory between them:

* The **shell engine** knows how to talk to Homebrew, the App Store (`mas`),
  Sparkle appcasts and GitHub release feeds. It does all the work and writes
  what it finds into
  `~/Library/Application Support/MacSoftwareUpdater/cache/`.
* The **SwiftUI app** (`GuideApp/`) reads that cache and drives the engine by
  invoking its subcommands, and owns the menu bar item. Every engine
  invocation names a subcommand; run it bare and it prints its usage and
  exits **2**.

The cache format is the contract between them, documented in
[CACHE_FORMAT.md](CACHE_FORMAT.md).

## Features

* **Update everything from one place.** Homebrew formulae and casks, App Store
  apps via `mas`, and apps that update themselves through a Sparkle appcast or
  a GitHub releases feed.
* **Instant menu.** Everything shown is read from the cache, refreshed in the
  background, so opening the menu never waits on Homebrew or the network.
* **Live progress.** The engine writes what it is doing right now — refreshing
  Homebrew, upgrading a named package, cleaning up — and both the menu bar item
  and the Updates page report it, whether the run is headless or in a terminal.
* **Honest history.** After a run each package is re-checked and the real
  outcome is logged, so a failed update is recorded as failed rather than
  counted as a success.
* **Inventory with provenance.** Every application with its icon, version and
  where it came from: Homebrew, App Store, Setapp, Apple, or installed by hand.
* **CLI tools as their own page.** Every Homebrew formula on the machine,
  grouped into categories (see below).
* **Move to Homebrew.** Finds hand-installed apps a Homebrew cask could keep
  updated, says how sure each pairing is and exactly what moving would do, then
  hands them over in place.
* **Verified self-update.** The engine only replaces itself after the download
  matches the published `SHA256SUMS` — see [Security](#security).
* **Verified app replacement, opt-in.** For apps with a direct DMG/ZIP
  download, the engine can install the update itself, but only after Team ID,
  code signature, Gatekeeper and (where published) Sparkle's EdDSA signature
  all pass. Off by default.
* **Granular control.** Ignore (pin) an app, correct how it is tracked, map an
  app name to a Homebrew cask token, or fix a detected website/GitHub link —
  all from the app, all written into the engine's own config files.
* **Native notifications.** The engine drops one file per event into
  `notifications/`; the app turns each into a real `UNUserNotificationCenter`
  alert with an **Open** action. When the app is not running, the engine falls
  back to `osascript`.
* **Nothing to install.** The engine ships **inside the app** and runs from
  there — no setup step, no download, no version mismatch, and nothing written
  outside the app's own state folder. On a Mac that is only missing Homebrew or
  `mas`, a setup sheet offers those two and nothing else; when both are present
  it never appears. The app never asks for your password: the one step that
  needs an administrator (Homebrew's own installer) is opened in Terminal, and
  the app watches for the result.
* **Two languages.** English and Turkish, switchable without relaunching.

## Menu bar states

The icon is drawn by the app (`MenuBarLabel` in `MacUpdaterGuideApp.swift`) and
carries three states:

<!-- Image 1.1 : img/menubar_icon_states.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/menubar_icon_states.png" alt="The three menu bar icon states" width="100%">
  <br><sub>Left to right: up to date, updates pending, refreshing.</sub>
</p>
-->

| State | SF Symbol | Meaning |
| :--- | :--- | :--- |
| **Up to date** | `checkmark.circle` | Nothing pending. |
| **Updates pending** | `arrow.triangle.2.circlepath.circle` + count | The number of waiting updates is drawn next to the icon. |
| **Refreshing** | `arrow.triangle.2.circlepath` | A cache refresh is in flight. |


## Installation

The app and the engine install separately. Most people want both, but each
works on its own.

### 1. The app

Download from
[GitHub Releases](https://github.com/dogukannparlak/mac_software_manager/releases):

| File | For |
| --- | --- |
| `MacUpdaterGuide-<version>-macOS-universal.dmg` | Drag-and-drop install |
| `MacUpdaterGuide-<version>-macOS-universal.zip` | Smaller download |

Both are universal binaries — Apple Silicon and Intel — and require macOS 14.0
or later. Each release also publishes a `SHA256SUMS.txt` you can check your
download against:

```bash
shasum -a 256 MacUpdaterGuide-<version>-macOS-universal.dmg
```

The app is **signed ad-hoc**, not with an Apple Developer ID, so macOS refuses
to open it on the first try. Either:

* **Right-click the app → Open → Open**, or
* run `xattr -dr com.apple.quarantine /Applications/MacUpdaterGuide.app`

Once only.

> The 1.6.0 release is still a **draft** at the time of writing, so its assets
> are not publicly downloadable yet. Until it is published, build the app from
> source — see [Development](#development).

### 2. The engine and the migration wizard

**From the app: nothing to do.** `MacUpdaterGuide.app` carries the whole engine
inside it — `update_system.1h.sh`, `lib/*.sh` and `uninstall.sh` — and runs it
straight out of the bundle. There is no install step, no download, and no
"engine not found" state: the app and the engine are one release, so they can
never disagree about what the other writes.

That works because the engine never writes beside itself. Everything it stores
goes to `~/Library/Application Support/MacSoftwareUpdater/`, which it creates on
its own on every run, and it runs on defaults when there is no `settings.conf`.
The app points `MSU_LIB_DIR` at its own resources and calls it.

The only things the app cannot bring with it are Homebrew and `mas`. If either
is missing, a setup sheet offers them — Homebrew by opening its official
installer in Terminal (never in the app: it asks for an administrator
password), `mas` with `brew install mas`. With both present the sheet never
appears at all.

**From a terminal.** Clone the repository (or download the source archive from
the Releases page) and run the wizard from the checkout:

```bash
git clone https://github.com/dogukannparlak/mac_software_manager.git
cd mac_software_manager
./setup_mac.sh
```

`setup_mac.sh` installs the engine into
`~/Library/Application Support/MacSoftwareUpdater/`, writes `settings.conf`,
and walks you through the migration step described below. Without `--local` it
downloads each file it installs and verifies it against the published
`SHA256SUMS` before putting it in place, falling back to the copy next to the
installer only when no verified remote source can be reached.
`./setup_mac.sh --help` lists every flag.

`--unattended` is the mode the app's setup sheet drives, and it works from a
terminal too — useful for scripting a fresh Mac. It answers every question with
its safe default (existing configuration where there is one, otherwise
Terminal.app and App Store updates on), skips the migration wizard, adds no
login item, and prints machine-readable
`STEP|<id>|<state>|<text>` lines alongside its normal output. It never installs
Homebrew: a Mac without it exits **3** with a single line saying so. Exit codes
are `0` success, `2` bad usage, `3` no Homebrew, `1` anything else.

`setup_mac.sh` installs the engine into
`~/Library/Application Support/MacSoftwareUpdater/`, which is where the app
looks for an installed copy.

During setup it asks for a **Codeberg username** for a backup mirror. Leave it
blank to skip: downloads still work and are verified against GitHub alone, and
the menu says so rather than silently downgrading the guarantee. See
[Security](#security).


### The migration step

`setup_mac.sh` scans `/Applications` for software no package manager owns, and
for each one checks whether a matching Homebrew cask or App Store entry exists.
For every unmanaged app it asks what to do:

* **[A]pp Store** — replace the manual copy with the App Store version.
* **[B]rew Cask** — replace it with a Homebrew cask, preserving settings.
* **[L]eave** — keep it exactly as it is.

<!-- Image 6 : img/migration_utility.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/migration_utility.png" alt="The migration wizard in a terminal" width="100%">
  <br><sub><code>setup_mac.sh</code> asking what to do with an unmanaged app. The file in the repository is from v1.2.4 and still carries the old project name, so it needs re-shooting before this is uncommented.</sub>
</p>
-->

Before any migration it makes a local backup (`.app.bak`) and restores it
automatically if the new installation fails, removing the backup only after a
completely successful install.

Answering **[L]eave** costs nothing: the same job is available later from the
app under **Settings → Move to Homebrew**, without a terminal.

## Using it

### The app

The window is a sidebar and a detail pane:

Six entries in the sidebar: **Updates**, **Installed Apps**, **CLI Tools**,
**History**, **Guide** and **Settings**. Each is described below.

The menu bar item is created by the app itself. It shows the pending count and,
during a run, which package it is on. It is deliberately read-only — a glance,
not a control panel. **Settings → General → Menu bar only** drops the Dock icon.

The app ships its own copy of the engine and also looks in
`~/Library/Application Support/MacSoftwareUpdater/` for an installed one. If you
keep it elsewhere, point at it under **Settings → Advanced**.

#### Updates

Everything waiting, grouped by source, with real app icons. Update one item or
all of them, or hide one you want to stay behind on. **Refresh** re-reads the
cache; **Check Homebrew** pulls the latest Homebrew and tap metadata on demand.

<!-- Image 2 : img/app_updates.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_updates.png" alt="The Updates page" width="100%">
  <br><sub>Pending updates grouped by source, with Refresh and Check Homebrew in the toolbar.</sub>
</p>
-->

Updates run in the background by default, with a progress banner naming the
phase and the package currently being installed, an x/y counter, and a Cancel
button. Cancelling a bulk run asks for confirmation first
(`ToolkitController.cancelUpdate()`). A terminal window is opt-in, under Settings → General.

<!-- Image 2.1 : img/app_updates_progress.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_updates_progress.png" alt="A run in progress" width="100%">
  <br><sub>The progress banner during a run: phase, current package, counter and Cancel.</sub>
</p>
-->

#### Installed Apps

Every application with its icon, version and origin — Homebrew, App Store,
Setapp, Apple, or installed by hand. Filter by source and search.

<!-- Image 3 : img/app_installed.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_installed.png" alt="The Installed Apps page" width="100%">
  <br><sub>Each row carries an icon, a version and the badge saying where the app came from.</sub>
</p>
-->

Each row's **"…" menu** is everything for that one app: open its website or
GitHub page, correct those links, change how it is tracked for updates, remap
it to a Homebrew cask, or ignore it. Every correction is local and applied
immediately.

<!-- Image 3.1 : img/app_installed_row_menu.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_installed_row_menu.png" alt="A row's actions menu" width="100%">
  <br><sub>Edit Links…, Edit Tracking Method…, Edit Homebrew Mapping… and Ignore, all on one app.</sub>
</p>
-->

#### CLI Tools

Homebrew has no first-class notion of a category for a formula, so this page
leans on the one piece of real metadata Homebrew does expose: `brew leaves` —
what you actually asked for, as opposed to what was pulled in transitively —
plus a keyword heuristic over each leaf's own `brew desc` description.

Leaves are sorted into eleven categories: Version Control, Languages &
Runtimes, Cloud/DevOps & AI, Databases, Networking & Security, Build & Package
Tools, Media & Documents, Shell & Text Utilities, Testing, Other Tools, and
Libraries & Dependencies.

A formula that is **not** a leaf is someone else's dependency, not a tool you
think of as having a category, so it always lands in **Libraries &
Dependencies** regardless of what it does. That bucket is the biggest one on
most machines, so it is broken down further into its own sub-headings
(runtime support, networking & security, databases, graphics & media, text &
data, compression, AWS SDK, windowing, core).

<!-- Image 3.2 : img/app_cli_tools.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_cli_tools.png" alt="The CLI Tools page" width="100%">
  <br><sub>The category filter, with the leaf categories separated from the Libraries &amp; Dependencies bucket.</sub>
</p>
-->

#### History

What was updated over the last 7 or 30 days, grouped by day. Failures are
marked, not hidden — after a run each package is re-checked and the real
outcome is what gets logged.

<!-- Image 4 : img/app_history.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_history.png" alt="The History page" width="100%">
  <br><sub>The 7/30 day selector and day-grouped entries, including a failed one.</sub>
</p>
-->

#### Guide

The full feature guide, built into the app in English and Turkish, switchable
without relaunching.

#### Settings

Eight pages: General, Updates, Tracked Apps, Name Mapping, Move to Homebrew,
Ignored Apps, Advanced, About. Everything is written straight into the engine's
own config files, so the app and the terminal never disagree.

**Simultaneous Updates** on the General page is why single-item runs are exempt
from the engine's exclusive lock: the app caps how many run at once itself
(`AppPreferences.maxConcurrentUpdates`), and taking the bulk lock as well would
just serialize them back to one at a time.

<!-- Image 5 : img/app_settings_general.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_settings_general.png" alt="Settings › General" width="100%">
  <br><sub>Language, check interval, run-in-terminal switch and terminal picker, concurrent update count, Dock icon, open at login.</sub>
</p>
-->

#### Settings → Move to Homebrew

The wizard's migration step, available at any time and without a terminal.

**Scan** walks `/Applications` and `~/Applications`, skips everything already
accounted for (Homebrew casks, App Store apps, Setapp's catalogue, Apple's own
apps, anything you have ignored), and for each of the rest asks Homebrew
whether a cask by that name exists. **Scanning changes nothing**: the verdict
for every row is read off the cask's own JSON metadata and the installed
bundle's `Info.plist`, so nothing is downloaded, installed or moved until you
pick a row. It is never run in the background — one `brew info` per candidate
per unmanaged app is too expensive for the hourly tick — so the list is a
snapshot of whenever you last pressed the button.

The results land in three groups:

* **Ready to move** — Homebrew adopts the copy already on disk. Checkboxes and
  a bulk button, because adopting is not destructive.
* **Needs your confirmation** — the installed copy is not the version the cask
  ships, so adopting is refused and moving means *replacing* the app with the
  cask's version. One at a time, behind a confirmation sheet that shows both
  versions and warns you when the move would be a downgrade.
* **Cannot be moved** — listed with the reason rather than filtered out,
  because "why is my app not in the list" is the question a filtered list
  creates.

<!-- Image 5.1 : img/app_settings_migrate.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_settings_migrate.png" alt="Move to Homebrew after a scan" width="100%">
  <br><sub>All three groups at once: Ready to move, Needs your confirmation, and Cannot be moved with its reason.</sub>
</p>
-->

**Why a failed move costs nothing.** The default is
`brew install --cask --adopt`, which takes over the bundle that is already
there instead of downloading a replacement. When Homebrew will not adopt it,
it says so and **leaves the target completely untouched** — a refused adopt
does not delete, move or overwrite your installation, so the worst case is
that nothing happened. The destructive path (back up, reinstall, restore on
failure) is only ever reached by asking for it explicitly in the
"Needs your confirmation" group.

**When moving is not possible at all.** Three cases, and the page names which
one applies to each row:

* **pkg / installer casks** (`logitech-g-hub` is the usual example) install a
  package rather than an `.app`, so there is no bundle for Homebrew to adopt
  and none to put back if anything went wrong.
* **Casks that need an administrator** — an installer script declaring `sudo`,
  or a target under `/Library`. The toolkit never runs `sudo` from a
  background run, which would have nowhere to show a password prompt, so the
  row shows you the `brew install --cask <token>` line to run yourself.
* **A target mismatch** — usually an app in `~/Applications` for a cask that
  installs to `/Applications`. Adopting does not *move* a bundle; it would
  install a second copy at the cask's own target and leave yours where it is.

Every row also says how the app was tied to its cask. A pairing backed by the
cask's own metadata (its app file name or your app's exact bundle identifier)
or by a line you wrote in `app_token_map.conf` is treated as verified;
a pairing that is only a guess derived from the app's name is flagged
**Unverified**, with a link to the cask's page so you can check before moving
anything.

**Its relationship to the installer's migration step.** They are the same job
with two entry points: `setup_mac.sh` asks the question once, while you are
installing, and this page asks it any time afterwards. The wizard runs
*before* the toolkit exists — it is what creates `~/Library/Application
Support/MacSoftwareUpdater/lib` in the first place — so it cannot `source`
anything from `lib/` and carries its own copy of the token matching and the
migration itself. That duplication is deliberate, not an oversight; when the
matching rules change, both copies move together. Two differences follow from
where each one runs: the wizard has a terminal, so it may escalate with
`sudo` and it falls straight through from a refused adopt to a
back-up-and-reinstall, whereas the page runs headless with nowhere to show a
password prompt and never replaces an app unless you ask for it by name.

### From a terminal

The app is optional. A full update from a terminal:

```bash
~/Library/Application\ Support/MacSoftwareUpdater/update_system.1h.sh run all
```

## Engine command line

`update_system.1h.sh` is a bootstrap and dispatcher; its functions live in
`lib/*.sh` (ten modules) and are sourced at runtime. Every caller names one of
the subcommands below; anything else prints the usage banner and exits **2**.

| Invocation | What it does |
| --- | --- |
| `run all` | `plugin` then `system`: self-update check, then the full update. Takes the exclusive update lock. |
| `run system` | Homebrew and (if enabled) App Store upgrades, plus optional cleanup. Exclusive lock. |
| `run plugin` | Self-update check for the engine and its `lib/` set. Exclusive lock. |
| `run single <args>` | Update one item, headless. No exclusive lock — the app enforces its own concurrency limit. |
| `run install <args>` | Install one app's update from its DMG/ZIP. No exclusive lock. |
| `run migrate <app> <token> [adopt\|replace\|dry]` | Hand one app over to Homebrew. No exclusive lock. |
| `refresh_cache [auto\|force]` | `auto` (the default) refreshes only the stale tiers; `force` (or `all`) refreshes everything. Non-blocking — exits if a refresh is already running. |
| `check_updates` | Manual self-update check. |
| `brew_update` | `brew update` only: pulls the latest Homebrew and tap metadata without upgrading anything. Takes the same lock a run does. |
| `scan_migration` | Scans for apps Homebrew could manage. Never part of a background refresh. Takes the cache lock. |
| `migrate_app <app> <token> [adopt\|replace\|dry]` | Headless migration of one app. Never runs `sudo`. |
| `migrate_app_in_terminal <app> <token> [adopt\|replace\|dry]` | The same, in your configured terminal, where Homebrew can prompt for a password. |
| `install_app <app> [live\|dry]` | Launches `run install` in your terminal. |
| `update_app <args>` | Launches `run single` in your terminal. |
| `ignore_app <brew\|cask\|mas\|sparkle> <id> [name]` | Pins a formula or adds the item to `ignored_apps.conf`. |
| `unignore_app <type> <id>` | Reverses that. |
| `toggle_mas` | Turns App Store (`mas`) support on or off. |
| `toggle_cleanup` | Turns `brew cleanup --prune=all` after a run on or off. |
| `toggle_auto_install` | Turns automatic app-bundle replacement on or off. |
| `change_terminal` | Preferred terminal: Terminal, iTerm2, Warp, Alacritty or Ghostty. |
| `change_branch` | Update channel — see the note under [Update channel](#update-channel). |
| `about_dialog` | The About dialog. |
| `launch_update [mode]` | Launches a run in your configured terminal. |

### Update channel

`change_branch` offers **Stable (Main)** and **Beta (Develop)**, writing
`main` or `develop` into `UPDATE_BRANCH`. The setting exists and works, but
**the `develop` branch is not currently published** — `origin` has `main` and
`feature/debug-page` only — so selecting Beta today points self-update at a
branch that is not there. Stay on Stable unless a `develop` branch is
announced.

## Configuration files

All in `~/Library/Application Support/MacSoftwareUpdater/`.

| Path | Purpose |
| --- | --- |
| `settings.conf` | The engine's settings, written by `setup_mac.sh` and edited by the toggles above. Mode `600`. |
| `ignored_apps.conf` | Apps hidden from the update list (`type\|id\|name`). |
| `tracked_apps.conf` | How individual apps are checked for updates. |
| `app_token_map.conf` | App name → Homebrew cask token mapping. |
| `app_links.conf` | Corrections to an app's detected website / GitHub repository. App-only — the shell engine never reads it. |
| `cache/` | Cached update data plus the engine contract file. Safe to delete; rebuilt automatically. |
| `notifications/` | One-shot notification requests the engine drops for the app to pick up. Events, not TTL state. |
| `results/` | One file per single-item run, holding that run's outcome. |
| `lib/` | The eleven engine modules, downloaded and verified as one atomic set. |

`update_history.log` sits alongside them and holds the history the app shows.

### `settings.conf` keys

Exactly what `setup_mac.sh` writes:

| Key | Meaning |
| --- | --- |
| `PREFERRED_TERMINAL` | `Terminal`, `iTerm2`, `Warp`, `Alacritty` or `Ghostty`. |
| `MAS_ENABLED` | App Store updates. `1` = enabled, `0` = disabled. |
| `UPDATE_BRANCH` | Update channel: `main` (stable) or `develop` (beta). |
| `AUTOSTART` | Legacy autostart flag. Nothing reads it — starting at login is the app's own setting, recorded by macOS. |
| `CLEANUP_ENABLED` | Run `brew cleanup --prune=all` after each update. |
| `AUTO_INSTALL_APPS` | Replace self-updating app bundles directly. `0` by default. |
| `CODEBERG_USERNAME` | Username for the backup mirror. Blank = GitHub only, no dual-source verification. |

Re-running `setup_mac.sh` preserves the existing values.

### `tracked_apps.conf`

Apps that manage their own updates are detected automatically (Sparkle feed in
`Info.plist`, otherwise a GitHub repository derived from that feed or from a
`com.github.owner.repo` bundle identifier). Add a line here when the automatic
guess is wrong or missing:

```
App Name|method|identifier

MyApp|sparkle|https://example.com/appcast.xml   # explicit appcast URL
MyApp|github|owner/MyApp                        # GitHub releases feed
MyApp|homebrew|my-app                           # leave it to the Homebrew section
MyApp|skip|                                     # never check this app
```

`App Name` is the bundle name without `.app`, matched case insensitively. Edit
it from **Settings → Tracked Apps**, or open an app's "…" menu on the
Installed Apps page and choose **Edit Tracking Method…** to fix just that one.

### `app_token_map.conf`

Some Homebrew tokens cannot be derived from an app's name (`lghub` is the cask
`logitech-g-hub`). One mapping per line:

```
lghub|logitech-g-hub
Sublime Text|sublime-text
```

The migration wizard also appends a mapping automatically whenever you type a
cask name by hand, so it will match on the next run. Editable from
**Settings → Name Mapping** or per app from its "…" menu.

A mapping here counts as an `override` in the **Move to Homebrew** scan, which
is the strongest match there is: you stated the answer, so nothing is guessed
after it and no name-derived candidate can outrank it.

### `app_links.conf`

Website and GitHub links are detected automatically (from a Homebrew cask's
declared homepage and download URL, or a GitHub repo's own homepage field) and
are usually right. When one is wrong or missing, correct it from an app's "…"
menu → **Edit Links…** — nothing to type here by hand:

```
App Name|website|owner/repo
```

Either field can be left blank to keep the automatically detected value for
just that one. Purely local: the shell engine never reads this file.

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md) — please do not open
a public issue for one.

### Self-update

Self-update overwrites a script that runs on every menu refresh, so nothing is
installed before it passes three checks: the download has to parse as `zsh`,
its SHA-256 has to match the publisher's `SHA256SUMS`, and — when a mirror is
configured — the second source's `SHA256SUMS` has to agree.

* **With `CODEBERG_USERNAME` set:** two independent sources are compared. A
  single compromised or half-pushed mirror is caught, and the update is
  refused if they disagree.
* **Without it:** the file is verified against GitHub only. That is stated out
  loud — the menu shows a "Config Warnings" entry saying so — rather than
  quietly downgrading the guarantee.

Downloads use HTTPS with TLS 1.2 enforced. Modifying the installed scripts
yourself will trip the checksum comparison and show a toolkit-update prompt.

### App replacement

Off by default (`AUTO_INSTALL_APPS=0`); turn it on under **Settings →
Updates**.

<!-- Image 5.2 : img/app_settings_updates.png (not yet captured; delete this comment wrapper once the file exists)
<p align="center">
  <img src="img/app_settings_updates.png" alt="Settings › Updates" width="100%">
  <br><sub>The App Store, cleanup and automatic-installation switches, the warning next to automatic installation, and the update channel picker.</sub>
</p>
-->

When enabled, replacing an app bundle passes through
[lib/app_install.sh](lib/app_install.sh), where every check must pass before
anything is written:

1. **Team ID match** — the downloaded bundle's `TeamIdentifier` must equal the
   installed one's. An unsigned installed app has nothing to compare against,
   so it is never replaced.
2. **Code signature** — `codesign --verify` on the download.
3. **Gatekeeper** — `spctl -a -t open`. Rejects anything not signed for
   distribution and notarised.
4. **Sparkle EdDSA** — verified when the app publishes an `SUPublicEDKey` and
   the feed carries a signature. A signature that does not match is fatal; a
   missing key or signature is reported as not checked, not as a pass.
5. **Version match** — the bundle must be the version the feed advertised.

Only `.dmg` and `.zip` are accepted. **`.pkg` is refused outright**: it runs
preinstall/postinstall scripts as root, which can neither be sandboxed nor
rolled back. The old bundle is moved aside rather than deleted and is restored
on any error. Every install also offers a **Dry run** that performs the
download and all signature checks without modifying anything.

## Uninstalling

There are two ways to do this, and they run the same code.

### From the app

**Settings › Uninstall** lists everything the toolkit put on this Mac, one
tick box per item, with the exact path each one would remove. Tick what should
go, press **Remove Selected**, confirm once. There is a **Dry run** first, the
same as everywhere else in the toolkit: it reports what each ticked item would
remove and removes nothing.

The page runs `uninstall.sh` with the ticked steps as flags, which turns its
questions off — the choosing already happened in the UI. Two things it does in
Swift rather than through the script, because only the running app can make
them stick: switching off the `SMAppService` login item, and dropping the
in-memory copy of the preferences that would otherwise be written back out on
quit.

If `uninstall.sh` is not on the Mac at all — the app was dragged out of the
disk image and `setup_mac.sh` never ran — the page says so and offers to move
the app to the Trash and clear its preferences, which is all there is to
remove in that case.

### From the terminal

`setup_mac.sh` places an uninstaller in the application support folder:

```zsh
~/Library/Application\ Support/MacSoftwareUpdater/uninstall.sh
```

Run with no arguments it asks before each of five steps:

1. **The app** — removes `/Applications/MacUpdaterGuide.app`, reading its
   bundle identifier from the bundle first so step 4 still works.
2. **Login item** — removes legacy LaunchAgents and System Events login
   items. The app itself registers through `SMAppService`, which can only be
   turned off inside the app or in System Settings, so the script offers to
   open that pane.
3. **Data and configuration** — deletes
   `~/Library/Application Support/MacSoftwareUpdater`.
4. **App preferences** — `defaults delete` for the bundle identifier read in
   step 1.
5. **Optional dependencies** — offers to uninstall `mas`, behind its own
   confirmation. It is the only package the toolkit installs for itself.
   Homebrew is left alone: it is a system-wide package manager holding
   unrelated software, so removing it is not this uninstaller's job. The
   script says so and points at Homebrew's own instructions.

Named steps run without any questions, which is how the app drives it:

```zsh
uninstall.sh --list                  # what is present, one line per step
uninstall.sh --app --data            # remove exactly these two, ask nothing
uninstall.sh --all --dry-run         # report everything, remove nothing
uninstall.sh --help                  # every flag
```

Each named step prints one `RESULT|step|outcome|detail` line, and `--list`
prints one `ITEM|step|yes|no|detail` line, so a caller can report per-step
results rather than guessing from an exit code.

## Development

The workflow lives in its own documents rather than here, so there is one copy
of each rule to keep current. [CONTRIBUTING.md](CONTRIBUTING.md) is the whole of
it: installing your working tree with `--local`, running both test suites, the
version and checksum rule, what CI's four jobs check, and the four places a
cache-format change has to reach. Pull requests go against `main`.

* **[CONTRIBUTING.md](CONTRIBUTING.md)** — setup, tests, shell style, the
  version/checksum rule, CI, branches and pull requests.
* **[GuideApp/README.md](GuideApp/README.md)** — the SwiftUI app on its own:
  building it with `run.sh`, the page-to-view map, and the Debug page.
* **[CACHE_FORMAT.md](CACHE_FORMAT.md)** — the file contract the engine and the
  app both have to agree with.
* **[CHANGELOG.md](CHANGELOG.md)** — what changed in each release.

## Known limitations

* **Apple's own apps** (iMovie, GarageBand and friends) are often invisible to
  the `mas` CLI. They can be monitored, but the update itself has to be done in
  the App Store.
* **iPad/iPhone apps running on Apple Silicon** are invisible to this tool.
  That is a limitation of `mas`, not of the toolkit.
* **Setapp** — anything under `/Applications/Setapp/` is skipped entirely.
  Setapp ships its own updater and replacing those bundles breaks it.
* **`.pkg` downloads cannot be installed.** Only `.dmg` and `.zip`; a `.pkg`
  always opens the publisher's page instead.
* **Apps signed with a plain "Apple Development" certificate** — common for
  small open-source projects — are rejected by Gatekeeper and have to be
  installed by hand. That is the intended outcome, not a bug to work around.
* **The `develop` update channel** is selectable but that branch is not
  currently published.

## License

MIT — see [LICENSE](LICENSE).
