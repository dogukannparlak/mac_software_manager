import Foundation
import Observation

/// Every `Localized` pair in the app, read out of the source files.
///
/// **Why it parses source rather than reflecting over the types.** `UIStrings`
/// and `GuideContent` are enums of `static let`s, and Swift has no reflection
/// over static members - `Mirror` sees nothing. The alternatives were to
/// hand-list several hundred keys (which would be stale within a week and
/// would silently miss exactly the new string somebody forgot to translate)
/// or to read the files. Reading the files is the only version of this that
/// cannot go quietly out of date.
///
/// It therefore needs the repository on disk, which a Debug build run from
/// the checkout has and a copy installed elsewhere does not. That is stated
/// on screen rather than papered over.
///
/// English-only string literals - see the header of `DebugView.swift`.
@MainActor
@Observable
final class DebugLocalizationAudit {

    /// What is wrong with a pair. A pair can have more than one.
    enum Issue: String, CaseIterable, Identifiable, Hashable {
        /// No Turkish at all.
        case missingTranslation
        /// Both sides identical. Often legitimate - "Homebrew" is "Homebrew"
        /// - which is why this is a *suspicion*, listed separately from the
        /// two that are always faults.
        case identical
        /// The format specifiers do not line up between the two. This is the
        /// one that crashes: `String(format:)` reads its arguments
        /// positionally off the format string, so a Turkish string with an
        /// extra `%@` reads a pointer that was never passed.
        case specifierMismatch

        var id: String { rawValue }

        var label: String {
            switch self {
            case .missingTranslation: return "TR missing"
            case .identical: return "TR == EN"
            case .specifierMismatch: return "Specifier mismatch"
            }
        }

        var isFault: Bool { self != .identical }
    }

    struct Pair: Identifiable, Sendable {
        let id: String
        let key: String
        let file: String
        let line: Int
        let en: String
        let tr: String
        let enSpecifiers: [String]
        let trSpecifiers: [String]
        let issues: Set<Issue>
    }

    private(set) var pairs: [Pair] = []
    private(set) var sourceStatus: String = ""
    private(set) var didFindSources = false

    var faults: Int { pairs.filter { $0.issues.contains(where: \.self.isFault) }.count }

