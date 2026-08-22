import Foundation
import Observation

/// Writes fake state over the engine's real files, and puts the real ones
/// back.
///
/// The rule this type exists to enforce: **nothing is overwritten without a
/// backup beside it first.** The backup is a sidecar file next to the
/// original rather than a copy held in memory, because the interesting
/// failures are the ones where the app is quit or crashes mid-injection -
/// and a restore that only works while the process that made the mess is
/// still alive is not a restore.
///
/// Two sidecars, never both, so "there was no file here" is recorded as
/// explicitly as "here is what was here":
///
/// - `<name>.debugbackup` - a real file was displaced; restore copies it back.
/// - `<name>.debugbackup.none` - there was no file; restore deletes the fake.
///
/// The event directories (`notifications/`, `results/`) are never overwritten
/// at all: injection only ever *adds* a file there, named with a `.debug.`
/// marker so cleanup can delete exactly what this page created and nothing a
/// real run left. CACHE_FORMAT.md states outright that those names carry no
/// meaning and readers must not parse them, which is what makes that safe.
///
/// Everything is therefore recoverable from disk alone: `restoreAll` scans
/// for sidecars and markers rather than consulting anything in memory, so it
/// works just as well after a relaunch.
///
/// English-only string literals - see the header of `DebugView.swift`.
@MainActor
@Observable
final class DebugStateStore {

    static let backupSuffix = ".debugbackup"
    static let absentSuffix = ".debugbackup.none"
    /// Part of the file name for anything this page drops into an event
    /// directory. `notify.debug.<uuid>` still matches the shape the engine
    /// writes (`notify.<pid>.<random>`), so the bridge treats it no
    /// differently - it just tells cleanup which files are ours.
    static let injectedMarker = ".debug."

    /// Paths currently holding injected content, as found on disk.
    private(set) var injectedPaths: [String] = []
    private(set) var lastError: String?

    /// Drives the warning strip. Deliberately derived from a disk scan, not
    /// from a flag set on write: an injection left behind by an earlier
    /// launch has to raise the same warning as one made a second ago.
    var isInjecting: Bool { !injectedPaths.isEmpty }

    /// Scanned shallowly, so the subdirectories of the support folder show up
    /// as names rather than being descended into - which is what we want,
    /// since each of them is listed here in its own right.
    ///
    /// The support directory itself is in the list because the config files
    /// (`settings.conf`, `ignored_apps.conf`, ...) live there, and the
    /// Feature drill can reset one to its template. Those are hand-edited
    /// files with no engine to regenerate them, so they are the ones a lost
    /// backup would hurt most.
    private var directories: [URL] {
        [
            ToolkitPaths.supportDirectory,
            ToolkitPaths.cacheDirectory,
            ToolkitPaths.notificationsDirectory,
            ToolkitPaths.resultsDirectory
        ]
    }

    init() {
        rescan()
    }

    // MARK: - Scanning

