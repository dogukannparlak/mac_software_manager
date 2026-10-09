import Foundation

/// Updating a package from outside Homebrew and the App Store.
extension ToolkitController {

    /// Runs the package's own update command (`npm install -g`, `pipx
    /// upgrade`, `claude update`, …) in the user's terminal, through the engine's
    /// `update_tool` - which only acts on a package its last scan found.
    ///
    /// Always a terminal window, never a background run: these managers can
    /// stop to ask for things (a password for a root-owned npm prefix, a
    /// compiler for cargo), and their output is the only account of what
    /// happened.
    func updateTool(_ package: OtherPackage) {
        guard package.isUpdatable else { return }
        guard let script = scriptURL else {
            return report(.updateItem, subject: package.name, .toolkitMissing)
        }

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
