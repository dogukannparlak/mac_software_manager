<div align="center" markdown="1">

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Last Commit](https://img.shields.io/gitea/last-commit/dogukannparlak/mac_software_manager?gitea_url=https%3A%2F%2Fcodeberg.org&label=last%20update&color=blue)](https://codeberg.org/dogukannparlak/mac_software_manager/commits/branch/main)
[![Version](https://img.shields.io/badge/version-1.5.0-blue)](https://codeberg.org/dogukannparlak/mac_software_manager/releases)

![Platform](https://img.shields.io/badge/macOS-12%2B-blue?logo=apple&logoColor=white)
![Zsh](https://img.shields.io/badge/shell-Zsh-blue?logo=gnu-bash&logoColor=white)
![Homebrew](https://img.shields.io/badge/needs-Homebrew-blue?logo=homebrew&logoColor=white)
![SwiftBar](https://img.shields.io/badge/GUI-SwiftBar-blue?logo=swift&logoColor=white)

![Sources](https://img.shields.io/badge/sources-GitHub_%26_Codeberg-blue?logo=git&logoColor=white)
![Maintenance](https://img.shields.io/badge/maintenance-automated-blue?logo=robot-framework&logoColor=white)

</div>

# Mac Software Manager

Mac Software Manager is a targeted automation tool designed to bring order to your macOS environment. This project combines **Homebrew**, **Mac App Store CLI (mas)**, and **SwiftBar** to solve two specific problems:

1. **Migration:** Moving manually installed applications under the control of package managers (App Store or Homebrew).
2. **Updates:** Monitors updates from the menu bar and applies them via a single terminal command.

> **⚠️ Note to Contributors & Testers**
>
> * **Pull Requests:** Please submit all changes to the **`develop`** branch. The `main` branch is reserved for stable releases.
> * **Upcoming Features:** Want to try the latest version before it's released? Switch to the `develop` branch to see what's next.

## 🚀 Key Features

* **Fail-Safe Migration:** Safely converts "Drag & Drop" apps to Homebrew Casks or App Store versions without data loss.
* **Menu Bar Dashboard:** Detailed breakdown of Casks, Formulae, and Store apps (with version numbers).
* **One-Click Update:** Runs `brew upgrade` and `mas upgrade` in the background by default, with progress shown right in the app — no terminal window unless you turn one on in Settings.
* **Built-in Uninstaller:** A dedicated script to safely remove the toolkit and its logs.
* **Smart History:** Tracks how many updates you've installed over the last 7 and 30 days.
* **Apple Silicon Ready:** Works natively on M1/M2/M3 and Intel Macs.
* **Resilient Updates:** Features a smart failover system that automatically switches to a backup server (Codeberg) if GitHub is unreachable.
* **Granular Control:** Easily ignore (pin) specific updates directly from the menu if you need to stay on an older version.
* **Modular Updates:** Optional App Store support. Enable or disable mas updates globally if you prefer to manage Store apps manually.
* **Self-Updating Apps:** Detects new releases for apps managed by neither Homebrew nor the App Store, via their Sparkle appcast or GitHub releases feed. Detection only — the menu links to the publisher's download.
* **Instant Menu:** All data is cached and refreshed in the background, so opening the menu never waits on Homebrew or the network.
* **Verified Self-Update:** The toolkit only replaces itself after the download matches the published `SHA256SUMS` on **both** GitHub and Codeberg.
* **Honest History:** Updates that fail are recorded as failed instead of being counted as successes.
* **Verified App Replacement (opt-in):** For apps with a direct DMG/ZIP download, the toolkit can install the update itself — but only after the developer's Team ID matches, the signature verifies, Gatekeeper accepts it and (where published) Sparkle's EdDSA signature checks out. Off by default; enable under **Settings → Updates**.
* **Native App, Two Languages:** A SwiftUI app provides the menu bar item, a full update list with app icons, an inventory of everything installed and where it came from, update history, and settings — in English and Turkish, switchable without relaunching.
* **Live Progress:** A progress bar in the app tracks every phase of an update — refreshing Homebrew, upgrading packages, cleaning up — and names the package currently being installed. Visible in the menu bar and on the Updates page, whether the update is running in the background or in a terminal.
* **Official Links, Verified Automatically:** Detects each app's official website and GitHub repository from data it already has — a Homebrew cask's declared homepage and download URL, a GitHub repo's own homepage field — never guessed. Wrong or missing links can be corrected per app, purely locally.
* **One Menu Per App:** Every row on the Installed Apps page has a "…" menu with everything for that app — open its links, correct them, fix how it is tracked for updates, remap it to a Homebrew cask, ignore it — no more hunting through separate settings pages.
* **Manual Homebrew Check:** A dedicated "Check Homebrew" action pulls the latest Homebrew and tap metadata (`brew update`) on demand, the same way the Updates page lets you re-check individual apps.

## ⚙️ How It Works

This is not a generic maintenance utility. It is a small engine with a native interface on top:

* The **shell toolkit** knows how to talk to Homebrew, the App Store, Sparkle feeds and GitHub releases. It does all the work and writes what it finds to a cache.
* The **SwiftUI app** (`GuideApp/`) reads that cache and drives the toolkit. It owns the menu bar item, so **SwiftBar is no longer required** — though the plugin still renders in SwiftBar if you prefer it.

### 1. Migration Wizard (`setup_mac.sh`)

Run via terminal, this script scans your `/Applications` folder to detect unmanaged software. For every app found, it checks if a matching version exists in Homebrew or the App Store.

* **Installation:** It can reuse your Homebrew and other tools, but if you don't have them, they will be installed
* **Verification:** Distinguishes between System apps, Homebrew apps, and manually downloaded apps. It will only migrate unmanaged versions
* **The Decision:** For every "unmanaged" app (e.g., Spotify or Chrome installed manually), it asks you for an action (depending on availability):
  * **[A]pp Store:** Replaces the manual version with the official App Store version.
  * **[B]rew Cask:** Replaces the manual version with a Homebrew Cask (preserving settings).
  * **[L]eave:** Keeps the app exactly as it is.
* **🛡️Safety First:** Before any migration, it creates a local backup (`.app.bak`). If the new installation fails (network error, hash mismatch) it automatically restores the original application. Only removes the backup if the installation was 100% successful.

### 2. Update Engine (`update_system.x.sh`)

The part that knows how things actually get updated.

* **Status:** Collects pending updates from Homebrew, the App Store, Sparkle appcasts and GitHub release feeds, and caches the result so nothing has to wait on the network to see it.
* **Action:** Runs `brew upgrade` and `mas upgrade` in a terminal window you can watch and stop, followed by an optional cleanup.
* **Verification:** After a run it re-checks each package and records the real outcome, so a failed update is never logged as a success.
* **Progress:** Writes what it is doing right now — including the package currently being installed — so the interface can report it without taking the run away from the terminal.

It runs standalone: `./update_system.1h.sh run all` does a full update from a terminal, no app required. Run with no arguments it prints a SwiftBar plugin menu, which is how the toolkit worked before the app existed.

### 3. The App (`GuideApp/`)

A native SwiftUI app that puts a face on all of it. Open the Xcode project and run it.

* **Menu bar item:** Created by the app itself. Shows the pending count and, when a run is in flight, which package it is on. Deliberately read-only — a glance, not a control panel. Turn on **Settings → General → Menu bar only** to drop the Dock icon and live entirely up there.
* **Updates:** Everything waiting, grouped by source, with real app icons. Update one item or all of them, or hide something you want to stay behind on. A **Check Homebrew** button next to Refresh pulls the latest Homebrew metadata on demand. Updates run in the background with an in-app progress bar by default; a terminal window is opt-in.
* **Installed Apps:** Every application with its icon, version and **where it came from** — Homebrew, App Store, Setapp, Apple, or installed by hand. Filter by source, search, and see the Homebrew command line tools underneath. Each row's **"…" menu** opens its official website or GitHub page, and edits how that one app is tracked, mapped or linked — all local corrections, applied instantly.
* **History:** What was updated over the last 7 or 30 days, grouped by day, with failures marked rather than hidden.
* **Settings:** Part of the same window, not a separate panel. Language, check interval, Dock icon, open at login, whether updates run in a terminal (and which one), App Store support, cleanup, automatic installation, update channel, ignored apps, cache, and the engine location — plus full editors for the tracking rules and Homebrew name mapping, so no configuration ever needs a text editor. Everything is written straight into the toolkit's config files, so the app and the terminal never disagree.
* **Guide:** The whole feature guide built in, in English and Turkish, switchable without relaunching.

## 📸 Screenshots

<table width="100%">
  <tr>
    <td width="50%" align="center"><b>Main Menu Status</b><br>Overview of Homebrew and App Store updates</td>
    <td width="50%" align="center"><b>History</b><br>Submenu tracking update counts for the last 7 and 30 days</td>
  </tr>
  <tr>
    <td valign="top" align="center">
      <img src="img/menubar_monitor.png" alt="Main View" height="400">
    </td>
    <td valign="top" align="center">
      <img src="img/menubar_monitor_history.png" alt="History" weight="400">
    </td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Monitored apps</b><br>Submenu showing numbers of monitored apps</td>
    <td width="50%" align="center"><b>Managed Apps List</b><br>Submenu showing details of monitored apps</td>
  </tr>
  <tr>
    <td valign="top" align="center">
      <img src="img/menubar_monitor_details.png" alt="Formulae Details" width="100%">
    </td>
    <td valign="top" align="center">
      <img src="img/menubar_monitor_managed_apps.png" alt="Managed Apps List" width="100%">
    </td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Preferences</b><br>Change Update Frequency, disable or force</td>
    <td width="50%" align="center"><b>Migration tool</b><br>CLI Tool</td>
  </tr>
  <tr>
    <td valign="top" align="center">
      <img src="img/menubar_preferences.png" alt="Main View" width="100%">
    </td>
    <td valign="top" align="center">
      <img src="img/migration_utility.png" alt="History" width="100%">
    </td>
  </tr>
</table>

### Menu Bar States

| Status                  | Icon Appearance | Description                                |
| :---------------------- | :-------------- | :----------------------------------------- |
| **Up to Date**    | <img src="img/menubar_icon_everything_updated.png?v=2" height="24" alt="Everything Updated"> | System is clean, checkmark icon displayed. |
| **Updates Ready** | <img src="img/menubar_icon_update_ready.png?v=2" height="24" alt="Updates Ready"> | Badge with update count and red sync icon. |
| **Plugin Update** | <img src="img/menubar_icon_plugin_update.png" height="24" alt="Plugin Update"> | New version of the toolkit is available.   |

### Preferences & Control

Manage the plugin behavior directly from the menu.

| Feature                    | Description                                                                                                                                                                                                   |
| :------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Update Frequency** | Toggle check intervals:`1h`, `2h`, `6h`, `12h`, or `1d`.                                                                                                                                            |
| **Terminal App**     | Choose preferred terminal:`Terminal`, `iTerm2`, `Warp`, `Alacritty`, or `Ghostty`.                                                                                                                  |
| **Self-Update**      | Check for updates. Verified against GitHub, plus your configured Codeberg mirror if you set one (see`CODEBERG_USERNAME` below) - GitHub only otherwise, and the menu shows a warning when no mirror is set. |
| **Update Channel**   | Switch between`Stable (Main)` and `Beta (Develop)` releases instantly.                                                                                                                                    |
| **App Store**        | Toggle`mas` integration on/off directly from the menu.                                                                                                                                                      |

## 🛠 Quick Start

### 1. Run the Installer

The fastest way to start is to run this command in your Terminal. It downloads and triggers the migration wizard:

**Option A: Standard Install (GitHub)**

```bash
curl -L https://github.com/dogukannparlak/mac_software_manager/releases/download/v1.5.0/Installer.zip -o Installer.zip && unzip -q Installer.zip && cd mac_software_manager && chmod +x setup_mac.sh && ./setup_mac.sh
```

**Option B: Emergency Mirror (Codeberg)**

```bash
zsh -c "$(curl -fsSL https://codeberg.org/<your-codeberg-username>/mac_software_manager/raw/branch/main/setup_mac.sh)"
```

> Option B only works once you've pushed this repo to your own Codeberg account and substituted `<your-codeberg-username>` above. `setup_mac.sh` will then ask for that same username and save it as `CODEBERG_USERNAME` in `settings.conf` - every download and self-update check from that point on verifies against **both** GitHub and Codeberg, and refuses to install a plugin update if the two disagree. Leave the prompt blank to skip the mirror entirely; downloads still work, verified against GitHub only, and the menu shows a "Config Warnings" entry saying so rather than silently downgrading the guarantee.

### 2. Follow the Wizard

The script will prompt you on how to handle detected applications. You can choose to migrate them or skip the process entirely.

### 3. Finish

Once completed, the update engine is installed and configured.

> **Important:** If macOS asks for permission to access your Documents folder, click **Allow**. This is required to write and read the plugin file.

### 4. Build the app (optional but recommended)

```bash
open GuideApp/MacUpdaterGuide.xcodeproj
```

Press **⌘R**. Or, from a terminal, without opening Xcode:

```bash
cd GuideApp && ./run.sh          # build (Debug) and launch
cd GuideApp && ./run.sh -n       # launch what is already built, no rebuild
cd GuideApp && ./run.sh --install  # build Release and copy into /Applications
```

The app adds its own menu bar item and gives you the update list, the installed-app inventory, history and settings. Turn on **Settings → General → Open at login** so the menu bar item is always there. Login items only work reliably when the app lives in `/Applications`, so use `--install` if you want that.

The app finds the engine automatically in the SwiftBar plugin folder or in
`~/Library/Application Support/MacSoftwareUpdater/`. If you keep it somewhere
else, point at it under **Settings → Advanced**.

If you would rather not use the app at all, everything still works from a terminal:

```bash
~/Library/Application\ Support/MacSoftwareUpdater/update_system.1h.sh run all
```

---

## 📦 Tools Used

This toolkit acts as the "glue" integrating standard macOS power-user tools:

* **[Homebrew](https://brew.sh)** – The primary package manager. Used to install and update the majority of applications.
* **[mas-cli](https://github.com/mas-cli/mas)** – Command-line interface for the Mac App Store. Allows updating Store apps without opening the GUI.
* **[SwiftBar](https://swiftbar.app)** – *Optional.* The engine still renders a SwiftBar plugin menu when run with no arguments, for anyone who already uses SwiftBar. The bundled app provides its own menu bar item and does not need it.
* **Sparkle appcasts & GitHub release feeds** – Read directly (via `xsltproc`) to catch apps that neither Homebrew nor the App Store manages.

---

## 🗑️ Uninstallation

If you decide to remove the toolkit, an uninstaller script is automatically placed in your application support folder during setup.

To uninstall:

1. Open **Terminal**.
2. Run the following command:

```zsh
~/Library/Application\ Support/MacSoftwareUpdater/uninstall.sh
```

---

## 🗂 Configuration Files

All live in `~/Library/Application Support/MacSoftwareUpdater/`.

| File                   | Purpose                                                                                                                                                                |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `settings.conf`      | Terminal choice, App Store on/off, update channel, autostart, cleanup on/off. Re-running`setup_mac.sh` preserves these.                                              |
| `ignored_apps.conf`  | Apps hidden from the update list (`type\|id\|name`). Managed from the menu.                                                                                            |
| `tracked_apps.conf`  | How individual apps are checked for updates. Edited from**Settings → Tracked Apps**, or per app from its "…" menu — no need to open it by hand.               |
| `app_token_map.conf` | Manual app name → Homebrew cask token mapping. Edited from**Settings → Name Mapping**, or per app from its "…" menu.                                          |
| `app_links.conf`     | Corrections to an app's detected website / GitHub repository. App-only — the shell engine never reads it. Edited per app from its "…" menu (**Edit Links…**). |
| `cache/`             | Cached update data. Safe to delete; it is rebuilt automatically.                                                                                                       |

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
cask name by hand, so it will match on the next run. Editable the same two
ways as `tracked_apps.conf` above — the app list, or **Edit Homebrew
Mapping…** on the one app.

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

## 🧑‍💻 Development

### Installing your working tree (`--local`)

`setup_mac.sh` normally downloads every file it installs and verifies it
against `SHA256SUMS` before putting it in place, falling back to the copy next
to the installer only when no verified remote source can be reached. That is
what you want as a user — and exactly what gets in the way while developing.
Run the plain installer from a checkout with unpushed fixes and the *published*
copy wins: it downloads, verifies fine, and is written straight over your local
changes.

Use `--local` for that case:

```bash
./setup_mac.sh --local
```

With the flag, the download and checksum step is skipped entirely and
`update_system.1h.sh`, all ten `lib/*.sh` files and `uninstall.sh` are copied
from the directory the script itself lives in. Everything else about the run —
the migration wizard, the prompts, the SwiftBar setup — is unchanged.

The verification is not skipped quietly. A `--local` run says so up front and
prints one line per file confirming that the checksum check was deliberately
disabled, because in this mode a file's provenance is "whatever is in this
working tree", which no published checksum can describe.

Without the flag, behaviour is byte-for-byte what it has always been: remote
first, local copy only as a fallback. `./setup_mac.sh --help` describes both.

When you are ready to push, regenerate the checksums — see the **For
contributors** note under [Notes](#-notes); installed copies refuse to
self-update against a stale `SHA256SUMS`.

## 📝 Notes

> **Important:** Since this script uses checksums to detect updates, modifying the code (e.g., changing icons) will trigger a "Plugin Update Available" alert. If you customize the script, please go to Preferences → Disable Self-Update to prevent your changes from being overwritten.
>
> **Limitation:** Apple-native apps (e.g., iMovie) are often invisible to the mas CLI. While this plugin provides a workaround to monitor these "Ghost Apps," the actual update must be performed manually in the App Store.
>
> **Known Issue:** Apps running as iPad/iPhone wrappers on Apple Silicon are invisible to this tool. This is a limitation of the upstream `mas` command-line utility used for App Store interactions.
>
> **Setapp:** Applications under `/Applications/Setapp/` are skipped entirely. Setapp ships its own updater and replacing those bundles breaks it.
>
> **App installation limits:** Only `.dmg` and `.zip` downloads can be installed automatically. A `.pkg` runs installer scripts as root, which can neither be contained nor rolled back, so it always opens the publisher's page instead. Every install has a **Dry run** option that performs the download and all signature checks without modifying anything. Apps signed with a plain "Apple Development" certificate — common for small open-source projects — are refused by Gatekeeper and must be installed by hand.
>
> **For contributors:** `VERSION` is the single source of truth for the version number, and the runtime scripts are verified against `SHA256SUMS` before any self-update. After changing `setup_mac.sh`, `uninstall.sh` or `update_system.1h.sh`, run `./tools/sync_version.sh` and `./tools/generate_checksums.sh` and commit the result — otherwise installed copies will refuse to update themselves. CI checks both.

## License

MIT License.
