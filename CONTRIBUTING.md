# Contributing

Two codebases in one repository: a zsh engine (`update_system.1h.sh`,
`lib/*.sh`, `setup_mac.sh`, `uninstall.sh`) and a SwiftUI app (`GuideApp/`).
They talk to each other only through the files documented in
[CACHE_FORMAT.md](CACHE_FORMAT.md).

## Development setup

Clone the repository and install your working tree with `--local`:

```bash
./setup_mac.sh --local
```

**Why the flag exists.** Without it, `setup_mac.sh` downloads every file it
installs and verifies it against the published `SHA256SUMS` before putting it
in place, falling back to the copy next to the installer only when no verified
remote source can be reached. That is correct for a user and wrong for you: run
the plain installer from a checkout with unpushed fixes and the *published*
copy wins — it downloads, verifies fine, and is written straight over your
local changes.

With `--local` the download and checksum step is skipped entirely, and
`update_system.1h.sh`, all eleven `lib/*.sh` files and `uninstall.sh` are
copied from the directory the script itself lives in. Everything else about the
run — the migration wizard, the prompts, the SwiftBar setup — is unchanged.

It says so out loud and prints one line per file confirming that verification
was deliberately disabled — in this mode a file's provenance is "whatever is in
this working tree", which no published checksum can describe.

## Running the tests

```bash
bats tests/                          # 271 shell tests (brew install bats-core)
swift test --package-path GuideApp   # 282 XCTest cases
```

The bats suite does not need an installed toolkit. It points `MSU_LIB_DIR` at
the checkout's `lib/` so the engine loads the modules you are editing:

```bash
MSU_LIB_DIR="$PWD/lib" ./update_system.1h.sh          # render the menu from this checkout
MSU_LIB_DIR="$PWD/lib" ./update_system.1h.sh run all  # or drive a real run
```

CI does the same thing when it checks that a menu render works against an empty
`HOME` without touching the network.

## Shell style

Every shell file here is **zsh**, not bash — `${0:a:h}`, `typeset -a`,
`(N)` glob qualifiers, `zstat` and `EPOCHSECONDS` all appear in the engine.

The test suite sources the engine from a **zsh subprocess**, never with a bash
`source`. `update_system.1h.sh` guards the top of its dispatcher (section 5) on
`$ZSH_EVAL_CONTEXT`, so being sourced loads the functions without triggering a
run. A bash `source` of a zsh-syntax file fails on the syntax before it reaches
any of that. Follow the existing pattern in `tests/test_helper.bash` rather
than inventing a second one.

CI parses every script with `zsh -n` before anything else runs, so a syntax
error fails the build immediately.

## Version and checksum rule

`VERSION` is the single source of truth. The scripts are distributed
standalone — the plugin is one file in the SwiftBar plugin directory — so each
one embeds its own copy of the version string, and self-update refuses to
install anything whose SHA-256 is not in the published `SHA256SUMS`.

After changing `setup_mac.sh`, `uninstall.sh`, `update_system.1h.sh` or any
`lib/*.sh`:

```bash
./tools/sync_version.sh          # propagate VERSION into every file carrying one
./tools/generate_checksums.sh    # regenerate SHA256SUMS
```

Commit the result **in the same commit as the change**. A stale `SHA256SUMS`
does not fail loudly at runtime — it silently freezes every installed copy,
because self-update will not install a file it cannot verify. Both tools take
`--check` to report drift without writing, which is exactly what CI runs.

`sync_version.sh` propagates the string into `update_system.1h.sh`,
`setup_mac.sh`, `uninstall.sh`, the version badge in `README.md` and
`README.tr.md`, and *both* build configurations in `project.pbxproj` — it
asserts an exact count of two there, so a half-updated project file cannot look
in sync. If you move or reword those badges, update the matching `apply` call in
the same commit or the CI version step fails.

## Building a release

```bash
./tools/build_release.sh          # dist/ gets the .dmg, the .zip and SHA256SUMS.txt
./tools/build_release.sh --clean  # empty dist/ first
```

It refuses to build a tree whose version strings or `SHA256SUMS` are out of
date (the two `--check` runs above), builds Release for `arm64 x86_64` and
fails if `lipo` says the result is not universal, then packages the same `.app`
twice: a `.dmg` with an `/Applications` symlink to drag onto, and a `.zip` for
the smaller download. `ditto` does both, because `zip` breaks the code
signature and an app with a broken signature will not open.