    func rescan() {
        var found: [String] = []
        for directory in directories {
            let path = directory.path(percentEncoded: false)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }

            for name in names {
                if name.hasSuffix(Self.backupSuffix) {
                    found.append(path + "/" + String(name.dropLast(Self.backupSuffix.count)))
                } else if name.hasSuffix(Self.absentSuffix) {
                    found.append(path + "/" + String(name.dropLast(Self.absentSuffix.count)))
                } else if name.contains(Self.injectedMarker) {
                    found.append(path + "/" + name)
                }
            }
        }
        injectedPaths = found.sorted()
    }

    // MARK: - Writing over a real file

    /// Backs up whatever is at `url`, then writes `contents` in its place.
    ///
    /// The backup is taken once per file, not once per write: a second
    /// injection over an already-injected file must not overwrite the
    /// sidecar with the first injection's fake content, which would lose the
    /// real file for good.
    func write(_ contents: String, to url: URL, log: DebugLog) {
        do {
            try backUp(url)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            log.note("Injected \(url.lastPathComponent) (\(contents.split(separator: "\n").count) lines)")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.append("Injection failed for \(url.lastPathComponent): \(error.localizedDescription)", stream: .stderr)
        }
        rescan()
    }

    /// Backdates a file this page wrote.
    ///
    /// The modification time of `cache/progress` is part of its contract -
    /// a `running` entry that has stopped aging is a run that died - so the
    /// only way to test the staleness path without waiting fifteen real
    /// minutes is to write the entry and then age it.
    func backdate(_ url: URL, by interval: TimeInterval, log: DebugLog) {
        let date = Date().addingTimeInterval(-interval)
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            log.note("Backdated \(url.lastPathComponent) by \(Int(interval))s")
        } catch {
            log.append("Could not backdate \(url.lastPathComponent): \(error.localizedDescription)", stream: .stderr)
        }
    }

    /// Deletes the file at `url`, keeping any backup so the real content can
    /// still be put back. For testing the "no record at all" paths, where the
    /// absence *is* the state being injected.
    func removeInjecting(_ url: URL, log: DebugLog) {
        do {
            try backUp(url)
            try? FileManager.default.removeItem(at: url)
            log.note("Removed \(url.lastPathComponent) (backup kept)")
        } catch {
            log.append("Could not remove \(url.lastPathComponent): \(error.localizedDescription)", stream: .stderr)
        }
        rescan()
    }

    /// Takes the backup without writing anything, for the one caller whose
    /// content is produced by somebody else's writer (`ToolkitSettings.save()`
    /// writes `settings.conf` itself). Call it *before* that writer runs.
    func prepare(_ url: URL, log: DebugLog) {
        do {
            try backUp(url)
            log.note("Backed up \(url.lastPathComponent) before an external writer")
        } catch {
            lastError = error.localizedDescription
            log.append("Could not back up \(url.lastPathComponent): \(error.localizedDescription)", stream: .stderr)
        }
        rescan()
    }

    private func backUp(_ url: URL) throws {
        let manager = FileManager.default
        let path = url.path(percentEncoded: false)
        let backup = URL(filePath: path + Self.backupSuffix)
        let absent = URL(filePath: path + Self.absentSuffix)

        // Already backed up by an earlier injection: leave it alone. The
        // sidecar holds the *real* file, and this is the one line standing
        // between a second injection and losing it.
        guard !manager.fileExists(atPath: backup.path(percentEncoded: false)),
              !manager.fileExists(atPath: absent.path(percentEncoded: false)) else { return }

        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if manager.fileExists(atPath: path) {
            try manager.copyItem(at: url, to: backup)
        } else {
            try Data().write(to: absent)
        }
    }

    // MARK: - Dropping an event file

    /// Adds one file to an event directory. Nothing is displaced, so nothing
    /// is backed up - only the name marks it as ours.
    @discardableResult
    func drop(_ contents: String, into directory: URL, prefix: String, log: DebugLog) -> URL? {
        let name = "\(prefix)\(Self.injectedMarker)\(UUID().uuidString.prefix(8))"
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Temp file plus rename, the way the engine writes these: the
            // directory watcher must never see a half-written record.
            let temporary = URL(filePath: url.path(percentEncoded: false) + ".tmp")
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: temporary, to: url)
            log.note("Dropped \(directory.lastPathComponent)/\(name)")
            rescan()
            return url
        } catch {
            lastError = error.localizedDescription
            log.append("Could not drop into \(directory.lastPathComponent): \(error.localizedDescription)", stream: .stderr)
            rescan()
            return nil
        }
    }

    // MARK: - Restoring

    /// Puts every real file back and deletes everything this page created.
    ///
    /// Driven entirely by what is on disk, so it is idempotent, survives a
    /// relaunch, and can be pressed when nothing is injected without doing
    /// any harm.
    func restoreAll(log: DebugLog) {
        var restored = 0
        var deleted = 0

        for directory in directories {
            let path = directory.path(percentEncoded: false)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }

            for name in names.sorted() {
                let url = directory.appending(path: name)
                if name.hasSuffix(Self.backupSuffix) {
                    restored += restore(from: url, suffix: Self.backupSuffix) ? 1 : 0
                } else if name.hasSuffix(Self.absentSuffix) {
                    deleted += discard(markedBy: url) ? 1 : 0
                } else if name.contains(Self.injectedMarker) {
                    try? FileManager.default.removeItem(at: url)
                    deleted += 1
                }
            }
        }

        log.note("Restored \(restored) file(s), deleted \(deleted) injected file(s).")
        lastError = nil
        rescan()
    }

    private func restore(from backup: URL, suffix: String) -> Bool {
        let manager = FileManager.default
        let backupPath = backup.path(percentEncoded: false)
        let original = URL(filePath: String(backupPath.dropLast(suffix.count)))

        try? manager.removeItem(at: original)
        do {
            try manager.moveItem(at: backup, to: original)
            return true
        } catch {
            // The backup stays exactly where it is: a restore that could not
            // finish must leave the only copy of the real content on disk,
            // not tidy it away.
            return false
        }
    }

    private func discard(markedBy marker: URL) -> Bool {
        let manager = FileManager.default
        let markerPath = marker.path(percentEncoded: false)
        let original = URL(filePath: String(markerPath.dropLast(Self.absentSuffix.count)))

        try? manager.removeItem(at: original)
        try? manager.removeItem(at: marker)
        return true
    }
}
