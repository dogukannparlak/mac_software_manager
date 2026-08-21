import Foundation

/// What the installed shell engine says it can be relied on to write.
///
/// See CACHE_FORMAT.md ("Engine contract") for the format this and the shell
/// writer (`engine_write()` in lib/cache.sh) both agree on.
///
/// This exists because the two halves of the toolkit ship separately. The app
/// is built here; the engine is whatever `setup_mac.sh` last installed under
/// `~/Library/Application Support/MacSoftwareUpdater`, and it can be older
/// than the app that is reading its files. When it is, the app asks for
/// something the engine never writes and has, until now, quietly fallen back
/// to guessing - which is how a `brew upgrade` that actually succeeded ended
/// up on screen as "failed": the run could not file a result record, so the
/// row's outcome was worked out from a cache the dead run never refreshed.
///
/// The record is deliberately not the release version. `<bitbar.version>`
/// tracks releases, and two engines carrying the same one can still write
/// different things: the whole `results/` contract was added within v1.5.0,
/// so that string describes both an engine that files single-item results and
/// one that cannot. This number moves only when what a reader may depend on
/// moves.
struct EngineContract: Equatable, Sendable {

    /// The only format version this build understands. The shell writer
    /// (`ENGINE_FORMAT_VERSION` in lib/cache.sh) and this must agree, or
    /// `parse` fails closed instead of misreading.
    static let formatVersion = "v1"

    /// The contract this build needs from the engine.
    ///
    /// `1` is single-item run results: `ToolkitController` resolves a row it
    /// launched from the record the run files (`ItemRunResult`), and an engine
    /// that predates `result_write()` never files one. Raise this in the same
    /// change that starts depending on a newer `ENGINE_CONTRACT`.
    static let required = 1

    /// When the engine wrote this record. Whole seconds - it comes from the
    /// shell's `EPOCHSECONDS`.
    let recordedAt: Date
    /// What the engine declares it writes. Compared against `required`, never
    /// against the release.
    let contract: Int
    /// The engine's release version, for diagnostics only - never part of the
    /// decision. May be empty.
    let release: String

    var meetsRequirement: Bool { contract >= Self.required }

    /// `v1|epoch|contract|release`
    ///
    /// Fails closed on anything it cannot read whole - a missing or unknown
    /// version, a short line, an unparseable timestamp, a non-numeric
    /// contract. `nil` means "this engine said nothing", which is exactly how
    /// a pre-contract engine reads, and is the same fail-closed rule
    /// `UpdateProgress` and `ItemRunResult` follow.
    static func parse(raw: String) -> EngineContract? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count == 4, fields[0] == formatVersion else { return nil }
        guard let epoch = TimeInterval(fields[1]) else { return nil }
        guard let contract = Int(fields[2]) else { return nil }

        return EngineContract(
            recordedAt: Date(timeIntervalSince1970: epoch),
            contract: contract,
            release: fields[3]
        )
    }

    /// Whether this record is the account of the engine that ran for a run
    /// starting at `startedAt`, rather than one left behind earlier.
    ///
    /// The engine rewrites the record on every invocation, before it
    /// dispatches anything, so a run that just finished has necessarily left a
    /// current one - if it was new enough to write one at all. That is what
    /// makes absence conclusive at the moment it is checked, instead of
    /// ambiguous between "too old to report" and "has not run yet".
    ///
    /// It also closes the downgrade case: a record left by a newer engine that
    /// has since been replaced by an older one is older than the run asking,
    /// and is correctly read as "this engine said nothing" rather than
    /// vouching for an engine that is no longer installed.
    ///
    /// Same one-second slack, for the same reason, as
    /// `ItemRunResult.belongs(toRun:startedAt:)`: the stamp is whole seconds
    /// and the run's start is not.
    func covers(runStartedAt: Date) -> Bool {
        recordedAt >= runStartedAt.addingTimeInterval(-ItemRunResultStore.timestampGranularity)
    }
}

/// The `cache/engine` file: the installed engine's own statement of what it
/// writes, refreshed by every invocation.
enum EngineContractStore {

    /// The record as it is on disk, whenever it was written.
    static func load() -> EngineContract? {
        guard let data = try? Data(contentsOf: ToolkitPaths.engineFile),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return EngineContract.parse(raw: raw)
    }

    /// What the engine that ran for this run declared, or `nil` when it
    /// declared nothing - an engine older than the contract, which writes no
    /// record at all.
    ///
    /// Ask this straight after a run has finished, which is the only moment
    /// the answer is unambiguous: see `EngineContract.covers(runStartedAt:)`.
    static func declared(forRunStartedAt startedAt: Date) -> EngineContract? {
        guard let record = load(), record.covers(runStartedAt: startedAt) else { return nil }
        return record
    }

    /// Whether the engine that ran for this run can be relied on for
    /// everything this build reads. `false` covers both "declared less than
    /// `required`" and "declared nothing at all".
    static func satisfiesRequirement(forRunStartedAt startedAt: Date) -> Bool {
        declared(forRunStartedAt: startedAt)?.meetsRequirement == true
    }
}