The signature is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), not a Developer ID, which
is why the README tells people to right-click → Open the first time.

`dist/` is gitignored. Its contents are uploaded to the GitHub release, never
committed.

## CI

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on pushes to `main`
and to `feature/**` / `fix/**`, on pull requests targeting `main`, and on
manual dispatch. Four jobs:

| Job | Runner | Blocking? | What it does |
| --- | --- | --- | --- |
| **Syntax, versions and checksums** | macOS | **Yes** | `zsh -n` over every script; `sync_version.sh --check`; `generate_checksums.sh --check`; a menu render against an empty `HOME` with `MSU_LIB_DIR` set, asserting the output contains `Refresh now` (proves the render neither hits the network nor hangs); then `bats tests/`. |
| **Swift unit tests (GuideApp)** | macOS | **Yes** | `swift test --package-path GuideApp`. |
| **shellcheck (advisory)** | Ubuntu | **No** — `continue-on-error: true` | Runs shellcheck as bash. There is no zsh mode, so it flags genuine quoting problems *and* zsh-only syntax. Read it, do not obey it blindly. |
| **SwiftLint** | macOS | **Only on errors** | `.swiftlint.yml` draws the line: a line over 200 characters or a type body over 400 lines is an error and fails the job. The warning tier (150 / 300, `file_length`, `identifier_name` and the rest) is reported and passes — there is no `--strict`. The error count is at zero; keep it there. |

## Changing a cache format

The engine writes the files under
`~/Library/Application Support/MacSoftwareUpdater/`; the app reads them
independently, and neither side imports the other's parser. Nothing catches a
mismatch for you.

A format change reaches **four** places in one commit:

1. The **writer** — `lib/cache.sh`, `lib/updaters.sh`, `lib/selfupdate_apps.sh`
   or `lib/migrate.sh`, depending on the file.
2. Every **shell reader** — `brew_outdated` alone has four consumers of its raw
   field positions besides the writer (see the lockstep list in
   [CACHE_FORMAT.md](CACHE_FORMAT.md)).
3. The **Swift reader** — `Toolkit/UpdateSnapshot.swift`,
   `UpdateProgress.swift`, `ItemRunResult.swift`, `MigrationCandidate.swift`,
   `EngineContract.swift` or `InstalledApps.swift`.
4. `Views/Debug/DebugFixtures.swift`, which is a second writer: the Debug page
   generates fixtures in most of these formats, and its generators are
   round-tripped against the real parsers in `DebugFixturesTests.swift`.

Then update [CACHE_FORMAT.md](CACHE_FORMAT.md) itself. `tests/cache_format.bats`
and `UpdateProgressParsingTests.swift` assert against the same canonical example
lines, so a change on one side that the other does not match fails a test on
whichever side is stale.

If a reader becomes entitled to something an older engine never wrote, bump
`ENGINE_CONTRACT` in `lib/cache.sh` — and bump `EngineContract.required` (or
`migrationContract`) only in the commit that actually starts depending on it.
Those are two different edits, and only the second is a promise the app makes.

## Branches and pull requests

`origin` carries `main` and `feature/debug-page`. **There is no `develop`
branch** — despite the `Beta (Develop)` option the engine's update-channel
dialog still offers.

* Branch off `main` as `feature/<name>` or `fix/<name>`. CI runs on both globs,
  so the full suite goes green before you ever open a pull request.
* Open the pull request against `main`. CI's `pull_request` trigger filters on
  the branch a PR *targets*, so only `main` is watched.
* Keep version and checksum regeneration in the same commit as the change that
  needs it.

[.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) fills the
description in for you; every box on it is one of the rules above, and CI
checks all of them. Bug reports and feature requests have templates too, under
[.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/) — the bug one asks for both
version strings, because the engine and the app ship separately and a mismatch
between them is its own failure mode. Security problems do not go in an issue;
see [SECURITY.md](SECURITY.md).

## Documentation

* [CACHE_FORMAT.md](CACHE_FORMAT.md) — the contract between the two halves.
* [SECURITY.md](SECURITY.md) — verification chains and how to report a
  vulnerability.
* [GuideApp/README.md](GuideApp/README.md) — the app on its own.
* [CHANGELOG.md](CHANGELOG.md) — Keep a Changelog format; add an entry under
  `Unreleased` for anything a user would notice.
* `README.md` and `README.tr.md` are kept structurally identical, section for
  section, so they can be updated together. Change one, change the other.
