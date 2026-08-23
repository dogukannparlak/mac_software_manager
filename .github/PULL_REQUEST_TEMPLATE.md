## What changed

<!-- A sentence or two. Link the issue if there is one. -->

## Checks

Tick what applies. Every box below is something CI actually runs, so an
unticked box that should be ticked is a red build, not a style note.

- [ ] **Branch and target.** Branched off `main` as `feature/<name>` or
      `fix/<name>`, and this PR targets `main`. (`origin` carries only `main`
      and `feature/debug-page` — there is no `develop` branch, despite the
      `Beta (Develop)` option the engine's update-channel dialog offers.)

- [ ] **Version and checksums, if I touched a distributed script.** Changing
      `setup_mac.sh`, `uninstall.sh`, `update_system.1h.sh` or any `lib/*.sh`
      means running both tools and committing the result **in the same commit
      as the change**:

      ./tools/sync_version.sh
      ./tools/generate_checksums.sh

      A stale `SHA256SUMS` does not fail loudly at runtime — self-update
      refuses to install a file it cannot verify, so it silently freezes every
      installed copy.

- [ ] **`bats tests/` passes locally.**

- [ ] **`swift test --package-path GuideApp` passes locally.**

- [ ] **Cache format, if I changed one.** A format change reaches five things
      in one commit: the writer (`lib/cache.sh`, `lib/updaters.sh`,
      `lib/selfupdate_apps.sh` or `lib/migrate.sh`), every shell reader,
      the Swift reader in `Toolkit/`, `Views/Debug/DebugFixtures.swift` (the
      Debug page is a second writer), and `CACHE_FORMAT.md` itself. Neither
      side imports the other's parser, so nothing catches a mismatch for you.

- [ ] **Both READMEs, if I changed either.** `README.md` and `README.tr.md` are
      kept structurally identical, section for section. Change one, change the
      other — same heading hierarchy, same order.

## Notes for the reviewer

<!-- Anything worth knowing: a judgement call, something deliberately left out,
     a shellcheck warning you decided to ignore and why. -->

---

CI runs four jobs on this PR. **Syntax, versions and checksums** and
**Swift unit tests** block a merge. **shellcheck** is advisory and never blocks
— it has no zsh mode, so it flags genuine quoting problems *and* zsh-only
syntax; read it, do not obey it blindly. **SwiftLint** blocks on errors only
(a line over 200 characters, a type body over 400 lines); the warning tier is
reported and passes.
