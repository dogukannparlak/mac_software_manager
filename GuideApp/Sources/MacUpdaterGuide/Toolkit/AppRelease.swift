import CryptoKit
import Foundation

/// The pure half of the app's self-update: what a GitHub release says, which
/// of its files is the app, and whether a download is the file it claims to
/// be. No network, no AppKit, no file swapping - those live in `AppUpdater` -
/// so every decision here is unit-testable on its own.
///
/// The update source is GitHub Releases, not the repository's raw files. The
/// app is a compiled, signed bundle: replacing individual files inside it
/// would break its signature, and the Swift half cannot be "pulled" at all.
/// What `tools/build_release.sh` produces - the universal `.zip` and the
/// `SHA256SUMS.txt` describing it - is exactly the unit that can be swapped.

// MARK: - Versions

/// A dotted numeric version ("1.6.0", "v1.10", "1.6.0-beta"), compared
/// component by component, so 1.10 is newer than 1.9 (a string compare gets
/// that backwards). Anything after the first non-numeric character of a
/// component is ignored for ordering, and a missing component counts as 0, so
/// "1.6" == "1.6.0".
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    let raw: String

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // "1.6.0-beta.1" / "1.6.0+build" - the suffix does not order releases.
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) {
            text = String(text[..<cut])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            let digits = part.prefix(while: \.isNumber)
            guard let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        components = numbers
        raw = text
    }

    var description: String { raw }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

// MARK: - GitHub release

/// The fields of `GET /repos/{owner}/{repo}/releases/latest` this app reads.
/// That endpoint already skips drafts and pre-releases; `isInstallable`
/// checks again rather than trusting a response it did not ask for.
struct AppRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let pageURL: URL?
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    /// The file name `tools/build_release.sh` writes the checksums into.
    static let checksumFileName = "SHA256SUMS.txt"

    static func decode(_ data: Data) throws -> AppRelease {
        try JSONDecoder().decode(AppRelease.self, from: data)
    }

    var version: AppVersion? { AppVersion(tagName) }

    /// The app archive: `MacUpdaterGuide-<version>-macOS-universal.zip`.
    /// The `.dmg` is for people dragging the app in by hand; the `.zip` is
    /// smaller and `ditto` unpacks it without mounting anything.
    func appArchive(appName: String) -> Asset? {
        assets.first {
            $0.name.hasPrefix("\(appName)-")
                && $0.name.hasSuffix("-macOS-universal.zip")
        }
    }

    var checksumFile: Asset? {
        assets.first { $0.name == Self.checksumFileName }
    }

    /// True when this release is newer than `current` and carries both files
    /// an install needs. A release without its checksum file is never
    /// installed: there would be nothing to check the download against.
    func isInstallable(over current: AppVersion, appName: String) -> Bool {
        guard !isDraft, !isPrerelease,
              let version, version > current,
              appArchive(appName: appName) != nil,
              checksumFile != nil else { return false }
        return true
    }
}

// MARK: - Checksums

/// `shasum -a 256` output: `<64 hex>  <name>` per line (or `<hex> *<name>`
/// in binary mode). Lines that do not look like that are skipped, so a
/// trailing blank line or a comment cannot fail the whole file.
enum ChecksumList {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let hash = trimmed[..<space].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }

            var name = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard !name.isEmpty else { continue }
            result[name] = hash
        }
        return result
    }

    /// SHA-256 of a file, read in chunks so a large archive is never held in
    /// memory whole.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
