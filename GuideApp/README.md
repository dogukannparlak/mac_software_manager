# MacUpdaterGuide

The native SwiftUI half of [Mac Software Manager](../README.md). It owns the
menu bar item, reads the zsh engine's cache and drives the engine by invoking
its subcommands. The engine does all the work; this app is the interface on
top of the files it writes.


## Requirements

**macOS 14.0 or later** — `MACOSX_DEPLOYMENT_TARGET = 14.0` in
`MacUpdaterGuide.xcodeproj/project.pbxproj`, `.macOS(.v14)` in
[Package.swift](Package.swift). Builds as a universal binary (Apple Silicon and
Intel).

Xcode is needed to build the app bundle; `swift test` alone needs only the
toolchain.

## Building and running

Open the project and press **⌘R**:

```bash
open MacUpdaterGuide.xcodeproj
```

Or use [run.sh](run.sh), which keeps `xcodebuild`'s output quiet unless the
build actually fails:

| Command | Effect |
| --- | --- |
| `./run.sh` | Build Debug and launch. |
| `./run.sh -n` | Launch what is already built, no rebuild. |
| `./run.sh -r` | Build Release instead of Debug. |
| `./run.sh --install` | Build Release and copy into `/Applications`. |
| `./run.sh --clean` | Remove `DerivedData/` first. |

It stops any running copy before launching, so you never end up with two menu
bar icons. Login items only work reliably from `/Applications`, so use
`--install` if you want Settings → General → Open at login.

## Pages

| Sidebar entry | View |
| --- | --- |
| **Updates** | `Views/UpdatesView.swift` — everything pending, grouped by source, with per-row actions and a Check Homebrew button. |
| **Installed Apps** | `Views/InstalledAppsView.swift` — every application with its origin, filterable, with a per-app "…" menu. |
| **CLI Tools** | `Views/CLIToolsView.swift` — every Homebrew formula, categorized via `brew leaves` + `brew desc` (`Toolkit/CLIToolCategory.swift`). |
| **History** | `Views/HistoryView.swift` — the last 7 or 30 days, failures marked. |
| **Guide** | `Views/TopicDetailView.swift`, content in `Content/GuideContent*.swift` — one sidebar row per topic. |
| **Settings** | `Views/SettingsPages.swift` — eight sections: General, Updates, Tracked Apps, Name Mapping, Move to Homebrew, Ignored Apps, Advanced, About. |
| **Debug** | `Views/Debug/` — hidden; see below. |

`Views/MenuBarView.swift` is the menu bar panel, deliberately read-only.
`Views/MigrateToHomebrewPage.swift` is the Move to Homebrew settings page.

The `Toolkit/` directory is everything that talks to the engine: cache parsers
(`UpdateSnapshot`, `InstalledApps`, `UpdateProgress`, `ItemRunResult`,
`MigrationCandidate`, `EngineContract`), the process layer
(`ToolkitRunner+*.swift`), and the paths themselves (`ToolkitPaths`).

## Tests

```bash
swift test --package-path .      # from this directory
swift test --package-path GuideApp   # from the repository root
```

The suite covers the cache parsers, the settings key mapping and the Debug
page's fixture generators — the fixtures are round-tripped against the real
parsers, so a format change that reaches only one side fails here.

## The Debug page

A hidden page for driving every screen, state and engine output by hand, without
waiting on `brew`, `mas` or the network.

* **DEBUG build:** always in the sidebar.
* **Release build:** turn it on at the bottom of **Settings › Advanced** with
  **Show the Debug page**, which adds a **Developer** section to the sidebar.

It is at the bottom of the last settings page deliberately — it is somewhere you
go looking for, not somewhere you pass through — and some of what it offers
starts real updates.

Its State panel does not mock anything. It produces a UI state by writing the
same files the app normally reads, under
`~/Library/Application Support/MacSoftwareUpdater` — the cache, the notification
queue, the run results and the hand-edited config files. What you see afterwards
is the real code path reading real files; only the contents are fake.

That is what makes the backup contract the important part. Nothing is ever
overwritten without a backup landing beside it first, as a sidecar file rather
than a copy held in memory — the failures worth testing are the ones where the
app is quit or crashes mid-injection, and a restore that only works while the
process that made the mess is still running is not a restore. There are two
sidecars and never both, so *"there was no file here"* is recorded as explicitly
as *"here is what was here"*:

| Sidecar | Meaning | What restore does |
| --- | --- | --- |
| `<name>.debugbackup` | A real file was displaced | Copies it back |
| `<name>.debugbackup.none` | There was no file here | Deletes the fake |

The event directories (`notifications/`, `results/`) are never overwritten at
all. Injection only ever *adds* a file there, named with a `.debug.` marker so
cleanup deletes exactly what the page created and nothing a real run left
behind. [CACHE_FORMAT.md](../CACHE_FORMAT.md) states outright that those file
names carry no meaning and that readers must not parse them, which is what makes
that safe.

**Restore all real state** therefore works from the disk alone: it scans the
four directories for sidecars and `.debug.` markers rather than consulting
anything held in memory, so it recovers just as well after a relaunch — or after
a crash — as it does a second after the injection. For the same reason the
warning strip at the top of the page is driven by a disk scan, not by a flag set
on write: state left injected by an earlier launch raises the warning the moment
the page is opened. The failure this page has to avoid is somebody debugging
fake state for an hour without knowing it is fake.

Nothing inside the page is localized, on purpose. Its labels name Swift
properties, cache keys and shell verbs — `brew_outdated`, `run single`,
`EngineContract.supportsMigration` — each of which has exactly one spelling, here
and in [CACHE_FORMAT.md](../CACHE_FORMAT.md). The two strings a non-developer
could meet, the sidebar entry and the settings toggle, are translated like
everything else.

## The cache contract

The engine and this app never import each other's parsers.
[CACHE_FORMAT.md](../CACHE_FORMAT.md) is the single place both are required to
agree with. Change a format and you change the writer, every reader on both
sides, `Views/Debug/DebugFixtures.swift`, and that document — in one commit.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full workflow.
