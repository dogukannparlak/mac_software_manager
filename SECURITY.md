# Security

## Reporting a vulnerability

**Do not open a public GitHub issue for a security problem.**

1. **Preferred:** open a private report through GitHub Security Advisories —
   [Report a vulnerability](https://github.com/dogukannparlak/mac_software_manager/security/advisories/new).
2. **If that is unavailable or you get no reply:** email
   <dogukannparlak@gmail.com>.

Include what you did, what happened, and which version you were on
(`~/Library/Application Support/MacSoftwareUpdater/update_system.1h.sh` carries
its version in the `<bitbar.version>` header; the app shows it under
Settings → About). A proof of concept helps but is not required.

This is a personal project with no SLA. Expect a first response measured in
days, not hours.

## Supported versions

Only the latest release is supported. `VERSION` is the single source of truth,
and installed copies self-update from `main`.

## What this toolkit actually verifies

Two things here can overwrite an executable on your Mac: the toolkit replacing
itself, and the toolkit replacing another application. Both are gated, and the
gates are different.

### Self-update (`lib/selfupdate.sh`)

Self-update overwrites a script that runs on every menu refresh, so nothing is
installed before it passes all of:

1. **Non-empty** — a zero-byte download is refused outright.
2. **Parses as zsh** — `zsh -n` on the downloaded file. A truncated or tampered
   script usually stops parsing, and this catches it before the file is ever
   executed.
3. **SHA-256 matches the publisher's `SHA256SUMS`** — fetched from the same
   source that served the file (`remote_expected_hash`). No entry for the file
   in that manifest is a refusal, not a pass.
4. **Both sources agree**, when a mirror is configured — see below.

Transport is HTTPS with `--proto '=https' --tlsv1.2` on every request.

**The mirror.** `setup_mac.sh` asks for a Codeberg username and stores it as
`CODEBERG_USERNAME` in `settings.conf`, which fills in `URL_BACKUP_BASE`.

* **Configured:** the file's hash is compared against the `SHA256SUMS`
  published by *both* GitHub and Codeberg. A single compromised or
  half-pushed mirror is caught, and a disagreement refuses the update.
* **Not configured:** the download is verified against GitHub alone. This is
  stated rather than hidden — the engine prints
  `No Codeberg mirror configured: <file> verified against GitHub only`, and the
  menu carries a "Config Warnings" entry. The guarantee is never silently
  downgraded.

The engine's `lib/*.sh` modules are downloaded and verified as one atomic set,
so a half-updated install — a new dispatcher over old libraries — is not a
state self-update can leave behind.

**Modifying the scripts yourself** changes their hash and will show a toolkit
update as available. That is the mechanism working, not a bug.

### Application replacement (`lib/app_install.sh`)

**Off by default.** `setup_mac.sh` writes `AUTO_INSTALL_APPS="0"` and only
carries a `1` forward if you had already turned it on. Enable it under
Settings → Updates. With it off, the toolkit detects updates for
self-updating apps and links you to the publisher's download; it installs
nothing.

With it on, `verify_app_replacement()` must pass every check before anything is
written to disk:

1. **Team ID match** — `TeamIdentifier` of the downloaded bundle must equal the
   installed one's. This is the check that actually proves provenance. If the
   *installed* app has no Team ID (unsigned, or Apple-internal) there is
   nothing to compare against, so it is never replaced.
2. **Code signature** — `codesign --verify` on the downloaded bundle.
3. **Gatekeeper** — `spctl -a -t open --context context:primary-signature`.
   This rejects anything not signed for distribution and notarised.
4. **Sparkle EdDSA** — when the installed app publishes an `SUPublicEDKey` and
   the feed carries a signature, the archive is verified against it with an
   OpenSSL 3 that supports raw ed25519. A signature that does not match is
   **fatal**. A missing key, missing signature or missing OpenSSL 3 is reported
   as *not checked* — never as a pass.
5. **Version match** — the bundle must be the version the feed advertised.

**Archive types.** Only `.dmg` and `.zip`. A **`.pkg` is refused outright**: it
runs preinstall/postinstall scripts as root, which can neither be sandboxed nor
rolled back, so the publisher's page is opened instead. ZIPs are unpacked with
`ditto -x -k`, which preserves the extended attributes and resource forks a
plain `unzip` mangles — a mangled bundle fails `codesign`.

**The swap.** `replace_app_bundle()` moves the existing bundle aside to
`<app>.msu-backup` rather than deleting it. If the copy fails, or the resulting
bundle looks incomplete (no `Contents/MacOS`), the backup is moved back and the
operation reports failure. The backup is removed only after the new bundle is
verifiably in place. The quarantine flag is cleared only after Gatekeeper has
already assessed the bundle.

Every install also offers a **dry run**, which performs the download and all
signature checks and changes nothing.

**Known refusal:** apps signed with a plain "Apple Development" certificate —
common for small open-source projects — are rejected by Gatekeeper and must be
installed by hand. That is the intended outcome, not a gap to work around.

### `sudo` policy

**A headless run never invokes `sudo`.** A background run has no tty and
nowhere to show a password prompt, so a prompt there would hang until it timed
out. `lib/migrate.sh` states this in its header and enforces it: a cask that
needs administrator rights — an installer script declaring `sudo`, or a target
under `/Library` — is reported as `needs-root` and the UI shows you the
`brew install --cask <token>` line to run yourself.

The only paths where escalation can happen are the ones with a terminal
attached: `setup_mac.sh` (you are sitting in front of it) and
`migrate_app_in_terminal`, which exists precisely so Homebrew can ask for a
password when it needs one to write over a root-owned bundle.

### File permissions

| Path | Mode | Set by |
| --- | --- | --- |
| `~/Library/Application Support/MacSoftwareUpdater/` | `700` | `setup_mac.sh`, re-asserted by `update_system.1h.sh` on every invocation |
| `settings.conf` | `600` | `setup_mac.sh`; re-applied when `change_branch` rewrites it |
| `app_token_map.conf` | `600` | `setup_mac.sh` |
| `tracked_apps.conf` | `600` | `lib/selfupdate_apps.sh` |

`settings.conf` is parsed with strict key matching, not sourced as shell — an
unexpected line in it cannot execute.

### Third-party installers

`setup_mac.sh` can install Homebrew itself, which means running a script from
`raw.githubusercontent.com`. Homebrew publishes no checksum to pin against, so
the baseline applied instead is: HTTPS with TLS 1.2 enforced, the download must
be non-empty, and it must parse as bash (`bash -n`) before it is executed.

`uninstall.sh` runs no remote script at all. It never removes Homebrew, so it
has nothing to download.

## Scope

In scope: the verification chains above, the config file handling, the
migration paths, and anything that can lead to code execution or an
unverified binary landing on disk.

Out of scope: vulnerabilities in Homebrew, `mas` or the applications
this toolkit updates — report those upstream. `--local` installs are
deliberately unverified and say so; that is not a finding.
