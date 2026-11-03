import Foundation

/// Updating a package from outside Homebrew and the App Store.
extension ToolkitController {

    /// Runs the package's own update command (`npm install -g`, `pipx
    /// upgrade`, `claude update`, …) through the engine's `run tool`, which
    /// only acts on a package its last scan found.
    ///
    /// In the background by default, exactly like a Homebrew row: none of
    /// these managers needs a password where this app finds them (a
    /// Homebrew-installed npm writes into the Homebrew prefix, pipx/uv/cargo
    /// and the self-updating tools into the home folder). Settings ›
    /// General › "Run updates in Terminal" opens a window instead, for
    /// anyone who wants to watch it - the same switch every other update
    /// follows.
    func updateTool(_ package: OtherPackage) {
        guard package.isUpdatable else { return }
        guard let script = scriptURL else {
            return report(.updateItem, subject: package.name, .toolkitMissing)
        }

        if preferences.runUpdatesInTerminal {
            return updateToolInTerminal(package, script: script)
        }

        guard !updatingOtherPackageIDs.contains(package.id) else { return }
        updatingOtherPackageIDs.insert(package.id)

        _ = startProcess(
            script: script,
            arguments: ["run", "tool", package.source.rawValue, package.name],
            // Several can run at once, and none of them is the bulk run the
            // shared progress banner follows.
            extraEnvironment: ["GUIDEAPP_NO_SHARED_PROGRESS": "1"]
        ) { [weak self] outcome in
            guard let self else { return }
            self.updatingOtherPackageIDs.remove(package.id)
            if !outcome.succeeded {
                self.report(.updateItem, subject: package.name, .from(outcome))
            }
            self.startNextQueuedTool()
            // The run rewrote other_packages/other_outdated; re-reading the
            // snapshot moves its last-check time, which is what reloads the
            // inventory these rows come from.
            self.reload()
        }
    }

    /// Lines several packages up to update one after another - what "Update
    /// Everything" does with this section (`updateEverything`).
    ///
    /// One at a time, not side by side: two of the same manager at once
    /// (two `npm install -g` into one prefix, two `cargo install`) write the
    /// same directories. A row's own Update button still starts at once; the
    /// queue just waits until nothing from this section is running.
    func updateTools(_ packages: [OtherPackage]) {
        for package in packages where package.isUpdatable
            && !updatingOtherPackageIDs.contains(package.id)
            && !queuedOtherPackages.contains(where: { $0.id == package.id }) {
            queuedOtherPackages.append(package)
        }
        startNextQueuedTool()
    }

    func isQueuedTool(_ package: OtherPackage) -> Bool {
        queuedOtherPackages.contains { $0.id == package.id }
    }

    func startNextQueuedTool() {
        guard updatingOtherPackageIDs.isEmpty, !queuedOtherPackages.isEmpty else { return }
        updateTool(queuedOtherPackages.removeFirst())
    }

    /// The same update in the user's terminal (`update_tool`).
    private func updateToolInTerminal(_ package: OtherPackage, script: URL) {
        let startedAt = Date()
        Task {
            let outcome = await Self.run(
                script: script,
                arguments: ["update_tool", package.source.rawValue, package.name]
            )
            await MainActor.run {
                guard outcome.succeeded else {
                    return self.reportFailure(outcome, startedAt: startedAt)
                }
                self.startProgressWatch()
            }
        }
    }
}
