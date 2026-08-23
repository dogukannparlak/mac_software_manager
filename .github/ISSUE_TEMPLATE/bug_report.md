---
name: Bug report
about: Something in the engine or the app does not behave as documented
title: ''
labels: bug
assignees: ''
---

## What happened

<!-- What you did, what you expected, what you got instead. -->

## Versions

This project is two halves that ship separately, so **both versions matter** —
an app built against a newer cache format than the installed engine writes is a
real failure mode.

- **App version:**
- **Engine (toolkit) version:**

Settings → About shows both on one card. From a terminal, the engine carries
its version in a `<bitbar.version>` header:

```sh
grep -m1 '<bitbar.version>' "$(find ~/Library/Application\ Support/MacSoftwareUpdater \
    -maxdepth 1 -name 'update_system.*.sh' 2>/dev/null | head -1)"
```

<!-- An older install can still be named update_system.6h.sh rather than 1h,
     which is why the find matches on the prefix. If the app came from the disk
     image and was never set up from a terminal, there is no installed copy:
     read the version from Settings → About instead. -->

## System

- **macOS version:**
- **Architecture:** <!-- Apple Silicon or Intel — `uname -m` prints arm64 or x86_64 -->
- **Homebrew installed?** <!-- yes / no -->

Homebrew is not optional: the engine refuses to start a run without it
(`❌ Error: Homebrew is not installed!`). `brew --version` settles it.

## Engine or app?

The app only reads what the engine writes, so the first thing worth knowing is
which half is wrong. Run the engine directly and paste the output:

```sh
"$(find ~/Library/Application\ Support/MacSoftwareUpdater \
    -maxdepth 1 -name 'update_system.*.sh' 2>/dev/null | head -1)" run all
```

<details>
<summary>Output</summary>

```
paste here
```

</details>

- If the engine misbehaves here, it is an engine bug and the app is reporting it faithfully.
- If the engine looks right but the app disagrees, it is an app or cache-format bug.

Running with no arguments instead renders the menu from the cache alone and
never touches the network — useful for separating a stale cache from a failing
update.

## Anything else

<!-- Screenshots, a relevant slice of ~/Library/Application Support/MacSoftwareUpdater/,
     whether it reproduces after a fresh run. Redact anything you would rather not publish. -->
