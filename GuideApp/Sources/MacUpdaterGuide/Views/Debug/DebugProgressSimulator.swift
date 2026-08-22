import Foundation
import Observation

/// Plays a run's worth of `cache/progress` entries, one frame at a time.
///
/// A real run writes that file as it goes and the app reads it every 700ms;
/// everything downstream - the progress banner, the menu bar spinner,
/// `ProgressWatch`'s startup and quiet-tick logic, the concurrency queue that
/// waits behind a `running` entry - is driven by nothing but those lines and
/// the file's modification time. So a scripted writer is not an approximation
/// of a run for those readers: it is indistinguishable from one.
///
/// What it deliberately cannot reproduce is a run that the app itself
/// launched, because `ToolkitController` only trusts entries newer than the
/// watch it started. Injecting frames exercises the readers; it does not
/// fake a process.
///
/// English-only string literals - see the header of `DebugView.swift`.
@MainActor
@Observable
final class DebugProgressSimulator {

    /// One line of `cache/progress`, plus a note about why it is in the
    /// script.
    struct Frame: Identifiable, Sendable {
        let id: Int
        let state: String
        let phase: String
        var item: String = ""
        var index: Int?
        var total: Int?
        /// Shown next to the frame in the step list.
        var note: String = ""

        var line: String {
            DebugFixtures.progress(state: state, phase: phase, item: item, index: index, total: total)
        }

        var summary: String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The runs worth replaying. Each is a real sequence the engine can
    /// produce, not an invented one.
    enum Script: String, CaseIterable, Identifiable, Hashable {
        case successfulRun
        case runWithFailures
        case diesMidRun
        case singleItem
        case installApp
        case scanMigration
        case launchFailed
        case terminalPermission

        var id: String { rawValue }

        var label: String {
            switch self {
            case .successfulRun: return "Full run, succeeds"
            case .runWithFailures: return "Full run, 2 of 4 failed"
            case .diesMidRun: return "Dies mid-upgrade"
            case .singleItem: return "Single item"
            case .installApp: return "Install app (Sparkle)"
            case .scanMigration: return "Scan for migrations"
            case .launchFailed: return "Terminal never opened"
            case .terminalPermission: return "Automation permission refused"
            }
        }

        var detail: String {
            switch self {
            case .successfulRun:
                return "starting → brew-update → analyze → brew-upgrade ×3 → mas-upgrade → cleanup → verify → done|complete."
            case .runWithFailures:
                return """
                Ends on failed|complete-with-failures with index=2, total=4 - the counts the banner \
                words as "2 of 4 failed" rather than showing a green tick.
                """
            case .diesMidRun:
                return """
                Stops writing halfway through the upgrade. Use "Age to stale" afterwards to make the \
                reader treat the run as dead - that is the only way to reach that path without waiting.
                """
            case .singleItem:
                return "The single phase, as a terminal-mode one-item run writes it."
            case .installApp:
                return "The install-app phase: a Sparkle or GitHub app being replaced."
            case .scanMigration:
                return "scan-migration, stepping through applications one at a time."
            case .launchFailed:
                return "failed|launch-failed with the terminal app in item - written when no window ever opened."
            case .terminalPermission:
                return """
                failed|terminal-permission - the one launch failure that comes with an instruction, \
                which the reader words in the user's language from the app name in item.
                """
            }
        }

        var frames: [Frame] { DebugProgressSimulator.frames(for: self) }
    }

    private(set) var frames: [Frame] = []
    /// How many frames have been written. Equal to `frames.count` once the
    /// script has run to the end.
    private(set) var position = 0
    private(set) var isPlaying = false

    /// Seconds between frames. A real run's phases are minutes apart, so
    /// this is the one thing about the replay that is not faithful - and it
    /// is the whole reason for replaying it.
    var interval: TimeInterval = 0.8

    var script: Script = .successfulRun {
        didSet { load(script) }
    }

    private var task: Task<Void, Never>?

    var isFinished: Bool { position >= frames.count }
    var nextFrame: Frame? { position < frames.count ? frames[position] : nil }

    init() {
        load(script)
    }

    func load(_ script: Script) {
        pause()
        frames = script.frames
        position = 0
    }

    /// Writes the next frame and advances. The write itself is the caller's,
    /// so this type never touches the filesystem and the backup rule stays
    /// in one place (`DebugStateStore`).
    func step(_ write: (Frame) -> Void) {
        guard position < frames.count else { return }
        write(frames[position])
        position += 1
    }

