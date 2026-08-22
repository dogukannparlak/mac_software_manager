@testable import MacUpdaterGuide
import XCTest

/// Runs the Debug page's localization audit in CI.
///
/// `DebugLocalizationAudit` reads the Swift sources and reports three things
/// about every `Localized(en, tr)` pair. Two of them are always faults and are
/// asserted here:
///
/// - `missingTranslation` - a pair with no Turkish side at all, which ships an
///   English string to a Turkish user.
/// - `specifierMismatch` - the one that crashes. `String(format:)` fills its
///   arguments positionally off the format string, so a Turkish string with a
///   different ordered set of `%d`/`%@` reads an argument that was never
///   passed.
///
/// The third, `identical`, is deliberately *not* a failure. "Homebrew" really
/// is "Homebrew" in both languages, and a large share of the identical pairs
/// are product names, URLs and shell verbs. It is printed as a count so a
/// sudden jump is visible in the log, and nothing more.
///
/// **Why this scans the tree rather than a fixed list.** The audit itself
/// names two files (`UIStrings.swift`, `GuideContent.swift`) because that is
/// where the bulk of the strings live. Ten other files also call `Localized`,
/// and a file that gets split in two would quietly fall out of any list
/// written by hand. Walking the source directory cannot go out of date.
///
/// The parsing is `DebugLocalizationAudit.pairs(in:file:)` - the same
/// `nonisolated static` scanner the page calls. Nothing about how a Swift
/// literal is read is reimplemented here; a second parser would drift from
/// the first and the drift would look like a translation bug.
final class LocalizationAuditTests: XCTestCase {

    // MARK: - Faults

    func testEveryLocalizedPairHasATurkishSide() throws {
        let offenders = try pairs().filter { $0.issues.contains(.missingTranslation) }

        XCTAssertTrue(
            offenders.isEmpty,
            "\(offenders.count) pair(s) have no Turkish translation:\n" + describe(offenders)
        )
    }

    func testFormatSpecifiersLineUpBetweenTheTwoLanguages() throws {
        let offenders = try pairs().filter { $0.issues.contains(.specifierMismatch) }

        XCTAssertTrue(
            offenders.isEmpty,
            "\(offenders.count) pair(s) disagree on format specifiers - String(format:) reads "
                + "arguments positionally, so these are crashes, not typos:\n"
                + describe(offenders, showSpecifiers: true)
        )
    }

    // MARK: - Suspicion, reported but never a failure

    func testIdenticalPairsAreReportedWithoutFailing() throws {
        let identical = try pairs().filter { $0.issues.contains(.identical) }
        let total = try pairs().count

        // Legitimate far more often than not - product names, URLs, shell
        // verbs. Logged so a sudden jump is visible, asserted on never.
        print("[localization] \(identical.count) of \(total) pair(s) are identical in both languages (not a fault)")
    }

    // MARK: - The scan itself

    /// Without this, a scanner that silently matched nothing would make every
    /// assertion above pass by finding no offenders.
    func testTheScanActuallyFindsPairsAcrossSeveralFiles() throws {
        let found = try pairs()
        let files = Set(found.map(\.file))

        XCTAssertGreaterThan(found.count, 200, "Expected the app's several hundred pairs, got \(found.count)")
        XCTAssertGreaterThan(files.count, 2, "Expected pairs from more than the two files the Debug page lists")
        XCTAssertTrue(files.contains("UIStrings.swift"))
    }

    // MARK: - The detector, on input built to be wrong

    /// The assertions above are only worth something if the two faults are
    /// detectable at all, so each one is provoked here on a synthetic source.

    func testAnEmptyTurkishSideIsFlaggedAsMissing() {
        let found = DebugLocalizationAudit.pairs(in: #"let a = Localized("Update", "")"#, file: "T.swift")

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.issues, [.missingTranslation])
    }

    func testAWhitespaceOnlyTurkishSideIsFlaggedAsMissing() {
        let found = DebugLocalizationAudit.pairs(in: #"let a = Localized("Update", "   ")"#, file: "T.swift")

        XCTAssertTrue(found.first?.issues.contains(.missingTranslation) == true)
    }

    func testADifferentSpecifierOrderIsFlaggedAsAMismatch() {
        let source = #"let a = Localized("%d of %@", "%@ içinde %d")"#
        let found = DebugLocalizationAudit.pairs(in: source, file: "T.swift")

        XCTAssertEqual(found.first?.issues, [.specifierMismatch])
        XCTAssertEqual(found.first?.enSpecifiers, ["%d", "%@"])
        XCTAssertEqual(found.first?.trSpecifiers, ["%@", "%d"])
    }

    func testAMissingSpecifierIsFlaggedAsAMismatch() {
        let found = DebugLocalizationAudit.pairs(in: #"let a = Localized("%d apps", "uygulamalar")"#, file: "T.swift")

        XCTAssertTrue(found.first?.issues.contains(.specifierMismatch) == true)
    }

    /// `%%` is a literal percent sign and consumes no argument, so a language
    /// that needs a different number of them is not a fault.
    func testLiteralPercentSignsDoNotCountAsSpecifiers() {
        let found = DebugLocalizationAudit.pairs(in: #"let a = Localized("100%% done", "bitti")"#, file: "T.swift")

        XCTAssertEqual(found.first?.issues, [])
    }

    func testAnIdenticalPairIsNotAFault() {
        let found = DebugLocalizationAudit.pairs(in: #"let a = Localized("Homebrew", "Homebrew")"#, file: "T.swift")

        XCTAssertEqual(found.first?.issues, [.identical])
        XCTAssertFalse(DebugLocalizationAudit.Issue.identical.isFault)
    }

    func testMatchingSpecifiersInADifferentSentenceShapeAreClean() {
        let source = #"let a = Localized("%@ needs %d update", "%@ için %d güncelleme var")"#
        let found = DebugLocalizationAudit.pairs(in: source, file: "T.swift")

        XCTAssertEqual(found.first?.issues, [])
    }

    // MARK: - Reading the sources

    /// Three levels up from this file is the package root. `#filePath` is the
    /// real path in the checkout, which is what makes this work without the
    /// test bundle carrying a copy of the sources.
    private static let sourceRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/MacUpdaterGuide")

    /// Every Swift file under the module, minus the audit itself: that file
    /// carries `Localized(` in a doc comment and in the scanner's own marker
    /// string, neither of which is a call.
    private static func sourceFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Source tree not readable at \(sourceRoot.path(percentEncoded: false))")
        }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { $0.lastPathComponent != "DebugLocalizationAudit.swift" }
            .sorted { $0.path < $1.path }
    }

    private func pairs() throws -> [DebugLocalizationAudit.Pair] {
        try Self.sourceFiles().flatMap { file -> [DebugLocalizationAudit.Pair] in
            let text = try String(contentsOf: file, encoding: .utf8)
            return DebugLocalizationAudit.pairs(in: text, file: file.lastPathComponent)
        }
    }

    private func describe(_ pairs: [DebugLocalizationAudit.Pair], showSpecifiers: Bool = false) -> String {
        pairs.map { pair in
            var line = "  \(pair.file):\(pair.line) [\(pair.key)] EN=\(quoted(pair.en)) TR=\(quoted(pair.tr))"
            if showSpecifiers {
                line += " EN specifiers=\(pair.enSpecifiers) TR specifiers=\(pair.trSpecifiers)"
            }
            return line
        }
        .joined(separator: "\n")
    }

    private func quoted(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 60 ? "\"\(single.prefix(60))…\"" : "\"\(single)\""
    }
}