    func load() {
        var found: [Pair] = []
        var missing: [String] = []

        for file in Self.sourceFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                missing.append(file.lastPathComponent)
                continue
            }
            found.append(contentsOf: Self.pairs(in: text, file: file.lastPathComponent))
        }

        pairs = found
        didFindSources = missing.isEmpty && !found.isEmpty
        sourceStatus = didFindSources
            ? "\(found.count) pair(s) from \(Self.sourceFiles.count) file(s) under \(Self.sourceRoot.path(percentEncoded: false))"
            : """
            Could not read \(missing.joined(separator: ", ")) under \
            \(Self.sourceRoot.path(percentEncoded: false)). This audit reads the Swift sources, so it \
            only works from a build run against the checkout.
            """
    }

    /// Markdown, generated from the same `Pair` values the table draws.
    func markdown(filter: Issue?) -> String {
        let rows = filtered(by: filter)
        var lines = [
            "# Localization audit",
            "",
            "_\(rows.count) of \(pairs.count) pair(s)\(filter.map { ", filtered to \($0.label)" } ?? "")_",
            "",
            "| Key | File:line | EN | TR | Issues |",
            "| --- | --- | --- | --- | --- |"
        ]
        for pair in rows {
            let issues = pair.issues.map(\.self.label).sorted().joined(separator: ", ")
            lines.append("| \(pair.key) | \(pair.file):\(pair.line) | \(cell(pair.en)) | \(cell(pair.tr)) | \(issues) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func filtered(by issue: Issue?) -> [Pair] {
        guard let issue else { return pairs }
        return pairs.filter { $0.issues.contains(issue) }
    }

    func count(of issue: Issue) -> Int {
        pairs.filter { $0.issues.contains(issue) }.count
    }

    /// Newlines and pipes both break a markdown table cell.
    private func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Where the sources are

    /// Derived from `#filePath`, which in a Debug build is the real path of
    /// this file in the checkout. Three levels up from `Views/Debug/` is the
    /// module root.
    static let sourceRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let sourceFiles: [URL] = [
        sourceRoot.appending(path: "Localization/UIStrings.swift"),
        sourceRoot.appending(path: "Content/GuideContent.swift")
    ]

    // MARK: - Parsing

    /// Finds every `Localized("…", "…")` and pulls both literals out.
    ///
    /// A hand-rolled scanner rather than a regular expression, because the
    /// second argument is regularly a `"""` block with `\` line continuations
    /// and escaped quotes inside it - which is exactly the shape a regex
    /// gets wrong quietly.
    nonisolated static func pairs(in source: String, file: String) -> [Pair] {
        var results: [Pair] = []
        let characters = Array(source)
        let marker = Array("Localized(")
        var index = 0

        while index < characters.count {
            guard matches(characters, at: index, marker) else {
                index += 1
                continue
            }

            var cursor = index + marker.count
            guard let en = literal(characters, from: &cursor) else {
                index += marker.count
                continue
            }
            skip(characters, &cursor, past: ",")
            guard let tr = literal(characters, from: &cursor) else {
                index += marker.count
                continue
            }

            let line = 1 + characters[0..<index].filter { $0 == "\n" }.count
            let location = "\(file):\(line)"
            results.append(pair(
                key: key(characters, before: index) ?? location,
                id: "\(location):\(results.count)",
                file: file,
                line: line,
                text: (en: en, tr: tr)
            ))
            index = cursor
        }

        return results
    }

    nonisolated private static func pair(
        key: String, id: String, file: String, line: Int, text: (en: String, tr: String)
    ) -> Pair {
        let enSpecs = specifiers(in: text.en)
        let trSpecs = specifiers(in: text.tr)

        var issues: Set<Issue> = []
        if text.tr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.insert(.missingTranslation) }
        if !text.en.isEmpty, text.en == text.tr { issues.insert(.identical) }
        if enSpecs != trSpecs { issues.insert(.specifierMismatch) }

        return Pair(
            id: id,
            key: key,
            file: file,
            line: line,
            en: text.en,
            tr: text.tr,
            enSpecifiers: enSpecs,
            trSpecifiers: trSpecs,
            issues: issues
        )
    }

    /// Ordered, not counted: `String(format:)` fills arguments in the order
    /// the specifiers appear, so `"%d of %@"` and `"%@ of %d"` are a crash
    /// even though the counts match.
    ///
    /// `%%` is dropped - it is a literal percent sign and consumes no
    /// argument, so a language that needs one more of them is not a fault.
    nonisolated static func specifiers(in text: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?[-+ 0#]*[0-9*]*(?:\\.[0-9*]+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOeEfgGaAcCsSpn%]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let token = String(text[found])
            return token == "%%" ? nil : token
        }
    }

    // MARK: - Scanner

    nonisolated private static func matches(_ characters: [Character], at index: Int, _ marker: [Character]) -> Bool {
        guard index + marker.count <= characters.count else { return false }
        for offset in 0..<marker.count where characters[index + offset] != marker[offset] {
            return false
        }
        return true
    }

    nonisolated private static func skip(_ characters: [Character], _ cursor: inout Int, past target: Character) {
        while cursor < characters.count {
            if characters[cursor] == target {
                cursor += 1
                return
            }
            guard characters[cursor].isWhitespace else { return }
            cursor += 1
        }
    }

    /// One Swift string literal, single-line or `"""`, starting at the next
    /// non-whitespace character.
    nonisolated private static func literal(_ characters: [Character], from cursor: inout Int) -> String? {
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }

        if matches(characters, at: cursor, ["\"", "\"", "\""]) {
            return multilineLiteral(characters, from: &cursor)
        }
        return singleLineLiteral(characters, from: &cursor)
    }

    nonisolated private static func singleLineLiteral(_ characters: [Character], from cursor: inout Int) -> String? {
        cursor += 1
        var raw = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\", cursor + 1 < characters.count {
                raw.append(character)
                raw.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            if character == "\"" {
                cursor += 1
                return unescape(raw)
            }
            raw.append(character)
            cursor += 1
        }
        return nil
    }

    nonisolated private static func multilineLiteral(_ characters: [Character], from cursor: inout Int) -> String? {
        cursor += 3
        var raw = ""
        while cursor < characters.count {
            if matches(characters, at: cursor, ["\"", "\"", "\""]) {
                cursor += 3
                return unescape(normalizeBlock(raw))
            }
            raw.append(characters[cursor])
            cursor += 1
        }
        return nil
    }

    /// Turns a `"""` block into the string Swift would produce: leading
    /// indentation off every line, and a trailing `\` joining a line to the
    /// next without a newline.
    nonisolated private static func normalizeBlock(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == " " || $0 == "\t" } }
            .map(String.init)

        var output = ""
        for line in lines.dropFirst() {
            if line.hasSuffix("\\") {
                output += String(line.dropLast())
            } else {
                output += line + "\n"
            }
        }
        // The last line before the closing delimiter contributes no newline.
        if output.hasSuffix("\n") { output.removeLast() }
        return output
    }

    nonisolated private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// The `static let <name> =` immediately before the call, when there is
    /// one. `GuideContent` uses `Localized` inline inside struct literals
    /// (`title:`, `body:`) where there is no name to find - those fall back
    /// to file:line, which is still enough to open the right place.
    nonisolated private static func key(_ characters: [Character], before index: Int) -> String? {
        let start = max(0, index - 160)
        let prefix = String(characters[start..<index])
        let pattern = "(?:static\\s+)?let\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?::\\s*Localized\\s*)?=\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let range = Range(match.range(at: 1), in: prefix) else { return nil }
        return String(prefix[range])
    }
}