    func play(_ write: @escaping (Frame) -> Void) {
        guard !isPlaying, !isFinished else { return }
        isPlaying = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying, !self.isFinished else { return }
                self.step(write)
                if self.isFinished {
                    self.isPlaying = false
                    return
                }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    func rewind() {
        pause()
        position = 0
    }

    // MARK: - The scripts

    /// Phase tokens exactly as CACHE_FORMAT.md lists them for this entry.
    /// Kept here as strings rather than built from `UpdateProgress.Phase`,
    /// so a fixture cannot quietly follow the reader if the reader drifts -
    /// the point of a fixture is to be the other side of the contract.
    static let phaseTokens = [
        "starting", "brew-update", "analyze", "brew-upgrade", "mas-upgrade",
        "cleanup", "verify", "install-app", "single", "scan-migration",
        "migrate", "complete", "complete-with-failures", "launch-failed",
        "terminal-permission"
    ]

    /// The closed set of states. Anything else makes the reader drop the
    /// line, which is itself worth being able to inject - see the malformed
    /// buttons on the panel.
    static let stateTokens = ["running", "done", "failed"]

    // `nonisolated`: the scripts are pure data, and `Script.frames` is read
    // from the enum itself, which is not actor-isolated the way its enclosing
    // class is.
    nonisolated private static func frames(for script: Script) -> [Frame] {
        switch script {
        case .successfulRun: return fullRun(failed: 0)
        case .runWithFailures: return fullRun(failed: 2)
        case .diesMidRun: return Array(fullRun(failed: 0).prefix(5))
        case .singleItem: return singleItemFrames
        case .installApp: return installAppFrames
        case .scanMigration: return scanMigrationFrames
        case .launchFailed:
            return [Frame(id: 0, state: "failed", phase: "launch-failed", item: "iTerm2",
                          note: "item carries the terminal it tried to open")]
        case .terminalPermission:
            return [Frame(id: 0, state: "failed", phase: "terminal-permission", item: "iTerm2",
                          note: "the reader turns this into the System Settings instruction")]
        }
    }

    nonisolated private static func fullRun(failed: Int) -> [Frame] {
        let packages = ["alt-tab", "ripgrep", "jq"]
        var frames: [Frame] = [
            Frame(id: 0, state: "running", phase: "starting", note: "before the lock is taken"),
            Frame(id: 1, state: "running", phase: "brew-update", note: "can legitimately be quiet for a long time"),
            Frame(id: 2, state: "running", phase: "analyze", note: "no counts yet: indeterminate bar")
        ]

        for (offset, package) in packages.enumerated() {
            frames.append(Frame(
                id: 3 + offset,
                state: "running",
                phase: "brew-upgrade",
                item: package,
                index: offset + 1,
                total: 4,
                note: offset == 0 ? "counts appear: the bar goes determinate" : ""
            ))
        }

        frames.append(Frame(id: 6, state: "running", phase: "mas-upgrade", item: "Keynote", index: 4, total: 4))
        frames.append(Frame(id: 7, state: "running", phase: "cleanup"))
        frames.append(Frame(id: 8, state: "running", phase: "verify", note: "the pass that decides the ending below"))

        if failed > 0 {
            frames.append(Frame(
                id: 9,
                state: "failed",
                phase: "complete-with-failures",
                index: failed,
                total: 4,
                note: "index/total are failed/attempted here, not progress"
            ))
        } else {
            frames.append(Frame(id: 9, state: "done", phase: "complete", note: "green tick, run over"))
        }
        return frames
    }

    nonisolated private static let singleItemFrames = [
        Frame(id: 0, state: "running", phase: "starting"),
        Frame(id: 1, state: "running", phase: "single", item: "alt-tab",
              note: "what a terminal-mode single-item run writes"),
        Frame(id: 2, state: "done", phase: "complete")
    ]

    nonisolated private static let installAppFrames = [
        Frame(id: 0, state: "running", phase: "starting"),
        Frame(id: 1, state: "running", phase: "install-app", item: "BetterDisplay",
              note: "one download, so silence here is normal"),
        Frame(id: 2, state: "done", phase: "complete")
    ]

    nonisolated private static let scanMigrationFrames = [
        Frame(id: 0, state: "running", phase: "starting"),
        Frame(id: 1, state: "running", phase: "scan-migration", item: "Rectangle", index: 1, total: 3,
              note: "steps app by app, so silence really means a dead scan"),
        Frame(id: 2, state: "running", phase: "scan-migration", item: "Keka", index: 2, total: 3),
        Frame(id: 3, state: "running", phase: "scan-migration", item: "Şifre Kasası 🔐", index: 3, total: 3),
        Frame(id: 4, state: "done", phase: "complete")
    ]
}
